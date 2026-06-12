#!/usr/bin/env bash
set -euo pipefail
IFS=$'\n\t'

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
RUNTIME_DIR="${APPROVER_ROOT:-${SCRIPT_DIR}}"

# cmux 0.64+ changed default socket path to ~/.local/state/cmux/cmux.sock
export CMUX_SOCKET_PATH="${CMUX_SOCKET_PATH:-${HOME}/.local/state/cmux/cmux.sock}"
SELF_WORKSPACE_FILE="${RUNTIME_DIR}/workspace_id"
SELF_SURFACE_FILE="${RUNTIME_DIR}/surface_id"
DECISIONS_FILE="${RUNTIME_DIR}/decisions.jsonl"
LOOP_LOG="${RUNTIME_DIR}/loop.log"
PID_FILE="${RUNTIME_DIR}/scan.pid"

mode="once"
interval="1"

while (($# > 0)); do
  case "$1" in
    --dry-run)
      jq -n \
        --arg action "approver-scan" \
        --arg mode "dry-run" \
        --arg runtime_dir "${RUNTIME_DIR}" \
        '{action:$action,mode:$mode,runtime_dir:$runtime_dir}'
      exit 0
      ;;
    --loop) mode="loop" ;;
    --once) mode="once" ;;
    --interval)
      shift
      interval="${1:?--interval requires seconds}"
      ;;
    *)
      printf 'approver-scan.sh: unknown argument: %s\n' "$1" >&2
      exit 2
      ;;
  esac
  shift
done

self_workspace=""
self_surface=""

timestamp_utc() {
  date -u +"%Y-%m-%dT%H:%M:%SZ"
}

log_runtime() {
  local message="$1"
  printf '%s %s\n' "$(timestamp_utc)" "${message}" >> "${LOOP_LOG}"
}

refresh_self_context() {
  self_workspace=""
  self_surface=""

  if [[ -f "${SELF_WORKSPACE_FILE}" ]]; then
    self_workspace="$(tr -d '[:space:]' < "${SELF_WORKSPACE_FILE}" 2>/dev/null || true)"
  fi

  if [[ -f "${SELF_SURFACE_FILE}" ]]; then
    self_surface="$(tr -d '[:space:]' < "${SELF_SURFACE_FILE}" 2>/dev/null || true)"
  fi
}

screen_tail() {
  printf '%s\n' "${1:-}" | tail -n 25
}

prompt_present() {
  local tail_text
  tail_text="$(screen_tail "${1:-}")"

  if [[ "${tail_text}" == *"Press enter to confirm or esc to cancel"* ]]; then
    return 0
  fi

  if printf '%s\n' "${tail_text}" | rg -q '^[[:space:]]*[›❯] 1\. Yes'; then
    return 0
  fi

  if [[ "${tail_text}" == *"Would you like to run the following command?"* ]] \
    && [[ "${tail_text}" == *"Yes, proceed"* || "${tail_text}" == *"don't ask again"* || "${tail_text}" == *"No, and kill Codex"* ]]; then
    return 0
  fi

  if [[ "${tail_text}" == *"Do you want to proceed?"* ]] \
    && printf '%s\n' "${tail_text}" | rg -q '^[[:space:]]*[›❯]?[[:space:]]*[123]\.'; then
    return 0
  fi

  if [[ "${tail_text}" == *"Allow once"* || "${tail_text}" == *"Allow always"* ]]; then
    return 0
  fi

  if [[ "${tail_text}" == *"[y/N]"* || "${tail_text}" == *"[Y/n]"* ]]; then
    return 0
  fi

  return 1
}

prompt_type() {
  local tail_text
  tail_text="$(screen_tail "${1:-}")"

  if [[ "${tail_text}" == *"Would you like to run the following command?"* ]]; then
    printf 'codex_command_approval'
  elif [[ "${tail_text}" == *"Do you want to proceed?"* ]]; then
    printf 'proceed_confirmation'
  elif [[ "${tail_text}" == *"Allow once"* || "${tail_text}" == *"Allow always"* ]]; then
    printf 'tool_permission_prompt'
  elif [[ "${tail_text}" == *"[y/N]"* || "${tail_text}" == *"[Y/n]"* ]]; then
    printf 'yes_no_prompt'
  else
    printf 'approval_prompt'
  fi
}

