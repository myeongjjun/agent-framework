#!/usr/bin/env bats
# brief lead — the area lead call (docs/area-lead-design.md §9 stage 2).
# A fake model (BRIEF_LEAD_CMD) stands in for `claude -p`; it records whether it ran and what it got.

BRIEF="$BATS_TEST_DIRNAME/../cmux/brief"
LEAD="$BATS_TEST_DIRNAME/../cmux/brief-lead"

setup() {
  export BRIEF_AREAS="$BATS_TEST_TMPDIR/orch-areas.md" BRIEF_LOCAL="$BATS_TEST_TMPDIR/orch-local.md"
  export BRIEF_LEAD_NOW="11-24 10:00" CALLED="$BATS_TEST_TMPDIR/called" PROMPT="$BATS_TEST_TMPDIR/prompt"
  cat >"$BRIEF_AREAS" <<'EOF'
# orch area profiles

## A. 에이전트 도구

### Scope
- Covers: `~/personal/agent-framework`

### Permissions
| kind | level |
|---|---|
| place | decide |
| answer | decide |
| close | decide |
| commit | decide |
| rules | advise |

### Trial
- Stage: 2

### Decision log
- 11-23 18:38 | rules | by:user | 스킬 description 은 영어로 둔다 | ref:abc1234

### Lessons

## B. 다른 영역

### Permissions
| kind | level |
|---|---|
| answer | user |

### Decision log
- 11-23 10:00 | place | by:desk | 무언가 | ref:x
EOF
  cat >"$BRIEF_LOCAL" <<'EOF'
## Approvals
- Approval rule:
- Ask-first areas (these override Do it, then report):
  - WidgetDB: any task about WidgetDB (the skills `wdb-ops`, `wdb-moves`, `widgetdb-*`; also `위젯디비`).

## Other
EOF
  fake '{"verdict":"decide","decision":"기존 결정대로 영어 description 을 유지한다","reason":"by:user 기록이 있다","based_on":["11-23 18:38 by:user"]}'
}

# fake <json>: the model replies with this JSON, wrapped like `claude -p --output-format json`.
fake() {
  printf '%s' "$1" >"$BATS_TEST_TMPDIR/reply"
  cat >"$BATS_TEST_TMPDIR/model" <<EOF
#!/bin/sh
touch "$CALLED"; cat >"$PROMPT"
python3 -c 'import json,sys; print(json.dumps({"type":"result","result":"","structured_output":json.load(open(sys.argv[1]))}))' "$BATS_TEST_TMPDIR/reply"
EOF
  chmod +x "$BATS_TEST_TMPDIR/model"
  export BRIEF_LEAD_CMD="$BATS_TEST_TMPDIR/model"
}

lead_lines() { grep -c '| by:lead |' "$BRIEF_AREAS" || true; }

@test "brief lead: brief dispatches to the lead script" {
  run "$BRIEF" lead --help
  [ "$status" -eq 0 ]
  [[ "$output" == *"영역 담당(Area lead) 호출"* ]]
}

@test "decide: returns decision and reason, logs one by:lead line under the area's Decision log" {
  run "$LEAD" A "스킬 description 을 한국어로 바꿀까요?" --ref "스킬 정리 세션"
  [ "$status" -eq 0 ]
  [[ "$output" == *"결정: 기존 결정대로 영어 description 을 유지한다"* ]]
  [[ "$output" == *"근거: by:user 기록이 있다"* ]]
  [ "$(lead_lines)" = 1 ]
  # The line sits right after the area's last log line, before ### Lessons, in the log format.
  run awk '/^### Decision log/{d=1;next} /^#/{d=0} d && /by:lead/' "$BRIEF_AREAS"
  [ "$output" = "- 11-24 10:00 | answer | by:lead | 기존 결정대로 영어 description 을 유지한다 — by:user 기록이 있다 | ref:스킬 정리 세션" ]
  run awk '/^## A\./{a=1} /^## B\./{a=0} a && /by:lead/{print NR}' "$BRIEF_AREAS"
  [ -n "$output" ]
}

