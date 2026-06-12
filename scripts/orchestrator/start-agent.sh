#!/usr/bin/env bash
#
# start-agent.sh — Start a persistent LLM agent in the agent-team workspace.
#
# Supports the orchestrator (default) and LLM-backed named agents with a
# bootstrap prompt. Daemon-backed agents are supervised elsewhere.
#
# Flow:
#   1. Resolve/create shared cmux workspace ("agent-team")
#   2. Create surface for this agent
#   3. zmx attach (creates session if absent)
#   4. Wait for the agent CLI to boot
#   5. Inject bootstrap prompt
#   6. Health check (BOOTSTRAPPED sentinel)
#   7. Write sentinel state + update registry
#
# Usage:
#   scripts/orchestrator/start-agent.sh [--agent-name NAME] [--family claude|codex] [--type daemon|llm-agent] [--dry-run|--execute] [--model MODEL] [--bootstrap PATH]

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
export ORCHESTRATOR_CALLER_TOKEN="start-agent:$$"

# cmux 0.64+ changed default socket path to ~/.local/state/cmux/cmux.sock
export CMUX_SOCKET_PATH="${CMUX_SOCKET_PATH:-${HOME}/.local/state/cmux/cmux.sock}"
SPAWN_EFFECT="${SCRIPT_DIR}/effects/spawn-surface.sh"
INJECT_EFFECT="${SCRIPT_DIR}/effects/inject-takeover.sh"
# shellcheck source=/dev/null
. "${SCRIPT_DIR}/protocol.sh"

die() { printf 'start-agent.sh: %s\n' "$*" >&2; exit 1; }

running_inside_codex_sandbox() {
  [[ -n "${CODEX_SANDBOX:-}" || -n "${CODEX_SANDBOX_NETWORK_DISABLED:-}" ]]
}

refuse_codex_sandbox_daemon_start() {
  running_inside_codex_sandbox || return 0
  cat >&2 <<'EOF'
start-agent.sh: REFUSED: orchestrator daemon must not be started from inside a Codex sandbox.
  Start it from the external orchestrator/shell context instead.
EOF
  exit 2
}

read_metadata() {
  local key="$1"
  local file_path
  file_path="$(_agent_metadata_file "${agent_name}" "${key}")"
  [[ -f "${file_path}" ]] || return 1
  tr -d '[:space:]' < "${file_path}"
}

# --- Parse args ---------------------------------------------------------------

mode='dry-run'
model=''
agent_name='orchestrator'
bootstrap_override=''
agent_type=''
agent_family=''
while (($# > 0)); do
  case "$1" in
    --dry-run)        mode='dry-run' ;;
    --execute)        mode='execute' ;;
    --force-restart)  die "--force-restart is disabled; use graceful stop then start" ;;
    --model)          shift; model="$1" ;;
    --agent-name)     shift; agent_name="$1" ;;
    --family)         shift; agent_family="$1" ;;
    --type)           shift; agent_type="$1" ;;
    --bootstrap)      shift; bootstrap_override="$1" ;;
    --help|-h)
      sed -n '2,20p' "$0" >&2
      exit 0
      ;;
    *) die "unknown argument: $1" ;;
  esac
  shift
done

# --- Constants ----------------------------------------------------------------

_validate_agent_name "${agent_name}" || die "invalid agent name: ${agent_name}"
declared_type="$(_agent_declared_type "${agent_name}" 2>/dev/null || true)"
if [[ "${agent_name}" == "approver" || "${declared_type}" == "daemon" && "${agent_name}" != "orchestrator" ]]; then
  die "agent '${agent_name}' is daemon-supervised; use team.sh start ${agent_name}"
fi

if [[ -z "${agent_type}" ]]; then
  if [[ "${agent_name}" == "orchestrator" ]]; then
    agent_type="${ORCHESTRATOR_AGENT_TYPE:-${declared_type:-daemon}}"
  else
    agent_type="${declared_type:-llm-agent}"
  fi
fi
case "${agent_type}" in
  daemon|llm-agent|service) ;;
  *) die "--type must be daemon, llm-agent, or service" ;;
esac
if [[ "${agent_type}" == "daemon" && "${agent_name}" != "orchestrator" ]]; then
  die "daemon type is only supported for agent-name=orchestrator"
fi
if [[ "${agent_type}" == "daemon" && "${mode}" == "execute" ]]; then
  refuse_codex_sandbox_daemon_start
