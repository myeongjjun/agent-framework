#!/usr/bin/env bats
# brief tree: the agent control structure (user → desk → area → session), who spawned each session,
# what it waits for, and the live event feed. Runs against a fake HOME and a fake cmux.

BRIEF="$BATS_TEST_DIRNAME/../cmux/brief"
DESK=DESK-PANEL A=AAAA-PANEL B=BBBB-PANEL C=CCCC-PANEL

setup() {
  export HOME="$BATS_TEST_TMPDIR/home"
  mkdir -p "$HOME/bin" "$HOME/.cache/cmux" "$HOME/.config/cmux" "$HOME/.local/share/sib/state" "$HOME/tools" "$HOME/data"
  export BRIEF_CMUX="$HOME/bin/cmux" BRIEF_DESK_PANEL="$DESK" BRIEF_SIB_STATE="$HOME/.local/share/sib/state"
  export BRIEF_DESK_DIR="$HOME/.local/share/cmux/desk" BRIEF_OFFICE_ART=0  # no real Codex art panes from the test server
  export STUB="$HOME/stub"; mkdir -p "$STUB"
  cat > "$HOME/.config/cmux/orch-areas.md" <<'EOF'
# orch area profiles
## A. Tools
### Scope
- Covers: `~/tools`, `brief`.
### Permissions
| kind | level |
|---|---|
| place | decide |
| commit | decide |
### Trial
- Stage: 1
EOF
  cat > "$HOME/.config/cmux/orch-local.md" <<'EOF'
- Ask-first areas (these override Do it, then report):
  - WidgetDB: any task about WidgetDB (the skills `wdb-ops`, `widgetdb-*`).
- Something else
EOF
  item() { printf '{"label":"%s","cwd":"%s","agents":[{"kind":"claude","state":"%s","session_id":"sid-%s","last_activity_at":"2026-11-23T10:00:00Z"}],"projections":[{"panel_id":"%s","workspace_id":"W1"}]}' "$@"; }
  printf '{"items":[%s,%s,%s,%s]}' \
    "$(item Desk "$HOME/desk" idle d $DESK)" \
    "$(item "Tool work" "$HOME/tools" working a $A)" \
    "$(item "WidgetDB TTL check" "$HOME/data" idle b $B)" \
    "$(item "Tool worker" "$HOME/tools/wt" idle c $C)" > "$STUB/current.json"
  printf '{"messages":[{"id":"m1","created_at":%s,"sender_surface_id":"%s","recipient_surface_id":"%s","state":"delivered","body":"desk-message: do the thing"}]}' \
    "$(date +%s)" "$DESK" "$A" > "$STUB/inbox.json"
  # A spawned by the desk; C spawned by A as a /collab worker (worktree); B has no sib record (the user opened it).
  printf 'slug=tool-work\nagent=claude\nsurface=surface:2\nworktree_managed=0\nspawner_surface=surface:1\n' > "$BRIEF_SIB_STATE/tool-work.env"
  printf 'slug=tool-claude\nagent=claude\nsurface=surface:4\nworktree_managed=1\nspawner_surface=surface:2\n' > "$BRIEF_SIB_STATE/tool-claude.env"
  cat > "$BRIEF_CMUX" <<'EOF'
#!/usr/bin/env bash
echo "cmux $*" >> "$STUB/calls"
case "$1 $2" in
  "current --json")
    n=$(( $(cat "$STUB/n" 2>/dev/null || echo 0) + 1 )); echo $n > "$STUB/n"
    if [ -f "$STUB/current.next" ] && [ "$n" -ge 2 ]; then cat "$STUB/current.next"; else cat "$STUB/current.json"; fi ;;
  "agent inbox") cat "$STUB/inbox.json" ;;
  "rpc workspace.list") echo '{"workspaces":[{"id":"W1"}]}' ;;
  "rpc surface.list") echo '{"surfaces":[{"ref":"surface:1","id":"DESK-PANEL"},{"ref":"surface:2","id":"AAAA-PANEL"},{"ref":"surface:3","id":"BBBB-PANEL"},{"ref":"surface:4","id":"CCCC-PANEL"}]}' ;;
  "new-split right") echo "OK surface:9 workspace:1" ;;
  "list-windows ") echo "* 0: MAIN-WIN selected_workspace=W1 workspaces=1" ;;
  *) : ;;
esac
EOF
  chmod +x "$BRIEF_CMUX"
}

q() { python3 -c "import json,sys; d=json.load(sys.stdin); print($1)"; }

