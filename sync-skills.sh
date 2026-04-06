#!/bin/bash
# sync-skills.sh
# Detect drift between source skills (agent-workspace/skills/) and deployed skills,
# and selectively synchronize in either direction.
# Supports Claude (~/.claude/skills) and Codex (~/.codex/skills) targets.
#
# Usage:
#   ./sync-skills.sh              # Interactive: show diff + prompt per skill (Claude)
#   ./sync-skills.sh --status     # Show diff only (no changes)
#   ./sync-skills.sh --pull       # Pull all changed deployed→source
#   ./sync-skills.sh --pull daily # Pull specific skill
#   ./sync-skills.sh --push       # Push all changed source→deployed
#   ./sync-skills.sh --push daily # Push specific skill
#   ./sync-skills.sh --dry-run    # Preview changes without applying
#   ./sync-skills.sh --codex      # Target Codex instead of Claude
#   ./sync-skills.sh --target both # Target both Claude and Codex
#   ./sync-skills.sh --list       # List source skills

set -euo pipefail

# Configuration
SOURCE_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/skills" && pwd)"
CLAUDE_DIR="${HOME}/.claude/skills"
CODEX_DIR="${HOME}/.codex/skills"

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
BOLD='\033[1m'
DIM='\033[2m'
NC='\033[0m'

# Defaults
MODE=""          # "", "status", "pull", "push", "list"
DRY_RUN=false
SKILL_FILTER=()
TARGETS=()       # populated by args; default: claude

show_help() {
  cat <<EOF
Usage: $(basename "$0") [OPTIONS] [SKILL_NAMES...]

Detect and sync drift between source and deployed skills.

MODES:
  (default)            Interactive: show diff, prompt per changed skill
  --status             Show diff only, no changes
  --pull               Pull all changes: deployed → source
  --push               Push all changes: source → deployed
  --list               List available source skills

TARGET:
  --claude             Target Claude (~/.claude/skills) [default]
  --codex              Target Codex (~/.codex/skills)
  --target TARGET      claude | codex | both

OPTIONS:
  -h, --help           Show this help
  -n, --dry-run        Preview what would change
  SKILL_NAMES          Filter to specific skills (with --pull or --push)

EXAMPLES:
  $(basename "$0")                        # Interactive sync (Claude)
  $(basename "$0") --status               # Diff status (Claude)
  $(basename "$0") --codex --status       # Diff status (Codex)
  $(basename "$0") --target both --push   # Push to both targets
  $(basename "$0") --push                 # Push source → Claude
  $(basename "$0") --codex --push         # Push source → Codex
  $(basename "$0") --pull daily           # Pull 'daily' skill from Claude
  $(basename "$0") --dry-run --pull       # Preview pull
  $(basename "$0") --list                 # List source skills

DIRECTORIES:
  Source:  ${SOURCE_DIR}
  Claude:  ${CLAUDE_DIR}
  Codex:   ${CODEX_DIR}
EOF
  exit 0
}

list_skills() {
  echo -e "${BOLD}=== Source Skills ===${NC}"
  echo ""

  if [ ! -d "$SOURCE_DIR" ]; then
    echo -e "${RED}Error: Source directory not found: ${SOURCE_DIR}${NC}" >&2
    exit 1
  fi

  for skill in "$SOURCE_DIR"/*/; do
    [ -d "$skill" ] || continue
    local skill_name
    skill_name=$(basename "$skill")

    if [ -f "$skill/SKILL.md" ]; then
      local version description
      version=$(grep '^version:' "$skill/SKILL.md" 2>/dev/null | head -1 | sed 's/version: *//' || echo "unknown")
      description=$(grep '^description:' "$skill/SKILL.md" 2>/dev/null | head -1 | sed 's/description: *//' || echo "")

      echo -e "  ${GREEN}${skill_name}${NC} (v${version})"
      if [ -n "$description" ]; then
        echo "    $description"
      fi
    else
      echo -e "  ${YELLOW}${skill_name}${NC} (no SKILL.md)"
    fi
  done
  echo ""
  exit 0
}

