#!/usr/bin/env bash

set -euo pipefail
IFS=$'\n\t'

usage() {
  cat <<'EOF'
Usage: plan.sh --state-json <json> --slug <slug> --description <text> \
  --cwd <path> --project-name <name> [--agent <claude|codex>] \
  [--root <path>] [--no-worktree] [--keep-alive] \
  [--advisor-mode <none|plan|review>] \
  [--executor-tier <default|capable|fast>]

Build a pure dispatch plan JSON. No files are written and no external tools
such as cmux/zmx/git are invoked.

Worktree behavior:
  By default the plan provisions a per-task git worktree under
  <cwd>/.worktrees/dispatch-<slug>-<agent>-<N> on branch
  dispatch/<slug>-<agent>-<N>. The sibling agent attaches inside that
  worktree so concurrent dispatches do not collide on git state.
  Pass --no-worktree to keep the agent in the project root (escape
  hatch for read-only or doc-only tasks).
EOF
}

slugify() {
  printf '%s' "$1" \
    | tr '[:upper:]' '[:lower:]' \
    | sed -E 's/[^a-z0-9]+/-/g; s/^-+//; s/-+$//; s/-{2,}/-/g'
}

state_json=''
task_slug=''
description=''
cwd=''
project_name=''
agent_family='claude'
orchestrator_root="${ORCHESTRATOR_ROOT:-${HOME}/.orchestrator}"
worktree_required=1
keep_alive=0
advisor_mode='none'
executor_tier='default'

