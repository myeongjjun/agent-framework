#!/usr/bin/env bash
#
# daemon.sh — deterministic file-backed Global Session Orchestrator.
#
# Polls ${ORCHESTRATOR_ROOT}/inbox every 0.5s and routes request files to
# shell handlers. This replaces the persistent LLM orchestrator for purely
# mechanical routing.

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
REPO_SCRIPTS_DIR="$(cd -- "${SCRIPT_DIR}/.." && pwd)"
CONDUCTOR_SH="${REPO_SCRIPTS_DIR}/conductor.sh"
STATE_READ="${SCRIPT_DIR}/core/state-read.sh"
INJECT_EFFECT="${SCRIPT_DIR}/effects/inject-takeover.sh"
export ORCHESTRATOR_CALLER_TOKEN="daemon:$$"

# shellcheck source=/dev/null
. "${SCRIPT_DIR}/protocol.sh"

mode='run'
command_mode='run'
while (($# > 0)); do
  case "$1" in
    --once) mode='once' ;;
    --foreground) mode='run' ;;
    --ensure-approver) command_mode='ensure-approver' ;;
    --help|-h)
      sed -n '2,10p' "$0" >&2
      exit 0
      ;;
    *) printf 'daemon.sh: unknown argument: %s\n' "$1" >&2; exit 1 ;;
  esac
  shift
done

root_dir="$(_orchestrator_root)"
agent_name='orchestrator'
agent_dir="$(_agent_dir "${agent_name}")"
registry_file="$(_agents_dir)/registry.json"
inbox_dir="${root_dir}/inbox"
outbox_dir="${root_dir}/outbox"
processed_dir="${root_dir}/inbox-processed"
log_file="${root_dir}/activity.jsonl"
approver_name='approver'
approver_dir="$(_agent_dir "${approver_name}")"
approver_disabled_file="${approver_dir}/DISABLED"
approver_pid_file="${approver_dir}/pid"
approver_scan_pid_file="${approver_dir}/scan.pid"
approver_loop_log="${approver_dir}/loop.log"
approver_daemon_log="${approver_dir}/daemon.log"

stop_requested=0
shutdown_reason=""
runtime_started=0

die() {
  printf 'daemon.sh: %s\n' "$*" >&2
  exit 1
}

iso8601() {
  date -u +"%Y-%m-%dT%H:%M:%SZ"
}

epoch_ns() {
  _orchestrator_epoch_ns
}

duration_ms() {
  local start_ns="$1" end_ns
  end_ns="$(epoch_ns)"
  printf '%s\n' "$(( (end_ns - start_ns) / 1000000 ))"
}

json_activity() {
  mkdir -p "${root_dir}"
  printf '%s\n' "$1" >> "${log_file}"
}

frontmatter_value() {
  _orchestrator_frontmatter_value "$@"
}

payload_field() {
  local file_path="$1" key="$2"
  awk -v key="${key}" '
    BEGIN { in_payload=0; capture=0 }
    /^## Payload/ { in_payload=1; next }
    in_payload == 0 { next }
    capture == 1 {
      if ($0 ~ /^- [A-Za-z0-9_]+:/ || $0 ~ /^## /) {
        exit
      }
      line=$0
      sub(/^    /, "", line)
      sub(/^  /, "", line)
      print line
      next
    }
    $0 ~ ("^- " key ":") {
      line=$0
      sub("^- " key ":[[:space:]]*", "", line)
      if (line == "|") {
        capture=1
        next
      }
      print line
      exit
    }
  ' "${file_path}"
}

request_project() {
  awk '
    BEGIN { in_fm=0 }
    /^---$/ {
      if (in_fm == 0) { in_fm=1; next }
      exit
    }
    in_fm && /^  project:/ {
      sub(/^  project:[[:space:]]*/, "", $0)
      print $0
      exit
    }
  ' "$1"
}

request_workspace() {
  awk '
    BEGIN { in_fm=0 }
    /^---$/ {
      if (in_fm == 0) { in_fm=1; next }
      exit
    }
    in_fm && /^  cmux_workspace_id:/ {
      sub(/^  cmux_workspace_id:[[:space:]]*/, "", $0)
      print $0
      exit
    }
  ' "$1"
}

request_slot() {
  awk '
    BEGIN { in_fm=0 }
    /^---$/ {
      if (in_fm == 0) { in_fm=1; next }
      exit
    }
    in_fm && /^  slot:/ {
      sub(/^  slot:[[:space:]]*/, "", $0)
      print $0
      exit
    }
  ' "$1"
}

response_path_for() {
  local req_file="$1" response_path
  response_path="$(frontmatter_value "${req_file}" response_path)"
  if [[ -n "${response_path}" ]]; then
    printf '%s\n' "${response_path}"
    return 0
  fi
  printf '%s/res-%s.md\n' "${outbox_dir}" "$(frontmatter_value "${req_file}" id)"
}

write_response() {
  local req_file="$1" response_status="$2" body="$3" error_body="${4:-}" start_ns="$5"
  local request_id response_path tmp

  request_id="$(frontmatter_value "${req_file}" id)"
  response_path="$(response_path_for "${req_file}")"
  mkdir -p "$(dirname -- "${response_path}")"
  tmp="$(mktemp "${response_path}.tmp.XXXXXX")" || return 1
  {
    printf -- '---\n'
    printf 'schema_version: 1\n'
    printf 'id: %s\n' "${request_id}"
    printf 'status: %s\n' "${response_status}"
    printf 'processed_by: daemon\n'
    printf 'processed_at: %s\n' "$(iso8601)"
    printf 'duration_ms: %s\n' "$(duration_ms "${start_ns}")"
    printf -- '---\n\n'
    printf '## Result\n'
    printf '%s\n' "${body}"
    if [[ -n "${error_body}" ]]; then
      printf '\n## Error\n'
      printf '%s\n' "${error_body}"
    fi
  } > "${tmp}"
  mv "${tmp}" "${response_path}"
}

archive_request() {
  local req_file="$1" dest
  mkdir -p "${processed_dir}"
  dest="${processed_dir}/$(basename -- "${req_file}")"
  if [[ -e "${dest}" ]]; then
    dest="${processed_dir}/$(basename -- "${req_file}").$(date +%s)"
  fi
  mv "${req_file}" "${dest}"
}

command_status_from_json() {
  local output="$1"
  jq -r '.status // "ok"' <<<"${output}" 2>/dev/null || printf 'ok\n'
}