# Parse arguments
while [[ $# -gt 0 ]]; do
  case $1 in
    -h|--help)
      show_help
      ;;
    --status)
      MODE="status"
      shift
      ;;
    --pull)
      MODE="pull"
      shift
      ;;
    --push)
      MODE="push"
      shift
      ;;
    --list|-l)
      MODE="list"
      shift
      ;;
    --claude)
      TARGETS+=("claude")
      shift
      ;;
    --codex)
      TARGETS+=("codex")
      shift
      ;;
    --target|-t)
      if [ $# -lt 2 ]; then
        echo -e "${RED}Error: --target requires an argument (claude|codex|both)${NC}" >&2
        exit 1
      fi
      case $2 in
        claude) TARGETS+=("claude") ;;
        codex)  TARGETS+=("codex") ;;
        both)   TARGETS+=("claude" "codex") ;;
        *)
          echo -e "${RED}Error: Unknown target: $2 (use claude|codex|both)${NC}" >&2
          exit 1
          ;;
      esac
      shift 2
      ;;
    -n|--dry-run)
      DRY_RUN=true
      shift
      ;;
    -*)
      echo -e "${RED}Error: Unknown option $1${NC}" >&2
      exit 1
      ;;
    *)
      SKILL_FILTER+=("$1")
      shift
      ;;
  esac
done

# Handle --list before target resolution
if [ "$MODE" = "list" ]; then
  list_skills
fi

# Default target: claude
if [ ${#TARGETS[@]} -eq 0 ]; then
  TARGETS=("claude")
fi

# Deduplicate targets
TARGETS=($(printf '%s\n' "${TARGETS[@]}" | awk '!seen[$0]++'))

# Validate source directory
if [ ! -d "$SOURCE_DIR" ]; then
  echo -e "${RED}Error: Source directory not found: ${SOURCE_DIR}${NC}" >&2
  exit 1
fi

# Resolve target directory
resolve_deployed_dir() {
  case $1 in
    claude) echo "$CLAUDE_DIR" ;;
    codex)  echo "$CODEX_DIR" ;;
    *)
      echo -e "${RED}Error: Unknown target: $1${NC}" >&2
      exit 1
      ;;
  esac
}

# Get newest mtime in a directory (returns epoch seconds)
newest_mtime() {
  local dir="$1"
  find "$dir" -type f -exec stat -f '%m' {} + 2>/dev/null | sort -rn | head -1
}

# Format epoch to human-readable
format_time() {
  date -r "$1" '+%Y-%m-%d %H:%M' 2>/dev/null
}

# Compare one skill, populate result variables
# Sets: DIFF_STATUS, DIFF_DIRECTION, SRC_TIME_FMT, DEP_TIME_FMT
compare_skill() {
  local name="$1"
  local deployed_dir="$2"
  local src="$SOURCE_DIR/$name"
  local dep="$deployed_dir/$name"

  DIFF_STATUS=""
  DIFF_DIRECTION=""
  SRC_TIME_FMT=""
  DEP_TIME_FMT=""

  # Only in source
  if [ -d "$src" ] && [ ! -d "$dep" ]; then
    DIFF_STATUS="source_only"
    DIFF_DIRECTION="push"
    return
  fi

  # Only in deployed
  if [ ! -d "$src" ] && [ -d "$dep" ]; then
    DIFF_STATUS="deployed_only"
    DIFF_DIRECTION="pull"
    return
  fi

  # Both exist — diff content
  if diff -rq "$src" "$dep" >/dev/null 2>&1; then
    DIFF_STATUS="in_sync"
    return
  fi

  # Content differs — determine direction by mtime
  DIFF_STATUS="modified"
  local src_mtime dep_mtime
  src_mtime=$(newest_mtime "$src")
  dep_mtime=$(newest_mtime "$dep")
  SRC_TIME_FMT=$(format_time "$src_mtime")
  DEP_TIME_FMT=$(format_time "$dep_mtime")

  if [ "$dep_mtime" -gt "$src_mtime" ]; then
    DIFF_DIRECTION="pull"
  elif [ "$src_mtime" -gt "$dep_mtime" ]; then
    DIFF_DIRECTION="push"
  else
    DIFF_DIRECTION="unknown"
  fi
}

