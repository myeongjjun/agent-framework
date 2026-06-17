#!/usr/bin/env bats
# Regression tests for `sib spawn` placement flags:
#   --workdir / --cwd, --workspace, --new-workspace, and their interaction
#   with --worktree and the persisted state file.
#
# cmux is stubbed (tests/helpers/cmux-stub) and injected via SIB_EXTRA_PATH so
# no live cmux is touched. State + worktrees go to a throwaway XDG_DATA_HOME.

setup() {
  REPO_ROOT="$(cd "$BATS_TEST_DIRNAME/.." && pwd)"
  SIB="$REPO_ROOT/bin/sib"

  # Sandbox cmux + git behind a stub dir on the front of PATH.
  STUBDIR="$BATS_TEST_TMPDIR/stub"
  mkdir -p "$STUBDIR"
  cp "$BATS_TEST_DIRNAME/helpers/cmux-stub" "$STUBDIR/cmux"
  chmod +x "$STUBDIR/cmux"
  export SIB_EXTRA_PATH="$STUBDIR"

  export CMUX_STUB_LOG="$BATS_TEST_TMPDIR/cmux.log"
  : > "$CMUX_STUB_LOG"

  # Isolated state home + a fake cmux pane context.
  export XDG_DATA_HOME="$BATS_TEST_TMPDIR/xdg"
  export CMUX_WORKSPACE_ID="workspace:1"
  STATE="$XDG_DATA_HOME/sib/state"

  # A real working dir for --workdir targeting.
  WORKDIR="$BATS_TEST_TMPDIR/target"
  mkdir -p "$WORKDIR"
}

# --- --workdir / --cwd ------------------------------------------------------

@test "--workdir starts the sibling in the given path and records it" {
  run "$SIB" spawn wd-test --workdir "$WORKDIR"
  [ "$status" -eq 0 ]

  # the launch 'cd' targets WORKDIR
  grep -q "cmux send .* cd .*$WORKDIR && exec claude" "$CMUX_STUB_LOG"

  # state records workdir + worktree(=start dir) consistently
  grep -qx "workdir=$WORKDIR" "$STATE/wd-test.env"
  grep -qx "worktree=$WORKDIR" "$STATE/wd-test.env"
  grep -qx "worktree_managed=0" "$STATE/wd-test.env"
}

@test "--cwd is an accepted alias for --workdir" {
  run "$SIB" spawn cwd-alias --cwd "$WORKDIR"
  [ "$status" -eq 0 ]
  grep -qx "workdir=$WORKDIR" "$STATE/cwd-alias.env"
}

@test "--workdir on a nonexistent path fails before creating state" {
  run "$SIB" spawn bad-wd --workdir "$BATS_TEST_TMPDIR/nope"
  [ "$status" -ne 0 ]
  [[ "$output" == *"start dir does not exist"* ]]
  [ ! -f "$STATE/bad-wd.env" ]
}

@test "--workdir combined with --worktree is rejected" {
  run "$SIB" spawn wd-wt --workdir "$WORKDIR" --worktree
  [ "$status" -ne 0 ]
  [[ "$output" == *"do not combine with --workdir"* ]]
}

# --- default placement (legacy) ---------------------------------------------

@test "default placement splits the caller's workspace via new-pane" {
  run "$SIB" spawn def-test
  [ "$status" -eq 0 ]
  grep -q "cmux new-pane .* --workspace workspace:1" "$CMUX_STUB_LOG"
  grep -qx "workspace=workspace:1" "$STATE/def-test.env"
  grep -qx "workspace_managed=0" "$STATE/def-test.env"
}

# --- --workspace ------------------------------------------------------------

@test "--workspace splits the named workspace, not the caller's" {
  run "$SIB" spawn ws-test --workspace workspace:5
  [ "$status" -eq 0 ]
  grep -q "cmux new-split right --workspace workspace:5" "$CMUX_STUB_LOG"
  # must NOT split the caller's workspace
  ! grep -q "cmux new-pane" "$CMUX_STUB_LOG"
  grep -qx "workspace=workspace:5" "$STATE/ws-test.env"
}

# --- --new-workspace --------------------------------------------------------

@test "--new-workspace creates a dedicated workspace rooted at workdir" {
  CMUX_STUB_WS="workspace:42" CMUX_STUB_SURFACE="surface:92" \
    run "$SIB" spawn nw-test --workdir "$WORKDIR" --new-workspace
  [ "$status" -eq 0 ]
  grep -q "cmux new-workspace .* --cwd $WORKDIR" "$CMUX_STUB_LOG"
  grep -q "cmux list-pane-surfaces --workspace workspace:42" "$CMUX_STUB_LOG"
  grep -qx "workspace=workspace:42" "$STATE/nw-test.env"
  grep -qx "workspace_managed=1" "$STATE/nw-test.env"
}

@test "--workspace and --new-workspace are mutually exclusive" {
  run "$SIB" spawn xclusive --workspace workspace:5 --new-workspace
  [ "$status" -ne 0 ]
  [[ "$output" == *"mutually exclusive"* ]]
}

# --- kill cleanup -----------------------------------------------------------

@test "kill of a --new-workspace sibling closes the workspace, not a surface" {
  CMUX_STUB_WS="workspace:42" run "$SIB" spawn nw-kill --workdir "$WORKDIR" --new-workspace
  [ "$status" -eq 0 ]

  : > "$CMUX_STUB_LOG"   # only look at kill-time calls
  run "$SIB" kill nw-kill
  [ "$status" -eq 0 ]
  grep -q "cmux close-workspace --workspace workspace:42" "$CMUX_STUB_LOG"
  ! grep -q "cmux close-surface" "$CMUX_STUB_LOG"
  [ ! -f "$STATE/nw-kill.env" ]
}

@test "kill of a default sibling closes its surface" {
  run "$SIB" spawn def-kill
  [ "$status" -eq 0 ]

  : > "$CMUX_STUB_LOG"
  run "$SIB" kill def-kill
  [ "$status" -eq 0 ]
  grep -q "cmux close-surface" "$CMUX_STUB_LOG"
  ! grep -q "cmux close-workspace" "$CMUX_STUB_LOG"
}

@test "kill of a state file lacking workspace_managed defaults to surface close" {
  # simulate a pre-upgrade state file (no workspace_managed line)
  mkdir -p "$STATE"
  cat > "$STATE/legacy.env" <<EOF
slug=legacy
agent=claude
surface=surface:11
workspace=workspace:1
worktree=$WORKDIR
worktree_managed=0
EOF
  run "$SIB" kill legacy
  [ "$status" -eq 0 ]
  grep -q "cmux close-surface --surface surface:11" "$CMUX_STUB_LOG"
}