fi

if [[ "${agent_type}" == "llm-agent" ]]; then
  if [[ -z "${agent_family}" ]]; then
    agent_family="$(_agent_declared_family "${agent_name}" 2>/dev/null || true)"
  fi
  [[ -n "${agent_family}" ]] || agent_family='claude'
  case "${agent_family}" in
    claude|codex) ;;
    *) die "--family must be claude or codex" ;;
  esac
else
  agent_family=''
fi

runtime_root="$(_orchestrator_root)"
agent_dir="$(_agent_dir "${agent_name}")"
launch_cwd="$(pwd -P)"
if git -C "${launch_cwd}" rev-parse --show-toplevel >/dev/null 2>&1; then
  launch_cwd="$(git -C "${launch_cwd}" rev-parse --show-toplevel)"
fi
agents_root="$(_agents_dir)"
registry_file="${agents_root}/registry.json"

# Bootstrap source: explicit override > agent-specific > orchestrator default
if [[ -n "${bootstrap_override}" ]]; then
  bootstrap_src="${bootstrap_override}"
elif [[ -f "${SCRIPT_DIR}/bootstrap-${agent_name}.md" ]]; then
  bootstrap_src="${SCRIPT_DIR}/bootstrap-${agent_name}.md"
else
  bootstrap_src="${SCRIPT_DIR}/bootstrap.md"
fi

# Slot naming: centralized in protocol.sh
slot="$(_agent_slot_name "${agent_name}" "${agent_family}")"
ws_name="${ORCHESTRATOR_WORKSPACE_NAME:-agent-team}"
reuse_surface=0
reuse_surface_id=''
reuse_workspace_id=''
skip_bootstrap_prompt=0

[[ -r "${bootstrap_src}" ]] || die "bootstrap prompt missing: ${bootstrap_src}"

# --- Already running? ---------------------------------------------------------

if _agent_alive "${agent_name}"; then
  if [[ "${agent_type}" == "daemon" ]]; then
    printf 'status=already-running agent=%s type=daemon pid=%s\n' \
      "${agent_name}" "$(_agent_pid "${agent_name}")"
  else
    printf 'status=already-running agent=%s type=llm-agent family=%s pid=%s slot=%s\n' \
      "${agent_name}" "${agent_family}" "$(_agent_pid "${agent_name}")" "${slot}"
  fi
  exit 0
fi

# --- Dry-run ------------------------------------------------------------------

if [[ "${mode}" == 'dry-run' ]]; then
  if [[ "${agent_type}" == "daemon" ]]; then
    printf 'action=start-agent mode=dry-run agent=%s type=daemon cwd=%s daemon=%s\n' \
      "${agent_name}" "${runtime_root}" "${SCRIPT_DIR}/daemon.sh"
  else
    printf 'action=start-agent mode=dry-run agent=%s type=llm-agent family=%s slot=%s cwd=%s bootstrap=%s\n' \
      "${agent_name}" "${agent_family}" "${slot}" "${launch_cwd}" "${bootstrap_src}"
  fi
  exit 0
fi

# --- Daemon launch ------------------------------------------------------------

