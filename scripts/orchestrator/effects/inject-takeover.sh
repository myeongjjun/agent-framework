#!/usr/bin/env bash
#
# effects/inject-takeover.sh — terminal-agnostic dispatcher.
#
# Detects the active terminal backend (cmux | iterm2) and delegates to
# the corresponding backends/<backend>/inject.sh implementation.
#
# Usage:
#   inject-takeover.sh [--dry-run|--execute] <surface-id> <work-item-path>

set -euo pipefail
IFS=$'\n\t'

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
. "${SCRIPT_DIR}/guard.sh"
. "${SCRIPT_DIR}/backends/detect.sh"
detect_backend

if [[ "${BACKEND}" == "unknown" ]]; then
  echo "inject-takeover.sh: no supported backend detected (need cmux or iTerm2)" >&2
  exit 1
fi

BACKEND_SCRIPT="${SCRIPT_DIR}/backends/${BACKEND}/inject.sh"
[[ -x "${BACKEND_SCRIPT}" ]] || { echo "inject-takeover.sh: backend script not found: ${BACKEND_SCRIPT}" >&2; exit 1; }

exec "${BACKEND_SCRIPT}" "$@"
