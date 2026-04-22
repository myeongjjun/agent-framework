#!/usr/bin/env bash
#
# protocol.sh — sourceable requester-side helpers for the Stage 0.2
# orchestrator agent protocol.
#
# Exit codes (consistent across all helpers that return status):
#   0 — ok (operation succeeded, or the orchestrator returned status=ok)
#   1 — orchestrator not running (sentinel missing or pid dead)
#   2 — timeout (orchestrator did not respond within timeout_seconds)
#   3 — orchestrator returned status=error or status=partial
#   4 — protocol error (schema mismatch, bash version wrong, IO failure)
#
# Cherry-picked from Worker A cross-review: exit-code table comment.
#
# shellcheck shell=bash

if [[ -z "${BASH_VERSION:-}" ]]; then
  echo "protocol.sh: bash is required" >&2
  return 4 2>/dev/null || exit 4
fi

ORCHESTRATOR_PROTOCOL_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
ORCHESTRATOR_EFFECTS_DIR="${ORCHESTRATOR_PROTOCOL_DIR}/effects"

_orchestrator_repo_root() {
  cd -- "${ORCHESTRATOR_PROTOCOL_DIR}/../.." && pwd
}

: <<'__ORCHESTRATOR_PROTOCOL_SPEC__'
Stage 0.2 Request / Response Protocol

Request file path:
  ~/.claude/orchestrator/inbox/req-<uuid>.md

Request file format:
  ---
  schema_version: 1
  id: <uuid>
  type: dispatch | collab | inject | status | gc | tidy | resume | rotate | shutdown
  slug: <optional, kebab-case>
  requester:
    slot: <requester zmx slot or "-" if unknown>
    project: <absolute path or "-">
    session_id: <claude session id or "-">
    cmux_workspace_id: <workspace:N or "-" if unknown>
  created_at: <iso8601>
  response_path: ~/.claude/orchestrator/outbox/res-<uuid>.md
  timeout_seconds: <int, default 60>
  ---

  ## Payload
  <type-specific structured markdown>

Response file path:
  ~/.claude/orchestrator/outbox/res-<uuid>.md

Response file format:
  ---
  schema_version: 1
  id: <matching uuid>
  status: ok | error | partial
  processed_by: orchestrator
  processed_at: <iso8601>
  duration_ms: <int>
  ---

  ## Result
  <type-specific structured markdown>

  ## Error (only if status=error)
  <error message + stack if relevant>
__ORCHESTRATOR_PROTOCOL_SPEC__

_orchestrator_root() {
  printf '%s\n' "${ORCHESTRATOR_ROOT:-${HOME}/.orchestrator}"
}

# Agent runtime helpers.
# Orchestrator keeps its control-plane state under ~/.orchestrator while
# approver uses its own dedicated runtime root (~/.approver).

_agent_runtime_root() {
  local agent_name="${1:?_agent_runtime_root requires agent name}"
  case "${agent_name}" in
    orchestrator)
      _orchestrator_root
      ;;
    approver)
      printf '%s\n' "${APPROVER_ROOT:-${HOME}/.approver}"
      ;;
    *)
      printf '%s/agents/%s\n' "$(_orchestrator_root)" "${agent_name}"
      ;;
  esac
}

_agent_dir() {
  local agent_name="${1:?_agent_dir requires agent name}"
  case "${agent_name}" in
    orchestrator)
      printf '%s/agents/%s\n' "$(_orchestrator_root)" "${agent_name}"
      ;;
    *)
      _agent_runtime_root "${agent_name}"
      ;;
  esac
}

_agent_metadata_file() {
  local agent_name="${1:?}" key="${2:?}"
  printf '%s/%s\n' "$(_agent_dir "${agent_name}")" "${key}"
}

_agent_recorded_pid() {
  local agent_name="${1:?}" pid_file pid
  pid_file="$(_agent_metadata_file "${agent_name}" pid)"
  [[ -f "${pid_file}" ]] || return 1
  pid="$(tr -d '[:space:]' < "${pid_file}")"
  [[ "${pid}" =~ ^[0-9]+$ ]] || return 1
  printf '%s\n' "${pid}"
}

_agent_discover_pid() {
  local agent_name="${1:?}" backend_file backend_name slot_file slot_name candidate pid

  backend_file="$(_agent_metadata_file "${agent_name}" backend)"
  backend_name="$(tr -d '[:space:]' < "${backend_file}" 2>/dev/null || true)"

  case "${backend_name}" in
    daemon)
      if ! command -v pgrep >/dev/null 2>&1; then
        return 1
      fi
      if [[ "${agent_name}" == "approver" ]]; then
        candidate="$(_agent_dir "${agent_name}")/approver-scan.sh --loop"
        pid="$(pgrep -f -- "${candidate}" 2>/dev/null | head -1 || true)"
        if [[ "${pid}" =~ ^[0-9]+$ ]] && kill -0 "${pid}" 2>/dev/null; then
          printf '%s\n' "${pid}"
          return 0
        fi
      fi
      for candidate in \
        "${ORCHESTRATOR_PROTOCOL_DIR}/daemon.sh --foreground" \
        "$(_orchestrator_root)/scripts/orchestrator/daemon.sh --foreground"
      do
        pid="$(pgrep -f -- "${candidate}" 2>/dev/null | head -1 || true)"
        if [[ "${pid}" =~ ^[0-9]+$ ]] && kill -0 "${pid}" 2>/dev/null; then
          printf '%s\n' "${pid}"
          return 0
        fi
      done
      ;;
    *)
      if ! command -v pgrep >/dev/null 2>&1; then
        return 1
      fi
      slot_file="$(_agent_metadata_file "${agent_name}" slot)"
      slot_name="$(tr -d '[:space:]' < "${slot_file}" 2>/dev/null || true)"
      if [[ -z "${slot_name}" ]]; then
        slot_name="$(_agent_slot_name "${agent_name}" 2>/dev/null || true)"
      fi
      [[ -n "${slot_name}" ]] || return 1
      pid="$(pgrep -f -- "zmx attach ${slot_name}" 2>/dev/null | head -1 || true)"
      if [[ "${pid}" =~ ^[0-9]+$ ]] && kill -0 "${pid}" 2>/dev/null; then
        printf '%s\n' "${pid}"
        return 0
      fi
      ;;
  esac

  return 1
}

