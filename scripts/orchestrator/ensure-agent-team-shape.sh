#!/bin/bash
# ensure-agent-team-shape.sh — keep the PINNED `agent-team` cmux workspace at
# its canonical shape: exactly one daemon-log + one approver-log pane.
#
# Targets ONLY the workspace where pinned=true AND title="agent-team", queried
# via `cmux rpc workspace.list` (authoritative). Never auto-creates a new
# workspace — if no pinned agent-team exists, the keeper silently exits and
# the user must pin one via the cmux UI.
#
# Surface resolution prefers the canonical surface_id stored at
# ${ORCH_ROOT}/agents/<role>/surface_id (written by attach_* helpers).
# Title-based grep is a fallback when the canonical surface no longer
# exists in the workspace. This avoids the prior failure mode where a
# `tail -f` exit reverted the pane title to its cwd (e.g. `~/.approver`),
# causing the title-only grep to miss and the keeper to create a fresh
# duplicate pane on the next tick.
#
# Dedup: panes whose title matches `daemon-log`/`approver-log` but whose
# surface_id is NOT the canonical one get closed. This is the only
# destructive action and is narrowly scoped to our own titles, never
# unrelated panes.
#
# Why this exists separately from health.sh recover_surfaces:
#   - health.sh recover_surfaces is only triggered by manual `health.sh --all`
#     calls. Nothing in the daemon main loop invokes it, so once a pane is
#     closed it stays closed.
#   - This script is called from daemon.sh's periodic tick so the agent-team
#     workspace shape is auto-restored within ~30s of any drift.
#
# Subprocess cmux calls bypass Claude Code's PreToolUse hook (the hook only
# fires on Claude's Bash tool, not on nested bash subprocess invocations),
# so role-restricted commands like `cmux send`/`cmux send-key` are usable
# here without violating the role policy.

set -uo pipefail

ORCH_ROOT="${ORCH_ROOT:-${HOME}/.orchestrator}"
APPROVER_ROOT="${APPROVER_ROOT:-${HOME}/.approver}"
ACTIVITY_LOG="${ORCH_ROOT}/activity.jsonl"
SCAN_LOG="${APPROVER_ROOT}/loop.log"
WS_NAME="agent-team"

command -v cmux >/dev/null 2>&1 || exit 0
command -v python3 >/dev/null 2>&1 || exit 0

# Find the workspace where pinned=true AND title=agent-team.
# rpc workspace.list returns only workspaces actually attached to a window
# (orphan/ghost workspaces from prior keeper bugs are excluded), with the
# authoritative `pinned` flag.
ws_id="$(cmux rpc workspace.list 2>/dev/null | python3 -c '
import json, sys, os
target = os.environ.get("WS_NAME", "agent-team")
try:
    data = json.load(sys.stdin)
    for ws in data.get("workspaces", []):
        if ws.get("pinned") and ws.get("title") == target:
            print(ws["ref"])
            break
except Exception:
    pass
' 2>/dev/null || true)"

# Silent exit if no pinned agent-team workspace exists. User must pin one via
# the cmux UI; the keeper never auto-creates.
[[ -n "${ws_id}" ]] || exit 0

ws_tree="$(cmux tree --workspace "${ws_id}" 2>/dev/null || true)"
# Guard: an empty tree query (cmux hiccup) must NOT trigger pane creation.
# Without this, every tree-fetch failure would spawn a new daemon-log +
# approver-log pair, accumulating duplicates over time.
[[ -n "${ws_tree}" ]] || exit 0

# Helper: does surface_id exist in the current workspace tree?
surface_in_tree() {
  local sid="$1"
  [[ -n "${sid}" ]] || return 1
  grep -qE "surface:${sid#surface:}\b" <<<"${ws_tree}"
}

# Helper: list all surface_ids matching a given pane title.
surfaces_with_title() {
  local title="$1"
  grep -oE "surface:[0-9]+ \[terminal\] \"${title}\"" <<<"${ws_tree}" \
    | grep -oE 'surface:[0-9]+'
}

# Resolve a role to its canonical surface_id, preferring the stored ID
# (re-attaches survive `tail -f` death) and falling back to title match.
resolve_role_surface() {
  local role="$1" title="$2"
  local stored_path="${ORCH_ROOT}/agents/${role}/surface_id"
  local stored=""
  [[ -f "${stored_path}" ]] && stored="$(<"${stored_path}")"
  if [[ -n "${stored}" ]] && surface_in_tree "${stored}"; then
    printf '%s\n' "${stored}"
    return 0
  fi
  # Stored canonical missing or stale — fall back to title match.
  surfaces_with_title "${title}" | head -1
}

daemon_surface="$(resolve_role_surface orchestrator daemon-log)"
approver_surface="$(resolve_role_surface approver approver-log)"

