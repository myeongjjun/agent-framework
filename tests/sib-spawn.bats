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
  # Codex first-turn watch: one look, no wait (tests that need it raise it).
  export SIB_CODEX_TURN_CHECK=0
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

@test "kill records the caller's close (slug, pane id, start dir) for brief audit" {
  run "$SIB" spawn rec-kill --workdir "$WORKDIR"
  [ "$status" -eq 0 ]
  surf="$(sed -n 's/^surface=//p' "$STATE/rec-kill.env")"
  CMUX_STUB_SURFACE="$surf" CMUX_STUB_PANEL_ID="PANE-UUID-1" CMUX_PANEL_ID="CALLER-1" run "$SIB" kill rec-kill
  [ "$status" -eq 0 ]
  run jq -r '[.slug, .panel, .workdir, .by] | join(" ")' "$XDG_DATA_HOME/sib/killed.jsonl"
  [ "$output" = "rec-kill PANE-UUID-1 $WORKDIR CALLER-1" ]
}

@test "kill that fails records no close" {
  run "$SIB" spawn norec-kill
  CMUX_STUB_CLOSE_FAIL=1 run "$SIB" kill norec-kill
  [ "$status" -ne 0 ]
  [ ! -s "$XDG_DATA_HOME/sib/killed.jsonl" ]
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
tab to queue message" CMUX_STUB_SCREEN_AFTER_ENTERS=2 CMUX_STUB_SCREEN3="• Working (1s • esc to interrupt)"
  run "$SIB" spawn queued --codex --workdir "$WORKDIR" --no-report -- "do the thing"
  [ "$status" -eq 0 ]
  # prompt text was placed in the box
  grep -q "cmux send .*do the thing" "$CMUX_STUB_LOG"
  # and an enter was eventually sent (after the bounded queue wait)
  grep -q "cmux send-key .* enter" "$CMUX_STUB_LOG"
}

@test "a codex first turn that fails on the model is reported, not claimed booted (11-25)" {
  # The error replaces the work signal, so the submit check alone would call it unconfirmed.
  export SIB_CODEX_TURN_CHECK=3 CMUX_STUB_SCREEN="›
do the thing" CMUX_STUB_SCREEN_AFTER_ENTERS=2
  export CMUX_STUB_SCREEN3='■ {"detail":"The '"'"'gpt-5.5'"'"' model is not supported when using Codex with a ChatGPT account."}
›'
  run "$SIB" spawn cx-model --codex --workdir "$WORKDIR" --no-report -- "do the thing"
  [ "$status" -eq 7 ]
  [[ "$output" == *"Codex rejected the model"* ]]
  [[ "$output" == *"model is not supported"* ]]
  [[ "$output" != *"[booted]"* ]]
  [ -f "$STATE/cx-model.env" ]                               # the pane stays recorded for sib kill
}

