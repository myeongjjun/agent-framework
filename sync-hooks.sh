#!/bin/bash
# sync-hooks.sh
# Sync hook scripts from source (agent-framework/hooks/<category>/) to deployed
# hook directories for Claude and/or Codex. Reads @hook metadata from file
# headers to auto-update ~/.claude/settings.json and ~/.codex/hooks.json.
# Supports category-based profiles: --profile <name> activates general +
# observability + <name> hooks.
#
# Usage:
#   ./sync-hooks.sh                          # Show status
#   ./sync-hooks.sh --status                 # Show diff only
#   ./sync-hooks.sh --push                   # Push all categories
#   ./sync-hooks.sh --push --profile myproject    # Push general + observability + myproject
#   ./sync-hooks.sh --push --dry-run         # Preview changes
#   ./sync-hooks.sh --list                   # List categories and hooks

set -euo pipefail

# Configuration
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SOURCE_DIR="${SCRIPT_DIR}/hooks"
CLAUDE_DEPLOY_DIR="${HOME}/.claude/hooks"
CLAUDE_SETTINGS_FILE="${HOME}/.claude/settings.json"
CLAUDE_ACTIVE_PROFILE_FILE="${CLAUDE_DEPLOY_DIR}/.active-profile"
CODEX_DEPLOY_DIR="${HOME}/.codex/hooks"
CODEX_HOOKS_FILE="${HOME}/.codex/hooks.json"
CODEX_CONFIG_FILE="${HOME}/.codex/config.toml"
CODEX_ACTIVE_PROFILE_FILE="${CODEX_DEPLOY_DIR}/.active-profile"

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
TARGET="both"

show_help() {
  cat <<EOF
Usage: $(basename "$0") [OPTIONS]

Sync hook scripts from source to deployed targets, and update runtime hook config.

MODES:
  --status                 Show diff only (default)
  --push                   Push source → deployed + update settings.json
  --list                   List categories and hooks

OPTIONS:
  --target <target>        One of: claude | codex | both (default: both)
  --profile <category>     Activate general + observability + specified category
  --dry-run                Preview changes without applying
  -h, --help               Show this help

Categories are subdirectories under hooks/ (e.g., general, observability).
The 'general' and 'observability' categories are always included.

Source:   ${SOURCE_DIR}/
Claude:   ${CLAUDE_DEPLOY_DIR}/ + ${CLAUDE_SETTINGS_FILE}
Codex:    ${CODEX_DEPLOY_DIR}/ + ${CODEX_HOOKS_FILE}
EOF
  exit 0
}

# Parse arguments
while [[ $# -gt 0 ]]; do
  case "$1" in
    --status)   MODE="status"; shift ;;
    --push)     MODE="push"; shift ;;
    --list)     MODE="list"; shift ;;
    --target)
      [[ -z "${2:-}" ]] && { echo "Error: --target requires claude, codex, or both"; exit 1; }
      TARGET="$2"; shift 2 ;;
    --claude)   TARGET="claude"; shift ;;
    --codex)    TARGET="codex"; shift ;;
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

case "$TARGET" in
  claude|codex|both) ;;
  *)
    echo -e "${RED}Error: Invalid --target '${TARGET}' (expected claude, codex, or both)${NC}"
    exit 1
    ;;
esac

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

# Parse @hook metadata from a hook file header
# Sets: HOOK_EVENT, HOOK_MATCHER, HOOK_TIMEOUT
parse_hook_metadata() {
  local file="$1"
  HOOK_EVENT=""
  HOOK_MATCHER=""
  HOOK_TIMEOUT=""

  # Read first 15 lines for @hook directives
  local line
  while IFS= read -r line; do
    case "$line" in
      *'@hook event:'*)   HOOK_EVENT=$(echo "$line" | sed 's/.*@hook event:[[:space:]]*//')   ;;
      *'@hook matcher:'*) HOOK_MATCHER=$(echo "$line" | sed 's/.*@hook matcher:[[:space:]]*//');;
      *'@hook timeout:'*) HOOK_TIMEOUT=$(echo "$line" | sed 's/.*@hook timeout:[[:space:]]*//');;
    esac
  done < <(head -15 "$file")
}

