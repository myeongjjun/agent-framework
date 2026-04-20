#!/usr/bin/env bash
#
# backends/iterm2/spawn.sh — iTerm2 backend for spawning a sibling pane.
#
# SIDE EFFECT: osascript split + write text. Dry-run by default.
#
# Pattern: `tell current session of current window to split vertically`
# returns the new session id, which we use as the surface_id. Then
# `tell session id "..." to write text "..."` injects the start command;
# `write text` delivers its own newline (no separate enter keystroke).
#
# Adapted from scripts/handoff-rotate-iterm.sh patterns.
#
# Optional environment:
#   ORCHESTRATOR_AGENT_PID_FILE=<path>
#     If set, wrap the launch command so the spawned shell writes its pid
#     before it execs the agent command.

set -euo pipefail
IFS=$'\n\t'

mode='dry-run'
while (($# > 0)); do
  case "$1" in
    --dry-run) mode='dry-run'; shift ;;
    --execute) mode='execute'; shift ;;
    --help|-h) sed -n '2,12p' "$0" >&2; exit 0 ;;
    *) break ;;
  esac
done

[[ $# -eq 2 ]] || { echo "backends/iterm2/spawn.sh: usage: spawn.sh [--dry-run|--execute] <slot> <cwd>" >&2; exit 1; }
slot_name="$1"
cwd="$2"

case "${slot_name}" in
  claude-*) agent_cmd='claude' ;;
  codex-*)  agent_cmd='codex' ;;
  *) echo "backends/iterm2/spawn.sh: slot must start with claude- or codex-" >&2; exit 1 ;;
esac

# Optional extra args (e.g. --dangerously-skip-permissions for the
# orchestrator agent). Same pass-through contract as the cmux backend.
if [[ -n "${ORCHESTRATOR_AGENT_EXTRA_ARGS:-}" ]]; then
  agent_cmd="${agent_cmd} ${ORCHESTRATOR_AGENT_EXTRA_ARGS}"
fi

# iTerm2 has no zmx-style named slots, so we run the agent directly
# inside the new pane. The slot_name is preserved as a logical label
# in state.json for symmetry with the cmux backend.
if [[ -n "${ORCHESTRATOR_AGENT_PID_FILE:-}" ]]; then
  pid_dir="$(dirname -- "${ORCHESTRATOR_AGENT_PID_FILE}")"
  printf -v wrapped_agent_command \
    'mkdir -p %q && printf "%%s\n" "$$" > %q && exec %s' \
    "${pid_dir}" \
    "${ORCHESTRATOR_AGENT_PID_FILE}" \
    "${agent_cmd}"
  printf -v start_command 'cd %q && bash -lc %q' "${cwd}" "${wrapped_agent_command}"
else
  printf -v start_command 'cd %q && %s' "${cwd}" "${agent_cmd}"
fi

if [[ "${mode}" == 'dry-run' ]]; then
  jq -n \
    --arg slot "${slot_name}" \
    --arg cwd "${cwd}" \
    --arg start_command "${start_command}" \
    --arg pid_file "${ORCHESTRATOR_AGENT_PID_FILE:-}" \
    '{
      action: "spawn-surface",
      backend: "iterm2",
      mode: "dry-run",
      slot: $slot,
      cwd: $cwd,
      pid_file: (if $pid_file == "" then null else $pid_file end),
      convention: "iTerm2 split vertically + write text",
      commands: [
        "osascript -e \"tell application \\\"iTerm2\\\" to tell current session of current window to set newSess to (split vertically with default profile)\" -e \"return id of newSess\"",
        ("osascript -e \"tell application \\\"iTerm2\\\" to tell session id <new-id> to write text \" -e " + ($start_command | @json))
      ]
    }'
  exit 0
fi

command -v osascript >/dev/null 2>&1 || { echo "backends/iterm2/spawn.sh: osascript not found (macOS only)" >&2; exit 1; }
[[ "${TERM_PROGRAM:-}" == "iTerm.app" ]] || { echo "backends/iterm2/spawn.sh: not running inside iTerm2 (TERM_PROGRAM=${TERM_PROGRAM:-})" >&2; exit 1; }

# Step 1: split vertically and capture the new session id.
new_session_id="$(osascript <<'OSA'
tell application "iTerm2"
  tell current session of current window
    set newSess to (split vertically with default profile)
    return id of newSess
  end tell
end tell
OSA
)" || { echo "backends/iterm2/spawn.sh: split vertically failed" >&2; exit 1; }
new_session_id="${new_session_id//$'\n'/}"
[[ -n "${new_session_id}" ]] || { echo "backends/iterm2/spawn.sh: empty new session id" >&2; exit 1; }

# Step 2: send the start command to the new pane.
osascript <<OSA
tell application "iTerm2"
  tell session id "${new_session_id}"
    write text "${start_command}"
  end tell
end tell
OSA

jq -n \
  --arg slot "${slot_name}" \
  --arg cwd "${cwd}" \
  --arg surface_id "${new_session_id}" \
  --arg start_command "${start_command}" \
  --arg pid_file "${ORCHESTRATOR_AGENT_PID_FILE:-}" \
  '{
    action: "spawn-surface",
    backend: "iterm2",
    mode: "execute",
    slot: $slot,
    cwd: $cwd,
    surface_id: $surface_id,
    start_command: $start_command,
    pid_file: (if $pid_file == "" then null else $pid_file end)
  }'
