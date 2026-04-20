#!/usr/bin/env bash
#
# backends/cmux/kill.sh — cmux backend for killing a sibling slot.
#
# SIDE EFFECT: zmx kill + cmux close-surface. Dry-run by default.

set -euo pipefail
IFS=$'\n\t'

mode='dry-run'
surface_id=''
while (($# > 0)); do
  case "$1" in
    --dry-run) mode='dry-run'; shift ;;
    --execute) mode='execute'; shift ;;
    --surface) shift; surface_id="${1:-}"; shift ;;
    --help|-h) sed -n '2,9p' "$0" >&2; exit 0 ;;
    *) break ;;
  esac
done

[[ $# -ge 1 ]] || { echo "backends/cmux/kill.sh: usage: kill.sh [--dry-run|--execute] [--surface <id>] <slot-name>" >&2; exit 1; }
slot_name="$1"

if [[ "${mode}" == 'dry-run' ]]; then
  jq -n \
    --arg slot "${slot_name}" \
    --arg surface_id "${surface_id}" \
    '{
      action: "kill-surface",
      backend: "cmux",
      mode: "dry-run",
      slot: $slot,
      surface_id: $surface_id,
      commands: (
        ["zmx kill " + $slot]
        + (if $surface_id == "" then [] else ["cmux close-surface --surface " + $surface_id] end)
      )
    }'
  exit 0
fi

command -v zmx >/dev/null 2>&1 || { echo "backends/cmux/kill.sh: zmx not found" >&2; exit 1; }
zmx kill "${slot_name}" || true
if [[ -n "${surface_id}" ]] && command -v cmux >/dev/null 2>&1; then
  cmux close-surface --surface "${surface_id}" || true
fi

jq -n \
  --arg slot "${slot_name}" \
  --arg surface_id "${surface_id}" \
  '{
    action: "kill-surface",
    backend: "cmux",
    mode: "execute",
    slot: $slot,
    surface_id: $surface_id
  }'
