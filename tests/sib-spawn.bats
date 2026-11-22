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
  export CMUX_STUB_WS_CWD="$WORKDIR"
  run "$SIB" spawn ws-test --workspace workspace:5
  [ "$status" -eq 0 ]
  grep -q "cmux new-split right --workspace workspace:5" "$CMUX_STUB_LOG"
  # must NOT split the caller's workspace
  ! grep -q "cmux new-pane" "$CMUX_STUB_LOG"
  grep -qx "workspace=workspace:5" "$STATE/ws-test.env"
}

@test "--workspace without --workdir adopts the target workspace's cwd" {
  # Regression: pane went to W but the agent started in the caller's PWD.
  # sib must read W's cwd (sidebar-state) and start the agent there.
  export CMUX_STUB_WS_CWD="$WORKDIR"
  run "$SIB" spawn ws-cwd --workspace workspace:5
  [ "$status" -eq 0 ]
  grep -q "cmux sidebar-state --workspace workspace:5" "$CMUX_STUB_LOG"
  grep -q "cmux send .* cd .*$WORKDIR && exec claude" "$CMUX_STUB_LOG"
  grep -qx "workdir=$WORKDIR" "$STATE/ws-cwd.env"
}

@test "--workspace with explicit --workdir keeps the explicit dir" {
  # explicit --workdir must win over the target workspace's cwd
  OTHER="$BATS_TEST_TMPDIR/explicit"; mkdir -p "$OTHER"
  export CMUX_STUB_WS_CWD="$WORKDIR"
  run "$SIB" spawn ws-explicit --workspace workspace:5 --workdir "$OTHER"
  [ "$status" -eq 0 ]
  grep -qx "workdir=$OTHER" "$STATE/ws-explicit.env"
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

@test "kill that cannot close the pane fails and keeps the state file" {
  run "$SIB" spawn stuck-kill
  [ "$status" -eq 0 ]
  CMUX_STUB_CLOSE_FAIL=1 run "$SIB" kill stuck-kill
  [ "$status" -ne 0 ]
  [[ "$output" == *"still open"* ]]
  [[ "$output" != *"killed"* ]]
  [ -f "$STATE/stuck-kill.env" ]
  # the forced retry was attempted
  grep -qE "cmux close-surface .*--force( |$)" "$CMUX_STUB_LOG"
}

@test "kill force-closes a live sibling with a bare --force (pane and workspace)" {
  run "$SIB" spawn live-pane
  [ "$status" -eq 0 ]
  CMUX_STUB_CLOSE_LIVE=1 run "$SIB" kill live-pane
  [ "$status" -eq 0 ]
  [[ "$output" == *"killed live-pane"* ]]
  CMUX_STUB_WS="workspace:42" run "$SIB" spawn live-ws --workdir "$WORKDIR" --new-workspace
  [ "$status" -eq 0 ]
  CMUX_STUB_CLOSE_LIVE=1 run "$SIB" kill live-ws
  [ "$status" -eq 0 ]
  [[ "$output" == *"killed live-ws"* ]]
  ! grep -q -- "--force true" "$CMUX_STUB_LOG"
}

# --- prompt submission (cmux-cli-reference §9) ------------------------------

@test "prompt is sent as text BEFORE its submit enter (not after)" {
  # Put text in the box, then submit. If enter preceded the text send, the
  # agent would submit an empty line and drop the task. (Note: the launch
  # 'cd && exec' line has its own earlier enter — we check the PROMPT send is
  # followed by an enter, i.e. there is an enter AFTER the prompt send line.)
  export CMUX_STUB_PROMPT_ECHO="do the thing"
  run "$SIB" spawn submit-order --workdir "$WORKDIR" --no-report -- "do the thing"
  [ "$status" -eq 0 ]
  send_line=$(grep -n "cmux send .*do the thing" "$CMUX_STUB_LOG" | head -1 | cut -d: -f1)
  last_enter=$(grep -n "cmux send-key .* enter" "$CMUX_STUB_LOG" | tail -1 | cut -d: -f1)
  [ -n "$send_line" ] && [ -n "$last_enter" ]
  # the submit enter comes after the prompt text was placed
  [ "$last_enter" -gt "$send_line" ]
}

@test "submission waits out a codex queue notice before enter" {
  # Simulate a pane stuck on 'tab to queue message': sib must NOT have given up
  # without ever sending enter. (Loop is bounded, so it still proceeds.)
  # (static stub screen: the trailing work signal lets the submit confirm.)
  export CMUX_STUB_SCREEN="›
do the thing
tab to queue message
working"
  run "$SIB" spawn queued --codex --workdir "$WORKDIR" --no-report -- "do the thing"
  [ "$status" -eq 0 ]
  # prompt text was placed in the box
  grep -q "cmux send .*do the thing" "$CMUX_STUB_LOG"
  # and an enter was eventually sent (after the bounded queue wait)
  grep -q "cmux send-key .* enter" "$CMUX_STUB_LOG"
}

@test "no prompt → only the launch enter, no prompt-submit enter" {
  run "$SIB" spawn no-prompt --workdir "$WORKDIR"
  [ "$status" -eq 0 ]
  # the launch 'cd && exec' line gets exactly one enter; with no prompt there
  # must be no second (submit) enter.
  enters=$(grep -c "cmux send-key .* enter" "$CMUX_STUB_LOG")
  [ "$enters" -eq 1 ]
}

# --- boot detection + truncation (2026-10-29 incident) ----------------------

@test "a shell prompt using the same glyph does not count as booted" {
  # starship's default prompt ends in '❯'. Typing the task into the shell
  # before claude takes the pty truncates it at MAX_CANON (1024 bytes).
  export CMUX_STUB_SCREEN="host  repo  main ❯ cd /x && exec claude"
  run "$SIB" spawn shell-glyph --workdir "$WORKDIR" --no-report -- "do the thing"
  [ "$status" -eq 5 ]
  [[ "$output" == *"input box never appeared"* ]]
  # the prompt was never typed
  ! grep -q "cmux send .*do the thing" "$CMUX_STUB_LOG"
}

@test "a prompt whose tail never shows up is not submitted" {
  export CMUX_STUB_SCREEN="❯ do the thing and then
──────────────────────"
  run "$SIB" spawn truncated --workdir "$WORKDIR" --no-report -- "do the thing and then a long tail that got cut off"
  [ "$status" -eq 5 ]
  [[ "$output" == *"did not fully appear"* ]]
  # only the launch enter — no submit enter for a partial prompt
  enters=$(grep -c "cmux send-key .* enter" "$CMUX_STUB_LOG")
  [ "$enters" -eq 1 ]
}

@test "newlines in the prompt are flattened (cmux send treats \\n as enter)" {
  export CMUX_STUB_PROMPT_ECHO="line one line two"
  run "$SIB" spawn multiline --workdir "$WORKDIR" --no-report -- "line one
line two"
  [ "$status" -eq 0 ]
  grep -q "cmux send .*line one line two" "$CMUX_STUB_LOG"
}

# --- slug validation + dead-state pruning ------------------------------------

@test "a slug starting with '-' is rejected before any state is written" {
  run "$SIB" spawn -x
  [ "$status" -ne 0 ]
  [[ "$output" == *"lowercase-kebab"* ]]
  [ ! -f "$STATE/-x.env" ]
}

@test "spawn reuses a slug whose old pane is gone (no worktree)" {
  run "$SIB" spawn reuse-me
  [ "$status" -eq 0 ]
  touch "${CMUX_STUB_LOG}.closed-surface:90"   # the old pane was closed outside sib
  CMUX_STUB_SURFACE="surface:93" run "$SIB" spawn reuse-me
  [ "$status" -eq 0 ]
  grep -qx "surface=surface:93" "$STATE/reuse-me.env"
}

@test "spawn still refuses a slug whose pane is alive" {
  run "$SIB" spawn live-one
  [ "$status" -eq 0 ]
  run "$SIB" spawn live-one
  [ "$status" -ne 0 ]
  [[ "$output" == *"already exists"* ]]
}

@test "list prunes dead non-worktree state but keeps worktree-managed state" {
  mkdir -p "$STATE"
  printf 'slug=gone\nagent=claude\nsurface=surface:70\nworkspace=workspace:1\nworktree=/x\nworktree_managed=0\n' > "$STATE/gone.env"
  printf 'slug=wt\nagent=codex\nsurface=surface:71\nworkspace=workspace:1\nworktree=/y\nworktree_managed=1\n' > "$STATE/wt.env"
  printf 'slug=up\nagent=claude\nsurface=surface:72\nworkspace=workspace:1\nworktree=/z\nworktree_managed=0\n' > "$STATE/up.env"
  touch "${CMUX_STUB_LOG}.closed-surface:70" "${CMUX_STUB_LOG}.closed-surface:71"
  run "$SIB" list
  [ "$status" -eq 0 ]
  [ ! -f "$STATE/gone.env" ]
  [ -f "$STATE/wt.env" ]
  [ -f "$STATE/up.env" ]
  [[ "$output" == *"wt "*"(dead)"* ]]
}

# --- completion contract (default on) ---------------------------------------

# A screen that shows the head and tail of "do the thing" + contract, so the
# landed check passes without waiting out its 30s cap.
CONTRACT_SCREEN=$'❯\n──────────\ndothething---comple … trealityandclosesit.\nworking (esc to interrupt)'

@test "the completion contract is appended by default" {
  CMUX_STUB_SCREEN="$CONTRACT_SCREEN" run "$SIB" spawn rep-on -- "do the thing"
  [ "$status" -eq 0 ]
  grep -q "cmux send .*do the thing.*completion contract.*Done when.*brief note.*done-report" "$CMUX_STUB_LOG"
}

@test "--report is still accepted (no-op, default)" {
  CMUX_STUB_SCREEN="$CONTRACT_SCREEN" run "$SIB" spawn rep-old --report -- "do the thing"
  [ "$status" -eq 0 ]
  grep -q "completion contract" "$CMUX_STUB_LOG"
}

@test "--no-report sends the prompt unchanged" {
  run "$SIB" spawn rep-off --no-report -- "the task prompt"
  [ "$status" -eq 0 ]
  ! grep -q "completion contract" "$CMUX_STUB_LOG"
}

@test "a --worktree sibling (collab worker) gets no contract" {
  git -C "$WORKDIR" init -q && git -C "$WORKDIR" -c user.email=t@t -c user.name=t commit -q --allow-empty -m init
  cd "$WORKDIR"
  run "$SIB" spawn rep-wt --worktree -- "the task prompt"
  [ "$status" -eq 0 ]
  ! grep -q "completion contract" "$CMUX_STUB_LOG"
}

# --- folded paste + fast turn (2026-11-18 incident) --------------------------
# A long prompt arrives in chunks; claude folds a big chunk into
# "[Pasted text #N]", so the head is never drawn. Stage the screens: boot box
# (before the prompt send), folded input (after it), finished turn (after the
# submit enter).
BOOT_SCREEN=$'❯ \n──────────────────────'

@test "a folded paste (new placeholder + tail) counts as landed" {
  export CMUX_STUB_SCREEN="$BOOT_SCREEN" CMUX_STUB_SCREEN_AFTER_SENDS=2 \
    CMUX_STUB_SCREEN2=$'❯ [Pasted text #1]way and the tail end of it\n──────────────────────' \
    CMUX_STUB_SCREEN_AFTER_ENTERS=2 CMUX_STUB_SCREEN3=$'✻ Cooking…\n──────────────────────\n❯ '
  run "$SIB" spawn folded --workdir "$WORKDIR" --no-report -- "a long head that the agent folded away and the tail end of it"
  [ "$status" -eq 0 ]
  [ "$(grep -c "cmux send-key .* enter" "$CMUX_STUB_LOG")" -eq 2 ]
}

@test "a placeholder already on screen before the send proves nothing" {
  export CMUX_STUB_SCREEN=$'❯ [Pasted text #1]way and the tail end of it\n──────────────────────'
  run "$SIB" spawn stale-paste --workdir "$WORKDIR" --no-report -- "a long head that the agent folded away and the tail end of it"
  [ "$status" -eq 5 ]
  [[ "$output" == *"did not fully appear"* ]]
}

@test "an emptied input box confirms a turn that ended before the check" {
  export CMUX_STUB_SCREEN="$BOOT_SCREEN" CMUX_STUB_SCREEN_AFTER_SENDS=2 \
    CMUX_STUB_SCREEN2=$'❯ quick one\n──────────────────────' \
    CMUX_STUB_SCREEN_AFTER_ENTERS=2 CMUX_STUB_SCREEN3=$'⏺ OK\n✻ Cooked for 1s · done\n──────────────────────\n❯ \n──────────────────────'
  run "$SIB" spawn quick --workdir "$WORKDIR" --no-report -- "quick one"
  [ "$status" -eq 0 ]
  # confirmed on the first check: no retry enter
  [ "$(grep -c "cmux send-key .* enter" "$CMUX_STUB_LOG")" -eq 2 ]
}

@test "codex sibling boots with the auto-reviewer, not per-command y/n prompts" {
  run "$SIB" spawn rev --codex --workdir "$WORKDIR" --no-report
  [ "$status" -eq 0 ]
  grep -q "exec codex --approve-for-me" "$CMUX_STUB_LOG"
}

@test "codex --yolo still bypasses sandbox and approvals" {
  run "$SIB" spawn rev-yolo --codex --yolo --workdir "$WORKDIR" --no-report
  [ "$status" -eq 0 ]
  grep -q "exec codex --dangerously-bypass-approvals-and-sandbox" "$CMUX_STUB_LOG"
}

# --- folder-trust pre-acceptance (allowlist) --------------------------------
# HOME is sandboxed so the real ~/.claude.json is never read or written.

trust_setup() {
  export HOME="$BATS_TEST_TMPDIR/home"
  export XDG_CONFIG_HOME="$HOME/.config"
  unset CLAUDE_CONFIG_DIR SIB_TRUST_FILE
  mkdir -p "$HOME/work/proj/deep" "$HOME/other" "$XDG_CONFIG_HOME/sib"
  echo '{"projects":{}}' > "$HOME/.claude.json"
  printf '# comment\n~/work/*\n' > "$XDG_CONFIG_HOME/sib/trusted-dirs"
}
trusted() { jq -e --arg d "$1" '.projects[$d].hasTrustDialogAccepted == true' "$HOME/.claude.json" >/dev/null; }

@test "an allowlisted workdir is pre-trusted before claude launches" {
  trust_setup
  run "$SIB" spawn tr-ok --workdir "$HOME/work/proj"
  [ "$status" -eq 0 ]
  trusted "$(cd "$HOME/work/proj" && pwd -P)"
  [[ "$output" == *"pre-trusted"* ]]
}

@test "a workdir outside the allowlist is left untrusted" {
  trust_setup
  run "$SIB" spawn tr-no --workdir "$HOME/other"
  [ "$status" -eq 0 ]
  ! trusted "$(cd "$HOME/other" && pwd -P)"
}

@test "'*' in the allowlist does not cross a path segment" {
  trust_setup
  run "$SIB" spawn tr-deep --workdir "$HOME/work/proj/deep"
  [ "$status" -eq 0 ]
  ! trusted "$(cd "$HOME/work/proj/deep" && pwd -P)"
}

@test "existing project settings survive pre-trust" {
  trust_setup
  d="$(cd "$HOME/work/proj" && pwd -P)"
  jq --arg d "$d" '.projects[$d] = {allowedTools: ["x"]} | .keep = 1' "$HOME/.claude.json" > "$HOME/c" && mv "$HOME/c" "$HOME/.claude.json"
  run "$SIB" spawn tr-keep --workdir "$HOME/work/proj"
  [ "$status" -eq 0 ]
  trusted "$d"
  jq -e --arg d "$d" '.projects[$d].allowedTools == ["x"] and .keep == 1' "$HOME/.claude.json"
}

@test "codex siblings never touch claude's trust state" {
  trust_setup
  run "$SIB" spawn tr-codex --codex --workdir "$HOME/work/proj"
  ! trusted "$(cd "$HOME/work/proj" && pwd -P)"
}

@test "a pane stuck at the trust dialog is reported, not claimed ready" {
  trust_setup
  export CMUX_STUB_SCREEN="Do you trust the files in this folder?
❯ 1. Yes, I trust this folder"
  run "$SIB" spawn tr-stuck --workdir "$HOME/other" -- "do the thing"
  [ "$status" -eq 6 ]
  [[ "$output" == *"trust-folder dialog"* ]]
  ! grep -q "cmux send .*do the thing" "$CMUX_STUB_LOG"
}

# --- state with spaces / help ------------------------------------------------

@test "a workdir with spaces survives sib list and kill" {
  mkdir -p "$BATS_TEST_TMPDIR/with space"
  run "$SIB" spawn sp --workdir "$BATS_TEST_TMPDIR/with space"
  [ "$status" -eq 0 ]
  run "$SIB" list
  [ "$status" -eq 0 ]
  [[ "$output" == *"with space (up)"* ]]
  run "$SIB" kill sp
  [ "$status" -eq 0 ]
  [ ! -f "$STATE/sp.env" ]
}

@test "sib spawn --help prints usage and spawns nothing" {
  run "$SIB" spawn --help
  [ "$status" -eq 0 ]
  [[ "$output" == *"sib spawn <slug>"* ]]
  [ ! -s "$CMUX_STUB_LOG" ]
  [ -z "$(ls "$STATE")" ]
}