_agent_pid() {
  local agent_name="${1:?}" pid_file pid
  pid_file="$(_agent_metadata_file "${agent_name}" pid)"

  if [[ "${agent_name}" == "approver" ]]; then
    local scan_pid_file scan_pid
    scan_pid_file="$(_agent_metadata_file "${agent_name}" scan.pid)"
    if [[ -f "${scan_pid_file}" ]]; then
      scan_pid="$(tr -d '[:space:]' < "${scan_pid_file}" 2>/dev/null || true)"
      if [[ "${scan_pid}" =~ ^[0-9]+$ ]] && kill -0 "${scan_pid}" 2>/dev/null; then
        mkdir -p "$(dirname "${pid_file}")"
        printf '%s\n' "${scan_pid}" > "${pid_file}"
        printf '%s\n' "${scan_pid}"
        return 0
      fi
    fi
  fi

  pid="$(_agent_recorded_pid "${agent_name}" 2>/dev/null || true)"
  if [[ "${pid}" =~ ^[0-9]+$ ]] && kill -0 "${pid}" 2>/dev/null; then
    printf '%s\n' "${pid}"
    return 0
  fi

  pid="$(_agent_discover_pid "${agent_name}" 2>/dev/null || true)"
  if [[ "${pid}" =~ ^[0-9]+$ ]]; then
    mkdir -p "$(dirname "${pid_file}")"
    printf '%s\n' "${pid}" > "${pid_file}"
    printf '%s\n' "${pid}"
    return 0
  fi

  return 1
}

_agent_started() {
  local agent_name="${1:?}" running_file
  running_file="$(_agent_metadata_file "${agent_name}" RUNNING)"
  [[ -f "${running_file}" ]]
}

# _iso8601_to_epoch <iso>  →  prints epoch seconds, or nothing on failure
# Accepts either "2026-04-20T12:34:56Z" or similar UTC ISO 8601 strings.
_iso8601_to_epoch() {
  local iso="${1:-}"
  [[ -n "${iso}" && "${iso}" != "-" ]] || return 1
  # macOS BSD date
  date -ju -f "%Y-%m-%dT%H:%M:%SZ" "${iso}" +%s 2>/dev/null && return 0
  # GNU date
  date -u -d "${iso}" +%s 2>/dev/null
}

# _agent_pid_state <pid>  →  prints one of: alive | dead | restricted
#
# alive      kill -0 succeeded — process exists and we can signal it
# dead       kill -0 failed with ESRCH ("No such process")
# restricted kill -0 failed with EPERM ("Operation not permitted"):
#            the process likely exists but this session cannot signal
#            it (sandbox, different namespace, other user). Callers
#            must NOT conclude the process is gone — defer to an IPC
#            or heartbeat check.
_agent_pid_state() {
  local pid="${1:-}"
  [[ "${pid}" =~ ^[0-9]+$ ]] || { printf 'dead'; return; }
  local err rc
  err="$(kill -0 "${pid}" 2>&1)"
  rc=$?
  if (( rc == 0 )); then
    printf 'alive'
    return
  fi
  if printf '%s' "${err}" | grep -qiE 'not permitted|eperm|operation not permitted'; then
    printf 'restricted'
  else
    printf 'dead'
  fi
}

_agent_alive() {
  local agent_name="${1:?}" running_file pid
  if [[ "${agent_name}" == "approver" ]]; then
    local scan_pid_file scan_pid
    running_file="$(_agent_metadata_file "${agent_name}" RUNNING)"
    [[ -f "${running_file}" ]] || return 1

    scan_pid_file="$(_agent_metadata_file "${agent_name}" scan.pid)"
    [[ -f "${scan_pid_file}" ]] || return 1
    scan_pid="$(tr -d '[:space:]' < "${scan_pid_file}" 2>/dev/null || true)"
    [[ "${scan_pid}" =~ ^[0-9]+$ ]] || return 1
    kill -0 "${scan_pid}" 2>/dev/null || return 1

    return 0
  fi

  running_file="$(_agent_metadata_file "${agent_name}" RUNNING)"
  [[ -f "${running_file}" ]] || return 1
  pid="$(_agent_pid "${agent_name}")" || return 1
  kill -0 "${pid}" 2>/dev/null
}

_zmx_slot_unreachable() {
  local slot_name="${1:?}" slot_line
  command -v zmx >/dev/null 2>&1 || return 1
  slot_line="$(zmx list 2>/dev/null | grep -F "name=${slot_name}" || true)"
  [[ -n "${slot_line}" ]] || return 1
  [[ "${slot_line}" == *"status=unreachable"* ]]
}

