#!/usr/bin/env bash

set -euo pipefail
IFS=$'\n\t'

# Canonical runtime gate — see team.sh for rationale.
_canonical_dir="${HOME}/.orchestrator/scripts/orchestrator"
_canonical="${_canonical_dir}/$(basename "${BASH_SOURCE[0]}")"
_current_dir="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
if [[ "${_current_dir}" != "${_canonical_dir}" ]]; then
  if [[ -x "${_canonical}" ]]; then
    exec "${_canonical}" "$@"
  else
    echo "$(basename "${BASH_SOURCE[0]}"): canonical runtime ${_canonical} missing — run ./scripts/sync-all.sh" >&2
    exit 1
  fi
fi
unset _canonical_dir _canonical _current_dir

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=/dev/null
. "${SCRIPT_DIR}/protocol.sh"

# cmux 0.64+ changed default socket path to ~/.local/state/cmux/cmux.sock
export CMUX_SOCKET_PATH="${CMUX_SOCKET_PATH:-${HOME}/.local/state/cmux/cmux.sock}"

usage() {
  cat <<'EOF'
Usage:
  scripts/orchestrator/health.sh [--agent-name NAME] [--all]
EOF
}

ORCH_ROOT="${ORCHESTRATOR_ROOT:-${HOME}/.orchestrator}"
APPROVER_ROOT="${APPROVER_ROOT:-${HOME}/.approver}"

running_inside_codex_sandbox() {
  [[ -n "${CODEX_SANDBOX:-}" || -n "${CODEX_SANDBOX_NETWORK_DISABLED:-}" ]]
}

# Close duplicate daemon-log/approver-log surfaces in a workspace, keeping
# the first one of each title. Fixes the case where stop/start-agent leaves
# an orphan log surface that a subsequent start re-creates.
dedupe_log_surfaces() {
  local ws_id="${1:?}"
  # Match by clear identifying patterns (not just title) because rename-tab
  # can fail silently, leaving surfaces with the raw tail command as title.
  # For each log type:
  #   1. Collect all surfaces matching title OR raw tail pattern
  #   2. Prefer keeping a surface with the proper title ("daemon-log" /
  #      "approver-log"). Close all others including raw-titled ones.
  local kind title_pat raw_pat
  for kind in daemon-log approver-log; do
    case "${kind}" in
      daemon-log)
        title_pat='"daemon-log"'
        raw_pat='tail -f .*activity\.jsonl'
        ;;
      approver-log)
        title_pat='"approver-log"'
        raw_pat='tail (-n 40 )?-f .*(loop\.log|decisions\.jsonl)'
        ;;
    esac
    local tree_output proper_surfaces raw_surfaces
    tree_output="$(cmux tree --workspace "${ws_id}" 2>/dev/null || true)"
    [[ -n "${tree_output}" ]] || continue
    proper_surfaces="$(printf '%s\n' "${tree_output}" | awk -v pat="${title_pat}" '
        $0 ~ pat { match($0, /surface:[0-9]+/); if (RSTART>0) print substr($0, RSTART, RLENGTH) }')"
    raw_surfaces="$(printf '%s\n' "${tree_output}" | awk -v pat="${raw_pat}" '
        $0 ~ pat { match($0, /surface:[0-9]+/); if (RSTART>0) print substr($0, RSTART, RLENGTH) }')"

    local to_close="" keeper=""
    if [[ -n "${proper_surfaces}" ]]; then
      keeper="$(head -1 <<<"${proper_surfaces}")"
      # Close other proper-titled duplicates
      to_close+="$(tail -n +2 <<<"${proper_surfaces}")"
      # Close ALL raw-titled surfaces (keeper is a proper one)
      to_close+=$'\n'"${raw_surfaces}"
    elif [[ -n "${raw_surfaces}" ]]; then
      # No proper-titled, only raw → keep first raw, close rest
      keeper="$(head -1 <<<"${raw_surfaces}")"
      to_close+="$(tail -n +2 <<<"${raw_surfaces}")"
    fi

    local sid
    while IFS= read -r sid; do
      sid="$(printf '%s' "${sid}" | tr -d '[:space:]')"
      [[ -n "${sid}" && "${sid}" != "${keeper}" ]] || continue
      cmux close-surface --surface "${sid}" --workspace "${ws_id}" >/dev/null 2>&1 || true
    done <<<"${to_close}"
  done
}