@test "tree: user → desk → areas; ask-first area first; spawner and nesting" {
  run python3 "$BRIEF" tree --json
  [ "$status" -eq 0 ]
  [ "$(echo "$output" | q 'd["desk"]["panel"]')" = "$DESK" ]
  [ "$(echo "$output" | q '[a["name"] for a in d["areas"]]')" = "['WidgetDB', 'A. Tools']" ]   # an empty 영역 밖 is not drawn
  [ "$(echo "$output" | q 'd["areas"][0]["sessions"][0]["title"]')" = "WidgetDB TTL check" ]
  [ "$(echo "$output" | q 'd["areas"][0]["sessions"][0]["spawned_by"]["kind"]')" = "user" ]
  [ "$(echo "$output" | q 'd["areas"][1]["decides"]')" = "데스크가 결정 · 시험 1단계" ]
  a='d["areas"][1]["sessions"][0]'
  [ "$(echo "$output" | q "$a[\"title\"]")" = "Tool work" ]
  [ "$(echo "$output" | q "$a[\"spawned_by\"][\"kind\"]")" = "desk" ]
  [ "$(echo "$output" | q "$a[\"waiting\"][\"who\"]")" = "none" ]          # working
  [ "$(echo "$output" | q "$a[\"children\"][0][\"title\"]")" = "Tool worker" ]
  [ "$(echo "$output" | q "$a[\"children\"][0][\"spawned_by\"][\"label\"]")" = "/collab: Tool work" ]
  [ "$(echo "$output" | q 'len(d["areas"][1]["sessions"])')" = "1" ]          # the worker is not listed twice
  # agent-to-agent message is an event
  [ "$(echo "$output" | q '[e["title"] for e in d["events"] if e["what"]=="msg"][0]')" = "데스크 → Tool work" ]
}

@test "tree: a session that sent its done-report waits for the desk's check; text view draws it" {
  CMUX_PANEL_ID=$C run python3 "$BRIEF" report "done-report: ready"
  [ "$status" -eq 0 ]
  grep -q '"what": "report"' "$HOME/.cache/cmux/brief-events.jsonl"
  run python3 "$BRIEF" tree --json
  [ "$(echo "$output" | q 'd["areas"][1]["sessions"][0]["children"][0]["waiting"]["who"]')" = "desk" ]
  run python3 "$BRIEF" tree
  [ "$status" -eq 0 ]
  [[ "$output" == *"👤 사용자"* ]]
  [[ "$output" == *"☀ 데스크"* ]]
  [[ "$output" == *"띄움: /collab: Tool work"* ]]
  [[ "$output" == *"기다림: 데스크의 대조"* ]]
  [[ "$output" == *"📮 완료 보고"* ]]
}

@test "tree: text lines fit the pane width; a long wait is cut with an ellipsis, --json keeps it whole" {
  CMUX_PANEL_ID=$C run python3 "$BRIEF" report "done-report: ready"
  run python3 "$BRIEF" tree --json
  [ "$(echo "$output" | q 'd["areas"][1]["sessions"][0]["children"][0]["waiting"]["label"]')" = "데스크의 대조 (완료 보고 보냄)" ]
  for w in 40 55 65; do
    run env COLUMNS=$w python3 "$BRIEF" tree
    [ "$status" -eq 0 ]
    [ "$w" -lt 55 ] || [[ "$output" == *"기다림: 데"*"…"* ]]
    widest=$(printf '%s\n' "$output" | python3 -c "import sys,unicodedata as u; print(max(sum(2 if u.east_asian_width(c) in 'WF' else 1 for c in l.rstrip('\n')) for l in sys.stdin))")
    [ "$widest" -le "$w" ]
  done
  # coloured lines are cut on visible width, and the colour is closed
  run python3 -c "
import importlib.machinery as m, importlib.util as u
l = m.SourceFileLoader('b', '$BRIEF'); b = u.module_from_spec(u.spec_from_loader('b', l)); l.exec_module(b)
print(repr(b.fit('\033[36m띄움\033[0m  \033[31m기다림: 사용자의 답: 아주 긴 글\033[0m', 20)))"
  [ "$output" = "'\x1b[36m띄움\x1b[0m  \x1b[31m기다림: 사용…\x1b[0m'" ]
}

@test "tree --watch: a pane that appears between frames shows up as a live event" {
  sed 's/"Tool worker"/"Tool worker"/' "$STUB/current.json" | python3 -c '
import json,sys; d=json.load(sys.stdin); x=json.loads(json.dumps(d["items"][2]))
x["label"]="Fresh session"; x["projections"][0]["panel_id"]="EEEE-PANEL"; d["items"].append(x); print(json.dumps(d))' > "$STUB/current.next"
  BRIEF_TREE_FRAMES=2 BRIEF_TREE_INTERVAL=0.1 run python3 "$BRIEF" tree --watch
  [ "$status" -eq 0 ]
  [[ "$output" == *"🚀 새 세션  Fresh session"* ]]
}

@test "tree --toggle: first call opens the watch pane, second closes it" {
  run python3 "$BRIEF" tree --toggle
  [ "$status" -eq 0 ]
  grep -q 'new-split right --command .*tree --watch' "$STUB/calls"
  run python3 "$BRIEF" tree --toggle
  [[ "$output" == *"닫았습니다"* ]]
  grep -q 'close-surface --surface surface:9' "$STUB/calls"
  [ ! -f "$HOME/.cache/cmux/brief-tree-pane.json" ]
}

@test "tree --popup: starts the office server and an app-mode browser; second call stops both" {
  printf '#!/usr/bin/env bash\necho "$@" > "%s/chrome-args"\nexec sleep 60\n' "$STUB" > "$HOME/bin/chrome"; chmod +x "$HOME/bin/chrome"
  BRIEF_CHROME="$HOME/bin/chrome" run python3 "$BRIEF" tree --popup
  [ "$status" -eq 0 ]
  [[ "$output" == *"열었습니다"* ]]
  st="$HOME/.cache/cmux/brief-tree-popup.json"
  url=$(python3 -c "import json;print(json.load(open('$st'))['url'])")
  srv=$(python3 -c "import json;print(json.load(open('$st'))['server'])")
  br=$(python3 -c "import json;print(json.load(open('$st'))['browser'])")
  for i in $(seq 30); do [ -f "$STUB/chrome-args" ] && break; sleep 0.1; done
  grep -q -- "--app=$url" "$STUB/chrome-args"
  [ "$(curl -s --noproxy '*' -o /dev/null -w '%{http_code}' "$url")" = "200" ]
  kill -0 "$srv"; kill -0 "$br"
  run python3 "$BRIEF" tree --popup
  [[ "$output" == *"닫았습니다"* ]]
  [ ! -f "$st" ]
  sleep 0.5
  ! kill -0 "$srv" 2>/dev/null
  ! kill -0 "$br" 2>/dev/null
}

@test "tree --serve: the office page, its art, /data and click-to-go; nothing outside the office folder" {
  port=$(python3 -c 'import socket;s=socket.socket();s.bind(("127.0.0.1",0));print(s.getsockname()[1])')
  printf '#!/bin/sh\n' > "$HOME/bin/ps"; chmod +x "$HOME/bin/ps"   # no background agents on the test machine
  printf '#!/bin/sh\n' > "$HOME/bin/open"; chmod +x "$HOME/bin/open"   # do not raise the real cmux app
  PATH="$HOME/bin:$PATH" python3 "$BRIEF" tree --serve --port "$port" 3>&- &
  pid=$!
  for i in $(seq 50); do curl -s --noproxy '*' "127.0.0.1:$port/" >/dev/null && break; sleep 0.1; done
  page=$(curl -s --noproxy '*' "127.0.0.1:$port/")
  art=$(curl -s --noproxy '*' -o /dev/null -w '%{http_code} %{content_type}' "127.0.0.1:$port/art/claude-working.svg")
  escape=$(curl -s --noproxy '*' --path-as-is -o /dev/null -w '%{http_code}' "127.0.0.1:$port/art/../../brief")
  data=$(curl -s --noproxy '*' "127.0.0.1:$port/data")
  go=$(curl -s --noproxy '*' -X POST -d '{"panel":"aaaa-panel"}' -w ' %{http_code}' "127.0.0.1:$port/go")
  stranger=$(curl -s --noproxy '*' -X POST -d '{"panel":"ZZZZ"}' -w ' %{http_code}' "127.0.0.1:$port/go")
  kill $pid
  [ "$go" = "ok 200" ]                                            # click on a worker → its cmux pane
  grep -q 'cmux focus-window --window MAIN-WIN' "$STUB/calls"
  grep -q 'cmux focus-panel --panel AAAA-PANEL --workspace W1 --window MAIN-WIN' "$STUB/calls"
  [ "$stranger" = "열린 세션이 아님 400" ]                          # only open sessions can be focused
  [[ "$page" == *"에이전트 사무실"* ]]
  [ "$art" = "200 image/svg+xml" ]
  [ "$escape" = "404" ]
  [ "$(echo "$data" | q 'd["stats"]["sessions"]')" = "3" ]
  [ "$(echo "$data" | q 'd["stats"]["working"]')" = "1" ]
  [ "$(echo "$data" | q 'd["tree"]["areas"][1]["sessions"][0]["children"][0]["spawned_by"]["label"]')" = "/collab: Tool work" ]
  [ "$(echo "$data" | q '[e["what"] for e in d["events"]]')" = "['msg']" ]
}

@test "tree: helper agents — a second agent in a pane, a background codex exec traced to its session, and one outside cmux" {
  run python3 - "$BRIEF" <<'PY'
import importlib.machinery, types, json, sys
p = sys.argv[1]; l = importlib.machinery.SourceFileLoader("brief", p); m = types.ModuleType("brief"); m.__file__ = p; l.exec_module(m)
ss = [{"panel": "AAAA-PANEL", "session": "11111111-1111-1111-1111-111111111111", "title": "Tool work"}]
cur = {"items": [{"projections": [{"panel_id": "AAAA-PANEL"}], "agents": [
    {"kind": "claude", "state": "working"}, {"kind": "codex", "state": "working"}, {"kind": "codex", "state": "ended"}]}]}
ps = "\n".join([
    "100 1 /Users/x/.local/bin/claude --session-id 11111111-1111-1111-1111-111111111111 --settings s.json",
    "101 100 /bin/zsh -c codex exec",
    "102 101 /opt/homebrew/bin/codex exec -s workspace-write -c model_reasoning_effort=high Draw the office art",
    "103 102 /opt/homebrew/bin/codex exec -s workspace-write Draw the office art",
    "200 1 /Applications/ChatGPT.app/Contents/MacOS/ChatGPT",
    "201 200 /Applications/ChatGPT.app/x/codex exec --json",
    "300 1 /Users/x/.codex/bin/codex app-server --listen stdio://",
    "400 1 /Users/x/.local/bin/claude --session-id 22222222-2222-2222-2222-222222222222"])
for h in m.helper_agents(ss, ps_out=ps, current=cur):
    print(h["kind"], h["host"], h["origin"], h["label"], sep="|")
PY
  [ "$status" -eq 0 ]
  [ "${#lines[@]}" -eq 3 ]                                       # ended agent, app-server and plain sessions are not helpers
  [[ "$output" == *"codex|AAAA-PANEL|pane|codex (같은 pane)"* ]]
  [[ "$output" == *"codex|AAAA-PANEL|세션이 띄움|Draw the office art"* ]]   # wrapper + child count once
  [[ "$output" == *"codex|None|ChatGPT 앱|codex 실행"* ]]
}

@test "tree: power — today's Claude/Codex tokens, per-minute flow, per-session, live subagents; only new lines on the next scan" {
  now=$(date -u +%Y-%m-%dT%H:%M:%SZ)
  P="$HOME/.claude/projects/-x"; mkdir -p "$P/sid-a/subagents"
  u='{"input_tokens":10,"output_tokens":5,"cache_read_input_tokens":100,"cache_creation_input_tokens":0}'
  # the same message written three times (streamed blocks) counts once
  for i in 1 2 3; do printf '{"type":"assistant","timestamp":"%s","message":{"id":"m1","usage":%s}}\n' "$now" "$u" >> "$P/sid-a.jsonl"; done
  printf '{"type":"assistant","timestamp":"%s","message":{"id":"s1","usage":%s}}\n' "$now" "$u" > "$P/sid-a/subagents/agent-x.jsonl"
  echo '{"agentType":"Explore","description":"Find the cable","finished":false}' > "$P/sid-a/subagents/agent-x.meta.json"
  C="$HOME/.codex/sessions/$(date +%Y/%m/%d)"; mkdir -p "$C"
  { printf '{"timestamp":"%s","type":"session_meta","payload":{"id":"cx-1"}}\n' "$now"
    printf '{"timestamp":"%s","type":"event_msg","payload":{"type":"token_count","info":{"total_token_usage":{"total_tokens":1000}},"rate_limits":{"plan_type":"plus","primary":{"used_percent":40}}}}\n' "$now"
    printf '{"timestamp":"%s","type":"event_msg","payload":{"type":"token_count","info":{"total_token_usage":{"total_tokens":1500}},"rate_limits":{"plan_type":"plus","primary":null}}}\n' "$now"
  } > "$C/rollout-x.jsonl"
  printf '{"at":1,"rate_limits":{"five_hour":{"used_percentage":12.5,"resets_at":1795440000},"seven_day":{"used_percentage":3}}}' > "$HOME/.cache/cmux/claude-limits.json"
  run python3 - "$BRIEF" <<'PY'
import importlib.machinery, types, json, sys
p = sys.argv[1]; l = importlib.machinery.SourceFileLoader("brief", p); m = types.ModuleType("brief"); m.__file__ = p; l.exec_module(m)
pw = {}
r = m.power_scan(pw)
print(json.dumps(r, sort_keys=True))
r = m.power_scan(pw)                     # nothing new: totals stay
print(r["claude"]["today"], r["codex"]["today"])
PY
  [ "$status" -eq 0 ]
  first=$(echo "${lines[0]}")
  [ "$(echo "$first" | q 'd["claude"]["today"]')" = "230" ]          # m1 once + subagent s1
  [ "$(echo "$first" | q 'd["codex"]["today"]')" = "1500" ]
  [ "$(echo "$first" | q 'd["codex"]["limits"]["codex"]["primary"]["used"]')" = "40" ]   # per Codex home
  [ "$(echo "$first" | q 'd["sessions"]["sid-a"]')" = "230" ]       # subagent tokens go to its host session
  [ "$(echo "$first" | q 'd["sessions"]["cx-1"]')" = "1500" ]
  [ "$(echo "$first" | q 'd["subagents"][0]["label"]')" = "Find the cable" ]
  [ "${lines[1]}" = "230 1500" ]
  [ "$(echo "$first" | q 'd["claude"]["limits"]["claude"]["primary"]["used"]')" = "12.5" ]   # from the status line file
  [ "$(echo "$first" | q 'd["claude"]["limits"]["claude"]["secondary"]["used"]')" = "3" ]
}

@test "tree: a pane from yesterday's desk reads as the desk; committee panes meet in their own room by name and role" {
  # D was spawned by a closed surface (yesterday's desk): its sib output is in the desk's transcript.
  # E is a committee member pane started by A (agent-scout): own meeting room, named member · round, role scout-redteam.
  printf '{"items":[%s,%s,%s,%s]}' \
    "$(item Desk "$HOME/desk" idle d $DESK)" \
    "$(item "Tool work" "$HOME/tools" working a $A)" \
    "$(item "Old desk work" "$HOME/tools" idle e DDDD-PANEL)" \
    "$(item "You are a member of the agent scouting committee" "$HOME/tools" working f EEEE-PANEL)" > "$STUB/current.json"
  printf 'slug=old-work\nagent=claude\nsurface=surface:5\nworktree_managed=0\nspawner_surface=surface:99\n' > "$BRIEF_SIB_STATE/old-work.env"
  mkdir -p "$HOME/meet"; printf '=== draft `tool-builder` ===\nbody\n=== end of `tool-builder` ===\n' > "$HOME/meet/task.md"
  printf 'slug=scout-redteam-evaluate-42\nagent=codex\nsurface=surface:6\nworktree_managed=0\nspawner_surface=surface:2\nworkdir=%s\n' "$HOME/meet" > "$BRIEF_SIB_STATE/scout-redteam-evaluate-42.env"
  sed -i '' 's/{"ref":"surface:4","id":"CCCC-PANEL"}/{"ref":"surface:5","id":"DDDD-PANEL"},{"ref":"surface:6","id":"EEEE-PANEL"}/' "$BRIEF_CMUX"
  proj="$HOME/.claude/projects/$(python3 -c 'import re,sys;print(re.sub(r"[^A-Za-z0-9]","-",sys.argv[1]))' "$HOME/.local/share/cmux/desk")"
  mkdir -p "$proj" "$HOME/.claude/agents"
  echo '{"x":"sib spawn old-work → W1 surface:5 [booted]"}' > "$proj/s1.jsonl"
  printf -- '---\nname: scout-redteam\ndescription: Red-team reviewer.\n---\nbody\n' > "$HOME/.claude/agents/scout-redteam.md"
  run python3 "$BRIEF" tree --json
  [ "$status" -eq 0 ]
  [ "$(echo "$output" | q '[a["name"] for a in d["areas"]]')" = "['WidgetDB', 'A. Tools', '위원회 회의 42']" ]
  [ "$(echo "$output" | q '[s["spawned_by"]["label"] for s in d["areas"][1]["sessions"] if s["panel"]=="DDDD-PANEL"][0]')" = "데스크 (지난 데스크)" ]
  [ "$(echo "$output" | q 'd["areas"][2]["sessions"][0]["name"]')" = "redteam · evaluate" ]
  [ "$(echo "$output" | q 'd["areas"][2]["sessions"][0]["role"]')" = "scout-redteam" ]
  [ "$(echo "$output" | q 'd["areas"][2]["decides"]')" = "소집: Tool work · evaluate" ]
  [ "$(echo "$output" | q 'd["areas"][2]["topic"]')" = "초안 심사: tool-builder" ]   # what the meeting is about, from the member's task
  grep -q '"surface:99": true' "$HOME/.cache/cmux/brief-desk-refs.json"
}

@test "tree: the first input of a pane another agent spawned is work handed over, not the user typing" {
  now=$(date +%s)
  printf '{"at":%s,"what":"new","panel":"%s","title":"Tool work"}\n{"at":%s,"what":"input","panel":"%s","title":"Tool work"}\n{"at":%s,"what":"input","panel":"%s","title":"WidgetDB TTL check"}\n' \
    "$now" "$A" "$((now+2))" "$A" "$((now+3))" "$B" > "$HOME/.cache/cmux/brief-events.jsonl"
  run python3 "$BRIEF" tree --json
  [ "$(echo "$output" | q '[(e["what"], e["panel"]) for e in d["events"] if e["what"] in ("input","handoff")]')" = "[('handoff', 'AAAA-PANEL'), ('input', 'BBBB-PANEL')]" ]
}

@test "office art: a role with no prop goes to one Codex pane; a checked SVG is kept, a bad one is not, the pane is closed" {
  export BRIEF_ROLE_ART="$HOME/art" BRIEF_SIB="$HOME/bin/sib" BRIEF_OFFICE_ART=1
  printf '#!/bin/sh\necho "sib $*" >> "%s/sib-calls"\n' "$STUB" > "$HOME/bin/sib"; chmod +x "$HOME/bin/sib"
  run python3 - "$BRIEF" <<'PY'
import importlib.machinery, types, os, sys
p = sys.argv[1]; l = importlib.machinery.SourceFileLoader("brief", p); m = types.ModuleType("brief"); m.__file__ = p; l.exec_module(m)
job = m.art_step({"scout-redteam": "Red team.", "scout-replay": "Replay."}, now=1000)
assert job and job["roles"] == ["scout-redteam", "scout-replay"], job
assert "Red team." in open(os.path.join(job["dir"], "task.md")).read()
good = '<svg xmlns="http://www.w3.org/2000/svg" width="40" height="40" viewBox="0 0 40 40"><circle cx="20" cy="20" r="9" fill="#d6453d"/></svg>'
bad = '<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 40 40"><image href="https://x/y.png"/></svg>'
open(os.path.join(job["dir"], "scout-redteam.svg"), "w").write(good)
open(os.path.join(job["dir"], "scout-replay.svg"), "w").write(bad)
assert m.art_step({"scout-redteam": "", "scout-replay": ""}, now=1100)  # one still missing: the pane stays
assert sorted(m.role_art_have()) == ["scout-redteam"]
assert m.art_step({"scout-redteam": "", "scout-replay": ""}, now=1000 + 1300) is None  # timeout: pane closed, replay not retried today
assert m.art_step({"scout-redteam": "", "scout-replay": ""}, now=1000 + 90000)  # next day: asked again
print("ok")
PY
  [ "$status" -eq 0 ]
  [ "${lines[-1]}" = "ok" ]
  grep -q 'sib spawn office-art-1000 --codex --no-report --workdir .*/art/jobs/office-art-1000 --new-workspace -- Read task.md' "$STUB/sib-calls"
  grep -q 'sib kill office-art-1000' "$STUB/sib-calls"
  [ "$(grep -c 'sib spawn' "$STUB/sib-calls")" = "2" ]
}

@test "tree: a session's role is the agent definition its process runs with (--agent), not a word in its slug" {
  printf -- '---\nname: tool-maker\ndescription: Makes tools.\n---\n' > "$HOME/.claude/agents/tool-maker.md" 2>/dev/null || { mkdir -p "$HOME/.claude/agents"; printf -- '---\nname: tool-maker\ndescription: Makes tools.\n---\n' > "$HOME/.claude/agents/tool-maker.md"; }
  printf 'slug=tool-maker-brief\nagent=claude\nsurface=surface:3\nworktree_managed=0\nspawner_surface=surface:1\n' > "$BRIEF_SIB_STATE/tool-maker-brief.env"
  printf '#!/bin/sh\necho "/x/claude --session-id sid-a --settings s.json --agent tool-maker"\n' > "$HOME/bin/ps"; chmod +x "$HOME/bin/ps"
  PATH="$HOME/bin:$PATH" run python3 "$BRIEF" tree --json
  [ "$(echo "$output" | q '{s["panel"]: s["role"] for a in d["areas"] for s in a["sessions"]}')" = "{'BBBB-PANEL': None, 'AAAA-PANEL': 'tool-maker'}" ]
}

@test "office archive: finished committee meetings stay listed with results and what became of each role" {
  hr="$HOME/.local/share/cmux/hr"; mkdir -p "$hr/agents"
  echo '{"date":"2026-11-23","period":["2026-11-03","2026-11-23"],"scouts":[{"name":"a","model":"opus","error":"spawn failed"}],"candidates":[]}' > "$hr/failed-convene-2026-11-23.json"
  echo '{"date":"2026-11-24","period":["2026-11-04","2026-11-24"],"scouts":[{"name":"a","model":"opus","error":null}],"candidates":[{"kind":"ops","role":"rev","result":"pass","support":2,"backers":["a","b"]},{"kind":"x","role":"gone","result":"watch","support":1,"backers":["a"]}]}' > "$hr/quorum-2026-11-24.json"
  echo '{"id":"eval-2026-11-24-1","members":[{"name":"a","model":"opus"}],"results":{"rev":{"result":"revise","counts":{"hire":1,"revise":4,"reject":0}},"old":{"result":"approve","counts":{"hire":3}}}}' > "$hr/eval-2026-11-24-1.json"
  echo '# 회의록' > "$hr/eval-2026-11-24-1.md"
  touch -t 202611230900 "$hr/failed-convene-2026-11-23.json"; touch -t 202611240900 "$hr/quorum-2026-11-24.json"; touch -t 202611241000 "$hr/eval-2026-11-24-1.json"
  echo x > "$hr/agents/rev.md"
  printf '## Roles\n- old | agent | L2 | A | 상태: 수습 | 시작 11-24\n## Log\n- 11-24 | gone | merged | into rev | by:user\n' > "$HOME/.config/cmux/orch-roster.md"
  port=$(python3 -c 'import socket;s=socket.socket();s.bind(("127.0.0.1",0));print(s.getsockname()[1])')
  printf '#!/bin/sh\n' > "$HOME/bin/ps"; chmod +x "$HOME/bin/ps"
  printf '#!/bin/sh\n' > "$HOME/bin/open"; chmod +x "$HOME/bin/open"
  PATH="$HOME/bin:$PATH" python3 "$BRIEF" tree --serve --port "$port" 3>&- &
  pid=$!
  for i in $(seq 50); do curl -s --noproxy '*' "127.0.0.1:$port/" >/dev/null && break; sleep 0.1; done
  arc=$(curl -s --noproxy '*' "127.0.0.1:$port/archive")
  md=$(curl -s --noproxy '*' "127.0.0.1:$port/archive/eval-2026-11-24-1.md")
  esc1=$(curl -s --noproxy '*' --path-as-is -o /dev/null -w '%{http_code}' "127.0.0.1:$port/archive/../../../.config/cmux/orch-roster.md")
  esc2=$(curl -s --noproxy '*' -o /dev/null -w '%{http_code}' "127.0.0.1:$port/archive/quorum-2026-11-24.json")
  page=$(curl -s --noproxy '*' "127.0.0.1:$port/")
  kill $pid
  a() { echo "$arc" | python3 -c "import json,sys;d=[m for m in json.load(sys.stdin) if not m.get('record')];print($1)"; }
  [ "$(echo "$arc" | python3 -c "import json,sys;print([m['what']+' '+m['topic'] for m in json.load(sys.stdin) if m.get('record')])")" = "['합쳐짐 gone']" ]
  [ "$(a 'len(d)')" = "3" ]
  [ "$(a 'd[0]["id"]')" = "eval-2026-11-24-1" ]                       # newest first
  [ "$(a 'd[0]["items"][0]["result"]+"|"+d[0]["items"][0]["fate"]')" = "수정|초안 · 투입 전" ]
  [ "$(a 'd[0]["items"][1]["fate"]')" = "투입 · 수습" ]                 # roster Roles
  [ "$(a 'd[1]["items"][1]["fate"]')" = "합쳐짐 — into rev" ]           # roster Log
  [ "$(a 'd[2]["failed"]')" = "True" ]                                  # a failed meeting is kept, marked
  [ "$(a 'd[2]["what"]')" = "새 에이전트 발굴 (실패)" ]
  [ "$md" = "# 회의록" ]
  [ "$esc1" = "404" ] && [ "$esc2" = "404" ]                            # only .md in the hr folder
  [[ "$page" == *"기록 보관소"* ]]
}

@test "office members: current and former committee members with history, metrics and activity" {
  hr="$HOME/.local/share/cmux/hr"; mkdir -p "$hr"
  printf '## Members\n| member | runner | agent | model | approach | evidence | status | rounds |\n|---|---|---|---|---|---|---|---|\n| pstack | claude | scout-pstack | opus | slices | corrections | on | propose,evaluate |\n## Judge\n- judge: claude:fable   # blind\n' > "$HOME/.config/cmux/agent-committee.md"
  printf '## Committee\n- pstack | claude:opus | scout-pstack | 접근: slices | 상태: 수습 | 시작 11-23 | 판정 12-07\n' > "$HOME/.config/cmux/orch-roster.md"
  echo '{"scouts":[{"name":"volume","model":"opus","error":null}],"proposals":{"volume":[{"kind":"ops","role":"rev"}]},"candidates":[{"kind":"ops","role":"rev","result":"pass","support":2,"backers":["volume"]}],"judge":{"grades":[{"member":"volume","kind":"ops","evidence":2,"fit":1}]}}' > "$hr/pilot-panel-2026-11-23.json"
  echo '{"id":"eval-2026-11-24-1","members":[{"name":"pstack","model":"opus"}],"results":{"rev":{"result":"revise","reviews":[{"member":"pstack","verdict":"hire","grounded":2}]}}}' > "$hr/eval-2026-11-24-1.json"
  run python3 - "$BRIEF" <<'PY'
import importlib.machinery, importlib.util, sys, json
l = importlib.machinery.SourceFileLoader("brief", sys.argv[1]); s = importlib.util.spec_from_loader("brief", l)
b = importlib.util.module_from_spec(s); l.exec_module(b)
ms = b.committee_members(measure=lambda n: {"runs": 1})
for m in ms:
    print(m["name"], m["current"], m.get("roster", ""), m.get("since", ""), m["agree"], m["metrics"]["runs"], "|", " ; ".join(x for a in m["activity"] for x in a["did"]))
PY
  [ "$status" -eq 0 ]
  [ "${lines[0]}" = "pstack True 수습 11-23 0/1 1 | rev: 채용 (최종 수정, 근거 점수 2/2)" ]
  [[ "${lines[1]}" == "judge True "* ]]
  [ "${lines[2]}" = "volume False    1 | 제안 rev → 통과 (심판 근거 2·적합 1)" ]   # a former member stays, from the records
}

@test "office org chart: every agent in one chart — areas, committee, drafts, retired — with contract, start and retire reasons" {
  hr="$HOME/.local/share/cmux/hr"; mkdir -p "$hr/agents/archive" "$HOME/.claude/agents"
  printf '## A. Tools\n' > "$HOME/.config/cmux/orch-areas.md"
  printf '## Members\n| member | runner | agent | model | approach | evidence | status | rounds |\n|---|---|---|---|---|---|---|---|\n| pstack | claude | scout-pstack | opus | slices | corrections | on | |\n' > "$HOME/.config/cmux/agent-committee.md"
  cat > "$HOME/.config/cmux/orch-roster.md" <<'R'
## Roles
- rsc | agent | L2 | A | 상태: 수습 | 시작 11-24 | 판정 12-01 | 연장 시 12-08 | 계약 판정 12-15부터 14일마다 | 판정자: user
## Standing
- desk | orch | L1 | 전체 | 상태: 계약 | 시작 11-24 | 판정 12-01부터 7일마다(월)
- lead:A | brief lead | L1 | A | 상태: 시험 2단계 | 시작 11-23
## Committee
- pstack | claude:opus | scout-pstack | 상태: 수습 | 시작 11-23 | 판정 12-07
## Log
- 11-24 | rsc | hire | backers: a,b | quorum-2026-11-23 #5
- 11-24 | old | merged | into rsc | by:user
R
  printf -- '---\nname: rsc\ndescription: "scope"\nmodel: sonnet\n---\n' > "$HOME/.claude/agents/rsc.md"
  printf -- '---\nname: stray\ndescription: "x"\n---\n' > "$HOME/.claude/agents/stray.md"
  printf -- '---\nname: draft1\nmodel: opus\n---\n' > "$hr/agents/draft1.md"
  echo '{"scouts":[{"name":"volume","model":"opus"}],"proposals":{},"candidates":[]}' > "$hr/pilot-panel-2026-11-23.json"
  run python3 - "$BRIEF" <<'PY'
import importlib.machinery, importlib.util, sys
l = importlib.machinery.SourceFileLoader("brief", sys.argv[1]); s = importlib.util.spec_from_loader("brief", l)
b = importlib.util.module_from_spec(s); l.exec_module(b)
for n in b.org_chart(measure=lambda n: f"M:{n}")["nodes"]:
    c = n.get("contract") or {}
    print(n["name"], "|", n["dept"], "|", n["kind"], "|", c.get("start", ""), c.get("probation", ""), c.get("extend", ""), "|",
          (n.get("hired_why") or "")[:30], "|", (n.get("retired_why") or "")[:30], "|", n["metrics"])
PY
  [ "$status" -eq 0 ]
  [[ "$output" == *"rsc | A. Tools | 역할 | 11-24 12-01 12-08 | 11-24 고용 — backers: a,b | quor |  | M:rsc"* ]]
  [[ "$output" == *"desk | 데스크 | 데스크 (orch) | 11-24 12-01부터 7일마다(월)  | 고용(hire) 기록 없음"* ]]
  [[ "$output" == *"lead:A | A. Tools | 영역 담당 |"* ]]                  # the area lead heads its area
  [[ "$output" == *"pstack | 위원회 | 위원 |"* ]]                         # a committee member is one more agent
  [[ "$output" == *"draft1 | 투입 전 초안 | 초안 |"* ]]
  [[ "$output" == *"stray | 명부에 없는 정의 |"* ]]
  [[ "$output" == *"old | 은퇴 | 합쳐짐 |"*"11-24 합쳐짐 — into rsc | by:user"* ]]
  [[ "$output" == *"volume | 은퇴 | 예전 위원 |"*"마지막 회의 pilot-panel-2026-11-23"* ]]
  [[ "$output" != *"M:volume"* && "$output" != *"M:old"* ]]               # retired: no metrics
}

@test "office archive: installs and clean-ups from the roster sit in the timeline, with the user's decision time when there is one" {
  hr="$HOME/.local/share/cmux/hr"; mkdir -p "$hr/agents"
  echo '{"id":"eval-2026-11-24-1","members":[],"results":{"rsc":{"result":"approve","counts":{"hire":4}}}}' > "$hr/eval-2026-11-24-1.json"
  printf '## A. Tools\n### Decision log\n- 11-24 11:12 | rules | by:user | rsc 를 투입 보고 뒤 설치 확인함 | ref:x\n' > "$HOME/.config/cmux/orch-areas.md"
  printf '## Roles\n- rsc | agent | L2 | A | 상태: 수습\n## Log\n- 11-24 | rsc | hire | backers: a | eval-2026-11-24-1 approve\n- 11-24 | old | tool | becomes a script | by:desk\n' > "$HOME/.config/cmux/orch-roster.md"
  run python3 - "$BRIEF" <<'PY'
import importlib.machinery, importlib.util, sys
l = importlib.machinery.SourceFileLoader("brief", sys.argv[1]); s = importlib.util.spec_from_loader("brief", l)
b = importlib.util.module_from_spec(s); l.exec_module(b)
b.AREAS_MD = b.os.path.join(b.HOME, ".config/cmux/orch-areas.md")
for m in b.committee_archive():
    if m.get("record"):
        print(m["what"], m["topic"], m["time_known"], b._kst(m["at"])[6:] if m["time_known"] else "-", m["items"][0]["fate"])
PY
  [ "$status" -eq 0 ]
  [[ "$output" == *"투입 rsc True 11:12 투입 · 수습"* ]]        # time from the user's decision line
  [[ "$output" == *"도구로 전환 old False - 도구로 전환 — becomes a script"* ]]   # no time on record: not invented
}
