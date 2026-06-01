#!/bin/bash
# turn-end-wip-commit.sh — Auto-commit uncommitted work at the end of each
# turn while inside a dispatched worker worktree. Captures every iteration
# so `agent-promote.sh` can later squash + merge a clean single commit into
# the base branch.
# @hook event: Stop
# @hook timeout: 30
#
# Fires only when the agent's cwd resolves to a dispatched worker worktree,
# detected via either:
#   - branch name matching `dispatch/<slug>-(claude|codex)-<idx>`
#   - worktree dirname matching `dispatch-<slug>-(claude|codex)-<idx>`
# The slug is the captured group; it is interpolated into the commit subject.
#
# Behaviour:
#   - clean tree (no staged, unstaged, or untracked) → silent exit 0
#   - dirty tree → `git add -A && git commit -m "wip(<slug>): <iso8601> — turn-end"`
#   - commit failure (pre-commit veto, lock, signing prompt, etc.) → log to
#     stderr and exit 0. A broken commit must NEVER break the turn.
#
# Opt-out: set env `WIP_COMMIT_OFF=1` before the spawning agent starts.
#
# Coverage:
#   ✅ dispatched worker worktree with dirty tree → commit
#   ✅ dispatched worker worktree with clean tree → no-op
#   ✅ base session / non-dispatch branch / non-git cwd → no-op
#   ✅ commit failure → exit 0, stderr warning

set -euo pipefail

[[ "${WIP_COMMIT_OFF:-}" == "1" ]] && exit 0

input=$(cat)
cwd=""
if command -v jq >/dev/null 2>&1; then
  cwd=$(printf '%s' "$input" | jq -r '.cwd // empty' 2>/dev/null || true)
fi
[[ -n "$cwd" ]] || cwd="$PWD"
[[ -d "$cwd" ]] || exit 0

# Resolve the worktree root from the candidate cwd. If we're not inside a
# git repo, exit silently.
worktree_root=$(git -C "$cwd" rev-parse --show-toplevel 2>/dev/null || true)
[[ -n "$worktree_root" ]] || exit 0

branch=$(git -C "$worktree_root" rev-parse --abbrev-ref HEAD 2>/dev/null || true)
[[ -n "$branch" && "$branch" != "HEAD" ]] || exit 0

# Slug detection — branch name first (authoritative), worktree dir as fallback.
slug=""
if [[ "$branch" =~ ^dispatch/(.+)-(claude|codex)-([0-9]+)$ ]]; then
  slug="${BASH_REMATCH[1]}"
fi
if [[ -z "$slug" ]]; then
  case "$worktree_root" in
    */.worktrees/dispatch-*)
      dir_tail="${worktree_root##*/}"
      if [[ "$dir_tail" =~ ^dispatch-(.+)-(claude|codex)-([0-9]+)$ ]]; then
        slug="${BASH_REMATCH[1]}"
      fi
      ;;
  esac
fi

# Not a dispatched worker worktree → silent no-op.
[[ -n "$slug" ]] || exit 0

# Skip when there is nothing to commit (staged, unstaged, untracked all empty).
if [[ -z "$(git -C "$worktree_root" status --porcelain 2>/dev/null)" ]]; then
  exit 0
fi

stamp=$(date -u +%FT%TZ)
msg="wip(${slug}): ${stamp} — turn-end"

# `git add -A` should rarely fail, but tolerate it.
if ! add_err=$(git -C "$worktree_root" add -A 2>&1); then
  echo "turn-end-wip-commit: git add failed (${worktree_root}): ${add_err}" >&2
  exit 0
fi

# Commit. Pre-commit veto, signing prompt timeout, lock contention — all
# tolerated. We never want a missed wip to break the turn.
if ! commit_err=$(git -C "$worktree_root" commit -m "$msg" 2>&1); then
  echo "turn-end-wip-commit: commit failed (${worktree_root}): ${commit_err}" >&2
  exit 0
fi

exit 0