handle_dispatch() {
  local req_file="$1" dry_run mode_flag output rc
  dry_run="$(payload_field "${req_file}" dry_run)"
  mode_flag='--execute'
  [[ "${dry_run}" == "true" ]] && mode_flag='--dry-run'

  set +e
  output="$("${CONDUCTOR_SH}" dispatch --request "${req_file}" "${mode_flag}" 2>&1)"
  rc=$?
  set -e
  if (( rc == 0 )); then
    printf '%s\n' "${output}"
    return 0
  fi
  printf 'command: %q dispatch --request %q %s\nexit_code: %s\n\n%s\n' \
    "${CONDUCTOR_SH}" "${req_file}" "${mode_flag}" "${rc}" "${output}"
  return "${rc}"
}

handle_collab() {
  local req_file="$1" dry_run mode_flag output rc status
  dry_run="$(payload_field "${req_file}" dry_run)"
  mode_flag='--execute'
  [[ "${dry_run}" == "true" ]] && mode_flag='--dry-run'

  set +e
  output="$("${CONDUCTOR_SH}" collab --request "${req_file}" "${mode_flag}" 2>&1)"
  rc=$?
  set -e
  if (( rc != 0 )); then
    printf 'command: %q collab --request %q %s\nexit_code: %s\n\n%s\n' \
      "${CONDUCTOR_SH}" "${req_file}" "${mode_flag}" "${rc}" "${output}"
    return "${rc}"
  fi
  status="$(command_status_from_json "${output}")"
  printf '%s\n' "${output}"
  [[ "${status}" == "error" ]] && return 1
  return 0
}

