#!/bin/bash
# sync-all.sh — Unified deploy: skills + hooks + agents + global scripts.
# Replaces the repeated `sync-skills.sh && sync-hooks.sh` pattern and now
# also includes sync-agents.sh for agent definitions and an explicit global
# scripts deploy step (top-level scripts/*.sh referenced from skills via
# absolute path ~/.claude/scripts/<name>).
#
# Usage:
#   ./scripts/sync-all.sh                       # deploy skills + hooks + agents + scripts
#   ./scripts/sync-all.sh --dry-run             # preview
#   ./scripts/sync-all.sh --profile myproject    # pass profile to hooks

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BOLD='\033[1m'
DIM='\033[2m'
NC='\033[0m'

# Defaults
DRY_RUN=false
PROFILE=""

show_help() {
  cat <<EOF
Usage: $(basename "$0") [OPTIONS]

Unified deploy: sync skills + hooks + agents + global scripts in a single command.

OPTIONS:
  --profile <name>   Pass profile to sync-hooks.sh (e.g., myproject)
  --dry-run          Preview changes without applying
  -h, --help         Show this help

EXAMPLES:
  $(basename "$0")                       # deploy skills + hooks + agents + scripts
  $(basename "$0") --dry-run             # preview all four
  $(basename "$0") --profile myproject   # hooks with myproject profile
EOF
  exit 0
}

# Parse arguments
while [[ $# -gt 0 ]]; do
  case "$1" in
    --profile)
      [[ -z "${2:-}" ]] && { echo -e "${RED}Error: --profile requires a name${NC}"; exit 1; }
      PROFILE="$2"; shift 2 ;;
    --dry-run)  DRY_RUN=true; shift ;;
    -h|--help)  show_help ;;
    *) echo -e "${RED}Unknown option: $1${NC}"; show_help ;;
  esac
done

# Build argument arrays
SKILLS_ARGS=("--target" "both" "--push")
HOOKS_ARGS=("--push")
AGENTS_ARGS=("--push")

if $DRY_RUN; then
  SKILLS_ARGS+=("--dry-run")
  HOOKS_ARGS+=("--dry-run")
  AGENTS_ARGS+=("--dry-run")
fi

if [[ -n "$PROFILE" ]]; then
  HOOKS_ARGS+=("--profile" "$PROFILE")
fi

# Track results
skills_ok=false
hooks_ok=false
agents_ok=false
scripts_ok=false

# --- Step 1: Skills ---
echo -e "${BOLD}=== [1/4] Syncing Skills ===${NC}"
echo ""
if "$REPO_ROOT/sync-skills.sh" "${SKILLS_ARGS[@]}"; then
  skills_ok=true
else
  echo -e "${RED}Skills sync failed${NC}"
fi

echo ""

# --- Step 2: Hooks ---
echo -e "${BOLD}=== [2/4] Syncing Hooks ===${NC}"
echo ""
if "$REPO_ROOT/sync-hooks.sh" "${HOOKS_ARGS[@]}"; then
  hooks_ok=true
else
  echo -e "${RED}Hooks sync failed${NC}"
fi

echo ""

# --- Step 3: Agents ---
echo -e "${BOLD}=== [3/4] Syncing Agents ===${NC}"
echo ""
if "$REPO_ROOT/sync-agents.sh" "${AGENTS_ARGS[@]}"; then
  agents_ok=true
else
  echo -e "${RED}Agents sync failed${NC}"
fi

echo ""

# --- Step 4: Global scripts ---
# Top-level project scripts that need to be invokable from any cwd by any
# claude session (e.g., handoff-rotate.sh referenced by skills/handoff
# via absolute path ~/.claude/scripts/<name>). Mirrors sync-hooks.sh's
# flat-file deploy pattern.
echo -e "${BOLD}=== [4/4] Syncing Global Scripts ===${NC}"
echo ""

GLOBAL_SCRIPTS=(handoff-rotate.sh)
GLOBAL_DEST="$HOME/.claude/scripts"
scripts_ok=true

if $DRY_RUN; then
  for s in "${GLOBAL_SCRIPTS[@]}"; do
    src="$REPO_ROOT/scripts/$s"
    if [[ ! -f "$src" ]]; then
      echo -e "  ${RED}MISSING:${NC} $src"
      scripts_ok=false
      continue
    fi
    echo -e "  ${YELLOW}[dry-run]${NC} would install $src -> $GLOBAL_DEST/$s"
  done
else
  mkdir -p "$GLOBAL_DEST"
  for s in "${GLOBAL_SCRIPTS[@]}"; do
    src="$REPO_ROOT/scripts/$s"
    if [[ ! -f "$src" ]]; then
      echo -e "  ${RED}MISSING:${NC} $src"
      scripts_ok=false
      continue
    fi
    if install -m 755 "$src" "$GLOBAL_DEST/$s"; then
      echo -e "  ${GREEN}✓${NC} $s -> $GLOBAL_DEST/$s"
    else
      echo -e "  ${RED}FAILED:${NC} $s"
      scripts_ok=false
    fi
  done
fi

# --- Summary ---
echo ""
echo -e "${BOLD}=== Deploy Summary ===${NC}"

if $skills_ok; then
  echo -e "  Skills:  ${GREEN}OK${NC}"
else
  echo -e "  Skills:  ${RED}FAILED${NC}"
fi

if $hooks_ok; then
  echo -e "  Hooks:   ${GREEN}OK${NC}"
else
  echo -e "  Hooks:   ${RED}FAILED${NC}"
fi

if $agents_ok; then
  echo -e "  Agents:  ${GREEN}OK${NC}"
else
  echo -e "  Agents:  ${RED}FAILED${NC}"
fi

if $scripts_ok; then
  echo -e "  Scripts: ${GREEN}OK${NC}"
else
  echo -e "  Scripts: ${RED}FAILED${NC}"
fi

if $DRY_RUN; then
  echo -e "  ${DIM}(dry-run — no changes applied)${NC}"
fi

if $skills_ok && $hooks_ok && $agents_ok && $scripts_ok; then
  echo -e "\n${GREEN}All synced.${NC}"
  exit 0
else
  echo -e "\n${YELLOW}Partial failure — check output above.${NC}"
  exit 1
fi
