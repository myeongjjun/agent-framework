#!/usr/bin/env bats
# brief audit: the tool, not the desk, re-judges closed sessions from the transcript, the input box
# captured at close, and git. Runs cmux/brief against a fake HOME and a fake cmux.

BRIEF="$BATS_TEST_DIRNAME/../cmux/brief"
A=AAAA-PANEL
DESK=DESK-PANEL

setup() {
  # Board days and held spans read local time; pin it so the suite is the same on every machine.
  export TZ=UTC
  export HOME="$BATS_TEST_TMPDIR/home"
  mkdir -p "$HOME/.claude/projects/p" "$HOME/bin" "$HOME/.cache/cmux"
  export BRIEF_CMUX="$HOME/bin/cmux" BRIEF_DESK_PANEL="$DESK" BRIEF_PATROL_MIN=0
  export STUB="$HOME/stub"; mkdir -p "$STUB"
  repo="$HOME/repo"
  git init -q "$repo"
  git -C "$repo" -c user.email=t@t -c user.name=t commit -q --allow-empty -m init
  cat > "$STUB/current.json" <<EOF
{"items":[{"label":"Task A","cwd":"$repo","agents":[{"kind":"claude","state":"idle","session_id":"sid-a","last_activity_at":"2026-11-19T02:10:00Z"}],"projections":[{"panel_id":"$A","workspace_id":"W1"}]}]}
EOF
  echo '{"messages":[]}' > "$STUB/inbox.json"
  printf '  ❯ \n  ─────\n' > "$STUB/screen.txt"
  cat > "$BRIEF_CMUX" <<'EOF'
#!/usr/bin/env bash
echo "cmux $*" >> "$STUB/calls"
case "$1 $2" in
  "current --json") cat "$STUB/current.json" ;;
  "agent inbox") cat "$STUB/inbox.json" ;;
  "list-workspaces --json") echo '{"workspaces":[]}' ;;
  "rpc workspace.list") echo '{"workspaces":[]}' ;;
  "rpc surface.list") echo '{"surfaces":[{"id":"x"},{"id":"y"}]}' ;;
  "rpc surface.input_state") [ -f "$STUB/input_state" ] && printf '{"surface_id":"AAAA-PANEL","state":"%s"}' "$(cat "$STUB/input_state")" ;;
  read-screen*) cat "$STUB/screen.txt" ;;
  *) : ;;
esac
EOF
  chmod +x "$BRIEF_CMUX"
}

line() { printf '{"type":"%s","timestamp":"%s","message":{"content":%s}%s}\n' "$1" "$2" "$3" "${4:-}"; }
transcript() { cat > "$HOME/.claude/projects/p/sid-a.jsonl"; }
# A closed record for sid-a, closed now. $1: the desk's verified note (empty: closed without review).
closed() {
  python3 - "$repo" "$1" <<'EOF' >> "$HOME/.cache/cmux/brief-closed.jsonl"
import json, sys, time
r = {"panel": "AAAA-PANEL", "title": "Task A", "cwd": sys.argv[1], "agent": "claude", "session": "sid-a",
     "at": int(time.time()), "closed": True}
if sys.argv[2]:
    r["verified"] = sys.argv[2]
else:
    r["check"] = {}
print(json.dumps(r))
EOF
}
verdict() { python3 -c "import json,sys; a=json.load(sys.stdin); print(a[0]['verdict'] if a else 'none')"; }

@test "audit: a desk close over an unanswered question is 'left', whatever the desk's note says" {
  transcript <<EOF
$(line user 2026-11-19T01:00:00Z '"check memory --- completion contract (from sib) ---"')
$(line assistant 2026-11-19T01:40:00Z '[{"type":"text","text":"Swap is high.\nShall I clean up the old sessions?"}]')
EOF
  closed "no report; nothing left, decided not to clean up"
  run python3 "$BRIEF" audit --json
  [ "$status" -eq 0 ]
  [ "$(echo "$output" | verdict)" = "left" ]
  [[ "$output" == *"Shall I clean up"* ]]
  run python3 "$BRIEF" board
  [[ "$output" == *"! 닫기 검사: 데스크가 닫음 1 · 일이 남은 채 닫음 1"* ]]
  run python3 "$BRIEF" closed
  [[ "$output" == *"검사: 일이 남은 채 닫음 · 데스크가 닫음"* ]]
  [[ "$output" == "! "* ]]
}