# Sync functions
do_pull() {
  local skill="$1"
  local deployed_dir="$2"
  local src="$SOURCE_DIR/$skill"
  local dep="$deployed_dir/$skill"

  if [ ! -d "$dep" ]; then
    echo -e "  ${RED}Cannot pull: deployed directory does not exist${NC}"
    return 1
  fi

  if [ "$DRY_RUN" = true ]; then
    echo -e "  ${YELLOW}[DRY RUN]${NC} Would copy: ${dep} → ${src}"
    return 0
  fi

  rm -rf "$src"
  cp -r "$dep" "$src"
  echo -e "  ${GREEN}✓ Pulled: deployed → source${NC}"
}

do_push() {
  local skill="$1"
  local deployed_dir="$2"
  local src="$SOURCE_DIR/$skill"
  local dep="$deployed_dir/$skill"

  if [ ! -d "$src" ]; then
    echo -e "  ${RED}Cannot push: source directory does not exist${NC}"
    return 1
  fi

  if [ "$DRY_RUN" = true ]; then
    echo -e "  ${YELLOW}[DRY RUN]${NC} Would copy: ${src} → ${dep}"
    return 0
  fi

  mkdir -p "$deployed_dir"
  rm -rf "$dep"
  cp -r "$src" "$dep"

  # Set executable permissions for scripts
  if [ -d "$dep/scripts" ]; then
    chmod +x "$dep/scripts/"*.sh 2>/dev/null || true
  fi

  echo -e "  ${GREEN}✓ Pushed: source → deployed${NC}"
}