log_surface_keeper() {
  local ws_id="${1:?}" kind="${2:?}" title_pat raw_pat tree_output proper_surfaces raw_surfaces
  case "${kind}" in
    daemon-log)
      title_pat='"daemon-log"'
      raw_pat='tail -f .*activity\.jsonl'
      ;;
    approver-log)
      title_pat='"approver-log"'
      raw_pat='tail (-n 40 )?-f .*(loop\.log|decisions\.jsonl)'
      ;;
    *)
      return 1
      ;;
  esac

  tree_output="$(cmux tree --workspace "${ws_id}" 2>/dev/null || true)"
  [[ -n "${tree_output}" ]] || return 1
  proper_surfaces="$(printf '%s\n' "${tree_output}" | awk -v pat="${title_pat}" '
      $0 ~ pat { match($0, /surface:[0-9]+/); if (RSTART>0) print substr($0, RSTART, RLENGTH) }')"
  raw_surfaces="$(printf '%s\n' "${tree_output}" | awk -v pat="${raw_pat}" '
      $0 ~ pat { match($0, /surface:[0-9]+/); if (RSTART>0) print substr($0, RSTART, RLENGTH) }')"

  if [[ -n "${proper_surfaces}" ]]; then
    head -1 <<<"${proper_surfaces}"
    return 0
  fi
  if [[ -n "${raw_surfaces}" ]]; then
    head -1 <<<"${raw_surfaces}"
    return 0
  fi
  return 1
}

prune_agent_team_surfaces() {
  local ws_id="${1:?}"
  shift
  local keepers=("$@") sid
  while IFS= read -r sid; do
    [[ -n "${sid}" ]] || continue
    if [[ " ${keepers[*]} " == *" ${sid} "* ]]; then
      continue
    fi
    cmux close-surface --surface "${sid}" --workspace "${ws_id}" >/dev/null 2>&1 || true
  done < <(
    cmux tree --workspace "${ws_id}" 2>/dev/null | awk '
      /surface:[0-9]+.*\[terminal\]/ {
        match($0, /surface:[0-9]+/)
        if (RSTART > 0) {
          print substr($0, RSTART, RLENGTH)
        }
      }'
  )
}