@test "audit: a ready report is found; the request's ready|not-ready template is not a report" {
  transcript <<EOF
$(line user 2026-11-19T01:00:00Z '"done-request: reply done-report: ready|not-ready then did: ..."')
$(line assistant 2026-11-19T01:01:00Z '[{"type":"tool_use","name":"Bash","input":{"command":"brief report \"done-report: ready | did: x\""}}]')
$(line assistant 2026-11-19T01:01:30Z '[{"type":"text","text":"Reported."}]')
EOF
  closed "report matches"
  run python3 "$BRIEF" audit --json
  [ "$(echo "$output" | verdict)" = "ok" ]
  [[ "$output" == *'"report": "ready"'* ]]
}

@test "audit: no report and nothing left is 'unreported', counted on the board" {
  transcript <<EOF
$(line user 2026-11-19T01:00:00Z '"look at x"' ',"origin":{"kind":"human"}')
$(line assistant 2026-11-19T01:40:00Z '[{"type":"text","text":"Done, x is fine."}]')
EOF
  closed "no report; idle for days"
  run python3 "$BRIEF" audit --json
  [ "$(echo "$output" | verdict)" = "unreported" ]
  run python3 "$BRIEF" board
  [[ "$output" == *"보고 없이 닫음 1"* ]]
}

@test "audit: a not-ready report the user talked past is not held against the close" {
  transcript <<EOF
$(line assistant 2026-11-19T01:00:00Z '[{"type":"text","text":"done-report: not-ready | remaining: one choice"}]')
$(line user 2026-11-19T01:10:00Z '"anything left here?"' ',"origin":{"kind":"human"}')
$(line assistant 2026-11-19T01:11:00Z '[{"type":"text","text":"The task is finished."}]')
EOF
  closed "finished"
  run python3 "$BRIEF" audit --json
  [ "$(echo "$output" | verdict)" = "ok" ]
}

@test "audit: the session's own uncommitted file is work left without a ready report, handed over with one" {
  echo x > "$repo/mine.txt"
  echo y > "$repo/other.txt"
  transcript <<EOF
$(line assistant 2026-11-19T01:00:00Z "[{\"type\":\"tool_use\",\"name\":\"Write\",\"input\":{\"file_path\":\"$repo/mine.txt\",\"content\":\"x\"}}]")
$(line assistant 2026-11-19T01:01:00Z '[{"type":"text","text":"Wrote it."}]')
EOF
  closed "no report"
  run python3 "$BRIEF" audit --json
  [ "$(echo "$output" | verdict)" = "left" ]
  [[ "$output" == *"세션이 고친 파일 미커밋 1"* ]]   # other.txt is not the session's
  printf '%s\n' "$(line assistant 2026-11-19T01:02:00Z '[{"type":"text","text":"done-report: ready | uncommitted: mine.txt"}]')" \
    >> "$HOME/.claude/projects/p/sid-a.jsonl"
  run python3 "$BRIEF" audit --json --fresh
  [ "$(echo "$output" | verdict)" = "ok" ]
}

@test "done --verified: the tool captures the input box before closing, and the audit flags unsent text" {
  transcript <<EOF
$(line assistant 2026-11-19T01:00:00Z '[{"type":"text","text":"done-report: ready | did: x"}]')
EOF
  printf '  ❯ also push to the team repo\n  ─────\n' > "$STUB/screen.txt"
  run python3 "$BRIEF" done "$A" --verified "report matches" --drop-unsent
  [ "$status" -eq 0 ]
  grep -q '"unsent": "also push to the team repo"' "$HOME/.cache/cmux/brief-closed.jsonl"
  run python3 "$BRIEF" audit
  [[ "$output" == *"! "*"보내지 않은 글 'also push to the team repo'"* ]]
}