# ── Run sync for a single target ────────────────────────────────────
run_for_target() {
  local target="$1"
  local DEPLOYED_DIR
  DEPLOYED_DIR="$(resolve_deployed_dir "$target")"

  local target_label
  case $target in
    claude) target_label="Claude (~/.claude/skills)" ;;
    codex)  target_label="Codex (~/.codex/skills)" ;;
  esac

  # Validate deployed directory exists (create on push if needed)
  if [ ! -d "$DEPLOYED_DIR" ]; then
    if [ "$MODE" = "push" ]; then
      if [ "$DRY_RUN" = false ]; then
        mkdir -p "$DEPLOYED_DIR"
      fi
    else
      echo -e "${YELLOW}Warning: Deployed directory not found for ${target}: ${DEPLOYED_DIR}${NC}"
      echo -e "${DIM}Use --push to create and deploy skills.${NC}"
      echo ""
      return 0
    fi
  fi

  # Collect all skill names from both sides (union), sorted and deduped
  local SORTED_SKILLS=()
  {
    for d in "$SOURCE_DIR"/*/; do
      [ -d "$d" ] && basename "$d"
    done
    if [ -d "$DEPLOYED_DIR" ]; then
      for d in "$DEPLOYED_DIR"/*/; do
        [ -d "$d" ] && basename "$d"
      done
    fi
  } | sort -u > /tmp/sync-skills-list.$$

  while IFS= read -r name; do
    SORTED_SKILLS+=("$name")
  done < /tmp/sync-skills-list.$$
  rm -f /tmp/sync-skills-list.$$

  # Apply filter if specified
  if [ ${#SKILL_FILTER[@]} -gt 0 ]; then
    local FILTERED=()
    for skill in "${SORTED_SKILLS[@]}"; do
      for f in "${SKILL_FILTER[@]}"; do
        if [ "$skill" = "$f" ]; then
          FILTERED+=("$skill")
          break
        fi
      done
    done
    # Validate filter
    for f in "${SKILL_FILTER[@]}"; do
      local found=false
      for skill in "${SORTED_SKILLS[@]}"; do
        [ "$skill" = "$f" ] && found=true && break
      done
      if [ "$found" = false ]; then
        echo -e "${RED}Error: Skill not found: ${f}${NC}" >&2
        return 1
      fi
    done
    SORTED_SKILLS=("${FILTERED[@]}")
  fi

  # Parallel arrays to store results
  local R_STATUS=()
  local R_DIRECTION=()
  local PULL_COUNT=0
  local PUSH_COUNT=0
  local SRC_ONLY_COUNT=0
  local DEP_ONLY_COUNT=0

  echo -e "${BOLD}=== Skill Sync Status [${target_label}] ===${NC}"
  echo ""

  local idx=0
  for skill in "${SORTED_SKILLS[@]}"; do
    compare_skill "$skill" "$DEPLOYED_DIR"
    R_STATUS+=("$DIFF_STATUS")
    R_DIRECTION+=("$DIFF_DIRECTION")

    case "$DIFF_STATUS" in
      in_sync)
        printf "  %-16s ${GREEN}✓ in sync${NC}\n" "$skill"
        ;;
      modified)
        if [ "$DIFF_DIRECTION" = "pull" ]; then
          printf "  %-16s ${YELLOW}← MODIFIED${NC} ${DIM}(deployed newer: %s vs source: %s)${NC}\n" \
            "$skill" "$DEP_TIME_FMT" "$SRC_TIME_FMT"
          PULL_COUNT=$((PULL_COUNT + 1))
        elif [ "$DIFF_DIRECTION" = "push" ]; then
          printf "  %-16s ${CYAN}→ MODIFIED${NC} ${DIM}(source newer: %s vs deployed: %s)${NC}\n" \
            "$skill" "$SRC_TIME_FMT" "$DEP_TIME_FMT"
          PUSH_COUNT=$((PUSH_COUNT + 1))
        else
          printf "  %-16s ${RED}⚠ MODIFIED${NC} ${DIM}(same mtime — check manually)${NC}\n" "$skill"
          PULL_COUNT=$((PULL_COUNT + 1))
        fi
        ;;
      source_only)
        printf "  %-16s ${CYAN}→ SOURCE ONLY${NC} ${DIM}(not deployed)${NC}\n" "$skill"
        SRC_ONLY_COUNT=$((SRC_ONLY_COUNT + 1))
        ;;
      deployed_only)
        printf "  %-16s ${YELLOW}← DEPLOYED ONLY${NC} ${DIM}(not in source)${NC}\n" "$skill"
        DEP_ONLY_COUNT=$((DEP_ONLY_COUNT + 1))
        ;;
    esac

    idx=$((idx + 1))
  done

  echo ""

  # Summary line
  local TOTAL_CHANGES=$((PULL_COUNT + PUSH_COUNT + SRC_ONLY_COUNT + DEP_ONLY_COUNT))
  if [ $TOTAL_CHANGES -eq 0 ]; then
    echo -e "${GREEN}All skills are in sync.${NC}"
    echo ""
    return 0
  fi

  local SUMMARY=""
  [ $PULL_COUNT -gt 0 ] && SUMMARY="${SUMMARY}${PULL_COUNT} need pull, "
  [ $PUSH_COUNT -gt 0 ] && SUMMARY="${SUMMARY}${PUSH_COUNT} need push, "
  [ $SRC_ONLY_COUNT -gt 0 ] && SUMMARY="${SUMMARY}${SRC_ONLY_COUNT} source-only, "
  [ $DEP_ONLY_COUNT -gt 0 ] && SUMMARY="${SUMMARY}${DEP_ONLY_COUNT} deployed-only, "
  SUMMARY="${SUMMARY%, }"

  echo -e "${BOLD}${TOTAL_CHANGES} skill(s) differ: ${SUMMARY}${NC}"
  echo ""

  # If status-only mode, return
  if [ "$MODE" = "status" ]; then
    return 0
  fi

  # Batch pull/push mode
  if [ "$MODE" = "pull" ] || [ "$MODE" = "push" ]; then
    local SYNCED=0
    local SKIPPED=0

    idx=0
    for skill in "${SORTED_SKILLS[@]}"; do
      local status="${R_STATUS[$idx]}"

      if [ "$status" = "in_sync" ]; then
        idx=$((idx + 1))
        continue
      fi

      echo -e "${BLUE}${skill}:${NC}"

      if [ "$MODE" = "pull" ]; then
        if [ "$status" = "source_only" ]; then
          echo -e "  ${DIM}Skipped (source-only, nothing to pull)${NC}"
          SKIPPED=$((SKIPPED + 1))
        else
          do_pull "$skill" "$DEPLOYED_DIR" && SYNCED=$((SYNCED + 1))
        fi
      elif [ "$MODE" = "push" ]; then
        if [ "$status" = "deployed_only" ]; then
          echo -e "  ${DIM}Skipped (deployed-only, nothing to push)${NC}"
          SKIPPED=$((SKIPPED + 1))
        else
          do_push "$skill" "$DEPLOYED_DIR" && SYNCED=$((SYNCED + 1))
        fi
      fi

      idx=$((idx + 1))
    done

    echo ""
    if [ "$DRY_RUN" = true ]; then
      echo -e "${YELLOW}Dry run complete. No files were changed.${NC}"
    else
      echo -e "${GREEN}Synced: ${SYNCED} skill(s)${NC}"
      [ $SKIPPED -gt 0 ] && echo -e "${DIM}Skipped: ${SKIPPED} skill(s)${NC}"
    fi
    return 0
  fi

  # Interactive mode (default)
  echo -e "${BOLD}Interactive sync${NC} — for each changed skill, choose an action:"
  echo -e "${DIM}  [p]ull = deployed→source  [P]ush = source→deployed  [s]kip  [d]iff  [q]uit${NC}"
  echo ""

  local SYNCED=0
  local SKIPPED=0

  idx=0
  for skill in "${SORTED_SKILLS[@]}"; do
    local status="${R_STATUS[$idx]}"

    if [ "$status" = "in_sync" ]; then
      idx=$((idx + 1))
      continue
    fi

    local direction="${R_DIRECTION[$idx]}"

    case "$status" in
      modified)
        if [ "$direction" = "pull" ]; then
          echo -e "${YELLOW}← ${skill}${NC} (deployed newer)"
        else
          echo -e "${CYAN}→ ${skill}${NC} (source newer)"
        fi
        ;;
      source_only)
        echo -e "${CYAN}→ ${skill}${NC} (source only)"
        ;;
      deployed_only)
        echo -e "${YELLOW}← ${skill}${NC} (deployed only)"
        ;;
    esac

    while true; do
      echo -n "  Action [p/P/s/d/q]: "
      read -r action </dev/tty

      case "$action" in
        p)
          echo -e "  ${BLUE}Pulling...${NC}"
          if [ "$status" = "source_only" ]; then
            echo -e "  ${RED}Nothing to pull (source-only skill)${NC}"
          elif [ "$DRY_RUN" = true ]; then
            echo -e "  ${YELLOW}[DRY RUN]${NC} Would pull deployed → source"
            SYNCED=$((SYNCED + 1))
          else
            do_pull "$skill" "$DEPLOYED_DIR" && SYNCED=$((SYNCED + 1))
          fi
          break
          ;;
        P)
          echo -e "  ${BLUE}Pushing...${NC}"
          if [ "$status" = "deployed_only" ]; then
            echo -e "  ${RED}Nothing to push (deployed-only skill)${NC}"
          elif [ "$DRY_RUN" = true ]; then
            echo -e "  ${YELLOW}[DRY RUN]${NC} Would push source → deployed"
            SYNCED=$((SYNCED + 1))
          else
            do_push "$skill" "$DEPLOYED_DIR" && SYNCED=$((SYNCED + 1))
          fi
          break
          ;;
        s|"")
          echo -e "  ${DIM}Skipped${NC}"
          SKIPPED=$((SKIPPED + 1))
          break
          ;;
        d)
          local local_src="$SOURCE_DIR/$skill"
          local local_dep="$DEPLOYED_DIR/$skill"
          if [ -d "$local_src" ] && [ -d "$local_dep" ]; then
            diff -ru "$local_src" "$local_dep" | head -60 || true
          elif [ -d "$local_src" ]; then
            echo -e "  ${DIM}(only exists in source)${NC}"
          else
            echo -e "  ${DIM}(only exists in deployed)${NC}"
          fi
          echo ""
          ;;
        q)
          echo -e "\n${DIM}Quit.${NC}"
          exit 0
          ;;
        *)
          echo -e "  ${DIM}Unknown action. Use p/P/s/d/q${NC}"
          ;;
      esac
    done
    echo ""

    idx=$((idx + 1))
  done

  echo -e "${GREEN}Done.${NC} Synced: ${SYNCED}, Skipped: ${SKIPPED}"
}

# ── Main: iterate over targets ──────────────────────────────────────
for target in "${TARGETS[@]}"; do
  run_for_target "$target"
done