handle_status() {
  local state tasks agents worktrees
  state="$("${STATE_READ}" --root "${root_dir}")"
  tasks="$(jq -r '
    (.tasks // {})
    | to_entries
    | group_by(.value.status // "unknown")
    | map("- " + (.[0].value.status // "unknown") + ": " + (length|tostring))
    | if length == 0 then "- none" else .[] end
  ' <<<"${state}")"
  agents="$(jq -r '
    (.agents // {})
    | to_entries
    | sort_by(.key)
    | map("- " + .key + ": " + (.value.status // "unknown"))
    | if length == 0 then "- none" else .[] end
  ' <<<"${state}")"
  worktrees="$(jq -r '
    [(.tasks // {})[] | .worktree_path // empty]
    | if length == 0 then "- none" else .[] | "- " + . end
  ' <<<"${state}")"

  printf '### Tasks\n%s\n\n### Agents\n%s\n\n### Worktrees\n%s\n' \
    "${tasks}" "${agents}" "${worktrees}"
}

handle_gc() {
  local req_file="$1" dry_run force mode_flag args output rc
  dry_run="$(payload_field "${req_file}" dry_run)"
  force="$(payload_field "${req_file}" force)"
  mode_flag='--execute'
  [[ "${dry_run}" == "true" ]] && mode_flag='--dry-run'

  args=(gc "${mode_flag}")
  [[ "${force}" == "true" ]] && args+=(--force)

  set +e
  output="$("${CONDUCTOR_SH}" "${args[@]}" 2>&1)"
  rc=$?
  set -e
  if (( rc == 0 )); then
    printf '%s\n' "${output}"
    return 0
  fi
  printf 'command: %q %s\nexit_code: %s\n\n%s\n' "${CONDUCTOR_SH}" "${args[*]}" "${rc}" "${output}"
  return "${rc}"
}

handle_tidy() {
  local req_file="$1" dry_run slugs_csv mode_flag args output rc
  dry_run="$(payload_field "${req_file}" dry_run)"
  slugs_csv="$(payload_field "${req_file}" slugs)"
  mode_flag='--execute'
  [[ "${dry_run}" == "true" ]] && mode_flag='--dry-run'

  args=(tidy "${mode_flag}")
  # Optional: comma-separated slugs to scope the tidy
  if [[ -n "${slugs_csv}" ]]; then
    local IFS=','
    local slug
    for slug in ${slugs_csv}; do
      slug="$(printf '%s' "${slug}" | tr -d '[:space:]')"
      [[ -n "${slug}" ]] && args+=("${slug}")
    done
  fi

  set +e
  output="$("${CONDUCTOR_SH}" "${args[@]}" 2>&1)"
  rc=$?
  set -e
  if (( rc == 0 )); then
    printf '%s\n' "${output}"
    return 0
  fi
  printf 'command: %q %s\nexit_code: %s\n\n%s\n' "${CONDUCTOR_SH}" "${args[*]}" "${rc}" "${output}"
  return "${rc}"
}

handle_resume() {
  local req_file="$1" slug dry_run agent_family keep_alive mode_flag args output rc
  local requester_workspace
  slug="$(payload_field "${req_file}" slug)"
  dry_run="$(payload_field "${req_file}" dry_run)"
  agent_family="$(payload_field "${req_file}" worker_family)"
  keep_alive="$(payload_field "${req_file}" keep_alive)"
  requester_workspace="$(request_workspace "${req_file}")"
  [[ -n "${slug}" ]] || { printf 'missing payload field: slug\n'; return 1; }
  [[ -n "${requester_workspace}" && "${requester_workspace}" != "-" ]] \
    || { printf 'requester.cmux_workspace_id is required\n'; return 1; }
  mode_flag='--execute'
  [[ "${dry_run}" == "true" ]] && mode_flag='--dry-run'

  args=(resume "${slug}" "${mode_flag}")
  [[ -n "${agent_family}" ]] && args+=(--agent "${agent_family}")
  [[ "${keep_alive}" == "true" ]] && args+=(--keep-alive)

  set +e
  output="$(ORCHESTRATOR_TARGET_WORKSPACE_ID="${requester_workspace}" "${CONDUCTOR_SH}" "${args[@]}" 2>&1)"
  rc=$?
  set -e
  if (( rc == 0 )); then
    printf '%s\n' "${output}"
    return 0
  fi
  printf 'command: %q %s\nexit_code: %s\n\n%s\n' "${CONDUCTOR_SH}" "${args[*]}" "${rc}" "${output}"
  return "${rc}"
}

handle_inject() {
  # All locals initialized to avoid set -u unbound errors in error-path
  # printf / jq when the caller reached this function via surface_id
  # without a slug (slot never resolves).
  local req_file="$1"
  local slug="" prompt="" surface_override=""
  local state="" slot="" surface="" workspace="" status=""
  local output="" rc=0
  slug="$(payload_field "${req_file}" slug)"
  prompt="$(payload_field "${req_file}" prompt)"
  surface_override="$(payload_field "${req_file}" surface_id)"
  [[ -n "${slug}" || -n "${surface_override}" ]] || { printf 'missing payload field: slug or surface_id\n'; return 1; }
  [[ -n "${prompt}" ]] || { printf 'missing payload field: prompt\n'; return 1; }

  state="$("${STATE_READ}" --root "${root_dir}")"

  # Resolve slot from slug (optional when surface_id is provided directly)
  if [[ -n "${slug}" ]]; then
    slot="$(jq -r --arg slug "${slug}" '.tasks[$slug].agents[0] // empty' <<<"${state}")"
    if [[ -n "${slot}" ]]; then
      status="$(jq -r --arg slot "${slot}" '.agents[$slot].status // "missing"' <<<"${state}")"
      [[ "${status}" == "running" ]] || { printf 'agent is not running (status: %s)\n' "${status}"; return 1; }
    fi
  fi

  surface="${surface_override}"
  if [[ -z "${surface}" && -n "${slot}" ]]; then
    surface="$(jq -r --arg slot "${slot}" '.agents[$slot].surface_id // empty' <<<"${state}")"
  fi
  [[ -n "${surface}" ]] || { printf 'cannot resolve surface_id (slug: %s, slot: %s)\n' "${slug:-<none>}" "${slot:-<none>}"; return 1; }

  if [[ -n "${surface_override}" ]]; then
    workspace="$(agent_workspace_id orchestrator 2>/dev/null || true)"
  else
    workspace="$(jq -r --arg slot "${slot}" '.agents[$slot].workspace_id // empty' <<<"${state}")"
  fi
  [[ -n "${workspace}" ]] || workspace="$(agent_workspace_id orchestrator 2>/dev/null || true)"
  [[ -n "${workspace}" ]] || { printf 'missing workspace_id for injection\n'; return 1; }

  set +e
  output="$(ORCHESTRATOR_BACKEND=cmux \
    ORCHESTRATOR_CALLER_TOKEN="${ORCHESTRATOR_CALLER_TOKEN:-daemon:$$}" \
    "${INJECT_EFFECT}" --execute --as-prompt --workspace "${workspace}" "${surface}" "${prompt}" 2>&1)"
  rc=$?
  set -e
  if (( rc != 0 )); then
    printf 'inject failed for slug=%s slot=%s surface=%s workspace=%s\n\n%s\n' \
      "${slug}" "${slot}" "${surface}" "${workspace}" "${output}"
    return "${rc}"
  fi

  jq -n \
    --arg slug "${slug}" \
    --arg slot "${slot}" \
    --arg surface_id "${surface}" \
    --arg workspace_id "${workspace}" \
    --arg injected_at "$(iso8601)" \
    --argjson prompt_length "${#prompt}" \
    --argjson effect "${output}" \
    '{slug:$slug, slot:$slot, surface_id:$surface_id, workspace_id:$workspace_id,
      prompt_length:$prompt_length, injected_at:$injected_at, effect:$effect}' | jq '.'
}

zmx_pid_for() {
  local slot="$1"
  # Require whitespace directly after ${slot} so prefix-matching doesn't
  # pick up sibling slots (e.g. `claude-agent-framework` must NOT match
  # the running `claude-agent-framework-2` or `...-ghost-*` lines).
  zmx list 2>/dev/null | sed -n "s/.*name=${slot}[[:space:]].*pid=\\([0-9][0-9]*\\).*/\\1/p" | head -1
}

wait_zmx_pid() {
  local slot="$1" old_pid="${2:-}" max_loops="${3:-20}" pid=''
  for _ in $(seq 1 "${max_loops}"); do
    pid="$(zmx_pid_for "${slot}")"
    if [[ -n "${pid}" && "${pid}" != "${old_pid}" ]]; then
      printf '%s\n' "${pid}"
      return 0
    fi
    sleep 1
  done
  return 1
}

wait_pid_gone() {
  local pid="$1" max_loops="${2:-10}"
  for _ in $(seq 1 "${max_loops}"); do
    kill -0 "${pid}" 2>/dev/null || return 0
    sleep 1
  done
  return 1
}

wait_zmx_gone() {
  local slot="$1" max_loops="${2:-5}"
  for _ in $(seq 1 "${max_loops}"); do
    if ! zmx list 2>/dev/null | grep -q "name=${slot}"; then
      return 0
    fi
    sleep 1
  done
  return 1
}

# Wait for a spawned agent's stdin to be live (accepting input), not just
# the process to exist. wait_zmx_pid only confirms the process is running,
# but cmux send + send-key at that point may race with stdin init: text
# gets buffered, enter gets dropped, prompt appears but doesn't submit.
#
# Polls the screen for agent-specific "ready" markers:
#   claude: "bypass permissions on" footer indicates input box wired up
#   codex:  gpt-<model> or "high fast" hint line appears when ready
wait_agent_ready() {
  local surface_id="$1" workspace="${2:-}" family="${3:-claude}" max_loops="${4:-30}"
  local ws_args=() _screen
  [[ -n "${workspace}" ]] && ws_args=(--workspace "${workspace}")
  for _ in $(seq 1 "${max_loops}"); do
    _screen="$(cmux read-screen --surface "${surface_id}" "${ws_args[@]}" --lines 15 2>/dev/null || true)"
    if [[ -n "${_screen}" ]]; then
      case "${family}" in
        claude)
          if printf '%s' "${_screen}" | grep -qE 'bypass permissions on'; then
            return 0
          fi
          ;;
        codex)
          if printf '%s' "${_screen}" | grep -qE 'gpt-[0-9]|high fast'; then
            return 0
          fi
          ;;
      esac
    fi
    sleep 1
  done
  return 1
}

# Check whether a candidate ghost slug collides with existing state.
# Returns 0 when in use, 1 when free. Consulting state.json (not zmx) is
# sufficient because conductor.sh registers every dispatched slug there,
# and a stale entry still wins because reusing a name would confuse
# Claude's `--resume <slug>` picker (two JSONLs answering to one name).
_ghost_slug_in_use() {
  local slug="$1" state
  state="$("${STATE_READ}" --root "${root_dir}" 2>/dev/null || true)"
  [[ -n "${state}" ]] || return 1
  jq -e --arg s "${slug}" '.tasks[$s] // false' <<<"${state}" >/dev/null 2>&1
}

# Derive a human-searchable ghost slug from the origin zmx slot so
# operators can find the archive later by grepping their slot name
# (e.g. `zmx list | grep agent-framework`). Falls back to timestamp
# suffix only if 99 sibling ghosts already exist for the same slot.
# Enforces validate_slug's 32-char / lowercase-kebab rule.
derive_ghost_slug() {
  local orig_zmx="$1" base prefix n candidate
  case "${orig_zmx}" in
    claude-*) base="${orig_zmx#claude-}" ;;
    codex-*)  base="${orig_zmx#codex-}" ;;
    *)        base="${orig_zmx}" ;;
  esac
  # Reserve 6 chars for "-ghost" and up to 3 for "-NN" so the total
  # stays within the 32-char slug limit even at the N=99 boundary.
  (( ${#base} > 23 )) && { base="${base:0:23}"; base="${base%-}"; }
  prefix="${base}-ghost"
  for (( n=1; n<=99; n++ )); do
    candidate="${prefix}-${n}"
    if ! _ghost_slug_in_use "${candidate}"; then
      printf '%s\n' "${candidate}"
      return 0
    fi
  done
  printf '%s-%s\n' "${prefix}" "$(date +%s)"
}

handle_rotate() {
  local req_file="$1" entry_path surface_id dry_run target_agent orig_zmx orig_workspace project_dir
  local orig_pid ghost_slug mode_flag ghost_desc ghost_output ghost_rc ghost_zmx attach_cmd attach_output takeover_output takeover_cmd
  local fresh_pid orig_family base_target target_zmx _n entry_session_id ghost_agent ghost_extra_args
  local _canonical_base _orig_suffix

  entry_path="$(payload_field "${req_file}" entry_path)"
  surface_id="$(payload_field "${req_file}" surface_id)"
  dry_run="$(payload_field "${req_file}" dry_run)"
  target_agent="$(payload_field "${req_file}" target_agent)"
  [[ -n "${target_agent}" ]] || target_agent='claude'
  case "${target_agent}" in
    claude|codex) ;;
    *) printf 'target_agent must be claude or codex\n'; return 1 ;;
  esac

  orig_zmx="$(request_slot "${req_file}")"
  orig_workspace="$(request_workspace "${req_file}")"
  project_dir="$(request_project "${req_file}")"
  [[ -n "${orig_zmx}" && "${orig_zmx}" != "-" ]] || { printf 'requester.slot is required\n'; return 1; }
  [[ -n "${project_dir}" && "${project_dir}" = /* ]] || { printf 'requester.project must be absolute\n'; return 1; }
  [[ -n "${orig_workspace}" && "${orig_workspace}" != "-" ]] || { printf 'requester.cmux_workspace_id is required\n'; return 1; }
  [[ -n "${surface_id}" ]] || { printf 'surface_id is required\n'; return 1; }
  [[ -n "${entry_path}" ]] || { printf 'entry_path is required\n'; return 1; }
  [[ "${entry_path}" = /* ]] || entry_path="${project_dir}/${entry_path}"
  [[ -f "${entry_path}" ]] || { printf 'entry_path not found: %s\n' "${entry_path}"; return 1; }

  orig_pid="$(zmx_pid_for "${orig_zmx}")"
  if [[ -z "${orig_pid}" ]]; then
    if [[ "${dry_run}" == "true" ]]; then
      orig_pid='DRY-RUN-PID'
    else
      printf 'could not resolve pid for requester slot: %s\n' "${orig_zmx}"
      return 1
    fi
  fi

  # Keep the archive in the requester's family so session continuation
  # uses the native resume path for that CLI. Cross-family rotation only
  # affects the fresh base target slot.
  case "${orig_zmx}" in
    claude-*) orig_family=claude; base_target="${target_agent}-${orig_zmx#claude-}" ;;
    codex-*)  orig_family=codex;  base_target="${target_agent}-${orig_zmx#codex-}" ;;
    *) printf 'unrecognized family prefix in orig_zmx: %s\n' "${orig_zmx}"; return 1 ;;
  esac
  if [[ "${orig_family}" == "${target_agent}" ]]; then
    # Same-family rotate: prefer migrating back to the canonical
    # (unnumbered) base slot when it's free. A numbered slot like
    # `claude-agent-framework-2` usually came from a past cross-family
    # collision bump; without this migration, every subsequent rotate
    # keeps the drift forever. Ghost slug still records the origin's
    # numbered form (e.g. `agent-framework-2-ghost-1`), preserving
    # the lineage for later lookup.
    _orig_suffix="${orig_zmx##*-}"
    _canonical_base="${orig_zmx%-*}"
    if [[ "${_orig_suffix}" =~ ^[0-9]+$ ]] \
        && [[ "${_canonical_base}" != "${orig_zmx}" ]] \
        && [[ -z "$(zmx_pid_for "${_canonical_base}")" ]]; then
      target_zmx="${_canonical_base}"
    else
      target_zmx="${orig_zmx}"
    fi
  else
    target_zmx="${base_target}"
    _n=2
    while [[ -n "$(zmx_pid_for "${target_zmx}")" ]]; do
      target_zmx="${base_target}-${_n}"
      _n=$(( _n + 1 ))
      (( _n > 99 )) && { printf 'too many collisions for base slot: %s\n' "${base_target}"; return 1; }
    done
  fi

  ghost_slug="$(derive_ghost_slug "${orig_zmx}")"
  ghost_agent="${orig_family}"
  case "${orig_family}" in
    claude)
      # -n <slug> sets the display name so a later `claude --resume <slug>`
      # can locate this continued session via the /resume picker's
      # name-match path. Without it the continuation inherits no stable
      # identifier and is unrecoverable by slug.
      ghost_extra_args="--continue -n ${ghost_slug}"
      ;;
    codex)
      entry_session_id="$(
        awk -F'|' '
          /^\| ID \|/ {
            gsub(/^[ \t]+|[ \t]+$/, "", $3)
            print $3
            exit
          }
        ' "${entry_path}"
      )"
      [[ -n "${entry_session_id}" && "${entry_session_id}" != "N/A" ]] \
        || { printf 'entry session id is required for codex-origin rotate: %s\n' "${entry_path}"; return 1; }
      ghost_extra_args="resume ${entry_session_id} --full-auto"
      ;;
  esac

  mode_flag='--execute'
  [[ "${dry_run}" == "true" ]] && mode_flag='--dry-run'
  ghost_desc="Ghost archive for rotation of ${orig_zmx}. Stay alive as a passive session archive. Do NOT self-cleanup or mark done. The user will inspect and clean up manually."

  set +e
  ghost_output="$(
    cd "${project_dir}" && \
      ORCHESTRATOR_TARGET_WORKSPACE_ID="${orig_workspace}" \
      ORCHESTRATOR_AGENT_EXTRA_ARGS="${ghost_extra_args}" \
      "${CONDUCTOR_SH}" dispatch "${ghost_slug}" "${ghost_desc}" "${mode_flag}" --agent "${ghost_agent}" --no-worktree --keep-alive 2>&1
  )"
  ghost_rc=$?
  set -e
  (( ghost_rc == 0 )) || { printf 'ghost dispatch failed\n\n%s\n' "${ghost_output}"; return "${ghost_rc}"; }
  ghost_zmx="$(jq -r '.plan.agents[0].slot // empty' <<<"${ghost_output}" 2>/dev/null || true)"

  case "${target_agent}" in
    claude) attach_cmd="zmx attach ${target_zmx} claude --dangerously-skip-permissions" ;;
    codex) attach_cmd="zmx attach ${target_zmx} codex --full-auto" ;;
  esac

  case "${target_agent}" in
    claude) takeover_cmd="/takeover" ;;
    codex) takeover_cmd='$takeover' ;;
  esac

  if [[ "${dry_run}" == "true" ]]; then
    attach_output="$(ORCHESTRATOR_BACKEND=cmux "${INJECT_EFFECT}" --dry-run --as-prompt --family "${target_agent}" --workspace "${orig_workspace}" "${surface_id}" "${attach_cmd}")"
    takeover_output="$(ORCHESTRATOR_BACKEND=cmux "${INJECT_EFFECT}" --dry-run --as-prompt --family "${target_agent}" --workspace "${orig_workspace}" "${surface_id}" "${takeover_cmd}")"
    jq -n \
      --arg orig_zmx "${orig_zmx}" \
      --arg orig_surface "${surface_id}" \
      --arg orig_workspace "${orig_workspace}" \
      --arg orig_pid "${orig_pid}" \
      --arg ghost_slug "${ghost_slug}" \
      --arg ghost_zmx "${ghost_zmx}" \
      --arg entry_path "${entry_path}" \
      --arg target_agent "${target_agent}" \
      --arg target_slot "${target_zmx}" \
      --argjson ghost_dispatch "${ghost_output}" \
      --argjson base_attach "${attach_output}" \
      --argjson takeover_inject "${takeover_output}" \
      '{rotate:{requester_slot:$orig_zmx, requester_surface:$orig_surface, requester_workspace:$orig_workspace,
        requester_pid:$orig_pid, ghost_slug:$ghost_slug, ghost_slot:$ghost_zmx, entry_path:$entry_path,
        target_agent:$target_agent, target_slot:$target_slot, kill_step:("kill -QUIT " + $orig_pid)},
        ghost_dispatch:$ghost_dispatch, base_attach:$base_attach, takeover_inject:$takeover_inject}' | jq '.'
    return 0
  fi

  [[ -n "${ghost_zmx}" ]] || { printf 'ghost dispatch did not return a slot\n'; return 1; }
  local ghost_pid
  ghost_pid="$(wait_zmx_pid "${ghost_zmx}" "" 20)" \
    || { printf 'ghost session did not become ready within 20s\n'; return 1; }

  # H12: verify the ghost is stable before killing the original. A zmx
  # session can have a pid entry the moment `zmx run` fires, but the
  # inner process may still be in the bootstrap window where stdin isn't
  # hooked up and no JSONL has been written yet. SIGQUIT'ing orig in that
  # window would strand the ghost without the archive it's about to read.
  # Poll the pid for 3 consecutive seconds of liveness before proceeding.
  local _stable=0
  for _ in 1 2 3; do
    if kill -0 "${ghost_pid}" 2>/dev/null; then
      _stable=$(( _stable + 1 ))
    else
      _stable=0
    fi
    sleep 1
  done
  if (( _stable < 3 )); then
    printf 'ghost pid %s was not stable for 3s — aborting rotation\n' "${ghost_pid}"
    return 1
  fi

  kill -QUIT "${orig_pid}" 2>/dev/null || true
  if ! wait_pid_gone "${orig_pid}" 10; then
    kill -TERM "${orig_pid}" 2>/dev/null || true
    if ! wait_pid_gone "${orig_pid}" 2; then
      # Final escalation: SIGKILL rather than aborting half-rotation.
      # A stuck original would otherwise leave the fresh surface blocked
      # from attaching (zmx slot still occupied) and the ghost dangling.
      kill -KILL "${orig_pid}" 2>/dev/null || true
      wait_pid_gone "${orig_pid}" 2 || { printf 'original pid did not exit even after SIGKILL: %s\n' "${orig_pid}"; return 1; }
    fi
  fi
  wait_zmx_gone "${orig_zmx}" 5 || true

  # Attach inject: target is shell → command execution. No verify (shell
  # alternate-screens to agent UI, fingerprint disappears, retry would
  # re-send into the newly-booted agent as a user prompt).
  attach_output="$(ORCHESTRATOR_BACKEND=cmux "${INJECT_EFFECT}" --execute --as-prompt --family "${target_agent}" --workspace "${orig_workspace}" "${surface_id}" "${attach_cmd}" 2>&1)"
  local _exclude_pid=""
  [[ "${target_zmx}" == "${orig_zmx}" ]] && _exclude_pid="${orig_pid}"
  fresh_pid="$(wait_zmx_pid "${target_zmx}" "${_exclude_pid}" 20)" || { printf 'fresh %s did not boot within 20s in slot %s\n' "${target_agent}" "${target_zmx}"; return 1; }
  # Wait for the fresh agent's input to be actually live (screen shows
  # agent-specific ready marker). Replaces a blind sleep — proceed only
  # when Claude/Codex has wired up stdin.
  wait_agent_ready "${surface_id}" "${orig_workspace}" "${target_agent}" 30 \
    || { printf 'fresh %s did not reach input-ready state within 30s\n' "${target_agent}"; return 1; }
  # /takeover inject: --verify as belt-and-suspenders retry if the first
  # send+enter still raced with stdin.
  takeover_output="$(ORCHESTRATOR_BACKEND=cmux "${INJECT_EFFECT}" --execute --verify --as-prompt --family "${target_agent}" --workspace "${orig_workspace}" "${surface_id}" "${takeover_cmd}" 2>&1)"

  jq -n \
    --arg orig_zmx "${orig_zmx}" \
    --arg orig_surface "${surface_id}" \
    --arg orig_workspace "${orig_workspace}" \
    --arg orig_pid "${orig_pid}" \
    --arg fresh_pid "${fresh_pid}" \
    --arg ghost_slug "${ghost_slug}" \
    --arg ghost_zmx "${ghost_zmx}" \
    --arg entry_path "${entry_path}" \
    --arg target_agent "${target_agent}" \
    --arg target_slot "${target_zmx}" \
    --argjson ghost_dispatch "${ghost_output}" \
    --argjson base_attach "${attach_output}" \
    --argjson takeover_inject "${takeover_output}" \
    '{rotate:{requester_slot:$orig_zmx, requester_surface:$orig_surface, requester_workspace:$orig_workspace,
      requester_pid:$orig_pid, fresh_pid:$fresh_pid, ghost_slug:$ghost_slug, ghost_slot:$ghost_zmx,
      entry_path:$entry_path, target_agent:$target_agent, target_slot:$target_slot},
      ghost_dispatch:$ghost_dispatch, base_attach:$base_attach, takeover_inject:$takeover_inject,
      user_commands:["zmx attach " + $ghost_zmx, "bash ~/.orchestrator/scripts/conductor.sh cleanup " + $ghost_slug + " --execute"]}' | jq '.'
}

handle_shutdown() {
  # stop_requested is set by the caller after this returns (subshell boundary)
  printf 'Graceful shutdown acknowledged. The orchestrator wrote its final response, archived the request, and is exiting now.\n'
}

process_request() {
  local req_file="$1" request_id request_type start_ns output rc response_status error_body
  [[ -f "${req_file}" ]] || return 0
  request_id="$(frontmatter_value "${req_file}" id)"
  request_type="$(frontmatter_value "${req_file}" type)"
  start_ns="$(epoch_ns)"

  # Idempotency: if a response already exists for this id, a previous
  # daemon crashed between write_response and archive_request. Re-running
  # the handler would duplicate side effects (dispatch, rotate). Archive
  # the stray request and move on.
  local existing_response
  existing_response="$(response_path_for "${req_file}")"
  if [[ -f "${existing_response}" ]]; then
    json_activity "$(jq -cn --arg timestamp "$(iso8601)" --arg id "${request_id}" --arg type "${request_type}" '{timestamp:$timestamp,event:"request-replayed",id:$id,type:$type}')"
    archive_request "${req_file}"
    return 0
  fi

  # M6: content dedup beyond UUID. If the same (type, slug) was processed
  # in the last 2s, treat this as an accidental double-submit. Keyed by
  # type+slug because user scripts sometimes fire twice on fat-finger or
  # retry logic. 2s is tight enough not to block legitimate re-dispatch.
  local req_slug dedup_key dedup_file dedup_mtime dedup_now dedup_age
  req_slug="$(frontmatter_value "${req_file}" slug)"
  if [[ -n "${req_slug}" && "${req_slug}" != "-" ]]; then
    dedup_key="$(printf '%s:%s' "${request_type}" "${req_slug}" | tr -c 'A-Za-z0-9_.-' '_')"
    dedup_file="${root_dir}/dedup/${dedup_key}.ts"
    if [[ -f "${dedup_file}" ]]; then
      dedup_now="$(date +%s)"
      dedup_mtime="$(stat -f %m "${dedup_file}" 2>/dev/null || stat -c %Y "${dedup_file}" 2>/dev/null || printf '0')"
      dedup_age=$(( dedup_now - dedup_mtime ))
      if (( dedup_age < 2 )); then
        json_activity "$(jq -cn --arg timestamp "$(iso8601)" --arg id "${request_id}" --arg type "${request_type}" --arg slug "${req_slug}" '{timestamp:$timestamp,event:"request-deduped",id:$id,type:$type,slug:$slug,reason:"content-recent"}')"
        archive_request "${req_file}"
        return 0
      fi
    fi
    mkdir -p "$(dirname -- "${dedup_file}")"
    : > "${dedup_file}"
  fi

  json_activity "$(jq -cn --arg timestamp "$(iso8601)" --arg id "${request_id}" --arg type "${request_type}" '{timestamp:$timestamp,event:"request-started",id:$id,type:$type}')"

  set +e
  case "${request_type}" in
    dispatch) output="$(handle_dispatch "${req_file}")"; rc=$? ;;
    collab) output="$(handle_collab "${req_file}")"; rc=$? ;;
    inject) output="$(handle_inject "${req_file}")"; rc=$? ;;
    rotate) output="$(handle_rotate "${req_file}")"; rc=$? ;;
    status) output="$(handle_status "${req_file}")"; rc=$? ;;
    gc) output="$(handle_gc "${req_file}")"; rc=$? ;;
    tidy) output="$(handle_tidy "${req_file}")"; rc=$? ;;
    resume) output="$(handle_resume "${req_file}")"; rc=$? ;;
    shutdown) output="$(handle_shutdown "${req_file}")"; rc=$? ;;
    *) output="unsupported request type: ${request_type}"; rc=1 ;;
  esac
  set -e

  response_status='ok'
  error_body=''
  if (( rc != 0 )); then
    response_status='error'
    error_body="${output}"
    output="Request failed for type=${request_type}."
  elif [[ "${request_type}" == "collab" ]]; then
    local collab_status
    collab_status="$(command_status_from_json "${output}")"
    [[ "${collab_status}" == "partial" ]] && response_status='partial'
  fi
  if [[ "${request_type}" == "shutdown" && "${response_status}" == "ok" ]]; then
    stop_requested=1
    shutdown_reason="request"
  fi

  write_response "${req_file}" "${response_status}" "${output}" "${error_body}" "${start_ns}"
  archive_request "${req_file}"
  json_activity "$(jq -cn --arg timestamp "$(iso8601)" --arg id "${request_id}" --arg type "${request_type}" --arg status "${response_status}" '{timestamp:$timestamp,event:"request-finished",id:$id,type:$type,status:$status}')"
}

cleanup_runtime() {
  (( runtime_started == 1 )) || return 0
  json_activity "$(jq -cn \
    --arg timestamp "$(iso8601)" \
    --arg reason "${shutdown_reason:-exit}" \
    --argjson pid "$$" \
    '{timestamp:$timestamp,event:"daemon-shutdown",pid:$pid,reason:$reason}')" 2>/dev/null || true
  rm -f "${agent_dir}/RUNNING" "${agent_dir}/pid" "${agent_dir}/BOOTSTRAPPED" 2>/dev/null || true
  if [[ -f "${registry_file}" ]]; then
    _locked_registry_update "${registry_file}" \
      "$(printf '.agents["%s"].status = "stopped" | .agents["%s"].pid = null | .agents["%s"].last_health = "%s"' \
        "${agent_name}" "${agent_name}" "${agent_name}" "$(iso8601)")" >/dev/null 2>&1 || true
  fi
}

signal_shutdown() {
  stop_requested=1
  shutdown_reason="signal"
}

approver_enabled() {
  [[ ! -f "${approver_disabled_file}" ]]
}

sync_approver_runtime() {
  local helper src
  mkdir -p "${approver_dir}"
  for helper in approver-send-key.sh approver-scan.sh approver-run.sh; do
    src="${SCRIPT_DIR}/effects/${helper}"
    [[ -f "${src}" ]] || die "missing approver helper: ${src}"
    cp -f "${src}" "${approver_dir}/${helper}"
    chmod +x "${approver_dir}/${helper}"
  done
  ln -sf approver-send-key.sh "${approver_dir}/send-key.sh"
  printf 'daemon\n' > "${approver_dir}/backend"
  printf 'daemon\n' > "${approver_dir}/type"
  : >> "${approver_loop_log}"
  : >> "${approver_daemon_log}"
}

approver_registry_running() {
  local pid="${1:?}" now
  now="$(iso8601)"
  _locked_registry_update "${registry_file}" \
    "$(printf '.schema_version = 2 | .agents["%s"] = {type:"daemon",status:"running",pid:%s,slot:null,surface_id:null,workspace_id:null,started_at:(.agents["%s"].started_at // "%s"),last_health:"%s",restart_count:((.agents["%s"].restart_count // 0))}' \
      "${approver_name}" "${pid}" "${approver_name}" "${now}" "${now}" "${approver_name}")" >/dev/null 2>&1 || true
}

approver_registry_stopped() {
  local now
  now="$(iso8601)"
  _locked_registry_update "${registry_file}" \
    "$(printf '.schema_version = 2 | .agents["%s"] = ((.agents["%s"] // {type:"daemon",restart_count:0}) + {type:"daemon",status:"stopped",pid:null,slot:null,surface_id:null,workspace_id:null,last_health:"%s"})' \
      "${approver_name}" "${approver_name}" "${now}")" >/dev/null 2>&1 || true
}

record_approver_runtime() {
  local pid="${1:?}" now
  now="$(iso8601)"
  printf 'started_at=%s\n' "${now}" > "${approver_dir}/RUNNING"
  printf '%s\n' "${pid}" > "${approver_pid_file}"
  printf 'daemon\n' > "${approver_dir}/backend"
  printf 'daemon\n' > "${approver_dir}/type"
}

spawn_approver_daemon() {
  local runner="${approver_dir}/approver-run.sh"
  [[ -x "${runner}" ]] || return 1
  # setsid is Linux-only; macOS falls back to nohup. Both yield a detached
  # background process that survives the parent's exit.
  local detach_cmd
  if command -v setsid >/dev/null 2>&1; then
    detach_cmd=setsid
  else
    detach_cmd=nohup
  fi
  (
    cd -- "${approver_dir}" || exit 1
    APPROVER_ROOT="${approver_dir}" \
      "${detach_cmd}" "${runner}" >> "${approver_daemon_log}" 2>&1 < /dev/null &
    disown 2>/dev/null || true
  ) >/dev/null 2>&1
}

wait_for_approver_ready() {
  local pid=''
  for _i in $(seq 1 50); do
    if [[ -f "${approver_scan_pid_file}" && -f "${approver_dir}/BOOTSTRAPPED" ]]; then
      pid="$(tr -d '[:space:]' < "${approver_scan_pid_file}" 2>/dev/null || true)"
      if [[ "${pid}" =~ ^[0-9]+$ ]] && kill -0 "${pid}" 2>/dev/null; then
        printf '%s\n' "${pid}"
        return 0
      fi
    fi
    sleep 0.2
  done
  return 1
}

stop_approver_runtime() {
  local pid=''
  pid="$(_agent_pid "${approver_name}" 2>/dev/null || true)"
  if [[ "${pid}" =~ ^[0-9]+$ ]] && kill -0 "${pid}" 2>/dev/null; then
    kill -TERM "${pid}" 2>/dev/null || true
    for _i in $(seq 1 10); do
      kill -0 "${pid}" 2>/dev/null || break
      sleep 0.2
    done
    kill -0 "${pid}" 2>/dev/null && kill -KILL "${pid}" 2>/dev/null || true
  fi
  rm -f "${approver_dir}/RUNNING" "${approver_pid_file}" "${approver_scan_pid_file}" "${approver_dir}/BOOTSTRAPPED" 2>/dev/null || true
  approver_registry_stopped
}

ensure_approver_runtime() {
  local pid
  sync_approver_runtime
  if ! approver_enabled; then
    stop_approver_runtime
    return 0
  fi

  if _agent_alive "${approver_name}" 2>/dev/null; then
    pid="$(_agent_pid "${approver_name}" 2>/dev/null || true)"
    if [[ "${pid}" =~ ^[0-9]+$ ]]; then
      record_approver_runtime "${pid}"
      approver_registry_running "${pid}"
      return 0
    fi
  fi

  rm -f "${approver_dir}/RUNNING" "${approver_pid_file}" "${approver_scan_pid_file}" "${approver_dir}/BOOTSTRAPPED" 2>/dev/null || true
  spawn_approver_daemon || return 1
  pid="$(wait_for_approver_ready)" || return 1
  record_approver_runtime "${pid}"
  approver_registry_running "${pid}"
  json_activity "$(jq -cn \
    --arg timestamp "$(iso8601)" \
    --arg agent "${approver_name}" \
    --argjson pid "${pid}" \
    '{timestamp:$timestamp,event:"approver-started",agent:$agent,pid:$pid}')" 2>/dev/null || true
}

start_runtime() {
  runtime_started=1
  mkdir -p "${inbox_dir}" "${outbox_dir}" "${processed_dir}" "${root_dir}/locks" "${agent_dir}" "$(_agents_dir)"
  printf 'started_at=%s\n' "$(iso8601)" > "${agent_dir}/RUNNING"
  printf '%s\n' "$$" > "${agent_dir}/pid"
  printf 'daemon\n' > "${agent_dir}/backend"
  printf 'READY\n' > "${agent_dir}/BOOTSTRAPPED"
  _locked_registry_update "${registry_file}" \
    "$(printf '.schema_version = 2 | .agents["%s"] = {type:"daemon",status:"running",pid:%s,slot:null,surface_id:null,workspace_id:null,started_at:"%s",last_health:"%s",restart_count:((.agents["%s"].restart_count // 0))}' \
      "${agent_name}" "$$" "$(iso8601)" "$(iso8601)" "${agent_name}")"
  json_activity "$(jq -cn \
    --arg timestamp "$(iso8601)" \
    --arg mode "${mode}" \
    --argjson pid "$$" \
    '{timestamp:$timestamp,event:"daemon-started",pid:$pid,mode:$mode}')" 2>/dev/null || true
}

trap signal_shutdown INT TERM HUP
trap cleanup_runtime EXIT

[[ -x "${CONDUCTOR_SH}" ]] || die "conductor not executable: ${CONDUCTOR_SH}"
[[ -x "${STATE_READ}" ]] || die "state-read not executable: ${STATE_READ}"
[[ -x "${INJECT_EFFECT}" ]] || die "inject effect not executable: ${INJECT_EFFECT}"

if [[ "${command_mode}" == "ensure-approver" ]]; then
  mkdir -p "${root_dir}/locks" "${approver_dir}" "$(_agents_dir)"
  if ensure_approver_runtime; then
    pid="$(_agent_pid "${approver_name}" 2>/dev/null || true)"
    printf 'status=%s\n' "$(approver_enabled && printf 'running' || printf 'stopped')"
    printf 'agent=%s\n' "${approver_name}"
    [[ -n "${pid}" ]] && printf 'pid=%s\n' "${pid}"
    exit 0
  fi
  die "failed to reconcile approver runtime"
fi

start_runtime
ensure_approver_runtime >/dev/null 2>&1 || true

# Periodic auto-tidy: every N iterations of the poll loop, run a tidy
# reconcile to clean up fire-and-forget workers whose zmx has died.
# At 0.5s per iteration, 60 iterations = 30 seconds between tidy runs.
# This replaces the worker-side EXIT trap (which cmux's auto-close of
# the pane makes impossible) with an external polling cleanup.
PERIODIC_TIDY_INTERVAL="${ORCHESTRATOR_TIDY_INTERVAL:-60}"
PERIODIC_TIDY_ENABLED="${ORCHESTRATOR_TIDY_ENABLED:-1}"
_tidy_tick=0

# Heartbeat: stamp last_health on the registry every N poll iterations.
# Gives health.sh a way to confirm liveness when PID-check is blocked by
# EPERM (sandbox, different namespace, etc). At 0.5s/iter × 10 = 5s.
HEARTBEAT_INTERVAL_TICKS="${ORCHESTRATOR_HEARTBEAT_TICKS:-10}"
_heartbeat_tick=0

run_heartbeat() {
  local now; now="$(iso8601)"
  local jq_expr
  jq_expr="$(printf '.agents["%s"].last_health = "%s"' "${agent_name}" "${now}")"
  if _agent_alive "${approver_name}" 2>/dev/null; then
    jq_expr+="$(printf ' | .agents["%s"].last_health = "%s" | .agents["%s"].status = "running" | .agents["%s"].type = "daemon"' \
      "${approver_name}" "${now}" "${approver_name}" "${approver_name}")"
  elif [[ -f "${registry_file}" ]]; then
    jq_expr+="$(printf ' | if (.agents | has("%s")) then .agents["%s"].status = "stopped" else . end' \
      "${approver_name}" "${approver_name}")"
  fi
  _locked_registry_update "${registry_file}" "${jq_expr}" >/dev/null 2>&1 || true
}

run_periodic_tidy() {
  [[ "${PERIODIC_TIDY_ENABLED}" == "1" ]] || return 0
  # Run gc (full reconcile + cleanup) and tidy (worktree+branch for resource-
  # based done tasks). gc handles state.json reconciliation for stale entries;
  # tidy handles orphan worktrees without state.json dependencies.
  set +e
  "${CONDUCTOR_SH}" gc --execute >/dev/null 2>&1
  # Per-project tidy: iterate known project paths in state.json and call
  # conductor.sh tidy in each one (tidy is cwd-scoped).
  local _state _projects _proj
  _state="$("${STATE_READ}" --root "${root_dir}" 2>/dev/null || true)"
  if [[ -n "${_state}" ]]; then
    _projects="$(jq -r '.projects // {} | to_entries[] | .value.path // empty' <<<"${_state}" 2>/dev/null || true)"
    while IFS= read -r _proj; do
      [[ -n "${_proj}" && -d "${_proj}" ]] || continue
      # Periodic tidy is dry-run only by default — destructive worktree
      # removal must be a deliberate, manual action. The dry-run still
      # surfaces removal candidates via activity.jsonl so an operator can
      # review and explicitly call `orchestrator_request --type tidy`
      # with execute when ready. See .collab/hook-failure-observe-* for
      # the incident that motivated this change.
      ( cd -- "${_proj}" && "${CONDUCTOR_SH}" tidy --dry-run >/dev/null 2>&1 ) || true
    done <<<"${_projects}"
  fi
  # Maintain the canonical agent-team workspace shape (daemon-log +
  # approver-log panes). Global, not per-project — runs once per tick.
  # Idempotent. Without this, drift from a closed pane, stale registry
  # surface_id, or daemon restart persists indefinitely because nothing
  # else in the daemon loop invokes health.sh recover_surfaces.
  bash "${SCRIPT_DIR}/ensure-agent-team-shape.sh" >/dev/null 2>&1 || true
  set -e
  ensure_approver_runtime >/dev/null 2>&1 || true
}

while :; do
  for req_file in "${inbox_dir}"/req-*.md; do
    [[ -e "${req_file}" ]] || continue
    process_request "${req_file}"
    (( stop_requested == 1 )) && break
  done

  [[ "${mode}" == "once" ]] && break
  (( stop_requested == 1 )) && break

  # Periodic auto-tidy
  _tidy_tick=$((_tidy_tick + 1))
  if (( _tidy_tick >= PERIODIC_TIDY_INTERVAL )); then
    _tidy_tick=0
    run_periodic_tidy
  fi

  # Heartbeat
  _heartbeat_tick=$((_heartbeat_tick + 1))
  if (( _heartbeat_tick >= HEARTBEAT_INTERVAL_TICKS )); then
    _heartbeat_tick=0
    run_heartbeat
  fi

  sleep 0.5
done
