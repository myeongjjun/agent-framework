#!/usr/bin/env bash
#
# backends/iterm2/kill.sh — iTerm2 backend for tearing down a sibling pane.
#
# SIDE EFFECT: osascript close session. Dry-run by default.
#
# Stage 0 limitation: iTerm2 has no zmx-style named slot, so the
# "kill the agent process" responsibility falls back to closing the
# pane and letting the shell SIGHUP the child process. This is
# best-effort. For a guaranteed kill, the caller should pass --pid <N>
# (recorded by spawn at execute time and stored in state.json by the
# conductor — Stage 1 enhancement).

set -euo pipefail
IFS=$'\n\t'

mode='dry-run'
surface_id=''
pid=''
while (($# > 0)); do
  case "$1" in
    --dry-run) mode='dry-run'; shift ;;
    --execute) mode='execute'; shift ;;
    --surface) shift; surface_id="${1:-}"; shift ;;
    --pid) shift; pid="${1:-}"; shift ;;
    --help|-h) sed -n '2,12p' "$0" >&2; exit 0 ;;
    *) break ;;
  esac
done

[[ $# -ge 1 ]] || { echo "backends/iterm2/kill.sh: usage: kill.sh [--dry-run|--execute] [--surface <id>] [--pid <n>] <slot-name>" >&2; exit 1; }
slot_name="$1"

if [[ "${mode}" == 'dry-run' ]]; then
  jq -n \
    --arg slot "${slot_name}" \
    --arg surface_id "${surface_id}" \
    --arg pid "${pid}" \
    '{
      action: "kill-surface",
      backend: "iterm2",
      mode: "dry-run",
      slot: $slot,
      surface_id: $surface_id,
      pid: $pid,
      commands: (
        (if $pid == "" then [] else ["kill -TERM " + $pid] end)
        + (if $surface_id == "" then [] else
            ["osascript -e \"tell application \\\"iTerm2\\\" to tell session id \\\"" + $surface_id + "\\\" to close\""]
          end)
      ),
      note: "iTerm2 has no named slot; closing the pane SIGHUPs the child agent. Pass --pid for a guaranteed kill."
    }'
  exit 0
fi

command -v osascript >/dev/null 2>&1 || { echo "backends/iterm2/kill.sh: osascript not found" >&2; exit 1; }

if [[ -n "${pid}" ]]; then
  kill -TERM "${pid}" 2>/dev/null || true
fi

if [[ -n "${surface_id}" ]]; then
  osascript <<OSA || true
tell application "iTerm2"
  tell session id "${surface_id}"
    close
  end tell
end tell
OSA
fi

jq -n \
  --arg slot "${slot_name}" \
  --arg surface_id "${surface_id}" \
  --arg pid "${pid}" \
  '{
    action: "kill-surface",
    backend: "iterm2",
    mode: "execute",
    slot: $slot,
    surface_id: $surface_id,
    pid: $pid
  }'
