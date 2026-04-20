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

usage() {
  cat <<'EOF'
Usage:
  scripts/orchestrator/stop-agent.sh [--agent-name NAME] [--dry-run|--execute]

Notes:
  - Dry-run is the default. Pass --execute to mutate runtime state.
  - stop-agent always attempts graceful shutdown before cleanup.
  - --agent-name defaults to "orchestrator".
EOF
}

die() {
  printf 'stop-agent.sh: %s\n' "$*" >&2
  exit 1
}

agent_state_present() {
  local dir
  dir="$(_agent_dir "${agent_name}")"
  [[ -d "${dir}" ]] || return 1
  find "${dir}" -mindepth 1 -maxdepth 1 -print -quit | grep -q .
}

clear_agent_state() {
  local dir
  dir="$(_agent_dir "${agent_name}")"
  [[ -d "${dir}" ]] || return 0
  rm -f \
    "${dir}/RUNNING" \
    "${dir}/pid" \
    "${dir}/slot" \
    "${dir}/surface_id" \
    "${dir}/backend" \
    "${dir}/family" \
    "${dir}/type" \
    "${dir}/workspace_id" \
    "${dir}/BOOTSTRAPPED" \
    "${dir}/scan.pid" \
    "${dir}/pending_surface_id" \
    "${dir}/pending_workspace_id"
}

read_metadata() {
  local key="$1"
  local file_path
  file_path="$(_agent_metadata_file "${agent_name}" "${key}")"
  [[ -f "${file_path}" ]] || return 1
  tr -d '[:space:]' < "${file_path}"
}

workspace_surface_rows() {
  local workspace_id="${1:?workspace_surface_rows requires workspace id}"
  cmux tree --all 2>/dev/null | awk -v target_ws="${workspace_id}" '
    /workspace:[0-9]+/ {
      match($0, /workspace:[0-9]+/)
      ws = substr($0, RSTART, RLENGTH)
    }
    /surface:[0-9]+.*\[terminal\]/ {
      if (ws != target_ws) {
        next
      }
      match($0, /surface:[0-9]+/)
      sf = substr($0, RSTART, RLENGTH)
      title = ""
      if (match($0, /"[^"]+"/)) {
        title = substr($0, RSTART + 1, RLENGTH - 2)
      }
      print sf "\t" title
    }
  '
}

close_surface_if_present() {
  local workspace_id="$1"
  local surface_ref="$2"
  [[ -n "${workspace_id}" && -n "${surface_ref}" ]] || return 0
  cmux close-surface --surface "${surface_ref}" --workspace "${workspace_id}" >/dev/null 2>&1 || true
}

mode='dry-run'
agent_name='orchestrator'
while (($# > 0)); do
  case "$1" in
    --dry-run)      mode='dry-run' ;;
    --execute)      mode='execute' ;;
    --force)        die "--force is disabled; stop-agent always uses graceful stop" ;;
    --agent-name)   shift; agent_name="$1" ;;
    --help|-h)      usage; exit 0 ;;
    *)              die "unknown argument: $1" ;;
  esac
  shift
done

_validate_agent_name "${agent_name}" || die "invalid agent name: ${agent_name}"

agent_dir="$(_agent_dir "${agent_name}")"
runtime_root="$(_orchestrator_root)"
registry_file="$(_agents_dir)/registry.json"
backend_name="$(read_metadata backend 2>/dev/null || printf 'unknown')"
agent_family="$(read_metadata family 2>/dev/null || true)"
agent_type="$(
  if [[ -f "${registry_file}" ]]; then
    jq -r --arg agent "${agent_name}" '.agents[$agent].type // empty' "${registry_file}" 2>/dev/null || true
  fi
)"
if [[ -z "${agent_family}" && -f "${registry_file}" ]]; then
  agent_family="$(jq -r --arg agent "${agent_name}" '.agents[$agent].family // empty' "${registry_file}" 2>/dev/null || true)"
fi
if [[ -z "${agent_family}" ]]; then
  agent_family="$(_agent_declared_family "${agent_name}" 2>/dev/null || true)"
