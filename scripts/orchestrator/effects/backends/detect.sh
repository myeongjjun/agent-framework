#!/usr/bin/env bash
#
# effects/backends/detect.sh — terminal backend detection.
#
# Sourceable. Sets the global variable BACKEND to one of:
#   cmux | iterm2 | unknown
#
# Selection rules (highest priority first):
#   1. Explicit override:  $ORCHESTRATOR_BACKEND
#   2. cmux:    $CMUX_SURFACE_ID set AND `cmux` on PATH
#   3. iterm2:  $TERM_PROGRAM == iTerm.app AND $ITERM_SESSION_ID set
#               AND `osascript` on PATH
#   4. Fallback: cmux if installed, else unknown
#
# Usage:
#   . "$(dirname "$0")/backends/detect.sh"
#   detect_backend          # sets BACKEND
#   echo "$BACKEND"

detect_backend() {
  if [[ -n "${ORCHESTRATOR_BACKEND:-}" ]]; then
    # M10: allowlist — reject anything that is not a known backend name.
    # Without this, a caller that controls the env can point BACKEND at
    # `../something` and get `backends/../something/spawn.sh` sourced.
    case "${ORCHESTRATOR_BACKEND}" in
      cmux|iterm2) BACKEND="${ORCHESTRATOR_BACKEND}" ;;
      *)
        echo "detect.sh: invalid ORCHESTRATOR_BACKEND=${ORCHESTRATOR_BACKEND} (allowed: cmux, iterm2)" >&2
        BACKEND="unknown"
        return 1
        ;;
    esac
    return 0
  fi
  if [[ -n "${CMUX_SURFACE_ID:-}" ]] && command -v cmux >/dev/null 2>&1; then
    BACKEND="cmux"
    return 0
  fi
  if [[ "${TERM_PROGRAM:-}" == "iTerm.app" ]] \
     && [[ -n "${ITERM_SESSION_ID:-}" ]] \
     && command -v osascript >/dev/null 2>&1; then
    BACKEND="iterm2"
    return 0
  fi
  if command -v cmux >/dev/null 2>&1; then
    BACKEND="cmux"
    return 0
  fi
  BACKEND="unknown"
  return 0
}