# Check for hook files missing @hook metadata
# Returns 0 if all hooks have metadata, 1 if missing
check_missing_metadata() {
  local active_cats="$1"
  local has_missing=false

  for cat in $active_cats; do
    local dir="${SOURCE_DIR}/${cat}"
    [[ -d "$dir" ]] || continue
    for src in "$dir"/*.sh; do
      [[ -f "$src" ]] || continue
      local name
      name=$(basename "$src")

      parse_hook_metadata "$src"
      if [[ -z "$HOOK_EVENT" ]]; then
        echo -e "  ${RED}⚠ ${name}${NC} ${DIM}[${cat}]${NC} ${RED}— missing @hook event, will NOT be registered in settings.json${NC}"
        has_missing=true
      fi
    done
  done

  $has_missing && return 1
  return 0
}

# Return 0 when the hook event is supported by current Codex hooks.
codex_event_supported() {
  local event="$1"

  case "$event" in
    SessionStart|PreToolUse|PostToolUse|UserPromptSubmit|Stop)
      return 0
      ;;
    *)
      return 1
      ;;
  esac
}

# Return 0 when the specific matcher entry is meaningful for current Codex.
codex_matcher_supported() {
  local event="$1"
  local matcher="$2"

  case "$event" in
    PreToolUse|PostToolUse)
      case "$matcher" in
        ""|"*"|"Bash") return 0 ;;
        *) return 1 ;;
      esac
      ;;
    SessionStart|UserPromptSubmit|Stop)
      return 0
      ;;
    *)
      return 1
      ;;
  esac
}

hook_supported_in_codex() {
  local event="$1"
  local matcher_csv="$2"

  codex_event_supported "$event" || return 1

  case "$event" in
    PreToolUse|PostToolUse)
      if [[ -z "$matcher_csv" ]]; then
        return 0
      fi

      local matcher
      IFS=',' read -ra matchers <<< "$matcher_csv"
      for matcher in "${matchers[@]}"; do
        matcher=$(echo "$matcher" | xargs)
        if codex_matcher_supported "$event" "$matcher"; then
          return 0
        fi
      done
      return 1
      ;;
    *)
      return 0
      ;;
  esac
}

update_claude_settings() {
  local active_cats="$1"

  if [[ ! -f "$CLAUDE_SETTINGS_FILE" ]]; then
    echo -e "${YELLOW}Warning: ${CLAUDE_SETTINGS_FILE} not found, skipping Claude settings update${NC}"
    return
  fi

  local tmpentries
  tmpentries=$(mktemp)

  for cat in $active_cats; do
    local dir="${SOURCE_DIR}/${cat}"
    [[ -d "$dir" ]] || continue
    for src in "$dir"/*.sh; do
      [[ -f "$src" ]] || continue
      local name
      name=$(basename "$src")

      parse_hook_metadata "$src"

      # Skip hooks without @hook event
      [[ -z "$HOOK_EVENT" ]] && continue

      # Default timeout
      [[ -z "$HOOK_TIMEOUT" ]] && HOOK_TIMEOUT=5

      # Expand comma-separated matchers into separate entries
      if [[ -n "$HOOK_MATCHER" && "$HOOK_MATCHER" == *","* ]]; then
        IFS=',' read -ra matchers <<< "$HOOK_MATCHER"
        for mat in "${matchers[@]}"; do
          mat=$(echo "$mat" | xargs)
          jq -n \
            --arg evt "$HOOK_EVENT" \
            --arg mat "$mat" \
            --arg cmd "bash ${CLAUDE_DEPLOY_DIR}/${name}" \
            --argjson timeout "$HOOK_TIMEOUT" \
            '{ evt: $evt, mat: $mat, hook: { type: "command", command: $cmd, timeout: $timeout } }' >> "$tmpentries"
        done
      else
        jq -n \
          --arg evt "$HOOK_EVENT" \
          --arg mat "${HOOK_MATCHER:-}" \
          --arg cmd "bash ${CLAUDE_DEPLOY_DIR}/${name}" \
          --argjson timeout "$HOOK_TIMEOUT" \
          '{ evt: $evt, mat: $mat, hook: { type: "command", command: $cmd, timeout: $timeout } }' >> "$tmpentries"
      fi
    done
  done

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
  jq --argjson hooks "$new_hooks" '.hooks = $hooks' "$CLAUDE_SETTINGS_FILE" > "$tmp"
  mv "$tmp" "$CLAUDE_SETTINGS_FILE"

  echo -e "${GREEN}✓ Updated ${CLAUDE_SETTINGS_FILE} hooks section${NC}"
}

update_codex_hooks() {
  local active_cats="$1"
  local codex_root
  codex_root=$(dirname "$CODEX_HOOKS_FILE")
  mkdir -p "$codex_root"

  local tmpentries
  tmpentries=$(mktemp)

  for cat in $active_cats; do
    local dir="${SOURCE_DIR}/${cat}"
    [[ -d "$dir" ]] || continue
    for src in "$dir"/*.sh; do
      [[ -f "$src" ]] || continue
      local name
      name=$(basename "$src")

      parse_hook_metadata "$src"
      [[ -n "$HOOK_EVENT" ]] || continue
      hook_supported_in_codex "$HOOK_EVENT" "$HOOK_MATCHER" || continue

      [[ -z "$HOOK_TIMEOUT" ]] && HOOK_TIMEOUT=5

      if [[ -n "$HOOK_MATCHER" && "$HOOK_MATCHER" == *","* ]]; then
        local matcher
        IFS=',' read -ra matchers <<< "$HOOK_MATCHER"
        for matcher in "${matchers[@]}"; do
          matcher=$(echo "$matcher" | xargs)
          codex_matcher_supported "$HOOK_EVENT" "$matcher" || continue
          jq -n \
            --arg evt "$HOOK_EVENT" \
            --arg mat "$matcher" \
            --arg cmd "bash ${CODEX_DEPLOY_DIR}/${name}" \
            --argjson timeout "$HOOK_TIMEOUT" \
            '{ evt: $evt, mat: $mat, hook: { type: "command", command: $cmd, timeout: $timeout } }' >> "$tmpentries"
        done
      else
        local matcher="${HOOK_MATCHER:-}"
        codex_matcher_supported "$HOOK_EVENT" "$matcher" || continue
        jq -n \
          --arg evt "$HOOK_EVENT" \
          --arg mat "$matcher" \
          --arg cmd "bash ${CODEX_DEPLOY_DIR}/${name}" \
          --argjson timeout "$HOOK_TIMEOUT" \
          '{ evt: $evt, mat: $mat, hook: { type: "command", command: $cmd, timeout: $timeout } }' >> "$tmpentries"
      fi
    done
  done

  local new_hooks
  if [[ -s "$tmpentries" ]]; then
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
  else
    new_hooks='{}'
  fi

  rm -f "$tmpentries"
  jq -n --argjson hooks "$new_hooks" '{hooks: $hooks}' > "$CODEX_HOOKS_FILE"
  echo -e "${GREEN}✓ Updated ${CODEX_HOOKS_FILE}${NC}"
}

enable_hooks_feature() {
  # codex 0.129.0 deprecated `[features].codex_hooks` in favor of `[features].hooks`.
  # This writer emits the new key and migrates any legacy `codex_hooks = ...` line
  # under [features] to `hooks = true`.
  mkdir -p "$(dirname "$CODEX_CONFIG_FILE")"

  if [[ ! -f "$CODEX_CONFIG_FILE" ]]; then
    cat > "$CODEX_CONFIG_FILE" <<EOF
[features]
hooks = true
EOF
    echo -e "${GREEN}✓ Created ${CODEX_CONFIG_FILE} with [features].hooks enabled${NC}"
    return
  fi

  local tmp
  tmp=$(mktemp)
  awk '
    BEGIN {
      in_features = 0
      saw_features = 0
      saw_hooks = 0
    }
    /^\[features\][[:space:]]*$/ {
      print
      in_features = 1
      saw_features = 1
      next
    }
    /^\[[^]]+\][[:space:]]*$/ {
      if (in_features && !saw_hooks) {
        print "hooks = true"
        saw_hooks = 1
      }
      in_features = 0
      print
      next
    }
    {
      # Migrate legacy `codex_hooks` and write canonical `hooks`.
      if (in_features && $0 ~ /^[[:space:]]*(codex_hooks|hooks)[[:space:]]*=/) {
        if (!saw_hooks) {
          print "hooks = true"
          saw_hooks = 1
        }
        next
      }
      print
    }
    END {
      if (in_features && !saw_hooks) {
        print "hooks = true"
      } else if (!saw_features) {
        print ""
        print "[features]"
        print "hooks = true"
      }
    }
  ' "$CODEX_CONFIG_FILE" > "$tmp"
  mv "$tmp" "$CODEX_CONFIG_FILE"
  echo -e "${GREEN}✓ Enabled [features].hooks in ${CODEX_CONFIG_FILE}${NC}"
}

show_target_status() {
  local target="$1"
  local deploy_dir="$2"
  local active_profile_file="$3"
  local synced=0
  local total_diff=0
  local active_cats="$4"

  local label deploy_label
  case "$target" in
    claude) label="Claude"; deploy_label="$CLAUDE_SETTINGS_FILE" ;;
    codex)  label="Codex"; deploy_label="$CODEX_HOOKS_FILE" ;;
  esac

  echo -e "${BOLD}=== ${label} Hook Sync Status ===${NC}"
  echo ""

  if [[ -f "$active_profile_file" ]]; then
    current_profile=$(cat "$active_profile_file")
    echo -e "Active profile: ${CYAN}${current_profile}${NC}"
  else
    echo -e "Active profile: ${DIM}(none — all categories active)${NC}"
  fi

  if [[ -n "$PROFILE" ]]; then
    echo -e "Target profile: ${CYAN}${PROFILE}${NC}"
  fi
  echo -e "Target runtime: ${CYAN}${target}${NC}"
  echo -e "Deploy config: ${DIM}${deploy_label}${NC}"
  echo ""

  local SOURCE_ONLY=()
  local MODIFIED=()
  local IN_SYNC=()
  local SKIPPED=()

  mkdir -p "$deploy_dir"

  for cat in $active_cats; do
    echo -e "${BOLD}[${cat}]${NC}"

    for src in "$SOURCE_DIR/$cat"/*.sh; do
      [[ -f "$src" ]] || continue
      name=$(basename "$src")
      dep="${deploy_dir}/${name}"

      parse_hook_metadata "$src"
      if [[ "$target" == "codex" ]] && ! hook_supported_in_codex "$HOOK_EVENT" "$HOOK_MATCHER"; then
        SKIPPED+=("$cat/$name")
        printf "  %-35s ${DIM}- skipped for codex${NC}\n" "$name"
        continue
      fi

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

  echo -e "${BOLD}[deployed-only]${NC}"
  local has_deployed_only=false
  for dep in "$deploy_dir"/*.sh; do
    [[ -f "$dep" ]] || continue
    name=$(basename "$dep")
    found=false
    for cat in $active_cats; do
      if [[ -f "$SOURCE_DIR/$cat/$name" ]]; then
        if [[ "$target" == "claude" ]]; then
          found=true
          break
        fi
        parse_hook_metadata "$SOURCE_DIR/$cat/$name"
        if hook_supported_in_codex "$HOOK_EVENT" "$HOOK_MATCHER"; then
          found=true
          break
        fi
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

  echo -e "${BOLD}[missing metadata]${NC}"
  if check_missing_metadata "$active_cats"; then
    printf "  ${DIM}(none)${NC}\n"
  fi
  echo ""

  total_diff=$(( ${#SOURCE_ONLY[@]} + ${#MODIFIED[@]} ))
  if [[ $total_diff -eq 0 ]]; then
    echo -e "${GREEN}All ${label} hooks in sync.${NC}"
  else
    echo -e "${BOLD}${total_diff} ${label} hook(s) to sync${NC}"
  fi
  echo ""
}

push_target() {
  local target="$1"
  local deploy_dir="$2"
  local active_profile_file="$3"
  local active_cats="$4"
  local synced=0

  mkdir -p "$deploy_dir"

  for cat in $active_cats; do
    for src in "$SOURCE_DIR/$cat"/*.sh; do
      [[ -f "$src" ]] || continue
      name=$(basename "$src")

      parse_hook_metadata "$src"
      if [[ "$target" == "codex" ]] && ! hook_supported_in_codex "$HOOK_EVENT" "$HOOK_MATCHER"; then
        if $DRY_RUN; then
          echo -e "${DIM}${name}${NC} ${DIM}[${cat}]${NC} ${DIM}(dry-run) skipped for current Codex hook runtime${NC}"
        fi
        continue
      fi

      dep="${deploy_dir}/${name}"
      if [[ ! -f "$dep" ]] || ! diff -q "$src" "$dep" > /dev/null 2>&1; then
        if $DRY_RUN; then
          echo -e "${BLUE}${name}${NC} ${DIM}[${cat}]${NC} ${DIM}(dry-run) would push to ${target}${NC}"
        else
          cp "$src" "$deploy_dir/$name"
          chmod +x "$deploy_dir/$name"
          echo -e "${BLUE}${name}${NC} ${DIM}[${cat}]${NC} ${GREEN}✓ pushed to ${target}${NC}"
          ((synced++)) || true
        fi
      fi
    done
  done

  if ! check_missing_metadata "$active_cats" 2>/dev/null; then
    echo ""
    echo -e "${RED}⚠ Hooks with missing @hook metadata detected — add @hook headers to register in runtime config${NC}"
  fi

  echo ""
  if $DRY_RUN; then
    if [[ "$target" == "claude" ]]; then
      echo -e "${DIM}(dry-run) Would update ${CLAUDE_SETTINGS_FILE} hooks section${NC}"
    else
      echo -e "${DIM}(dry-run) Would update ${CODEX_HOOKS_FILE}${NC}"
      echo -e "${DIM}(dry-run) Would enable [features].hooks in ${CODEX_CONFIG_FILE}${NC}"
    fi
    echo -e "${DIM}(dry-run) Would write profile to ${active_profile_file}${NC}"
  else
    if [[ "$target" == "claude" ]]; then
      update_claude_settings "$active_cats"
    else
      update_codex_hooks "$active_cats"
      enable_hooks_feature
    fi

    if [[ -n "$PROFILE" ]]; then
      echo "$PROFILE" > "$active_profile_file"
      echo -e "${GREEN}✓ Active profile set: ${PROFILE}${NC}"
    else
      echo "all" > "$active_profile_file"
      echo -e "${GREEN}✓ Active profile set: all${NC}"
    fi
  fi

  echo ""
  if $DRY_RUN; then
    echo -e "${DIM}Dry run complete. No changes made for ${target}.${NC}"
  else
    echo -e "${GREEN}Synced to ${target}: ${synced} hook(s)${NC}"
  fi
}

# List mode
if [[ "$MODE" == "list" ]]; then
  echo -e "${BOLD}=== Hook Categories ===${NC}"
  echo ""
  echo -e "Target runtime: ${CYAN}${TARGET}${NC}"
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

active_cats=$(get_active_categories)

# Status mode stops here
if [[ "$MODE" == "status" ]]; then
  if [[ "$TARGET" == "claude" || "$TARGET" == "both" ]]; then
    show_target_status "claude" "$CLAUDE_DEPLOY_DIR" "$CLAUDE_ACTIVE_PROFILE_FILE" "$active_cats"
  fi
  if [[ "$TARGET" == "codex" || "$TARGET" == "both" ]]; then
    show_target_status "codex" "$CODEX_DEPLOY_DIR" "$CODEX_ACTIVE_PROFILE_FILE" "$active_cats"
  fi
  exit 0
fi

# Push mode
if [[ "$MODE" == "push" ]]; then
  if [[ "$TARGET" == "claude" || "$TARGET" == "both" ]]; then
    echo -e "${BOLD}=== Push Claude Hooks ===${NC}"
    echo ""
    push_target "claude" "$CLAUDE_DEPLOY_DIR" "$CLAUDE_ACTIVE_PROFILE_FILE" "$active_cats"
  fi
  if [[ "$TARGET" == "codex" || "$TARGET" == "both" ]]; then
    echo -e "${BOLD}=== Push Codex Hooks ===${NC}"
    echo ""
    push_target "codex" "$CODEX_DEPLOY_DIR" "$CODEX_ACTIVE_PROFILE_FILE" "$active_cats"
  fi
fi
