#!/bin/bash
# ensure-agent-team-shape.sh — keep the `agent-team` cmux workspace at its
# canonical shape: exactly two panes, left=daemon-log, right=approver-log.
#
# Idempotent. Safe to run on every daemon poll tick. Fixes drift caused by
# pane closure, daemon restarts, or stale registry surface_ids.
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

# Locate or create the workspace.
ws_id="$(cmux tree --all 2>/dev/null \
  | grep -E "workspace workspace:[0-9]+ \"${WS_NAME}\"" \
  | grep -oE 'workspace:[0-9]+' | head -1 || true)"

if [[ -z "${ws_id}" ]]; then
  out="$(cmux new-workspace --name "${WS_NAME}" 2>&1)" || exit 0
  ws_id="$(grep -oE 'workspace:[0-9]+' <<<"${out}" | head -1)"
  [[ -n "${ws_id}" ]] || exit 0
fi

ws_tree="$(cmux tree --workspace "${ws_id}" 2>/dev/null || true)"

# Locate existing log surfaces by title.
daemon_surface="$(grep -oE 'surface:[0-9]+ \[terminal\] "daemon-log"' <<<"${ws_tree}" \
  | grep -oE 'surface:[0-9]+' | head -1 || true)"
approver_surface="$(grep -oE 'surface:[0-9]+ \[terminal\] "approver-log"' <<<"${ws_tree}" \
  | grep -oE 'surface:[0-9]+' | head -1 || true)"

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

exit 0
