#!/usr/bin/env bash

set -euo pipefail
IFS=$'\n\t'

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
ORCHESTRATOR_ROOT="${ORCHESTRATOR_ROOT:-${HOME}/.orchestrator}"

# Caller token: effect scripts check this to refuse direct invocation.
# Only conductor.sh (and orchestrator start/stop scripts) should set this.
export ORCHESTRATOR_CALLER_TOKEN="conductor:$$"

STATE_READ="${SCRIPT_DIR}/orchestrator/core/state-read.sh"
PLAN_SCRIPT="${SCRIPT_DIR}/orchestrator/core/plan.sh"
STATE_TRANSITION="${SCRIPT_DIR}/orchestrator/core/state-transition.sh"
SPAWN_EFFECT="${SCRIPT_DIR}/orchestrator/effects/spawn-surface.sh"
INJECT_EFFECT="${SCRIPT_DIR}/orchestrator/effects/inject-takeover.sh"
KILL_EFFECT="${SCRIPT_DIR}/orchestrator/effects/kill-surface.sh"
CREATE_WORKTREE_EFFECT="${SCRIPT_DIR}/orchestrator/effects/create-worktree.sh"
CLEANUP_WORKTREE_EFFECT="${SCRIPT_DIR}/orchestrator/effects/cleanup-worktree.sh"

usage() {
  cat <<'EOF'
Usage:
  scripts/conductor.sh dispatch <slug> "<description>" [--dry-run|--execute] [--agent claude|codex] [--no-worktree] [--keep-alive] [--resume] [--advisor-mode none|plan|review] [--executor-tier default|capable|fast]
  scripts/conductor.sh collab <slug> "<description>" [--dry-run|--execute] [--advisor-mode none|plan|review] [--executor-tier default|capable|fast] [--no-worktree]
  scripts/conductor.sh collab --request <request-file> [--dry-run|--execute]
  scripts/conductor.sh list
  scripts/conductor.sh status [<slug>]
  scripts/conductor.sh done <slug> [--dry-run|--execute] [--cleanup]
  scripts/conductor.sh cleanup <slug> [--dry-run|--execute] [--force]
  scripts/conductor.sh resume <slug> [--dry-run|--execute] [--agent claude|codex] [--keep-alive]
  scripts/conductor.sh gc [--dry-run|--execute] [--force] [--max-age N]
  scripts/conductor.sh tidy [--dry-run|--execute] [--all|<slug>...]
  scripts/conductor.sh help

Notes:
  - `dispatch`, `done`, `collab`, `resume`, `cleanup`, and `tidy` default to --dry-run.
  - `--execute` is required to mutate state.
  - `--keep-alive` prevents worker self-done (caller manages lifecycle).
  - `collab` = paired dispatch (claude + codex) with --keep-alive, slug max 25 chars.
  - `done` = state transition only (in_progress → done). Resources preserved.
  - `cleanup` = remove surface, zmx session, worktree, branch, agent from state.
  - `done --cleanup` = both in one call (backwards compat for standalone dispatch).
  - `tidy` = remove worktrees/branches for finished tasks (zmx gone). Resource-
     based, does not touch state.json. Safe to run anytime; skips live workers.
EOF
}

die() {
  printf 'conductor.sh: %s\n' "$*" >&2
  exit 1
}

timestamp_utc() {
  date -u +"%Y-%m-%dT%H:%M:%SZ"
}

validate_slug() {
  local slug="$1"
  [[ "${slug}" =~ ^[a-z0-9]+(-[a-z0-9]+)*$ ]] || die "slug must be lowercase kebab-case"
  [[ ${#slug} -le 32 ]] || die "slug must be 32 characters or fewer"
  # Reserved-slug denylist (Stage 0.1: ported from Worker A cross-review).
  # 'base' would collide with the canonical rotate slot; 'main'/'master'
  # collide with git default branch names and create cognitive conflicts.
  case "${slug}" in
    base|main|master|head|origin) die "slug '${slug}' is reserved" ;;
  esac
}

derive_agent_family() {
  case "${ZMX_SESSION:-}" in
    claude-*) printf 'claude\n' ;;
    codex-*) printf 'codex\n' ;;
    *) printf 'claude\n' ;;
  esac
}

# Per ADR-033: resolve a cwd to its short project alias if registered in
# ~/.orchestrator/project-aliases.json, else fall back to basename(cwd).
# Aliases solve the slot-name fit problem for projects whose basename is
# 27+ chars (clickhouse-upgrade-framework etc) by letting the user choose
# a readable short name (clickhouse → ch, framework → fw, etc).
# Output is what gets passed as --project-name to plan.sh.
_resolve_project_alias() {
  local cwd="$1"
  local aliases_file="${ORCHESTRATOR_ROOT}/project-aliases.json"
  if [[ -f "${aliases_file}" ]]; then
    local alias
    alias="$(jq -r --arg p "${cwd}" '.[$p] // empty' "${aliases_file}" 2>/dev/null || true)"
    if [[ -n "${alias}" ]]; then
      printf '%s\n' "${alias}"
      return 0
    fi
  fi
  basename "${cwd}"
}

# Wait until a spawned agent is ready to accept input.
# Uses cmux read-screen to detect prompt indicators instead of fixed sleep.
# Usage: await_agent_ready <surface_id> <agent_family> [max_seconds] [workspace_id]
# Returns 0 when the agent's input prompt is ready to accept a line, or
# on timeout (timeout doesn't fail — just proceeds; effect script may
# retry on its own). Default timeout 60s because Claude first-boot can
# take 20-40s with hooks + settings parsing.
await_agent_ready() {
  local surface_id="$1"
  local family="${2:-claude}"
  local max_wait="${3:-60}"
  local workspace="${4:-}"
  local waited=0
  local ws_args=()
  [[ -n "${workspace}" ]] && ws_args=(--workspace "${workspace}")

  if ! command -v cmux &>/dev/null; then
    sleep 3
    return 0
  fi

  # Ready patterns:
  #   Claude: U+276F (❯) prompt, "bypass permissions on" footer line,
  #           ╭ box-drawing at input box start
  #   Codex:  › (U+203A) prompt, or Codex banner + blinking cursor
  # Both families can also be ready when screen shows no "loading"/"booting"
  # text and a prompt glyph is present.
  while (( waited < max_wait )); do
    local screen
    screen="$(cmux read-screen --surface "${surface_id}" "${ws_args[@]}" --lines 20 2>/dev/null || true)"
    if [[ -n "${screen}" ]]; then
      case "${family}" in
        claude)
          if printf '%s' "${screen}" | grep -qE '❯|bypass permissions|^> |╭|waiting for|What would you'; then
            return 0
          fi
          ;;
        codex)
          if printf '%s' "${screen}" | grep -qE '›|sandbox|gpt-|Codex'; then
            return 0
          fi
          ;;
      esac
    fi
    sleep 0.5
    (( waited++ )) || true
  done
  return 0
}

cmux_surface_snapshot() {
  if ! command -v cmux &>/dev/null; then
    return 0
  fi
  cmux tree --all 2>/dev/null || true
}

cmux_surface_exists() {
  local snapshot="${1:-}"
  local surface_id="${2:-}"
  [[ -n "${surface_id}" ]] || return 1
  grep -Fq "${surface_id}" <<<"${snapshot}"
}

cmux_workspace_for_surface() {
  local snapshot="${1:-}"
  local surface_id="${2:-}"
  [[ -n "${snapshot}" && -n "${surface_id}" ]] || return 1
  awk -v target_sf="${surface_id}" '
    /workspace:[0-9]+/ {
      match($0, /workspace:[0-9]+/)
      ws = substr($0, RSTART, RLENGTH)
    }
    index($0, target_sf) {
      if (ws != "") {
        print ws
        exit
      }
    }
  ' <<<"${snapshot}"
}

canonical_workspace_ref() {
  local workspace_id="${1:-}"
  local snapshot="${2:-}"
  local surface_id="${3:-}"

  if [[ "${workspace_id}" =~ ^workspace:[0-9]+$ ]]; then
    printf '%s\n' "${workspace_id}"
    return 0
  fi

  if [[ -n "${surface_id}" ]]; then
    local derived=''
    derived="$(cmux_workspace_for_surface "${snapshot}" "${surface_id}" 2>/dev/null || true)"
    if [[ "${derived}" =~ ^workspace:[0-9]+$ ]]; then
      printf '%s\n' "${derived}"
      return 0
    fi
  fi

  return 1
}

atomic_write() {
  local target="$1"
  local content="$2"
  local parent tmp

  parent="$(dirname -- "${target}")"
  mkdir -p "${parent}"
  tmp="$(mktemp "${target}.tmp.XXXXXX")"
  printf '%s\n' "${content}" > "${tmp}"
  mv "${tmp}" "${target}"
}

append_activity() {
  local entry="$1"
  mkdir -p "${ORCHESTRATOR_ROOT}"
  printf '%s\n' "${entry}" >> "${ORCHESTRATOR_ROOT}/activity.jsonl"
}

git_worktree_snapshot() {
  local repo_cwd="${1:-${PWD}}"
  git -C "${repo_cwd}" worktree list --porcelain 2>/dev/null || true
}

canonicalize_path() {
  local target_path="${1:-}"
  [[ -n "${target_path}" ]] || return 1

  if [[ -d "${target_path}" ]]; then
    (
      cd "${target_path}" 2>/dev/null && pwd -P
    ) || printf '%s\n' "${target_path}"
    return 0
  fi

  local parent base
  parent="$(dirname -- "${target_path}")"
  base="$(basename -- "${target_path}")"
  if [[ -d "${parent}" ]]; then
    printf '%s/%s\n' "$(
      cd "${parent}" 2>/dev/null && pwd -P
    )" "${base}"
  else
    printf '%s\n' "${target_path}"
  fi
}

git_worktree_path_registered() {
  local snapshot="${1:-}"
  local target_path="${2:-}"
  [[ -n "${snapshot}" && -n "${target_path}" ]] || return 1
  local target_real
  target_real="$(canonicalize_path "${target_path}")"
  local line registered_path
  while IFS= read -r line; do
    [[ "${line}" == worktree\ * ]] || continue
    registered_path="${line#worktree }"
    if [[ "$(canonicalize_path "${registered_path}")" == "${target_real}" ]]; then
      return 0
    fi
  done <<<"${snapshot}"
  return 1
}

git_worktree_branch_registered() {
  local snapshot="${1:-}"
  local target_branch="${2:-}"
  [[ -n "${snapshot}" && -n "${target_branch}" ]] || return 1
  awk -v target="refs/heads/${target_branch}" '
    /^branch / && $2 == target { found=1 }
    END { exit(found ? 0 : 1) }
  ' <<<"${snapshot}"
}

zmx_snapshot() {
  if ! command -v zmx >/dev/null 2>&1; then
    return 0
  fi
  zmx list 2>/dev/null || true
}

zmx_snapshot_has_start_dir() {
  local snapshot="${1:-}"
  local target_path="${2:-}"
  [[ -n "${snapshot}" && -n "${target_path}" ]] || return 1
  local target_real
  target_real="$(canonicalize_path "${target_path}")"
  local line field start_dir
  local fields=()
  while IFS= read -r line; do
    IFS=' ' read -r -a fields <<<"${line}"
    for field in "${fields[@]}"; do
      [[ "${field}" == start_dir=* ]] || continue
      start_dir="${field#start_dir=}"
      if [[ "$(canonicalize_path "${start_dir}")" == "${target_real}" ]]; then
        return 0
      fi
    done
  done <<<"${snapshot}"
  return 1
}

