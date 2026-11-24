#!/usr/bin/env bats
# brief: session facts (P1) and the check a pane gets when it is closed without a desk review (P4).
# Runs cmux/brief against a fake HOME and a fake cmux, so no live cmux state is read or written.

BRIEF="$BATS_TEST_DIRNAME/../cmux/brief"
A=AAAA-PANEL
DESK=DESK-PANEL

setup() {
  export HOME="$BATS_TEST_TMPDIR/home"
  mkdir -p "$HOME/.claude/projects/p" "$HOME/bin" "$HOME/.cache/cmux"
  export BRIEF_CMUX="$HOME/bin/cmux" BRIEF_DESK_PANEL="$DESK" BRIEF_PATROL_MIN=0
  export STUB="$HOME/stub"; mkdir -p "$STUB"
  # The session's working tree: one commit, one uncommitted file.
  repo="$HOME/repo"
  git init -q "$repo"
  git -C "$repo" -c user.email=t@t -c user.name=t commit -q --allow-empty -m init
  echo x > "$repo/dirty.txt"
  # cmux current: one session in $repo (the file can be emptied to simulate the pane closing).
  cat > "$STUB/current.json" <<EOF
{"items":[{"label":"Task A","cwd":"$repo","agents":[{"kind":"claude","state":"idle","session_id":"sid-a","last_activity_at":"2026-11-19T02:10:00Z"}],"projections":[{"panel_id":"$A","workspace_id":"W1"}]}]}
EOF
  echo '{"messages":[]}' > "$STUB/inbox.json"
  cat > "$BRIEF_CMUX" <<'EOF'
#!/usr/bin/env bash
echo "cmux $*" >> "$STUB/calls"
case "$1 $2" in
  "current --json") cat "$STUB/current.json" ;;
  "agent inbox") cat "$STUB/inbox.json" ;;
  "list-workspaces --json") echo '{"workspaces":[]}' ;;
  "rpc workspace.list") echo '{"workspaces":[]}' ;;
  *) : ;;
esac
EOF
  chmod +x "$BRIEF_CMUX"
}

# One transcript line. $1 type, $2 ISO time, $3 content (JSON value), $4 extra fields.
line() { printf '{"type":"%s","timestamp":"%s","message":{"content":%s}%s}\n' "$1" "$2" "$3" "${4:-}"; }

transcript() { cat > "$HOME/.claude/projects/p/sid-a.jsonl"; }

field() { python3 -c "import json,sys; x=json.load(sys.stdin)[0]; print(x.get('$1'))"; }

@test "sessions: user input, desk message, turn start, question, git counts" {
  transcript <<EOF
$(line user 2026-11-19T01:00:00Z '"desk brief here --- completion contract (from sib) ---"')
$(line assistant 2026-11-19T01:00:05Z '[{"type":"text","text":"working"}]')
$(line user 2026-11-19T01:30:00Z '"please also check the tests"' ',"origin":{"kind":"human"}')
$(line user 2026-11-19T01:30:01Z '[{"type":"tool_result","content":"ok"}]')
$(line user 2026-11-19T01:31:00Z '"<task-notification>x</task-notification>"' ',"origin":{"kind":"task-notification"}')
$(line assistant 2026-11-19T01:40:00Z '[{"type":"text","text":"Done.\nShall I push it?"}]')
EOF
  run python3 "$BRIEF" sessions
  [ "$status" -eq 0 ]
  [ "$(echo "$output" | field input_at)" = "$(python3 -c 'import time,calendar;print(time.strftime("%m-%d %H:%M",time.localtime(calendar.timegm((2026,11,19,1,30,0)))))')" ]
  [ "$(echo "$output" | field started)" = "True" ]
  [ "$(echo "$output" | field question)" = "Shall I push it?" ]
  [ "$(echo "$output" | field uncommitted)" = "1" ]
  [ "$(echo "$output" | field unpushed)" = "None" ]   # no upstream
}

