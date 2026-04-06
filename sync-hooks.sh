#!/bin/bash
# sync-hooks.sh
# Sync hook scripts from source (agent-framework/hooks/<category>/) to deployed (~/.claude/hooks/).
# Reads HOOKS.md manifest to auto-update ~/.claude/settings.json hooks section.
# Supports category-based profiles: --profile <name> activates general + <name> hooks.
#
# Usage:
#   ./sync-hooks.sh                          # Show status
#   ./sync-hooks.sh --status                 # Show diff only
#   ./sync-hooks.sh --push                   # Push all categories
#   ./sync-hooks.sh --push --profile myproject    # Push general + myproject only
#   ./sync-hooks.sh --push --dry-run         # Preview changes
#   ./sync-hooks.sh --list                   # List categories and hooks

set -euo pipefail

# Configuration
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SOURCE_DIR="${SCRIPT_DIR}/hooks"
DEPLOY_DIR="${HOME}/.claude/hooks"
SETTINGS_FILE="${HOME}/.claude/settings.json"
MANIFEST="${SOURCE_DIR}/HOOKS.md"
ACTIVE_PROFILE_FILE="${DEPLOY_DIR}/.active-profile"

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
MODE="status"
DRY_RUN=false
PROFILE=""

show_help() {
  cat <<EOF
Usage: $(basename "$0") [OPTIONS]

Sync hook scripts from source to deployed, and update settings.json.

MODES:
  --status                 Show diff only (default)
  --push                   Push source → deployed + update settings.json
  --list                   List categories and hooks

OPTIONS:
  --profile <category>     Activate general + specified category only
  --dry-run                Preview changes without applying
  -h, --help               Show this help

Categories are subdirectories under hooks/ (e.g., general, observability).
The 'general' category is always included.

Source:   ${SOURCE_DIR}/
Deploy:   ${DEPLOY_DIR}/
Settings: ${SETTINGS_FILE}
EOF
  exit 0
}

# Parse arguments
while [[ $# -gt 0 ]]; do
  case "$1" in
    --status)   MODE="status"; shift ;;
    --push)     MODE="push"; shift ;;
    --list)     MODE="list"; shift ;;
    --profile)
      [[ -z "${2:-}" ]] && { echo "Error: --profile requires a category name"; exit 1; }
      PROFILE="$2"; shift 2 ;;
    --dry-run)  DRY_RUN=true; shift ;;
    -h|--help)  show_help ;;
    *) echo "Unknown option: $1"; show_help ;;
  esac
done

# Ensure source directory exists
if [[ ! -d "$SOURCE_DIR" ]]; then
  echo -e "${RED}Error: Source directory not found: ${SOURCE_DIR}${NC}"
  exit 1
fi