# Parse a request file (frontmatter + payload) into shell variables.
# Usage: eval "$(parse_request_file /path/to/req.md)"
# Sets: REQ_ID, REQ_TYPE, REQ_SLUG, REQ_PROJECT, REQ_WORKSPACE_ID, REQ_PAYLOAD_*
parse_request_file() {
  local req_file="$1"
  [[ -f "${req_file}" ]] || { echo "echo 'request file not found: ${req_file}' >&2; return 1"; return; }

  awk '
    BEGIN { in_fm=0; in_payload=0 }
    /^---$/ {
      if (!in_fm) { in_fm=1; next }
      else { in_fm=0; next }
    }
    in_fm && /^  project:/ { sub(/^  project: */, ""); gsub(/'\''/, "'\''\\'\'''\''"); printf "REQ_PROJECT='\''%s'\''\n", $0 }
    in_fm && /^  cmux_workspace_id:/ { sub(/^  cmux_workspace_id: */, ""); gsub(/'\''/, "'\''\\'\'''\''"); printf "REQ_WORKSPACE_ID='\''%s'\''\n", $0 }
    in_fm && /^id:/ { sub(/^id: */, ""); printf "REQ_ID='\''%s'\''\n", $0 }
    in_fm && /^type:/ { sub(/^type: */, ""); printf "REQ_TYPE='\''%s'\''\n", $0 }
    in_fm && /^slug:/ { sub(/^slug: */, ""); printf "REQ_SLUG='\''%s'\''\n", $0 }
    /^## Payload/ { in_payload=1; next }
    in_payload && /^- slug:/ { sub(/^- slug: */, ""); gsub(/'\''/, "'\''\\'\'''\''"); printf "REQ_PAYLOAD_SLUG='\''%s'\''\n", $0 }
    in_payload && /^- description:/ { sub(/^- description: */, ""); gsub(/'\''/, "'\''\\'\'''\''"); printf "REQ_PAYLOAD_DESCRIPTION='\''%s'\''\n", $0 }
    in_payload && /^- worker_family:/ { sub(/^- worker_family: */, ""); printf "REQ_PAYLOAD_WORKER_FAMILY='\''%s'\''\n", $0 }
    in_payload && /^- advisor_mode:/ { sub(/^- advisor_mode: */, ""); printf "REQ_PAYLOAD_ADVISOR_MODE='\''%s'\''\n", $0 }
    in_payload && /^- executor_tier:/ { sub(/^- executor_tier: */, ""); printf "REQ_PAYLOAD_EXECUTOR_TIER='\''%s'\''\n", $0 }
    in_payload && /^- dry_run:/ { sub(/^- dry_run: */, ""); printf "REQ_PAYLOAD_DRY_RUN='\''%s'\''\n", $0 }
    in_payload && /^- no_worktree:/ { sub(/^- no_worktree: */, ""); printf "REQ_PAYLOAD_NO_WORKTREE='\''%s'\''\n", $0 }
    in_payload && /^- keep_alive:/ { sub(/^- keep_alive: */, ""); printf "REQ_PAYLOAD_KEEP_ALIVE='\''%s'\''\n", $0 }
    in_payload && /^- resume:/ { sub(/^- resume: */, ""); printf "REQ_PAYLOAD_RESUME='\''%s'\''\n", $0 }
  ' "${req_file}"
}

truncate_for_prompt() {
  local value="$1"
  local limit="${2:-30000}"

  if (( ${#value} > limit )); then
    printf '%s\n\n[truncated to %s characters]' "${value:0:limit}" "${limit}"
  else
    printf '%s' "${value}"
  fi
}

collect_advisor_git_context() {
  local review_cwd="$1"

  if [[ ! -d "${review_cwd}" ]]; then
    jq -n --arg cwd "${review_cwd}" '{cwd: $cwd, available: false, reason: "cwd-not-found"}'
    return 0
  fi

  if ! git -C "${review_cwd}" rev-parse --is-inside-work-tree >/dev/null 2>&1; then
    jq -n --arg cwd "${review_cwd}" '{cwd: $cwd, available: false, reason: "not-a-git-worktree"}'
    return 0
  fi

  local status diff_stat unstaged staged combined_diff truncated_diff
  status="$(git -C "${review_cwd}" status --short 2>&1 || true)"
  diff_stat="$(git -C "${review_cwd}" diff --stat 2>&1 || true)"
  unstaged="$(git -C "${review_cwd}" diff --no-ext-diff 2>&1 || true)"
  staged="$(git -C "${review_cwd}" diff --cached --no-ext-diff 2>&1 || true)"
  combined_diff="$(
    printf '## Unstaged diff\n%s\n\n## Staged diff\n%s\n' \
      "${unstaged:-<empty>}" \
      "${staged:-<empty>}"
  )"
  truncated_diff="$(truncate_for_prompt "${combined_diff}" 30000)"

  jq -n \
    --arg cwd "${review_cwd}" \
    --arg status "${status}" \
    --arg diff_stat "${diff_stat}" \
    --arg diff "${truncated_diff}" \
    '{cwd: $cwd, available: true, status: $status, diff_stat: $diff_stat, diff: $diff}'
}

normalize_advisor_response() {
  local raw="$1"

  jq -c '
    def parsed:
      if type == "string" then (fromjson? // empty) else . end;

    (
      if type == "object" and has("verdict") then
        .
      elif type == "object" and (.result? != null) then
        (.result | parsed)
      elif type == "object" and (.content? != null) then
        (.content | parsed)
      else
        empty
      end
    )
    | select(.verdict == "approve" or .verdict == "revise")
    | {
        verdict,
        notes: (.notes // ""),
        score: (.score // null)
      }
  ' <<<"${raw}" 2>/dev/null
}

_run_advisor() {
  local advisor_mode="$1"
  local slug="$2"
  local description="$3"
  local task_path="$4"
  local done_report_path="$5"
  local state="$6"

  case "${advisor_mode}" in
    none|plan) return 0 ;;
    review) ;;
    *)
      append_activity "$(
        jq -cn \
          --arg timestamp "$(timestamp_utc)" \
          --arg slug "${slug}" \
          --arg advisor_mode "${advisor_mode}" \
          '{timestamp:$timestamp, event:"advisor-review-skipped", slug:$slug, advisor_mode:$advisor_mode, reason:"unsupported-advisor-mode"}'
      )"
      return 0
      ;;
  esac

  if ! command -v claude >/dev/null 2>&1; then
    append_activity "$(
      jq -cn \
        --arg timestamp "$(timestamp_utc)" \
        --arg slug "${slug}" \
        '{timestamp:$timestamp, event:"advisor-review-skipped", slug:$slug, reason:"claude-not-found"}'
    )"
    return 0
  fi

  local review_cwd
  review_cwd="$(jq -r --arg slug "${slug}" '.tasks[$slug].worktree_path // .tasks[$slug].project_path // empty' <<<"${state}")"
  [[ -n "${review_cwd}" ]] || review_cwd="${PWD}"

  local git_context prompt_context prompt raw parsed verdict notes score_json
  git_context="$(collect_advisor_git_context "${review_cwd}")"
  prompt_context="$(
    jq -n \
      --arg slug "${slug}" \
      --arg description "${description}" \
      --arg task_path "${task_path}" \
      --arg done_report_path "${done_report_path}" \
      --argjson git_context "${git_context}" \
      '{
        task: {
          slug: $slug,
          description: $description,
          work_item_path: $task_path,
          done_report_path: $done_report_path
        },
        git: $git_context
      }'
  )"
  prompt="$(cat <<EOF
You are the short-lived advisor reviewer for an orchestrated worker task.

Review the worker output for correctness, completeness, and local style.
Return only JSON matching this schema:
{"verdict":"approve"|"revise","notes":"short actionable note","score":0.0}

Approve only if the task appears complete and reviewable. Use revise when
there is a concrete blocker that should prevent marking the task done.

Context:
${prompt_context}
EOF
)"

  if ! raw="$(claude --model sonnet -p "${prompt}" --output-format json 2>&1)"; then
    append_activity "$(
      jq -cn \
        --arg timestamp "$(timestamp_utc)" \
        --arg slug "${slug}" \
        --arg error "$(truncate_for_prompt "${raw}" 4000)" \
        '{timestamp:$timestamp, event:"advisor-review-failed", slug:$slug, reason:"claude-call-failed", error:$error}'
    )"
    return 0
  fi

  if ! parsed="$(normalize_advisor_response "${raw}")" || [[ -z "${parsed}" ]]; then
    append_activity "$(
      jq -cn \
        --arg timestamp "$(timestamp_utc)" \
        --arg slug "${slug}" \
        --arg raw "$(truncate_for_prompt "${raw}" 4000)" \
        '{timestamp:$timestamp, event:"advisor-review-failed", slug:$slug, reason:"parse-failed", raw:$raw}'
    )"
    return 0
  fi

  verdict="$(jq -r '.verdict' <<<"${parsed}")"
  notes="$(jq -r '.notes' <<<"${parsed}")"
  score_json="$(jq -c '.score // null' <<<"${parsed}")"
  append_activity "$(
    jq -cn \
      --arg timestamp "$(timestamp_utc)" \
      --arg slug "${slug}" \
      --arg verdict "${verdict}" \
      --arg notes "${notes}" \
      --argjson score "${score_json}" \
      '{timestamp:$timestamp, event:"advisor-review", slug:$slug, verdict:$verdict, notes:$notes, score:$score}'
  )"

  if [[ "${verdict}" == "revise" ]]; then
    printf 'conductor.sh: advisor requested revision for %s: %s\n' "${slug}" "${notes}" >&2
    return 20
  fi

  return 0
}