if [[ "${agent_type}" == "daemon" ]]; then
  daemon_script="${SCRIPT_DIR}/daemon.sh"
  [[ -x "${daemon_script}" ]] || die "daemon script missing or not executable: ${daemon_script}"
  mkdir -p "${runtime_root}"/{inbox,outbox,inbox-processed,locks,mailbox}
  mkdir -p "${agent_dir}" "${agents_root}"

  rm -f "${agent_dir}"/{RUNNING,pid,slot,surface_id,workspace_id,BOOTSTRAPPED} 2>/dev/null || true
  printf 'daemon\n' > "${agent_dir}/backend"
  log_file="${agent_dir}/daemon.log"
  ORCHESTRATOR_ROOT="${runtime_root}" nohup "${daemon_script}" --foreground >> "${log_file}" 2>&1 &
  daemon_pid=$!

  daemon_ready=0
  for _i in $(seq 1 50); do
    if [[ -f "${agent_dir}/RUNNING" ]] && [[ -f "${agent_dir}/pid" ]] && kill -0 "${daemon_pid}" 2>/dev/null; then
      daemon_ready=1
      break
    fi
    sleep 0.1
  done
  (( daemon_ready == 1 )) || die "daemon did not become ready; see ${log_file}"

  # Spawn a log tail surface in the orchestrator workspace so the user
  # can see daemon activity. This is a plain terminal, not managed by
  # the daemon — no circular dependency.
  _orch_ws_id="$(cat "$(_agents_dir)/.workspace_id" 2>/dev/null || true)"
  # Verify the recorded workspace actually exists; if not, fall back to
  # looking up by name ("agent-team") and refresh the stored id.
  if [[ -n "${_orch_ws_id}" ]] \
     && ! cmux list-workspaces 2>/dev/null | grep -qF "${_orch_ws_id}"; then
    _orch_ws_id=""
  fi
  if [[ -z "${_orch_ws_id}" ]]; then
    _orch_ws_id="$(cmux tree --all 2>/dev/null \
      | grep -E 'workspace workspace:[0-9]+ "agent-team"' \
      | grep -oE 'workspace:[0-9]+' | head -1 || true)"
    if [[ -n "${_orch_ws_id}" ]]; then
      printf '%s\n' "${_orch_ws_id}" > "$(_agents_dir)/.workspace_id" 2>/dev/null || true
    fi
  fi
  if [[ -n "${_orch_ws_id}" ]]; then
    # Dedupe any existing daemon-log surfaces first (renamed or raw title).
    # Keep the first, close the rest — handles zombie surfaces left by
    # crashed stop-agent or rename-tab failures.
    _log_surfaces="$(cmux tree --workspace "${_orch_ws_id}" 2>/dev/null \
      | awk '/"daemon-log"|tail -f .*activity\.jsonl/ {
          match($0, /surface:[0-9]+/)
          if (RSTART > 0) { print substr($0, RSTART, RLENGTH) }
        }')"
    _existing_log=""
    if [[ -n "${_log_surfaces}" ]]; then
      _kept=0
      while IFS= read -r _s; do
        [[ -n "${_s}" ]] || continue
        if (( _kept == 0 )); then
          _existing_log="${_s}"
          _kept=1
          continue
        fi
        cmux close-surface --surface "${_s}" --workspace "${_orch_ws_id}" >/dev/null 2>&1 || true
      done <<<"${_log_surfaces}"
    fi
    if [[ -n "${_existing_log}" ]]; then
      # Existing daemon-log found → leave alone. Content is still tailing
      # the same activity.jsonl that the new daemon writes to.
      :
    else
      _log_surface_output="$(cmux new-split left --workspace "${_orch_ws_id}" 2>&1 || true)"
      _log_surface_id="$(printf '%s' "${_log_surface_output}" | grep -oE 'surface:[0-9]+' | head -1)"
      if [[ -n "${_log_surface_id}" ]]; then
        cmux send --surface "${_log_surface_id}" --workspace "${_orch_ws_id}" \
          "tail -f ${runtime_root}/activity.jsonl | jq -r '[.timestamp,.event,(.slug // .agent // .type // .reason // .mode // \"-\")] | join(\" \")'" >/dev/null 2>&1 || true
        cmux send-key --surface "${_log_surface_id}" --workspace "${_orch_ws_id}" enter >/dev/null 2>&1 || true
        cmux rename-tab --surface "${_log_surface_id}" --workspace "${_orch_ws_id}" "daemon-log" >/dev/null 2>&1 || true
      fi
    fi
  fi

  printf 'status=started\n'
  printf 'agent=%s\n' "${agent_name}"
  printf 'type=daemon\n'
  printf 'pid=%s\n' "${daemon_pid}"
  printf 'log=%s\n' "${log_file}"
  exit 0
fi

# --- 0. Prepare dirs + bootstrap copy -----------------------------------------

mkdir -p "${runtime_root}"/{inbox,outbox,inbox-processed,locks,mailbox}
mkdir -p "${agent_dir}"/{inbox,outbox,mailbox}
cp -f "${bootstrap_src}" "${agent_dir}/bootstrap.md"

# --- 1. Resolve or create shared agent-team workspace -------------------------
# All agents share one cmux workspace ("agent-team"). Each agent gets its
# own surface within this workspace.

ws_file="${agent_dir}/workspace_id"
shared_ws_file="${agents_root}/.workspace_id"
ws_id=""

# Check shared workspace file first
if [[ -f "${shared_ws_file}" ]]; then
  ws_id="$(tr -d '[:space:]' < "${shared_ws_file}")"
  if ! cmux list-workspaces 2>/dev/null | grep -qF "${ws_id}"; then
    ws_id=""
  fi