fi
[[ -n "${agent_family}" ]] || agent_family='claude'
slot_name="$(read_metadata slot 2>/dev/null || _agent_slot_name "${agent_name}" "${agent_family}")"
[[ -n "${agent_type}" ]] || { [[ "${backend_name}" == "daemon" ]] && agent_type="daemon" || agent_type="llm-agent"; }
surface_id="$(read_metadata surface_id 2>/dev/null || true)"
pending_surface_id="$(read_metadata pending_surface_id 2>/dev/null || true)"
pending_workspace_id="$(read_metadata pending_workspace_id 2>/dev/null || true)"
pid_value="$(_agent_pid "${agent_name}" 2>/dev/null || true)"
scan_pid_file="${agent_dir}/scan.pid"
kill_script=''
strategy='graceful'
alive_now=0
if ! _agent_alive "${agent_name}"; then
  strategy='stale-cleanup'
fi

if _agent_alive "${agent_name}"; then
  alive_now=1
fi

if ! agent_state_present && (( alive_now == 0 )); then
  die "no agent sentinel state found for '${agent_name}'"
fi

if [[ "${backend_name}" == "cmux" || "${backend_name}" == "iterm2" ]]; then
  kill_script="${SCRIPT_DIR}/effects/backends/${backend_name}/kill.sh"
fi

if [[ "${mode}" == 'dry-run' ]]; then
  jq -n \
    --arg mode "${mode}" \
    --arg agent "${agent_name}" \
    --arg strategy "${strategy}" \
    --arg type "${agent_type}" \
    --arg family "${agent_family}" \
    --arg backend "${backend_name}" \
    --arg slot "${slot_name}" \
    --arg surface_id "${surface_id}" \
    --arg pid "${pid_value}" \
    --arg runtime_root "${runtime_root}" \
    --arg kill_script "${kill_script}" \
    --argjson alive "$( (( alive_now == 1 )) && printf 'true' || printf 'false' )" \
    '{
      action: "stop-agent",
      agent: $agent,
      type: $type,
      family: $family,
      mode: $mode,
      strategy: $strategy,
      alive: $alive,
      runtime_root: $runtime_root,
      target: {
        backend: $backend,
        slot: $slot,
        surface_id: (if $surface_id == "" then null else $surface_id end),
        pid: (if $pid == "" then null else $pid end)
      },
      graceful_request: {
        type: "shutdown",
        timeout_seconds: 15,
        enabled: $alive
      }
    }'
  exit 0
fi

# --- Graceful shutdown --------------------------------------------------------

if (( alive_now == 1 )); then
  if [[ "${agent_name}" == "orchestrator" ]]; then
    # Orchestrator has its own protocol request handler
    shutdown_payload='Write a goodbye response, archive the request, and then exit cleanly.'
    if orchestrator_request \
      --type shutdown \
      --payload "${shutdown_payload}" \
      --timeout 15 \
      --wait >/dev/null 2>&1; then
      for _ in 1 2 3 4 5; do
        kill -0 "${pid_value}" 2>/dev/null || break
        sleep 1
      done
    fi
  elif [[ "${backend_name}" != "daemon" ]]; then
    # Non-orchestrator LLM agents: deterministic graceful stop (M13).
    # The prior approach injected a "Run: exit" prompt and waited up to
    # 5s for the LLM to comply — non-deterministic (model could refuse,
    # take longer, or produce text instead). Replace with send-key ctrl-c
    # to interrupt any in-flight reasoning, then rely on the SIGTERM →
    # SIGKILL path below. Agents that need on-exit cleanup must do it via
    # external signals, not prompt compliance.
    local_ws_id="$(read_metadata workspace_id 2>/dev/null || true)"
    if [[ -n "${surface_id}" && -n "${local_ws_id}" && "${backend_name}" == "cmux" ]]; then
      cmux send-key --surface "${surface_id}" --workspace "${local_ws_id}" ctrl-c >/dev/null 2>&1 || true
      sleep 1
    fi
  fi
fi

# --- Kill process -------------------------------------------------------------

if [[ -n "${pid_value}" ]] && kill -0 "${pid_value}" 2>/dev/null; then
  kill -TERM "${pid_value}" 2>/dev/null || true
  sleep 3
  if kill -0 "${pid_value}" 2>/dev/null; then
    kill -KILL "${pid_value}" 2>/dev/null || true
  fi
fi

if [[ -f "${scan_pid_file}" ]]; then
  scan_pid_value="$(tr -d '[:space:]' < "${scan_pid_file}" 2>/dev/null || true)"
  if [[ "${scan_pid_value}" =~ ^[0-9]+$ ]] && kill -0 "${scan_pid_value}" 2>/dev/null; then
    kill -TERM "${scan_pid_value}" 2>/dev/null || true
    sleep 1
    kill -0 "${scan_pid_value}" 2>/dev/null && kill -KILL "${scan_pid_value}" 2>/dev/null || true
  fi
