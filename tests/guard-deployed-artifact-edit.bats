#!/usr/bin/env bats
# guard-deployed-artifact-edit.sh: blocks edits to deployed copies and names
# the owning layer in the message. HOME is sandboxed.

setup() {
  HOOK="${BATS_TEST_DIRNAME}/../hooks/general/guard-deployed-artifact-edit.sh"
  export HOME="$BATS_TEST_TMPDIR/home"
  mkdir -p "$HOME/.claude/hooks" "$HOME/.claude/skills"
  echo x > "$HOME/.claude/hooks/l1.sh"
  echo x > "$HOME/.claude/hooks/l2.sh"
  printf 'deadbeef  %s\n' "$HOME/.claude/hooks/l1.sh" > "$HOME/.claude/.framework-owned"

  # A symlinked skill whose source repo is not agent-framework.
  SRC="$BATS_TEST_TMPDIR/persona-repo"
  mkdir -p "$SRC/skills/foo"
  git init -q "$SRC"
  ln -s "$SRC/skills/foo" "$HOME/.claude/skills/foo"
}

run_hook() {
  printf '{"tool_name":"%s","tool_input":{"file_path":"%s"}}' "$1" "$2" | bash "$HOOK"
}

@test "L1-owned hook copy points at agent-framework + install.sh" {
  run run_hook Edit "$HOME/.claude/hooks/l1.sh"
  [ "$status" -eq 0 ]
  [[ "$output" == *'"decision": "block"'* ]]
  [[ "$output" == *"agent-framework/"*"scripts/install.sh"* ]]
}

@test "unowned hook copy gets layer-neutral advice" {
  run run_hook Write "$HOME/.claude/hooks/l2.sh"
  [[ "$output" == *'"decision": "block"'* ]]
  [[ "$output" == *"another layer"* ]]
  [[ "$output" != *"install.sh"* ]]
}

@test "symlinked skill names its real source" {
  run run_hook Edit "$HOME/.claude/skills/foo/SKILL.md"
  [[ "$output" == *'"decision": "block"'* ]]
  [[ "$output" == *"$(cd -P "$SRC" && pwd)/skills/foo/SKILL.md"* ]]
  [[ "$output" != *"agent-framework/"* ]]
}

@test "non-deployed path and non-edit tools pass" {
  run run_hook Edit "$BATS_TEST_TMPDIR/anything.txt"
  [ "$status" -eq 0 ]; [ -z "$output" ]
  run run_hook Read "$HOME/.claude/hooks/l1.sh"
  [ "$status" -eq 0 ]; [ -z "$output" ]
}