fi

# Fallback: this agent's own record
if [[ -z "${ws_id}" ]] && [[ -f "${ws_file}" ]]; then
  ws_id="$(tr -d '[:space:]' < "${ws_file}")"
  if ! cmux list-workspaces 2>/dev/null | grep -qF "${ws_id}"; then
    ws_id=""
  fi
fi

# Create workspace only if none exists
if [[ -z "${ws_id}" ]]; then
  ws_output="$(cmux new-workspace --name "${ws_name}" --cwd "${launch_cwd}" 2>&1)" \
    || die "cmux new-workspace failed: ${ws_output}"
  ws_id="$(grep -oE 'workspace:[0-9]+' <<< "${ws_output}" | head -1)"
  [[ -n "${ws_id}" ]] || die "could not parse workspace id from: ${ws_output}"
  mkdir -p "${agents_root}"
  printf '%s\n' "${ws_id}" > "${shared_ws_file}"
fi

printf '%s\n' "${ws_id}" > "${ws_file}"

# --- 2-4. Spawn agent surface via the shared backend path ---------------------

pid_file="${agent_dir}/pid"
pending_surface_file="${agent_dir}/pending_surface_id"
pending_workspace_file="${agent_dir}/pending_workspace_id"
rm -f "${pid_file}" 2>/dev/null || true
rm -f "${pending_surface_file}" "${pending_workspace_file}" 2>/dev/null || true

surface_id=''
spawn_target_workspace="${ws_id}"

# Clean up surface if script fails after this point.
_start_success=0
_cleanup_on_error() {
  if (( _start_success == 0 )) && [[ -n "${surface_id:-}" ]] && (( reuse_surface == 0 )); then
    if [[ "${agent_type}" != "daemon" ]]; then
      zmx kill "${slot}" 2>/dev/null || true
      pkill -9 -f "zmx attach ${slot}" 2>/dev/null || true
    fi
    cmux close-surface --surface "${surface_id}" --workspace "${spawn_target_workspace}" 2>/dev/null || true
  fi
  rm -f "${pending_surface_file}" "${pending_workspace_file}" 2>/dev/null || true
}
trap _cleanup_on_error EXIT

session_id=''
case "${agent_family}" in
  claude)
    session_id="$(uuidgen | tr '[:upper:]' '[:lower:]')"
    if [[ -n "${model}" ]]; then
      printf -v agent_cmd 'claude --dangerously-skip-permissions --model %q --session-id %q' "${model}" "${session_id}"
    else
      printf -v agent_cmd 'claude --dangerously-skip-permissions --session-id %q' "${session_id}"
    fi
    ;;
  codex)
    if [[ -n "${model}" ]]; then
      printf -v agent_cmd 'codex -s workspace-write -a never -m %q' "${model}"
    else
      agent_cmd='codex -s workspace-write -a never'
    fi
    ;;
  *)
    die "unsupported llm-agent family: ${agent_family}"
    ;;
esac

printf -v base_agent_command 'zmx attach %q %s' "${slot}" "${agent_cmd}"
if [[ -n "${pid_file}" ]]; then
  pid_dir="$(dirname -- "${pid_file}")"
  printf -v wrapped_agent_command \
    'mkdir -p %q && printf "%%s\n" "$$" > %q && exec %s' \
    "${pid_dir}" \
    "${pid_file}" \
    "${base_agent_command}"
  printf -v attach_command 'cd %q && bash -lc %q' "${launch_cwd}" "${wrapped_agent_command}"
else
  printf -v attach_command 'cd %q && %s' "${launch_cwd}" "${base_agent_command}"
fi

export ORCHESTRATOR_TARGET_WORKSPACE_ID="${ws_id}"
export ORCHESTRATOR_AGENT_EXTRA_ARGS="${agent_cmd#${agent_family} }"
export ORCHESTRATOR_AGENT_PID_FILE="${pid_file}"
if (( reuse_surface == 1 )); then
  surface_id="${reuse_surface_id}"
  spawn_target_workspace="${reuse_workspace_id}"
  cmux send-key --surface "${surface_id}" --workspace "${spawn_target_workspace}" ctrl-c >/dev/null 2>&1 || true
  sleep 1
  cmux send --surface "${surface_id}" --workspace "${spawn_target_workspace}" "${attach_command}" >/dev/null
  cmux send-key --surface "${surface_id}" --workspace "${spawn_target_workspace}" enter >/dev/null
