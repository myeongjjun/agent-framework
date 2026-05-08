#!/usr/bin/env bash
#
# backends/cmux/spawn.sh — cmux backend for spawning a sibling surface.
#
# SIDE EFFECT: cmux new-split + zmx attach. Dry-run by default.
#
# Usage:
#   spawn.sh [--dry-run|--execute] <slot-name> <cwd>
#
# Outputs JSON describing the spawn (or its dry-run preview).
#
# Optional environment:
#   ORCHESTRATOR_AGENT_PID_FILE=<path>
#     If set, wrap the launch command so the spawned shell writes its pid
#     before it execs the agent attach command.
#   ORCHESTRATOR_TARGET_WORKSPACE_ID=workspace:<n>
#     If set, create the new split in this cmux workspace instead of the
#     caller's ${CMUX_WORKSPACE_ID}. Used by start-agent.sh to park the
#     orchestrator in a dedicated workspace, and by conductor.sh to route
#     dispatched workers into the requester's project workspace instead of
#     the orchestrator's own workspace.

set -euo pipefail
IFS=$'\n\t'

mode='dry-run'
split_direction="${ORCHESTRATOR_SPAWN_DIRECTION:-auto}"
attach_only="${ORCHESTRATOR_AGENT_ATTACH_ONLY:-0}"
while (($# > 0)); do
  case "$1" in
    --dry-run) mode='dry-run'; shift ;;
    --execute) mode='execute'; shift ;;
    --direction) shift; split_direction="${1:-right}"; shift ;;
    --help|-h) sed -n '2,12p' "$0" >&2; exit 0 ;;
    *) break ;;
  esac
done

[[ $# -eq 2 ]] || { echo "backends/cmux/spawn.sh: usage: spawn.sh [--dry-run|--execute] <slot> <cwd>" >&2; exit 1; }
slot_name="$1"
cwd="$2"

case "${slot_name}" in
  claude-*) agent_cmd='claude' ;;
  codex-*)  agent_cmd='codex' ;;
  *) echo "backends/cmux/spawn.sh: slot must start with claude- or codex-" >&2; exit 1 ;;
esac

# Worker agents (dispatched via conductor.sh) run non-interactively and
# need --dangerously-skip-permissions to avoid blocking on approval prompts.
# The orchestrator itself also uses this via ORCHESTRATOR_AGENT_EXTRA_ARGS.
# For dispatched Claude workers (not the orchestrator), auto-add the flag.
resume_flag="${ORCHESTRATOR_AGENT_RESUME:-}"

# Clear stale zmx session before spawn (prevents name collision on resume).
# Skip this in attach-only mode because the caller already created the session
# and wants this pane to attach to that live runner.
if [[ "${attach_only}" != "1" ]] && command -v zmx &>/dev/null; then
  _stale_line="$(zmx list 2>/dev/null | grep "name=${slot_name}" || true)"
  if [[ -n "${_stale_line}" ]]; then
    if ! zmx kill "${slot_name}" >/dev/null 2>&1; then
      # zmx kill failed — try pid from zmx list, then pgrep fallback
      _stale_pid="$(sed -n 's/.*pid=\([0-9]*\).*/\1/p' <<<"${_stale_line}")"
      if [[ -z "${_stale_pid}" ]]; then
        _stale_pid="$(pgrep -f "zmx attach ${slot_name}" 2>/dev/null | head -1 || true)"
      fi
      if [[ -n "${_stale_pid}" ]]; then
        kill -9 "${_stale_pid}" 2>/dev/null || true
        sleep 1
      fi
      # Force zmx daemon to drop the stale entry
      zmx kill "${slot_name}" >/dev/null 2>&1 || true
    fi
  fi
fi

task_slug="${ORCHESTRATOR_TASK_SLUG:-}"

if [[ -n "${ORCHESTRATOR_AGENT_EXTRA_ARGS:-}" ]]; then
  agent_cmd="${agent_cmd} ${ORCHESTRATOR_AGENT_EXTRA_ARGS}"