@test "decide: the model gets the whole area profile with the decision log, not other areas" {
  "$LEAD" A "질문" >/dev/null
  grep -q 'by:user | 스킬 description 은 영어로 둔다' "$PROMPT"
  grep -q '^| answer | decide |' "$PROMPT"
  ! grep -q 'B. 다른 영역' "$PROMPT"
}

@test "area by name works, unknown area fails without calling the model" {
  run "$LEAD" "에이전트 도구" "질문" --json
  [ "$status" -eq 0 ]
  [[ "$output" == *'"verdict": "decide"'* ]]
  rm -f "$CALLED"
  run "$LEAD" Z "질문"
  [ "$status" -eq 1 ]
  [ ! -e "$CALLED" ]
}

@test "permission table: user level refuses without calling the model or logging" {
  run "$LEAD" B "질문"
  [ "$status" -eq 2 ]
  [[ "$output" == *"거절"* ]]
  [ ! -e "$CALLED" ]
  [ "$(lead_lines)" = 0 ]
}

@test "permission table: a kind missing from the table counts as user" {
  # B has no `commit` row.
  run "$LEAD" B "질문" --kind commit
  [ "$status" -eq 2 ]
  [ ! -e "$CALLED" ]
}

@test "permission table: advise returns a recommendation and logs nothing" {
  run "$LEAD" A "규칙 문서의 절 순서를 바꿀까요?" --kind rules
  [ "$status" -eq 0 ]
  [[ "$output" == *"권고(사용자가 고름)"* ]]
  [[ "$output" == *"권고: "* ]]
  [ "$(lead_lines)" = 0 ]
}

@test "Ask-first area: a WidgetDB question escalates without calling the model" {
  for q in "WidgetDB 스키마 정리 스크립트를 고칠까요?" "wdb-ops 스킬 출력 형식을 바꿀까요?" "위젯디비 TTL 을 볼까요?"; do
    rm -f "$CALLED"
    run "$LEAD" A "$q"
    [ "$status" -eq 3 ]
    [[ "$output" == *"사용자에게 넘김"* ]]
    [[ "$output" == *"ask-first:WidgetDB"* ]]
    [ ! -e "$CALLED" ]
  done
  [ "$(lead_lines)" = 0 ]
}

@test "Never / outward-facing: push, PR, tickets, wiki, messages escalate without the model" {
  for q in "main 에 push 할까요?" "PR 을 열까요?" "Jira 티켓 상태를 바꿀까요?" "위키에 올릴까요?" "슬랙으로 팀에 알릴까요?"; do
    rm -f "$CALLED"
    run "$LEAD" A "$q"
    [ "$status" -eq 3 ]
    [[ "$output" == *"outward("* ]]
    [ ! -e "$CALLED" ]
  done
  [ "$(lead_lines)" = 0 ]
}

@test "security: secrets and permission rules escalate without the model" {
  for q in "API 토큰을 설정 파일에 넣을까요?" "settings.json 의 allow 규칙을 넓힐까요?" "MCP 서버를 추가할까요?"; do
    rm -f "$CALLED"
    run "$LEAD" A "$q"
    [ "$status" -eq 3 ]
    [[ "$output" == *"security("* ]]
    [ ! -e "$CALLED" ]
  done
}

@test "irreversible and contract: escalate without the model" {
  for q in "git reset --hard 로 정리할까요?" "권한표의 rules 를 decide 로 올릴까요?" "영역을 하나 더 만들까요?"; do
    rm -f "$CALLED"
    run "$LEAD" A "$q"
    [ "$status" -eq 3 ]
    [ ! -e "$CALLED" ]
  done
  [ "$(lead_lines)" = 0 ]
}