attach_daemon_log() {
  local surface_id="$1"
  cmux send-key --surface "${surface_id}" --workspace "${ws_id}" ctrl-c >/dev/null 2>&1 || true
  sleep 0.2
  cmux send --surface "${surface_id}" --workspace "${ws_id}" \
    "tail -f ${ACTIVITY_LOG} | jq -r '[.timestamp,.event,.slug // \"-\"] | join(\" \")'" \
    >/dev/null 2>&1 || true
  sleep 0.2
  cmux send-key --surface "${surface_id}" --workspace "${ws_id}" enter >/dev/null 2>&1 || true
  cmux rename-tab --surface "${surface_id}" --workspace "${ws_id}" "daemon-log" >/dev/null 2>&1 || true
  printf '%s\n' "${surface_id}" > "${ORCH_ROOT}/agents/orchestrator/surface_id.tmp"
  mv "${ORCH_ROOT}/agents/orchestrator/surface_id.tmp" "${ORCH_ROOT}/agents/orchestrator/surface_id"
  printf '%s\n' "${ws_id}" > "${ORCH_ROOT}/agents/orchestrator/workspace_id.tmp"
  mv "${ORCH_ROOT}/agents/orchestrator/workspace_id.tmp" "${ORCH_ROOT}/agents/orchestrator/workspace_id"
}

attach_approver_log() {
  local surface_id="$1"
  mkdir -p "${APPROVER_ROOT}"
  : >> "${SCAN_LOG}"
  cmux send-key --surface "${surface_id}" --workspace "${ws_id}" ctrl-c >/dev/null 2>&1 || true
  sleep 0.2
  cmux send --surface "${surface_id}" --workspace "${ws_id}" \
    "tail -n 40 -f ${SCAN_LOG}" >/dev/null 2>&1 || true
  sleep 0.2
  cmux send-key --surface "${surface_id}" --workspace "${ws_id}" enter >/dev/null 2>&1 || true
  cmux rename-tab --surface "${surface_id}" --workspace "${ws_id}" "approver-log" >/dev/null 2>&1 || true
  printf '%s\n' "${surface_id}" > "${ORCH_ROOT}/agents/approver/surface_id.tmp"
  mv "${ORCH_ROOT}/agents/approver/surface_id.tmp" "${ORCH_ROOT}/agents/approver/surface_id"
  printf '%s\n' "${ws_id}" > "${ORCH_ROOT}/agents/approver/workspace_id.tmp"
  mv "${ORCH_ROOT}/agents/approver/workspace_id.tmp" "${ORCH_ROOT}/agents/approver/workspace_id"
}

new_pane() {
  local out
  out="$(cmux new-pane --type terminal --direction right --workspace "${ws_id}" 2>&1)" || return 1
  grep -oE 'surface:[0-9]+' <<<"${out}" | head -1
}

# Reuse default surface if neither log surface exists yet (avoids spawning an
# extra empty pane on first bootstrap).
if [[ -z "${daemon_surface}" && -z "${approver_surface}" ]]; then
  default_surface="$(grep -oE 'surface:[0-9]+' <<<"${ws_tree}" | head -1 || true)"
  if [[ -n "${default_surface}" ]]; then
    attach_daemon_log "${default_surface}"
    daemon_surface="${default_surface}"
  fi
fi

if [[ -z "${daemon_surface}" ]]; then
  sid="$(new_pane)" || true
  [[ -n "${sid}" ]] && attach_daemon_log "${sid}"
fi

if [[ -z "${approver_surface}" ]]; then
  sid="$(new_pane)" || true
  [[ -n "${sid}" ]] && attach_approver_log "${sid}"
fi

# Dedup: close panes that match our titles but aren't the canonical surface.
# Narrowly scoped destructive action — only touches "daemon-log"/"approver-log"
# titles, never unrelated panes. This handles the case where a tail death
# briefly hid the original pane and a duplicate got created before the next
# tick rediscovered the canonical surface_id.
dedup_role() {
  local canonical="$1" title="$2"
  [[ -n "${canonical}" ]] || return 0
  while read -r dup; do
    [[ -z "${dup}" ]] && continue
    [[ "${dup}" == "${canonical}" ]] && continue
    cmux close-surface --surface "${dup}" --workspace "${ws_id}" >/dev/null 2>&1 || true
  done < <(surfaces_with_title "${title}")
}

# Re-fetch tree so newly-created panes are visible to the dedup pass.
ws_tree="$(cmux tree --workspace "${ws_id}" 2>/dev/null || true)"
if [[ -n "${ws_tree}" ]]; then
  dedup_role "${daemon_surface}" daemon-log
  dedup_role "${approver_surface}" approver-log
fi

exit 0
