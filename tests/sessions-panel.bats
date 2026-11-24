#!/usr/bin/env bats
# Sessions panel: TODO and Running are separate states. A TODO session that is working
# stays in the TODO group with its number and carries a "작업 중" marker.

TPL="$BATS_TEST_DIRNAME/../cmux/sidebars/sessions.js"
HARNESS="$BATS_TEST_DIRNAME/helpers/sessions-panel.js"
PLAN='{"at":1000,"items":[{"panel":"P1","do":"first task","done":false}]}'

ws() {  # $1 status of P1, $2 status of P2
  echo "[{\"id\":\"W\",\"title\":\"w\",\"tabs\":[{\"id\":\"P1\",\"title\":\"one\"},{\"id\":\"P2\",\"title\":\"two\"}],\"agents\":[{\"panelId\":\"P1\",\"status\":\"$1\",\"kind\":\"claude\",\"lastActivityAt\":1000},{\"panelId\":\"P2\",\"status\":\"$2\",\"kind\":\"claude\",\"lastActivityAt\":1000}]}]"
}

entries() { node "$HARNESS" "$TPL" "$PLAN" "$(ws "$1" "$2")" 1100; }

@test "working TODO session stays in TODO with its number and a working marker" {
  run entries working working
  [ "$status" -eq 0 ]
  row=$(echo "$output" | grep '"title":"one"')
  [[ "$row" == *'"group":-1'* ]]
  [[ "$row" == *'"num":"①"'* ]]
  [[ "$row" == *'"todo":"first task"'* ]]
  [[ "$row" == *'"busy":true'* ]]
  # the non-TODO working session is still under Running, without the TODO marker
  two=$(echo "$output" | grep '"title":"two"')
  [[ "$two" == *'"group":1'* ]]
  [[ "$two" == *'"busy":false'* ]]
}

@test "idle TODO session has no working marker" {
  run entries idle idle
  [ "$status" -eq 0 ]
  row=$(echo "$output" | grep '"title":"one"')
  [[ "$row" == *'"group":-1'* ]]
  [[ "$row" == *'"busy":false'* ]]
}

@test "row renders the working label and the header counts busy TODO rows as running" {
  grep -q 'e().busy ? "작업 중"' "$TPL"
  grep -q 'x.group === 1 || x.busy' "$TPL"
}

@test "header counts a collab member once, though it also shows in the Collab group" {
  teams='[{"name":"pair","last":null,"members":[{"panel":"P1","agent":"claude"},{"panel":"P2","agent":"codex"}]}]'
  run node "$HARNESS" "$TPL" '{"at":0,"items":[]}' "$(ws idle working)" 1100 "$teams"
  [ "$status" -eq 0 ]
  # both sessions appear twice (own group + Collab) ...
  [ "$(echo "$output" | grep -c '"kind":"agent"')" -eq 4 ]
  # ... but the header counts two sessions
  [ "$(echo "$output" | grep '^HEADER')" = "HEADER 1 running · 2 sessions" ]
}