# Three keyword-only hand-offs (invented, same shape as real ones). Each was a keyword hit, not a
# boundary case: a background mention (MCP), an exclusion (WidgetDB 가 아닌 / 밖), a negation
# ("push 는 하지 않음") and a word inside a file name (doc-scope-checker → scope).
Q_MCP="측정 샌드박스(scripts/probe.py:10)가 claude -p 를 --setting-sources project 와 --strict-mcp-config 로 부르는데, MCP 는 막히지만 플러그인의 SessionStart·Stop 훅은 여전히 뜬다. 이 측정 호출에서 플러그인 훅도 뜨지 않게 고쳐야 하는가, 그대로 두는가? 고친다면 새 세션에 배치한다."
Q_CH="에이전트 발굴 도구 세션이 묻습니다: 오늘 위원회에서 WidgetDB 가 아닌 통과 후보가 없습니다. drift-checker 는 위원 2명이 지지했지만 심판이 '반복되는 필요가 아니다'라며 적합 0점을 줘 보류입니다. 끝까지 만들어 설치하고 한 번 불러 볼 WidgetDB 밖 후보를 무엇으로 할까요? 선택지: 1) 범위 확인자(세션 권장) 2) drift-checker(심판 보류를 풀고 설치, 수습 7일) 3) 둘 다 하지 않음(WidgetDB 초안과 위원 평가만)"
Q_PUSH="에이전트 발굴 도구 세션이 묻습니다: L2 저장소 ~/persona 에 새 에이전트 정의 2개(agents/doc-scope-checker.md, agents/drift-checker.md)가 커밋되지 않은 채 있습니다. 그 저장소에는 git 규칙 제약이 없습니다. 선택지: 1) 두 파일만 main 에 로컬 커밋하고 push 는 하지 않음. 이 규칙을 /acp-constraint 로 그 저장소에 남겨 다음부터 묻지 않게 함(세션 권장) 2) 커밋하지 않고 파일만 둠(커밋은 사용자가)"

@test "keyword-only hand-offs: the three now reach the model and get a decision" {
  for q in "$Q_MCP" "$Q_CH" "$Q_PUSH"; do
    rm -f "$CALLED"
    run "$LEAD" A "$q" --kind place
    [ "$status" -eq 0 ]
    [[ "$output" == *"· 결정"* ]]
    [[ "$output" != *"경계:"* ]]
    [ -e "$CALLED" ]
  done
  [ "$(lead_lines)" = 3 ]
}

@test "keyword-only hand-offs: with advise permission they get a recommendation, not a hand-off" {
  for q in "$Q_MCP" "$Q_CH" "$Q_PUSH"; do
    run "$LEAD" A "$q" --kind rules
    [ "$status" -eq 0 ]
    [[ "$output" == *"권고(사용자가 고름)"* ]]
  done
  [ "$(lead_lines)" = 0 ]
}

@test "a background-only mention is passed to the model as a mention, not as the asked action" {
  run "$LEAD" A "$Q_MCP" --dry-run
  [ "$status" -eq 0 ]
  [[ "$output" == *"언급(할 일 아님, 모델이 판단): security(MCP)"* ]]
  [[ "$output" == *"Boundary words in the background of the question (not in what is asked): MCP (security)"* ]]
  run "$LEAD" A "$Q_PUSH" --dry-run
  [[ "$output" != *"언급"* ]]
}

@test "true crossings still go to the user without the model, even next to a negation or an exclusion" {
  for q in "테스트는 하지 않고 바로 push 할까요?" \
           "WidgetDB 가 아닌 후보가 없으니 WidgetDB 검토자를 L2 에 설치할까요?" \
           "non-WidgetDB 후보가 없으니 wdb-ops 스킬 출력 형식을 바꿀까요?" \
           "선택지: 1) 로컬 커밋만 하고 끝냄 2) 커밋하고 push 해서 PR 을 엶" \
           "Should we push this to main?"; do
    rm -f "$CALLED"
    run "$LEAD" A "$q"
    [ "$status" -eq 3 ]
    [[ "$output" == *"사용자에게 넘김"* ]]
    [[ "$output" == *"경계: "* ]]
    [ ! -e "$CALLED" ]
  done
  [ "$(lead_lines)" = 0 ]
}