# Recover surfaces for all alive daemon agents into a single shared workspace.
# Layout: one workspace "agent-team", two panes split left/right.
#   left  = orchestrator daemon-log  (activity.jsonl)
#   right = approver-log             (loop.log)
recover_surfaces() {
  local agents=("$@")
  command -v cmux >/dev/null 2>&1 || return 1

  # Find existing "agent-team" workspace or create one
  local ws_id default_surface=''
  ws_id="$(cmux tree --all 2>/dev/null \
    | grep -E 'workspace workspace:[0-9]+ "agent-team"' \
    | grep -oE 'workspace:[0-9]+' | head -1 || true)"

  if [[ -n "${ws_id}" ]]; then
    # Existing workspace: dedupe any duplicate log surfaces before adding
    dedupe_log_surfaces "${ws_id}"
  else
    local ws_output
    ws_output="$(cmux new-workspace --name "agent-team" 2>&1)" || return 1
    ws_id="$(grep -oE 'workspace:[0-9]+' <<<"${ws_output}" | head -1)"
    [[ -n "${ws_id}" ]] || return 1
    # New workspace comes with one default surface
    default_surface="$(cmux tree --workspace "${ws_id}" 2>/dev/null \
      | grep -oE 'surface:[0-9]+' | head -1 || true)"
  fi

  local daemon_surface approver_surface
  daemon_surface="$(log_surface_keeper "${ws_id}" daemon-log 2>/dev/null || true)"
  approver_surface="$(log_surface_keeper "${ws_id}" approver-log 2>/dev/null || true)"
  prune_agent_team_surfaces "${ws_id}" "${daemon_surface}" "${approver_surface}"

  local first=1
  for name in "${agents[@]}"; do
    local agent_dir surface_id
    agent_dir="$(_agent_dir "${name}")"

    if [[ "${name}" == "orchestrator" && -n "${daemon_surface}" ]]; then
      surface_id="${daemon_surface}"
      first=0
    elif [[ "${name}" == "approver" && -n "${approver_surface}" ]]; then
      surface_id="${approver_surface}"
      first=0
    elif (( first )) && [[ -n "${default_surface}" ]]; then
      # New workspace: reuse the default surface for the first agent
      surface_id="${default_surface}"
      first=0
    else
      # Split for this agent
      local pane_output
      pane_output="$(cmux new-pane --type terminal --direction right --workspace "${ws_id}" 2>&1)" || continue
      surface_id="$(grep -oE 'surface:[0-9]+' <<<"${pane_output}" | head -1)"
      [[ -n "${surface_id}" ]] || continue
      first=0
    fi

    # Attach log tail based on agent type
    case "${name}" in
      orchestrator)
        local log_file="${ORCH_ROOT}/activity.jsonl"
        if [[ -f "${log_file}" ]]; then
          cmux send-key --surface "${surface_id}" --workspace "${ws_id}" ctrl-c >/dev/null 2>&1 || true
          cmux send --surface "${surface_id}" --workspace "${ws_id}" \
            "tail -f ${log_file} | jq -r '[.timestamp,.event,.slug // \"-\"] | join(\" \")'" >/dev/null 2>&1 || true
          cmux send-key --surface "${surface_id}" --workspace "${ws_id}" enter >/dev/null 2>&1 || true
        fi
        cmux rename-tab --surface "${surface_id}" --workspace "${ws_id}" "daemon-log" >/dev/null 2>&1 || true
        ;;
      approver)
        local scan_log="${APPROVER_ROOT}/loop.log"
        mkdir -p "${APPROVER_ROOT}"
        : >> "${scan_log}"
        cmux send-key --surface "${surface_id}" --workspace "${ws_id}" ctrl-c >/dev/null 2>&1 || true
        cmux send --surface "${surface_id}" --workspace "${ws_id}" \
          "tail -n 40 -f ${scan_log}" >/dev/null 2>&1 || true
        cmux send-key --surface "${surface_id}" --workspace "${ws_id}" enter >/dev/null 2>&1 || true
        cmux rename-tab --surface "${surface_id}" --workspace "${ws_id}" "approver-log" >/dev/null 2>&1 || true
        ;;
    esac

    # Persist metadata
    mkdir -p "${agent_dir}"
    printf '%s' "${surface_id}" > "${agent_dir}/surface_id"
    printf '%s' "${ws_id}" > "${agent_dir}/workspace_id"
  done
}