# Get all categories (subdirectories with .sh files)
get_categories() {
  local cats=()
  for dir in "$SOURCE_DIR"/*/; do
    [[ -d "$dir" ]] || continue
    local name
    name=$(basename "$dir")
    # Only include if it has .sh files
    if compgen -G "$dir*.sh" > /dev/null 2>&1; then
      cats+=("$name")
    fi
  done
  printf '%s\n' "${cats[@]}" | sort
}

# Get active categories based on profile
get_active_categories() {
  if [[ -n "$PROFILE" ]]; then
    echo "general"
    echo "observability"
    if [[ "$PROFILE" != "general" && "$PROFILE" != "observability" ]]; then
      echo "$PROFILE"
    fi
  else
    get_categories
  fi
}

# Get hooks for a category
get_category_hooks() {
  local category="$1"
  local dir="${SOURCE_DIR}/${category}"
  if [[ -d "$dir" ]]; then
    for f in "$dir"/*.sh; do
      [[ -f "$f" ]] && basename "$f"
    done
  fi
}

# Update settings.json hooks section from HOOKS.md manifest
update_settings() {
  local active_cats="$1"

  if [[ ! -f "$MANIFEST" ]]; then
    echo -e "${YELLOW}Warning: HOOKS.md manifest not found, skipping settings.json update${NC}"
    return
  fi

  if [[ ! -f "$SETTINGS_FILE" ]]; then
    echo -e "${YELLOW}Warning: ${SETTINGS_FILE} not found, skipping settings update${NC}"
    return
  fi

  # Parse HOOKS.md table rows and build hooks JSON via jq
  # Format: | Hook | Category | Event | Matcher | Timeout | Purpose |
  # Uses a temp file to collect entries, then groups by event:matcher with jq
  local tmpentries
  tmpentries=$(mktemp)

  while IFS='|' read -r _ hook category event matcher timeout _; do
    hook=$(echo "$hook" | xargs)
    category=$(echo "$category" | xargs)
    event=$(echo "$event" | xargs)
    matcher=$(echo "$matcher" | xargs)
    timeout=$(echo "$timeout" | xargs)

    # Skip header, separator, empty
    [[ -z "$hook" || "$hook" == "Hook" || "$hook" == "---"* ]] && continue

    # Check if this hook's category is active
    local is_active=false
    for cat in $active_cats; do
      if [[ "$category" == "$cat" ]]; then
        is_active=true
        break
      fi
    done
    $is_active || continue

    # Write entry as JSON line with event+matcher metadata
    jq -n \
      --arg evt "$event" \
      --arg mat "$matcher" \
      --arg cmd "bash ${HOME}/.claude/hooks/${hook}" \
      --argjson timeout "$timeout" \
      '{ evt: $evt, mat: $mat, hook: { type: "command", command: $cmd, timeout: $timeout } }' >> "$tmpentries"
  done < "$MANIFEST"

  # Group entries by event:matcher and build settings.json hooks structure
  local new_hooks
  new_hooks=$(jq -s '
    group_by(.evt + ":" + .mat)
    | map({
        evt: .[0].evt,
        mat: .[0].mat,
        hooks: [.[].hook]
      })
    | reduce .[] as $g ({};
        .[$g.evt] = ((.[$g.evt] // []) + [
          if $g.mat != "" then { matcher: $g.mat, hooks: $g.hooks }
          else { hooks: $g.hooks } end
        ])
      )
  ' "$tmpentries")

  rm -f "$tmpentries"

  # Merge into settings.json (preserve all other fields, replace hooks)
  local tmp
  tmp=$(mktemp)
  jq --argjson hooks "$new_hooks" '.hooks = $hooks' "$SETTINGS_FILE" > "$tmp"
  mv "$tmp" "$SETTINGS_FILE"

  echo -e "${GREEN}✓ Updated ${SETTINGS_FILE} hooks section${NC}"
}

# List mode
if [[ "$MODE" == "list" ]]; then
  echo -e "${BOLD}=== Hook Categories ===${NC}"
  echo ""

  # Show active profile
  if [[ -f "$ACTIVE_PROFILE_FILE" ]]; then
    echo -e "Active profile: ${CYAN}$(cat "$ACTIVE_PROFILE_FILE")${NC}"
  else
    echo -e "Active profile: ${DIM}(none — all categories active)${NC}"
  fi
  echo ""

  for cat in $(get_categories); do
    count=0
    for f in "$SOURCE_DIR/$cat"/*.sh; do
      [[ -f "$f" ]] && ((count++))
    done

    if [[ "$cat" == "general" || "$cat" == "observability" ]]; then
      echo -e "  ${GREEN}${cat}${NC} (${count} hooks) ${DIM}— always active${NC}"
    else
      echo -e "  ${BLUE}${cat}${NC} (${count} hooks)"
    fi

    for f in "$SOURCE_DIR/$cat"/*.sh; do
      [[ -f "$f" ]] || continue
      echo -e "    ${DIM}$(basename "$f")${NC}"
    done
  done
  exit 0
fi

# Ensure deploy directory exists
mkdir -p "$DEPLOY_DIR"

# Status / Push mode
echo -e "${BOLD}=== Hook Sync Status ===${NC}"
echo ""

# Show active profile
if [[ -f "$ACTIVE_PROFILE_FILE" ]]; then
  current_profile=$(cat "$ACTIVE_PROFILE_FILE")
  echo -e "Active profile: ${CYAN}${current_profile}${NC}"
else
  echo -e "Active profile: ${DIM}(none — all categories active)${NC}"
fi

if [[ -n "$PROFILE" ]]; then
  echo -e "Target profile: ${CYAN}${PROFILE}${NC}"
fi
echo ""

SOURCE_ONLY=()
MODIFIED=()
IN_SYNC=()
synced=0

active_cats=$(get_active_categories)

for cat in $active_cats; do
  echo -e "${BOLD}[${cat}]${NC}"

  for src in "$SOURCE_DIR/$cat"/*.sh; do
    [[ -f "$src" ]] || continue
    name=$(basename "$src")
    dep="${DEPLOY_DIR}/${name}"

    if [[ ! -f "$dep" ]]; then
      SOURCE_ONLY+=("$cat/$name")
      printf "  %-35s ${CYAN}→ source only${NC}\n" "$name"
    elif diff -q "$src" "$dep" > /dev/null 2>&1; then
      IN_SYNC+=("$cat/$name")
      printf "  %-35s ${GREEN}✓ in sync${NC}\n" "$name"
    else
      MODIFIED+=("$cat/$name")
      printf "  %-35s ${YELLOW}~ modified${NC}\n" "$name"
    fi
  done
  echo ""
done

# Check for deployed hooks not in any active category
echo -e "${BOLD}[deployed-only]${NC}"
has_deployed_only=false
for dep in "$DEPLOY_DIR"/*.sh; do
  [[ -f "$dep" ]] || continue
  name=$(basename "$dep")
  found=false
  for cat in $active_cats; do
    if [[ -f "$SOURCE_DIR/$cat/$name" ]]; then
      found=true
      break
    fi
  done
  if ! $found; then
    printf "  %-35s ${YELLOW}← deployed only${NC}\n" "$name"
    has_deployed_only=true
  fi
done
if ! $has_deployed_only; then
  printf "  ${DIM}(none)${NC}\n"
fi
echo ""

total_diff=$(( ${#SOURCE_ONLY[@]} + ${#MODIFIED[@]} ))
if [[ $total_diff -eq 0 ]]; then
  echo -e "${GREEN}All hooks in sync.${NC}"
else
  echo -e "${BOLD}${total_diff} hook(s) to sync${NC}"
fi

# Status mode stops here
if [[ "$MODE" == "status" ]]; then
  exit 0
fi

# Push mode
if [[ "$MODE" == "push" ]]; then
  echo ""

  # Push source-only and modified hooks
  all_to_push=("${SOURCE_ONLY[@]+"${SOURCE_ONLY[@]}"}" "${MODIFIED[@]+"${MODIFIED[@]}"}")
  for entry in "${all_to_push[@]+"${all_to_push[@]}"}"; do
    [[ -z "$entry" ]] && continue
    cat="${entry%%/*}"
    name="${entry##*/}"
    src="$SOURCE_DIR/$cat/$name"

    if $DRY_RUN; then
      echo -e "${BLUE}${name}${NC} ${DIM}[${cat}]${NC} ${DIM}(dry-run) would push${NC}"
    else
      cp "$src" "$DEPLOY_DIR/$name"
      chmod +x "$DEPLOY_DIR/$name"
      echo -e "${BLUE}${name}${NC} ${DIM}[${cat}]${NC} ${GREEN}✓ pushed${NC}"
      ((synced++)) || true
    fi
  done

  # Always update settings.json (HOOKS.md row removal must clear stale entries)
  if true; then
    echo ""
    if $DRY_RUN; then
      echo -e "${DIM}(dry-run) Would update settings.json hooks section${NC}"
      echo -e "${DIM}(dry-run) Would write profile to .active-profile${NC}"
    else
      update_settings "$active_cats"

      # Record active profile
      if [[ -n "$PROFILE" ]]; then
        echo "$PROFILE" > "$ACTIVE_PROFILE_FILE"
        echo -e "${GREEN}✓ Active profile set: ${PROFILE}${NC}"
      else
        echo "all" > "$ACTIVE_PROFILE_FILE"
        echo -e "${GREEN}✓ Active profile set: all${NC}"
      fi
    fi
  fi

  echo ""
  if $DRY_RUN; then
    echo -e "${DIM}Dry run complete. No changes made.${NC}"
  else
    echo -e "${GREEN}Synced: ${synced} hook(s)${NC}"
  fi
fi