@test "sessions: a desk message not yet read means not started; a later user answer clears the question" {
  transcript <<EOF
$(line assistant 2026-11-19T01:00:00Z '[{"type":"text","text":"Which option?"}]')
$(line user 2026-11-19T01:05:00Z '"option b"' ',"origin":{"kind":"human"}')
EOF
  cat > "$STUB/inbox.json" <<EOF
{"messages":[{"sender_surface_id":"$DESK","recipient_surface_id":"$A","created_at":1795060000,"read_at":null,"state":"queued","body":"do x"}]}
EOF
  run python3 "$BRIEF" sessions
  [ "$status" -eq 0 ]
  [ "$(echo "$output" | field started)" = "False" ]
  [ "$(echo "$output" | field desk_msg_at)" != "None" ]
  [ "$(echo "$output" | field question)" = "None" ]
}

@test "patrol: a pane closed without review is checked on the spot and counted unreviewed" {
  transcript <<EOF
$(line assistant 2026-11-19T01:40:00Z '[{"type":"text","text":"Should I commit dirty.txt?"}]')
EOF
  python3 "$BRIEF" patrol --read          # first run: snapshot only
  echo '{"items":[]}' > "$STUB/current.json"  # the user closes the pane
  python3 "$BRIEF" patrol
  run python3 -c "import json; r=[json.loads(l) for l in open('$HOME/.cache/cmux/brief-closed.jsonl')]; print(len(r), r[0]['panel'], 'verified' in r[0], r[0]['check'])"
  [ "$output" = "1 $A False {'uncommitted': 1, 'question': 'Should I commit dirty.txt?'}" ]
  grep -qi "agent message $DESK" "$STUB/calls"   # the desk got a patrol signal
  run python3 "$BRIEF" patrol --read
  [[ "$output" == *'"ev":"closed"'* ]]
  [[ "$output" == *'"check":{"uncommitted":1,"question":"Should I commit dirty.txt?"}'* ]]
  run python3 "$BRIEF" closed
  [[ "$output" == *"검토 없이 닫음 · 닫힐 때 대조: 미커밋 1, 미응답 질문"* ]]
  run python3 "$BRIEF" board --json
  [[ "$output" == *"검토 없이 1"* ]]
}

@test "patrol: a pane the desk closed after review is not logged twice" {
  transcript < /dev/null
  python3 "$BRIEF" patrol --read
  printf '{"panel":"%s","title":"Task A","session":"sid-a","at":%s,"closed":true,"verified":"git clean"}\n' \
    "$A" "$(date +%s)" > "$HOME/.cache/cmux/brief-closed.jsonl"
  echo '{"items":[]}' > "$STUB/current.json"
  python3 "$BRIEF" patrol
  [ "$(wc -l < "$HOME/.cache/cmux/brief-closed.jsonl" | tr -d ' ')" = "1" ]
  run python3 "$BRIEF" patrol --read
  [[ "$output" == *'"verified":"git clean"'* ]]
  [[ "$output" != *'"check"'* ]]
}

@test "closed --unreported: lists closures not yet reported, flags the ones that left work, --ack moves the mark" {
  now=$(date +%s)
  {
    printf '{"panel":"P1","title":"Reviewed","at":%s,"closed":true,"verified":"git clean"}\n' "$((now - 100))"
    printf '{"panel":"P2","title":"Left dirty","at":%s,"closed":true,"check":{"uncommitted":2,"unpushed":0}}\n' "$((now - 50))"
    printf '{"panel":"P3","title":"Clean close","at":%s,"closed":true,"check":{"uncommitted":0,"unpushed":0}}\n' "$((now - 10))"
  } > "$HOME/.cache/cmux/brief-closed.jsonl"
  run python3 "$BRIEF" closed --unreported
  [[ "$output" == *"Reviewed"* ]]
  [[ "$output" == *"! "*"Left dirty"* ]]
  [[ "$output" != *"! "*"Clean close"* ]]
  # A closure after the listing but before --ack stays unreported.
  printf '{"panel":"P5","title":"Closed meanwhile","at":%s,"closed":true,"verified":"ok"}\n' "$((now + 5))" \
    >> "$HOME/.cache/cmux/brief-closed.jsonl"
  python3 "$BRIEF" closed --ack
  run python3 "$BRIEF" closed --unreported
  [[ "$output" == *"Closed meanwhile"* ]]
  [[ "$output" != *"Reviewed"* ]]
  python3 "$BRIEF" closed --ack
  run python3 "$BRIEF" closed --unreported
  [[ "$output" == *"보고 안 한 닫힌 세션 없음"* ]]
}