fi

if [[ -n "${kill_script}" ]] && [[ -x "${kill_script}" ]]; then
  kill_args=(--execute)
  if [[ -n "${surface_id}" ]]; then
    kill_args+=(--surface "${surface_id}")
  fi
  if [[ "${backend_name}" == "iterm2" ]] && [[ -n "${pid_value}" ]]; then
    kill_args+=(--pid "${pid_value}")
  fi
  kill_args+=("${slot_name}")
  "${kill_script}" "${kill_args[@]}" >/dev/null 2>&1 || true
fi

# Kill ALL zmx attach processes for this slot.
if [[ "${backend_name}" != "daemon" && -n "${slot_name}" ]]; then
  pkill -9 -f "zmx attach ${slot_name}" 2>/dev/null || true
  sleep 1
fi

# Close the cmux surface(s) so restarts don't leave orphaned panes.
if [[ "${backend_name}" != "daemon" ]]; then
  local_ws_id="$(read_metadata workspace_id 2>/dev/null || true)"
  if [[ "${agent_name}" == "approver" && -n "${local_ws_id}" ]]; then
    while IFS=$'\t' read -r workspace_surface_id workspace_surface_title; do
      [[ -n "${workspace_surface_id}" ]] || continue
      [[ "${workspace_surface_title}" == "daemon-log" ]] && continue
      close_surface_if_present "${local_ws_id}" "${workspace_surface_id}"
    done < <(workspace_surface_rows "${local_ws_id}")
  else
    close_surface_if_present "${local_ws_id:-}" "${surface_id}"
  fi
  if [[ -n "${pending_surface_id}" ]]; then
    close_surface_if_present "${pending_workspace_id:-${local_ws_id:-}}" "${pending_surface_id}"
  fi
fi

# For daemon-backed agents (orchestrator, ...), close the daemon-log surface
# if one exists so a restart doesn't accumulate duplicates. Uses the stored
# orchestrator workspace id (.workspace_id) which start-agent.sh wrote.
#
# Match both the renamed title ("daemon-log") AND the raw tail command,
# because rename-tab can fail silently leaving surfaces with untamed titles.
if [[ "${backend_name}" == "daemon" ]]; then
  _orch_ws_id="$(cat "$(_agents_dir)/.workspace_id" 2>/dev/null || true)"
  if [[ -n "${_orch_ws_id}" ]]; then
    while IFS=$'\t' read -r _log_surf_id _log_surf_title; do
      [[ -n "${_log_surf_id}" ]] || continue
      case "${_log_surf_title}" in
        daemon-log) ;;
        *tail\ -f*activity.jsonl*) ;;
        *) continue ;;
      esac
      close_surface_if_present "${_orch_ws_id}" "${_log_surf_id}"
    done < <(workspace_surface_rows "${_orch_ws_id}" 2>/dev/null || true)
  fi
fi

clear_agent_state

# --- Update registry ----------------------------------------------------------

if [[ -f "${registry_file}" ]]; then
  _locked_registry_update "${registry_file}" \
    "$(printf '.agents["%s"].status = "stopped" | .agents["%s"].pid = null | .agents["%s"].surface_id = null | .agents["%s"].workspace_id = null' \
      "${agent_name}" "${agent_name}" "${agent_name}" "${agent_name}")"
fi

mkdir -p "${runtime_root}" 2>/dev/null || true
jq -cn \
  --arg timestamp "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
  --arg agent "${agent_name}" \
  --arg family "${agent_family}" \
  --arg strategy "${strategy}" \
  --arg slot "${slot_name}" \
  --arg backend "${backend_name}" \
  '{timestamp:$timestamp,event:"agent-stopped",agent:$agent,family:$family,strategy:$strategy,slot:$slot,backend:$backend}' \
  >> "${runtime_root}/activity.jsonl" 2>/dev/null || true

printf 'status=stopped\n'
printf 'agent=%s\n' "${agent_name}"
printf 'family=%s\n' "${agent_family}"
printf 'strategy=%s\n' "${strategy}"
printf 'slot=%s\n' "${slot_name}"
printf 'backend=%s\n' "${backend_name}"
