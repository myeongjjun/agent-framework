#!/usr/bin/env bats
#
# Coverage for bin/agent-promote.sh.
# Each test builds a throwaway base repo + a sib-style worker worktree
# (branch sib/<slug>, checkout under ~/.local/share/sib/worktrees/) in a
# temp dir.

setup() {
  SCRIPT="${BATS_TEST_DIRNAME}/../bin/agent-promote.sh"
  TEST_ROOT="$(mktemp -d "${TMPDIR:-/tmp}/agent-promote-test.XXXXXX")"

  export HOME="${TEST_ROOT}/home"
  export GIT_CONFIG_GLOBAL="${TEST_ROOT}/gitconfig"
  export GIT_CONFIG_SYSTEM="/dev/null"
  mkdir -p "$HOME"
  cat >"$GIT_CONFIG_GLOBAL" <<'CFG'
[user]
  name = test
  email = test@example.com
[init]
  defaultBranch = main
[commit]
  gpgsign = false
[advice]
  detachedHead = false
CFG
}

teardown() {
  rm -rf "$TEST_ROOT"
}

make_base_repo() {
  local repo="${TEST_ROOT}/base"
  git init -q -b main "$repo"
  ( cd "$repo" \
      && echo "base" >README.md \
      && git add README.md \
      && git commit -q -m "initial" )
  printf '%s' "$repo"
}

# add_worker_branch <base_repo> <worker_slug>
# Mirrors `sib spawn --worktree`: branch sib/<slug>, worktree at
# ~/.local/share/sib/worktrees/<repo>-<slug>.
add_worker_branch() {
  local repo="$1" slug="$2"
  local branch="sib/${slug}"
  local wt="${HOME}/.local/share/sib/worktrees/$(basename "$repo")-${slug}"
  mkdir -p "$(dirname "$wt")"
  git -C "$repo" worktree add -q -b "$branch" "$wt"
  printf '%s' "$wt"
}

make_wip_commit() {
  local wt="$1" slug="$2" turn="$3"
  echo "content $turn" >"${wt}/file${turn}.txt"
  git -C "$wt" add -A
  git -C "$wt" commit -q -m "wip(${slug}): turn ${turn}"
}

@test "happy path: squash 3 wip commits into one base commit" {
  base="$(make_base_repo)"
  wt="$(add_worker_branch "$base" alpha)"
  make_wip_commit "$wt" alpha 1
  make_wip_commit "$wt" alpha 2
  make_wip_commit "$wt" alpha 3

  cd "$base"
  run bash "$SCRIPT" alpha --yes
  echo "$output"
  [ "$status" -eq 0 ]

  # Base now has initial + 1 squashed commit = 2 commits on main.
  [ "$(git -C "$base" rev-list --count main)" -eq 2 ]
  for f in file1.txt file2.txt file3.txt; do
    [ -f "${base}/${f}" ]
  done
  # Worker branch + worktree remain (no --cleanup)
  run git -C "$base" show-ref --verify --quiet "refs/heads/sib/alpha"
  [ "$status" -eq 0 ]
  [ -d "$wt" ]
}

@test "--no-ff merge preserves worker history (merge commit with two parents)" {
  base="$(make_base_repo)"
  wt="$(add_worker_branch "$base" beta)"

  echo "a" >"${wt}/a.txt"
  git -C "$wt" add -A && git -C "$wt" commit -q -m "feat(beta): add a"
  echo "b" >"${wt}/b.txt"
  git -C "$wt" add -A && git -C "$wt" commit -q -m "feat(beta): add b"

  cd "$base"
  run bash "$SCRIPT" beta --no-ff --yes
  echo "$output"
  [ "$status" -eq 0 ]

  parents="$(git -C "$base" log -1 --format='%P')"
  # Merge commit has 2 parents separated by space.
  [[ "$parents" == *' '* ]]
}

@test "risky files (.env + >1MB) are detected and require --yes-risk" {
  base="$(make_base_repo)"
  wt="$(add_worker_branch "$base" risky)"

  echo "SECRET=x" >"${wt}/.env"
  dd if=/dev/zero of="${wt}/big.bin" bs=1024 count=1100 status=none
  git -C "$wt" add -A
  git -C "$wt" commit -q -m "wip(risky): turn 1"

  cd "$base"

  # --yes without --yes-risk → fail
  run bash "$SCRIPT" risky --yes
  [ "$status" -ne 0 ]
  [[ "$output" == *"risk"* ]]
  [[ "$output" == *".env"* ]]
  [[ "$output" == *"big.bin"* ]]

  # --yes-risk → succeed
  run bash "$SCRIPT" risky --yes --yes-risk
  echo "$output"
  [ "$status" -eq 0 ]
  [ -f "${base}/.env" ]
  [ -f "${base}/big.bin" ]
}