@test "done --verified: the desk's own unsent request in the box is not counted" {
  transcript <<EOF
$(line assistant 2026-11-19T01:00:00Z '[{"type":"text","text":"done-report: ready | did: x"}]')
EOF
  printf '  ❯ done-request: this session looks finished\n  ─────\n' > "$STUB/screen.txt"
  run python3 "$BRIEF" done "$A" --verified "report matches"
  ! grep -q '"unsent"' "$HOME/.cache/cmux/brief-closed.jsonl"
  run python3 "$BRIEF" audit --json
  [ "$(echo "$output" | verdict)" = "ok" ]
}

@test "done --verified: unsent text the desk did not write blocks the close and is shown" {
  transcript <<EOF
$(line assistant 2026-11-19T01:00:00Z '[{"type":"text","text":"done-report: ready | did: x"}]')
EOF
  printf '  ❯ evalset 의 --strict-mcp-config 도 같이 고쳐줘\n  ─────\n' > "$STUB/screen.txt"
  echo draft > "$STUB/input_state"   # cmux: the user typed it
  run python3 "$BRIEF" done "$A" --verified "report matches"
  [ "$status" -eq 1 ]
  [[ "$output" == *"닫지 않음"*"evalset 의 --strict-mcp-config 도 같이 고쳐줘"*"--drop-unsent"* ]]
  ! grep -q close-surface "$STUB/calls"
  [ ! -s "$HOME/.cache/cmux/brief-closed.jsonl" ]
  run python3 "$BRIEF" done "$A" --now
  [ "$status" -eq 1 ]
  run python3 "$BRIEF" done "$A" --verified "user confirmed the draft is stale" --drop-unsent
  [ "$status" -eq 0 ]
  grep -q close-surface "$STUB/calls"
}

@test "done --verified: a prompt suggestion (cmux input state empty) closes and the audit does not count it" {
  transcript <<EOF
$(line assistant 2026-11-19T01:00:00Z '[{"type":"text","text":"done-report: ready | did: x"}]')
EOF
  printf '  ❯ 문서 2개 커밋해줘\n  ─────\n' > "$STUB/screen.txt"   # same plain text as a typed draft
  echo empty > "$STUB/input_state"                                 # but cmux sees an empty box: Claude Code's ghost text
  run python3 "$BRIEF" done "$A" --verified "report matches"
  [ "$status" -eq 0 ]
  grep -q close-surface "$STUB/calls"
  grep -q '"suggested": "문서 2개 커밋해줘"' "$HOME/.cache/cmux/brief-closed.jsonl"
  ! grep -q '"unsent"' "$HOME/.cache/cmux/brief-closed.jsonl"
  run python3 "$BRIEF" audit --json
  [ "$(echo "$output" | verdict)" = "ok" ]
  [[ "$output" == *"프롬프트 제안"* ]]
}

@test "done --verified: text with an unreadable input state still blocks the close (treated as typed)" {
  transcript <<EOF
$(line assistant 2026-11-19T01:00:00Z '[{"type":"text","text":"done-report: ready | did: x"}]')
EOF
  printf '  ❯ 푸시해\n  ─────\n' > "$STUB/screen.txt"   # no input_state stub: rpc gives nothing
  run python3 "$BRIEF" done "$A" --verified "report matches"
  [ "$status" -eq 1 ]
  [[ "$output" == *"닫지 않음"*"푸시해"* ]]
  run python3 "$BRIEF" done "$A" --verified "stale" --drop-unsent
  grep -q '"input": "unknown"' "$HOME/.cache/cmux/brief-closed.jsonl"
  run python3 "$BRIEF" audit --json
  [ "$(echo "$output" | verdict)" = "left" ]
}

@test "done --verified: a selection dialog (cmux input state dialog) is not unsent text" {
  transcript <<EOF
$(line assistant 2026-11-19T01:00:00Z '[{"type":"text","text":"done-report: ready | did: x"}]')
EOF
  printf '  ❯ 1. 커밋한다\n    2. 그대로 둔다\n  ─────\n' > "$STUB/screen.txt"   # AskUserQuestion menu: '❯' marks the choice
  echo dialog > "$STUB/input_state"
  run python3 "$BRIEF" done "$A" --verified "report matches"
  [ "$status" -eq 0 ]
  [[ "$output" != *"닫지 않음"* ]]
  grep -q '"input": "dialog"' "$HOME/.cache/cmux/brief-closed.jsonl"
  ! grep -q '"unsent"' "$HOME/.cache/cmux/brief-closed.jsonl"
}

