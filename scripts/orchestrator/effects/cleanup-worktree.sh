#!/usr/bin/env bash
#
# effects/cleanup-worktree.sh — remove a per-task git worktree.
#
# SIDE EFFECT: calls `git worktree remove` and optionally `git branch -D`.
# Dry-run by default.
#
# Stage 0: cleanup is invoked by `dispatch-done` after the sibling agent
# has merged or signalled completion. The branch is preserved by default
# (the caller decides whether to keep it for review or delete it).
#
# Usage:
#   cleanup-worktree.sh [--dry-run|--execute] <project-cwd> <worktree-path> [--branch <name>] [--delete-branch] [--force]

set -euo pipefail
IFS=$'\n\t'

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
. "${SCRIPT_DIR}/guard.sh"

usage() {
  cat <<'EOF'
Usage: cleanup-worktree.sh [--dry-run|--execute] <project-cwd> <worktree-path> \
  [--branch <name>] [--delete-branch] [--force]

Remove the per-task git worktree at <worktree-path>. Optionally delete the
associated branch. Dry-run by default. --force passes --force to
`git worktree remove` (use only when the worktree is dirty and the caller
has confirmed the work is preserved elsewhere).
EOF
}

mode='dry-run'
branch=''
delete_branch=0
force=0
positional=()

while (($# > 0)); do
  case "$1" in
    --dry-run) mode='dry-run'; shift ;;
    --execute) mode='execute'; shift ;;
    --branch)
      shift
      [[ $# -gt 0 ]] || { echo "cleanup-worktree.sh: --branch requires a value" >&2; exit 1; }
      branch="$1"
      shift
      ;;
    --delete-branch) delete_branch=1; shift ;;
    --force) force=1; shift ;;
    --help|-h) usage; exit 0 ;;
    --) shift; while (($# > 0)); do positional+=("$1"); shift; done ;;
    *) positional+=("$1"); shift ;;
  esac
done

[[ ${#positional[@]} -ge 2 ]] || { usage >&2; exit 1; }
project_cwd="${positional[0]}"
worktree_path="${positional[1]}"

remove_cmd_preview="git -C ${project_cwd} worktree remove ${worktree_path}"
(( force == 1 )) && remove_cmd_preview+=" --force"
delete_cmd_preview=""
if (( delete_branch == 1 )) && [[ -n "${branch}" ]]; then
  delete_cmd_preview="git -C ${project_cwd} branch -D ${branch}"
fi

if [[ "${mode}" == 'dry-run' ]]; then
  jq -n \
    --arg project_cwd "${project_cwd}" \
    --arg worktree_path "${worktree_path}" \
    --arg branch "${branch}" \
    --arg remove "${remove_cmd_preview}" \
    --arg delete "${delete_cmd_preview}" \
    --argjson delete_branch "${delete_branch}" \
    --argjson force "${force}" \
    '{
      action: "cleanup-worktree",
      mode: "dry-run",
      project_cwd: $project_cwd,
      worktree_path: $worktree_path,
      branch: $branch,
      delete_branch: ($delete_branch == 1),
      force: ($force == 1),
      commands: ([$remove] + (if $delete == "" then [] else [$delete] end))
    }'
  exit 0
fi

command -v git >/dev/null 2>&1 || { echo "cleanup-worktree.sh: git not found" >&2; exit 1; }
[[ -d "${project_cwd}/.git" || -f "${project_cwd}/.git" ]] || {
  echo "cleanup-worktree.sh: ${project_cwd} is not a git repository" >&2
  exit 1
}

remove_args=(worktree remove "${worktree_path}")
(( force == 1 )) && remove_args+=(--force)
git -C "${project_cwd}" "${remove_args[@]}" >/dev/null 2>&1

if (( delete_branch == 1 )) && [[ -n "${branch}" ]]; then
  git -C "${project_cwd}" branch -D "${branch}" >/dev/null 2>&1
fi

jq -n \
  --arg project_cwd "${project_cwd}" \
  --arg worktree_path "${worktree_path}" \
  --arg branch "${branch}" \
  --argjson delete_branch "${delete_branch}" \
  --argjson force "${force}" \
  '{
    action: "cleanup-worktree",
    mode: "execute",
    project_cwd: $project_cwd,
    worktree_path: $worktree_path,
    branch: $branch,
    delete_branch: ($delete_branch == 1),
    force: ($force == 1)
  }'