@test "multi-match worker branches refuse without --branch; --branch picks one" {
  base="$(make_base_repo)"
  wt1="$(add_worker_branch "$base" multi-claude)"
  wt2="$(add_worker_branch "$base" multi-codex)"

  echo "x" >"${wt1}/a.txt"
  git -C "$wt1" add -A && git -C "$wt1" commit -q -m "wip(multi): t1"
  echo "y" >"${wt2}/b.txt"
  git -C "$wt2" add -A && git -C "$wt2" commit -q -m "wip(multi): t1"

  cd "$base"
  run bash "$SCRIPT" multi --yes
  [ "$status" -ne 0 ]
  [[ "$output" == *"multiple worker branches"* || "$output" == *"--branch"* ]]

  run bash "$SCRIPT" multi --branch "sib/multi-claude" --yes
  echo "$output"
  [ "$status" -eq 0 ]
  [ -f "${base}/a.txt" ]
  [ ! -f "${base}/b.txt" ]
}

@test "--cleanup removes worker branch + worktree after merge" {
  base="$(make_base_repo)"
  wt="$(add_worker_branch "$base" cleanup)"
  make_wip_commit "$wt" cleanup 1

  cd "$base"
  run bash "$SCRIPT" cleanup --yes --cleanup
  echo "$output"
  [ "$status" -eq 0 ]

  [ ! -d "$wt" ]
  run git -C "$base" show-ref --verify --quiet "refs/heads/sib/cleanup"
  [ "$status" -ne 0 ]
}

@test "refuses to merge into a dirty base working tree" {
  base="$(make_base_repo)"
  wt="$(add_worker_branch "$base" dirty)"
  make_wip_commit "$wt" dirty 1

  echo "uncommitted" >"${base}/junk.txt"

  cd "$base"
  run bash "$SCRIPT" dirty --yes
  [ "$status" -ne 0 ]
  [[ "$output" == *"dirty"* ]]
}

@test "--dry-run prints plan and applies no changes" {
  base="$(make_base_repo)"
  wt="$(add_worker_branch "$base" preview)"
  make_wip_commit "$wt" preview 1
  sha_before="$(git -C "$base" rev-parse HEAD)"

  cd "$base"
  run bash "$SCRIPT" preview --dry-run
  [ "$status" -eq 0 ]
  [[ "$output" == *"agent-promote plan"* ]]
  [[ "$output" == *"dry-run"* ]]

  [ "$(git -C "$base" rev-parse HEAD)" = "$sha_before" ]
  [ ! -f "${base}/file1.txt" ]
}

@test "missing worker branch → refuse with helpful message" {
  base="$(make_base_repo)"
  cd "$base"
  run bash "$SCRIPT" nonexistent --yes
  [ "$status" -ne 0 ]
  [[ "$output" == *"no worker branch"* ]]
}

@test "worker branch with no commits ahead → refuse" {
  base="$(make_base_repo)"
  wt="$(add_worker_branch "$base" empty)"
  cd "$base"
  run bash "$SCRIPT" empty --yes
  [ "$status" -ne 0 ]
  [[ "$output" == *"no commits ahead"* ]]
}

@test "--target matching current branch is accepted; mismatched → refused" {
  base="$(make_base_repo)"
  wt="$(add_worker_branch "$base" target)"
  make_wip_commit "$wt" target 1

  cd "$base"
  run bash "$SCRIPT" target --target main --yes
  [ "$status" -eq 0 ]

  # Re-run after another wip commit, with mismatched --target
  wt2="$(add_worker_branch "$base" target2)"
  echo "fresh" >"${wt2}/target2-only.txt"
  git -C "$wt2" add -A
  git -C "$wt2" commit -q -m "wip(target2): turn 1"
  run bash "$SCRIPT" target2 --target nonexistent --yes
  [ "$status" -ne 0 ]
  [[ "$output" == *"differs"* ]]
}

@test "--message overrides derived commit message" {
  base="$(make_base_repo)"
  wt="$(add_worker_branch "$base" msg)"
  make_wip_commit "$wt" msg 1

  cd "$base"
  run bash "$SCRIPT" msg --yes --message "custom: hand-picked subject"
  [ "$status" -eq 0 ]

  subject="$(git -C "$base" log -1 --format=%s)"
  [ "$subject" = "custom: hand-picked subject" ]
}

@test "refuses to run from inside a sib worker worktree" {
  base="$(make_base_repo)"
  wt="$(add_worker_branch "$base" inside)"
  make_wip_commit "$wt" inside 1

  cd "$wt"
  run bash "$SCRIPT" inside --yes
  [ "$status" -ne 0 ]
  [[ "$output" == *"not from inside a worker worktree"* ]]
}