_zmx_socket_dir() {
  local runtime_base=''
  if [[ -n "${ZMX_DIR:-}" ]]; then
    runtime_base="${ZMX_DIR}"
  elif [[ -n "${XDG_RUNTIME_DIR:-}" ]]; then
    runtime_base="${XDG_RUNTIME_DIR}/zmx"
  elif [[ -n "${TMPDIR:-}" ]]; then
    runtime_base="${TMPDIR%/}/zmx-$(id -u)"
  else
    runtime_base="/tmp/zmx-$(id -u)"
  fi
  printf '%s\n' "${runtime_base}"
}

_zmx_remove_slot_socket() {
  local slot_name="${1:?}"
  local socket_path
  socket_path="$(_zmx_socket_dir)/${slot_name}"
  rm -f "${socket_path}" 2>/dev/null || true
}

_cmux_tree_snapshot() {
  # Returns the cmux tree with both refs and UUIDs so callers can look
  # up surfaces/panes/workspaces by UUID. Older cmux versions may not
  # support --id-format; fall back to plain tree in that case.
  command -v cmux >/dev/null 2>&1 || return 0
  cmux --id-format both tree --all 2>/dev/null \
    || cmux tree --all 2>/dev/null \
    || true
}

_cmux_workspace_for_surface() {
  local snapshot="${1:-}" surface_id="${2:-}"
  [[ -n "${snapshot}" && -n "${surface_id}" ]] || return 1
  awk -v target_sf="${surface_id}" '
    /workspace:[0-9]+/ {
      match($0, /workspace:[0-9]+/)
      ws = substr($0, RSTART, RLENGTH)
    }
    index($0, target_sf) {
      if (ws != "") {
        print ws
        exit
      }
    }
  ' <<<"${snapshot}"
}

_cmux_resolve_workspace_ref() {
  # Convert a CMUX_WORKSPACE_ID (ref or UUID) to a workspace:N ref.
  #
  # CAUTION: `cmux identify --workspace <UUID>` silently falls back to
  # the currently focused workspace when the UUID does not exist — that
  # would mis-route dispatches to whichever workspace the user happens
  # to be looking at. We verify the UUID by looking it up in
  # `cmux list-workspaces --id-format both`, which is the authoritative
  # UUID→ref mapping.
  local raw="${1:-}"
  [[ -n "${raw}" ]] || return 1

  # Already a ref
  if [[ "${raw}" =~ ^workspace:[0-9]+$ ]]; then
    printf '%s\n' "${raw}"
    return 0
  fi

  # UUID — look up exact match in list-workspaces
  if [[ "${raw}" =~ ^[0-9A-Fa-f-]{36}$ ]]; then
    local uuid_lc ref
    uuid_lc="$(printf '%s' "${raw}" | tr '[:upper:]' '[:lower:]')"
    ref="$(cmux --id-format both list-workspaces 2>/dev/null \
           | awk -v target="${uuid_lc}" '
               {
                 line = tolower($0)
                 if (index(line, target) > 0) {
                   match($0, /workspace:[0-9]+/)
                   if (RSTART > 0) {
                     print substr($0, RSTART, RLENGTH)
                     exit
                   }
                 }
               }' || true)"
    if [[ "${ref}" =~ ^workspace:[0-9]+$ ]]; then
      printf '%s\n' "${ref}"
      return 0
    fi
  fi

  return 1
}

_cmux_resolve_surface_ref() {
  # Convert a CMUX_SURFACE_ID (ref or UUID) to a surface:N ref.
  local raw="${1:-}"
  [[ -n "${raw}" ]] || return 1

  # Already a ref
  if [[ "${raw}" =~ ^surface:[0-9]+$ ]]; then
    printf '%s\n' "${raw}"
    return 0
  fi

  # UUID — search cmux tree for the UUID
  if [[ "${raw}" =~ ^[0-9A-Fa-f-]{36}$ ]]; then
    local snapshot ref
    snapshot="$(_cmux_tree_snapshot)"
    ref="$(awk -v uuid="${raw}" '
      /surface:[0-9]+/ && index($0, uuid) {
        match($0, /surface:[0-9]+/)
        print substr($0, RSTART, RLENGTH)
        exit
      }
    ' <<<"${snapshot}")" || true
    if [[ "${ref}" =~ ^surface:[0-9]+$ ]]; then
      printf '%s\n' "${ref}"
      return 0
    fi
  fi

  return 1
}