elif [[ "${agent_cmd}" == "claude" && "${slot_name}" != "claude-orchestrator-global" ]]; then
  if [[ "${resume_flag}" == "true" && -n "${task_slug}" ]]; then
    agent_cmd="claude --dangerously-skip-permissions --resume ${task_slug}"
  elif [[ -n "${task_slug}" ]]; then
    agent_cmd="claude --dangerously-skip-permissions -n ${task_slug}"
  else
    agent_cmd="claude --dangerously-skip-permissions"
  fi
elif [[ "${agent_cmd}" == "codex" ]]; then
  if [[ "${resume_flag}" == "true" && -n "${task_slug}" ]]; then
    agent_cmd="codex resume ${task_slug} --full-auto"
  else
    agent_cmd="codex --full-auto"
  fi
  # codex has no -n flag; thread name is set post-spawn via /rename injection.
fi

if [[ "${attach_only}" == "1" ]]; then
  printf -v base_agent_command 'zmx attach %q' "${slot_name}"
else
  printf -v base_agent_command 'zmx attach %q %s' "${slot_name}" "${agent_cmd}"
fi
if [[ -n "${ORCHESTRATOR_AGENT_PID_FILE:-}" ]]; then
  pid_dir="$(dirname -- "${ORCHESTRATOR_AGENT_PID_FILE}")"
  printf -v wrapped_agent_command \
    'mkdir -p %q && printf "%%s\n" "$$" > %q && exec %s' \
    "${pid_dir}" \
    "${ORCHESTRATOR_AGENT_PID_FILE}" \
    "${base_agent_command}"
  printf -v attach_command 'cd %q && bash -lc %q' "${cwd}" "${wrapped_agent_command}"
else
  printf -v attach_command 'cd %q && %s' "${cwd}" "${base_agent_command}"
fi

# Target workspace MUST be set explicitly by the orchestrator/conductor.
# Never fall back to CMUX_WORKSPACE_ID — that belongs to the orchestrator's
# own workspace and would misroute the surface.
target_workspace="${ORCHESTRATOR_TARGET_WORKSPACE_ID:-}"

if [[ "${mode}" == 'dry-run' ]]; then
  dry_workspace="${target_workspace:-\${ORCHESTRATOR_TARGET_WORKSPACE_ID:-\${CMUX_WORKSPACE_ID\}\}}"
  jq -n \
    --arg slot "${slot_name}" \
    --arg cwd "${cwd}" \
    --arg attach_command "${attach_command}" \
    --arg pid_file "${ORCHESTRATOR_AGENT_PID_FILE:-}" \
    --arg target_workspace "${target_workspace}" \
    --arg dry_workspace "${dry_workspace}" \
    --arg split_direction "${split_direction}" \
    '{
      action: "spawn-surface",
      backend: "cmux",
      mode: "dry-run",
      slot: $slot,
      cwd: $cwd,
      split_direction: $split_direction,
      target_workspace: (if $target_workspace == "" then null else $target_workspace end),
      pid_file: (if $pid_file == "" then null else $pid_file end),
      convention: "cmux new-pane",
      commands: [
        ("cmux new-pane --type terminal --direction " + $split_direction + " --workspace " + $dry_workspace),
        ("cmux send --surface <new-surface> " + ($attach_command | @json)),
        "cmux send-key --surface <new-surface> enter"
      ]
    }'
  exit 0
fi

command -v cmux >/dev/null 2>&1 || { echo "backends/cmux/spawn.sh: cmux not found" >&2; exit 1; }
command -v zmx >/dev/null 2>&1 || { echo "backends/cmux/spawn.sh: zmx not found" >&2; exit 1; }
[[ -n "${target_workspace}" ]] || { echo "backends/cmux/spawn.sh: ORCHESTRATOR_TARGET_WORKSPACE_ID required for --execute (must be set by conductor.sh)" >&2; exit 1; }