narrow_screen() { printf '\n──\n❯…\n\xc2\xa0\n──\n' > "$STUB/screen.txt"; }   # a 2-column pane: Claude draws the box as '…'

@test "done --verified: a narrow pane's '…' is 'cannot read the input box', not unsent text, when nobody typed after the last answer" {
  transcript <<EOF
$(line user 2026-11-19T00:50:00Z '"do x"')
$(line assistant 2026-11-19T01:00:00Z '[{"type":"text","text":"done-report: ready | did: x"}]')
EOF
  narrow_screen
  echo unknown > "$STUB/input_state"
  run python3 "$BRIEF" done "$A" --verified "report matches"
  [ "$status" -eq 0 ]
  [[ "$output" == *"입력 칸을 읽을 수 없음(폭 2칸)"* ]]
  [[ "$output" != *"'…'"* ]]
  grep -q close-surface "$STUB/calls"
  ! grep -q '"unsent"' "$HOME/.cache/cmux/brief-closed.jsonl"
  grep -q '"unreadable": "입력 칸을 읽을 수 없음(폭 2칸)"' "$HOME/.cache/cmux/brief-closed.jsonl"
  run python3 "$BRIEF" audit --json
  [ "$(echo "$output" | verdict)" = "ok" ]
  [[ "$output" == *"입력 칸을 읽을 수 없음"* ]]
}

@test "done --verified: a narrow pane still blocks when cmux says draft, or the user typed after the last answer" {
  transcript <<EOF
$(line assistant 2026-11-19T01:00:00Z '[{"type":"text","text":"done-report: ready | did: x"}]')
EOF
  narrow_screen
  echo draft > "$STUB/input_state"
  run python3 "$BRIEF" done "$A" --verified "report matches"
  [ "$status" -eq 1 ]
  [[ "$output" == *"닫지 않음"*"입력 칸을 읽을 수 없음"* ]]
  [[ "$output" != *"'…'"* ]]
  transcript <<EOF
$(line assistant 2026-11-19T01:00:00Z '[{"type":"text","text":"done-report: ready | did: x"}]')
$(line user 2026-11-19T01:05:00Z '"그리고 하나 더"')
EOF
  echo unknown > "$STUB/input_state"
  run python3 "$BRIEF" done "$A" --verified "report matches"
  [ "$status" -eq 1 ]
  [[ "$output" == *"마지막 답 뒤에 사용자 입력이 있음"* ]]
  ! grep -q close-surface "$STUB/calls"
}

@test "done (request): a narrow pane's refusal says the box cannot be read, not '…' as unsent text" {
  transcript <<EOF
$(line assistant 2026-11-19T01:00:00Z '[{"type":"text","text":"done-report: ready | did: x"}]')
EOF
  narrow_screen
  echo unknown > "$STUB/input_state"
  export BRIEF_DELIVER="$HOME/bin/pane-deliver"
  printf '#!/usr/bin/env bash\necho "REFUSED: input box holds text that is not ours: …" >&2\nexit 7\n' > "$BRIEF_DELIVER"
  chmod +x "$BRIEF_DELIVER"
  run python3 "$BRIEF" done "$A"
  [[ "$output" == *"입력 칸을 읽을 수 없음(폭 2칸)"* ]]
  [[ "$output" != *"쓰던 글"* ]]
}

@test "audit: an old record's '…' is a note, not unsent text" {
  transcript <<EOF
$(line assistant 2026-11-19T01:00:00Z '[{"type":"text","text":"done-report: ready | did: x"}]')
EOF
  python3 -c 'import json,sys,time; print(json.dumps({"panel":"AAAA-PANEL","title":"Task A","cwd":sys.argv[1],"agent":"claude","session":"sid-a","at":int(time.time()),"closed":True,"verified":"ok","check":{"input":"unknown","unsent":"…"}}))' "$repo" >> "$HOME/.cache/cmux/brief-closed.jsonl"
  run python3 "$BRIEF" audit --json
  [ "$(echo "$output" | verdict)" = "ok" ]
  [[ "$output" == *"입력 칸을 읽을 수 없음"* ]]
}