_orchestrator_requester_workspace_ref() {
  # Try direct resolution of CMUX_WORKSPACE_ID (ref or UUID)
  if [[ -n "${CMUX_WORKSPACE_ID:-}" ]]; then
    local resolved
    resolved="$(_cmux_resolve_workspace_ref "${CMUX_WORKSPACE_ID}" 2>/dev/null || true)"
    if [[ "${resolved}" =~ ^workspace:[0-9]+$ ]]; then
      printf '%s\n' "${resolved}"
      return 0
    fi
  fi

  # Fallback: derive workspace from surface ID
  if [[ -n "${CMUX_SURFACE_ID:-}" ]]; then
    local surface_ref snapshot derived
    surface_ref="$(_cmux_resolve_surface_ref "${CMUX_SURFACE_ID}" 2>/dev/null || true)"
    if [[ -n "${surface_ref}" ]]; then
      snapshot="$(_cmux_tree_snapshot)"
      derived="$(_cmux_workspace_for_surface "${snapshot}" "${surface_ref}" 2>/dev/null || true)"
      if [[ "${derived}" =~ ^workspace:[0-9]+$ ]]; then
        printf '%s\n' "${derived}"
        return 0
      fi
    fi
  fi

  # Last resort: the currently selected workspace from list-workspaces.
  # This is used when CMUX_WORKSPACE_ID/CMUX_SURFACE_ID are stale (cmux
  # was restarted after session start, so the UUIDs no longer match).
  # Opt-in: requires ORCHESTRATOR_ALLOW_SELECTED_WS_FALLBACK=1 to avoid
  # silently routing to a random focused workspace.
  if [[ "${ORCHESTRATOR_ALLOW_SELECTED_WS_FALLBACK:-0}" == "1" ]] \
    && command -v cmux >/dev/null 2>&1; then
    local selected
    selected="$(cmux list-workspaces 2>/dev/null \
                 | awk '/\[selected\]/ { match($0, /workspace:[0-9]+/); if (RSTART>0) { print substr($0, RSTART, RLENGTH); exit } }' || true)"
    if [[ "${selected}" =~ ^workspace:[0-9]+$ ]]; then
      printf '%s\n' "${selected}"
      return 0
    fi
  fi

  printf '%s\n' "-"
}

_agents_dir() {
  printf '%s/agents\n' "$(_orchestrator_root)"
}

_frontmatter_field() {
  local file_path="${1:?}" field_name="${2:?}"
  [[ -f "${file_path}" ]] || return 1

  awk -v key="${field_name}" '
    BEGIN { in_fm = 0 }
    /^---$/ { in_fm = !in_fm; next }
    in_fm && $0 ~ "^" key "[[:space:]]*:" {
      sub("^" key "[[:space:]]*:[[:space:]]*", "")
      gsub(/^["'\''"]/, "")
      gsub(/["'\''"]$/, "")
      print
      exit
    }
  ' "${file_path}"
}

_agent_definition_file() {
  local agent_name="${1:?}"
  local candidate

  for candidate in \
    "$(_orchestrator_repo_root)/agents/${agent_name}.md" \
    "${HOME}/.claude/agents/${agent_name}.md" \
    "${HOME}/.codex/agents/${agent_name}.md"; do
    if [[ -f "${candidate}" ]]; then
      printf '%s\n' "${candidate}"
      return 0
    fi
  done

  return 1
}

_agent_declared_family() {
  local agent_name="${1:?}" def_file family

  def_file="$(_agent_definition_file "${agent_name}" 2>/dev/null || true)"
  [[ -n "${def_file}" ]] || return 1

  family="$(_frontmatter_field "${def_file}" family 2>/dev/null || true)"
  case "${family}" in
    claude|codex)
      printf '%s\n' "${family}"
      ;;
    *)
      return 1
      ;;
  esac
}

_agent_declared_type() {
  local agent_name="${1:?}" def_file declared_type

  def_file="$(_agent_definition_file "${agent_name}" 2>/dev/null || true)"
  [[ -n "${def_file}" ]] || return 1

  declared_type="$(_frontmatter_field "${def_file}" type 2>/dev/null || true)"
  case "${declared_type}" in
    daemon|llm-agent|service)
      printf '%s\n' "${declared_type}"
      ;;
    *)
      return 1
      ;;
  esac
}

# Canonical slot name for an agent. Used by start-agent.sh, stop-agent.sh,
# health.sh — single source of truth for the naming convention.
_agent_slot_name() {
  local agent_name="${1:?}" agent_family="${2:-}"
  if [[ -z "${agent_family}" ]]; then
    agent_family="$(_agent_declared_family "${agent_name}" 2>/dev/null || true)"
  fi
  [[ -n "${agent_family}" ]] || agent_family='claude'
  printf '%s-%s-global\n' "${agent_family}" "${agent_name}"
}

# Validate agent name — reject path traversal, shell metacharacters.
_validate_agent_name() {
  local name="${1:?}"
  if [[ ! "${name}" =~ ^[a-z][a-z0-9_-]*$ ]]; then
    printf 'invalid agent name: %s (must match ^[a-z][a-z0-9_-]*$)\n' "${name}" >&2
    return 1
  fi
}

# Locked registry update. Accepts a jq filter and registry path.
# Handles lock acquire, stale lock detection (>60s), and cleanup trap.
_locked_registry_update() {
  local reg="${1:?}" jq_filter="${2:?}"
  local lock_dir="${reg}.lock.d"

  if [[ ! -f "${reg}" ]]; then
    mkdir -p "$(dirname "${reg}")"
    printf '{"schema_version":2,"agents":{}}\n' > "${reg}"
  fi

  # Stale lock detection: if lock dir is older than 60s, remove it
  if [[ -d "${lock_dir}" ]]; then
    local lock_age
    lock_age="$(( $(date +%s) - $(stat -f %m "${lock_dir}" 2>/dev/null || stat -c %Y "${lock_dir}" 2>/dev/null || echo 0) ))"
    if (( lock_age > 60 )); then
      rmdir "${lock_dir}" 2>/dev/null || true
    fi
  fi

  local acquired=0
  for _ in 1 2 3 4 5 6 7 8 9 10; do
    mkdir "${lock_dir}" 2>/dev/null && { acquired=1; break; }
    sleep 0.2
  done
  (( acquired == 1 )) || { printf 'failed to acquire registry lock\n' >&2; return 1; }

  # Release lock after jq completes. Use explicit cleanup (not trap RETURN)
  # because some callers run with set -u and nested subshells.
  local _lru_rc=0
  jq "(.schema_version = 2 | .agents = (.agents // {})) | ${jq_filter}" "${reg}" > "${reg}.tmp" \
    && mv "${reg}.tmp" "${reg}" || _lru_rc=$?
  rmdir "${lock_dir}" 2>/dev/null || true
  return "${_lru_rc}"
}