else
  spawn_output="$("${SPAWN_EFFECT}" --execute "${slot}" "${launch_cwd}")"
  surface_id="$(jq -r '.surface_id // empty' <<<"${spawn_output}")"
  spawn_target_workspace="$(jq -r '.target_workspace // empty' <<<"${spawn_output}")"
  [[ -n "${surface_id}" ]] || die "spawn did not return a surface_id"
  [[ -n "${spawn_target_workspace}" ]] || spawn_target_workspace="${ws_id}"
fi
unset ORCHESTRATOR_TARGET_WORKSPACE_ID ORCHESTRATOR_AGENT_EXTRA_ARGS ORCHESTRATOR_AGENT_PID_FILE ORCHESTRATOR_AGENT_ATTACH_ONLY ORCHESTRATOR_AGENT_ATTACH_COMMAND
printf '%s\n' "${surface_id}" > "${pending_surface_file}"
printf '%s\n' "${spawn_target_workspace}" > "${pending_workspace_file}"

# --- 5. Wait for the agent CLI to boot ----------------------------------------

pid=''
for _i in 1 2 3 4 5 6 7 8 9 10 11 12 13 14 15 16 17 18 19 20; do
  if [[ -f "${pid_file}" ]]; then
    pid="$(tr -d '[:space:]' < "${pid_file}")"
  fi
  if [[ "${pid}" =~ ^[0-9]+$ ]]; then
    break
  fi
  pid="$(
    ps aux 2>/dev/null \
      | grep "zmx attach ${slot}" \
      | grep -v grep \
      | awk '{print $2}' \
      | head -1
  )" || true
  [[ -n "${pid}" ]] && break
  sleep 1
done
[[ -n "${pid:-}" ]] || die "${agent_family} agent did not start within 20s"

# Wait for CLI to be ready (readiness probe instead of fixed sleep)
_cli_ready=0
if (( skip_bootstrap_prompt == 1 )); then
  _cli_ready=1
else
  for _i in $(seq 1 30); do
    _screen="$(cmux read-screen --surface "${surface_id}" --workspace "${spawn_target_workspace}" --lines 10 2>/dev/null || true)"
    if [[ -n "${_screen}" ]]; then
      case "${agent_family}" in
        claude)
          if printf '%s' "${_screen}" | grep -qE '(^>|╭|waiting for|What would you)'; then
            _cli_ready=1
            break
          fi
          ;;
        codex)
          if printf '%s' "${_screen}" | grep -qE '(sandbox|Codex|>)'; then
            _cli_ready=1
            break
          fi
          ;;
      esac
    fi
    sleep 0.5
  done
fi
if (( _cli_ready == 0 )); then
  echo "warn: CLI readiness probe timed out after 15s, proceeding anyway" >&2
fi

# --- 6. Inject bootstrap prompt -----------------------------------------------

bootstrap_copy="${agent_dir}/bootstrap.md"
if (( skip_bootstrap_prompt == 0 )); then
  # Orchestrator gets a special injection prompt; other agents get a generic one.
  if [[ "${agent_name}" == "orchestrator" ]]; then
    ref_prompt="Read ${bootstrap_copy} and follow it as your Global Session Orchestrator role prompt. After reading, run this exact command: echo READY > ${agent_dir}/BOOTSTRAPPED — Then acknowledge readiness with a single short line (for example, \"Ready.\"). Do not summarize the file back to me."
  elif [[ "${agent_family}" == "codex" ]]; then
    ref_prompt="Read ${bootstrap_copy} and follow it as your agent role prompt. Your agent name is '${agent_name}'. Use the Bash tool to run this exact command first: echo READY > ${agent_dir}/BOOTSTRAPPED . After the command succeeds, acknowledge readiness with a single short line and then continue following the bootstrap instructions. Do not summarize the file back to me."
  else
    ref_prompt="Read ${bootstrap_copy} and follow it as your agent role prompt. Your agent name is '${agent_name}'. After reading, run this exact command: echo READY > ${agent_dir}/BOOTSTRAPPED — Then acknowledge readiness with a single short line. Do not summarize the file back to me."
  fi

  "${INJECT_EFFECT}" --execute --as-prompt --family "${agent_family}" --workspace "${spawn_target_workspace}" "${surface_id}" "${ref_prompt}" >/dev/null
