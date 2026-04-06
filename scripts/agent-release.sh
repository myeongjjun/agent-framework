#!/usr/bin/env bash

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"

TAG_PREFIX="agent-v"
DIFF_SCOPE=(skills hooks agent-context scripts)
ROLLBACK_SCOPE=(skills hooks agent-context scripts sync-hooks.sh sync-skills.sh)

CLAUDE_SKILLS_DIR="${HOME}/.claude/skills"
CODEX_SKILLS_DIR="${HOME}/.codex/skills"
CLAUDE_HOOKS_DIR="${HOME}/.claude/hooks"

usage() {
  cat <<'EOF'
Usage: ./scripts/agent-release.sh <command> [args]

Commands:
  tag "message"    Create annotated tag agent-vX.Y.Z with automatic patch bump
  list             Show all agent-v* tags with dates and messages
  diff vX.Y.Z      Show diff between the tag and HEAD for managed paths
  rollback vX.Y.Z  Restore managed files from the tag, redeploy, and clean stale artifacts
  current          Show the latest agent-v* tag and commits since that release
  -h, --help       Show this help message
EOF
}

die() {
  echo "Error: $*" >&2
  exit 1
}

contains_name() {
  local needle="$1"
  shift || true

  local item
  for item in "$@"; do
    if [[ "$item" == "$needle" ]]; then
      return 0
    fi
  done

  return 1
}

ensure_git_repo() {
  git -C "$REPO_ROOT" rev-parse --git-dir >/dev/null 2>&1 || die "Not a git repository: ${REPO_ROOT}"
}

ensure_clean_tree() {
  local status
  status="$(git -C "$REPO_ROOT" status --porcelain)"
  if [[ -n "$status" ]]; then
    die "Git working tree must be clean before running this command."
  fi
}

latest_agent_tag() {
  git -C "$REPO_ROOT" tag --list "${TAG_PREFIX}*" --sort=version:refname | tail -1
}