@test "words inside names and negated words do not count: jira-sweeper, doc-scope-checker, no push" {
  for q in "jira-sweeper 에이전트 정의의 설명 문구를 고칠까요?" "We will not push. Should we commit locally?" \
           "doc-scope-checker 의 description 을 다듬을까요?"; do
    rm -f "$CALLED"
    run "$LEAD" A "$q"
    [ "$status" -eq 0 ]
    [ -e "$CALLED" ]
  done
}

@test "decision text: a negated boundary word is fine, an affirmative one is downgraded" {
  fake '{"verdict":"decide","decision":"두 파일만 로컬 커밋하고 push 는 하지 마세요","reason":"영역 A 의 commit 권한이 decide"}'
  run "$LEAD" A "$Q_PUSH"
  [ "$status" -eq 0 ]
  [ "$(lead_lines)" = 1 ]
  fake '{"verdict":"decide","decision":"3번: WidgetDB 초안을 다듬어 설치한다","reason":"후보가 없다"}'
  run "$LEAD" A "$Q_CH"
  [ "$status" -eq 3 ]
  [[ "$output" == *"결정문이 경계를 건드려 넘김"* ]]
  [ "$(lead_lines)" = 1 ]
}

@test "model escalates: no log line, exit 3" {
  fake '{"verdict":"escalate","decision":"새 목표라 사용자에게 묻는다","reason":"정해진 범위 밖"}'
  run "$LEAD" A "다음 분기 계획을 세울까요?"
  [ "$status" -eq 3 ]
  [[ "$output" == *"권고: 새 목표라 사용자에게 묻는다"* ]]
  [ "$(lead_lines)" = 0 ]
}

@test "model decides something past the boundary: downgraded to escalate, not logged" {
  fake '{"verdict":"decide","decision":"커밋하고 바로 push 한다","reason":"빠르다"}'
  run "$LEAD" A "이 변경을 어떻게 마무리할까요?"
  [ "$status" -eq 3 ]
  [[ "$output" == *"결정문이 경계를 건드려 넘김"* ]]
  [ "$(lead_lines)" = 0 ]
}

@test "malformed model reply: fails, logs nothing" {
  fake '{"verdict":"maybe"}'
  run "$LEAD" A "질문"
  [ "$status" -eq 1 ]
  [ "$(lead_lines)" = 0 ]
}

@test "pipes in the model reply cannot break the log format" {
  fake '{"verdict":"decide","decision":"a | b","reason":"c\nd"}'
  run "$LEAD" A "질문"
  [ "$status" -eq 0 ]
  run awk '/by:lead/' "$BRIEF_AREAS"
  [ "$output" = "- 11-24 10:00 | answer | by:lead | a / b — c d | ref:-" ]
}

@test "dry-run shows the prompt and never calls the model" {
  run "$LEAD" A "질문" --dry-run
  [ "$status" -eq 0 ]
  [[ "$output" == *"--- area profile ---"* ]]
  [ ! -e "$CALLED" ]
}

@test "question from stdin" {
  run sh -c "echo '표준 입력 질문' | '$LEAD' A -"
  [ "$status" -eq 0 ]
  grep -q '표준 입력 질문' "$PROMPT"
}

@test "real run: claude is called with no tools and no session persistence" {
  unset BRIEF_LEAD_CMD
  grep -q '"--tools", ""' "$LEAD"
  grep -q '"--no-session-persistence"' "$LEAD"
  grep -q 'not k.startswith("CMUX_")' "$LEAD"
}