@test "sessions: a sib brief stored as pasted content still counts as the desk's hand-off (11-23)" {
  transcript <<EOF2
$(line user 2026-11-19T01:00:00Z '"\n\n<pasted_content id=\"d1\">\n# Brief: x\n--- completion contract (from sib) ---\n</pasted_content id=\"d1\">"' ',"origin":{"kind":"human"}')
$(line assistant 2026-11-19T01:00:05Z '[{"type":"text","text":"on it"}]')
EOF2
  run python3 "$BRIEF" sessions
  [ "$status" -eq 0 ]
  [ "$(echo "$output" | field started)" = "True" ]
  [ "$(echo "$output" | field input_at)" = "None" ]   # the brief is not the user's own input
}

@test "sessions: a message that woke the session counts as reached before it is marked read (11-23)" {
  transcript <<EOF2
$(line assistant 2026-11-19T01:00:05Z '[{"type":"tool_use","name":"AskUserQuestion","input":{}}]')
EOF2
  t0=$(python3 -c 'import calendar;print(calendar.timegm((2026,11,19,1,0,0)))')
  cat > "$STUB/inbox.json" <<EOF2
{"messages":[{"sender_surface_id":"$DESK","recipient_surface_id":"$A","created_at":$t0,"delivered_at":$t0.5,"read_at":null,"state":"delivered","body":"do x"}]}
EOF2
  run python3 "$BRIEF" sessions
  [ "$(echo "$output" | field started)" = "True" ]
}

@test "sessions: a message delivered but not answered yet is not started" {
  transcript <<EOF2
$(line assistant 2026-11-19T00:59:00Z '[{"type":"text","text":"done earlier"}]')
EOF2
  t0=$(python3 -c 'import calendar;print(calendar.timegm((2026,11,19,1,0,0)))')
  cat > "$STUB/inbox.json" <<EOF2
{"messages":[{"sender_surface_id":"$DESK","recipient_surface_id":"$A","created_at":$t0,"delivered_at":$t0,"read_at":null,"state":"delivered","body":"do x"}]}
EOF2
  run python3 "$BRIEF" sessions
  [ "$(echo "$output" | field started)" = "False" ]
}

# Today's desk document under BRIEF_DESK_DIR (the board day starts at 05:00).
desk_doc() {
  export BRIEF_DESK_DIR="$HOME/desk"; mkdir -p "$BRIEF_DESK_DIR/Desk"
  cat > "$BRIEF_DESK_DIR/Desk/$(python3 -c 'import time;print(time.strftime("%y%m%d",time.localtime(time.time()-5*3600)))').md"
}