# === 3×2 Grid Layout ===
#
# Auto-determine split direction to fill a 3-column × 2-row grid:
#
#   ┌──────┬──────┬──────┐
#   │  1   │  2   │  3   │   row 1: direction=right
#   ├──────┼──────┼──────┤
#   │  4   │  5   │  6   │   row 2: direction=down (split from row 1 pane)
#   └──────┴──────┴──────┘
#
# When the grid is full (6 panes), create an overflow workspace and start
# a new grid there. The caller can override with --direction or
# ORCHESTRATOR_SPAWN_DIRECTION env.
#
# Pane ordering: list existing panes, pick the direction and (for row 2)
# focus the correct row-1 pane before splitting.

MAX_GRID_PANES=6

if [[ "${split_direction}" == "auto" || -z "${split_direction}" ]]; then
  # Read current pane list (bash 3.2 compatible — no mapfile)
  existing_panes=()
  while IFS= read -r _pane_line; do
    [[ -n "${_pane_line}" ]] && existing_panes+=("${_pane_line}")
  done < <(
    cmux list-panes --workspace "${target_workspace}" 2>/dev/null \
      | grep -oE 'pane:[0-9]+' || true
  )
  pane_count="${#existing_panes[@]}"

  if (( pane_count >= MAX_GRID_PANES )); then
    # Grid full → overflow workspace
    overflow_name="${ORCHESTRATOR_OVERFLOW_WS_NAME:-workers-overflow}"
    overflow_output="$(cmux new-workspace --name "${overflow_name}" 2>&1)" || {
      echo "backends/cmux/spawn.sh: failed to create overflow workspace: ${overflow_output}" >&2
      exit 1
    }
    target_workspace="$(grep -oE 'workspace:[0-9]+' <<<"${overflow_output}" | head -1)"
    [[ -n "${target_workspace}" ]] || {
      echo "backends/cmux/spawn.sh: could not parse overflow workspace id" >&2
      exit 1
    }
    split_direction="right"
  else
    # Always split right — cmux auto-arranges panes horizontally.
    # Previous 3×2 grid logic (focus row1 pane → split down) was unreliable
    # because cmux focus-pane from the orchestrator workspace doesn't
    # consistently affect the target workspace's focused pane, resulting in
    # broken layouts. Simpler horizontal splits let cmux handle layout.
    split_direction="right"
  fi
fi

surface_output="$(cmux new-pane --type terminal --direction "${split_direction}" --workspace "${target_workspace}" 2>&1)"
# Keep the full ref form `surface:NN` (cmux accepts id|ref, not raw index).
surface_id="$(grep -oE 'surface:[^[:space:]]+' <<<"${surface_output}" | head -1)"
[[ -n "${surface_id}" ]] || {
  echo "backends/cmux/spawn.sh: failed to parse surface id from: ${surface_output}" >&2
  exit 1
}

# H8 rollback: if the attach-command send fails after the pane is
# created, close the orphan so retries don't accumulate dead surfaces.
_spawn_rollback() {
  local rc=$?
  (( rc == 0 )) && return 0
  cmux close-surface --surface "${surface_id}" --workspace "${target_workspace}" >/dev/null 2>&1 || true
  return "${rc}"
}
trap _spawn_rollback EXIT

# Note: worker-side EXIT trap / sequential auto-done is not possible here —
# cmux closes the pane when its foreground process (zmx attach) exits,
# killing any trailing cleanup before it can run. Auto-cleanup must be
# driven externally (e.g., daemon polling zmx list, or user running
# `conductor.sh tidy`).

cmux send --surface "${surface_id}" --workspace "${target_workspace}" "${attach_command}" >/dev/null
cmux send-key --surface "${surface_id}" --workspace "${target_workspace}" enter >/dev/null

jq -n \
  --arg slot "${slot_name}" \
  --arg cwd "${cwd}" \
  --arg surface_id "${surface_id}" \
  --arg attach_command "${attach_command}" \
  --arg pid_file "${ORCHESTRATOR_AGENT_PID_FILE:-}" \
  --arg target_workspace "${target_workspace}" \
  '{
    action: "spawn-surface",
    backend: "cmux",
    mode: "execute",
    slot: $slot,
    cwd: $cwd,
    surface_id: $surface_id,
    target_workspace: $target_workspace,
    attach_command: $attach_command,
    pid_file: (if $pid_file == "" then null else $pid_file end)
  }'

trap - EXIT
