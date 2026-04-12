#!/bin/bash
# sync-agents.sh
# Sync agent definitions from source (agent-framework/agents/) to deployed
# (~/.claude/agents/). Mirrors the sync-skills.sh / sync-hooks.sh pattern
# so future project-local agents deploy via the same canonical entry
# point — `./scripts/sync-all.sh`.
#
# Usage:
#   ./sync-agents.sh                 # Show status
#   ./sync-agents.sh --status        # Show diff only
#   ./sync-agents.sh --push          # Push source → deployed
#   ./sync-agents.sh --push --dry-run
#   ./sync-agents.sh --list
#
# Source format: agents/<name>.md with YAML frontmatter (Claude Code agent
# definition). Subdirectories under agents/ (e.g. agents/<pack>/) are not
# scanned — keep agent files flat at the top of agents/.
#
# Deploy target: ~/.claude/agents/<name>.md (user-level, all projects).
# We deploy to user-level (not project-level .claude/agents/) so the
# helper is available wherever the rotate flow runs.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SOURCE_DIR="${SCRIPT_DIR}/agents"
DEPLOY_DIR="${HOME}/.claude/agents"

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
BOLD='\033[1m'
DIM='\033[2m'
NC='\033[0m'

MODE="status"
DRY_RUN=false

show_help() {
  cat <<EOF
Usage: $(basename "$0") [OPTIONS]

Sync agent definitions from source to deployed.

MODES:
  --status     Show diff only (default)
  --push       Push source → deployed
  --list       List discovered agents and their model/tools

OPTIONS:
  --dry-run    Preview changes without applying
  -h, --help   Show this help

Source:  ${SOURCE_DIR}/
Deploy:  ${DEPLOY_DIR}/

Conventions:
  - Files must be top-level .md under agents/ (no subdirectories)
  - README.md and INDEX.md are skipped automatically
  - Each file requires YAML frontmatter with at least name + description
EOF
  exit 0
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --status)  MODE="status"; shift ;;
    --push)    MODE="push"; shift ;;
    --list)    MODE="list"; shift ;;
    --dry-run) DRY_RUN=true; shift ;;
    -h|--help) show_help ;;
    *) echo "Unknown option: $1"; show_help ;;
  esac
done

if [[ ! -d "$SOURCE_DIR" ]]; then
  echo -e "${RED}Error: Source directory not found: ${SOURCE_DIR}${NC}"
  exit 1
fi

mkdir -p "$DEPLOY_DIR"

