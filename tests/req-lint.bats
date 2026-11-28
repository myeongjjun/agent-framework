#!/usr/bin/env bats
# req-lint — each test name starts with the requirement ID it checks
# (agent-context/constraints/<stem>.md, row in its "## Trace" table).

setup() {
  LINT="${BATS_TEST_DIRNAME}/../bin/req-lint"
  T="$(mktemp -d)"
}

teardown() {
  rm -rf "$T"
}

lint() {  # lint <stdin text> [args...]
  local text="$1"; shift
  printf '%s\n' "$text" | python3 -I "$LINT" "$@"
}

@test "good requirement sentences pass" {
  run lint "claw MUST NOT write a secret to chat, a log or a file." --subject claw
  [ "$status" -eq 0 ]
  run lint "If claw cannot read \`claw-local.md\`, claw MUST NOT make changes." --subject claw
  [ "$status" -eq 0 ]
  run lint "The agent SHOULD log each step, unless the user turns logging off."
  [ "$status" -eq 0 ]
}

@test "code-style-requirement-sentences.R1 rejects Hangul" {
  run lint "에이전트는 MUST 재시도한다."
  [ "$status" -eq 1 ]
  [[ "$output" == *"write in English"* ]]
}

@test "code-style-requirement-sentences.R2 rejects a sentence without subject + keyword form" {
  run lint "MUST retry."
  [ "$status" -eq 1 ]
  [[ "$output" == *"use the form"* ]] || false
  run lint "agent MUST retry." --subject claw
  [ "$status" -eq 1 ]
}

@test "code-style-requirement-sentences.R3 rejects two keywords in one sentence" {
  run lint "claw MUST ask first and MAY retry."
  [ "$status" -eq 1 ]
  [[ "$output" == *"exactly one RFC 2119 keyword"*"found 2"* ]]
}

@test "code-style-requirement-sentences.R4 rejects SHALL" {
  run lint "claw SHALL retry."
  [ "$status" -eq 1 ]
  [[ "$output" == *"do not use 'SHALL'"* ]]
}

@test "code-style-requirement-sentences.R5 rejects lowercase modals" {
  run lint "claw MUST retry when it should."
  [ "$status" -eq 1 ]
  [[ "$output" == *"lowercase 'should'"* ]]
}

@test "code-style-requirement-sentences.R6 rejects SHOULD without unless/except" {
  run lint "claw SHOULD retry."
  [ "$status" -eq 1 ]
  [[ "$output" == *"SHOULD needs its exception"* ]]
}

@test "code-style-requirement-sentences.R7 rejects more than 20 words, code span is one word" {
  run lint "claw MUST NOT send a message to a chat channel or a person, unless the user asks in the same session."
  [ "$status" -eq 1 ]
  [[ "$output" == *"21 words"* ]] || false
  run lint "claw MUST run \`a b c d e f g h i j k l m n o p q r s t u v\` now."
  [ "$status" -eq 0 ]
}

@test "--md checks only keyword sentences and skips fenced code" {
  printf '# T\n\nThis should be fine as a description.\n\n```\nclaw SHALL x.\n```\n\n- claw SHOULD retry.\n' > "$T/a.md"
  run python3 -I "$LINT" --md "$T/a.md"
  [ "$status" -eq 1 ]
  [[ "$output" == *"a.md:9: SHOULD needs its exception"* ]] || false
  [[ "$output" != *"SHALL"* ]]
}

@test "code-style-skill-language-convention.R1 --lang flags Korean workflow prose" {
  printf '# T\n\n## Workflow\n\n1. 이 단계는 한국어다.\n' > "$T/s.md"
  run python3 -I "$LINT" --lang "$T/s.md"
  [ "$status" -eq 1 ]
  [[ "$output" == *"s.md:5"* ]]
}

@test "code-style-skill-language-convention.R2 --lang allows Korean in triggers, quotes, glosses, output" {
  printf -- '---\ntrigger_phrases: ["독서 통계"]\n---\n# T\n\n## Workflow\n\n1. Group by **정체됨 (stale)**; say "전달해" or run `한글`.\n\n## Output Format\n\n- 완료된 이슈\n' > "$T/s.md"
  run python3 -I "$LINT" --lang "$T/s.md"
  [ "$status" -eq 0 ]
}

trace_fixture() {  # trace_fixture <constraint body> [check file content]
  mkdir -p "$T/agent-context/constraints" "$T/tests"
  printf '%b' "$1" > "$T/agent-context/constraints/x-rule.md"
  printf '%s\n' "${2:-}" > "$T/tests/x.bats"
}

@test "code-style-requirement-sentences.R9 --trace rejects a requirement without an ID" {
  trace_fixture "# Constraint: X\n\n- The agent MUST retry.\n"
  run python3 -I "$LINT" --trace "$T"
  [ "$status" -eq 1 ]
  [[ "$output" == *"requirement without an ID"* ]]
}

@test "code-style-requirement-sentences.R9 --trace rejects two requirements under one ID and duplicate IDs" {
  trace_fixture "# Constraint: X\n\n- **R1** The agent MUST retry. The agent MUST log.\n- **R1** The agent MUST stop.\n\n## Trace\n\n| ID | Check |\n|---|---|\n| R1 | manual |\n"
  run python3 -I "$LINT" --trace "$T"
  [ "$status" -eq 1 ]
  [[ "$output" == *"R1 has 2 requirement sentences"* ]] || false
  [[ "$output" == *"duplicate ID R1"* ]]
}

@test "code-style-requirement-sentences.R11 --trace rejects an ID without a Trace row and an orphan row" {
  trace_fixture "# Constraint: X\n\n- **R1** The agent MUST retry.\n\n## Trace\n\n| ID | Check |\n|---|---|\n| R2 | manual |\n"
  run python3 -I "$LINT" --trace "$T"
  [ "$status" -eq 1 ]
  [[ "$output" == *"R1 has no row"* ]] || false
  [[ "$output" == *"Trace row R2 names no requirement"* ]]
}

@test "code-style-requirement-sentences.R12 --trace needs a check file that names the full ID" {
  trace_fixture "# Constraint: X\n\n- **R1** The agent MUST retry.\n\n## Trace\n\n| ID | Check |\n|---|---|\n| R1 | \`tests/x.bats\` |\n" '@test "x-rule.R2 other" {'
  run python3 -I "$LINT" --trace "$T"
  [ "$status" -eq 1 ]
  [[ "$output" == *"does not mention x-rule.R1"* ]] || false
  printf '%s\n' '@test "x-rule.R1 retries" {' > "$T/tests/x.bats"
  run python3 -I "$LINT" --trace "$T"
  [ "$status" -eq 0 ]
}

@test "--md strips the ID prefix before checking the sentence" {
  printf '# T\n\n- **R1** The agent MUST retry.\n' > "$T/a.md"
  run python3 -I "$LINT" --md "$T/a.md"
  [ "$status" -eq 0 ]
}

@test "--help from another directory prints an existing rule document path" {
  cd "$T"
  run python3 -I "$LINT" --help
  [ "$status" -eq 0 ]
  doc="$(printf '%s\n' "$output" | grep -oE '(^| )/[^ ]*/code-style-requirement-sentences\.md' | head -1 | tr -d ' ')"
  [ -n "$doc" ]
  [ -f "$doc" ]
}
