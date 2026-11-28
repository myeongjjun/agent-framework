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
  [[ "$output" == *"did not fully appear"* ]] || false
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

@test "a long message goes to a file; the pane gets one line with its head and path (11-20, 11-21)" {
  export XDG_DATA_HOME="$BATS_TEST_TMPDIR/data"
  MSG="done-request: $(printf 'padding words to make it long %.0s' $(seq 1 20))the very end"
  export CMUX_STUB_SCREEN="$IDLE" CMUX_STUB_SCREEN_AFTER_SENDS=1 CMUX_STUB_SCREEN2=@echo \
    CMUX_STUB_SCREEN_AFTER_ENTERS=1 CMUX_STUB_SCREEN3=$'✻ Cooking…\n──────────────────────\n❯ '
  deliver
  [ "$status" -eq 0 ]
  f="$(sed -n 's/^FILE: //p' <<<"$output")"
  [ "$(cat "$f")" = "$MSG" ]
  typed="$(cat "$CMUX_STUB_LOG.last")"
  [[ "$typed" == "done-request: padding"*"read $f and act on it" ]] || false
  (( ${#typed} < ${#MSG} ))
}

@test "a box scrolled past its head ('↑ N more') counts as landed when the tail is there" {
  export CMUX_STUB_SCREEN="$IDLE" CMUX_STUB_SCREEN_AFTER_SENDS=1 \
    CMUX_STUB_SCREEN2=$' ↑ 7 more ─\n  away ...\n  and the\n  tail end\n  of it\n────────' \
    CMUX_STUB_SCREEN_AFTER_ENTERS=1 CMUX_STUB_SCREEN3=$'⏺ OK\n────────\n❯ \n────────'
  deliver
  [ "$status" -eq 0 ]
}

@test "a message that never fully lands is cleared from the box, not left half-sent" {
  export CMUX_STUB_SCREEN="$IDLE" CMUX_STUB_SCREEN_AFTER_SENDS=1 \
    CMUX_STUB_SCREEN2=$'❯ done-request: a long head the agent\n──────────────────────' \
    CMUX_STUB_SCREEN_AFTER_ESCAPES=2 CMUX_STUB_SCREEN4="$IDLE"
  deliver
  [ "$status" -eq 5 ]
  [[ "$output" == *"typed text cleared"* ]] || false
  [ "$(grep -c "send-key .* escape" "$CMUX_STUB_LOG")" -eq 2 ]
  ! grep -q "send-key .* enter" "$CMUX_STUB_LOG"
}

@test "a spinner wrapped by a narrow pane still counts as busy" {
  export CMUX_STUB_SCREEN=$'· Hullaba\nllooing… \n────────────\n❯ \n────────────'
  deliver
  [ "$status" -eq 4 ]
  ! grep -q "^cmux send " "$CMUX_STUB_LOG"
}

@test "an unsent earlier message of ours in the box is cleared and the send retried (11-23 holds text)" {
  export CMUX_STUB_SEND_HOLDS=1 \
    CMUX_STUB_SCREEN=$'❯ done-request: an old request from a desk\n  that has since closed\n──────────────────────' \
    CMUX_STUB_SCREEN_AFTER_ESCAPES=2 CMUX_STUB_SCREEN4=@echo \
    CMUX_STUB_SCREEN_AFTER_ENTERS=1 CMUX_STUB_SCREEN3=$'✻ Cooking…\n──────────────────────\n❯ '
  run "$DELIVER" --surface surface:5 --workspace workspace:1 --ours done-request: --ours desk-message: -- "$MSG"
  [ "$status" -eq 0 ]
  [[ "$output" == *CLEARED* && "$output" == *DELIVERED* ]] || false
  [ "$(grep -c "send-key .* escape" "$CMUX_STUB_LOG")" -eq 2 ]
  [ "$(cat "$CMUX_STUB_LOG.last")" = "$MSG" ]
}

@test "text in the box that is not ours is left alone and the send refused (exit 7)" {
  export CMUX_STUB_SEND_HOLDS=1 CMUX_STUB_SCREEN=$'❯ my own half-typed thought\n──────────────────────'
  run "$DELIVER" --surface surface:5 --workspace workspace:1 --ours done-request: -- "$MSG"
  [ "$status" -eq 7 ]
  [[ "$output" == *"not ours: myownhalf-typedthought"* ]] || false
  ! grep -q "send-key" "$CMUX_STUB_LOG"
}

# --- one deliverer: the two 11-23 screens -------------------------------------
# sib spawn exited 5 on '…i[Pasted text #1].': the last chunk ('.') was typed
# after the folded one, so the tail was neither drawn nor right before the rule.
@test "a placeholder followed by the message's last chunk is submitted (11-23 '[Pasted text #1].')" {
  MSG="do the task. --- completion contract (from sib) --- the desk checks the report against reality and closes it."
  export PANE_DELIVER_INLINE_MAX=100000 CMUX_STUB_SCREEN="$IDLE" CMUX_STUB_SCREEN_AFTER_SENDS=1 \
    CMUX_STUB_SCREEN2=$'❯ do the task. --- completion contract (from sib) --- the desk\n  i[Pasted text #1].\n──────────────────────\n  ⚡Opus 5.5' \
    CMUX_STUB_SCREEN_AFTER_ENTERS=1 CMUX_STUB_SCREEN3=$'✻ Cooking…\n──────────────────────\n❯ '
  deliver
  [ "$status" -eq 0 ]
  [[ "$output" == *DELIVERED* ]]
}

@test "a placeholder followed by text that is not the message's end is not proof" {
  export CMUX_STUB_SCREEN="$IDLE" CMUX_STUB_SCREEN_AFTER_SENDS=1 \
    CMUX_STUB_SCREEN2=$'❯ [Pasted text #1] something else\n──────────────────────'
  deliver
  [ "$status" -eq 5 ]
  ! grep -q "send-key .* enter" "$CMUX_STUB_LOG"
}

# 11-23 live screen: a pane 4 columns wide wraps the box at 2 characters a
# line; the head scrolls away and no '↑ N more' marker fits on the rule.
NARROW=$'  ma\n  in\n  d \n  of\n  it\n────\n❯ \n────'
narrow_box() { printf '%s' "$1" | tr -d ' ' | fold -w 2 | sed 's/^/  /'; }

@test "a 4-column pane whose head scrolled away (no fold marker) is submitted (11-23)" {
  export CMUX_STUB_SCREEN="$NARROW" CMUX_STUB_SCREEN_AFTER_SENDS=1 \
    CMUX_STUB_SCREEN2="$(narrow_box "${MSG: -40}")"$'\n────' \
    CMUX_STUB_SCREEN_AFTER_ENTERS=1 CMUX_STUB_SCREEN3=$'  ✻\n  Co\n  ok\n────\n❯ \n────'
  deliver
  [ "$status" -eq 0 ]
  [[ "$output" == *DELIVERED* ]]
}

@test "a tail that was already on screen before the send is not proof" {
  export CMUX_STUB_SCREEN="$(narrow_box "${MSG: -40}")"$'\n────'
  deliver
  [ "$status" -eq 5 ]
  [[ "$output" == *"tail seen (already on screen before the send)"*"pane 4 columns wide"* ]] || false
  ! grep -q "send-key .* enter" "$CMUX_STUB_LOG"
}

@test "text in but a codex queue notice that never clears still submits" {
  export CMUX_STUB_SCREEN=$'›' CMUX_STUB_SCREEN_AFTER_SENDS=1 \
    CMUX_STUB_SCREEN2="› $MSG"$'\ntab to queue message' \
    CMUX_STUB_SCREEN_AFTER_ENTERS=1 CMUX_STUB_SCREEN3=$'• Working (1s • esc to interrupt)'
  deliver
  [ "$status" -eq 0 ]
  [[ "$output" == *DELIVERED* ]]
}