command_summary() {
  local screen="$1"
  local command=""

  command="$(printf '%s\n' "${screen}" | rg -m1 '^[[:space:]]*\$ ' | sed 's/^[[:space:]]*\$ //')"
  if [[ -n "${command}" ]]; then
    printf '%s' "${command}"
    return 0
  fi

  command="$(printf '%s\n' "${screen}" | rg -m1 '^[[:space:]]*(git|bash|sh|uv|python|pytest|cmux|zmx|ls|cat|sed|rg|find)\b' | sed 's/^[[:space:]]*//')"
  if [[ -n "${command}" ]]; then
    printf '%s' "${command}"
    return 0
  fi

  printf 'interactive approval'
}

why_needed() {
  local summary="$1"

  if printf '%s\n' "${summary}" | rg -qi '(^|[[:space:]])rm[[:space:]]+-rf([[:space:]]|$)|git[[:space:]]+push([^\n])*--force|DROP[[:space:]]+TABLE|credential|secret|token'; then
    printf 'genuinely_risky'
  elif printf '%s\n' "${summary}" | rg -qi '^(git status|git diff|ls|cat|sed|rg|find|pwd|echo|head|tail|wc|which|env|cmux tree|cmux read-screen)\b'; then
    printf 'safe_but_not_preapproved'
  else
    printf 'unknown'
  fi
}

dangerous_summary() {
  printf '%s\n' "${1:-}" | rg -qi "$(_dangerous_regex)"
}

# Shared regex for both slow-path (this script) and fast-path
# (cmux-approval-watch.sh). Keep the two in sync when editing.
_dangerous_regex() {
  printf '%s' '(^|[[:space:]])rm[[:space:]]+-([rRfF]+|[rR][[:space:]]|[fF][[:space:]])|git[[:space:]]+push([^\n])*(--force|[[:space:]]-f([[:space:]]|$))|git[[:space:]]+reset[[:space:]]+--hard|curl[^\n|]*\|[[:space:]]*(sh|bash)|DROP[[:space:]]+TABLE|credential|secret|token'
}

# Per-surface recent-approval cooldown, shared with cmux-approval-watch.sh
# via the approver runtime dir. Both paths stamp the file after sending
# enter; both paths skip sending enter if the file is younger than the
# cooldown window. Prevents the fast+slow double-approval race where the
# second enter approves the NEXT prompt blindly.
_recent_approval_path() {
  local workspace_id="$1" surface_id="$2" safe_ws safe_surface
  safe_ws="$(printf '%s' "${workspace_id}" | tr -c 'A-Za-z0-9_.-' '_')"
  safe_surface="$(printf '%s' "${surface_id}" | tr -c 'A-Za-z0-9_.-' '_')"
  printf '%s/approvals/%s-%s.ts' "${RUNTIME_DIR}" "${safe_ws}" "${safe_surface}"
}

_recent_approval_active() {
  local workspace_id="$1" surface_id="$2" window="${3:-3}" path now mtime age
  path="$(_recent_approval_path "${workspace_id}" "${surface_id}")"
  [[ -f "${path}" ]] || return 1
  now="$(date +%s)"
  mtime="$(stat -f %m "${path}" 2>/dev/null || stat -c %Y "${path}" 2>/dev/null || printf '0')"
  age=$(( now - mtime ))
  (( age < window ))
}

_recent_approval_mark() {
  local workspace_id="$1" surface_id="$2" path
  path="$(_recent_approval_path "${workspace_id}" "${surface_id}")"
  mkdir -p "$(dirname -- "${path}")"
  : > "${path}"
}

log_decision() {
  local workspace_id="$1"
  local surface_id="$2"
  local title="$3"
  local type="$4"
  local summary="$5"
  local decision="$6"
  local why="$7"
  local approvals="$8"

  jq -nc \
    --arg timestamp "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
    --arg workspace "${workspace_id}" \
    --arg surface "${surface_id}" \
    --arg worker_slot "${title}" \
    --arg prompt_type "${type}" \
    --arg command_summary "${summary}" \
    --arg decision "${decision}" \
    --arg why_needed "${why}" \
    --argjson approvals "${approvals}" \
    '{timestamp:$timestamp,workspace:$workspace,surface:$surface,worker_slot:$worker_slot,prompt_type:$prompt_type,command_summary:$command_summary,decision:$decision,why_needed:$why_needed,approvals:$approvals}' \
    >> "${DECISIONS_FILE}"

  log_runtime \
    "decision=${decision} workspace=${workspace_id} surface=${surface_id} prompt_type=${type} why=${why} approvals=${approvals} summary=$(printf '%s' "${summary}" | tr '\n' ' ' | cut -c1-160)"
}

