#!/usr/bin/env bash

set -euo pipefail
IFS=$'\n\t'

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
ORCHESTRATOR_ROOT="${ORCHESTRATOR_ROOT:-${HOME}/.orchestrator}"

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
  scripts/conductor.sh dispatch <slug> "<description>" [--dry-run|--execute] [--agent claude|codex] [--no-worktree] [--collab] [--advisor-mode none|plan|review] [--executor-tier default|capable|fast]
  scripts/conductor.sh list
  scripts/conductor.sh status [<slug>]
  scripts/conductor.sh done <slug> [--dry-run|--execute] [--cleanup]
  scripts/conductor.sh cleanup <slug> [--dry-run|--execute]
  scripts/conductor.sh help

Notes:
  - `dispatch`, `done`, and `cleanup` default to --dry-run.
  - `--execute` is required to mutate state.
  - `done` = state transition only (in_progress → done). Resources preserved.
  - `cleanup` = remove surface, zmx session, worktree, branch, agent from state.
  - `done --cleanup` = both in one call (backwards compat for standalone dispatch).
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

render_work_item_markdown() {
  local slug="$1"
  local description="$2"
  local agent_family="${3:-claude}"
  local advisor_mode="${4:-none}"
  local executor_tier="${5:-default}"
  local is_collab="${6:-false}"
  local completion_prefix='/'

  if [[ "${agent_family}" == "codex" ]]; then
    completion_prefix='$'
  fi

  local completion_instruction
  if [[ "${is_collab}" == "true" ]]; then
    completion_instruction="- **Do NOT mark this task done.** This is a collab task — commit your work and wait. The caller session will handle cross-review, merge, and cleanup."
  else
    completion_instruction="- When done, run: \`bash scripts/conductor.sh done ${slug} --cleanup --execute\`"
  fi

  cat <<EOF
# Work Item: ${slug}

- **Status**: in-progress
- **Created**: $(timestamp_utc)
- **Project Root**: ${PWD}

## Goal

${description}

## Request Metadata

- agent_family: ${agent_family}
- advisor_mode: ${advisor_mode}
- executor_tier: ${executor_tier}

## Constraints

- Keep the base session untouched; this task runs in a sibling slot only.
- Treat this file as a scoped delegation brief, not a full handoff entry.
${completion_instruction}

## Definition of Done

- Implement or investigate the delegated work described above.
- Leave the repo in a reviewable state with a concise summary of outcomes.
$(if [[ "${is_collab}" == "true" ]]; then
  echo "- Commit all changes to the worktree branch. Do NOT merge to main."
  echo "- Stay alive after committing — the caller will drive cross-review."
else
  echo "- Mark the task done through the conductor when the sibling session finishes."
fi)

## Key Files

- ${PWD}
- ${SCRIPT_DIR}/conductor.sh

## Notes

- Stage 0 does not automate merge or dependency management yet.
$(if [[ "${is_collab}" == "true" ]]; then
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

with_state_lock() {
  mkdir -p "$(dirname "${STATE_LOCK}")"
  if command -v flock &>/dev/null; then
    flock -w 10 "${STATE_LOCK}" "$@"
  else
    "$@"
  fi
}

state_json() {
  with_state_lock "${STATE_READ}" --root "${ORCHESTRATOR_ROOT}"
}

write_state_json() {
  with_state_lock atomic_write "${ORCHESTRATOR_ROOT}/state.json" "$1"
}

task_exists_in_state() {
  local slug="$1"
  local state="$2"
  jq -e --arg slug "${slug}" '.tasks[$slug] != null' <<<"${state}" >/dev/null
}

dispatch_command() {
  local slug="${1:-}"
  local description="${2:-}"
  local execute=0
  local no_worktree=0
  local is_collab="false"
  local agent_override=""
  local advisor_mode="none"
  local executor_tier="default"
  local state plan slot work_item_path done_report_path plan_output spawn_preview inject_preview worktree_preview
  local now planned_state spawn_output inject_output surface_id running_state activity_entry agent_family
  local agent_cwd worktree_required worktree_path worktree_branch worktree_output

  [[ -n "${slug}" ]] || die "dispatch requires <slug>"
  [[ -n "${description}" ]] || die "dispatch requires <description>"
  shift 2 || true

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
      --collab)
        is_collab="true"
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
      *)
        die "unknown dispatch flag: $1"
        ;;
    esac
    shift
  done

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
    --cwd "${PWD}"
    --project-name "$(basename "${PWD}")"
    --agent "${agent_family}"
    --advisor-mode "${advisor_mode}"
    --executor-tier "${executor_tier}"
  )
  (( no_worktree == 1 )) && plan_args+=(--no-worktree)
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
    worktree_preview="$("${CREATE_WORKTREE_EFFECT}" --dry-run "${PWD}" "${worktree_path}" "${worktree_branch}" HEAD)"
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

  atomic_write "${work_item_path}" "$(render_work_item_markdown "${slug}" "${description}" "${agent_family}" "${advisor_mode}" "${executor_tier}" "${is_collab}")"
  now="$(timestamp_utc)"
  planned_state="$(
    "${STATE_TRANSITION}" \
      --mode dispatch \
      --now "${now}" \
      --state-json "${state}" \
      --plan-json "${plan}"
  )"
  write_state_json "${planned_state}"
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

  if [[ "${worktree_required}" == "true" ]]; then
    worktree_output="$("${CREATE_WORKTREE_EFFECT}" --execute "${PWD}" "${worktree_path}" "${worktree_branch}" HEAD)"
  else
    worktree_output='{"action":"create-worktree","mode":"skipped","reason":"--no-worktree"}'
  fi
  spawn_output="$("${SPAWN_EFFECT}" --execute "${slot}" "${agent_cwd}")"
  surface_id="$(jq -r '.surface_id // empty' <<<"${spawn_output}")"
  target_workspace="$(jq -r '.target_workspace // empty' <<<"${spawn_output}")"
  [[ -n "${surface_id}" ]] || die "spawn did not return a surface_id"

  # Wait for the spawned agent to boot before injecting the work item prompt.
  # Poll zmx first (fast path); fall back to ps if zmx is unreachable.
  # Override max wait via ORCHESTRATOR_SPAWN_WAIT (seconds, default 30).
  _spawn_wait_max="${ORCHESTRATOR_SPAWN_WAIT:-30}"
  _spawn_waited=0
  _spawn_detected=0
  while (( _spawn_waited < _spawn_wait_max )); do
    if zmx list 2>/dev/null | grep "name=${slot}" | grep -qE 'pid=[0-9]+'; then
      _spawn_detected=1; sleep 3; break
    fi
    if pgrep -f "zmx attach ${slot}" >/dev/null 2>&1; then
      _spawn_detected=1; sleep 3; break
    fi
    sleep 1
    (( _spawn_waited++ )) || true
  done
  if (( _spawn_detected == 0 )); then
    die "spawn_wait timeout: session '${slot}' did not boot within ${_spawn_wait_max}s"
  fi

  inject_output="$("${INJECT_EFFECT}" --execute --family "${agent_family}" "${surface_id}" "${work_item_path}")"
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
      ' <<<"${planned_state}"
  )"
  write_state_json "${running_state}"
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
  local state task_status task_path done_report_path description project_slug plan done_state now

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
    jq -n --argjson plan "${plan}" --argjson cleanup "$( (( do_cleanup == 1 )) && echo true || echo false)" \
      '{mode:"dry-run", plan:$plan, cleanup_after_done:$cleanup, note:"done = state transition only. Resources (surface, worktree, agent) are preserved. Use --cleanup or separate cleanup command to remove them."}'  | jq '.'
    return 0
  fi

  # State transition: in_progress → done (no resource cleanup)
  atomic_write "${done_report_path}" "$(render_done_report_markdown "${slug}" "${description}" "${task_path}")"
  now="$(timestamp_utc)"
  done_state="$(
    "${STATE_TRANSITION}" \
      --mode done \
      --now "${now}" \
      --state-json "${state}" \
      --plan-json "${plan}"
  )"
  write_state_json "${done_state}"
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
  local state task_status project_path worktree_path worktree_branch agent_slot agent_surface_id
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
        *)          die "unknown cleanup flag: $1" ;;
      esac
      shift
    done
    execute="${do_execute}"
  fi

  state="$(state_json)"
  task_exists_in_state "${slug}" "${state}" || die "task slug '${slug}' does not exist"
  task_status="$(jq -r --arg slug "${slug}" '.tasks[$slug].status // "missing"' <<<"${state}")"

  project_path="$(jq -r --arg slug "${slug}" '.tasks[$slug].project_path // empty' <<<"${state}")"
  worktree_path="$(jq -r --arg slug "${slug}" '.tasks[$slug].worktree_path // empty' <<<"${state}")"
  worktree_branch="$(jq -r --arg slug "${slug}" '.tasks[$slug].worktree_branch // empty' <<<"${state}")"
  agent_slot="$(jq -r --arg slug "${slug}" '.tasks[$slug].agents[0] // empty' <<<"${state}")"
  agent_surface_id=""
  if [[ -n "${agent_slot}" ]]; then
    agent_surface_id="$(jq -r --arg slot "${agent_slot}" '.agents[$slot].surface_id // empty' <<<"${state}")"
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

  # 1. Close cmux surface (before zmx kill — surface needs session alive to identify)
  surface_cleanup_output='{"action":"surface-cleanup","mode":"skipped"}'
  if [[ -n "${agent_surface_id}" ]] && command -v cmux >/dev/null 2>&1; then
    local ws_for_close="${ORCHESTRATOR_TARGET_WORKSPACE_ID:-${CMUX_WORKSPACE_ID:-}}"
    local close_args=(--surface "${agent_surface_id}")
    [[ -n "${ws_for_close}" ]] && close_args+=(--workspace "${ws_for_close}")
    cmux close-surface "${close_args[@]}" >/dev/null 2>&1 || true
    surface_cleanup_output="$(jq -n --arg surface "${agent_surface_id}" '{action:"close-surface",mode:"execute",surface:$surface}')"
  fi

  # 2. Kill zmx session
  if [[ -n "${agent_slot}" ]] && command -v zmx >/dev/null 2>&1; then
    zmx kill "${agent_slot}" >/dev/null 2>&1 || true
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
  fi

  # 4. Remove agent from state.json
  if [[ -n "${agent_slot}" ]]; then
    local now
    now="$(timestamp_utc)"
    local new_state
    new_state="$(jq --arg slot "${agent_slot}" --arg slug "${slug}" --arg now "${now}" '
      .updated_at = $now
      | del(.agents[$slot])
      | .tasks[$slug].agents = (.tasks[$slug].agents // [] | map(select(. != $slot)))
      | .tasks[$slug].updated_at = $now
    ' <<<"$(state_json)")"
    write_state_json "${new_state}"
    append_activity "$(jq -cn --arg timestamp "$(timestamp_utc)" --arg slug "${slug}" --arg slot "${agent_slot}" \
      '{timestamp:$timestamp, event:"task-cleanup", slug:$slug, slot:$slot}')"
  fi

  jq -n \
    --arg slug "${slug}" \
    --argjson surface "${surface_cleanup_output}" \
    --argjson worktree "${worktree_cleanup_output}" \
    '{mode:"execute", action:"cleanup", slug:$slug, effects:{surface:$surface, worktree:$worktree}}' | jq '.'
}

main() {
  local command="${1:-help}"
  shift || true

  case "${command}" in
    dispatch)
      dispatch_command "$@"
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
    help|--help|-h)
      usage
      ;;
    *)
      die "unknown subcommand: ${command}"
      ;;
  esac
}

main "$@"