check_agent() {
  local name="${1:?}"
  local status='dead'
  local surface='none'
  local agent_dir pid_file pid_value pid_live='no' running_file registry_file
  local reg_status='-' reg_pid='-' reg_last_health='-' last_error='-'
  local pid_state='dead' ipc_probe='skipped' heartbeat_age_s='-'
  local alive_reason='-'

  agent_dir="$(_agent_dir "${name}")"
  pid_file="${agent_dir}/pid"
  running_file="${agent_dir}/RUNNING"
  registry_file="$(_agents_dir)/registry.json"

  if [[ -f "${pid_file}" ]]; then
    pid_value="$(tr -d '[:space:]' < "${pid_file}" 2>/dev/null || true)"
  else
    pid_value=""
  fi
  if [[ "${name}" == "approver" && -z "${pid_value}" && -f "${APPROVER_ROOT}/scan.pid" ]]; then
    pid_value="$(tr -d '[:space:]' < "${APPROVER_ROOT}/scan.pid" 2>/dev/null || true)"
  fi

  # L1: PID check via _agent_pid_state — distinguishes ESRCH from EPERM
  # so that a sandbox/namespace restriction does not masquerade as a
  # dead daemon.
  pid_state="$(_agent_pid_state "${pid_value}")"
  case "${pid_state}" in
    alive)      pid_live='yes' ;;
    restricted) pid_live='restricted' ;;
    *)          pid_live='no' ;;
  esac

  if [[ -f "${registry_file}" ]]; then
    reg_status="$(jq -r --arg a "${name}" '.agents[$a].status // "-"' "${registry_file}" 2>/dev/null)"
    reg_pid="$(jq -r --arg a "${name}" '.agents[$a].pid // "-"' "${registry_file}" 2>/dev/null)"
    reg_last_health="$(jq -r --arg a "${name}" '.agents[$a].last_health // "-"' "${registry_file}" 2>/dev/null)"
  fi

  # L2 + L3: if PID says alive, we're done. Otherwise (dead or
  # restricted), fall through to IPC probe and heartbeat freshness
  # before declaring dead. Only the orchestrator has an IPC path;
  # other agents rely on PID + heartbeat.
  if [[ "${pid_state}" == 'alive' ]]; then
    status='alive'
    alive_reason='pid'
  else
    # L2: IPC probe — ask the daemon whether it can answer. Succeeds
    # even when our session can't signal the pid (EPERM), so this is
    # the strongest liveness signal we have in restricted contexts.
    if [[ "${name}" == 'orchestrator' && "${ORCHESTRATOR_HEALTH_SKIP_IPC:-0}" != '1' ]]; then
      if orchestrator_request --type status --slug 'health-probe' --timeout 3 --wait --payload '## Payload' >/dev/null 2>&1; then
        status='alive'
        alive_reason='ipc'
        ipc_probe='ok'
      else
        ipc_probe='failed'
      fi
    fi

    # L3: heartbeat freshness — even if IPC fails (e.g. filesystem
    # blocked), a recent last_health stamp proves the daemon's loop was
    # running seconds ago.
    if [[ "${status}" == 'dead' && "${reg_last_health}" != '-' ]]; then
      local hb_epoch now_epoch
      hb_epoch="$(_iso8601_to_epoch "${reg_last_health}" 2>/dev/null || printf '0')"
      now_epoch="$(date +%s)"
      if [[ "${hb_epoch}" =~ ^[0-9]+$ ]] && (( hb_epoch > 0 )); then
        heartbeat_age_s=$(( now_epoch - hb_epoch ))
        if (( heartbeat_age_s >= 0 && heartbeat_age_s < 30 )); then
          status='alive'
          alive_reason='heartbeat'
        fi
      fi
    fi
  fi

  if agent_surface_ok "${name}" 2>/dev/null; then
    surface='ok'
  fi

  # Self-heal: if the three-layer check all agree the agent is dead
  # (PID not found, IPC probe failed or skipped, heartbeat stale), flip
  # the registry entry from "running" to "stopped". Only reconcile on
  # confirmed write success so the displayed reg_status matches the
  # on-disk file — writing stopped to local var regardless misled past
  # debugging sessions. Restricted + heartbeat-alive cases are skipped
  # intentionally: the daemon is likely healthy even if we can't see it.
  if [[ "${status}" == 'dead' && "${name}" == 'orchestrator' ]] \
     && running_inside_codex_sandbox \
     && [[ "${reg_status}" == 'running' || -f "${running_file}" ]]; then
    status='unknown'
    alive_reason='sandbox-inaccessible'
    last_error='Codex sandbox cannot prove external orchestrator liveness; registry was left unchanged'
  fi

  if [[ "${status}" == 'dead' && "${reg_status}" == 'running' && "${pid_state}" == 'dead' ]] \
     && ! running_inside_codex_sandbox; then
    if _locked_registry_update "${registry_file}" \
         "$(printf '.agents["%s"].status = "stopped" | .agents["%s"].pid = null | .agents["%s"].last_health = "%s"' \
           "${name}" "${name}" "${name}" "$(date -u +%Y-%m-%dT%H:%M:%SZ)")" >/dev/null 2>&1; then
      rm -f "${running_file}" 2>/dev/null || true
      reg_status='stopped'
    else
      reg_status='running (reconcile failed)'
    fi
  fi

  # Surface the last stderr line from daemon.log — but only when it is
  # newer than the current daemon's start. Otherwise we echo a ghost
  # error from a previous (crashed and restarted) generation, which
  # makes debugging chase phantom bugs.
  if [[ "${status}" == 'dead' && -f "${agent_dir}/daemon.log" ]]; then
    local log_mtime=0 running_mtime=0
    if [[ -f "${running_file}" ]]; then
      running_mtime="$(stat -f %m "${running_file}" 2>/dev/null || stat -c %Y "${running_file}" 2>/dev/null || printf '0')"
    fi
    log_mtime="$(stat -f %m "${agent_dir}/daemon.log" 2>/dev/null || stat -c %Y "${agent_dir}/daemon.log" 2>/dev/null || printf '0')"
    if (( log_mtime >= running_mtime )); then
      last_error="$(tail -n 1 "${agent_dir}/daemon.log" 2>/dev/null | tr -d '\n')"
      [[ -n "${last_error}" ]] || last_error='-'
    else
      last_error='(log predates current daemon — stale, ignored)'
    fi
  fi

  printf 'agent=%s\n' "${name}"
  printf 'status=%s\n' "${status}"
  printf 'alive_via=%s\n' "${alive_reason}"
  printf 'surface=%s\n' "${surface}"
  printf 'pid_file=%s\n' "${pid_value:--}"
  printf 'pid_live=%s\n' "${pid_live}"
  printf 'pid_state=%s\n' "${pid_state}"
  printf 'ipc_probe=%s\n' "${ipc_probe}"
  printf 'heartbeat_age_s=%s\n' "${heartbeat_age_s}"
  printf 'registry_status=%s\n' "${reg_status}"
  printf 'registry_pid=%s\n' "${reg_pid}"
  if [[ "${status}" == 'dead' || "${status}" == 'unknown' ]]; then
    printf 'last_error=%s\n' "${last_error}"
  fi
  [[ "${status}" == 'alive' || "${status}" == 'unknown' ]]
}