normalize_tag() {
  local raw="$1"

  if [[ "$raw" == ${TAG_PREFIX}* ]]; then
    printf '%s\n' "$raw"
    return
  fi

  if [[ "$raw" =~ ^v[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
    printf '%s%s\n' "$TAG_PREFIX" "${raw#v}"
    return
  fi

  if [[ "$raw" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
    printf '%s%s\n' "$TAG_PREFIX" "$raw"
    return
  fi

  die "Invalid version: ${raw}. Use vX.Y.Z or X.Y.Z."
}

ensure_tag_exists() {
  local tag="$1"
  git -C "$REPO_ROOT" rev-parse -q --verify "refs/tags/${tag}" >/dev/null 2>&1 || die "Tag not found: ${tag}"
}

ensure_annotated_tag() {
  local tag="$1"
  local object_type

  object_type="$(git -C "$REPO_ROOT" for-each-ref "refs/tags/${tag}" --format='%(objecttype)')"
  [[ "$object_type" == "tag" ]] || die "Tag is not annotated: ${tag}"
}

next_agent_tag() {
  local latest
  latest="$(latest_agent_tag)"

  if [[ -z "$latest" ]]; then
    printf '%s\n' "${TAG_PREFIX}1.0.0"
    return
  fi

  local version="${latest#${TAG_PREFIX}}"
  local major
  local minor
  local patch
  IFS='.' read -r major minor patch <<<"$version"

  printf '%s%d.%d.%d\n' "$TAG_PREFIX" "$major" "$minor" "$((patch + 1))"
}

show_list() {
  local lines=()
  mapfile -t lines < <(
    git -C "$REPO_ROOT" for-each-ref \
      --sort=-version:refname \
      --format='%(refname:short)|%(taggerdate:short)|%(contents:subject)|%(objecttype)' \
      "refs/tags/${TAG_PREFIX}*"
  )

  if [[ ${#lines[@]} -eq 0 ]]; then
    echo "No ${TAG_PREFIX}* tags found."
    return
  fi

  printf '%-18s %-12s %-10s %s\n' "Tag" "Date" "Type" "Message"
  printf '%-18s %-12s %-10s %s\n' "---" "----" "----" "-------"

  local line
  local tag
  local date
  local message
  local object_type
  for line in "${lines[@]}"; do
    IFS='|' read -r tag date message object_type <<<"$line"
    printf '%-18s %-12s %-10s %s\n' "$tag" "${date:-unknown}" "$object_type" "${message:-"(no message)"}"
  done
}

create_tag() {
  local message="$1"
  [[ -n "$message" ]] || die "Tag message is required."

  ensure_clean_tree

  local tag
  tag="$(next_agent_tag)"
  git -C "$REPO_ROOT" tag -a "$tag" -m "$message"

  echo "Created annotated release tag: ${tag}"
}

show_diff() {
  local tag="$1"
  git -C "$REPO_ROOT" diff "${tag}..HEAD" -- "${DIFF_SCOPE[@]}"
}

show_current() {
  local latest
  latest="$(latest_agent_tag)"

  if [[ -z "$latest" ]]; then
    echo "No ${TAG_PREFIX}* tags found."
    return
  fi

  local tag_info
  tag_info="$(git -C "$REPO_ROOT" for-each-ref --format='%(taggerdate:short)|%(contents:subject)' "refs/tags/${latest}")"

  local tag_date="${tag_info%%|*}"
  local tag_message="${tag_info#*|}"
  local commit_count
  commit_count="$(git -C "$REPO_ROOT" rev-list --count "${latest}..HEAD")"

  echo "Latest release: ${latest}"
  echo "Date: ${tag_date:-unknown}"
  echo "Message: ${tag_message:-"(no message)"}"
  echo "Commits since release: ${commit_count}"

  if [[ "$commit_count" -gt 0 ]]; then
    echo
    git -C "$REPO_ROOT" log --oneline "${latest}..HEAD"
  fi
}

remove_empty_source_dirs() {
  local path
  for path in skills hooks agent-context scripts; do
    if [[ -d "${REPO_ROOT}/${path}" ]]; then
      find "${REPO_ROOT}/${path}" -depth -type d -empty ! -path "${REPO_ROOT}/${path}" -exec rmdir {} + 2>/dev/null || true
    fi
  done
}

cleanup_deployed_skill_dir() {
  local deploy_dir="$1"
  [[ -d "$deploy_dir" ]] || return 0

  local source_skills=()
  mapfile -t source_skills < <(find "${REPO_ROOT}/skills" -mindepth 1 -maxdepth 1 -type d ! -name '.*' -exec basename {} \; | sort)

  local deployed_dir
  local skill_name
  while IFS= read -r deployed_dir; do
    [[ -n "$deployed_dir" ]] || continue
    skill_name="$(basename "$deployed_dir")"
    if ! contains_name "$skill_name" "${source_skills[@]}"; then
      rm -rf -- "$deployed_dir"
      echo "Removed stale deployed skill: ${deploy_dir}/${skill_name}"
    fi
  done < <(find "$deploy_dir" -mindepth 1 -maxdepth 1 -type d ! -name '.*' | sort)
}

cleanup_deployed_hooks() {
  [[ -d "$CLAUDE_HOOKS_DIR" ]] || return 0

  local source_hooks=()
  mapfile -t source_hooks < <(find "${REPO_ROOT}/hooks" -mindepth 2 -maxdepth 2 -type f -name '*.sh' -exec basename {} \; | sort -u)

  local deployed_file
  local hook_name
  while IFS= read -r deployed_file; do
    [[ -n "$deployed_file" ]] || continue
    hook_name="$(basename "$deployed_file")"
    if ! contains_name "$hook_name" "${source_hooks[@]}"; then
      rm -f -- "$deployed_file"
      echo "Removed stale deployed hook: ${CLAUDE_HOOKS_DIR}/${hook_name}"
    fi
  done < <(find "$CLAUDE_HOOKS_DIR" -mindepth 1 -maxdepth 1 -type f -name '*.sh' | sort)
}

rollback_release() {
  local tag="$1"
  ensure_clean_tree

  local target_files=()
  local current_files=()
  local stale_source_files=()

  mapfile -t target_files < <(git -C "$REPO_ROOT" ls-tree -r --name-only "$tag" -- "${ROLLBACK_SCOPE[@]}")
  mapfile -t current_files < <(git -C "$REPO_ROOT" ls-files -- "${ROLLBACK_SCOPE[@]}")

  if [[ ${#target_files[@]} -gt 0 ]]; then
    git -C "$REPO_ROOT" restore --worktree --source="$tag" -- "${target_files[@]}"
  fi

  if [[ ${#current_files[@]} -gt 0 ]]; then
    mapfile -t stale_source_files < <(
      comm -23 \
        <(printf '%s\n' "${current_files[@]}" | sort -u) \
        <(printf '%s\n' "${target_files[@]}" | sort -u)
    )
  fi

  if [[ ${#stale_source_files[@]} -gt 0 ]]; then
    local relative_path
    for relative_path in "${stale_source_files[@]}"; do
      rm -f -- "${REPO_ROOT}/${relative_path}"
      echo "Removed stale source file: ${relative_path}"
    done
  fi

  remove_empty_source_dirs

  "${REPO_ROOT}/sync-skills.sh" --target both --push
  "${REPO_ROOT}/sync-hooks.sh" --push

  cleanup_deployed_skill_dir "$CLAUDE_SKILLS_DIR"
  cleanup_deployed_skill_dir "$CODEX_SKILLS_DIR"
  cleanup_deployed_hooks

  echo "Rollback restored release ${tag} into the working tree."
  echo ""
  echo "NOTE: Working tree has uncommitted changes from rollback."
  echo "Run: git add -A && git commit -m 'Rollback to ${tag}'"
}

ensure_git_repo

COMMAND="${1:-}"
if [[ -z "$COMMAND" ]]; then
  usage
  exit 1
fi
shift || true

case "$COMMAND" in
  -h|--help)
    usage
    ;;
  tag)
    create_tag "$*"
    ;;
  list)
    [[ $# -eq 0 ]] || die "list does not take arguments."
    show_list
    ;;
  diff)
    [[ $# -eq 1 ]] || die "diff requires exactly one version argument."
    TAG_NAME="$(normalize_tag "$1")"
    ensure_tag_exists "$TAG_NAME"
    ensure_annotated_tag "$TAG_NAME"
    show_diff "$TAG_NAME"
    ;;
  rollback)
    [[ $# -eq 1 ]] || die "rollback requires exactly one version argument."
    TAG_NAME="$(normalize_tag "$1")"
    ensure_tag_exists "$TAG_NAME"
    ensure_annotated_tag "$TAG_NAME"
    rollback_release "$TAG_NAME"
    ;;
  current)
    [[ $# -eq 0 ]] || die "current does not take arguments."
    show_current
    ;;
  *)
    die "Unknown command: ${COMMAND}"
    ;;
esac
