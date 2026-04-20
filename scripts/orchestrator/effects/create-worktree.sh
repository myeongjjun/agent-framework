#!/usr/bin/env bash
#
# effects/create-worktree.sh — provision a per-task git worktree.
#
# SIDE EFFECT: calls `git worktree add`. Dry-run by default.
#
# Stage 0: per-dispatch worktree is the default isolation mechanism so
# concurrent claude/codex agents working on different tasks in the same
# project never collide on git working-directory state.
#
# Usage:
#   create-worktree.sh [--dry-run|--execute] <project-cwd> <worktree-path> <branch> [base-ref]
#
# Outputs JSON describing the action (or the dry-run preview).

set -euo pipefail
IFS=$'\n\t'

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
. "${SCRIPT_DIR}/guard.sh"

usage() {
  cat <<'EOF'
Usage: create-worktree.sh [--dry-run|--execute] <project-cwd> <worktree-path> <branch> [base-ref]

Provision a per-task git worktree at <worktree-path>, branched from
<base-ref> (default HEAD), with branch name <branch>. Dry-run by default.
EOF
}

mode='dry-run'

while (($# > 0)); do
  case "$1" in
    --dry-run) mode='dry-run'; shift ;;
    --execute) mode='execute'; shift ;;
    --help|-h) usage; exit 0 ;;
    *) break ;;
  esac
done

[[ $# -ge 3 ]] || { usage >&2; exit 1; }

project_cwd="$1"
worktree_path="$2"
branch="$3"
base_ref="${4:-HEAD}"

if [[ "${mode}" == 'dry-run' ]]; then
  jq -n \
    --arg project_cwd "${project_cwd}" \
    --arg worktree_path "${worktree_path}" \
    --arg branch "${branch}" \
    --arg base_ref "${base_ref}" \
    '{
      action: "create-worktree",
      mode: "dry-run",
      project_cwd: $project_cwd,
      worktree_path: $worktree_path,
      branch: $branch,
      base_ref: $base_ref,
      commands: [
        ("git -C " + $project_cwd + " worktree add -b " + $branch + " " + $worktree_path + " " + $base_ref)
      ]
    }'
  exit 0
fi

command -v git >/dev/null 2>&1 || { echo "create-worktree.sh: git not found" >&2; exit 1; }
[[ -d "${project_cwd}/.git" || -f "${project_cwd}/.git" ]] || {
  echo "create-worktree.sh: ${project_cwd} is not a git repository" >&2
  exit 1
}
[[ ! -e "${worktree_path}" ]] || {
  echo "create-worktree.sh: ${worktree_path} already exists — refusing to clobber" >&2
  exit 1
}

mkdir -p "$(dirname -- "${worktree_path}")"
# Capture git stderr so failures surface with a useful message instead of
# silently propagating a bare exit code to the caller (M12 fix).
git_err="$(git -C "${project_cwd}" worktree add -b "${branch}" "${worktree_path}" "${base_ref}" 2>&1 >/dev/null)" || {
  echo "create-worktree.sh: git worktree add failed for ${branch} @ ${worktree_path}:" >&2
  printf '%s\n' "${git_err}" >&2
  exit 1
}

jq -n \
  --arg project_cwd "${project_cwd}" \
  --arg worktree_path "${worktree_path}" \
  --arg branch "${branch}" \
  --arg base_ref "${base_ref}" \
  '{
    action: "create-worktree",
    mode: "execute",
    project_cwd: $project_cwd,
    worktree_path: $worktree_path,
    branch: $branch,
    base_ref: $base_ref
  }'