# Discover agent files (flat top-level .md, skip README/INDEX)
discover_agents() {
  local files=()
  shopt -s nullglob
  for f in "$SOURCE_DIR"/*.md; do
    local name
    name=$(basename "$f")
    [[ "$name" == "README.md" || "$name" == "INDEX.md" ]] && continue
    files+=("$name")
  done
  shopt -u nullglob
  # ${arr[@]+...} guard avoids "unbound variable" under `set -u` when
  # the agents directory is empty (current state after Round 6 removed
  # handoff-runner).
  printf '%s\n' ${files[@]+"${files[@]}"} | sort
}

# Extract a YAML frontmatter scalar value (single line). Tolerates quoting.
fm_field() {
  local file="$1" key="$2"
  awk -v k="$key" '
    BEGIN { in_fm=0 }
    /^---$/ { in_fm = !in_fm; next }
    in_fm && $0 ~ "^"k"[[:space:]]*:" {
      sub("^"k"[[:space:]]*:[[:space:]]*", "")
      gsub(/^["'\'']/, ""); gsub(/["'\'']$/, "")
      print
      exit
    }
  ' "$file"
}

# Categorize each source agent against deployed.
SOURCE_ONLY=()
MODIFIED=()
IN_SYNC=()
DEPLOYED_ONLY=()

while IFS= read -r name; do
  [[ -z "$name" ]] && continue
  src="$SOURCE_DIR/$name"
  dst="$DEPLOY_DIR/$name"
  if [[ ! -f "$dst" ]]; then
    SOURCE_ONLY+=("$name")
  elif ! cmp -s "$src" "$dst"; then
    MODIFIED+=("$name")
  else
    IN_SYNC+=("$name")
  fi
done < <(discover_agents)

# Find deployed-only files
shopt -s nullglob
for f in "$DEPLOY_DIR"/*.md; do
  name=$(basename "$f")
  [[ -f "$SOURCE_DIR/$name" ]] && continue
  DEPLOYED_ONLY+=("$name")
done
shopt -u nullglob

# --- list ----------------------------------------------------------------
if [[ "$MODE" == "list" ]]; then
  echo -e "${BOLD}Agents in ${SOURCE_DIR}${NC}"
  while IFS= read -r name; do
    [[ -z "$name" ]] && continue
    src="$SOURCE_DIR/$name"
    desc=$(fm_field "$src" description | head -1)
    model=$(fm_field "$src" model)
    tools=$(fm_field "$src" tools)
    echo -e "  ${BLUE}${name%.md}${NC}"
    [[ -n "$desc" ]]  && echo -e "    ${DIM}desc:${NC}  ${desc}"
    [[ -n "$model" ]] && echo -e "    ${DIM}model:${NC} ${model}"
    [[ -n "$tools" ]] && echo -e "    ${DIM}tools:${NC} ${tools}"
  done < <(discover_agents)
  exit 0
fi

# --- status --------------------------------------------------------------
print_status() {
  echo -e "${BOLD}=== Agent Sync Status ===${NC}"
  echo
  for name in "${SOURCE_ONLY[@]+"${SOURCE_ONLY[@]}"}"; do
    echo -e "  ${name%.md}  ${CYAN}→ SOURCE ONLY${NC} ${DIM}(not deployed)${NC}"
  done
  for name in "${MODIFIED[@]+"${MODIFIED[@]}"}"; do
    src="$SOURCE_DIR/$name"
    dst="$DEPLOY_DIR/$name"
    src_mt=$(stat -f %Sm -t '%Y-%m-%d %H:%M' "$src" 2>/dev/null || stat -c '%y' "$src" | cut -c1-16)
    dst_mt=$(stat -f %Sm -t '%Y-%m-%d %H:%M' "$dst" 2>/dev/null || stat -c '%y' "$dst" | cut -c1-16)
    echo -e "  ${name%.md}  ${CYAN}→ MODIFIED${NC} ${DIM}(source: $src_mt vs deployed: $dst_mt)${NC}"
  done
  for name in "${IN_SYNC[@]+"${IN_SYNC[@]}"}"; do
    echo -e "  ${name%.md}  ${GREEN}✓ in sync${NC}"
  done
  for name in "${DEPLOYED_ONLY[@]+"${DEPLOYED_ONLY[@]}"}"; do
    echo -e "  ${name%.md}  ${YELLOW}← deployed only${NC}"
  done

  local total=$(( ${#SOURCE_ONLY[@]} + ${#MODIFIED[@]} + ${#IN_SYNC[@]} + ${#DEPLOYED_ONLY[@]} ))
  if (( total == 0 )); then
    echo -e "  ${DIM}(no agents found)${NC}"
  fi
  echo
}

if [[ "$MODE" == "status" ]]; then
  print_status
  exit 0
fi

# --- push ----------------------------------------------------------------
print_status

to_push=("${SOURCE_ONLY[@]+"${SOURCE_ONLY[@]}"}" "${MODIFIED[@]+"${MODIFIED[@]}"}")

if (( ${#to_push[@]} == 0 )); then
  echo -e "${GREEN}All agents in sync.${NC}"
  exit 0
fi

for name in "${to_push[@]}"; do
  src="$SOURCE_DIR/$name"
  dst="$DEPLOY_DIR/$name"
  if $DRY_RUN; then
    echo -e "${BLUE}${name%.md}${NC} ${DIM}(dry-run) would push${NC}"
  else
    cp "$src" "$dst"
    echo -e "${BLUE}${name%.md}${NC} ${GREEN}✓ pushed${NC}"
  fi
done

if $DRY_RUN; then
  echo -e "\n${DIM}Dry run complete. No changes made.${NC}"
else
  echo -e "\n${GREEN}Agents synced.${NC}"
fi
