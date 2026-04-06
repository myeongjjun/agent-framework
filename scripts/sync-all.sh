#!/bin/bash
# sync-all.sh — Unified deploy: skills + hooks in one command.
# Replaces the repeated `sync-skills.sh && sync-hooks.sh` pattern.
#
# Usage:
#   ./scripts/sync-all.sh                       # deploy skills + hooks
#   ./scripts/sync-all.sh --dry-run             # preview
#   ./scripts/sync-all.sh --profile myproject  # pass profile to hooks

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

Unified deploy: sync skills + hooks in a single command.

OPTIONS:
  --profile <name>   Pass profile to sync-hooks.sh (e.g., myproject)
  --dry-run          Preview changes without applying
  -h, --help         Show this help

EXAMPLES:
  $(basename "$0")                       # deploy skills + hooks
  $(basename "$0") --dry-run             # preview both
  $(basename "$0") --profile myproject  # hooks with clickhouse profile
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

if $DRY_RUN; then
  SKILLS_ARGS+=("--dry-run")
  HOOKS_ARGS+=("--dry-run")
fi

if [[ -n "$PROFILE" ]]; then
  HOOKS_ARGS+=("--profile" "$PROFILE")
fi

# Track results
skills_ok=false
hooks_ok=false

# --- Step 1: Skills ---
echo -e "${BOLD}=== [1/2] Syncing Skills ===${NC}"
echo ""
if "$REPO_ROOT/sync-skills.sh" "${SKILLS_ARGS[@]}"; then
  skills_ok=true
else
  echo -e "${RED}Skills sync failed${NC}"
fi

echo ""

# --- Step 2: Hooks ---
echo -e "${BOLD}=== [2/2] Syncing Hooks ===${NC}"
echo ""
if "$REPO_ROOT/sync-hooks.sh" "${HOOKS_ARGS[@]}"; then
  hooks_ok=true
else
  echo -e "${RED}Hooks sync failed${NC}"
fi

# --- Summary ---
echo ""
echo -e "${BOLD}=== Deploy Summary ===${NC}"

if $skills_ok; then
  echo -e "  Skills: ${GREEN}OK${NC}"
else
  echo -e "  Skills: ${RED}FAILED${NC}"
fi

if $hooks_ok; then
  echo -e "  Hooks:  ${GREEN}OK${NC}"
else
  echo -e "  Hooks:  ${RED}FAILED${NC}"
fi

if $DRY_RUN; then
  echo -e "  ${DIM}(dry-run — no changes applied)${NC}"
fi

if $skills_ok && $hooks_ok; then
  echo -e "\n${GREEN}All synced.${NC}"
  exit 0
else
  echo -e "\n${YELLOW}Partial failure — check output above.${NC}"
  exit 1
fi
