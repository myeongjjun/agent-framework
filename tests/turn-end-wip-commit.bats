#!/usr/bin/env bats
# turn-end-wip-commit.sh: commits a dirty sib/<slug> worktree at turn end and
# stays a silent no-op everywhere else.

setup() {
  HOOK="${BATS_TEST_DIRNAME}/../hooks/general/turn-end-wip-commit.sh"
  REPO="$BATS_TEST_TMPDIR/repo"
  git init -q -b main "$REPO"
  git -C "$REPO" config user.email t@example.com
  git -C "$REPO" config user.name t
  git -C "$REPO" config commit.gpgsign false
  echo base > "$REPO/f"
  git -C "$REPO" add f
  git -C "$REPO" commit -qm base
  unset WIP_COMMIT_OFF
}

run_hook() {
  printf '{"cwd":"%s"}' "$REPO" | bash "$HOOK"
}

commits() { git -C "$REPO" rev-list --count HEAD; }

@test "sib/<slug> branch with dirty tree gets a wip commit" {
  git -C "$REPO" checkout -qb sib/demo
  echo change >> "$REPO/f"
  echo new > "$REPO/untracked"

  run run_hook
  [ "$status" -eq 0 ]
  [ "$(commits)" -eq 2 ]
  [[ "$(git -C "$REPO" log -1 --format=%s)" == "wip(demo): "*" — turn-end" ]] || false
  [ -z "$(git -C "$REPO" status --porcelain)" ]
}

@test "sib/<slug> branch with clean tree is a no-op" {
  git -C "$REPO" checkout -qb sib/demo

  run run_hook
  [ "$status" -eq 0 ]
  [ "$(commits)" -eq 1 ]
}

@test "non-sib branch with dirty tree is a no-op" {
  echo change >> "$REPO/f"

  run run_hook
  [ "$status" -eq 0 ]
  [ "$(commits)" -eq 1 ]
  [ -n "$(git -C "$REPO" status --porcelain)" ]
}

@test "WIP_COMMIT_OFF=1 disables the commit" {
  git -C "$REPO" checkout -qb sib/demo
  echo change >> "$REPO/f"

  WIP_COMMIT_OFF=1 run run_hook
  [ "$status" -eq 0 ]
  [ "$(commits)" -eq 1 ]
}
