#!/usr/bin/env bats
# Regression tests for skills/pane-msg/scripts/pane-deliver.sh (used by
# `brief done` and `sib send`). cmux is stubbed (tests/helpers/cmux-stub).

setup() {
  REPO_ROOT="$(cd "$BATS_TEST_DIRNAME/.." && pwd)"
  DELIVER="$REPO_ROOT/skills/pane-msg/scripts/pane-deliver.sh"
  STUBDIR="$BATS_TEST_TMPDIR/stub"
  mkdir -p "$STUBDIR"
  cp "$BATS_TEST_DIRNAME/helpers/cmux-stub" "$STUBDIR/cmux"
  chmod +x "$STUBDIR/cmux"
  export SIB_EXTRA_PATH="$STUBDIR"
  export CMUX_STUB_LOG="$BATS_TEST_TMPDIR/cmux.log"
  : > "$CMUX_STUB_LOG"
  IDLE=$'❯ \n──────────────────────'
  MSG="done-request: a long head the agent folded away ... and the tail end of it"
}

deliver() { run "$DELIVER" --surface surface:5 --workspace workspace:1 -- "$MSG"; }

@test "a folded paste (new placeholder + tail) is submitted (2026-11-18 incident)" {
  export CMUX_STUB_SCREEN="$IDLE" CMUX_STUB_SCREEN_AFTER_SENDS=1 \
    CMUX_STUB_SCREEN2=$'❯ [Pasted text #3]... and the tail end of it\n──────────────────────' \
    CMUX_STUB_SCREEN_AFTER_ENTERS=1 CMUX_STUB_SCREEN3=$'✻ Cooking…\n──────────────────────\n❯ '
  deliver
  [ "$status" -eq 0 ]
  [[ "$output" == *DELIVERED* ]]
}

@test "the whole message folded into one placeholder is submitted" {
  export CMUX_STUB_SCREEN="$IDLE" CMUX_STUB_SCREEN_AFTER_SENDS=1 \
    CMUX_STUB_SCREEN2=$'❯ [Pasted text #3 +2 lines]\n──────────────────────' \
    CMUX_STUB_SCREEN_AFTER_ENTERS=1 CMUX_STUB_SCREEN3=$'✻ Cooking…\n──────────────────────\n❯ '
  deliver
  [ "$status" -eq 0 ]
}

@test "a placeholder already in the box before the send is not proof" {
  export CMUX_STUB_SCREEN=$'❯ [Pasted text #3]... and the tail end of it\n──────────────────────'
  deliver
  [ "$status" -eq 5 ]
  [[ "$output" == *"did not fully appear"* ]]
  ! grep -q "send-key .* enter" "$CMUX_STUB_LOG"
}

@test "an emptied input box confirms a turn that ended before the check" {
  export CMUX_STUB_SCREEN="$IDLE" CMUX_STUB_SCREEN_AFTER_SENDS=1 \
    CMUX_STUB_SCREEN2="❯ $MSG"$'\n──────────────────────' \
    CMUX_STUB_SCREEN_AFTER_ENTERS=1 CMUX_STUB_SCREEN3=$'⏺ OK\n✻ Cooked for 1s · done\n──────────────────────\n❯ \n──────────────────────'
  deliver
  [ "$status" -eq 0 ]
  [ "$(grep -c "send-key .* enter" "$CMUX_STUB_LOG")" -eq 1 ]
}

@test "text still in the box after enter is not a submit" {
  export CMUX_STUB_SCREEN="$IDLE" CMUX_STUB_SCREEN_AFTER_SENDS=1 \
    CMUX_STUB_SCREEN2="❯ $MSG"$'\n──────────────────────'
  deliver
  [ "$status" -eq 5 ]
  [[ "$output" == *"no work signal"* ]]
}
