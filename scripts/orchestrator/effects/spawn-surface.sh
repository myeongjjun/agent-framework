#!/usr/bin/env bash
#
# effects/spawn-surface.sh — terminal-agnostic dispatcher.
#
# Detects the active terminal backend (cmux | iterm2) and delegates to
# the corresponding backends/<backend>/spawn.sh implementation.
#
# Usage:
#   spawn-surface.sh [--dry-run|--execute] <slot-name> <cwd>
#
# Override the auto-detected backend via:
#   ORCHESTRATOR_BACKEND=cmux|iterm2 spawn-surface.sh ...

set -euo pipefail
IFS=$'\n\t'

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
. "${SCRIPT_DIR}/guard.sh"
. "${SCRIPT_DIR}/backends/detect.sh"
detect_backend

if [[ "${BACKEND}" == "unknown" ]]; then
  echo "spawn-surface.sh: no supported backend detected (need cmux or iTerm2)" >&2
  echo "  set ORCHESTRATOR_BACKEND=cmux|iterm2 to override" >&2
  exit 1
fi

BACKEND_SCRIPT="${SCRIPT_DIR}/backends/${BACKEND}/spawn.sh"
[[ -x "${BACKEND_SCRIPT}" ]] || { echo "spawn-surface.sh: backend script not found: ${BACKEND_SCRIPT}" >&2; exit 1; }

exec "${BACKEND_SCRIPT}" "$@"