while (($# > 0)); do
  case "$1" in
    --state-json)
      shift
      [[ $# -gt 0 ]] || { echo "plan.sh: missing value for --state-json" >&2; exit 1; }
      state_json="$1"
      ;;
    --slug)
      shift
      [[ $# -gt 0 ]] || { echo "plan.sh: missing value for --slug" >&2; exit 1; }
      task_slug="$1"
      ;;
    --description)
      shift
      [[ $# -gt 0 ]] || { echo "plan.sh: missing value for --description" >&2; exit 1; }
      description="$1"
      ;;
    --cwd)
      shift
      [[ $# -gt 0 ]] || { echo "plan.sh: missing value for --cwd" >&2; exit 1; }
      cwd="$1"
      ;;
    --project-name)
      shift
      [[ $# -gt 0 ]] || { echo "plan.sh: missing value for --project-name" >&2; exit 1; }
      project_name="$1"
      ;;
    --agent)
      shift
      [[ $# -gt 0 ]] || { echo "plan.sh: missing value for --agent" >&2; exit 1; }
      agent_family="$1"
      ;;
    --root)
      shift
      [[ $# -gt 0 ]] || { echo "plan.sh: missing value for --root" >&2; exit 1; }
      orchestrator_root="$1"
      ;;
    --no-worktree)
      worktree_required=0
      ;;
    --keep-alive)
      keep_alive=1
      ;;
    --advisor-mode)
      shift
      [[ $# -gt 0 ]] || { echo "plan.sh: missing value for --advisor-mode" >&2; exit 1; }
      advisor_mode="$1"
      ;;
    --executor-tier)
      shift
      [[ $# -gt 0 ]] || { echo "plan.sh: missing value for --executor-tier" >&2; exit 1; }
      executor_tier="$1"
      ;;
    --help|-h)
      usage
      exit 0
      ;;
    *)
      echo "plan.sh: unknown argument: $1" >&2
      exit 1
      ;;
  esac
  shift
done

[[ -n "${state_json}" ]] || { echo "plan.sh: --state-json is required" >&2; exit 1; }
[[ -n "${task_slug}" ]] || { echo "plan.sh: --slug is required" >&2; exit 1; }
[[ -n "${description}" ]] || { echo "plan.sh: --description is required" >&2; exit 1; }
[[ -n "${cwd}" ]] || { echo "plan.sh: --cwd is required" >&2; exit 1; }
[[ -n "${project_name}" ]] || { echo "plan.sh: --project-name is required" >&2; exit 1; }

case "${advisor_mode}" in
  none|plan|review) ;;
  *) echo "plan.sh: --advisor-mode must be none, plan, or review; got '${advisor_mode}'" >&2; exit 1 ;;
esac

case "${executor_tier}" in
  default|capable|fast) ;;
  *) echo "plan.sh: --executor-tier must be default, capable, or fast; got '${executor_tier}'" >&2; exit 1 ;;
esac

project_slug="$(slugify "${project_name}")"

# --- zmx session name length cap ---
# macOS sockaddr_un.sun_path is a 104-byte buffer that must include the
# terminating NUL byte, so the usable socket path is 103 bytes. The zmx
# socket lives at <socket_dir>/<session_name>, meaning session_name max =
# 104 - len(socket_dir) - 1 (slash) - 1 (NUL) - safety margin. Reserving
# only the slash (-1) passes this check but still fails at bind() time
# because the NUL is not accounted for.
# Detect at runtime; fall back to 43 (conservative default for macOS).
_zmx_socket_dir="$(ls -d /var/folders/*/*/T/zmx-"$(id -u)" 2>/dev/null | head -1 || true)"
if [[ -n "${_zmx_socket_dir}" ]]; then
  # Reserve 4 bytes: 1 slash + 1 NUL terminator + 2 safety margin.
  _zmx_max_name=$(( 104 - ${#_zmx_socket_dir} - 4 ))
else
  _zmx_max_name=43
fi

# Build slot name: {family}-{project_slug}-{task_slug}-{index}
# Slot naming policy is documented in ADR-033 (Orchestrator Identifier
# Scheme and Project Alias for Slot-Name Fit). If the slot exceeds the
# zmx limit, Tier 1 truncates task_slug + 4-char hash; Tier 2 (when
# project_slug is so long that Tier 1 cannot satisfy _available ≥ 8)
# falls back to a hash-only slot. Original task_slug is always preserved
# in claude `--name` and state.json `tasks[]`.
slot_prefix="${agent_family}-${project_slug}-${task_slug}-"

slot_index="$(
  jq -r --arg prefix "${slot_prefix}" '
    [
      (.agents // {})
      | keys[]?
      | select(startswith($prefix))
      | (($prefix | length) as $offset | .[$offset:])
      | select(test("^[0-9]+$"))
      | tonumber
    ]
    | if length == 0 then 1 else (max + 1) end
  ' <<<"${state_json}"
)"

# Guard against zmx name collision with stale sessions not in state.
# If the computed slot already exists in zmx, bump until unique.
if command -v zmx &>/dev/null; then
  while zmx list 2>/dev/null | grep -q "name=${slot_prefix}${slot_index}"; do
    (( slot_index++ ))
  done
fi

slot_name="${slot_prefix}${slot_index}"

if (( ${#slot_name} > _zmx_max_name )); then
  # Tier 1 — try truncating task_slug only (preserves project_slug readability).
  # Fixed parts: {family}-{project_slug}-{trunc_slug}-{index}
  # The trailing dash between trunc_slug and index is part of the overhead.
  _fixed_prefix="${agent_family}-${project_slug}-"
  _fixed_suffix="-${slot_index}"  # dash + index
  _overhead=1                      # trailing dash after trunc_slug
  _available=$(( _zmx_max_name - ${#_fixed_prefix} - ${#_fixed_suffix} - _overhead ))

  if (( _available >= 8 )); then
    # Truncate task_slug, append 4-char hash for uniqueness
    _hash="$(printf '%s' "${task_slug}" | shasum | cut -c1-4)"
    _trunc_len=$(( _available - 5 ))  # 4 hash chars + 1 dash
    _trunc_slug="${task_slug:0:${_trunc_len}}-${_hash}"

    # Recompute slot_prefix and index with truncated slug
    slot_prefix="${_fixed_prefix}${_trunc_slug}-"
    slot_index="$(
      jq -r --arg prefix "${slot_prefix}" '
        [
          (.agents // {})
          | keys[]?
          | select(startswith($prefix))
          | (($prefix | length) as $offset | .[$offset:])
          | select(test("^[0-9]+$"))
          | tonumber
        ]
        | if length == 0 then 1 else (max + 1) end
      ' <<<"${state_json}"
    )"
    slot_name="${slot_prefix}${slot_index}"
  else
    # Tier 2 (ADR-033) — project_slug is too long for Tier 1 to fit any task_slug.
    # Fall back to a hash-only slot. Readable identification lives in
    # `claude --name <task_slug>` and state.json `tasks[task_slug]` — slot_name
    # is just the zmx session identifier here.
    # Format: {family}-{hash6}-{index}   (always ≤ 17 chars)
    _hash6="$(printf '%s' "${agent_family}-${project_slug}-${task_slug}" | shasum | cut -c1-6)"
    slot_prefix="${agent_family}-${_hash6}-"
    slot_index="$(
      jq -r --arg prefix "${slot_prefix}" '
        [
          (.agents // {})
          | keys[]?
          | select(startswith($prefix))
          | (($prefix | length) as $offset | .[$offset:])
          | select(test("^[0-9]+$"))
          | tonumber
        ]
        | if length == 0 then 1 else (max + 1) end
      ' <<<"${state_json}"
    )"
    slot_name="${slot_prefix}${slot_index}"
  fi
fi
work_item_path="${orchestrator_root}/tasks/${task_slug}.md"
done_report_path="${orchestrator_root}/done/${task_slug}.md"
state_path="${orchestrator_root}/state.json"
activity_path="${orchestrator_root}/activity.jsonl"
locks_dir="${orchestrator_root}/locks"

# Worktree planning. Per ADR-032, the agent's working directory is ALWAYS
# the main repo path — never the worktree path — so that the claude
# session JSONL stays keyed to a stable cwd that survives any worktree
# lifecycle event. The worker is told to `cd <worktree>` as its first
# action via the work-item brief, but cwd-encoded session storage is
# anchored to the main repo regardless.
if (( worktree_required == 1 )); then
  worktree_path="${cwd}/.worktrees/dispatch-${task_slug}-${agent_family}-${slot_index}"
  worktree_branch="dispatch/${task_slug}-${agent_family}-${slot_index}"
  worktree_reason="default — concurrent dispatches must not collide on git state, mirroring the /collab same-task pattern"
else
  worktree_path=""
  worktree_branch=""
  worktree_reason="--no-worktree escape: caller asserts the task is read-only or doc-only and will not mutate git state"
fi
# ADR-032: agent_cwd is the main repo path in BOTH cases. Worktree is
# delivered to the worker via the brief; never as the spawn cwd.
agent_cwd="${cwd}"

# Worker agents run non-interactively; skip permission prompts.
# --name tags the session with the task slug for later resume.
# Codex 0.129.0 removed --full-auto; equivalent for non-interactive workers
# is `-s workspace-write -a never` (sandboxed write, never prompt).
if [[ "${agent_family}" == "claude" ]]; then
  attach_command="cd ${agent_cwd} && zmx attach ${slot_name} claude --dangerously-skip-permissions --name ${task_slug}"
elif [[ "${agent_family}" == "codex" ]]; then
  attach_command="cd ${agent_cwd} && zmx attach ${slot_name} codex -s workspace-write -a never"
else
  attach_command="cd ${agent_cwd} && zmx attach ${slot_name} ${agent_family}"
fi
takeover_command="Read ${work_item_path} and follow the instructions in it."

task_exists="$(
  jq -r --arg slug "${task_slug}" '
    ((.tasks // {})[$slug] // null) != null
  ' <<<"${state_json}"
)"

active_task_exists="$(
  jq -r --arg slug "${task_slug}" '
    ((.tasks // {})[$slug] // {status: "missing"}).status as $status
    | ($status != "missing" and $status != "done")
  ' <<<"${state_json}"
)"

jq -n \
  --arg project_name "${project_name}" \
  --arg project_slug "${project_slug}" \
  --arg cwd "${cwd}" \
  --arg task_slug "${task_slug}" \
  --arg description "${description}" \
  --arg agent_family "${agent_family}" \
  --arg advisor_mode "${advisor_mode}" \
  --arg executor_tier "${executor_tier}" \
  --arg slot_name "${slot_name}" \
  --arg agent_cwd "${agent_cwd}" \
  --arg work_item_path "${work_item_path}" \
  --arg done_report_path "${done_report_path}" \
  --arg state_path "${state_path}" \
  --arg activity_path "${activity_path}" \
  --arg locks_dir "${locks_dir}" \
  --arg attach_command "${attach_command}" \
  --arg takeover_command "${takeover_command}" \
  --arg worktree_path "${worktree_path}" \
  --arg worktree_branch "${worktree_branch}" \
  --arg worktree_reason "${worktree_reason}" \
  --argjson slot_index "${slot_index}" \
  --argjson task_exists "${task_exists}" \
  --argjson active_task_exists "${active_task_exists}" \
  --argjson keep_alive "${keep_alive}" \
  --argjson worktree_required "${worktree_required}" \
  '{
    action: "dispatch",
    project: {
      name: $project_name,
      slug: $project_slug,
      path: $cwd
    },
    request: {
      advisor_mode: $advisor_mode,
      executor_tier: $executor_tier,
      keep_alive: ($keep_alive == 1)
    },
    task: {
      slug: $task_slug,
      description: $description,
      work_item_path: $work_item_path,
      done_report_path: $done_report_path,
      metadata: {
        advisor_mode: $advisor_mode,
        executor_tier: $executor_tier
      }
    },
    agents: [
      {
        family: $agent_family,
        slot: $slot_name,
        index: $slot_index,
        cwd: $agent_cwd,
        status: "planned",
        attach_command: $attach_command,
        executor_tier: $executor_tier
      }
    ],
    worktree: (
      if $worktree_required == 1 then
        {
          required: true,
          path: $worktree_path,
          branch: $worktree_branch,
          base_ref: "HEAD",
          reason: $worktree_reason
        }
      else
        {
          required: false,
          reason: $worktree_reason
        }
      end
    ),
    paths: {
      state: $state_path,
      activity: $activity_path,
      locks_dir: $locks_dir
    },
    effects: {
      worktree: (
        if $worktree_required == 1 then
          {
            script: "scripts/orchestrator/effects/create-worktree.sh",
            command_preview: ("git worktree add -b " + $worktree_branch + " " + $worktree_path + " HEAD"),
            cleanup_script: "scripts/orchestrator/effects/cleanup-worktree.sh",
            cleanup_command_preview: ("git worktree remove " + $worktree_path)
          }
        else
          {
            script: null,
            note: "no worktree provisioning (--no-worktree)"
          }
        end
      ),
      spawn: {
        script: "scripts/orchestrator/effects/spawn-surface.sh",
        convention: "cmux new-split in the current workspace",
        command_preview: $attach_command
      },
      inject: {
        script: "scripts/orchestrator/effects/inject-takeover.sh",
        command_preview: $takeover_command
      },
      cleanup: {
        script: "scripts/orchestrator/effects/kill-surface.sh"
      }
    },
    planner: {
      mode: "local-shell",
      opus_stub: "TODO(Stage 1): use per-call Opus only for hard decomposition/conflict-resolution requests, never as a daemon"
    },
    conflicts: {
      task_exists: $task_exists,
      active_task_exists: $active_task_exists
    }
  }'