@test "audit: input-box text in a record without an input state (before 11-24) is a note, not work left" {
  transcript <<EOF
$(line assistant 2026-11-19T01:00:00Z '[{"type":"text","text":"done-report: ready | did: x"}]')
EOF
  closed "report matches. 입력 칸의 보내지 않은 글 '팀 레포에도 push해'는 버림"
  run python3 "$BRIEF" audit --json
  [ "$(echo "$output" | verdict)" = "ok" ]
  [[ "$output" == *"프롬프트 제안일 수 있음"* ]]
}

@test "audit: a declarative line with the verb \"pick\" (Korean) is not a question" {
  transcript <<EOF
$(line assistant 2026-11-19T01:00:00Z '[{"type":"text","text":"- 제 변경만 골라 커밋했습니다. 남은 미커밋은 그 세션 것입니다."}]')
EOF
  closed "report matches"
  run python3 "$BRIEF" audit --json
  [[ "$output" != *"답 없는 질문"* ]]
}

@test "audit: a not-ready report after the user said to stop is not work left" {
  transcript <<EOF
$(line user 2026-11-19T01:00:00Z '"작업 종료해"' ',"origin":{"kind":"human"}')
$(line assistant 2026-11-19T01:00:10Z '[{"type":"text","text":"done-report: not-ready | remaining: check the cluster"}]')
EOF
  closed "user ended it"
  run python3 "$BRIEF" audit --json
  [ "$(echo "$output" | verdict)" = "ok" ]
  [[ "$output" == *"사용자가 끝내라고 한 뒤"* ]]
}

@test "audit: finished then held open past the limit is counted, follow-up turns included" {
  # ready report, a follow-up answered without a question, then 3h17m of nothing until the user asks why
  transcript <<EOF
$(line assistant 2026-11-19T08:45:58Z '[{"type":"text","text":"done-report: ready | did: deploy"}]')
$(line user 2026-11-19T08:52:26Z '"티켓 해결해"' ',"origin":{"kind":"human"}')
$(line assistant 2026-11-19T08:53:02Z '[{"type":"text","text":"해결됨으로 바꿨습니다.\n이 세션에서 남은 건 messaging 건을 넘길지 하나입니다."}]')
$(line user 2026-11-19T12:10:22Z '"왜 열어두는거임"' ',"origin":{"kind":"human"}')
$(line assistant 2026-11-19T12:10:27Z '[{"type":"text","text":"남은 일은 없습니다."}]')
EOF
  closed "closed after the user asked"
  run python3 "$BRIEF" audit --json
  python3 -c "import json,sys; a=json.loads(sys.argv[1])[0]; d=[h[1]-h[0] for h in a['held']]; assert d[0] == 3*3600+17*60+20, d" "$output"
  run python3 "$BRIEF" audit
  [[ "$output" == *"끝났는데 열어 둠: 3시간 17분"* ]]
  run python3 "$BRIEF" board
  [[ "$output" == *"! 끝났는데 열어 둠: "*"닫힌 것 1"* ]]
}

@test "audit: a question or a quick close is not held open; the desk's done-request does not reset the clock" {
  transcript <<EOF
$(line assistant 2026-11-19T01:00:00Z '[{"type":"text","text":"done-report: ready | did: x\nShall I also push?"}]')
$(line user 2026-11-19T05:00:00Z '"no"' ',"origin":{"kind":"human"}')
$(line assistant 2026-11-19T05:00:10Z '[{"type":"text","text":"OK, nothing left."}]')
$(line user 2026-11-19T05:30:00Z '"done-request: this session looks finished"' ',"origin":{"kind":"human"}')
$(line assistant 2026-11-19T05:30:10Z '[{"type":"text","text":"done-report: ready | did: x"}]')
$(line user 2026-11-19T05:40:00Z '"thanks"' ',"origin":{"kind":"human"}')
EOF
  python3 - "$repo" <<'EOF' >> "$HOME/.cache/cmux/brief-closed.jsonl"
import json, sys, calendar
print(json.dumps({"panel": "AAAA-PANEL", "title": "Task A", "cwd": sys.argv[1], "agent": "claude", "session": "sid-a",
                  "at": calendar.timegm((2026, 11, 19, 5, 41, 0)), "closed": True, "verified": "ok"}))
EOF
  run python3 "$BRIEF" audit --day 2026-11-19 --json
  python3 -c "import json,sys; a=json.loads(sys.argv[1])[0]; assert a['held'] == [], a['held']" "$output"
}