@test "a codex first turn that works is not held up past the watch" {
  export SIB_CODEX_TURN_CHECK=1 CMUX_STUB_SCREEN="›
do the thing" CMUX_STUB_SCREEN_AFTER_ENTERS=2 CMUX_STUB_SCREEN3="• Working (1s • esc to interrupt)"
  run "$SIB" spawn cx-ok --codex --workdir "$WORKDIR" --no-report -- "do the thing"
  [ "$status" -eq 0 ]
  [[ "$output" == *"[booted]"* ]]
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
  touch -t 202001010000 "$STATE"/*.env   # older than list's one-minute grace
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

@test "--model picks the model the same way for claude and codex" {
  run "$SIB" spawn m-claude --model sonnet --workdir "$WORKDIR" --no-report
  [ "$status" -eq 0 ]
  grep -q "exec claude --model sonnet" "$CMUX_STUB_LOG"
  run "$SIB" spawn m-codex --codex --model gpt-x --workdir "$WORKDIR" --no-report
  [ "$status" -eq 0 ]
  grep -q "exec codex --approve-for-me -m gpt-x" "$CMUX_STUB_LOG"
  run "$SIB" spawn m-bad --model 'x;rm' --workdir "$WORKDIR" --no-report
  [ "$status" -ne 0 ]
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

@test "pre-trust works when HOME is reached through a symlink" {
  # macOS default TMPDIR is /var/... → /private/var/...; this reproduces it anywhere.
  trust_setup
  ln -s "$HOME" "$BATS_TEST_TMPDIR/home-link"
  export HOME="$BATS_TEST_TMPDIR/home-link" XDG_CONFIG_HOME="$BATS_TEST_TMPDIR/home-link/.config"
  run "$SIB" spawn tr-link --workdir "$HOME/work/proj"
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

@test "an allowlisted workdir is pre-trusted for codex in its config.toml, once" {
  trust_setup
  mkdir -p "$HOME/.codex"; printf 'model = "m"\n' > "$HOME/.codex/config.toml"
  unset CODEX_HOME
  d="$(cd "$HOME/work/proj" && pwd -P)"
  run "$SIB" spawn tr-cx --codex --workdir "$HOME/work/proj"
  [ "$status" -eq 0 ]
  [[ "$output" == *"pre-trusted"* ]]
  grep -qxF "[projects.\"$d\"]" "$HOME/.codex/config.toml"
  grep -qx 'model = "m"' "$HOME/.codex/config.toml"
  python3 -c 'import sys,tomllib; c=tomllib.load(open(sys.argv[1],"rb")); assert c["projects"][sys.argv[2]]["trust_level"]=="trusted"' "$HOME/.codex/config.toml" "$d"
  run "$SIB" spawn tr-cx2 --codex --workdir "$HOME/work/proj"
  [ "$(grep -cF "[projects.\"$d\"]" "$HOME/.codex/config.toml")" -eq 1 ]
}

@test "codex: a dir outside the allowlist, or one the user marked untrusted, is not changed" {
  trust_setup
  mkdir -p "$HOME/.codex"
  d="$(cd "$HOME/work/proj" && pwd -P)"
  printf '[projects."%s"]\ntrust_level = "untrusted"\n' "$d" > "$HOME/.codex/config.toml"
  cp "$HOME/.codex/config.toml" "$HOME/before.toml"
  run "$SIB" spawn tr-cx3 --codex --workdir "$HOME/work/proj"
  run "$SIB" spawn tr-cx4 --codex --workdir "$HOME/other"
  cmp "$HOME/.codex/config.toml" "$HOME/before.toml"
}

@test "a codex pane stuck at its trust screen is reported, not claimed ready" {
  trust_setup
  export CMUX_STUB_SCREEN="  Trust this folder? Codex can read, edit, and run files here
› 1. Trust and continue
  2. Open restricted"
  run "$SIB" spawn tr-cx-stuck --codex --workdir "$HOME/other" -- "do the thing"
  [ "$status" -eq 6 ]
  [[ "$output" == *"Codex's trust-folder dialog"* ]]
  ! grep -q "cmux send .*do the thing" "$CMUX_STUB_LOG"
}

@test "sib trusted answers from the allowlist and writes nothing" {
  trust_setup
  cp "$HOME/.claude.json" "$HOME/before.json"
  run "$SIB" trusted "$HOME/work/new-room"            # need not exist yet
  [ "$status" -eq 0 ]
  run "$SIB" trusted "$HOME/other"
  [ "$status" -eq 1 ]
  run "$SIB" trusted /private/tmp/agent-scout/x        # outside HOME: never
  [ "$status" -eq 1 ]
  cmp "$HOME/.claude.json" "$HOME/before.json"
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

# --- folded input box + placeholder + split failure (11-23 incident) ---------
# ~12 of 30 desk spawns exited 5 although the whole prompt sat in the box:
# claude scrolled the tall box ('─── ↑ 2 more ───' on its top rule) so the
# head was off screen. Screens below are shaped on the captured ones.

@test "a folded input box ('↑ N more') with the tail visible is submitted" {
  export CMUX_STUB_SCREEN="$BOOT_SCREEN" CMUX_STUB_SCREEN_AFTER_SENDS=2 \
    CMUX_STUB_SCREEN2=$'─── ↑ 2 more ──────────────\n  folded away and the tail\n  end of it\n──────────────────────\n  ⏵⏵ auto mode on' \
    CMUX_STUB_SCREEN_AFTER_ENTERS=2 CMUX_STUB_SCREEN3=$'✢ Orbiting… (6s)\n──────────────────────\n❯ '
  run "$SIB" spawn fold-box --workdir "$WORKDIR" --no-report -- "a long head that the agent folded away and the tail end of it"
  [ "$status" -eq 0 ]
  [ "$(grep -c "cmux send-key .* enter" "$CMUX_STUB_LOG")" -eq 2 ]
}

@test "a folded input box whose tail is missing is still not submitted" {
  export CMUX_STUB_SCREEN="$BOOT_SCREEN" CMUX_STUB_SCREEN_AFTER_SENDS=2 \
    CMUX_STUB_SCREEN2=$'─── ↑ 2 more ──────────────\n  folded away and the ta\n──────────────────────'
  run "$SIB" spawn fold-cut --workdir "$WORKDIR" --no-report -- "a long head that the agent folded away and the tail end of it"
  [ "$status" -eq 5 ]
  [[ "$output" == *"tail missing"*"box folded"* ]]
  [ "$(grep -c "cmux send-key .* enter" "$CMUX_STUB_LOG")" -eq 1 ]
}

@test "a head typed out and a tail folded into '[Pasted text #1]' is submitted" {
  # Captured live: the first chunk is drawn, the rest folds at the box end.
  export CMUX_STUB_SCREEN="$BOOT_SCREEN" CMUX_STUB_SCREEN_AFTER_SENDS=2 \
    CMUX_STUB_SCREEN2=$'❯ a long head that the agent folded\n  aw[Pasted text #1]\n──────────────────────\n  paste again to expand' \
    CMUX_STUB_SCREEN_AFTER_ENTERS=2 CMUX_STUB_SCREEN3=$'✻ Cooking…\n──────────────────────\n❯ '
  run "$SIB" spawn fold-paste --workdir "$WORKDIR" --no-report -- "a long head that the agent folded away and the tail end of it"
  [ "$status" -eq 0 ]
  [ "$(grep -c "cmux send-key .* enter" "$CMUX_STUB_LOG")" -eq 2 ]
}

@test "a prompt that never lands says what was seen" {
  export CMUX_STUB_SCREEN="$BOOT_SCREEN"
  run "$SIB" spawn never-landed --workdir "$WORKDIR" --no-report -- "a prompt that the agent never drew"
  [ "$status" -eq 5 ]
  [[ "$output" == *"head missing, tail missing"* ]]
}

@test "a workspace that cannot split again fails with the reason" {
  export CMUX_STUB_SPLIT_FAIL="Error: not enough space to split"
  run "$SIB" spawn no-room --workspace workspace:5 --workdir "$WORKDIR"
  [ "$status" -eq 1 ]
  [[ "$output" == *"not enough space to split"* ]]
  [[ "$output" == *"cannot add a pane to workspace workspace:5"* ]]
  [ ! -f "$STATE/no-room.env" ]
  run "$SIB" spawn no-room-def --workdir "$WORKDIR"
  [ "$status" -eq 1 ]
  [[ "$output" == *"cannot add a pane to workspace workspace:1"* ]]
}

# --- one deliverer (docs/agent-control-one-path.md §5 step 3, 11-23) ----------
# The first prompt goes through pane-deliver.sh, the same deliverer as
# `sib send` and `brief send`.

@test "the first prompt goes through pane-deliver, inline (no file pointer)" {
  export XDG_DATA_HOME="$BATS_TEST_TMPDIR/xdg" CMUX_STUB_SCREEN="$BOOT_SCREEN" CMUX_STUB_SCREEN_AFTER_SENDS=2 \
    CMUX_STUB_SCREEN2=@echo CMUX_STUB_SCREEN_AFTER_ENTERS=2 CMUX_STUB_SCREEN3=$'✻ Cooking…\n──────────────────────\n❯ '
  long="$(printf 'a long task sentence %.0s' $(seq 1 30))and its end"
  run "$SIB" spawn inline-long --workdir "$WORKDIR" --no-report -- "$long"
  [ "$status" -eq 0 ]
  [ "$(cat "$CMUX_STUB_LOG.last")" = "$long" ]
  [ ! -d "$XDG_DATA_HOME/pane-msg" ]
}

@test "a prompt whose last chunk follows '[Pasted text #1]' is submitted (11-23 exit 5)" {
  export CMUX_STUB_SCREEN="$BOOT_SCREEN" CMUX_STUB_SCREEN_AFTER_SENDS=2 \
    CMUX_STUB_SCREEN2=$'❯ a long head that the agent folded\n  i[Pasted text #1].\n──────────────────────\n  ⚡Opus 5.5' \
    CMUX_STUB_SCREEN_AFTER_ENTERS=2 CMUX_STUB_SCREEN3=$'✻ Cooking…\n──────────────────────\n❯ '
  run "$SIB" spawn paste-dot --workdir "$WORKDIR" --no-report -- "a long head that the agent folded away and closes it."
  [ "$status" -eq 0 ]
  [ "$(grep -c "cmux send-key .* enter" "$CMUX_STUB_LOG")" -eq 2 ]
}

@test "a prompt in a 4-column pane (head wrapped away, no fold marker) is submitted (11-23)" {
  export CMUX_STUB_SCREEN="$BOOT_SCREEN" CMUX_STUB_SCREEN_AFTER_SENDS=2 \
    CMUX_STUB_SCREEN2=$'  ay\n  an\n  d \n  th\n  e \n  ta\n  il\n  en\n  d \n  of\n  it\n────' \
    CMUX_STUB_SCREEN_AFTER_ENTERS=2 CMUX_STUB_SCREEN3=$'  ✻\n────\n❯\xc2\xa0\n────'
  run "$SIB" spawn narrow --workdir "$WORKDIR" --no-report -- "a long head that the agent folded away and the tail end of it"
  [ "$status" -eq 0 ]
  [ "$(grep -c "cmux send-key .* enter" "$CMUX_STUB_LOG")" -eq 2 ]
}

@test "sib send has no second path: it fails without pane-deliver instead of a plain send" {
  sib_copy="$BATS_TEST_TMPDIR/bin/sib"; mkdir -p "$(dirname "$sib_copy")"; cp "$SIB" "$sib_copy"
  export HOME="$BATS_TEST_TMPDIR/home"; mkdir -p "$HOME" "$STATE"
  printf 'slug=x\nagent=claude\nsurface=surface:5\nworkspace=workspace:1\nworktree=/x\n' > "$STATE/x.env"
  run "$sib_copy" send x "hello"
  [ "$status" -ne 0 ]
  [[ "$output" == *"pane-deliver.sh not found"* ]]
  ! grep -q "^cmux send " "$CMUX_STUB_LOG"
}

# --- no silent exit (11-23/11-24: "sib spawn failed (exit 1, no output)") ----
# Under `set -euo pipefail` a `x="$(cmux ... 2>/dev/null | grep ... | head -1)"`
# that finds nothing ended the spawn with exit 1 and nothing on stderr, and a
# --new-workspace spawn left its empty workspace behind. Every failure now
# says why, and a spawn that fails before its agent is launched closes the
# workspace or pane it created.

@test "a new workspace whose surface lookup fails says why and is closed (11-24 silent exit 1)" {
  export CMUX_STUB_FAIL_LIST_PANE_SURFACES="not_found: Pane or workspace not found" CMUX_STUB_WS="workspace:42"
  run "$SIB" spawn nw-nosurf --workdir "$WORKDIR" --new-workspace --no-report -- "task"
  [ "$status" -ne 0 ]
  [[ "$output" == *"sib:"* ]]
  [[ "$output" == *"not_found: Pane or workspace not found"* ]]
  grep -q "cmux close-workspace --workspace workspace:42" "$CMUX_STUB_LOG"
  [ ! -f "$STATE/nw-nosurf.env" ]
}

@test "a surface lookup that fails once is retried, not fatal" {
  export CMUX_STUB_FAIL_LIST_PANE_SURFACES="not_found: Pane or workspace not found" CMUX_STUB_FAIL_LIST_PANE_SURFACES_TIMES=2
  run "$SIB" spawn nw-retry --workdir "$WORKDIR" --new-workspace --no-report -- "task"
  [ "$status" -eq 0 ]
  ! grep -q "close-workspace" "$CMUX_STUB_LOG"
  [ -f "$STATE/nw-retry.env" ]
}

@test "a new-workspace answer without a workspace ref says why" {
  export CMUX_STUB_OUT_NEW_WORKSPACE="OK"
  run "$SIB" spawn nw-noref --workdir "$WORKDIR" --new-workspace
  [ "$status" -ne 0 ]
  [[ "$output" == *"sib: failed to create workspace"* ]]
}

@test "a split answer without a surface ref says why" {
  export CMUX_STUB_OUT_NEW_SPLIT="OK" CMUX_STUB_OUT_NEW_PANE="OK"
  run "$SIB" spawn sp-noref --workspace workspace:5 --workdir "$WORKDIR"
  [ "$status" -ne 0 ]
  [[ "$output" == *"cannot add a pane to workspace workspace:5"* ]]
  run "$SIB" spawn np-noref --workdir "$WORKDIR"
  [ "$status" -ne 0 ]
  [[ "$output" == *"cannot add a pane to workspace workspace:1"* ]]
}

@test "--workspace whose cwd cannot be read falls back to the caller's dir" {
  export CMUX_STUB_FAIL_SIDEBAR_STATE="broken pipe"
  cd "$WORKDIR"
  run "$SIB" spawn ws-nocwd --workspace workspace:5
  [ "$status" -eq 0 ]
  grep -qx "workdir=$WORKDIR" "$STATE/ws-nocwd.env"
}

@test "a launch that cmux refuses says why and closes the new pane" {
  export CMUX_STUB_FAIL_SEND="surface not ready" CMUX_STUB_SURFACE="surface:91"
  run "$SIB" spawn launch-fail --workspace workspace:5 --workdir "$WORKDIR"
  [ "$status" -ne 0 ]
  [[ "$output" == *"surface not ready"* ]]
  [[ "$output" == *"sib:"* ]]
  grep -q "cmux close-surface --surface surface:91" "$CMUX_STUB_LOG"
  [ ! -f "$STATE/launch-fail.env" ]
}

@test "a launch that cmux refuses in a new workspace closes that workspace" {
  export CMUX_STUB_FAIL_SEND="surface not ready" CMUX_STUB_WS="workspace:42"
  run "$SIB" spawn launch-fail-nw --workdir "$WORKDIR" --new-workspace
  [ "$status" -ne 0 ]
  [[ "$output" == *"surface not ready"* ]]
  grep -q "cmux close-workspace --workspace workspace:42" "$CMUX_STUB_LOG"
}

@test "a spawn run detached (stdin closed, backgrounded) still starts" {
  ( "$SIB" spawn detached --workdir "$WORKDIR" --new-workspace --no-report -- "task" </dev/null >"$BATS_TEST_TMPDIR/d.out" 2>&1; echo "rc=$?" >>"$BATS_TEST_TMPDIR/d.out" ) &
  wait
  grep -q "rc=0" "$BATS_TEST_TMPDIR/d.out"
  [ -f "$STATE/detached.env" ]
}

@test "sib list does not prune a state file a spawn wrote moments ago" {
  mkdir -p "$STATE"
  printf 'slug=fresh\nagent=claude\nsurface=surface:5\nworkspace=workspace:1\nworktree=/x\n' > "$STATE/fresh.env"
  touch "$CMUX_STUB_LOG.closed-surface:5"   # read-screen says the pane is gone
  run "$SIB" list
  [ "$status" -eq 0 ]
  [ -f "$STATE/fresh.env" ]
}

# --- Codex start screens (11-24: update screen ate committee prompts) --------

# Screens as Codex 0.170 / 0.172 draws them (update screen captured 11-24).
CODEX_UPDATE_SCREEN='  Update available · 0.170.0 → 0.172.0
  Release notes: https://github.com/openai/codex/releases/latest
› 1. Update now (runs `brew upgrade --cask codex`)
  2. Skip
  3. Skip until next version
  enter continue · esc skip'
CODEX_HOOKS_SCREEN='  Hooks need review
  2 hooks need review before they can run.
  Hooks can run outside the sandbox after you trust them.
› 1. Review hooks
  2. Trust all and continue
  3. Continue without trusting (hooks won'"'"'t run)'

# Every keystroke sib sent after the launch line ('cd … && exec codex' + its enter).
keys_after_launch() { grep -E "^cmux (send|send-key) " "$CMUX_STUB_LOG" | grep -v "exec codex" | sed 1d; }

@test "spawn --codex at the update screen sends no key, names the screen, keeps the pane" {
  export CMUX_STUB_SCREEN="$CODEX_UPDATE_SCREEN"
  run "$SIB" spawn upd --codex --workdir "$WORKDIR" -- "do the thing"
  [ "$status" -eq 6 ]
  [[ "$output" == *"Codex's update screen"* ]]
  [[ "$output" == *"no key was sent"* ]]
  [ -z "$(keys_after_launch)" ]
  ! grep -q "cmux close-" "$CMUX_STUB_LOG"
  [ -f "$STATE/upd.env" ]
}

@test "spawn --codex at the hooks-review screen sends no key and names the screen" {
  export CMUX_STUB_SCREEN="$CODEX_HOOKS_SCREEN"
  run "$SIB" spawn hooks --codex --workdir "$WORKDIR" -- "do the thing"
  [ "$status" -eq 6 ]
  [[ "$output" == *"Codex's hooks-review screen"* ]]
  [ -z "$(keys_after_launch)" ]
  [ -f "$STATE/hooks.env" ]
}

@test "an empty spawn --codex at the update screen is not reported as booted (research-codex, 11-24)" {
  export CMUX_STUB_SCREEN="$CODEX_UPDATE_SCREEN"
  run "$SIB" spawn upd-empty --codex --workdir "$WORKDIR"
  [ "$status" -eq 6 ]
  [[ "$output" != *"[booted]"* ]]
  [[ "$output" == *"update screen"* ]]
  [ -z "$(keys_after_launch)" ]
}

@test "sib send to a codex pane at a start screen sends no key and prints why" {
  for scr in "$CODEX_UPDATE_SCREEN" "$CODEX_HOOKS_SCREEN"; do
    mkdir -p "$STATE"
    printf 'slug=cx\nagent=codex\nsurface=surface:77\nworkspace=workspace:1\nworktree=%s\n' "$WORKDIR" > "$STATE/cx.env"
    : > "$CMUX_STUB_LOG"
    CMUX_STUB_SCREEN="$scr" run "$SIB" send cx "hello there"
    [ "$status" -eq 3 ]
    [[ "$output" == *"REFUSED"*"Codex's"*"screen"*"no key was sent"* ]]
    ! grep -qE "^cmux (send|send-key) " "$CMUX_STUB_LOG"
  done
}

@test "a codex option list (› 2. Skip) is not taken for the input box" {
  # A numbered '› N. …' line is an option list; a plain '›' line is the input box.
  export CMUX_STUB_SCREEN="› 2. Skip"
  run "$SIB" spawn optlist --codex --workdir "$WORKDIR" -- "do the thing"
  [ "$status" -eq 5 ]
  [[ "$output" == *"input box never appeared"* ]]
}
