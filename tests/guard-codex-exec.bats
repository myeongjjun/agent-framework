#!/usr/bin/env bats
# guard-codex-exec.sh blocks headless Codex runs and points to a cmux pane.

setup() {
  HOOK="${BATS_TEST_DIRNAME}/../hooks/general/guard-codex-exec.sh"
}

run_hook() {
  local tool="${2:-Bash}"
  jq -n --arg t "$tool" --arg c "$1" '{tool_name:$t, tool_input:{command:$c}}' | bash "$HOOK"
}

@test "codex exec is blocked and the message names sib spawn --codex" {
  run run_hook 'codex exec -s workspace-write -c model_reasoning_effort=high "draw the office art"'
  [ "$status" -eq 2 ]
  [[ "$output" == *"BLOCKED"* ]] || false
  [[ "$output" == *"sib spawn codex-<slug> --codex"* ]]
}

@test "headless forms are blocked: alias, review, paths, flags, prefixes, pipes, shell strings" {
  for c in \
    'codex e "fix it"' \
    'codex review --uncommitted' \
    '/opt/homebrew/bin/codex exec --json "x"' \
    'npx @openai/codex exec "x"' \
    'codex -c model_reasoning_effort=high exec "x"' \
    'codex --yolo exec "x"' \
    'codex -m gpt-5 -s read-only exec "x"' \
    'cd /tmp && codex exec "x"' \
    'timeout 600 codex exec "x" < /dev/null' \
    'nohup codex exec "x" > out.md 2>&1 &' \
    'printf "%s" "$diff" | codex exec --skip-git-repo-check -' \
    'result=$(codex exec "x")' \
    'bash -c "codex exec hello"' \
    "zsh -lc 'codex exec hello'" \
    "eval 'codex e hello'"; do
    run run_hook "$c"
    [ "$status" -eq 2 ] || { echo "not blocked: $c"; return 1; }
  done
}

@test "Codex's own shell tool name is covered too" {
  run run_hook 'codex exec "x"' shell
  [ "$status" -eq 2 ]
}

@test "pane runs, the TUI, and text that only mentions codex exec pass" {
  for c in \
    'sib spawn office-art --codex -- "draw the office art"' \
    'codex' \
    'codex --approve-for-me' \
    'codex resume --last' \
    'codex login --trust' \
    'codex --version' \
    'git commit -m "remove codex exec fallback"' \
    "grep -rn 'codex exec' skills/" \
    'echo "do not run codex exec"' \
    'ps -o command= | grep codex' \
    'brief tree' \
    'cat ~/.codex/config.toml' \
    'mycodex exec x' \
    'codex-review exec'; do
    run run_hook "$c"
    [ "$status" -eq 0 ] || { echo "blocked wrongly: $c"; return 1; }
  done
}

@test "a multi-line quoted string that mentions codex exec passes" {
  run run_hook $'brief report "done-report: ready\ndid: replaced codex exec with panes\nremaining: none"'
  [ "$status" -eq 0 ]
  run run_hook $'git commit -m "first line\n\ncodex exec is gone"'
  [ "$status" -eq 0 ]
}

@test "other tools are ignored" {
  run run_hook 'codex exec "x"' Edit
  [ "$status" -eq 0 ]
}