@test "done-request: the desk's request does not end a held span, the 60 minutes run from the finish" {
  # The board day starts at 05:00 local (UTC here), so the close at 07:06Z falls on 11-19.
  transcript <<EOF
$(line assistant 2026-11-19T06:00:00Z '[{"type":"text","text":"Done. nothing left."}]')
$(line user 2026-11-19T06:50:00Z '"done-request: this session looks finished"' ',"origin":{"kind":"human"}')
$(line assistant 2026-11-19T06:50:10Z '[{"type":"text","text":"done-report: ready | did: x"}]')
$(line user 2026-11-19T07:05:00Z '"one more thing"' ',"origin":{"kind":"human"}')
EOF
  python3 - "$repo" <<'EOF' >> "$HOME/.cache/cmux/brief-closed.jsonl"
import json, sys, calendar
print(json.dumps({"panel": "AAAA-PANEL", "title": "Task A", "cwd": sys.argv[1], "agent": "claude", "session": "sid-a",
                  "at": calendar.timegm((2026, 11, 19, 7, 6, 0)), "closed": True, "verified": "ok"}))
EOF
  run python3 "$BRIEF" audit --day 2026-11-19 --json
  python3 -c "import json,sys; a=json.loads(sys.argv[1])[0]; assert [h[1]-h[0] for h in a['held']] == [3900], a['held']" "$output"
}

@test "audit and board: an open idle session finished long ago is shown as held open now" {
  transcript <<EOF
$(line assistant 2026-11-19T01:00:00Z '[{"type":"text","text":"done-report: ready | did: x"}]')
EOF
  run python3 "$BRIEF" audit
  [[ "$output" == *"끝났는데 열어 둠 1 (지금 열림 1"* ]]
  [[ "$output" == *"! 지금 열림  Task A"*"brief done $A"* ]]
  run python3 "$BRIEF" board
  [[ "$output" == *"! 끝났는데 열어 둠: 1건 (닫힌 것 0 · 지금 열림 1: Task A"* ]]
}

# A closed record with overrides (JSON), e.g. '{"panel":"P2","at":123}'.
closed_as() {
  python3 - "$repo" "$1" <<'EOF' >> "$HOME/.cache/cmux/brief-closed.jsonl"
import json, sys, time
r = {"panel": "AAAA-PANEL", "title": "Task A", "cwd": sys.argv[1], "agent": "claude", "session": "sid-a",
     "at": int(time.time()), "closed": True, "check": {}}
r.update(json.loads(sys.argv[2]))
print(json.dumps(r))
EOF
}
killed() { mkdir -p "$HOME/.local/share/sib"; echo "$1" >> "$HOME/.local/share/sib/killed.jsonl"; }
quiet_transcript() {
  transcript <<EOF
$(line user 2026-11-19T01:00:00Z '"look at x"' ',"origin":{"kind":"human"}')
$(line assistant 2026-11-19T01:40:00Z '[{"type":"text","text":"Done, x is fine."}]')
EOF
}

@test "audit: a worker pane its caller closed with sib kill is the caller's close, not the user's unreported one" {
  quiet_transcript
  closed_as '{}'
  killed '{"at":1,"slug":"scout-craft-evaluate-1","panel":"aaaa-panel","workdir":"/elsewhere"}'
  run python3 "$BRIEF" audit --json
  echo "$output" | python3 -c '
import json,sys; a=json.load(sys.stdin)[0]
assert a["by"]=="caller" and a["caller"]=="scout-craft-evaluate-1", a'
  run python3 "$BRIEF" audit
  [[ "$output" == *"닫힘 1건 · 일이 남은 채 닫음 0 (데스크 0) · 보고 없이 닫음 0 (데스크 0)"*"호출자가 닫은 일꾼 1"* ]]
  [[ "$output" != *"Task A"* ]]                       # not listed as a problem
  run python3 "$BRIEF" audit --all
  [[ "$output" == *"호출자가 닫음(sib kill scout-craft-evaluate-1)"* ]]
}

