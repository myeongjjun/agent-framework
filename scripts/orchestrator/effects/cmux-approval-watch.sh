#!/usr/bin/env bash
#
# cmux-approval-watch.sh - install cmux pipe-pane triggers for approver.
#
# Dry-run is the default. In execute mode this script attaches a cmux
# pipe-pane command to every managed worker surface. The pipe command runs this
# same script in --stream mode and writes trigger JSON files when approval-like
# prompts appear in terminal output.

set -euo pipefail
IFS=$'\n\t'

SCRIPT_PATH="$0"
case "${SCRIPT_PATH}" in
  /*) ;;
  *) SCRIPT_PATH="$(cd -- "$(dirname -- "${SCRIPT_PATH}")" && pwd)/$(basename -- "${SCRIPT_PATH}")" ;;
esac

usage() {
  cat <<'EOF'
Usage:
  scripts/orchestrator/effects/cmux-approval-watch.sh [--dry-run|--execute] [--runtime-dir DIR]
  scripts/orchestrator/effects/cmux-approval-watch.sh --stream --workspace ID --surface ID [--runtime-dir DIR]

Modes:
  --dry-run   Print the cmux pipe-pane plan as JSON. This is the default.
  --execute   Install pipe-pane stream commands for managed surfaces.
  --stream    Read terminal output from stdin and write approval trigger files.
EOF
}

die() {
  printf 'cmux-approval-watch.sh: %s\n' "$*" >&2
  exit 1
}

orchestrator_root() {
  printf '%s\n' "${ORCHESTRATOR_ROOT:-${HOME}/.orchestrator}"
}

default_runtime_dir() {
  printf '%s\n' "${APPROVER_ROOT:-${HOME}/.approver}"
}

safe_name() {
  printf '%s' "$1" | tr -c 'A-Za-z0-9_.-' '_'
}

json_plan() {
  local mode="$1" runtime_dir="$2" plan_lines

  plan_lines="$(
    collect_managed_surfaces | while IFS=$'\t' read -r workspace_id surface_id source; do
      [[ -n "${workspace_id}" && -n "${surface_id}" ]] || continue
      printf '%s\t%s\t%s\t%s\n' \
        "${workspace_id}" \
        "${surface_id}" \
        "${source}" \
        "$(pipe_command "${workspace_id}" "${surface_id}" "${runtime_dir}")"
    done
  )"

  printf '%s\n' "${plan_lines}" | jq -Rs \
    --arg mode "${mode}" \
    --arg runtime_dir "${runtime_dir}" \
    --arg script "${SCRIPT_PATH}" '
      (split("\n")
        | map(select(length > 0)
        | split("\t")
        | {
            workspace_id: .[0],
            surface_id: .[1],
            source: .[2],
            command: .[3]
          })) as $watchers
      | {
          action: "cmux-approval-watch",
          mode: $mode,
          runtime_dir: $runtime_dir,
          script: $script,
          watchers: $watchers
        }
    '
}

collect_managed_surfaces() {
  local root state_file registry_file self_ws self_surface
  root="$(orchestrator_root)"
  state_file="${root}/state.json"
  registry_file="${root}/agents/registry.json"

  # Exclude approver's own surface so pipe-pane doesn't watch the agent
  # that reads the triggers. Runtime dir stores these at install time.
  self_ws=""
  self_surface=""
  if [[ -f "${runtime_dir:-}/workspace_id" ]]; then
    self_ws="$(tr -d '[:space:]' < "${runtime_dir}/workspace_id" 2>/dev/null || true)"
  fi
  if [[ -f "${runtime_dir:-}/surface_id" ]]; then
    self_surface="$(tr -d '[:space:]' < "${runtime_dir}/surface_id" 2>/dev/null || true)"
  fi

  {
    if [[ -f "${state_file}" ]]; then
      jq -r '
        (.agents // {})
        | to_entries[]
        | select((.value.status // "") as $status | ["running", "in_progress"] | index($status))
        | select((.value.workspace_id // "") != "" and (.value.surface_id // "") != "")
        | [.value.workspace_id, .value.surface_id, ("state:" + .key)]
        | @tsv
      ' "${state_file}" 2>/dev/null || true
    fi

    if [[ -f "${registry_file}" ]]; then
      jq -r '
        (.agents // {})
        | to_entries[]
        | select(.value.status == "running")
        | select((.value.workspace_id // "") != "" and (.value.surface_id // "") != "")
        | [.value.workspace_id, .value.surface_id, ("registry:" + .key)]
        | @tsv
      ' "${registry_file}" 2>/dev/null || true
    fi
    # Also discover ALL terminal surfaces via cmux tree.
    # This catches base sessions and unmanaged workspaces that state/registry miss.
    # Note: cmux tree output contains unicode box-drawing characters (├──, └──, │)
    # so we must use regex match() instead of positional $2 parsing.
    if command -v cmux >/dev/null 2>&1; then
      cmux tree --all 2>/dev/null \
        | awk '
          /workspace:[0-9]+/ { match($0, /workspace:[0-9]+/); ws=substr($0, RSTART, RLENGTH) }
          /surface:[0-9]+.*\[terminal\]/ { match($0, /surface:[0-9]+/); sf=substr($0, RSTART, RLENGTH); print ws "\t" sf "\ttree:discovered" }
        ' || true
    fi

  } | awk -F '\t' -v self_ws="${self_ws}" -v self_surface="${self_surface}" '
      NF >= 2 && $1 != "-" && $2 != "-" {
        if (self_ws != "" && self_surface != "" && $1 == self_ws && $2 == self_surface) next
        key = $1 "\t" $2
        if (!(key in seen)) {
          seen[key] = 1
          print $1 "\t" $2 "\t" ($3 == "" ? "unknown" : $3)
        }
      }
    '
}

pipe_command() {
  local workspace_id="$1" surface_id="$2" runtime_dir="$3"
  local q_script q_workspace q_surface q_runtime

  printf -v q_script '%q' "${SCRIPT_PATH}"
  printf -v q_workspace '%q' "${workspace_id}"
  printf -v q_surface '%q' "${surface_id}"
  printf -v q_runtime '%q' "${runtime_dir}"

  printf '%s --stream --workspace %s --surface %s --runtime-dir %s' \
    "${q_script}" "${q_workspace}" "${q_surface}" "${q_runtime}"
}

approval_prompt_line() {
  # Structural-only matchers (H4 fix). Previous loose "Allow … ?" and
  # "approval … proceed" checks matched ordinary log output. Stick to
  # the canonical Claude/Codex prompt strings — any novel prompt still
  # gets caught by the slow path (approver-scan.sh) that inspects the
  # full screen within its 1s poll.
  case "${line}" in
    *"Do you want to proceed?"*|*"Allow once"*|*"Allow always"*|*"[y/N]"*|*"[Y/n]"*)
      return 0
      ;;
    *"Press enter to confirm or esc to cancel"*)
      return 0
      ;;
    *"Would you like to run the following command?"*)
      return 0
      ;;
  esac

  return 1
}

# Keep in sync with approver-scan.sh _dangerous_regex().
_dangerous_regex() {
  printf '%s' '(^|[[:space:]])rm[[:space:]]+-([rRfF]+|[rR][[:space:]]|[fF][[:space:]])|git[[:space:]]+push([^\n])*(--force|[[:space:]]-f([[:space:]]|$))|git[[:space:]]+reset[[:space:]]+--hard|curl[^\n|]*\|[[:space:]]*(sh|bash)|DROP[[:space:]]+TABLE|credential|secret|token'
}

dangerous_context() {
  local screen="${1:-}"
  [[ -n "${screen}" ]] || return 1
  printf '%s\n' "${screen}" | rg -qi "$(_dangerous_regex)"
}

# Per-surface cooldown shared with approver-scan.sh (slow path). See
# approver-scan.sh:_recent_approval_path — same naming so both paths
# observe each other's recent approvals.
_recent_approval_path() {
  local runtime_dir="$1" workspace_id="$2" surface_id="$3" safe_ws safe_surface
  safe_ws="$(safe_name "${workspace_id}")"
  safe_surface="$(safe_name "${surface_id}")"
  printf '%s/approvals/%s-%s.ts' "${runtime_dir}" "${safe_ws}" "${safe_surface}"
}

_recent_approval_active() {
  local runtime_dir="$1" workspace_id="$2" surface_id="$3" window="${4:-3}"
  local path now mtime age
  path="$(_recent_approval_path "${runtime_dir}" "${workspace_id}" "${surface_id}")"
  [[ -f "${path}" ]] || return 1
  now="$(date +%s)"
  mtime="$(stat -f %m "${path}" 2>/dev/null || stat -c %Y "${path}" 2>/dev/null || printf '0')"
  age=$(( now - mtime ))
  (( age < window ))
}

_recent_approval_mark() {
  local runtime_dir="$1" workspace_id="$2" surface_id="$3" path
  path="$(_recent_approval_path "${runtime_dir}" "${workspace_id}" "${surface_id}")"
  mkdir -p "$(dirname -- "${path}")"
  : > "${path}"
}

emit_trigger() {
  local workspace_id="$1" surface_id="$2" runtime_dir="$3" matched_line="$4"
  local trigger_dir now epoch safe_workspace safe_surface trigger_path tmp_path
  local screen decision

  trigger_dir="${runtime_dir}/triggers"
  mkdir -p "${trigger_dir}"

  # Safety gate: inspect the screen before approving. A dangerous command
  # (rm -rf, git push --force, curl | sh, DROP TABLE, secrets) within the
  # prompt context means the approver must defer to the slow path / human.
  screen="$(cmux read-screen --surface "${surface_id}" --workspace "${workspace_id}" --lines 80 2>/dev/null || true)"
  if dangerous_context "${screen}"; then
    decision="skipped_dangerous"
  elif _recent_approval_active "${runtime_dir}" "${workspace_id}" "${surface_id}" 3; then
    decision="skipped_cooldown"
  else
    cmux send-key --surface "${surface_id}" --workspace "${workspace_id}" enter \
      >/dev/null 2>&1 || true
    _recent_approval_mark "${runtime_dir}" "${workspace_id}" "${surface_id}"
    decision="approved"
  fi

  now="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
  epoch="$(date +%s%N 2>/dev/null || printf '%s000000000' "$(date +%s)")"
  safe_workspace="$(safe_name "${workspace_id}")"
  safe_surface="$(safe_name "${surface_id}")"
  trigger_path="${trigger_dir}/${safe_workspace}-${safe_surface}-${epoch}.json"
  tmp_path="${trigger_path}.tmp"

  jq -n \
    --arg created_at "${now}" \
    --arg workspace_id "${workspace_id}" \
    --arg surface_id "${surface_id}" \
    --arg matched_line "${matched_line}" \
    --arg decision "${decision}" \
    '{
      schema_version: 1,
      created_at: $created_at,
      workspace_id: $workspace_id,
      surface_id: $surface_id,
      source: "cmux-pipe-pane",
      matched_line: $matched_line,
      decision: $decision,
      auto_approved: ($decision == "approved")
    }' > "${tmp_path}"
  mv "${tmp_path}" "${trigger_path}"
}

stream_mode() {
  local workspace_id="$1" surface_id="$2" runtime_dir="$3"
  local line now last_emit=0

  while IFS= read -r line; do
    approval_prompt_line "${line}" || continue
    now="$(date +%s)"
    if (( now - last_emit < 3 )); then
      continue
    fi
    emit_trigger "${workspace_id}" "${surface_id}" "${runtime_dir}" "${line}"
    last_emit="${now}"
  done
}

install_watchers() {
  local mode="$1" runtime_dir="$2" workspace_id surface_id source command

  if [[ "${mode}" == "dry-run" ]]; then
    json_plan "${mode}" "${runtime_dir}"
    return 0
  fi

  command -v cmux >/dev/null 2>&1 || die "cmux not found"
  mkdir -p "${runtime_dir}/triggers"

  collect_managed_surfaces | while IFS=$'\t' read -r workspace_id surface_id source; do
    [[ -n "${workspace_id}" && -n "${surface_id}" ]] || continue
    command="$(pipe_command "${workspace_id}" "${surface_id}" "${runtime_dir}")"
    if cmux pipe-pane \
      --workspace "${workspace_id}" \
      --surface "${surface_id}" \
      --command "${command}" >/dev/null 2>&1; then
      printf 'watcher=installed workspace=%s surface=%s source=%s\n' \
        "${workspace_id}" "${surface_id}" "${source}"
    else
      printf 'watcher=skipped workspace=%s surface=%s source=%s reason=surface-unavailable\n' \
        "${workspace_id}" "${surface_id}" "${source}" >&2
    fi
  done
}

mode="dry-run"
runtime_dir="$(default_runtime_dir)"
workspace_id=""
surface_id=""

while (($# > 0)); do
  case "$1" in
    --dry-run)
      mode="dry-run"
      ;;
    --execute)
      mode="execute"
      ;;
    --stream)
      mode="stream"
      ;;
    --runtime-dir)
      shift
      [[ $# -gt 0 ]] || die "--runtime-dir requires a value"
      runtime_dir="$1"
      ;;
    --workspace)
      shift
      [[ $# -gt 0 ]] || die "--workspace requires a value"
      workspace_id="$1"
      ;;
    --surface)
      shift
      [[ $# -gt 0 ]] || die "--surface requires a value"
      surface_id="$1"
      ;;
    --help|-h)
      usage
      exit 0
      ;;
    *)
      die "unknown argument: $1"
      ;;
  esac
  shift
done

case "${mode}" in
  dry-run|execute)
    install_watchers "${mode}" "${runtime_dir}"
    ;;
  stream)
    [[ -n "${workspace_id}" ]] || die "--stream requires --workspace"
    [[ -n "${surface_id}" ]] || die "--stream requires --surface"
    stream_mode "${workspace_id}" "${surface_id}" "${runtime_dir}"
    ;;
  *)
    die "unsupported mode: ${mode}"
    ;;
esac