check_all=0
agent_name='orchestrator'
while (($# > 0)); do
  case "$1" in
    --all)         check_all=1 ;;
    --agent-name)  shift; agent_name="$1" ;;
    --help|-h)     usage; exit 0 ;;
    *)             printf 'health.sh: unknown argument: %s\n' "$1" >&2; exit 1 ;;
  esac
  shift
done

if (( check_all == 1 )); then
  # Dedupe duplicate log surfaces in existing agent-team workspace.
  # This handles the case where stop/start-agent leaves an orphan log
  # surface that a subsequent start re-creates.
  if command -v cmux >/dev/null 2>&1; then
    _existing_team_ws="$(cmux tree --all 2>/dev/null \
      | grep -E 'workspace workspace:[0-9]+ "agent-team"' \
      | grep -oE 'workspace:[0-9]+' | head -1 || true)"
    [[ -n "${_existing_team_ws}" ]] && dedupe_log_surfaces "${_existing_team_ws}"
  fi

  # Collect alive agents that need surface recovery
  needs_recovery=()
  all_agents=()
  recoverable_agents=()
  registry_file="$(_agents_dir)/registry.json"
  if [[ -f "${registry_file}" ]]; then
    while IFS= read -r name; do
      [[ -n "${name}" ]] && all_agents+=("${name}")
    done < <(jq -r '.agents | keys[]' "${registry_file}" 2>/dev/null)
  else
    for name in orchestrator approver; do
      [[ -d "$(_agent_dir "${name}")" ]] && all_agents+=("${name}")
    done
  fi

  # First pass: detect who needs recovery
  for name in "${all_agents[@]}"; do
    local_alive=0
    if [[ "${name}" == "orchestrator" ]]; then
      orchestrator_alive && local_alive=1
    else
      _agent_alive "${name}" && local_alive=1
    fi
    if (( local_alive )) && ! agent_surface_ok "${name}" 2>/dev/null; then
      needs_recovery+=("${name}")
    fi
    if (( local_alive )) && [[ "${name}" == "orchestrator" || "${name}" == "approver" ]]; then
      recoverable_agents+=("${name}")
    fi
  done

  # Batch recover into a single workspace
  if (( ${#needs_recovery[@]} > 0 )) && (( ${#recoverable_agents[@]} > 0 )); then
    recover_surfaces "${recoverable_agents[@]}" 2>/dev/null || true
  fi

  # Second pass: report
  overall_exit=0
  for name in "${all_agents[@]}"; do
    echo "---"
    check_agent "${name}" || overall_exit=1
  done
  exit "${overall_exit}"
fi

# Single agent: recover if needed, then report
local_alive=0
single_recovery_agents=()
if [[ "${agent_name}" == "orchestrator" ]]; then
  orchestrator_alive && local_alive=1
else
  _agent_alive "${agent_name}" && local_alive=1
fi
orchestrator_alive && single_recovery_agents+=("orchestrator")
if _agent_alive approver 2>/dev/null; then
  single_recovery_agents+=("approver")
fi
if (( local_alive )) && ! agent_surface_ok "${agent_name}" 2>/dev/null && (( ${#single_recovery_agents[@]} > 0 )); then
  recover_surfaces "${single_recovery_agents[@]}" 2>/dev/null || true
fi
check_agent "${agent_name}"