_list_registered_agents() {
  local agents_root registry
  agents_root="$(_agents_dir)"
  registry="${agents_root}/registry.json"
  if [[ -f "${registry}" ]]; then
    jq -r '.agents | keys[]' "${registry}" 2>/dev/null
  fi
}

# Backward-compat shims — callers that don't pass an agent name
# default to "orchestrator".
_orchestrator_agent_dir() {
  _agent_dir "orchestrator"
}

_orchestrator_metadata_file() {
  local key="$1"
  _agent_metadata_file "orchestrator" "${key}"
}

_orchestrator_pid() {
  _agent_pid "orchestrator"
}

_orchestrator_iso8601() {
  date -u +"%Y-%m-%dT%H:%M:%SZ"
}

_orchestrator_epoch_ns() {
  local raw
  raw="$(date +%s%N 2>/dev/null || true)"
  if [[ "${raw}" =~ ^[0-9]+$ ]]; then
    printf '%s\n' "${raw}"
    return 0
  fi
  printf '%s000000000\n' "$(date +%s)"
}

_orchestrator_uuid() {
  local raw
  if command -v uuidgen >/dev/null 2>&1; then
    uuidgen | tr '[:upper:]' '[:lower:]'
    return 0
  fi
  raw="$(_orchestrator_epoch_ns)"
  printf '%s-%s\n' "${raw}" "$$"
}

_orchestrator_frontmatter_value() {
  local file_path="$1"
  local field_name="$2"

  awk -F': ' -v key="${field_name}" '
    BEGIN { in_frontmatter = 0 }
    /^---$/ {
      if (in_frontmatter == 0) {
        in_frontmatter = 1
        next
      }
      exit
    }
    in_frontmatter == 1 && index($0, key ":") == 1 {
      sub("^" key ": ?", "", $0)
      print $0
      exit
    }
  ' "${file_path}"
}

_orchestrator_requester_slot() {
  printf '%s\n' "${ZMX_SESSION:-"-"}"
}