render_work_item_markdown() {
  local slug="$1"
  local description="$2"
  local agent_family="${3:-claude}"
  local advisor_mode="${4:-none}"
  local executor_tier="${5:-default}"
  local keep_alive="${6:-false}"
  local is_collab_pair="${7:-false}"
  local worktree_path="${8:-}"
  local worktree_branch="${9:-}"
  local completion_prefix='/'

  if [[ "${agent_family}" == "codex" ]]; then
    completion_prefix='$'
  fi

  local completion_instruction
  if [[ "${keep_alive}" == "true" ]]; then
    completion_instruction="- **Do NOT mark this task done.** The caller session manages this worker's lifecycle — commit your work and wait."
  else
    completion_instruction='- When done, commit your work (if any) and run this as your final Bash tool call to terminate the worker session:
  \`kill -TERM $PPID\`
  (This kills the claude process that spawned the Bash subprocess. The `/exit` slash command cannot be invoked by the agent and will NOT terminate the session — it must be a real `kill` signal.)
  The orchestrator daemon will detect the dead session within ~30s and clean up the worktree, branch, and state entry automatically.'
  fi

  local workspace_section=""
  if [[ -n "${worktree_path}" ]]; then
    workspace_section="
## Workspace (ADR-032)

- **Worktree path**: ${worktree_path}
- **Branch**: ${worktree_branch}
- **Spawn cwd**: ${PWD} (main repo — claude session JSONL is anchored here so the session survives any worktree lifecycle event)

**FIRST ACTION**: \`cd ${worktree_path}\` before doing any work.

- Do all git operations and file edits inside the worktree.
- Do NOT run \`git\` mutations in the main repo cwd (\`${PWD}\`). If you accidentally start there, just \`cd\` to the worktree.
- If you must reference files outside the worktree, use absolute paths.
"
  fi

  cat <<EOF
# Work Item: ${slug}

- **Status**: in-progress
- **Created**: $(timestamp_utc)
- **Project Root**: ${PWD}
${workspace_section}
## Goal

${description}

## Request Metadata

- agent_family: ${agent_family}
- advisor_mode: ${advisor_mode}
- executor_tier: ${executor_tier}
- keep_alive: ${keep_alive}

## Constraints

- Keep the base session untouched; this task runs in a sibling slot only.
- Treat this file as a scoped delegation brief, not a full handoff entry.
${completion_instruction}

## Definition of Done

- Implement or investigate the delegated work described above.
- Leave the repo in a reviewable state with a concise summary of outcomes.
$(if [[ "${keep_alive}" == "true" ]]; then
  echo "- Commit all changes to the worktree branch. Do NOT merge to main."
  echo "- Stay alive after committing — the caller will drive next steps."
else
  echo "- Mark the task done through the conductor when the sibling session finishes."
fi)

## Key Files

- ${PWD}
- ${SCRIPT_DIR}/conductor.sh

## Notes

- Stage 0 does not automate merge or dependency management yet.
$(if [[ "${is_collab_pair}" == "true" ]]; then
  echo "- This is a COLLAB task. Another worker is doing the same task independently."
  echo "- Your output will be cross-reviewed against the other worker's output."
fi)
EOF
}

render_done_report_markdown() {
  local slug="$1"
  local description="$2"
  local task_path="$3"

  cat <<EOF
# Done Report: ${slug}

- **Completed**: $(timestamp_utc)
- **Task File**: ${task_path}
- **Project Root**: ${PWD}

## Summary

Task marked done via \`scripts/conductor.sh done ${slug}\`.

## Original Goal

${description}

## Stage 0 Follow-up

- Merge remains manual.
- Surface cleanup runs automatically unless \`--keep-surface\` was passed.
- Reconciliation is not implemented until Stage 1.
EOF
}

STATE_LOCK="${ORCHESTRATOR_ROOT}/locks/state.lock"
STATE_LOCK_DIR="${ORCHESTRATOR_ROOT}/locks/state.lockdir"
STATE_LOCK_FD=9

_acquire_state_lock() {
  mkdir -p "$(dirname "${STATE_LOCK}")"
  if command -v flock &>/dev/null; then
    exec 9>"${STATE_LOCK}"
    flock -w 10 9
  else
    # mkdir-based mutex fallback for macOS without flock.
    # mkdir is atomic on POSIX — only one process succeeds.
    local _wait=0
    while ! mkdir "${STATE_LOCK_DIR}" 2>/dev/null; do
      sleep 0.2
      (( _wait++ )) || true
      if (( _wait > 50 )); then
        # Timed out waiting. Only force-remove if the previous holder is
        # actually gone — never steal a live holder's lock (H2 fix).
        local _holder_pid
        _holder_pid="$(cat "${STATE_LOCK_DIR}/pid" 2>/dev/null | tr -d '[:space:]')"
        if [[ "${_holder_pid}" =~ ^[0-9]+$ ]] && kill -0 "${_holder_pid}" 2>/dev/null; then
          die "state lock held by live pid=${_holder_pid}; refusing to steal"
        fi
        rm -rf "${STATE_LOCK_DIR}"
        mkdir "${STATE_LOCK_DIR}" 2>/dev/null || die "cannot acquire state lock after stale cleanup"
        break
      fi
    done
    # Write PID for stale detection
    printf '%s' "$$" > "${STATE_LOCK_DIR}/pid" 2>/dev/null || true
  fi
}

_release_state_lock() {
  if command -v flock &>/dev/null; then
    exec 9>&- 2>/dev/null || true
  else
    rm -rf "${STATE_LOCK_DIR}" 2>/dev/null || true
  fi
}

state_json() {
  local current_state
  current_state="$("${STATE_READ}" --root "${ORCHESTRATOR_ROOT}")" \
    || die "failed to read orchestrator state from ${ORCHESTRATOR_ROOT}/state.json"
  [[ -n "${current_state//[[:space:]]/}" ]] \
    || die "state reader returned empty output for ${ORCHESTRATOR_ROOT}/state.json"
  printf '%s\n' "${current_state}"
}

write_state_json() {
  local new_state="$1"
  [[ -n "${new_state//[[:space:]]/}" ]] \
    || die "refusing to write blank orchestrator state"
  jq -e 'type == "object"' <<<"${new_state}" >/dev/null \
    || die "refusing to write invalid orchestrator state"
  atomic_write "${ORCHESTRATOR_ROOT}/state.json" "${new_state}"
}

# Run a read-modify-write transaction on state.json under a single lock.
# Usage: state_transaction <callback_fn>
# The callback receives the current state on stdin and must print new state on stdout.
state_transaction() {
  local callback="$1"
  _acquire_state_lock
  # Guarantee lock release even if any intermediate step fails (C2 fix).
  # Subshell + EXIT trap works for the mkdir-based mutex (rmdir is fs-level,
  # scope-independent). For flock-based systems the subshell's `exec 9>&-`
  # only closes its own fd copy, not the parent's — acceptable because on
  # bash-on-macOS (this project's target) flock is absent and the mkdir
  # path runs. If ported to Linux, switch _release_state_lock to also
  # rm the lockfile or restructure to avoid the subshell.
  (
    trap '_release_state_lock' EXIT
    local current new_state
    current="$(state_json)"
    new_state="$("${callback}" <<<"${current}")"
    write_state_json "${new_state}"
    printf '%s' "${new_state}"
  )
}

task_exists_in_state() {
  local slug="$1"
  local state="$2"
  jq -e --arg slug "${slug}" '.tasks[$slug] != null' <<<"${state}" >/dev/null
}

rollback_dispatch_artifacts() {
  local slug="${1:?}"
  local slot="${2:-}"
  local work_item_path="${3:-}"
  local worktree_required="${4:-false}"
  local project_path="${5:-}"
  local worktree_path="${6:-}"
  local worktree_branch="${7:-}"
  local surface_id="${8:-}"
  local workspace_id="${9:-}"

  rm -f "${work_item_path}" 2>/dev/null || true

  if [[ -n "${surface_id}" ]] && command -v cmux >/dev/null 2>&1; then
    local _snapshot _ws
    _snapshot="$(cmux_surface_snapshot)"
    _ws="$(canonical_workspace_ref "${workspace_id}" "${_snapshot}" "${surface_id}" 2>/dev/null || true)"
    if [[ -n "${_ws}" ]]; then
      cmux close-surface --surface "${surface_id}" --workspace "${_ws}" >/dev/null 2>&1 || true
    else
      cmux close-surface --surface "${surface_id}" >/dev/null 2>&1 || true
    fi
  fi

  if [[ -n "${slot}" ]] && command -v zmx >/dev/null 2>&1; then
    zmx kill "${slot}" >/dev/null 2>&1 || true
    pkill -9 -f "zmx attach ${slot}" 2>/dev/null || true
  fi

  if [[ "${worktree_required}" == "true" && -n "${worktree_path}" && -d "${worktree_path}" ]]; then
    local cleanup_args=(--execute "${project_path}" "${worktree_path}")
    [[ -n "${worktree_branch}" ]] && cleanup_args+=(--branch "${worktree_branch}" --delete-branch)
    "${CLEANUP_WORKTREE_EFFECT}" "${cleanup_args[@]}" >/dev/null 2>&1 || true
  fi

  _acquire_state_lock
  local rollback_state
  rollback_state="$(jq \
    --arg slug "${slug}" \
    --arg slot "${slot}" \
    --arg now "$(timestamp_utc)" \
    '
    .updated_at = $now
    | if $slot != "" then del(.agents[$slot]) else . end
    | del(.tasks[$slug])
    | .projects |= with_entries(
        .value.tasks = ((.value.tasks // []) | map(select(. != $slug)))
      )
    ' <<<"$(state_json)")"
  write_state_json "${rollback_state}"
  _release_state_lock
}

dispatch_command() {
  local slug="${1:-}"
  local description="${2:-}"
  local execute=0
  local no_worktree=0
  local keep_alive="false"
  local is_collab_pair="false"
  local do_resume="false"
  local agent_override=""
  local advisor_mode="none"
  local executor_tier="default"
  local state plan slot work_item_path done_report_path plan_output spawn_preview inject_preview worktree_preview
  local now planned_state spawn_output inject_output surface_id running_state activity_entry agent_family
  local agent_cwd worktree_required worktree_path worktree_branch worktree_output
  local project_path=""
  local target_workspace_id=""
  local request_file=""
  local dispatch_phase="plan"
  local dispatch_rc=0
  local spawn_workspace_id=""

  # Support --request as first arg: conductor.sh dispatch --request <file> [--execute|--dry-run]
  if [[ "${slug}" == "--request" ]]; then
    request_file="${description}"
    [[ -n "${request_file}" && -f "${request_file}" ]] || die "--request requires a valid file path"
    shift 2 || true

    # Parse all fields from the request file — no LLM judgment needed
    local REQ_ID="" REQ_TYPE="" REQ_SLUG="" REQ_PROJECT="" REQ_WORKSPACE_ID=""
    local REQ_PAYLOAD_SLUG="" REQ_PAYLOAD_DESCRIPTION="" REQ_PAYLOAD_WORKER_FAMILY=""
    local REQ_PAYLOAD_ADVISOR_MODE="" REQ_PAYLOAD_EXECUTOR_TIER=""
    local REQ_PAYLOAD_DRY_RUN="" REQ_PAYLOAD_NO_WORKTREE=""
    local REQ_PAYLOAD_KEEP_ALIVE="" REQ_PAYLOAD_RESUME=""
    eval "$(parse_request_file "${request_file}")"

    slug="${REQ_PAYLOAD_SLUG:-${REQ_SLUG:-}}"
    description="${REQ_PAYLOAD_DESCRIPTION:-}"
    if [[ -z "${slug}" ]]; then
      die "--request file missing slug (expected '- slug: <value>' in ## Payload section). Use build_dispatch_payload helper."
    fi
    if [[ -z "${description}" ]]; then
      die "--request file missing description (expected '- description: <value>' in ## Payload section). Use build_dispatch_payload helper."
    fi

    # Set all fields from request — these are authoritative, not LLM-derived
    [[ "${REQ_PROJECT}" != "-" && -n "${REQ_PROJECT}" ]] && project_path="${REQ_PROJECT}"
    [[ "${REQ_WORKSPACE_ID}" != "-" && -n "${REQ_WORKSPACE_ID}" ]] && target_workspace_id="${REQ_WORKSPACE_ID}"
    [[ -n "${REQ_PAYLOAD_WORKER_FAMILY}" ]] && agent_override="${REQ_PAYLOAD_WORKER_FAMILY}"
    [[ -n "${REQ_PAYLOAD_ADVISOR_MODE}" ]] && advisor_mode="${REQ_PAYLOAD_ADVISOR_MODE}"
    [[ -n "${REQ_PAYLOAD_EXECUTOR_TIER}" ]] && executor_tier="${REQ_PAYLOAD_EXECUTOR_TIER}"
    [[ "${REQ_PAYLOAD_DRY_RUN}" == "true" ]] && execute=0
    [[ "${REQ_PAYLOAD_NO_WORKTREE}" == "true" ]] && no_worktree=1
    [[ "${REQ_PAYLOAD_KEEP_ALIVE}" == "true" ]] && keep_alive="true"
    [[ "${REQ_PAYLOAD_RESUME}" == "true" ]] && do_resume="true"
  else
    [[ -n "${slug}" ]] || die "dispatch requires <slug>"
    [[ -n "${description}" ]] || die "dispatch requires <description>"
    shift 2 || true
  fi

  while (($# > 0)); do
    case "$1" in
      --dry-run)
        execute=0
        ;;
      --execute)
        execute=1
        ;;
      --no-worktree)
        no_worktree=1
        ;;
      --keep-alive)
        keep_alive="true"
        ;;
      --resume)
        do_resume="true"
        ;;
      --collab-pair)
        is_collab_pair="true"
        ;;
      --agent)
        shift
        [[ $# -gt 0 ]] || die "--agent requires a value (claude|codex)"
        agent_override="$1"
        ;;
      --advisor-mode)
        shift
        [[ $# -gt 0 ]] || die "--advisor-mode requires a value"
        advisor_mode="$1"
        ;;
      --executor-tier)
        shift
        [[ $# -gt 0 ]] || die "--executor-tier requires a value"
        executor_tier="$1"
        ;;
      --project-path)
        shift
        [[ $# -gt 0 ]] || die "--project-path requires a value"
        project_path="$1"
        ;;
      --target-workspace)
        shift
        [[ $# -gt 0 ]] || die "--target-workspace requires a value"
        target_workspace_id="$1"
        ;;
      *)
        die "unknown dispatch flag: $1"
        ;;
    esac
    shift
  done

  # Default project_path to PWD if not explicitly provided.
  # When the orchestrator calls conductor.sh on behalf of a requester,
  # it MUST pass --project-path so we don't use the orchestrator's own cwd.
  [[ -n "${project_path}" ]] || project_path="${PWD}"
  # Inherit workspace from env if not passed via --target-workspace (daemon
  # sets ORCHESTRATOR_TARGET_WORKSPACE_ID before calling conductor.sh).
  [[ -n "${target_workspace_id}" ]] || target_workspace_id="${ORCHESTRATOR_TARGET_WORKSPACE_ID:-}"

  # Rotate ghost sessions use --no-worktree because they're temporary
  # session archives, not task workers that need isolation. Accept both
  # the legacy `ghost-<ts>` form and the current `<origin>-ghost-<N>`
  # form produced by daemon.sh's derive_ghost_slug.
  if (( execute == 1 )) && (( no_worktree == 1 )) && [[ "${slug}" != ghost-* && "${slug}" != *-ghost-* ]]; then
    die "--no-worktree is disabled for execute; dispatch workers must use an isolated worktree"
  fi

  # Export target workspace so spawn.sh routes the surface correctly.
  # A valid workspace:N ref is required — spawning without one would land
  # the surface in the orchestrator's own workspace, which is always wrong.
  if [[ -z "${target_workspace_id}" ]]; then
    die "requester workspace unknown (target_workspace_id is empty). Cannot route surface — aborting dispatch."
  fi
  if [[ ! "${target_workspace_id}" =~ ^workspace:[0-9]+$ ]]; then
    die "--target-workspace/request workspace must be workspace:N, got '${target_workspace_id}'"
  fi
  export ORCHESTRATOR_TARGET_WORKSPACE_ID="${target_workspace_id}"

  validate_slug "${slug}"
  if [[ -n "${agent_override}" ]]; then
    case "${agent_override}" in
      claude|codex) agent_family="${agent_override}" ;;
      *) die "--agent must be 'claude' or 'codex', got '${agent_override}'" ;;
    esac
  else
    agent_family="$(derive_agent_family)"
  fi
  state="$(state_json)"
  local plan_args=(
    --root "${ORCHESTRATOR_ROOT}"
    --state-json "${state}"
    --slug "${slug}"
    --description "${description}"
    --cwd "${project_path}"
    --project-name "$(_resolve_project_alias "${project_path}")"
    --agent "${agent_family}"
    --advisor-mode "${advisor_mode}"
    --executor-tier "${executor_tier}"
  )
  (( no_worktree == 1 )) && plan_args+=(--no-worktree)
  [[ "${keep_alive}" == "true" ]] && plan_args+=(--keep-alive)
  plan="$("${PLAN_SCRIPT}" "${plan_args[@]}")"

  if jq -e '.conflicts.active_task_exists' <<<"${plan}" >/dev/null; then
    die "task slug '${slug}' already exists with non-done status in orchestrator state"
  fi

  slot="$(jq -r '.agents[0].slot' <<<"${plan}")"
  agent_cwd="$(jq -r '.agents[0].cwd' <<<"${plan}")"
  work_item_path="$(jq -r '.task.work_item_path' <<<"${plan}")"
  done_report_path="$(jq -r '.task.done_report_path' <<<"${plan}")"
  worktree_required="$(jq -r '.worktree.required' <<<"${plan}")"
  worktree_path="$(jq -r '.worktree.path // empty' <<<"${plan}")"
  worktree_branch="$(jq -r '.worktree.branch // empty' <<<"${plan}")"
  advisor_mode="$(jq -r '.request.advisor_mode // "none"' <<<"${plan}")"
  executor_tier="$(jq -r '.request.executor_tier // "default"' <<<"${plan}")"

  if [[ "${worktree_required}" == "true" ]]; then
    worktree_preview="$("${CREATE_WORKTREE_EFFECT}" --dry-run "${project_path}" "${worktree_path}" "${worktree_branch}" HEAD)"
  else
    worktree_preview='{"action":"create-worktree","mode":"skipped","reason":"--no-worktree"}'
  fi
  spawn_preview="$("${SPAWN_EFFECT}" --dry-run "${slot}" "${agent_cwd}")"
  inject_preview="$("${INJECT_EFFECT}" --dry-run --family "${agent_family}" "pending-surface" "${work_item_path}")"
  if (( execute == 0 )); then
    plan_output="$(
      jq -n \
        --argjson plan "${plan}" \
        --argjson worktree "${worktree_preview}" \
        --argjson spawn "${spawn_preview}" \
        --argjson inject "${inject_preview}" \
        '{
          mode: "dry-run",
          plan: $plan,
          effects: {
            worktree: $worktree,
            spawn: $spawn,
            inject: $inject
          }
        }'
    )"
    printf '%s\n' "${plan_output}" | jq '.'
    return 0
  fi

  atomic_write "${work_item_path}" "$(render_work_item_markdown "${slug}" "${description}" "${agent_family}" "${advisor_mode}" "${executor_tier}" "${keep_alive}" "${is_collab_pair}" "${worktree_path}" "${worktree_branch}")"
  now="$(timestamp_utc)"
  _acquire_state_lock
  state="$(state_json)"
  planned_state="$(
    "${STATE_TRANSITION}" \
      --mode dispatch \
      --now "${now}" \
      --state-json "${state}" \
      --plan-json "${plan}"
  )"
  write_state_json "${planned_state}"
  _release_state_lock
  append_activity "$(
    jq -cn \
      --arg timestamp "${now}" \
      --arg slug "${slug}" \
      --arg slot "${slot}" \
      --arg description "${description}" \
      --arg advisor_mode "${advisor_mode}" \
      --arg executor_tier "${executor_tier}" \
      '{timestamp: $timestamp, event: "dispatch-planned", slug: $slug, slot: $slot, description: $description, advisor_mode: $advisor_mode, executor_tier: $executor_tier}'
  )"

  _dispatch_fail() {
    rollback_dispatch_artifacts \
      "${slug}" \
      "${slot}" \
      "${work_item_path}" \
      "${worktree_required}" \
      "${project_path}" \
      "${worktree_path}" \
      "${worktree_branch}" \
      "${surface_id}" \
      "${spawn_workspace_id}"
    die "dispatch execute failed during ${dispatch_phase}"
  }

  if [[ "${worktree_required}" == "true" ]]; then
    dispatch_phase="create-worktree"
    set +e
    worktree_output="$("${CREATE_WORKTREE_EFFECT}" --execute "${project_path}" "${worktree_path}" "${worktree_branch}" HEAD 2>&1)"
    dispatch_rc=$?
    set -e
    if (( dispatch_rc != 0 )); then
      printf '%s\n' "${worktree_output}" >&2
      _dispatch_fail
    fi
  else
    worktree_output='{"action":"create-worktree","mode":"skipped","reason":"--no-worktree"}'
  fi
  dispatch_phase="spawn"
  export ORCHESTRATOR_AGENT_RESUME="${do_resume}" ORCHESTRATOR_TASK_SLUG="${slug}"
  set +e
  spawn_output="$("${SPAWN_EFFECT}" --execute "${slot}" "${agent_cwd}" 2>&1)"
  dispatch_rc=$?
  set -e
  unset ORCHESTRATOR_AGENT_RESUME ORCHESTRATOR_TASK_SLUG
  if (( dispatch_rc != 0 )); then
    printf '%s\n' "${spawn_output}" >&2
    _dispatch_fail
  fi
  surface_id="$(jq -r '.surface_id // empty' <<<"${spawn_output}")"
  target_workspace="$(jq -r '.target_workspace // empty' <<<"${spawn_output}")"
  [[ -n "${surface_id}" ]] || _dispatch_fail
  _cmux_snapshot_after_spawn="$(cmux_surface_snapshot)"
  target_workspace="$(canonical_workspace_ref "${target_workspace}" "${_cmux_snapshot_after_spawn}" "${surface_id}" 2>/dev/null || true)"
  [[ -n "${target_workspace}" ]] || _dispatch_fail
  spawn_workspace_id="${target_workspace}"

  # Wait for the spawned agent to boot before injecting the work item prompt.
  # Poll zmx first (fast path); fall back to ps if zmx is unreachable.
  # Override max wait via ORCHESTRATOR_SPAWN_WAIT (seconds, default 30).
  _spawn_wait_max="${ORCHESTRATOR_SPAWN_WAIT:-30}"
  _spawn_waited=0
  _spawn_detected=0
  while (( _spawn_waited < _spawn_wait_max )); do
    if zmx list 2>/dev/null | grep "name=${slot}" | grep -qE 'pid=[0-9]+'; then
      _spawn_detected=1; await_agent_ready "${surface_id}" "${agent_family}" 60 "${target_workspace}"; break
    fi
    if pgrep -f "zmx attach ${slot}" >/dev/null 2>&1; then
      _spawn_detected=1; await_agent_ready "${surface_id}" "${agent_family}" 60 "${target_workspace}"; break
    fi
    sleep 1
    (( _spawn_waited++ )) || true
  done
  if (( _spawn_detected == 0 )); then
    dispatch_phase="spawn-wait"
    _dispatch_fail
  fi

  dispatch_phase="inject"
  set +e
  inject_output="$("${INJECT_EFFECT}" --execute --verify --family "${agent_family}" "${surface_id}" "${work_item_path}" 2>&1)"
  dispatch_rc=$?
  set -e
  if (( dispatch_rc != 0 )); then
    printf '%s\n' "${inject_output}" >&2
    _dispatch_fail
  fi

  # Tag Codex sessions with the task slug for later `codex resume <slug>`.
  # Claude uses --name at spawn time; Codex lacks that flag, so we inject
  # /rename after the work item prompt.
  if [[ "${agent_family}" == "codex" ]]; then
    await_agent_ready "${surface_id}" "codex" 5
    "${INJECT_EFFECT}" --execute --as-prompt --family codex "${surface_id}" "/rename ${slug}" >/dev/null 2>&1 || true
  fi

  _acquire_state_lock
  local _current_state
  _current_state="$(state_json)"
  running_state="$(
    jq \
      --arg now "$(timestamp_utc)" \
      --arg slot "${slot}" \
      --arg slug "${slug}" \
      --arg surface_id "${surface_id}" \
      --arg workspace_id "${target_workspace}" \
      '
      .updated_at = $now
      | .tasks[$slug].status = "in_progress"
      | .tasks[$slug].updated_at = $now
      | .agents[$slot].status = "running"
      | .agents[$slot].surface_id = $surface_id
      | .agents[$slot].workspace_id = (if $workspace_id == "" then null else $workspace_id end)
      | .agents[$slot].updated_at = $now
      ' <<<"${_current_state}"
  )"
  write_state_json "${running_state}"
  _release_state_lock
  append_activity "$(
    jq -cn \
      --arg timestamp "$(timestamp_utc)" \
      --arg slug "${slug}" \
      --arg slot "${slot}" \
      --arg surface_id "${surface_id}" \
      --arg advisor_mode "${advisor_mode}" \
      --arg executor_tier "${executor_tier}" \
      '{timestamp: $timestamp, event: "dispatch-started", slug: $slug, slot: $slot, surface_id: $surface_id, advisor_mode: $advisor_mode, executor_tier: $executor_tier}'
  )"

  jq -n \
    --argjson plan "${plan}" \
    --argjson worktree "${worktree_output}" \
    --argjson spawn "${spawn_output}" \
    --argjson inject "${inject_output}" \
    --arg work_item_path "${work_item_path}" \
    --arg done_report_path "${done_report_path}" \
    '{
      mode: "execute",
      plan: $plan,
      effects: {
        worktree: $worktree,
        spawn: $spawn,
        inject: $inject
      },
      files: {
        work_item_path: $work_item_path,
        done_report_path: $done_report_path
      }
    }' | jq '.'
}

list_command() {
  local state
  state="$(state_json)"

  printf 'Orchestrator root: %s\n' "${ORCHESTRATOR_ROOT}"
  jq -r '
    "Projects:",
    (if (.projects | length) == 0 then
      "- none"
    else
      (.projects | to_entries | sort_by(.key)[] |
        "- \(.key) (\(.value.path)): \((.value.tasks // []) | length) task(s)")
    end),
    "Tasks:",
    (if (.tasks | length) == 0 then
      "- none"
    else
      (.tasks | to_entries | sort_by(.key)[] |
        "- \(.key) [\(.value.status)]: \(.value.description)")
    end),
    "Agents:",
    (if (.agents | length) == 0 then
      "- none"
    else
      (.agents | to_entries | sort_by(.key)[] |
        "- \(.key) [\(.value.status)]: task=\(.value.task) cwd=\(.value.cwd)")
    end)
  ' <<<"${state}"
}

status_command() {
  local slug="${1:-}"
  local state
  state="$(state_json)"

  if [[ -z "${slug}" ]]; then
    jq '{projects, tasks, agents, updated_at}' <<<"${state}"
    return 0
  fi

  validate_slug "${slug}"
  jq --arg slug "${slug}" '
    if .tasks[$slug] == null then
      error("task not found: \($slug)")
    else
      {
        task: .tasks[$slug],
        agents: (
          [(.tasks[$slug].agents // [])[] as $slot | .agents[$slot]]
        )
      }
    end
  ' <<<"${state}"
}

done_command() {
  local slug="${1:-}"
  local execute=0
  local do_cleanup=0
  local state task_status task_path done_report_path description project_slug advisor_mode plan done_state now

  [[ -n "${slug}" ]] || die "done requires <slug>"
  shift || true

  while (($# > 0)); do
    case "$1" in
      --dry-run)   execute=0 ;;
      --execute)   execute=1 ;;
      --cleanup)   do_cleanup=1 ;;
      *)           die "unknown done flag: $1" ;;
    esac
    shift
  done

  validate_slug "${slug}"
  state="$(state_json)"
  task_exists_in_state "${slug}" "${state}" || die "task slug '${slug}' does not exist"
  task_status="$(jq -r --arg slug "${slug}" '.tasks[$slug].status // "missing"' <<<"${state}")"
  if [[ "${task_status}" == "done" ]]; then
    if (( do_cleanup == 1 )); then
      # Already done, just run cleanup
      cleanup_command "${slug}" $(( execute == 1 )) && return 0 || return $?
    fi
    printf "conductor.sh: task slug '%s' is already done; skipping\n" "${slug}" >&2
    return 0
  fi

  task_path="$(jq -r --arg slug "${slug}" '.tasks[$slug].work_item_path // empty' <<<"${state}")"
  done_report_path="$(jq -r --arg slug "${slug}" '.tasks[$slug].done_report_path // empty' <<<"${state}")"
  description="$(jq -r --arg slug "${slug}" '.tasks[$slug].description // ""' <<<"${state}")"
  project_slug="$(jq -r --arg slug "${slug}" '.tasks[$slug].project // ""' <<<"${state}")"
  advisor_mode="$(
    jq -r --arg slug "${slug}" '
      .tasks[$slug].request_metadata.advisor_mode
      // ((.tasks[$slug].agents[0] // "") as $slot
          | if $slot == "" then null else .agents[$slot].advisor_mode end)
      // "none"
    ' <<<"${state}"
  )"

  [[ -n "${task_path}" ]] || task_path="${ORCHESTRATOR_ROOT}/tasks/${slug}.md"
  [[ -n "${done_report_path}" ]] || done_report_path="${ORCHESTRATOR_ROOT}/done/${slug}.md"

  plan="$(
    jq -n \
      --arg slug "${slug}" \
      --arg done_report_path "${done_report_path}" \
      --arg project_slug "${project_slug}" \
      '{action:"done", project:{slug:$project_slug}, task:{slug:$slug, done_report_path:$done_report_path}}'
  )"

  if (( execute == 0 )); then
    jq -n \
      --argjson plan "${plan}" \
      --arg advisor_mode "${advisor_mode}" \
      --argjson cleanup "$( (( do_cleanup == 1 )) && echo true || echo false)" \
      '{
        mode:"dry-run",
        plan:$plan,
        advisor:{mode:$advisor_mode, will_run_review:($advisor_mode == "review")},
        cleanup_after_done:$cleanup,
        note:"done = state transition only. Resources (surface, worktree, agent) are preserved. Use --cleanup or separate cleanup command to remove them."
      }'  | jq '.'
    return 0
  fi

  local advisor_status
  set +e
  _run_advisor "${advisor_mode}" "${slug}" "${description}" "${task_path}" "${done_report_path}" "${state}"
  advisor_status=$?
  set -e
  if (( advisor_status == 20 )); then
    return 20
  fi

  # State transition: in_progress → done (no resource cleanup).
  # Runs under state_transaction so we use a fresh read-modify-write,
  # not the state we captured before the advisor step (which may have
  # been invalidated by concurrent dispatches/cleanups) — C3 fix.
  atomic_write "${done_report_path}" "$(render_done_report_markdown "${slug}" "${description}" "${task_path}")"
  now="$(timestamp_utc)"
  _done_transition_cb() {
    local fresh_state
    fresh_state="$(cat)"
    "${STATE_TRANSITION}" \
      --mode done \
      --now "${now}" \
      --state-json "${fresh_state}" \
      --plan-json "${plan}"
  }
  state_transaction _done_transition_cb >/dev/null
  append_activity "$(
    jq -cn --arg timestamp "${now}" --arg slug "${slug}" \
      '{timestamp:$timestamp, event:"task-done", slug:$slug}'
  )"

  if (( do_cleanup == 1 )); then
    cleanup_command "${slug}" 1
  else
    jq -n --argjson plan "${plan}" --arg done_report_path "${done_report_path}" \
      '{mode:"execute", plan:$plan, effects:{surface:"preserved", worktree:"preserved", agent:"preserved"}, files:{done_report_path:$done_report_path}, note:"Resources preserved. Run cleanup to remove them."}' | jq '.'
  fi
}

cleanup_command() {
  local slug="${1:-}"
  local execute="${2:-0}"
  local force=0
  local state task_status project_path project_slug worktree_path worktree_branch agent_slot agent_surface_id
  local surface_cleanup_output worktree_cleanup_output

  [[ -n "${slug}" ]] || die "cleanup requires <slug>"

  # Support CLI flags when called directly
  if [[ "${execute}" != "0" && "${execute}" != "1" ]]; then
    local do_execute=0
    shift || true
    while (($# > 0)); do
      case "$1" in
        --dry-run)  do_execute=0 ;;
        --execute)  do_execute=1 ;;
        --force)    force=1 ;;
        *)          die "unknown cleanup flag: $1" ;;
      esac
      shift
    done
    execute="${do_execute}"
  fi

  state="$(state_json)"
  task_exists_in_state "${slug}" "${state}" || die "task slug '${slug}' does not exist"
  task_status="$(jq -r --arg slug "${slug}" '.tasks[$slug].status // "missing"' <<<"${state}")"

  project_slug="$(jq -r --arg slug "${slug}" '.tasks[$slug].project // empty' <<<"${state}")"
  project_path="$(jq -r --arg slug "${slug}" '.tasks[$slug].project_path // empty' <<<"${state}")"
  worktree_path="$(jq -r --arg slug "${slug}" '.tasks[$slug].worktree_path // empty' <<<"${state}")"
  worktree_branch="$(jq -r --arg slug "${slug}" '.tasks[$slug].worktree_branch // empty' <<<"${state}")"
  agent_slot="$(jq -r --arg slug "${slug}" '.tasks[$slug].agents[0] // empty' <<<"${state}")"
  # Fallback: if task.agents is empty, search agents map for one referencing this task
  if [[ -z "${agent_slot}" ]]; then
    agent_slot="$(jq -r --arg slug "${slug}" '
      [.agents // {} | to_entries[] | select(.value.task == $slug) | .key] | .[0] // empty
    ' <<<"${state}")"
  fi
  agent_surface_id=""
  local agent_workspace_id=""
  if [[ -n "${agent_slot}" ]]; then
    agent_surface_id="$(jq -r --arg slot "${agent_slot}" '.agents[$slot].surface_id // empty' <<<"${state}")"
    agent_workspace_id="$(jq -r --arg slot "${agent_slot}" '.agents[$slot].workspace_id // empty' <<<"${state}")"
  fi

  if (( execute == 0 )); then
    jq -n \
      --arg slug "${slug}" \
      --arg task_status "${task_status}" \
      --arg agent_slot "${agent_slot}" \
      --arg surface_id "${agent_surface_id}" \
      --arg worktree "${worktree_path}" \
      --arg branch "${worktree_branch}" \
      '{mode:"dry-run", action:"cleanup", slug:$slug, task_status:$task_status,
        will_close_surface:($surface_id != ""), will_remove_worktree:($worktree != ""),
        will_delete_branch:($branch != ""), will_remove_agent:($agent_slot != "")}' | jq '.'
    return 0
  fi

  # Explicit cleanup may remove a registered worktree, but never while a
  # live zmx session still owns that directory. Require both signals so
  # normal post-done cleanup continues to work for stale-but-inactive
  # worktrees.
  if [[ -n "${worktree_path}" && "${force}" != "1" ]]; then
    local cleanup_worktree_registry cleanup_zmx_live_snapshot
    local cleanup_registered_in_git=0 cleanup_zmx_start_dir_match=0
    cleanup_worktree_registry="$(git_worktree_snapshot "${project_path:-${PWD}}")"
    cleanup_zmx_live_snapshot="$(zmx_snapshot)"
    if git_worktree_path_registered "${cleanup_worktree_registry}" "${worktree_path}"; then
      cleanup_registered_in_git=1
    fi
    if zmx_snapshot_has_start_dir "${cleanup_zmx_live_snapshot}" "${worktree_path}"; then
      cleanup_zmx_start_dir_match=1
    fi
    if (( cleanup_registered_in_git == 1 )) && (( cleanup_zmx_start_dir_match == 1 )); then
      die "cleanup refused for '${slug}': live signals detected (registered git worktree, zmx start_dir=${worktree_path}); re-run with --force to override"
    fi
  fi

  # 1. Close cmux surface (before zmx kill — surface needs session alive to identify)
  #    GUARD: never close a surface that belongs to a persistent agent in the
  #    agent-team registry. GC/cleanup targets task workers, not team agents.
  surface_cleanup_output='{"action":"surface-cleanup","mode":"skipped"}'
  if [[ -n "${agent_surface_id}" ]] && command -v cmux >/dev/null 2>&1; then
    local _cmux_snapshot
    _cmux_snapshot="$(cmux_surface_snapshot)"
    local _protected=0
    local _registry="${ORCHESTRATOR_ROOT}/agents/registry.json"
    if [[ -f "${_registry}" ]]; then
      # Fail-closed: if registry exists but jq fails, assume protected.
      local _jq_result
      _jq_result="$(jq -r --arg sf "${agent_surface_id}" \
        '[.agents[].surface_id // empty] | map(select(. == $sf)) | length' \
        "${_registry}" 2>/dev/null)" || _jq_result="1"
      if [[ "${_jq_result}" != "0" ]]; then
        _protected=1
        surface_cleanup_output='{"action":"surface-cleanup","mode":"skipped","reason":"protected-agent-surface"}'
      fi
    fi
    if (( _protected == 0 )); then
      local ws_for_close=''
      ws_for_close="$(canonical_workspace_ref "${agent_workspace_id}" "${_cmux_snapshot}" "${agent_surface_id}" 2>/dev/null || true)"
      if [[ -z "${ws_for_close}" ]]; then
        ws_for_close="$(canonical_workspace_ref "${ORCHESTRATOR_TARGET_WORKSPACE_ID:-}" "${_cmux_snapshot}" "${agent_surface_id}" 2>/dev/null || true)"
      fi
      if [[ -z "${ws_for_close}" ]]; then
        ws_for_close="$(canonical_workspace_ref "${CMUX_WORKSPACE_ID:-}" "${_cmux_snapshot}" "${agent_surface_id}" 2>/dev/null || true)"
      fi
      local close_args=(--surface "${agent_surface_id}")
      [[ -n "${ws_for_close}" ]] && close_args+=(--workspace "${ws_for_close}")
      if cmux close-surface "${close_args[@]}" >/dev/null 2>&1; then
        surface_cleanup_output="$(jq -n --arg surface "${agent_surface_id}" '{action:"close-surface",mode:"execute",surface:$surface}')"
        append_activity "$(jq -nc \
          --arg ts "$(timestamp_utc)" \
          --arg slug "${slug}" \
          --arg surface "${agent_surface_id}" \
          '{ts:$ts, event:"cleanup.surface", slug:$slug, surface:$surface, result:"closed"}')"
      else
        surface_cleanup_output="$(jq -n --arg surface "${agent_surface_id}" --arg ws "${ws_for_close}" '{action:"close-surface",mode:"failed",surface:$surface,workspace:$ws}')"
        append_activity "$(jq -nc \
          --arg ts "$(timestamp_utc)" \
          --arg slug "${slug}" \
          --arg surface "${agent_surface_id}" \
          --arg workspace "${ws_for_close}" \
          '{ts:$ts, event:"cleanup.surface", slug:$slug, surface:$surface, workspace:$workspace, result:"failed"}')"
      fi
    fi
  fi

  # 2. Kill zmx session (fallback to process kill if zmx unreachable)
  if [[ -n "${agent_slot}" ]] && command -v zmx >/dev/null 2>&1; then
    if ! zmx kill "${agent_slot}" >/dev/null 2>&1; then
      local _zmx_pid
      _zmx_pid="$(zmx list 2>/dev/null | grep "name=${agent_slot}" | sed -n 's/.*pid=\([0-9]*\).*/\1/p')"
      if [[ -z "${_zmx_pid}" ]]; then
        _zmx_pid="$(pgrep -f "zmx attach ${agent_slot}" 2>/dev/null | head -1 || true)"
      fi
      if [[ -n "${_zmx_pid}" ]]; then
        kill -9 "${_zmx_pid}" 2>/dev/null || true
        sleep 1
      fi
      zmx kill "${agent_slot}" >/dev/null 2>&1 || true
    fi
    append_activity "$(jq -nc \
      --arg ts "$(timestamp_utc)" \
      --arg slug "${slug}" \
      --arg slot "${agent_slot}" \
      '{ts:$ts, event:"cleanup.zmx", slug:$slug, slot:$slot, result:"kill-requested"}')"
  fi

  # 3. Remove worktree + branch
  worktree_cleanup_output='{"action":"cleanup-worktree","mode":"skipped"}'
  if [[ -n "${worktree_path}" ]]; then
    local cleanup_args=(--execute "${project_path}" "${worktree_path}")
    [[ -n "${worktree_branch}" ]] && cleanup_args+=(--branch "${worktree_branch}" --delete-branch)
    worktree_cleanup_output="$("${CLEANUP_WORKTREE_EFFECT}" "${cleanup_args[@]}" 2>&1)" || true
    if ! jq -e . <<<"${worktree_cleanup_output}" >/dev/null 2>&1; then
      worktree_cleanup_output="$(jq -n --arg raw "${worktree_cleanup_output}" '{action:"cleanup-worktree",mode:"failed",raw:$raw}')"
    fi
    append_activity "$(jq -nc \
      --arg ts "$(timestamp_utc)" \
      --arg slug "${slug}" \
      --argjson effect "${worktree_cleanup_output}" \
      '{ts:$ts, event:"cleanup.worktree", slug:$slug, effect:$effect}')"
  fi

  # 4. Remove agent from state.json. If this was the final agent (or the
  #    task was already agentless), remove the task entry as well so cleanup
  #    does not leave stale in_progress tasks behind.
  {
    local now
    now="$(timestamp_utc)"
    local new_state
    new_state="$(jq \
      --arg slot "${agent_slot}" \
      --arg slug "${slug}" \
      --arg project "${project_slug}" \
      --arg now "${now}" '
      .updated_at = $now
      | if $slot != "" then del(.agents[$slot]) else . end
      | .tasks[$slug].agents = ((.tasks[$slug].agents // []) | map(select(. != $slot)))
      | if ((.tasks[$slug].agents // []) | length) == 0 then
          (if $project != "" and (.projects[$project] != null) then
             .projects[$project].tasks = ((.projects[$project].tasks // []) | map(select(. != $slug)))
             | .projects[$project].updated_at = $now
           else
             .
           end)
          | del(.tasks[$slug])
        else
          .tasks[$slug].updated_at = $now
        end
    ' <<<"$(state_json)")"
    write_state_json "${new_state}"
    append_activity "$(jq -cn --arg timestamp "${now}" --arg slug "${slug}" --arg slot "${agent_slot}" \
      '{timestamp:$timestamp, event:"task-cleanup", slug:$slug, slot:$slot}')"
  }

  jq -n \
    --arg slug "${slug}" \
    --argjson surface "${surface_cleanup_output}" \
    --argjson worktree "${worktree_cleanup_output}" \
    '{mode:"execute", action:"cleanup", slug:$slug, effects:{surface:$surface, worktree:$worktree}}' | jq '.'
}

collab_command() {
  local slug="${1:-}"
  local description="${2:-}"
  local execute=0
  local advisor_mode="none"
  local executor_tier="default"
  local no_worktree=0
  local project_path=""
  local target_workspace_id=""
  local request_file=""

  # Support --request as first arg: conductor.sh collab --request <file> [--execute|--dry-run]
  if [[ "${slug}" == "--request" ]]; then
    request_file="${description}"
    [[ -n "${request_file}" && -f "${request_file}" ]] || die "--request requires a valid file path"
    shift 2 || true

    local REQ_ID="" REQ_TYPE="" REQ_SLUG="" REQ_PROJECT="" REQ_WORKSPACE_ID=""
    local REQ_PAYLOAD_SLUG="" REQ_PAYLOAD_DESCRIPTION="" REQ_PAYLOAD_WORKER_FAMILY=""
    local REQ_PAYLOAD_ADVISOR_MODE="" REQ_PAYLOAD_EXECUTOR_TIER=""
    local REQ_PAYLOAD_DRY_RUN="" REQ_PAYLOAD_NO_WORKTREE=""
    local REQ_PAYLOAD_KEEP_ALIVE="" REQ_PAYLOAD_RESUME=""
    eval "$(parse_request_file "${request_file}")"

    slug="${REQ_PAYLOAD_SLUG:-${REQ_SLUG:-}}"
    description="${REQ_PAYLOAD_DESCRIPTION:-}"
    if [[ -z "${slug}" ]]; then
      die "--request file missing slug (expected '- slug: <value>' in ## Payload section). Use build_dispatch_payload helper."
    fi
    if [[ -z "${description}" ]]; then
      die "--request file missing description (expected '- description: <value>' in ## Payload section). Use build_dispatch_payload helper."
    fi

    [[ "${REQ_PROJECT}" != "-" && -n "${REQ_PROJECT}" ]] && project_path="${REQ_PROJECT}"
    [[ "${REQ_WORKSPACE_ID}" != "-" && -n "${REQ_WORKSPACE_ID}" ]] && target_workspace_id="${REQ_WORKSPACE_ID}"
    [[ -n "${REQ_PAYLOAD_ADVISOR_MODE}" ]] && advisor_mode="${REQ_PAYLOAD_ADVISOR_MODE}"
    [[ -n "${REQ_PAYLOAD_EXECUTOR_TIER}" ]] && executor_tier="${REQ_PAYLOAD_EXECUTOR_TIER}"
    [[ "${REQ_PAYLOAD_DRY_RUN}" == "true" ]] && execute=0
    [[ "${REQ_PAYLOAD_NO_WORKTREE}" == "true" ]] && no_worktree=1
  else
    [[ -n "${slug}" ]] || die "collab requires <slug>"
    [[ -n "${description}" ]] || die "collab requires <description>"
    shift 2 || true
  fi

  while (($# > 0)); do
    case "$1" in
      --dry-run)       execute=0 ;;
      --execute)       execute=1 ;;
      --advisor-mode)  shift; [[ $# -gt 0 ]] || die "--advisor-mode requires a value"; advisor_mode="$1" ;;
      --executor-tier) shift; [[ $# -gt 0 ]] || die "--executor-tier requires a value"; executor_tier="$1" ;;
      --no-worktree)   no_worktree=1 ;;
      --project-path)  shift; [[ $# -gt 0 ]] || die "--project-path requires a value"; project_path="$1" ;;
      --target-workspace) shift; [[ $# -gt 0 ]] || die "--target-workspace requires a value"; target_workspace_id="$1" ;;
      *)               die "unknown collab flag: $1" ;;
    esac
    shift
  done

  validate_slug "${slug}"
  [[ ${#slug} -le 25 ]] || die "collab slug must be <= 25 chars (reserve room for -claude/-codex suffixes)"

  local claude_slug="${slug}-claude"
  local codex_slug="${slug}-codex"
  local mode_flag="--dry-run"
  (( execute == 1 )) && mode_flag="--execute"

  local common_args=(
    "${mode_flag}"
    --keep-alive
    --collab-pair
    --advisor-mode "${advisor_mode}"
    --executor-tier "${executor_tier}"
  )
  (( no_worktree == 1 )) && common_args+=(--no-worktree)
  [[ -n "${project_path}" ]] && common_args+=(--project-path "${project_path}")
  if [[ -z "${target_workspace_id}" ]]; then
    die "requester workspace unknown (target_workspace_id is empty). Cannot route collab surfaces — aborting."
  fi
  common_args+=(--target-workspace "${target_workspace_id}")

  local claude_tmp codex_tmp
  claude_tmp="$(mktemp "${TMPDIR:-/tmp}/conductor-collab-claude.XXXXXX")"
  codex_tmp="$(mktemp "${TMPDIR:-/tmp}/conductor-collab-codex.XXXXXX")"
  # Ensure cleanup on exit from this function.
  # Capture paths in trap string to avoid unbound variable under set -u
  # if trap fires after local scope is lost.
  trap "rm -f '${claude_tmp}' '${codex_tmp}'" RETURN

  local claude_rc=0 codex_rc=0

  if (( execute == 0 )); then
    # Dry-run: run sequentially (no side effects, order doesn't matter)
    dispatch_command "${claude_slug}" "${description}" \
      --agent claude "${common_args[@]}" > "${claude_tmp}" 2>&1 || claude_rc=$?
    dispatch_command "${codex_slug}" "${description}" \
      --agent codex "${common_args[@]}" > "${codex_tmp}" 2>&1 || codex_rc=$?
  else
    # Execute: run in parallel (flock serializes state.json writes)
    dispatch_command "${claude_slug}" "${description}" \
      --agent claude "${common_args[@]}" > "${claude_tmp}" 2>&1 &
    local claude_pid=$!

    dispatch_command "${codex_slug}" "${description}" \
      --agent codex "${common_args[@]}" > "${codex_tmp}" 2>&1 &
    local codex_pid=$!

    wait "${claude_pid}" || claude_rc=$?
    wait "${codex_pid}" || codex_rc=$?
  fi

  local claude_out codex_out
  claude_out="$(cat "${claude_tmp}")"
  codex_out="$(cat "${codex_tmp}")"

  # Classify overall status
  local status="ok"
  if (( claude_rc != 0 && codex_rc != 0 )); then
    status="error"
  elif (( claude_rc != 0 || codex_rc != 0 )); then
    status="partial"
  fi

  # Parse JSON outputs; fall back to raw string on parse failure
  local claude_json codex_json
  claude_json="$(jq -e '.' <<<"${claude_out}" 2>/dev/null)" || \
    claude_json="$(jq -n --arg raw "${claude_out}" '{parse_error: true, raw: $raw}')"
  codex_json="$(jq -e '.' <<<"${codex_out}" 2>/dev/null)" || \
    codex_json="$(jq -n --arg raw "${codex_out}" '{parse_error: true, raw: $raw}')"

  jq -n \
    --arg mode "$(if (( execute )); then echo execute; else echo dry-run; fi)" \
    --arg status "${status}" \
    --arg base_slug "${slug}" \
    --argjson claude_rc "${claude_rc}" \
    --argjson codex_rc "${codex_rc}" \
    --argjson claude "${claude_json}" \
    --argjson codex "${codex_json}" \
    '{
      mode: $mode,
      status: $status,
      base_slug: $base_slug,
      claude_worker: { exit_code: $claude_rc, output: $claude },
      codex_worker: { exit_code: $codex_rc, output: $codex }
    }' | jq '.'
}

resume_command() {
  local slug="${1:-}"
  local execute=0
  local agent_override=""
  local keep_alive="false"

  [[ -n "${slug}" ]] || die "resume requires <slug>"
  shift || true

  while (($# > 0)); do
    case "$1" in
      --dry-run)     execute=0 ;;
      --execute)     execute=1 ;;
      --keep-alive)  keep_alive="true" ;;
      --agent)       shift; [[ $# -gt 0 ]] || die "--agent requires a value"; agent_override="$1" ;;
      *)             die "unknown resume flag: $1" ;;
    esac
    shift
  done

  validate_slug "${slug}"

  # Resolve agent family: explicit flag > state.json task > work_item.md
  local agent_family=""
  local state task_status project_path description
  state="$(state_json)"

  if [[ -n "${agent_override}" ]]; then
    agent_family="${agent_override}"
  else
    # Try state.json first (task may still exist even after done)
    local work_item_path
    work_item_path="$(jq -r --arg s "${slug}" '.tasks[$s].work_item_path // empty' <<<"${state}")"
    if [[ -n "${work_item_path}" && -f "${work_item_path}" ]]; then
      agent_family="$(grep '^- agent_family:' "${work_item_path}" | sed 's/^- agent_family: //' | tr -d '[:space:]')" || true
    fi
    # Fallback: check tasks dir directly
    if [[ -z "${agent_family}" ]]; then
      local fallback_path="${ORCHESTRATOR_ROOT}/tasks/${slug}.md"
      if [[ -f "${fallback_path}" ]]; then
        agent_family="$(grep '^- agent_family:' "${fallback_path}" | sed 's/^- agent_family: //' | tr -d '[:space:]')" || true
      fi
    fi
    [[ -n "${agent_family}" ]] || die "cannot determine agent family for '${slug}'. Use --agent claude|codex"
  fi

  case "${agent_family}" in
    claude|codex) ;;
    *) die "--agent must be 'claude' or 'codex', got '${agent_family}'" ;;
  esac

  # Verify the session can be resumed
  local session_exists=0
  if [[ "${agent_family}" == "claude" ]]; then
    # Claude sessions are named with --name <slug>; check projects dir
    if claude --resume "${slug}" --print "exit" >/dev/null 2>&1; then
      session_exists=1
    fi
    # Fallback: assume it exists if work_item was found (--resume will error at runtime if not)
    [[ "${session_exists}" -eq 0 ]] && session_exists=1
  else
    # Codex: check session_index.jsonl for thread_name match
    if grep -q "\"thread_name\":\"${slug}\"" "${HOME}/.codex/session_index.jsonl" 2>/dev/null; then
      session_exists=1
    fi
  fi
  (( session_exists == 1 )) || die "no resumable session found for '${slug}' (family: ${agent_family})"

  # Resolve project path from state or fallback to cwd
  project_path="$(jq -r --arg s "${slug}" '.tasks[$s].project_path // empty' <<<"${state}")"
  [[ -n "${project_path}" ]] || project_path="${PWD}"
  description="$(jq -r --arg s "${slug}" '.tasks[$s].description // "resumed session"' <<<"${state}")"

  # Build the resume command
  local resume_cmd
  if [[ "${agent_family}" == "claude" ]]; then
    resume_cmd="claude --dangerously-skip-permissions --resume ${slug}"
  else
    resume_cmd="codex resume ${slug}"
  fi

  # Plan: compute slot name using plan.sh
  local plan plan_args slot agent_cwd
  plan_args=(
    --root "${ORCHESTRATOR_ROOT}"
    --state-json "${state}"
    --slug "${slug}"
    --description "${description}"
    --cwd "${project_path}"
    --project-name "$(_resolve_project_alias "${project_path}")"
    --agent "${agent_family}"
    --no-worktree
  )
  [[ "${keep_alive}" == "true" ]] && plan_args+=(--keep-alive)
  plan="$("${PLAN_SCRIPT}" "${plan_args[@]}")"

  slot="$(jq -r '.agents[0].slot' <<<"${plan}")"
  agent_cwd="$(jq -r '.agents[0].cwd' <<<"${plan}")"

  # Build spawn preview — override attach_command with resume_cmd
  local spawn_preview
  spawn_preview="$("${SPAWN_EFFECT}" --dry-run "${slot}" "${agent_cwd}")"

  if (( execute == 0 )); then
    jq -n \
      --arg mode "dry-run" \
      --arg slug "${slug}" \
      --arg agent_family "${agent_family}" \
      --arg slot "${slot}" \
      --arg resume_cmd "${resume_cmd}" \
      --arg project_path "${project_path}" \
      --arg keep_alive "${keep_alive}" \
      --argjson spawn "${spawn_preview}" \
      '{
        mode: $mode,
        action: "resume",
        slug: $slug,
        agent_family: $agent_family,
        slot: $slot,
        resume_command: $resume_cmd,
        project_path: $project_path,
        keep_alive: ($keep_alive == "true"),
        effects: { spawn: $spawn }
      }' | jq '.'
    return 0
  fi

  # Execute: spawn surface with --resume baked into the zmx attach command.
  # Set ORCHESTRATOR_AGENT_RESUME so spawn.sh uses `claude --resume <slug>`
  # directly in the zmx attach command, instead of starting a fresh session.
  local spawn_output surface_id target_workspace
  export ORCHESTRATOR_AGENT_RESUME="true" ORCHESTRATOR_TASK_SLUG="${slug}"
  spawn_output="$("${SPAWN_EFFECT}" --execute "${slot}" "${agent_cwd}")"
  unset ORCHESTRATOR_AGENT_RESUME ORCHESTRATOR_TASK_SLUG
  surface_id="$(jq -r '.surface_id // empty' <<<"${spawn_output}")"
  target_workspace="$(jq -r '.target_workspace // empty' <<<"${spawn_output}")"
  [[ -n "${surface_id}" ]] || die "spawn did not return a surface_id"

  # Wait for surface to be ready
  _spawn_wait_max="${ORCHESTRATOR_SPAWN_WAIT:-15}"
  _spawn_waited=0
  _spawn_detected=0
  while (( _spawn_waited < _spawn_wait_max )); do
    if zmx list 2>/dev/null | grep "name=${slot}" | grep -qE 'pid=[0-9]+'; then
      _spawn_detected=1; await_agent_ready "${surface_id}" "${agent_family}" 10; break
    fi
    sleep 1
    (( _spawn_waited++ )) || true
  done
  if (( _spawn_detected == 0 )); then
    die "spawn_wait timeout: session '${slot}' did not boot within ${_spawn_wait_max}s"
  fi

  # Update state.json: re-register task as in_progress
  local now
  now="$(timestamp_utc)"
  local new_state
  new_state="$(
    jq \
      --arg now "${now}" \
      --arg slug "${slug}" \
      --arg slot "${slot}" \
      --arg surface_id "${surface_id}" \
      --arg workspace_id "${target_workspace}" \
      --arg family "${agent_family}" \
      --arg cwd "${agent_cwd}" \
      --argjson keep_alive "$(if [[ "${keep_alive}" == "true" ]]; then echo true; else echo false; fi)" \
      '
      .updated_at = $now
      | .tasks[$slug].status = "in_progress"
      | .tasks[$slug].keep_alive = $keep_alive
      | .tasks[$slug].agents = [$slot]
      | .tasks[$slug].updated_at = $now
      | if .tasks[$slug].completed_at then del(.tasks[$slug].completed_at) else . end
      | .agents[$slot] = {
          slot: $slot,
          family: $family,
          project: (.tasks[$slug].project // ""),
          task: $slug,
          cwd: $cwd,
          status: "running",
          surface_id: $surface_id,
          workspace_id: (if $workspace_id == "" then null else $workspace_id end),
          created_at: $now,
          updated_at: $now
        }
      ' <<<"$(state_json)"
  )"
  write_state_json "${new_state}"
  append_activity "$(
    jq -cn \
      --arg timestamp "${now}" \
      --arg slug "${slug}" \
      --arg slot "${slot}" \
      --arg surface_id "${surface_id}" \
      --arg family "${agent_family}" \
      '{timestamp: $timestamp, event: "task-resumed", slug: $slug, slot: $slot, surface_id: $surface_id, family: $family}'
  )"

  jq -n \
    --arg mode "execute" \
    --arg slug "${slug}" \
    --arg agent_family "${agent_family}" \
    --arg slot "${slot}" \
    --arg surface_id "${surface_id}" \
    --arg resume_cmd "${resume_cmd}" \
    --arg keep_alive "${keep_alive}" \
    --argjson spawn "${spawn_output}" \
    '{
      mode: $mode,
      action: "resume",
      slug: $slug,
      agent_family: $agent_family,
      slot: $slot,
      surface_id: $surface_id,
      resume_command: $resume_cmd,
      keep_alive: ($keep_alive == "true"),
      effects: { spawn: $spawn }
    }' | jq '.'
}

gc_command() {
  local execute=0 force=0
  while (($# > 0)); do
    case "$1" in
      --dry-run)  execute=0 ;;
      --execute)  execute=1 ;;
      --force)    force=1 ;;
      *) die "unknown gc flag: $1" ;;
    esac
    shift
  done

  local state now_epoch
  state="$(state_json)"
  now_epoch="$(date +%s)"

  # Snapshot zmx list once (avoids N calls)
  local zmx_snapshot=""
  if command -v zmx &>/dev/null; then
    zmx_snapshot="$(zmx list 2>/dev/null || true)"
  fi
  local cmux_snapshot=""
  cmux_snapshot="$(cmux_surface_snapshot)"

  local inspected=0 cleaned=0 failed_marked=0 skipped=0
  local details="[]"

  # Iterate all tasks in state.json
  local slugs
  slugs="$(jq -r '.tasks | keys[]' <<<"${state}" 2>/dev/null)" || true

  for slug in ${slugs}; do
    local task_status agent_slot agent_surface_id
    task_status="$(jq -r --arg s "${slug}" '.tasks[$s].status // "unknown"' <<<"${state}")"
    agent_slot="$(jq -r --arg s "${slug}" '.tasks[$s].agents[0] // empty' <<<"${state}")"
    agent_surface_id="$(jq -r --arg s "${slug}" '.tasks[$s].surface_id // empty' <<<"${state}")"
    if [[ -z "${agent_surface_id}" && -n "${agent_slot}" ]]; then
      agent_surface_id="$(jq -r --arg slot "${agent_slot}" '.agents[$slot].surface_id // empty' <<<"${state}")"
    fi
    (( inspected++ )) || true

    # Skip planned tasks unless forced. 'planned' is a short window between
    # state write and spawn completion — forced reconcile cleans up state
    # entries whose spawn failed and left no resources behind.
    if [[ "${task_status}" == "planned" ]]; then
      if [[ "${force}" != "1" ]]; then
        (( skipped++ )) || true
        continue
      fi
    fi

    # Check zmx status from snapshot (no extra calls)
    local zmx_status="gone" zmx_clients=0
    if [[ -n "${agent_slot}" && -n "${zmx_snapshot}" ]]; then
      local zmx_line
      zmx_line="$(grep "name=${agent_slot}" <<<"${zmx_snapshot}" || true)"
      if [[ -n "${zmx_line}" ]]; then
        if grep -q "unreachable" <<<"${zmx_line}"; then
          zmx_status="unreachable"
        else
          zmx_status="alive"
          zmx_clients="$(sed -n 's/.*clients=\([0-9]*\).*/\1/p' <<<"${zmx_line}" || echo 0)"
        fi
      fi
    fi

    local action="skip"
    local task_keep_alive
    local surface_alive=0
    task_keep_alive="$(jq -r --arg s "${slug}" '.tasks[$s].keep_alive // false' <<<"${state}")"
    if cmux_surface_exists "${cmux_snapshot}" "${agent_surface_id}"; then
      surface_alive=1
    fi

    case "${task_status}" in
      done|cleanup|failed)
        # Only clean up if zmx session is actually gone. If zmx reports
        # alive, the state.json is stale — don't kill a running worker.
        if [[ "${zmx_status}" == "alive" && "${force}" != "1" ]]; then
          action="skip"
        else
          action="cleanup"
        fi
        ;;
      in_progress)
        # Resource-based reconcile: if state says in_progress but zmx is
        # gone, the worker has exited (crash or normal) and the state is
        # stale. Clean it up so new dispatches with the same slug can run.
        if [[ "${zmx_status}" == "gone" ]]; then
          action="cleanup"
        else
          action="skip"
        fi
        ;;
      planned)
        # Reached only under --force. Always cleanup (spawn failed).
        action="cleanup"
        ;;
    esac

    if [[ "${action}" == "skip" ]]; then
      (( skipped++ )) || true
      continue
    fi

    details="$(jq --arg slug "${slug}" --arg status "${task_status}" \
      --arg zmx "${zmx_status}" --arg action "${action}" --arg surface "${agent_surface_id}" \
      --argjson surface_alive "$( (( surface_alive == 1 )) && printf 'true' || printf 'false' )" \
      '. += [{slug:$slug, task_status:$status, zmx_status:$zmx, action:$action, surface_id:($surface // null), surface_alive:$surface_alive}]' <<<"${details}")"

    if (( execute == 0 )); then
      continue
    fi

    if [[ "${action}" == "cleanup" ]]; then
      # Set workspace from state.json so cleanup closes the correct surface,
      # not the orchestrator's own workspace.
      local _agent_ws=""
      if [[ -n "${agent_slot}" ]]; then
        _agent_ws="$(jq -r --arg slot "${agent_slot}" '.agents[$slot].workspace_id // empty' <<<"${state}")"
      fi
      ORCHESTRATOR_TARGET_WORKSPACE_ID="${_agent_ws}" cleanup_command "${slug}" 1 >/dev/null 2>&1 || true
      # Also remove the task entry from state.json
      local _gc_state
      _gc_state="$(jq --arg s "${slug}" --arg now "$(timestamp_utc)" '
        .updated_at = $now | del(.tasks[$s])
      ' <<<"$(state_json)")"
      write_state_json "${_gc_state}"
      (( cleaned++ )) || true
    elif [[ "${action}" == "mark-failed" ]]; then
      local new_state
      new_state="$(jq --arg s "${slug}" --arg now "$(timestamp_utc)" \
        --arg slot "${agent_slot}" '
        .updated_at = $now
        | .tasks[$s].status = "failed"
        | .tasks[$s].updated_at = $now
        | (if $slot != "" then .agents[$slot].status = "crashed" | .agents[$slot].updated_at = $now else . end)
        ' <<<"$(state_json)")"
      write_state_json "${new_state}"
      (( failed_marked++ )) || true
    fi
  done

  # --- Orphan detection: resources that exist but are NOT in state.json ---
  local orphan_zmx=0 orphan_worktree=0 orphan_branch=0
  local orphan_details="[]"

  # Compute project slug from current directory for scoping orphan detection
  local _gc_project_slug
  _gc_project_slug="$(basename "${PWD}" | tr '[:upper:]' '[:lower:]' \
    | sed -E 's/[^a-z0-9]+/-/g; s/^-+//; s/-+$//; s/-{2,}/-/g')"

  # Known agent slots from state
  local known_agents
  known_agents="$(jq -r '.agents // {} | keys[]' <<<"${state}" 2>/dev/null)" || true

  # Known worktree paths from state
  local known_worktrees
  known_worktrees="$(jq -r '[.tasks // {} | .[].worktree_path // empty] | .[]' <<<"${state}" 2>/dev/null)" || true

  # Known dispatch branches from state
  local known_branches
  known_branches="$(jq -r '[.tasks // {} | .[].worktree_branch // empty] | .[]' <<<"${state}" 2>/dev/null)" || true

  # Snapshot git's live worktree registry once. State mappings can stale,
  # but a branch/path still attached to a registered worktree remains
  # authoritative and must block orphan cleanup.
  local _gc_worktree_snapshot
  _gc_worktree_snapshot="$(git_worktree_snapshot "${PWD}")"

  # 1. Orphan zmx sessions: report only.
  #    Never kill sessions or delete sockets solely because state.json does not
  #    reference them. User dialogue sessions can share the project slug.
  if [[ -n "${zmx_snapshot}" ]]; then
    local zmx_names
    zmx_names="$(sed -n 's/.*name=\([^ ]*\).*/\1/p' <<<"${zmx_snapshot}" || true)"
    for zname in ${zmx_names}; do
      # Only process sessions belonging to this project
      [[ "${zname}" == *"-${_gc_project_slug}-"* ]] || continue
      if ! grep -qxF "${zname}" <<<"${known_agents}" 2>/dev/null; then
        # Check if this orphan is unreachable (stale socket)
        local _orphan_zmx_line
        _orphan_zmx_line="$(grep "name=${zname}" <<<"${zmx_snapshot}" || true)"
        local _orphan_unreachable=0
        grep -q "unreachable" <<<"${_orphan_zmx_line}" && _orphan_unreachable=1

        (( orphan_zmx++ )) || true
        orphan_details="$(jq --arg name "${zname}" --arg type "zmx_session" \
          --arg unreachable "$(( _orphan_unreachable ))" \
          '. += [{type:$type, name:$name, action:"report-only", unreachable:($unreachable == "1")}]' \
          <<<"${orphan_details}")"
      fi
    done
  fi

  # 2. Orphan worktrees: .worktrees/dispatch-* dirs not in state
  local worktrees_dir="${PWD}/.worktrees"
  if [[ -d "${worktrees_dir}" ]]; then
    # Snapshot signals that mark a worktree as still-needed even when it
    # is not referenced from state.json. Missing state only means "lookup
    # stale"; live git/zmx signals still win and must skip deletion.
    local _gc_zmx_snapshot
    _gc_zmx_snapshot=""
    if command -v zmx >/dev/null 2>&1; then
      _gc_zmx_snapshot="$(zmx_snapshot)"
    fi
    local wt_dir
    for wt_dir in "${worktrees_dir}"/dispatch-*; do
      [[ -d "${wt_dir}" ]] || continue
      if ! grep -qxF "${wt_dir}" <<<"${known_worktrees}" 2>/dev/null; then
        # Protect: registered git worktree or zmx start_dir match.
        if git_worktree_path_registered "${_gc_worktree_snapshot}" "${wt_dir}"; then
          continue
        fi
        if zmx_snapshot_has_start_dir "${_gc_zmx_snapshot}" "${wt_dir}"; then
          continue
        fi
        (( orphan_worktree++ )) || true
        orphan_details="$(jq --arg path "${wt_dir}" --arg type "worktree" \
          '. += [{type:$type, path:$path, action:"remove"}]' <<<"${orphan_details}")"
        if (( execute )); then
          local orphan_worktree_result="worktree-remove-failed"
          if git worktree remove --force "${wt_dir}" 2>/dev/null; then
            orphan_worktree_result="worktree-removed"
          elif rm -rf "${wt_dir}" 2>/dev/null; then
            orphan_worktree_result="worktree-force-removed"
          fi
          append_activity "$(jq -nc \
            --arg ts "$(timestamp_utc)" \
            --arg path "${wt_dir}" \
            --arg result "${orphan_worktree_result}" \
            '{ts:$ts, event:"gc.orphan-worktree", path:$path, result:$result}')"
        fi
      fi
    done
  fi

  # 3. Orphan dispatch branches: dispatch/* branches not in state
  local git_dispatch_branches
  git_dispatch_branches="$(git branch --list 'dispatch/*' --format='%(refname:short)' 2>/dev/null)" || true
  for br in ${git_dispatch_branches}; do
    if ! grep -qxF "${br}" <<<"${known_branches}" 2>/dev/null; then
      # A branch still attached to any registered worktree is live even if
      # state.json forgot the mapping; never delete it from periodic gc.
      if git_worktree_branch_registered "${_gc_worktree_snapshot}" "${br}"; then
        continue
      fi
      (( orphan_branch++ )) || true
      orphan_details="$(jq --arg branch "${br}" --arg type "branch" \
        '. += [{type:$type, branch:$branch, action:"delete"}]' <<<"${orphan_details}")"
      if (( execute )); then
        local orphan_branch_result="branch-delete-failed"
        if git branch -D "${br}" 2>/dev/null; then
          orphan_branch_result="branch-deleted"
        fi
        append_activity "$(jq -nc \
          --arg ts "$(timestamp_utc)" \
          --arg branch "${br}" \
          --arg result "${orphan_branch_result}" \
          '{ts:$ts, event:"gc.orphan-branch", branch:$branch, result:$result}')"
      fi
    fi
  done

  # 4. Orphan cmux surfaces: surfaces whose title contains a dispatch worktree
  #    path that no longer exists in state or on disk
  local orphan_surface=0
  if command -v cmux &>/dev/null; then
    local known_surface_ids
    known_surface_ids="$(jq -r '[.agents // {} | .[].surface_id // empty] | .[]' <<<"${state}" 2>/dev/null)" || true

    # Get all surfaces whose title contains .worktrees/dispatch- for this project.
    # Parse workspace context from cmux tree to pass correct --workspace.
    local _cmux_tree
    _cmux_tree="$(cmux tree --all 2>/dev/null || true)"
    if [[ -n "${_cmux_tree}" ]]; then
      local _current_ws=""
      while IFS= read -r _tree_line; do
        # Track current workspace from tree output
        if [[ "${_tree_line}" =~ workspace\ (workspace:[0-9]+) ]]; then
          _current_ws="${BASH_REMATCH[1]}"
        fi
        # Find surfaces referencing dispatch worktrees
        if [[ "${_tree_line}" =~ surface\ (surface:[0-9]+).*\.worktrees/dispatch- ]]; then
          local _surf="${BASH_REMATCH[1]}"
          # Skip if still known in state
          if grep -qxF "${_surf}" <<<"${known_surface_ids}" 2>/dev/null; then
            continue
          fi
          (( orphan_surface++ )) || true
          orphan_details="$(jq --arg surface "${_surf}" --arg ws "${_current_ws}" --arg type "cmux_surface" \
            '. += [{type:$type, surface:$surface, workspace:$ws, action:"close"}]' <<<"${orphan_details}")"
          if (( execute )); then
            local _close_args=(--surface "${_surf}")
            [[ -n "${_current_ws}" ]] && _close_args+=(--workspace "${_current_ws}")
            cmux close-surface "${_close_args[@]}" >/dev/null 2>&1 || true
          fi
        fi
      done <<<"${_cmux_tree}"
    fi
  fi

  jq -n \
    --arg mode "$(if (( execute )); then echo execute; else echo dry-run; fi)" \
    --argjson inspected "${inspected}" \
    --argjson cleaned "${cleaned}" \
    --argjson failed_marked "${failed_marked}" \
    --argjson skipped "${skipped}" \
    --argjson details "${details}" \
    --argjson orphan_zmx "${orphan_zmx}" \
    --argjson orphan_worktree "${orphan_worktree}" \
    --argjson orphan_branch "${orphan_branch}" \
    --argjson orphan_surface "${orphan_surface}" \
    --argjson orphan_details "${orphan_details}" \
    '{mode:$mode, inspected:$inspected, cleaned:$cleaned, failed_marked:$failed_marked, skipped:$skipped, details:$details,
      orphans:{zmx_sessions:$orphan_zmx, worktrees:$orphan_worktree, branches:$orphan_branch, surfaces:$orphan_surface, details:$orphan_details}}'
}

# tidy_command — resource-based cleanup for finished dispatch worktrees.
#
# Unlike gc (which consults state.json), tidy uses the filesystem + zmx as
# the source of truth:
#   - Scan .worktrees/dispatch-* directories
#   - Treat any registered git worktree as explicit-cleanup only
#   - Treat any zmx session whose start_dir matches the path as live
#   - Remove only paths with neither live signal
#
# Accepts no args → list all candidates (dry-run).
# With --execute → remove candidates (or the specific slugs passed as args).
tidy_command() {
  local execute=0
  local selection_all=0
  local slugs_arg=()
  while (($# > 0)); do
    case "$1" in
      --dry-run)  execute=0 ;;
      --execute)  execute=1 ;;
      --all)      selection_all=1 ;;
      -*)         die "unknown tidy flag: $1" ;;
      *)          slugs_arg+=("$1") ;;
    esac
    shift
  done

  local project_cwd="${PWD}"
  local worktrees_dir="${project_cwd}/.worktrees"
  local zmx_snapshot=""
  zmx_snapshot="$(zmx_snapshot)"

  # git worktree registry snapshot — any directory currently registered as
  # a worktree was created intentionally and must not be reaped behind
  # git's back. Cleanup is the explicit responsibility of `done` /
  # `cleanup`, not the periodic tidy. Conservative-by-design: better to
  # leak an unused worktree than to nuke a recovered/manually-recreated
  # one (see .collab/hook-failure-observe-* for the original incident).
  local worktree_registry=""
  worktree_registry="$(git_worktree_snapshot "${project_cwd}")"

  # Gather candidates from the filesystem
  local candidates="[]"
  if [[ -d "${worktrees_dir}" ]]; then
    local wt_dir
    for wt_dir in "${worktrees_dir}"/dispatch-*; do
      [[ -d "${wt_dir}" ]] || continue
      local wt_name
      wt_name="$(basename "${wt_dir}")"

      # Refuse to remove the worktree we are currently executing inside.
      # tidy can be invoked from a worker session; without this guard a
      # caller could nuke its own CWD mid-call.
      case "${PWD}" in
        "${wt_dir}"|"${wt_dir}/"*) continue ;;
      esac

      # Path convention: dispatch-<slug>-<agent>-<N>
      # Derive slot: <agent>-<project>-<slug>-<N>
      # where agent ∈ {claude, codex}
      local slug="" agent="" index=""
      if [[ "${wt_name}" =~ ^dispatch-(.+)-(claude|codex)-([0-9]+)$ ]]; then
        slug="${BASH_REMATCH[1]}"
        agent="${BASH_REMATCH[2]}"
        index="${BASH_REMATCH[3]}"
      else
        # Unparseable name — mark as orphan
        candidates="$(jq --arg path "${wt_dir}" --arg name "${wt_name}" \
          '. += [{path:$path, name:$name, slug:"?", agent:"?", zmx_status:"unknown", classification:"orphan"}]' \
          <<<"${candidates}")"
        continue
      fi

      local project_slug
      project_slug="$(basename "${project_cwd}")"
      local slot="${agent}-${project_slug}-${slug}-${index}"

      # Additional protection signals (any one keeps the worktree alive):
      # - registered git worktree (intentional; cleanup belongs to done/cleanup)
      # - zmx session whose start_dir is exactly this path (truncation-proof)
      local registered_in_git=0 zmx_start_dir_match=0
      if git_worktree_path_registered "${worktree_registry}" "${wt_dir}"; then
        registered_in_git=1
      fi
      if zmx_snapshot_has_start_dir "${zmx_snapshot}" "${wt_dir}"; then
        zmx_start_dir_match=1
      fi
      local zmx_status="gone"
      (( zmx_start_dir_match == 1 )) && zmx_status="alive"

      # Classification — live signals only. Registered git worktrees are
      # explicit-cleanup only, and zmx start_dir is the authoritative
      # owner signal even when slot names drift due to truncation.
      local classification
      if (( registered_in_git == 1 )) || (( zmx_start_dir_match == 1 )); then
        classification="running"
      else
        classification="done"
      fi

      # Slug filter (if user passed specific slugs)
      if (( ${#slugs_arg[@]} > 0 )) && (( selection_all == 0 )); then
        local matched=0
        local s
        for s in "${slugs_arg[@]}"; do
          [[ "${slug}" == "${s}" ]] && { matched=1; break; }
        done
        (( matched == 1 )) || continue
      fi

      local branch="dispatch/${slug}-${agent}-${index}"
      candidates="$(jq \
        --arg path "${wt_dir}" \
        --arg name "${wt_name}" \
        --arg slug "${slug}" \
        --arg agent "${agent}" \
        --arg slot "${slot}" \
        --arg branch "${branch}" \
        --arg zmx_status "${zmx_status}" \
        --arg classification "${classification}" \
        '. += [{path:$path, name:$name, slug:$slug, agent:$agent, slot:$slot, branch:$branch, zmx_status:$zmx_status, classification:$classification}]' \
        <<<"${candidates}")"
    done
  fi

  # Execute cleanup for done/orphan candidates
  local cleaned=0 skipped=0 actions="[]"
  local n
  n="$(jq 'length' <<<"${candidates}")"
  local i=0
  while (( i < n )); do
    local item cls path branch
    item="$(jq ".[${i}]" <<<"${candidates}")"
    cls="$(jq -r '.classification' <<<"${item}")"
    path="$(jq -r '.path' <<<"${item}")"
    branch="$(jq -r '.branch // empty' <<<"${item}")"

    if [[ "${cls}" == "running" ]]; then
      (( skipped++ )) || true
      i=$((i + 1))
      continue
    fi

    local action_result="planned"
    if (( execute == 1 )); then
      # Worktree removal is intentionally non-destructive: run only the
      # native git operation and stop on refusal. The previous `rm -rf`
      # fallback silently destroyed live workers' CWDs (and the Claude
      # session JSONL parent path that ties resume to that CWD), so we
      # remove it. If git refuses (typically: untracked files inside —
      # itself a strong "still in use" signal), we log and let the
      # operator decide.
      if git -C "${project_cwd}" worktree remove "${path}" 2>/dev/null; then
        action_result="worktree-removed"
      else
        action_result="worktree-remove-refused"
      fi

      # Delete branch if present (best effort)
      if [[ -n "${branch}" ]]; then
        git -C "${project_cwd}" branch -D "${branch}" 2>/dev/null || true
      fi

      # Audit trail: persist every removal so destructive tidy actions
      # are reviewable post-hoc (the daemon's periodic invocation pipes
      # tidy stdout to /dev/null).
      append_activity "$(jq -nc \
        --arg ts "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
        --arg event "tidy.cleanup" \
        --argjson item "${item}" \
        --arg result "${action_result}" \
        '{ts:$ts, event:$event, action:($item + {action_result:$result})}')"

      (( cleaned++ )) || true
    fi

    actions="$(jq --argjson item "${item}" --arg result "${action_result}" \
      '. += [($item + {action_result:$result})]' <<<"${actions}")"
    i=$((i + 1))
  done

  local mode='dry-run'
  (( execute == 1 )) && mode='execute'

  jq -n \
    --arg mode "${mode}" \
    --argjson inspected "${n}" \
    --argjson cleaned "${cleaned}" \
    --argjson skipped "${skipped}" \
    --argjson candidates "${candidates}" \
    --argjson actions "${actions}" \
    '{mode:$mode, inspected:$inspected, cleaned:$cleaned, skipped_running:$skipped,
      candidates:$candidates, actions:$actions}'
}

_conductor_signal_cleanup() {
  # Release the state lock if this process is holding it, then exit with
  # the conventional 128+signal code. Without this trap, Ctrl-C between
  # acquire and release would leave locks/state.lockdir stale — and any
  # concurrent reader would then see a perma-held lock until the 10s
  # stale-detect path kicks in.
  _release_state_lock 2>/dev/null || true
  trap - INT TERM
  exit 130
}
trap _conductor_signal_cleanup INT TERM

main() {
  local command="${1:-help}"
  shift || true

  case "${command}" in
    dispatch)
      dispatch_command "$@"
      ;;
    collab)
      collab_command "$@"
      ;;
    resume)
      resume_command "$@"
      ;;
    list)
      list_command "$@"
      ;;
    status)
      status_command "$@"
      ;;
    done)
      done_command "$@"
      ;;
    cleanup)
      local _slug="${1:-}"
      shift || true
      cleanup_command "${_slug}" "$@"
      ;;
    gc)
      gc_command "$@"
      ;;
    tidy)
      tidy_command "$@"
      ;;
    help|--help|-h)
      usage
      ;;
    *)
      die "unknown subcommand: ${command}"
      ;;
  esac
}

main "$@"
