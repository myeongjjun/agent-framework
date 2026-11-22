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