_orchestrator_requester_project() {
  if [[ "${PWD}" = /* ]]; then
    printf '%s\n' "${PWD}"
  else
    printf '%s\n' "-"
  fi
}

_orchestrator_requester_session_id() {
  if [[ -n "${CLAUDE_SESSION_ID:-}" ]]; then
    printf '%s\n' "${CLAUDE_SESSION_ID}"
  elif [[ -n "${CODEX_SESSION_ID:-}" ]]; then
    printf '%s\n' "${CODEX_SESSION_ID}"
  else
    printf '%s\n' "-"
  fi
}

_orchestrator_payload_body() {
  local payload="$1"
  if [[ -f "${payload}" ]]; then
    cat -- "${payload}"
  else
    printf '%s\n' "${payload}"
  fi
}

# --- Payload builders --------------------------------------------------------
# Type-safe constructors that produce the "- key: value" list format expected
# by conductor.sh parse_request_file(). Callers pass named args; the builder
# emits the payload string to stdout. Use with:
#   orchestrator_request --type dispatch --slug X --payload "$(build_dispatch_payload ...)"

build_dispatch_payload() {
  local slug='' description='' worker_family='' dry_run='false'
  local no_worktree='false' advisor_mode='' executor_tier='' keep_alive='' resume=''
  while (($# > 0)); do
    case "$1" in
      --slug)           shift; slug="$1" ;;
      --description)    shift; description="$1" ;;
      --worker-family)  shift; worker_family="$1" ;;
      --dry-run)        dry_run='true' ;;
      --no-worktree)    no_worktree='true' ;;
      --advisor-mode)   shift; advisor_mode="$1" ;;
      --executor-tier)  shift; executor_tier="$1" ;;
      --keep-alive)     keep_alive='true' ;;
      --resume)         resume='true' ;;
      *) printf 'build_dispatch_payload: unknown arg: %s\n' "$1" >&2; return 1 ;;
    esac
    shift
  done
  [[ -n "${slug}" ]] || { printf 'build_dispatch_payload: --slug required\n' >&2; return 1; }
  [[ -n "${description}" ]] || { printf 'build_dispatch_payload: --description required\n' >&2; return 1; }

  printf -- '- slug: %s\n' "${slug}"
  printf -- '- description: %s\n' "${description}"
  [[ -n "${worker_family}" ]] && printf -- '- worker_family: %s\n' "${worker_family}" || true
  [[ "${dry_run}" == "true" ]] && printf -- '- dry_run: true\n' || true
  [[ "${no_worktree}" == "true" ]] && printf -- '- no_worktree: true\n' || true
  [[ -n "${advisor_mode}" ]] && printf -- '- advisor_mode: %s\n' "${advisor_mode}" || true
  [[ -n "${executor_tier}" ]] && printf -- '- executor_tier: %s\n' "${executor_tier}" || true
  [[ "${keep_alive}" == "true" ]] && printf -- '- keep_alive: true\n' || true
  [[ "${resume}" == "true" ]] && printf -- '- resume: true\n' || true
}

build_tidy_payload() {
  local dry_run='false'
  local slugs=()
  while (($# > 0)); do
    case "$1" in
      --dry-run)  dry_run='true' ;;
      --slug)     shift; slugs+=("$1") ;;
      *) printf 'build_tidy_payload: unknown arg: %s\n' "$1" >&2; return 1 ;;
    esac
    shift
  done

  [[ "${dry_run}" == "true" ]] && printf -- '- dry_run: true\n'
  if (( ${#slugs[@]} > 0 )); then
    local joined=""
    local s
    for s in "${slugs[@]}"; do
      [[ -n "${joined}" ]] && joined="${joined},"
      joined="${joined}${s}"
    done
    printf -- '- slugs: %s\n' "${joined}"
  fi
  # Payload may be empty (execute all done-class resources) — orchestrator_request
  # requires non-empty --payload, so emit at least a marker comment.
  if [[ "${dry_run}" != "true" ]] && (( ${#slugs[@]} == 0 )); then
    printf -- '- dry_run: false\n'
  fi
}

build_resume_payload() {
  local slug='' worker_family='' dry_run='false' keep_alive='false'
  while (($# > 0)); do
    case "$1" in
      --slug)           shift; slug="$1" ;;
      --worker-family)  shift; worker_family="$1" ;;
      --dry-run)        dry_run='true' ;;
      --keep-alive)     keep_alive='true' ;;
      *) printf 'build_resume_payload: unknown arg: %s\n' "$1" >&2; return 1 ;;
    esac
    shift
  done
  [[ -n "${slug}" ]] || { printf 'build_resume_payload: --slug required\n' >&2; return 1; }

  printf -- '- slug: %s\n' "${slug}"
  [[ -n "${worker_family}" ]] && printf -- '- worker_family: %s\n' "${worker_family}" || true
  [[ "${dry_run}" == "true" ]] && printf -- '- dry_run: true\n' || true
  [[ "${keep_alive}" == "true" ]] && printf -- '- keep_alive: true\n' || true
}

build_rotate_payload() {
  local entry_path='' surface_id='' dry_run='false'
  while (($# > 0)); do
    case "$1" in
      --entry-path)   shift; entry_path="$1" ;;
      --surface-id)   shift; surface_id="$1" ;;
      --dry-run)      dry_run='true' ;;
      *) printf 'build_rotate_payload: unknown arg: %s\n' "$1" >&2; return 1 ;;
    esac
    shift
  done
  [[ -n "${entry_path}" ]] || { printf 'build_rotate_payload: --entry-path required\n' >&2; return 1; }
  [[ -n "${surface_id}" ]] || { printf 'build_rotate_payload: --surface-id required\n' >&2; return 1; }

  printf -- '- entry_path: %s\n' "${entry_path}"
  printf -- '- surface_id: %s\n' "${surface_id}"
  printf -- '- dry_run: %s\n' "${dry_run}"
}

_orchestrator_detect_backend() {
  local detect_script detected_backend agent_backend
  detect_script="${ORCHESTRATOR_EFFECTS_DIR}/backends/detect.sh"
  [[ -r "${detect_script}" ]] || return 1

  # shellcheck source=/dev/null
  . "${detect_script}"
  detect_backend
  detected_backend="${BACKEND:-unknown}"
  agent_backend="$(orchestrator_backend 2>/dev/null || true)"

  if [[ -n "${agent_backend}" ]]; then
    printf '%s\n' "${agent_backend}"
    return 0
  fi
  if [[ "${detected_backend}" != "unknown" ]]; then
    printf '%s\n' "${detected_backend}"
    return 0
  fi
  return 1
}

_orchestrator_notification_script() {
  local backend="$1"
  printf '%s/backends/%s/inject.sh\n' "${ORCHESTRATOR_EFFECTS_DIR}" "${backend}"
}

_lock_dir_age_seconds() {
  local lock_dir="${1:?}"
  local lock_mtime now_epoch
  [[ -d "${lock_dir}" ]] || return 1

  lock_mtime="$(stat -f %m "${lock_dir}" 2>/dev/null || stat -c %Y "${lock_dir}" 2>/dev/null || echo 0)"
  [[ "${lock_mtime}" =~ ^[0-9]+$ ]] || return 1
  now_epoch="$(date +%s)"
  [[ "${now_epoch}" =~ ^[0-9]+$ ]] || return 1
  printf '%s\n' "$(( now_epoch - lock_mtime ))"
}

_clear_stale_lock_dir() {
  local lock_dir="${1:?}" max_age_seconds="${2:-60}"
  local lock_age
  [[ -d "${lock_dir}" ]] || return 1
  lock_age="$(_lock_dir_age_seconds "${lock_dir}" 2>/dev/null || true)"
  [[ "${lock_age}" =~ ^[0-9]+$ ]] || return 1
  if (( lock_age > max_age_seconds )); then
    rmdir "${lock_dir}" 2>/dev/null || true
    return 0
  fi
  return 1
}

_orchestrator_write_request() {
  local request_uuid="$1"
  local request_type="$2"
  local request_slug="$3"
  local payload_body="$4"
  local timeout_seconds="$5"
  local root_dir inbox_dir outbox_dir locks_dir response_path request_path
  local lock_path temp_path lock_fd

  root_dir="$(_orchestrator_root)"
  inbox_dir="${root_dir}/inbox"
  outbox_dir="${root_dir}/outbox"
  locks_dir="${root_dir}/locks"
  response_path="${outbox_dir}/res-${request_uuid}.md"
  request_path="${inbox_dir}/req-${request_uuid}.md"

  mkdir -p "${inbox_dir}" "${outbox_dir}" "${locks_dir}" || return 4

  # flock is preferred but unavailable on macOS by default. Fall back to
  # a directory-based mutex (mkdir is atomic on all POSIX filesystems)
  # when flock is missing. Exit code 4 is still used for unrecoverable
  # lock-acquisition failures.
  local have_flock=0
  local mkdir_lock=""
  if command -v flock >/dev/null 2>&1; then
    have_flock=1
    lock_path="${locks_dir}/inbox.lock"
    exec {lock_fd}> "${lock_path}" || return 4
    flock "${lock_fd}" || {
      exec {lock_fd}>&-
      return 4
    }
  else
    mkdir_lock="${locks_dir}/inbox.lock.d"
    local acquired=0
    for _ in 1 2 3 4 5 6 7 8 9 10; do
      if mkdir "${mkdir_lock}" 2>/dev/null; then
        acquired=1
        break
      fi
      _clear_stale_lock_dir "${mkdir_lock}" 60 >/dev/null 2>&1 || true
      sleep 0.1
    done
    (( acquired == 1 )) || return 4
  fi

  temp_path="$(mktemp "${inbox_dir}/.req-${request_uuid}.XXXXXX")" || {
    if (( have_flock == 1 )); then
      flock -u "${lock_fd}" || true
      exec {lock_fd}>&-
    else
      rmdir "${mkdir_lock}" 2>/dev/null || true
    fi
    return 4
  }

  {
    printf -- '---\n'
    printf 'schema_version: 1\n'
    printf 'id: %s\n' "${request_uuid}"
    printf 'type: %s\n' "${request_type}"
    if [[ -n "${request_slug}" ]]; then
      printf 'slug: %s\n' "${request_slug}"
    fi
    local _req_workspace_ref
    _req_workspace_ref="$(_orchestrator_requester_workspace_ref)"

    # Dispatch/collab requests require a valid workspace to route surfaces.
    # Refuse to send the request if workspace resolution failed — spawning
    # in the orchestrator's own workspace is never correct.
    if [[ "${request_type}" == "dispatch" || "${request_type}" == "collab" ]]; then
      if [[ "${_req_workspace_ref}" == "-" || -z "${_req_workspace_ref}" ]]; then
        printf 'error: cannot resolve requester workspace (CMUX_WORKSPACE_ID=%s). Dispatch aborted.\n' \
          "${CMUX_WORKSPACE_ID:-unset}" >&2
        rm -f "${temp_path}"
        if (( have_flock == 1 )); then
          flock -u "${lock_fd}" || true; exec {lock_fd}>&-
        else
          rmdir "${mkdir_lock}" 2>/dev/null || true
        fi
        return 4
      fi
    fi

    printf 'requester:\n'
    printf '  slot: %s\n' "$(_orchestrator_requester_slot)"
    printf '  project: %s\n' "$(_orchestrator_requester_project)"
    printf '  session_id: %s\n' "$(_orchestrator_requester_session_id)"
    printf '  cmux_workspace_id: %s\n' "${_req_workspace_ref}"
    printf 'created_at: %s\n' "$(_orchestrator_iso8601)"
    printf 'response_path: %s\n' "${response_path}"
    printf 'timeout_seconds: %s\n' "${timeout_seconds}"
    printf -- '---\n\n'
    printf '## Payload\n'
    printf '%s\n' "${payload_body}"
  } > "${temp_path}" || {
    rm -f "${temp_path}"
    if (( have_flock == 1 )); then
      flock -u "${lock_fd}" || true
      exec {lock_fd}>&-
    else
      rmdir "${mkdir_lock}" 2>/dev/null || true
    fi
    return 4
  }

  mv "${temp_path}" "${request_path}" || {
    rm -f "${temp_path}"
    if (( have_flock == 1 )); then
      flock -u "${lock_fd}" || true
      exec {lock_fd}>&-
    else
      rmdir "${mkdir_lock}" 2>/dev/null || true
    fi
    return 4
  }

  if (( have_flock == 1 )); then
    flock -u "${lock_fd}" || true
    exec {lock_fd}>&-
  else
    rmdir "${mkdir_lock}" 2>/dev/null || true
  fi
  printf '%s\n' "${request_path}"
}

# Generic agent state readers — pass agent name as first arg.
agent_surface_id() {
  local agent_name="${1:?}" file_path
  file_path="$(_agent_metadata_file "${agent_name}" surface_id)"
  [[ -f "${file_path}" ]] || return 1
  tr -d '[:space:]' < "${file_path}"
}

agent_surface_ok() {
  local agent_name="${1:?}" sid wid
  sid="$(agent_surface_id "${agent_name}" 2>/dev/null)" || return 1
  [[ -n "${sid}" ]] || return 1
  wid="$(agent_workspace_id "${agent_name}" 2>/dev/null)" || return 1
  [[ -n "${wid}" ]] || return 1
  command -v cmux >/dev/null 2>&1 || return 1
  cmux read-screen --surface "${sid}" --workspace "${wid}" --lines 1 >/dev/null 2>&1
}

agent_backend() {
  local agent_name="${1:?}" file_path backend
  file_path="$(_agent_metadata_file "${agent_name}" backend)"
  [[ -f "${file_path}" ]] || return 1
  backend="$(tr -d '[:space:]' < "${file_path}")"
  [[ -n "${backend}" ]] || return 1
  printf '%s\n' "${backend}"
}

agent_workspace_id() {
  local agent_name="${1:?}" ws_file
  ws_file="$(_agent_metadata_file "${agent_name}" workspace_id)"
  [[ -f "${ws_file}" ]] || return 1
  tr -d '[:space:]' < "${ws_file}"
}

# Backward-compat shims for orchestrator-specific callers.
orchestrator_alive() {
  _agent_alive "orchestrator"
}

orchestrator_surface_id() {
  agent_surface_id "orchestrator"
}

orchestrator_backend() {
  agent_backend "orchestrator"
}

orchestrator_request() {
  local request_type='' payload_arg='' request_slug='' timeout_seconds='60'
  local wait_mode='wait' request_uuid request_path response_path backend
  local inject_script notification_prompt response_status response_schema
  local response_id start_ns deadline_ns now_ns delay_index
  local payload_body delays

  while (($# > 0)); do
    case "$1" in
      --type)
        shift
        [[ $# -gt 0 ]] || return 4
        request_type="$1"
        ;;
      --payload)
        shift
        [[ $# -gt 0 ]] || return 4
        payload_arg="$1"
        ;;
      --slug)
        shift
        [[ $# -gt 0 ]] || return 4
        request_slug="$1"
        ;;
      --timeout)
        shift
        [[ $# -gt 0 ]] || return 4
        timeout_seconds="$1"
        ;;
      --wait)
        wait_mode='wait'
        ;;
      --no-wait)
        wait_mode='no-wait'
        ;;
      *)
        return 4
        ;;
    esac
    shift
  done

  [[ -n "${request_type}" ]] || return 4
  [[ -n "${payload_arg}" ]] || return 4
  [[ "${timeout_seconds}" =~ ^[0-9]+$ ]] || return 4
  if [[ -n "${request_slug}" ]] && [[ ! "${request_slug}" =~ ^[a-z0-9]+(-[a-z0-9]+)*$ ]]; then
    return 4
  fi
  orchestrator_alive || return 1

  request_uuid="$(_orchestrator_uuid)"
  payload_body="$(_orchestrator_payload_body "${payload_arg}")" || return 4
  request_path="$(_orchestrator_write_request \
    "${request_uuid}" \
    "${request_type}" \
    "${request_slug}" \
    "${payload_body}" \
    "${timeout_seconds}"
  )" || return 4

  backend="$(_orchestrator_detect_backend)" || return 4
  if [[ "${backend}" != "daemon" ]]; then
    inject_script="$(_orchestrator_notification_script "${backend}")"
    [[ -x "${inject_script}" ]] || return 4

    notification_prompt="process req-${request_uuid}"
    # Read the orchestrator's workspace id so we can pass --workspace to the
    # inject backend. Without this, cmux send fails with "Surface is not a
    # terminal" when the orchestrator lives in a different workspace than the
    # requester (which is always the case with a dedicated orchestrator
    # workspace). Daemon mode skips this because it polls the inbox directly.
    local orch_ws_args=()
    local orch_ws_id
    orch_ws_id="$(agent_workspace_id orchestrator 2>/dev/null || true)"
    [[ -n "${orch_ws_id}" ]] && orch_ws_args=(--workspace "${orch_ws_id}")
    "${inject_script}" \
      --execute \
      --as-prompt \
      "${orch_ws_args[@]}" \
      "$(orchestrator_surface_id)" \
      "${notification_prompt}" >/dev/null || return 4
  fi

  if [[ "${wait_mode}" == 'no-wait' ]]; then
    printf 'req-%s\n' "${request_uuid}"
    return 0
  fi

  response_path="$(_orchestrator_root)/outbox/res-${request_uuid}.md"
  start_ns="$(_orchestrator_epoch_ns)"
  deadline_ns=$((start_ns + timeout_seconds * 1000000000))
  delay_index=0
  delays=(0.2 0.5 1 2)

  while [[ ! -f "${response_path}" ]]; do
    now_ns="$(_orchestrator_epoch_ns)"
    if (( now_ns >= deadline_ns )); then
      return 2
    fi
    sleep "${delays[delay_index]}"
    if (( delay_index < ${#delays[@]} - 1 )); then
      delay_index=$((delay_index + 1))
    fi
  done

  response_schema="$(_orchestrator_frontmatter_value "${response_path}" schema_version)"
  response_id="$(_orchestrator_frontmatter_value "${response_path}" id)"
  response_status="$(_orchestrator_frontmatter_value "${response_path}" status)"
  [[ "${response_schema}" == "1" ]] || return 4
  [[ "${response_id}" == "${request_uuid}" ]] || return 4

  case "${response_status}" in
    ok|partial)
      cat -- "${response_path}"
      return 0
      ;;
    error)
      cat -- "${response_path}"
      return 3
      ;;
    *)
      return 4
      ;;
  esac
}
