#!/usr/bin/env bats
# brief send / brief done: the desk's one path to hand work to an open session.
# An idle pane gets the text typed in (pane-deliver); a busy or approval pane gets a cmux message,
# unless cmux does not know the pane's agent (a session older than a cmux restart, 11-23), when a
# busy pane gets the text in its input queue instead. Every outcome says which one happened.
# cmux and pane-deliver are stubbed; no live pane is touched.

BRIEF="$BATS_TEST_DIRNAME/../cmux/brief"
A=AAAA-PANEL
B=BBBB-PANEL
DESK=DESK-PANEL

setup() {
  export HOME="$BATS_TEST_TMPDIR/home"
  mkdir -p "$HOME/.claude/projects/p" "$HOME/bin" "$HOME/.cache/cmux"
  export BRIEF_CMUX="$HOME/bin/cmux" BRIEF_DESK_PANEL="$DESK" BRIEF_PATROL_MIN=0 CMUX_PANEL_ID="$DESK"
  export BRIEF_DELIVER="$HOME/bin/pane-deliver" STUB="$HOME/stub"; mkdir -p "$STUB"
  state idle
  cat > "$BRIEF_CMUX" <<'EOF'
#!/usr/bin/env bash
printf 'cmux' >> "$STUB/calls"; printf ' [%s]' "$@" >> "$STUB/calls"; echo >> "$STUB/calls"
case "$1 $2" in
  "current --json") cat "$STUB/current.json" ;;
  "agent inbox") echo '{"messages":[]}' ;;
  "agent message")
    printf '{"id":"m1","state":"%s","recipient_has_agent":%s}\n' "${STUB_MSG_STATE:-queued}" "${STUB_HAS_AGENT:-true}" ;;
  "list-workspaces --json") echo '{"workspaces":[]}' ;;
  *) : ;;
esac
EOF
  # pane-deliver stub: exit STUB_RC (STUB_QUEUE_RC under --queue), echo what it was asked to type.
  cat > "$BRIEF_DELIVER" <<'EOF'
#!/usr/bin/env bash
printf 'deliver' >> "$STUB/calls"; printf ' [%s]' "$@" >> "$STUB/calls"; echo >> "$STUB/calls"
rc="${STUB_RC:-0}"; [[ " $* " == *" --queue "* ]] && rc="${STUB_QUEUE_RC:-0}"
echo "TYPED: ${*: -1}"
[ "$rc" -eq 0 ] && echo "DELIVERED: stub" || echo "UNCONFIRMED: stub" >&2
exit "$rc"
EOF
  chmod +x "$BRIEF_CMUX" "$BRIEF_DELIVER"
}

state() {  # $1 the session's cmux state; panel B is open but cmux lists no agent for it
  cat > "$STUB/current.json" <<EOF
{"items":[
 {"label":"Task A","cwd":"$HOME","agents":[{"kind":"claude","state":"$1","session_id":"sid-a","last_activity_at":"2026-11-19T02:10:00Z"}],"projections":[{"panel_id":"$A","workspace_id":"W1"}]},
 {"label":"Old session","cwd":"$HOME","agents":[],"projections":[{"panel_id":"$B","workspace_id":"W2"}]}]}
EOF
}

@test "send: an idle pane gets the text typed in, marked as the desk's" {
  run python3 "$BRIEF" send "$A" "please rebase on main"
  [ "$status" -eq 0 ]
  [[ "$output" == "전달됨: "*"Task A" ]]
  grep -qF "deliver [--surface] [$A] [--workspace] [W1] [--] [desk-message: please rebase on main]" "$STUB/calls"
  ! grep -q "agent.*message" "$STUB/calls"
}

@test "send: a pane cmux lists without an agent is still reachable by panel id" {
  run python3 "$BRIEF" send "$B" "decision: go with option b"
  [ "$status" -eq 0 ]
  [[ "$output" == "전달됨: "*"Old session" ]]
  grep -qF "deliver [--surface] [$B] [--workspace] [W2]" "$STUB/calls"
}

@test "send: a working session gets a cmux message, not typed text" {
  state working
  run python3 "$BRIEF" send "$A" "also check the tests"
  [ "$status" -eq 0 ]
  [[ "$output" == "대기열: 일하는 중이라 cmux 메시지로"* ]]
  ! grep -q "^deliver" "$STUB/calls"
  grep -qF "[agent] [message] [$A] [--json] [--] [desk-message: also check the tests]" "$STUB/calls"
}

@test "send: busy and cmux does not know the agent (pre-restart session) goes to the input queue" {
  export STUB_RC=4 STUB_HAS_AGENT=false
  run python3 "$BRIEF" send "$A" "x"
  [ "$status" -eq 0 ]
  [[ "$output" == "대기열: 일하는 중이고 cmux 가 이 pane 의 에이전트를 모릅니다"* ]]
  grep -q "^deliver.*\[--queue\]" "$STUB/calls"
}

@test "send: an approval screen and an unknown agent is reported as not delivered" {
  export STUB_RC=3 STUB_HAS_AGENT=false
  run python3 "$BRIEF" send "$A" "x"
  [ "$status" -eq 1 ]
  [[ "$output" == "전달 못 함: 승인 대기 화면입니다"* ]]
  ! grep -q "\[--queue\]" "$STUB/calls"
}

@test "send: an unconfirmed submit that reached the transcript counts (narrow panes draw no spinner)" {
  export STUB_RC=5
  now="$(python3 -c 'import time;print(time.strftime("%Y-%m-%dT%H:%M:%S.000Z",time.gmtime(time.time()+2)))')"
  printf '{"type":"queue-operation","operation":"enqueue","timestamp":"%s","content":"desk-message: hello there"}\n' "$now" \
    > "$HOME/.claude/projects/p/sid-a.jsonl"
  run python3 "$BRIEF" send "$A" "hello there"
  [ "$status" -eq 0 ]
  [[ "$output" == "대기열: 세션이 일하는 중이라 Claude 가 입력 대기열에"* ]]
}

@test "send: an unconfirmed submit not in the transcript is not delivered" {
  export STUB_RC=5
  run python3 "$BRIEF" send "$A" "hello there"
  [ "$status" -eq 1 ]
  [[ "$output" == "전달 못 함: UNCONFIRMED"* ]]
}

@test "done: the done-request goes the same way and keeps its own marker" {
  run python3 "$BRIEF" done "$A"
  [ "$status" -eq 0 ]
  [[ "$output" == "완료 검토 요청 보냄: Task A — 전달됨"* ]]
  grep -qF "[--] [done-request: " "$STUB/calls"
}

@test "--help after any command prints usage and sends nothing (11-23: brief report --help)" {
  for c in report note send done; do
    run python3 "$BRIEF" "$c" --help
    [ "$status" -eq 0 ]
    [[ "$output" == *"brief report <글|->"* ]]
  done
  [ ! -e "$STUB/calls" ] || ! grep -q "message\|^deliver" "$STUB/calls"
  [ ! -e "$HOME/.cache/cmux/brief-reports.jsonl" ]
  [ ! -e "$HOME/.cache/cmux/brief-notes.jsonl" ]
}
