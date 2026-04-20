#!/usr/bin/env bash
#
# effects/kill-surface.sh — terminal-agnostic dispatcher.
#
# Detects the active terminal backend (cmux | iterm2) and delegates to
# the corresponding backends/<backend>/kill.sh implementation.
#
# Usage:
#   kill-surface.sh [--dry-run|--execute] [--surface <id>] [--pid <n>] <slot-name>

set -euo pipefail
IFS=$'\n\t'

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
. "${SCRIPT_DIR}/guard.sh"
. "${SCRIPT_DIR}/backends/detect.sh"
detect_backend

if [[ "${BACKEND}" == "unknown" ]]; then
  echo "kill-surface.sh: no supported backend detected (need cmux or iTerm2)" >&2
  exit 1
fi

BACKEND_SCRIPT="${SCRIPT_DIR}/backends/${BACKEND}/kill.sh"
[[ -x "${BACKEND_SCRIPT}" ]] || { echo "kill-surface.sh: backend script not found: ${BACKEND_SCRIPT}" >&2; exit 1; }

exec "${BACKEND_SCRIPT}" "$@"
