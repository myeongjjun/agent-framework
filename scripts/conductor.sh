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
  scripts/conductor.sh dispatch <slug> "<description>" [--dry-run|--execute] [--agent claude|codex] [--no-worktree]
  scripts/conductor.sh list
  scripts/conductor.sh status [<slug>]
  scripts/conductor.sh done <slug> [--dry-run|--execute] [--keep-worktree] [--keep-surface] [--keep-branch]
  scripts/conductor.sh help

Notes:
  - `dispatch` and `done` are destructive and default to --dry-run.
  - `--execute` is required to mutate ~/.claude/orchestrator/.
  - Stage 0 intentionally keeps Opus orchestration as a documented TODO stub.
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
  local completion_prefix='/'

  if [[ "${agent_family}" == "codex" ]]; then
    completion_prefix='$'
  fi

  cat <<EOF
# Work Item: ${slug}

- **Status**: in-progress
- **Created**: $(timestamp_utc)
- **Project Root**: ${PWD}

## Goal

${description}

## Constraints

- Keep the base session untouched; this task runs in a sibling slot only.
- Treat this file as a scoped delegation brief, not a full handoff entry.
- Report completion with \`${completion_prefix}dispatch-done ${slug}\`.

## Definition of Done

- Implement or investigate the delegated work described above.
- Leave the repo in a reviewable state with a concise summary of outcomes.
- Mark the task done through the conductor when the sibling session finishes.

## Key Files

- ${PWD}
- ${SCRIPT_DIR}/conductor.sh

## Notes

- Stage 0 does not automate merge or dependency management yet.
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

state_json() {
  "${STATE_READ}" --root "${ORCHESTRATOR_ROOT}"
}

write_state_json() {
  atomic_write "${ORCHESTRATOR_ROOT}/state.json" "$1"
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
  local agent_override=""
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
      --agent)
        shift
        [[ $# -gt 0 ]] || die "--agent requires a value (claude|codex)"
        agent_override="$1"
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

  atomic_write "${work_item_path}" "$(render_work_item_markdown "${slug}" "${description}" "${agent_family}")"
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
      '{timestamp: $timestamp, event: "dispatch-planned", slug: $slug, slot: $slot, description: $description}'
  )"

  if [[ "${worktree_required}" == "true" ]]; then
    worktree_output="$("${CREATE_WORKTREE_EFFECT}" --execute "${PWD}" "${worktree_path}" "${worktree_branch}" HEAD)"
  else
    worktree_output='{"action":"create-worktree","mode":"skipped","reason":"--no-worktree"}'
  fi
  spawn_output="$("${SPAWN_EFFECT}" --execute "${slot}" "${agent_cwd}")"
  surface_id="$(jq -r '.surface_id // empty' <<<"${spawn_output}")"
  [[ -n "${surface_id}" ]] || die "spawn did not return a surface_id"

  # Wait for the spawned agent (claude|codex) to finish booting before we
  # inject /takeover-task. Without this, the inject text falls into the
  # shell before the agent prompt exists, and is interpreted as a shell
  # command (command-not-found). 10s empirically matches handoff-rotate.sh.
  # Override via ORCHESTRATOR_SPAWN_WAIT (seconds).
  sleep "${ORCHESTRATOR_SPAWN_WAIT:-10}"

  inject_output="$("${INJECT_EFFECT}" --execute --family "${agent_family}" "${surface_id}" "${work_item_path}")"
  running_state="$(
    jq \
      --arg now "$(timestamp_utc)" \
      --arg slot "${slot}" \
      --arg slug "${slug}" \
      --arg surface_id "${surface_id}" \
      '
      .updated_at = $now
      | .tasks[$slug].status = "in_progress"
      | .tasks[$slug].updated_at = $now
      | .agents[$slot].status = "running"
      | .agents[$slot].surface_id = $surface_id
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
      '{timestamp: $timestamp, event: "dispatch-started", slug: $slug, slot: $slot, surface_id: $surface_id}'
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
  local keep_worktree=0
  local keep_surface=0
  local kill_session=0
  local delete_branch=1
  local state task_status task_path done_report_path description project_slug plan preview_json done_state now
  local worktree_path worktree_branch project_path worktree_cleanup_preview worktree_cleanup_output
  local agent_slot agent_surface_id surface_cleanup_preview surface_cleanup_output

  [[ -n "${slug}" ]] || die "done requires <slug>"
  shift || true

  while (($# > 0)); do
    case "$1" in
      --dry-run)
        execute=0
        ;;
      --execute)
        execute=1
        ;;
      --keep-worktree)
        keep_worktree=1
        ;;
      --keep-surface)
        keep_surface=1
        ;;
      --kill-session)
        kill_session=1
        ;;
      --keep-branch)
        delete_branch=0
        ;;
      *)
        die "unknown done flag: $1"
        ;;
    esac
    shift
  done

  validate_slug "${slug}"
  state="$(state_json)"
  task_exists_in_state "${slug}" "${state}" || die "task slug '${slug}' does not exist"
  task_status="$(jq -r --arg slug "${slug}" '.tasks[$slug].status // "missing"' <<<"${state}")"
  if [[ "${task_status}" == "done" ]]; then
    printf "conductor.sh: task slug '%s' is already done; skipping duplicate completion\n" "${slug}" >&2
    return 0
  fi

  task_path="$(jq -r --arg slug "${slug}" '.tasks[$slug].work_item_path // empty' <<<"${state}")"
  done_report_path="$(jq -r --arg slug "${slug}" '.tasks[$slug].done_report_path // empty' <<<"${state}")"
  description="$(jq -r --arg slug "${slug}" '.tasks[$slug].description // ""' <<<"${state}")"
  project_slug="$(jq -r --arg slug "${slug}" '.tasks[$slug].project // ""' <<<"${state}")"
  project_path="$(jq -r --arg slug "${slug}" '.tasks[$slug].project_path // empty' <<<"${state}")"
  worktree_path="$(jq -r --arg slug "${slug}" '.tasks[$slug].worktree_path // empty' <<<"${state}")"
  worktree_branch="$(jq -r --arg slug "${slug}" '.tasks[$slug].worktree_branch // empty' <<<"${state}")"
  agent_slot="$(jq -r --arg slug "${slug}" '.tasks[$slug].agents[0] // empty' <<<"${state}")"
  agent_surface_id=""
  if [[ -n "${agent_slot}" ]]; then
    agent_surface_id="$(jq -r --arg slot "${agent_slot}" '.agents[$slot].surface_id // empty' <<<"${state}")"
  fi

  [[ -n "${task_path}" ]] || task_path="${ORCHESTRATOR_ROOT}/tasks/${slug}.md"
  [[ -n "${done_report_path}" ]] || done_report_path="${ORCHESTRATOR_ROOT}/done/${slug}.md"

  plan="$(
    jq -n \
      --arg slug "${slug}" \
      --arg done_report_path "${done_report_path}" \
      --arg project_slug "${project_slug}" \
      '{
        action: "done",
        project: {
          slug: $project_slug
        },
        task: {
          slug: $slug,
          done_report_path: $done_report_path
        }
      }'
  )"

  # Plan surface cleanup preview if applicable
  if [[ -n "${agent_slot}" && "${keep_surface}" -eq 0 ]]; then
    local kill_preview_args=(--dry-run)
    [[ -n "${agent_surface_id}" ]] && kill_preview_args+=(--surface "${agent_surface_id}")
    kill_preview_args+=("${agent_slot}")
    surface_cleanup_preview="$("${KILL_EFFECT}" "${kill_preview_args[@]}" 2>&1)" || true
    if ! jq -e . <<<"${surface_cleanup_preview}" >/dev/null 2>&1; then
      surface_cleanup_preview="$(jq -n --arg raw "${surface_cleanup_preview}" \
        '{action:"kill-surface",mode:"failed",raw:$raw}')"
    fi
  else
    surface_cleanup_preview='{"action":"kill-surface","mode":"skipped","reason":"--keep-surface or no agent slot recorded"}'
  fi

  # Plan worktree cleanup preview if applicable
  if [[ -n "${worktree_path}" && "${keep_worktree}" -eq 0 ]]; then
    local cleanup_args=(--dry-run "${project_path}" "${worktree_path}")
    [[ -n "${worktree_branch}" ]] && cleanup_args+=(--branch "${worktree_branch}")
    (( delete_branch == 1 )) && cleanup_args+=(--delete-branch)
    worktree_cleanup_preview="$("${CLEANUP_WORKTREE_EFFECT}" "${cleanup_args[@]}" 2>&1)" || true
    if ! jq -e . <<<"${worktree_cleanup_preview}" >/dev/null 2>&1; then
      worktree_cleanup_preview="$(jq -n --arg raw "${worktree_cleanup_preview}" \
        '{action:"cleanup-worktree",mode:"failed",raw:$raw}')"
    fi
  else
    worktree_cleanup_preview='{"action":"cleanup-worktree","mode":"skipped","reason":"--keep-worktree or no worktree recorded"}'
  fi

  if (( execute == 0 )); then
    preview_json="$(
      jq -n \
        --argjson plan "${plan}" \
        --argjson surface_cleanup "${surface_cleanup_preview}" \
        --argjson worktree_cleanup "${worktree_cleanup_preview}" \
        --arg task_path "${task_path}" \
        '{
          mode: "dry-run",
          plan: $plan,
          effects: {
            surface_cleanup: $surface_cleanup,
            worktree_cleanup: $worktree_cleanup
          },
          files: {
            task_path: $task_path
          },
          note: "Stage 0 marks the task done, writes a completion report, kills the sibling surface, and (by default) removes the per-task worktree and its branch. Pass --keep-branch to preserve the branch."
        }'
    )"
    printf '%s\n' "${preview_json}" | jq '.'
    return 0
  fi

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
    jq -cn \
      --arg timestamp "${now}" \
      --arg slug "${slug}" \
      '{timestamp: $timestamp, event: "task-done", slug: $slug}'
  )"

  # Surface cleanup — close the cmux pane but preserve the zmx session by
  # default so the worker can be reattached later (zmx attach <slot> or
  # claude --continue). Use --kill-session to also terminate the zmx session.
  if [[ -n "${agent_slot}" && "${keep_surface}" -eq 0 ]]; then
    if (( kill_session == 1 )); then
      # Full cleanup: zmx kill + cmux close-surface
      local kill_args=(--execute)
      [[ -n "${agent_surface_id}" ]] && kill_args+=(--surface "${agent_surface_id}")
      kill_args+=("${agent_slot}")
      surface_cleanup_output="$("${KILL_EFFECT}" "${kill_args[@]}" 2>&1)" || true
    else
      # Surface-only cleanup: close the cmux pane, keep zmx session alive
      # for potential reattach. The worker process may exit on its own when
      # its terminal closes, but the zmx session persists (clients=0).
      if [[ -n "${agent_surface_id}" ]] && command -v cmux >/dev/null 2>&1; then
        local ws_for_close="${ORCHESTRATOR_TARGET_WORKSPACE_ID:-${CMUX_WORKSPACE_ID:-}}"
        local close_args=(--surface "${agent_surface_id}")
        [[ -n "${ws_for_close}" ]] && close_args+=(--workspace "${ws_for_close}")
        cmux close-surface "${close_args[@]}" >/dev/null 2>&1 || true
        surface_cleanup_output="$(jq -n \
          --arg surface "${agent_surface_id}" \
          --arg slot "${agent_slot}" \
          '{action:"close-surface",mode:"execute",surface:$surface,slot:$slot,zmx_session:"preserved"}')"
      else
        surface_cleanup_output='{"action":"close-surface","mode":"skipped","reason":"no surface_id or cmux unavailable"}'
      fi
    fi
    if ! jq -e . <<<"${surface_cleanup_output}" >/dev/null 2>&1; then
      surface_cleanup_output="$(jq -n --arg raw "${surface_cleanup_output}" \
        '{action:"surface-cleanup",mode:"failed",raw:$raw}')"
    fi
  else
    surface_cleanup_output='{"action":"surface-cleanup","mode":"skipped","reason":"--keep-surface or no agent slot recorded"}'
  fi

  if [[ -n "${worktree_path}" && "${keep_worktree}" -eq 0 ]]; then
    local cleanup_args=(--execute "${project_path}" "${worktree_path}")
    [[ -n "${worktree_branch}" ]] && cleanup_args+=(--branch "${worktree_branch}")
    (( delete_branch == 1 )) && cleanup_args+=(--delete-branch)
    worktree_cleanup_output="$("${CLEANUP_WORKTREE_EFFECT}" "${cleanup_args[@]}" 2>&1)" || true
    if ! jq -e . <<<"${worktree_cleanup_output}" >/dev/null 2>&1; then
      worktree_cleanup_output="$(jq -n --arg raw "${worktree_cleanup_output}" \
        '{action:"cleanup-worktree",mode:"failed",raw:$raw}')"
    fi
  else
    worktree_cleanup_output='{"action":"cleanup-worktree","mode":"skipped","reason":"--keep-worktree or no worktree recorded"}'
  fi

  jq -n \
    --argjson plan "${plan}" \
    --argjson surface_cleanup "${surface_cleanup_output}" \
    --argjson worktree_cleanup "${worktree_cleanup_output}" \
    --arg done_report_path "${done_report_path}" \
    '{
      mode: "execute",
      plan: $plan,
      effects: {
        surface_cleanup: $surface_cleanup,
        worktree_cleanup: $worktree_cleanup
      },
      files: {
        done_report_path: $done_report_path
      }
    }' | jq '.'
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
    help|--help|-h)
      usage
      ;;
    *)
      die "unknown subcommand: ${command}"
      ;;
  esac
}

main "$@"
