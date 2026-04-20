#!/usr/bin/env bash
# auto-done.sh — Called by EXIT trap in fire-and-forget worker shells.
#
# Cleans up ephemeral resources (surface, zmx session) and logs completion.
# Does NOT delete worktrees or branches — those are preserved for inspection
# and cleaned up later via `conductor.sh tidy`.
#
# Usage: auto-done.sh <slug> <slot> <surface_id> <workspace_id>
#
# This script runs in the dying worker shell, so it must be:
#   - Fast (no network calls, no jq pipelines)
#   - Tolerant of partial state (every command || true)
#   - Independent of state.json (no locks, no reads, no writes)

set -u

slug="${1:-}"
slot="${2:-}"
surface_id="${3:-}"
workspace_id="${4:-}"

[[ -n "${slug}" ]] || exit 0

ORCH_ROOT="${ORCHESTRATOR_ROOT:-${HOME}/.orchestrator}"
activity_log="${ORCH_ROOT}/activity.jsonl"

# 1. Close cmux surface — ONLY if it still exists in the workspace.
#    cmux close-surface on a non-existent surface may silently close a
#    different (wrong) surface, so we verify first.
if [[ -n "${surface_id}" && -n "${workspace_id}" ]] && command -v cmux >/dev/null 2>&1; then
  if cmux tree --workspace "${workspace_id}" 2>/dev/null \
    | grep -qE "(^|[[:space:]])${surface_id}([[:space:]]|$)"; then
    cmux close-surface --surface "${surface_id}" --workspace "${workspace_id}" 2>/dev/null || true
  fi
fi

# 2. Kill zmx session (process cleanup)
if [[ -n "${slot}" ]]; then
  zmx kill "${slot}" 2>/dev/null || true
fi

# 3. Log completion to activity.jsonl (append-only, no lock needed for small writes)
if [[ -d "${ORCH_ROOT}" ]]; then
  printf '{"timestamp":"%s","event":"auto-done","slug":"%s","slot":"%s"}\n' \
    "$(date -u +%FT%TZ)" "${slug}" "${slot}" >> "${activity_log}" 2>/dev/null || true
fi
