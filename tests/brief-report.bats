#!/usr/bin/env bats
# brief report: sessions reach the desk without carrying its panel id (ADR-007).
# The desk is looked up at send time, the sender is named by its session title, and a report
# the desk never read as a message comes back through `brief patrol --read`.

BRIEF="$BATS_TEST_DIRNAME/../cmux/brief"
A=AAAA-PANEL
DESK=DESK-PANEL

setup() {
  export HOME="$BATS_TEST_TMPDIR/home"
  mkdir -p "$HOME/bin" "$HOME/.cache/cmux"
  export BRIEF_CMUX="$HOME/bin/cmux" BRIEF_DESK_PANEL="$DESK" BRIEF_PATROL_MIN=0 CMUX_PANEL_ID="$A"
  export STUB="$HOME/stub"; mkdir -p "$STUB"
  cat > "$STUB/current.json" <<EOF
{"items":[{"label":"Task A","cwd":"$HOME","agents":[{"kind":"claude","state":"idle","session_id":"sid-a","last_activity_at":"2026-11-19T02:10:00Z"}],"projections":[{"panel_id":"$A","workspace_id":"W1"}]}]}
EOF
  echo '{"messages":[]}' > "$STUB/inbox.json"
  cat > "$BRIEF_CMUX" <<'EOF'
#!/usr/bin/env bash
printf 'cmux' >> "$STUB/calls"; printf ' [%s]' "$@" >> "$STUB/calls"; echo >> "$STUB/calls"
case "$1 $2" in
  "current --json") cat "$STUB/current.json" ;;
  "agent inbox") cat "$STUB/inbox.json" ;;
  "agent message")
    [ -n "${STUB_SEND_FAIL:-}" ] && { echo "Error: not_found" >&2; exit 1; }
    echo '{"id":"m1","state":"queued"}' ;;
  "list-workspaces --json") echo '{"workspaces":[]}' ;;
  "rpc agent.message.mark_read") echo "$3" > "$STUB/marked"; python3 -c 'import json,sys; print(json.dumps({"read": json.loads(sys.argv[1])["ids"]}))' "$3" ;;
  *) : ;;
esac
EOF
  chmod +x "$BRIEF_CMUX"
}

inbox() {  # $1 recipient, $2 state, $3 read_at (null or a number)
  echo "{\"messages\":[{\"id\":\"m1\",\"recipient_surface_id\":\"$1\",\"state\":\"$2\",\"read_at\":$3}]}" > "$STUB/inbox.json"
}

@test "report: sent to the desk found now, named by the session title, panel in the trailer" {
  run python3 "$BRIEF" report "done-report: ready"
  [ "$status" -eq 0 ]
  [[ "$output" == *"데스크에 보냄"* ]]
  grep -qF "[agent] [message] [$DESK] [--from] [Task A]" "$STUB/calls"
  grep -qF "— from: Task A (panel $A)" "$STUB/calls"
  grep -q '"msg": "m1"' "$HOME/.cache/cmux/brief-reports.jsonl"
}

@test "report: the desk read the message, so patrol --read does not repeat it" {
  python3 "$BRIEF" report "done-report: ready"
  inbox "$DESK" read 1795060000
  run python3 "$BRIEF" patrol --read
  [ "$status" -eq 0 ]
  [[ "$output" != *'"ev":"report"'* ]]
  [ ! -s "$HOME/.cache/cmux/brief-reports.jsonl" ]
}

@test "report: still queued for the current desk is held, not delivered twice" {
  python3 "$BRIEF" report "done-report: ready"
  inbox "$DESK" queued null
  run python3 "$BRIEF" patrol --read
  [[ "$output" != *'"ev":"report"'* ]]
  [ -s "$HOME/.cache/cmux/brief-reports.jsonl" ]
}

@test "report: no desk open — recorded, and the next desk gets it from patrol --read" {
  unset BRIEF_DESK_PANEL
  run python3 "$BRIEF" report "done-report: not-ready"
  [ "$status" -eq 0 ]
  [[ "$output" == *"바로 못 보냄"* ]]
  ! grep -q "\[agent\] \[message\]" "$STUB/calls"
  export BRIEF_DESK_PANEL="$DESK"
  run python3 "$BRIEF" patrol --read
  [[ "$output" == *'"ev":"report"'*'"report":"done-report: not-ready"'* ]]
  [ ! -s "$HOME/.cache/cmux/brief-reports.jsonl" ]
}

@test "report: queued to a desk that has since closed comes back to the new desk" {
  BRIEF_DESK_PANEL=OLD-DESK python3 "$BRIEF" report "done-report: ready"
  inbox OLD-DESK queued null
  run python3 "$BRIEF" patrol --read
  [[ "$output" == *'"ev":"report"'*'"title":"Task A"'* ]]
}

@test "report: send refused — recorded for patrol" {
  STUB_SEND_FAIL=1 run python3 "$BRIEF" report "done-report: ready"
  [ "$status" -eq 0 ]
  [[ "$output" == *"바로 못 보냄"* ]]
  run python3 "$BRIEF" patrol --read
  [[ "$output" == *'"ev":"report"'* ]]
}

@test "report: empty text is refused" {
  run python3 "$BRIEF" report "  "
  [ "$status" -ne 0 ]
}

@test "done-request: tells the session to answer with brief report, no desk id in the text" {
  # The session's own pane: request_close prints the text instead of typing it into the pane.
  # Done-requests left in an input box for days used to point at a desk that had since closed.
  run python3 "$BRIEF" done here
  [[ "$output" == *'brief report "<reply>"'* ]]
  [[ "$output" != *"$DESK"* ]]
}

@test "patrol: a new desk's first read retires unread messages the previous desks sent, nothing else" {
  echo '{"snap":{},"pending":{},"notified":0,"desk":"old-desk-b"}' > "$HOME/.cache/cmux/brief-patrol.json"
  cat > "$STUB/inbox.json" <<EOF
{"messages":[
 {"id":"t1","sender_surface_id":"OLD-DESK-A","recipient_surface_id":"S1","state":"queued","read_at":null,"body":"a test, reply with --reply-to"},
 {"id":"r0","sender_surface_id":"OLD-DESK-A","recipient_surface_id":"S2","state":"read","read_at":5,"body":"done-request: earlier"},
 {"id":"t2","sender_surface_id":"OLD-DESK-B","recipient_surface_id":"S1","state":"delivered","read_at":null,"body":"hand-written notice"},
 {"id":"k1","sender_surface_id":"S9","recipient_surface_id":"S1","state":"queued","read_at":null,"body":"peer message"},
 {"id":"k2","sender_surface_id":"OLD-DESK-A","recipient_surface_id":"$DESK","state":"queued","read_at":null,"body":"to the desk now"}]}
EOF
  CMUX_PANEL_ID="$DESK" run python3 "$BRIEF" patrol --read
  [ "$status" -eq 0 ]
  [ "$(cat "$STUB/marked")" = '{"ids": ["t1", "t2"]}' ]
  [[ "$output" == *'"ev":"retired","count":2'* ]]
  rm "$STUB/marked"
  CMUX_PANEL_ID="$DESK" run python3 "$BRIEF" patrol --read
  [ ! -e "$STUB/marked" ]
}
