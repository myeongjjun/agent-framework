#!/usr/bin/env bash
#
# team.sh — Agent team management CLI.
#
# Manages the agent-team: start/stop individual agents, check team health,
# list registered agents with A2A-inspired agent card metadata.
#
# Usage:
#   scripts/orchestrator/team.sh start <agent-name> [--execute] [--family claude|codex] [--model MODEL]
#   scripts/orchestrator/team.sh stop <agent-name> [--execute]
#   scripts/orchestrator/team.sh restart <agent-name> [--execute]
#   scripts/orchestrator/team.sh health [<agent-name>|--all]
#   scripts/orchestrator/team.sh status
#   scripts/orchestrator/team.sh list
#   scripts/orchestrator/team.sh card <agent-name>

set -euo pipefail
IFS=$'\n\t'

# Canonical runtime gate. The orchestrator's live install is
# ${HOME}/.orchestrator/scripts/orchestrator/. Source edits take effect
# only after sync-all.sh copies them into that tree. Force every
# invocation to re-exec through the canonical copy so worktree/source
# drift can never feed a stale script into the running daemon.
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

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
BOLD='\033[1m'
DIM='\033[2m'
NC='\033[0m'

die() { printf 'team.sh: %s\n' "$*" >&2; exit 1; }

parse_mode_flag() {
  local arg mode='dry-run'
  for arg in "$@"; do
    case "${arg}" in
      --execute) mode='execute' ;;
      --dry-run) mode='dry-run' ;;
      --family|--model|--bootstrap)
        die "approver is daemon-supervised; family/model/bootstrap overrides are not supported"
        ;;
      --*)
        die "unknown approver lifecycle argument: ${arg}"
        ;;
      *)
        die "unexpected approver lifecycle argument: ${arg}"
        ;;
    esac
  done
  printf '%s\n' "${mode}"
}

team_approver_start() {
  local mode
  mode="$(parse_mode_flag "$@")"
  if [[ "${mode}" == 'dry-run' ]]; then
    jq -n \
      --arg agent "approver" \
      --arg mode "${mode}" \
      '{action:"team-start",agent:$agent,mode:$mode,path:"daemon-supervisor"}'
    return 0
  fi
  mkdir -p "$(_agent_dir approver)"
  rm -f "$(_agent_dir approver)/DISABLED"
  "${SCRIPT_DIR}/daemon.sh" --ensure-approver
  "${SCRIPT_DIR}/health.sh" --agent-name approver >/dev/null 2>&1 || true
}

team_approver_stop() {
  local mode
  mode="$(parse_mode_flag "$@")"
  if [[ "${mode}" == 'dry-run' ]]; then
    "${SCRIPT_DIR}/stop-agent.sh" --agent-name approver --dry-run
    return 0
  fi
  mkdir -p "$(_agent_dir approver)"
  : > "$(_agent_dir approver)/DISABLED"
  "${SCRIPT_DIR}/stop-agent.sh" --agent-name approver --execute
}

team_approver_restart() {
  local mode
  mode="$(parse_mode_flag "$@")"
  if [[ "${mode}" == 'dry-run' ]]; then
    jq -n \
      --arg agent "approver" \
      --arg mode "${mode}" \
      '{action:"team-restart",agent:$agent,mode:$mode,path:"daemon-supervisor"}'
    return 0
  fi
  team_approver_stop --execute >/dev/null 2>&1 || true
  team_approver_start --execute
}

usage() {
  cat <<'EOF'
Usage:
  team.sh start <agent-name> [--execute] [--family claude|codex] [--model MODEL] [--bootstrap PATH]
  team.sh stop <agent-name> [--execute]
  team.sh restart <agent-name> [--execute] [--family claude|codex]
  team.sh health [<agent-name>|--all]
  team.sh status                        # overview of all agents
  team.sh list                          # list available agent definitions
  team.sh card <agent-name>             # show A2A-style agent card
  team.sh alias list                    # list registered project aliases (ADR-033)
  team.sh alias add <cwd> <short>       # register alias with validation
  team.sh alias rm <cwd>                # remove alias
  team.sh alias check <cwd>             # preview what _resolve_project_alias returns
EOF
  exit 0
}

# --- Project alias management (ADR-033) ---------------------------------------

ALIASES_FILE="${ORCHESTRATOR_ROOT:-${HOME}/.orchestrator}/project-aliases.json"

_aliases_load() {
  if [[ -f "${ALIASES_FILE}" ]]; then
    cat "${ALIASES_FILE}"
  else
    printf '{}\n'
  fi
}

