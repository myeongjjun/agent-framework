#!/usr/bin/env bats

setup() {
  HOOK="${BATS_TEST_DIRNAME}/../hooks/general/guard-cherry-pick.sh"
}

run_hook() {
  local command="$1"
  printf '{"tool_name":"Bash","tool_input":{"command":%s}}
' "$(jq -Rn --arg c "$command" '$c')" | bash "$HOOK"
}

@test "git cherry-pick warns" {
  run run_hook "git cherry-pick abc123"

  [ "$status" -eq 1 ]
  [[ "$output" == *"agent-promote.sh <slug>"* ]]
}

@test "cherry-pick recovery operations are allowed" {
  run run_hook "git cherry-pick --abort"
  [ "$status" -eq 0 ]

  run run_hook "git cherry-pick --continue"
  [ "$status" -eq 0 ]

  run run_hook "git cherry-pick --skip"
  [ "$status" -eq 0 ]
}

@test "explicit opt-out is allowed" {
  run run_hook "CHERRY_PICK_OK=1 git cherry-pick abc123"

  [ "$status" -eq 0 ]
}

@test "commit message mentioning cherry-pick is allowed" {
  run run_hook "git commit -m 'document git cherry-pick guard behavior'"

  [ "$status" -eq 0 ]
}