fi

# --- 7. Health check: wait for BOOTSTRAPPED sentinel --------------------------

sentinel="${agent_dir}/BOOTSTRAPPED"
for _i in 1 2 3 4 5 6 7 8 9 10 11 12 13 14 15 16 17 18 19 20 21 22 23 24 25 26 27 28 29 30 31 32 33 34 35 36 37 38 39 40 41 42 43 44 45 46 47 48 49 50 51 52 53 54 55 56 57 58 59 60; do
  [[ -f "${sentinel}" ]] && break
  sleep 2
done

if [[ ! -f "${sentinel}" ]]; then
  die "bootstrap health check failed — BOOTSTRAPPED not written within 120s; check agent surface for ${agent_name}"
fi

# --- H11: Upgrade pid_file to the inner agent PID -----------------------------
#
# Up to here ${pid} is the zmx-attach client PID captured via `exec $$`.
# Killing it only disconnects the client, not the agent. zmx list exposes
# the session's command PID (`pid=<N>` column), which is the actual
# claude/codex process. If we can resolve it, replace the file contents
# so stop-agent and registry reflect the real agent.
if command -v zmx >/dev/null 2>&1; then
  inner_pid="$(zmx list 2>/dev/null \
    | awk -v slot="name=${slot}" '$0 ~ slot { for (i=1;i<=NF;i++) if ($i ~ /^pid=/) { sub(/^pid=/,"",$i); print $i; exit } }')"
  if [[ "${inner_pid}" =~ ^[0-9]+$ ]] && kill -0 "${inner_pid}" 2>/dev/null; then
    pid="${inner_pid}"
  fi
fi

# --- Write sentinel state -----------------------------------------------------

printf 'started_at=%s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" > "${agent_dir}/RUNNING"
printf '%s\n' "${pid}" > "${pid_file}"
printf '%s\n' "${slot}" > "${agent_dir}/slot"
printf '%s\n' "${surface_id}" > "${agent_dir}/surface_id"
printf 'cmux\n' > "${agent_dir}/backend"
printf '%s\n' "${agent_family}" > "${agent_dir}/family"
rm -f "${pending_surface_file}" "${pending_workspace_file}" 2>/dev/null || true

# Delete session file to prevent claude --continue pollution.
if [[ "${agent_family}" == "claude" && -n "${session_id}" ]]; then
  _project_slug="$(printf '%s' "${launch_cwd}" | tr '/' '-' | sed 's/^-//')"
  session_jsonl="${HOME}/.claude/projects/${_project_slug}/${session_id}.jsonl"
  rm -f "${session_jsonl}" 2>/dev/null || true
fi

# --- Update agent registry ----------------------------------------------------

_now="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
_locked_registry_update "${registry_file}" \
  "$(printf '.agents["%s"] = {type:"llm-agent",family:"%s",status:"running",pid:%s,slot:"%s",surface_id:"%s",workspace_id:"%s",bootstrap_source:"%s",started_at:"%s",last_health:"%s",restart_count:((.agents["%s"].restart_count // 0))}' \
    "${agent_name}" "${agent_family}" "${pid}" "${slot}" "${surface_id}" "${spawn_target_workspace}" "${bootstrap_src}" "${_now}" "${_now}" "${agent_name}")"

_start_success=1

mkdir -p "${runtime_root}" 2>/dev/null || true
jq -cn \
  --arg timestamp "${_now}" \
  --arg agent "${agent_name}" \
  --arg family "${agent_family}" \
  --arg slot "${slot}" \
  --arg surface_id "${surface_id}" \
  --arg workspace_id "${spawn_target_workspace}" \
  --argjson pid "${pid}" \
  '{timestamp:$timestamp,event:"agent-started",agent:$agent,family:$family,pid:$pid,slot:$slot,surface_id:$surface_id,workspace_id:$workspace_id}' \
  >> "${runtime_root}/activity.jsonl" 2>/dev/null || true

printf 'status=started\n'
printf 'agent=%s\n' "${agent_name}"
printf 'family=%s\n' "${agent_family}"
printf 'pid=%s\n' "${pid}"
printf 'slot=%s\n' "${slot}"
printf 'surface_id=%s\n' "${surface_id}"
printf 'workspace_id=%s\n' "${spawn_target_workspace}"