scan_tree() {
  cmux tree --all 2>/dev/null | awk '
    /workspace:[0-9]+/ {
      match($0, /workspace:[0-9]+/)
      ws = substr($0, RSTART, RLENGTH)
    }
    /surface:[0-9]+.*\[terminal\]/ {
      match($0, /surface:[0-9]+/)
      sf = substr($0, RSTART, RLENGTH)
      title = ""
      if (match($0, /"[^"]+"/)) {
        title = substr($0, RSTART + 1, RLENGTH - 2)
      }
      print ws "\t" sf "\t" title
    }
  '
}

approve_surface() {
  local workspace_id="$1"
  local surface_id="$2"
  local title="$3"
  local screen=""
  local summary=""
  local kind=""
  local reason=""
  local approvals=0

  while (( approvals < 3 )); do
    screen="$(cmux read-screen --surface "${surface_id}" --workspace "${workspace_id}" --lines 80 2>/dev/null || true)"
    [[ -n "${screen}" ]] || break
    prompt_present "${screen}" || break

    kind="$(prompt_type "${screen}")"
    summary="$(command_summary "${screen}")"
    reason="$(why_needed "${summary}")"

    if dangerous_summary "${summary}"; then
      log_decision "${workspace_id}" "${surface_id}" "${title}" "${kind}" "${summary}" "skipped" "${reason}" "${approvals}"
      return 0
    fi

    # M9: Claude "Allow" prompts show the currently-highlighted choice
    # with a caret glyph (❯ or ›). If the highlight sits on "Allow always",
    # approving would grant persistent tool permission for this session.
    # Don't auto-grant — let the human pick. The slow-path approver still
    # records that it observed the prompt.
    if printf '%s\n' "${screen}" | rg -q -e '^[[:space:]]*[›❯][[:space:]]+Allow always'; then
      log_decision "${workspace_id}" "${surface_id}" "${title}" "${kind}" "${summary}" "skipped" "allow_always_requires_human" "${approvals}"
      return 0
    fi

    if _recent_approval_active "${workspace_id}" "${surface_id}" 3; then
      break
    fi

    "${RUNTIME_DIR}/send-key.sh" --surface "${surface_id}" --workspace "${workspace_id}" enter >/dev/null 2>&1 || true
    _recent_approval_mark "${workspace_id}" "${surface_id}"
    approvals=$((approvals + 1))
    sleep 1
  done

  if (( approvals > 0 )); then
    log_decision "${workspace_id}" "${surface_id}" "${title}" "${kind:-approval_prompt}" "${summary:-interactive approval}" "approved" "${reason:-unknown}" "${approvals}"
  fi
}

scan_once() {
  local workspace_id=""
  local surface_id=""
  local title=""

  refresh_self_context

  while IFS=$'\t' read -r workspace_id surface_id title; do
    [[ -n "${workspace_id}" && -n "${surface_id}" ]] || continue
    [[ "${workspace_id}" == "${self_workspace}" && "${surface_id}" == "${self_surface}" ]] && continue
    [[ "${title}" == "daemon-log" ]] && continue
    approve_surface "${workspace_id}" "${surface_id}" "${title}"
  done < <(scan_tree)
}

run_loop() {
  local next_heartbeat
  if [[ -f "${PID_FILE}" ]]; then
    existing_pid="$(tr -d '[:space:]' < "${PID_FILE}" 2>/dev/null || true)"
    if [[ "${existing_pid}" =~ ^[0-9]+$ ]] && kill -0 "${existing_pid}" 2>/dev/null; then
      log_runtime "scan loop already running existing_pid=${existing_pid}"
      exit 0
    fi
  fi

  printf '%s\n' "$$" > "${PID_FILE}"
  trap 'rm -f "${PID_FILE}"' EXIT
  next_heartbeat=$(( $(date +%s) + 30 ))
  log_runtime "scan loop started pid=$$ interval=${interval}s"

  while :; do
    scan_once
    if (( $(date +%s) >= next_heartbeat )); then
      log_runtime "heartbeat pid=$$ interval=${interval}s"
      next_heartbeat=$(( $(date +%s) + 30 ))
    fi
    sleep "${interval}"
  done
}

mkdir -p "${RUNTIME_DIR}" "$(dirname "${DECISIONS_FILE}")"
: >> "${LOOP_LOG}"

case "${mode}" in
  once) scan_once ;;
  loop) run_loop ;;
esac