@test "board: decisions handed to the user are the core metric; placing and closing count as the desk's own work" {
  desk_doc <<'EOF2'
# Desk 11-23  ·  갱신 18:33
**지금**: x

## 결정 필요
- **S3 후속 3건을 배치할지** — 맡은 세션 없음 · 권고: 새 세션
- **query topology 일을 맡을 세션을 지금 띄울지** — 맡은 세션 없음
- **완료 보고 커밋을 push 할지** — `t`(16번) · 대조와 일치 · 말씀하시면 데스크가 닫습니다
- **talkserver 증설 감시가 끝난 일인지** — `d`(4번) · 권고: 끝났다고 말씀하시면 데스크가 대조한 뒤 닫음
- **쿼리 비용 메모를 쓸지 답하기** — `p`(7번) · 그 pane 에서 답하시면 됩니다
## 진행 중
- `리서치`(19번) — 보고는 대조와 일치합니다. 사용자가 끝났다고 할 때까지 닫지 않습니다 · 다음 확인: 사용자가 말하면
- `작업`(20번) — 고치고 있습니다 · 다음 확인: 완료 보고가 오면
## 예약
없음
EOF2
  run python3 "$BRIEF" board --json
  [ "$status" -eq 0 ]
  [[ "$output" == *'"k": "사용자에게 넘김"'* ]]
  [[ "$output" == *"오늘 6건 · 데스크가 할 수 있었던 것 4 (배치 2 · 닫기 2)"* ]]
  # The top block is rewritten: a decision that left the document still counts for the day.
  sed -i.bak '/S3 후속/d' "$BRIEF_DESK_DIR"/Desk/*.md && rm -f "$BRIEF_DESK_DIR"/Desk/*.md.bak
  run python3 "$BRIEF" board --log
  [[ "$output" == *"오늘 6건"* ]]
  run python3 "$BRIEF" board --trend 3
  [[ "$output" == *"넘긴결정"*"스스로가능"* ]]
  [[ "$(echo "$output" | tail -1)" =~ ^[0-9-]+\ +6\ +4 ]]
}

@test "board: the desk's morning recount wins over the tool's estimate" {
  desk_doc <<'EOF2'
## 결정 필요
- **새 세션을 하나 띄울지** — 맡은 세션 없음
EOF2
  day=$(python3 -c 'import time;print(time.strftime("%Y-%m-%d",time.localtime(time.time()-5*3600)))')
  python3 "$BRIEF" board --set asked=3 avoidable=0 --day "$day" > /dev/null
  run python3 "$BRIEF" board --log
  [[ "$output" == *"오늘 3건 · 데스크가 할 수 있었던 것 0"* ]]
  python3 -c 'import json,sys;h=json.loads(open(sys.argv[1]).readlines()[-1]);assert (h["asked"],h["avoidable"])==(3,0),h' \
    "$HOME/.local/share/cmux/board.jsonl"
}

# P12: the Desk pane draws a decision as answered when the user typed into that session's pane after it
# was raised; user input in a pane is a patrol signal.
p12_doc() {  # $1 epoch for the document's mtime
  export BRIEF_DESK_DIR="$HOME/desk"; mkdir -p "$BRIEF_DESK_DIR/Desk"
  cat > "$BRIEF_DESK_DIR/Desk/261119.md" <<'DOC'
# Desk 11-19
## 결정 필요
- **푸시할지** — `Task A`(1번) · 권고: 푸시
- **세션 없는 결정** — 권고: 보류
## 타임라인
- 10:00 무시
DOC
  python3 -c "import os,sys; os.utime(sys.argv[1], (int(sys.argv[2]),) * 2)" "$BRIEF_DESK_DIR/Desk/261119.md" "$1"
  echo "{\"at\":1,\"items\":[{\"panel\":\"$A\",\"do\":\"x\",\"done\":false}]}" > "$HOME/.cache/cmux/brief-plan.json"
}
utc() { python3 -c "import calendar,sys; print(calendar.timegm(tuple(map(int,sys.argv[1:]))+(0,0,0)))" "$@"; }
iso_now() { python3 -c "import time; print(time.strftime('%Y-%m-%dT%H:%M:%S.000Z', time.gmtime()))"; }
# The desk was woken two minutes ago; the next ordinary wake-up is 8 minutes away (no retry is scheduled).
recently_woken() {
  python3 - "$HOME/.cache/cmux/brief-patrol.json" <<'PY'
import json, sys, time
p = sys.argv[1]; st = json.load(open(p)); st["notified"] = int(time.time()) - 120; st["retry"] = 2**40
json.dump(st, open(p, "w"))
PY
}

@test "answered: input after the decision went up marks that line; lines without a session are never marked" {
  p12_doc "$(utc 2026 11 19 1 20 0)"
  transcript <<TR
$(line assistant 2026-11-19T01:10:00Z '[{"type":"text","text":"Push it?"}]')
$(line user 2026-11-19T01:30:00Z '"yes push"' ',"origin":{"kind":"human"}')
TR
  run python3 "$BRIEF" answered
  [ "$status" -eq 0 ]
  python3 - "$output" <<'PY'
import json, sys
rows = json.loads(sys.argv[1])
assert [r["i"] for r in rows] == [0, 1], rows
assert rows[0]["n"] == 1 and rows[0]["answered"] is True and rows[0]["input_at"], rows
assert rows[1] == {"i": 1, "n": 0}, rows
PY
  # The line was first seen at the document's mtime; a later rewrite of the file does not move it.
  python3 -c "import os,sys; os.utime(sys.argv[1], (2000000000,)*2)" "$BRIEF_DESK_DIR/Desk/261119.md"
  run python3 "$BRIEF" answered
  [[ "$output" == *'"answered":true'* ]]
}

@test "answered: input before the decision went up, or the desk's own hand-off, is not an answer" {
  p12_doc "$(utc 2026 11 19 1 40 0)"
  transcript <<TR
$(line user 2026-11-19T01:30:00Z '"yes push"' ',"origin":{"kind":"human"}')
$(line user 2026-11-19T01:50:00Z '"desk-message: the user says push"' ',"origin":{"kind":"human"}')
TR
  run python3 "$BRIEF" answered
  [ "$status" -eq 0 ]
  [[ "$output" != *answered* ]]
}

@test "patrol --input: user input is a signal; in a pane with an open decision it wakes the desk at once" {
  p12_doc "$(utc 2026 11 19 1 20 0)"
  export BRIEF_INPUT_WAIT=0 BRIEF_PATROL_MIN=10
  transcript </dev/null
  python3 "$BRIEF" patrol --read >/dev/null   # the desk reads once, so it gets signals
  recently_woken
  # A hand-off the desk typed in is not user input.
  transcript <<TR
$(line user "$(iso_now)" '"desk-message: do x"' ',"origin":{"kind":"human"}')
TR
  CMUX_AUTOMATION_EVENT_JSON="{\"surface_id\":\"$A\"}" run python3 "$BRIEF" patrol --input
  [ "$status" -eq 0 ]
  ! grep -qi "agent message $DESK" "$STUB/calls"
  # The user answers in the pane: TODO 1 has an open decision, so the desk is woken now.
  transcript <<TR
$(line user "$(iso_now)" '"yes push"' ',"origin":{"kind":"human"}')
TR
  CMUX_AUTOMATION_EVENT_JSON="{\"payload\":{\"surface_id\":\"$A\"}}" run python3 "$BRIEF" patrol --input
  [ "$status" -eq 0 ]
  grep -qi "agent message $DESK --from orch-patrol -- patrol 1" "$STUB/calls"
  run python3 "$BRIEF" patrol --read
  [[ "$output" == *'"ev":"input"'* ]]
  [[ "$output" == *'"decision":true'* ]]
  [[ "$output" == *'"todo":1'* ]]
}

@test "patrol --input: without an open decision the input waits for the ordinary interval" {
  p12_doc "$(utc 2026 11 19 1 20 0)"
  echo '{"at":1,"items":[]}' > "$HOME/.cache/cmux/brief-plan.json"
  export BRIEF_INPUT_WAIT=0 BRIEF_PATROL_MIN=10
  transcript </dev/null
  python3 "$BRIEF" patrol --read >/dev/null
  recently_woken
  transcript <<TR
$(line user "$(iso_now)" '"carry on"' ',"origin":{"kind":"human"}')
TR
  run python3 "$BRIEF" patrol --input "$A"
  [ "$status" -eq 0 ]
  ! grep -qi "agent message $DESK" "$STUB/calls"
  run python3 "$BRIEF" patrol --read
  [[ "$output" == *'"ev":"input"'* ]]
  [[ "$output" != *decision* ]]
}