_aliases_save() {
  local content="$1" tmp
  mkdir -p "$(dirname "${ALIASES_FILE}")"
  tmp="$(mktemp "${ALIASES_FILE}.XXXXXX")"
  printf '%s\n' "${content}" | jq '.' > "${tmp}" || { rm -f "${tmp}"; die "alias save: jq formatting failed"; }
  mv "${tmp}" "${ALIASES_FILE}"
}

_alias_validate_format() {
  local alias="$1"
  [[ "${alias}" =~ ^[a-z0-9]+(-[a-z0-9]+)*$ ]] || die "alias must be lowercase kebab-case (got '${alias}')"
  (( ${#alias} <= 25 )) || die "alias must be 25 characters or fewer (got ${#alias})"
  (( ${#alias} >= 2 )) || die "alias must be at least 2 characters (got ${#alias})"
}

team_alias_list() {
  local data
  data="$(_aliases_load)"
  local count
  count="$(jq -r 'length' <<<"${data}")"
  if [[ "${count}" == "0" ]]; then
    echo -e "${DIM}(no aliases registered — see team.sh alias add)${NC}"
    return 0
  fi
  echo -e "${BOLD}Project aliases (${count})${NC}"
  jq -r 'to_entries | sort_by(.value)[] | "\(.value)\t\(.key)"' <<<"${data}" \
    | while IFS=$'\t' read -r alias cwd; do
        printf '  %b%-22s%b ← %s\n' "${BLUE}" "${alias}" "${NC}" "${cwd}"
      done
}

team_alias_add() {
  local cwd="${1:?alias add requires <cwd>}"
  local alias="${2:?alias add requires <short>}"

  _alias_validate_format "${alias}"

  # Optional but recommended: warn if cwd doesn't exist (don't block; users
  # may register aliases for repos they haven't cloned yet on this machine).
  if [[ ! -d "${cwd}" ]]; then
    echo -e "${YELLOW}warning${NC}: cwd '${cwd}' is not an existing directory (registering anyway)" >&2
  fi

  local data existing
  data="$(_aliases_load)"

  existing="$(jq -r --arg p "${cwd}" '.[$p] // empty' <<<"${data}")"
  if [[ -n "${existing}" ]]; then
    if [[ "${existing}" == "${alias}" ]]; then
      echo -e "${DIM}alias already registered: ${cwd} → ${alias} (no change)${NC}"
      return 0
    fi
    die "cwd '${cwd}' already maps to '${existing}'; remove first with: team.sh alias rm '${cwd}'"
  fi

  # Reject if alias is in use by a different cwd (would collide in slot_name).
  local collision
  collision="$(jq -r --arg a "${alias}" 'to_entries[] | select(.value == $a) | .key' <<<"${data}" | head -1)"
  if [[ -n "${collision}" ]]; then
    die "alias '${alias}' already used by '${collision}' — pick a different short name"
  fi

  local updated
  updated="$(jq --arg p "${cwd}" --arg a "${alias}" '. + {($p): $a}' <<<"${data}")"
  _aliases_save "${updated}"
  echo -e "${GREEN}✓ registered${NC} ${cwd} → ${alias}"
}

team_alias_rm() {
  local cwd="${1:?alias rm requires <cwd>}"
  local data existing
  data="$(_aliases_load)"
  existing="$(jq -r --arg p "${cwd}" '.[$p] // empty' <<<"${data}")"
  if [[ -z "${existing}" ]]; then
    echo -e "${DIM}no alias for ${cwd} (nothing to remove)${NC}"
    return 0
  fi
  local updated
  updated="$(jq --arg p "${cwd}" 'del(.[$p])' <<<"${data}")"
  _aliases_save "${updated}"
  echo -e "${GREEN}✓ removed${NC} ${cwd} → ${existing}"
}

team_alias_check() {
  local cwd="${1:?alias check requires <cwd>}"
  local data existing
  data="$(_aliases_load)"
  existing="$(jq -r --arg p "${cwd}" '.[$p] // empty' <<<"${data}")"
  if [[ -n "${existing}" ]]; then
    echo -e "${GREEN}alias hit${NC}: ${cwd} → ${existing}"
  else
    local fallback
    fallback="$(basename "${cwd}")"
    echo -e "${YELLOW}no alias${NC}: ${cwd} → fallback basename '${fallback}'"
    if (( ${#fallback} >= 27 )); then
      echo -e "  ${RED}warning${NC}: basename is ${#fallback} chars — slot will hit hash fallback (ADR-033 Tier 2)" >&2
    fi
  fi
}

# --- Agent Card (A2A-inspired) ------------------------------------------------

fm_field() {
  local file="$1" key="$2"
  awk -v k="$key" '
    BEGIN { in_fm=0 }
    /^---$/ { in_fm = !in_fm; next }
    in_fm && $0 ~ "^"k"[[:space:]]*:" {
      sub("^"k"[[:space:]]*:[[:space:]]*", "")
      gsub(/^["'\''"]/, ""); gsub(/["'\''"]$/, "")
      print
      exit
    }
  ' "$file"
}

show_agent_card() {
  local name="$1"
  local src="${AGENT_DEFS_DIR}/${name}.md"
  [[ -f "${src}" ]] || die "no agent definition found: ${src}"

  local desc family model tools persistent priority restart health_interval tags type
  desc="$(fm_field "${src}" description)"
  type="$(fm_field "${src}" type)"
  family="$(fm_field "${src}" family)"
  model="$(fm_field "${src}" model)"
  tools="$(fm_field "${src}" tools)"
  persistent="$(fm_field "${src}" persistent)"
  priority="$(fm_field "${src}" priority)"
  restart="$(fm_field "${src}" restart_policy)"
  health_interval="$(fm_field "${src}" health_interval)"
  tags="$(fm_field "${src}" tags)"

  # A2A Agent Card format
  echo -e "${BOLD}Agent Card: ${BLUE}${name}${NC}"
  echo -e "  ${DIM}description:${NC}    ${desc}"
  echo -e "  ${DIM}type:${NC}           ${type:-llm-agent}"
  echo -e "  ${DIM}family:${NC}         ${family:--}"
  echo -e "  ${DIM}model:${NC}          ${model:--}"
  echo -e "  ${DIM}tools:${NC}          ${tools:-all}"
  echo -e "  ${DIM}persistent:${NC}     ${persistent:-false}"
  echo -e "  ${DIM}priority:${NC}       ${priority:-10}"
  echo -e "  ${DIM}restart_policy:${NC} ${restart:-never}"
  echo -e "  ${DIM}health_check:${NC}   every ${health_interval:-300}s"
  echo -e "  ${DIM}tags:${NC}           ${tags:-none}"

  # Runtime status from registry
  local registry_file="$(_agents_dir)/registry.json"
  if [[ -f "${registry_file}" ]]; then
    local reg_status reg_family reg_pid reg_slot
    reg_status="$(jq -r ".agents[\"${name}\"].status // \"not registered\"" "${registry_file}")"
    reg_family="$(jq -r ".agents[\"${name}\"].family // \"-\"" "${registry_file}")"
    reg_pid="$(jq -r ".agents[\"${name}\"].pid // \"–\"" "${registry_file}")"
    reg_slot="$(jq -r ".agents[\"${name}\"].slot // \"–\"" "${registry_file}")"
    echo -e "  ${DIM}---runtime---${NC}"
    if [[ "${reg_status}" == "running" ]]; then
      echo -e "  ${DIM}status:${NC}         ${GREEN}${reg_status}${NC}"
    elif [[ "${reg_status}" == "stopped" ]]; then
      echo -e "  ${DIM}status:${NC}         ${YELLOW}${reg_status}${NC}"
    else
      echo -e "  ${DIM}status:${NC}         ${DIM}${reg_status}${NC}"
    fi
    echo -e "  ${DIM}family:${NC}         ${reg_family}"
    echo -e "  ${DIM}pid:${NC}            ${reg_pid}"
    echo -e "  ${DIM}slot:${NC}           ${reg_slot}"
  fi
}

# --- Commands -----------------------------------------------------------------

# Agent definitions: prefer project source, fall back to ~/.claude/agents/
_has_agent_defs() {
  local dir="$1"
  [[ -d "${dir}" ]] || return 1
  compgen -G "${dir}/*.md" >/dev/null 2>&1
}
AGENT_DEFS_DIR="${HOME}/.claude/agents"
_src_agents="$(cd "${SCRIPT_DIR}/../.." 2>/dev/null && pwd)/agents"
if _has_agent_defs "${_src_agents}"; then
  AGENT_DEFS_DIR="${_src_agents}"
fi

cmd="${1:-help}"
shift || true

case "${cmd}" in
  start)
    agent="${1:?start requires agent name}"
    shift
    if [[ "${agent}" == "approver" ]]; then
      team_approver_start "$@"
    else
      "${SCRIPT_DIR}/start-agent.sh" --agent-name "${agent}" "$@"
    fi
    ;;

  stop)
    agent="${1:?stop requires agent name}"
    shift
    if [[ "${agent}" == "approver" ]]; then
      team_approver_stop "$@"
    else
      "${SCRIPT_DIR}/stop-agent.sh" --agent-name "${agent}" "$@"
    fi
    ;;

  restart)
    agent="${1:?restart requires agent name}"
    shift
    if [[ "${agent}" == "approver" ]]; then
      team_approver_restart "$@"
    else
      "${SCRIPT_DIR}/stop-agent.sh" --agent-name "${agent}" "$@" 2>/dev/null || true
      "${SCRIPT_DIR}/start-agent.sh" --agent-name "${agent}" "$@"
    fi
    ;;

  health)
    if [[ "${1:-}" == "--all" ]]; then
      shift
      "${SCRIPT_DIR}/health.sh" --all "$@"
    elif [[ -n "${1:-}" && "${1}" != --* ]]; then
      agent="$1"
      shift
      "${SCRIPT_DIR}/health.sh" --agent-name "${agent}" "$@"
    else
      "${SCRIPT_DIR}/health.sh" "$@"
    fi
    ;;

  status)
    echo -e "${BOLD}=== Agent Team Status ===${NC}"
    echo
    registry="$(_agents_dir)/registry.json"
    if [[ ! -f "${registry}" ]]; then
      echo -e "  ${DIM}(no registry found — no agents have been started)${NC}"
      exit 0
    fi
    jq -r '.agents | to_entries[] | [.key, .value.status, (.value.pid // "-"), .value.slot] | @tsv' "${registry}" \
      | while IFS=$'\t' read -r name status pid slot; do
          if [[ "${status}" == "running" ]]; then
            # Verify PID is actually alive
            if [[ "${pid}" != "-" ]] && kill -0 "${pid}" 2>/dev/null; then
              echo -e "  ${GREEN}●${NC} ${BOLD}${name}${NC}  pid=${pid}  slot=${slot}"
            else
              echo -e "  ${YELLOW}◐${NC} ${BOLD}${name}${NC}  ${YELLOW}stale${NC} (registered as running but pid ${pid} dead)"
            fi
          else
            echo -e "  ${DIM}○${NC} ${name}  ${DIM}${status}${NC}"
          fi
        done
    echo
    ;;

  list)
    echo -e "${BOLD}Available Agent Definitions${NC}"
    echo
    shopt -s nullglob
    for f in "${AGENT_DEFS_DIR}"/*.md; do
      name="$(basename "${f}" .md)"
      [[ "${name}" == "README" || "${name}" == "INDEX" ]] && continue
      desc="$(fm_field "${f}" description | head -1)"
      type="$(fm_field "${f}" type)"
      family="$(fm_field "${f}" family)"
      model="$(fm_field "${f}" model)"
      persistent="$(fm_field "${f}" persistent)"
      marker=""
      [[ "${persistent}" == "true" ]] && marker=" ${CYAN}[persistent]${NC}"
      echo -e "  ${BLUE}${name}${NC}${marker}"
      [[ -n "${desc}" ]] && echo -e "    ${DIM}${desc}${NC}"
      [[ -n "${type}" ]] && echo -e "    ${DIM}type: ${type}${NC}"
      [[ -n "${family}" ]] && echo -e "    ${DIM}family: ${family}${NC}"
      [[ -n "${model}" ]] && echo -e "    ${DIM}model: ${model}${NC}"
    done
    shopt -u nullglob
    echo
    ;;

  card)
    agent="${1:?card requires agent name}"
    show_agent_card "${agent}"
    ;;

  close-surface)
    # Close specific cmux surfaces by ID. Usage: team.sh close-surface surface:N workspace:N [...]
    while (( $# >= 2 )); do
      local_sf="$1"; local_ws="$2"; shift 2
      if cmux close-surface --surface "${local_sf}" --workspace "${local_ws}" >/dev/null 2>&1; then
        echo -e "${GREEN}closed${NC} ${local_sf} (${local_ws})"
      else
        echo -e "${RED}failed${NC} ${local_sf} (${local_ws})"
      fi
    done
    ;;

  alias)
    sub="${1:-list}"
    shift || true
    case "${sub}" in
      list)  team_alias_list "$@" ;;
      add)   team_alias_add "$@" ;;
      rm|remove|delete) team_alias_rm "$@" ;;
      check) team_alias_check "$@" ;;
      *)     die "unknown alias subcommand: ${sub} (use list|add|rm|check)" ;;
    esac
    ;;

  help|--help|-h)
    usage
    ;;

  *)
    die "unknown command: ${cmd}"
    ;;
esac