@test "audit: a kill line without a pane id matches the same folder closed within 15 minutes only" {
  quiet_transcript
  now=$(date +%s)
  closed_as "{\"at\":$now}"
  killed "{\"at\":$((now - 2000)),\"slug\":\"old\",\"panel\":\"\",\"workdir\":\"$repo\"}"
  run python3 "$BRIEF" audit --json
  [ "$(echo "$output" | python3 -c 'import json,sys; print(json.load(sys.stdin)[0]["by"])')" = "user" ]
  killed "{\"at\":$((now - 5)),\"slug\":\"near\",\"panel\":\"\",\"workdir\":\"$repo\"}"
  run python3 "$BRIEF" audit --json
  [ "$(echo "$output" | python3 -c 'import json,sys; print(json.load(sys.stdin)[0]["caller"])')" = "near" ]
}

@test "audit: a pane the desk reviewed and closed stays the desk's close even if sib kill ran" {
  quiet_transcript
  closed "no report; idle for days"
  killed '{"at":1,"slug":"x","panel":"AAAA-PANEL"}'
  run python3 "$BRIEF" audit --json
  [ "$(echo "$output" | python3 -c 'import json,sys; print(json.load(sys.stdin)[0]["by"])')" = "desk" ]
}

@test "board trend and measure desk recount a past day the way audit does; a stale stored value is shown with its rule version" {
  transcript <<EOF
$(line user 2026-11-19T01:00:00Z '"check memory"')
$(line assistant 2026-11-19T01:40:00Z '[{"type":"text","text":"Swap is high.\nShall I clean up the old sessions?"}]')
EOF
  y=$(python3 -c 'import time; print(int(time.time()) - 86400)')
  yday=$(python3 -c "import time; print(time.strftime('%Y-%m-%d', time.localtime($y - 5*3600)))")
  closed_as "{\"at\":$y,\"verified\":\"closed\"}"                       # the desk closed it with a question open: left
  closed_as "{\"at\":$((y + 1)),\"panel\":\"W-1\"}"                      # a committee pane its caller closed
  killed '{"at":1,"slug":"scout-w","panel":"W-1"}'
  mkdir -p "$HOME/.local/share/cmux"
  printf '{"day":"%s","closed_desk":1,"wrong_close":7,"closed_noreport":0,"held_open":0,"audit_v":2}\n' "$yday" \
    > "$HOME/.local/share/cmux/board.jsonl"
  run python3 "$BRIEF" audit --day "$yday"
  [[ "$output" == *"일이 남은 채 닫음 1 (데스크 1) · 보고 없이 닫음 0 (데스크 0)"*"호출자가 닫은 일꾼 1"* ]]
  run python3 "$BRIEF" board --trend 3
  echo "$output" | grep -E "^${yday:5}  +1 +1 +0 +0$"                    # the recount, not the stored 7
  [[ "$output" == *"${yday:5} 적어 둔 값(규칙 v2) → 다시 셈: 남긴채닫음 7→1"* ]]
  printf '#!/usr/bin/env bash\nexec python3 %q "$@"\n' "$BRIEF" > "$HOME/bin/brief"; chmod +x "$HOME/bin/brief"
  AGENT_SCOUT_CONFIG="$BATS_TEST_DIRNAME/../cmux/seeds/agent-committee.md" AGENT_SCOUT_BRIEF="$HOME/bin/brief" AGENT_SCOUT_BOARD=/dev/null AGENT_SCOUT_DESK_EVAL="$HOME/none" \
    AGENT_SCOUT_ROSTER="$HOME/roster.md" run "$BATS_TEST_DIRNAME/../bin/agent-scout" measure desk --until "$yday" --json
  echo "$output" | python3 -c "
import json,sys; d=json.load(sys.stdin)
day=[x for x in d['days'] if x[0]=='$yday'][0]
assert day[1:3]==[1,1] and d['left']==1, d['days']"
}
