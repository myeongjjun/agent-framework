#!/usr/bin/env bats
# agent-scout — the agent scouting committee: quorum, blind judge, member review, define/check/install.
# A fake scout (AGENT_SCOUT_CMD) stands in for `claude -p --agent`; it answers by SCOUT_NAME and SCOUT_ROUND.

AS="$BATS_TEST_DIRNAME/../bin/agent-scout"

setup() {
  T="$BATS_TEST_TMPDIR"
  export AGENT_SCOUT_CONFIG="$T/agent-scouts.md" AGENT_SCOUT_ROSTER="$T/roster.md" AGENT_SCOUT_HR="$T/hr"
  export AGENT_SCOUT_AGENTS="$T/agents" AGENT_SCOUT_SKILLS="$T/skills" AGENT_SCOUT_CLAUDE_DIR="$T/claude"
  export AGENT_SCOUT_CODEX_DIR="$T/codex" AGENT_SCOUT_BRIEFS="$T/briefs" AGENT_SCOUT_DESK="$T/desk"
  export AGENT_SCOUT_AREAS="$T/areas.md" AGENT_SCOUT_LOCAL="$T/local.md" AGENT_SCOUT_TODAY="2026-11-23"
  export AGENT_SCOUT_CMD="$T/fake-scout" CALLS="$T/calls" AGENT_SCOUT_ASKED="$T/asked.json"
  mkdir -p "$T/agents" "$T/skills" "$T/claude/p1" "$T/codex" "$T/briefs" "$T/desk"
  cat >"$AGENT_SCOUT_CONFIG" <<'EOF'
# scouts
## Members
| member | runner | agent | model | approach | evidence | status |
|---|---|---|---|---|---|---|
| volume | claude | scout-volume | opus | a | sessions,briefs | on |
| friction | claude | scout-friction | sonnet | b | corrections | on |
| handoff | codex | scout-handoff | default | c | decisions | on |

## Quorum
- pass: 2
- vote: on
- watch: 1
- days: 21
- slices: 3

## Judge
- judge: claude:fable

## Review
- min_runs: 1
- pass_rate_min: 0.5
- judge_min: 0.5
- reversed_max: 0
- on_fail: bench

## Schedule
- every: 14

## Evaluate
- approve: 2
- reject: 2
- ground_min: 1

## Kinds
- research: `/research\b`
- db-upgrade: `widgetdb`
EOF
  cat >"$AGENT_SCOUT_LOCAL" <<'EOF'
- Ask-first areas:
  - WidgetDB: `widgetdb`, `wdb`
EOF
  printf '## A. tools\n### Decision log\n- 11-20 | answer | by:desk | scope of research | asked\n' >"$AGENT_SCOUT_AREAS"
  printf '# 261122\n## 결정 필요\n- research scope: internal or general?\n## Other\n- x\n' >"$T/desk/261122.md"
  # two research sessions with a correction, one upgrade session
  for i in 1 2; do
    cat >"$T/claude/p1/aaaaaaa$i-0000.jsonl" <<EOF
{"type":"user","timestamp":"2026-11-1${i}T01:00:00Z","cwd":"/home/u/research","message":{"content":"look into widget caching"}}
{"type":"assistant","message":{"content":"ok"}}
{"type":"user","timestamp":"2026-11-1${i}T01:05:00Z","cwd":"/home/u/research","message":{"content":"아니 사내 말고 일반 지식으로"}}
{"type":"user","timestamp":"2026-11-1${i}T01:06:00Z","cwd":"/home/u/research","message":{"content":[{"type":"tool_result","content":"x"}]}}
EOF
  done
  cat >"$T/claude/p1/bbbbbbbb-0000.jsonl" <<'EOF'
{"type":"user","timestamp":"2026-11-05T01:00:00Z","cwd":"/home/u/widgetdb","message":{"content":"plan the widgetdb upgrade test"}}
{"type":"user","timestamp":"2026-11-05T01:02:00Z","cwd":"/home/u/widgetdb","message":{"content":"왜 이렇게 오래 걸려"}}
EOF
  cat >"$T/claude/p1/old00000-0000.jsonl" <<'EOF'
{"type":"user","timestamp":"2026-09-01T01:00:00Z","cwd":"/home/u/research","message":{"content":"too old"}}
EOF
  touch -t 202609010000 "$T/claude/p1/old00000-0000.jsonl"
  cat >"$AGENT_SCOUT_CMD" <<'EOF'
#!/usr/bin/env bash
cat >"$CALLS.$SCOUT_NAME.$SCOUT_ROUND"
echo "$SCOUT_NAME $SCOUT_ROUND" >>"$CALLS"
case " $SCOUT_FAIL " in *" $SCOUT_NAME "*) echo "pane waiting at a trust screen" >&2; exit 6 ;; esac
cand() { printf '{"kind":"%s","role":"%s","title":"%s","why":"w","evidence":["e1"],"form":"agent","strength":%s}' "$1" "$2" "$3" "$4"; }
case "$SCOUT_NAME/$SCOUT_ROUND" in
  volume/propose)   echo "{\"candidates\":[$(cand research doc-scope-checker 'Checks research scope' 2),$(cand chart-review chart-pr-reviewer 'Reviews chart PRs' 1)]}" ;;
  friction/propose) echo "{\"candidates\":[$(cand research scope-checker 'Scope check' 3),$(cand db-upgrade widgetdb-plan-reviewer 'Reviews widgetdb plans' 3)]}" ;;
  handoff/propose)  echo '{"result":"{\"candidates\":[]}"}' ;;
  volume/vote)      echo '{"votes":[{"kind":"db-upgrade","vote":"yes","why":"13 sessions"}]}' ;;
  friction/vote)    echo '{"votes":[{"kind":"chart-review","vote":"no","why":"1 correction"}]}' ;;
  handoff/vote)     echo '{"votes":[{"kind":"db-upgrade","vote":"no","why":"-"},{"kind":"chart-review","vote":"no","why":"-"}]}' ;;
  */evaluate)       v=hire; [ "$SCOUT_NAME" = handoff ] && v=reject; [ "$SCOUT_NAME" = friction ] && v="${EVAL_FRICTION:-hire}"
                    echo "{\"reviews\":[{\"role\":\"scope-helper\",\"verdict\":\"$v\",\"need\":2,\"fit\":2,\"safety\":1,\"why\":\"w $SCOUT_NAME\",\"fixes\":[\"narrow the trigger\"],\"evidence\":[\"e1\"]},{\"role\":\"not-a-draft\",\"verdict\":\"hire\",\"need\":2,\"fit\":2,\"safety\":2,\"why\":\"x\",\"fixes\":[],\"evidence\":[]}]}" ;;
  judge/egrade)     grep -q "volume" "$CALLS.judge.egrade" && echo LEAK >>"$CALLS"
                    echo '{"grades":[{"id":"R1","grounded":2,"why":"ok"},{"id":"R2","grounded":2,"why":"ok"},{"id":"R3","grounded":0,"why":"generic"},{"id":"R4","grounded":0,"why":"generic"}]}' ;;
  judge/measure)    r='{"grades":[]}'; echo "${MEASURE_REPLY:-$r}" ;;
  judge/judge)      grep -q "volume" "$CALLS.judge.judge" && echo LEAK >>"$CALLS"
                    echo '{"grades":[{"id":"P1","evidence":2,"fit":2,"why":"ok"},{"id":"P2","evidence":0,"fit":0,"why":"thin"},{"id":"P3","evidence":2,"fit":1,"why":"ok"},{"id":"P4","evidence":2,"fit":2,"why":"ok"}]}' ;;
esac
EOF
  chmod +x "$AGENT_SCOUT_CMD"
}

@test "scan: builds three packs from history inside the window, skips tool results and old sessions" {
  run "$AS" scan --json
  [ "$status" -eq 0 ]
  echo "$output" | python3 -c '
import json,sys
d=json.load(sys.stdin)
k={x["kind"]:x for x in d["kinds"]}
assert k["research"]["sessions"]==2 and k["research"]["corrections"]==2, k
assert k["db-upgrade"]["corrections"]==1
assert "too old" not in d["packs"]["sessions"]
assert "사내 말고" in d["packs"]["corrections"]
assert "research scope: internal" in d["packs"]["decisions"] and "scope of research" in d["packs"]["decisions"]
assert "- x" not in d["packs"]["decisions"]
'
}

@test "quorum: each scout gets its own pack; 2 backers pass; one short goes to a vote" {
  run "$AS" quorum --json
  [ "$status" -eq 0 ]
  grep -q "사내 말고" "$CALLS.friction.propose"
  ! grep -q "사내 말고" "$CALLS.handoff.propose" || false
  grep -q "research scope: internal" "$CALLS.handoff.propose"
  echo "$output" | python3 -c '
import json,sys
d=json.load(sys.stdin)
c={g["kind"]:g for g in d["candidates"]}
assert c["research"]["result"]=="pass" and sorted(c["research"]["backers"])==["friction","volume"]
assert c["research"]["role"]=="scope-checker"          # strength 3 beats 2 on a tie of one proposal each
assert c["db-upgrade"]["result"]=="pass" and [v["scout"] for v in c["db-upgrade"]["voted"]]==["volume"]
assert [v["scout"] for v in c["db-upgrade"]["against"]]==["handoff"]
assert c["chart-review"]["result"]=="watch" and c["chart-review"]["support"]==1
assert d["candidates"][0]["result"]=="pass" and d["candidates"][-1]["result"]=="watch"
'
  # the vote round asks only scouts that did not propose the kind
  ! grep -q "db-upgrade" "$CALLS.friction.vote" || false
  ls "$AGENT_SCOUT_HR"/quorum-2026-11-23.json "$AGENT_SCOUT_HR"/quorum-2026-11-23.md
  grep -q "^- volume | claude:opus | scout-volume | 접근: a | 상태: 수습" "$AGENT_SCOUT_ROSTER"
  grep -q "| friction | scan | proposed 2 · passed 2 · judge 0.88" "$AGENT_SCOUT_ROSTER"
}

@test "quorum: the rule is config — pass 3 leaves nothing passed, vote off skips the vote round" {
  sed -i.bak 's/^- pass: 2/- pass: 3/; s/^- vote: on/- vote: off/' "$AGENT_SCOUT_CONFIG"
  run "$AS" quorum --json
  [ "$status" -eq 0 ]
  [ ! -e "$CALLS.volume.vote" ]
  echo "$output" | python3 -c '
import json,sys
d=json.load(sys.stdin)
assert all(g["result"]!="pass" for g in d["candidates"]), d["candidates"]
'
}

@test "quorum: a scout switched off is not run; a failing scout is reported and the others still count" {
  sed -i.bak 's/| handoff | codex | scout-handoff | default | c | decisions | on |/| handoff | codex | scout-handoff | default | c | decisions | off |/' "$AGENT_SCOUT_CONFIG"
  printf '#!/usr/bin/env bash\ncat >/dev/null\n[ "$SCOUT_NAME" = friction ] && exit 7\nexec %s\n' "$T/fake-scout.real" >"$T/wrap"
  mv "$AGENT_SCOUT_CMD" "$T/fake-scout.real"; mv "$T/wrap" "$AGENT_SCOUT_CMD"; chmod +x "$AGENT_SCOUT_CMD"
  run "$AS" quorum
  [ "$status" -eq 0 ]
  [[ "$output" == *"member friction"*"ERROR"* ]] || false
  [[ "$output" != *"member handoff"* ]]
}

@test "new/check/install: draft is not ready until TODOs are filled; install copies and adds a roster line" {
  "$AS" quorum >/dev/null
  run "$AS" new doc-scope-checker --from research --area A --layer L2 --home "$T/l2"
  [ "$status" -eq 0 ]
  d="$AGENT_SCOUT_HR/agents/doc-scope-checker.md"
  [ -f "$d" ]
  grep -q "| ask_first | no |" "$d"
  run "$AS" check doc-scope-checker
  [ "$status" -eq 3 ]
  [[ "$output" == *"TODO left"* ]] || false
  run "$AS" install doc-scope-checker
  [ "$status" -eq 3 ]
  python3 - "$d" <<'EOF'
import re,sys
p=sys.argv[1]; s=open(p).read()
s=s.replace('"TODO: one paragraph — what this agent does, when to call it (trigger), what it never does."','"Checks research scope before research starts."')
s=re.sub(r"TODO: [^|\n]*", "filled", s)
s=s.replace("filled\n", "Read the request. " * 20 + "\n")
open(p,"w").write(s)
EOF
  run "$AS" check doc-scope-checker
  [ "$status" -eq 0 ]
  run "$AS" install doc-scope-checker                    # every install: the report first, then the user's OK
  [ "$status" -eq 3 ]
  [[ "$output" == *"# 투입 보고: doc-scope-checker"* ]] || false
  [[ "$output" == *"## 2. 평가 지표"* && "$output" == *"## 3. 선발·퇴출"* && "$output" == *"## 4. 근거"* ]] || false
  [ ! -e "$AGENT_SCOUT_AGENTS/doc-scope-checker.md" ]
  run "$AS" install doc-scope-checker --user-approved
  [ "$status" -eq 0 ]
  [ -f "$AGENT_SCOUT_AGENTS/doc-scope-checker.md" ]
  [ -f "$T/l2/doc-scope-checker.md" ]
  grep -q "^- doc-scope-checker | agent | L2 | A | 상태: 수습 | 시작 11-23 | 판정 11-30 | 연장 시 12-07 | 계약 판정 12-14부터 14일마다 | 재평가 모델: - | 지표: agent-scout measure doc-scope-checker | 교체선: 5.3·5.5 표 | 판정자: user (역할이 그대로인 결과만 desk 기록) | 원본: $T/l2/" "$AGENT_SCOUT_ROSTER"
  grep -q "| doc-scope-checker | hire |" "$AGENT_SCOUT_ROSTER"
  run "$AS" log doc-scope-checker ok --ref t1
  grep -q "| doc-scope-checker | use | ref:t1 | ok" "$AGENT_SCOUT_ROSTER"
}

@test "install: a role in an ask-first area stays a draft until --user-approved" {
  "$AS" quorum >/dev/null
  "$AS" new widgetdb-plan-reviewer --from db-upgrade --area A --home "$T/proj/.claude/agents" >/dev/null
  d="$AGENT_SCOUT_HR/agents/widgetdb-plan-reviewer.md"
  grep -q "| ask_first | yes (WidgetDB) |" "$d"
  python3 - "$d" <<'EOF'
import re,sys
p=sys.argv[1]; s=open(p).read()
s=re.sub(r'"TODO[^"]*"', '"Reviews plans."', s)
s=re.sub(r"TODO: [^|\n]*", "filled", s)
s=s.replace("filled\n", "Read the plan. " * 20 + "\n")
open(p,"w").write(s)
EOF
  run "$AS" install widgetdb-plan-reviewer
  [ "$status" -eq 3 ]
  [[ "$output" == *"ask-first area 'WidgetDB'"* ]] || false
  [ ! -e "$AGENT_SCOUT_AGENTS/widgetdb-plan-reviewer.md" ]
  grep -q "| layer | L3 |" "$d"
  run "$AS" install widgetdb-plan-reviewer --user-approved
  [ "$status" -eq 0 ]
  [ -f "$T/proj/.claude/agents/widgetdb-plan-reviewer.md" ]
  [ ! -e "$AGENT_SCOUT_AGENTS/widgetdb-plan-reviewer.md" ]   # L3: active in its project only
  grep -q "widgetdb-plan-reviewer | hire |.*user-approved" "$AGENT_SCOUT_ROSTER"
}

@test "judge: grades blind (no member names in its prompt); a judge that is a member is refused" {
  run "$AS" convene --json
  [ "$status" -eq 0 ]
  ! grep -q LEAK "$CALLS" || false
  echo "$output" | python3 -c '
import json,sys
d=json.load(sys.stdin); g={x["id"]:x for x in d["judge"]["grades"]}
assert g["P1"]["member"]=="volume" and g["P3"]["member"]=="friction", g
'
  sed -i.bak 's/^- judge: claude:fable/- judge: claude:sonnet/' "$AGENT_SCOUT_CONFIG"
  rm "$CALLS"
  run "$AS" convene --json
  [ "$status" -eq 0 ]
  ! grep -q "judge judge" "$CALLS" || false
  [[ "$output" == *"is also a member"* ]]
}

@test "review: computed from records, not the member; a member under the line is benched in the config" {
  "$AS" convene >/dev/null
  run "$AS" reject research --why "not needed"
  [ "$status" -eq 0 ]
  grep -q "| committee | reject | kind research | backers: volume,friction | not needed" "$AGENT_SCOUT_ROSTER"
  run "$AS" review --json
  [ "$status" -eq 0 ]
  echo "$output" | python3 -c '
import json,sys
r={x["member"]:x for x in json.load(sys.stdin)}
assert r["handoff"]["proposed"]==0 and r["handoff"]["verdict"]=="bench", r["handoff"]
assert r["volume"]["rejected"]==1 and r["volume"]["verdict"]=="bench"
assert r["friction"]["passed"]==2
'
  grep -q "^| handoff | codex | scout-handoff | default | c | decisions | off |" "$AGENT_SCOUT_CONFIG"
  grep -q "| handoff | review | bench |" "$AGENT_SCOUT_ROSTER"
  run "$AS" convene
  [[ "$output" != *"member handoff"* ]]
}

@test "review: hire backers carry over — a corrected use counts against the members who backed the role" {
  "$AS" convene >/dev/null
  "$AS" new rsc --from research --area A --layer L2 --home "$T/l2" >/dev/null
  d="$AGENT_SCOUT_HR/agents/rsc.md"
  python3 - "$d" <<'EOF'
import re,sys
p=sys.argv[1]; s=open(p).read()
s=re.sub(r'"TODO[^"]*"', '"Checks scope."', s); s=re.sub(r"TODO: [^|\n]*", "filled", s)
s=s.replace("filled\n", "Read the request. " * 20 + "\n"); open(p,"w").write(s)
EOF
  "$AS" install rsc --user-approved >/dev/null
  grep -q "| rsc | hire | backers: volume,friction |" "$AGENT_SCOUT_ROSTER"
  "$AS" log rsc corrected --ref t9
  run "$AS" review --json --no-apply
  echo "$output" | python3 -c '
import json,sys
r={x["member"]:x for x in json.load(sys.stdin)}
assert r["friction"]["corrected"]==1 and r["friction"]["hired"]==1 and r["handoff"]["corrected"]==0
'
}

@test "due: a meeting is due when none happened or the last is older than the schedule" {
  run "$AS" due
  [ "$status" -eq 0 ]
  "$AS" convene >/dev/null
  run "$AS" due
  [ "$status" -eq 1 ]
  AGENT_SCOUT_TODAY=2026-12-07 run "$AS" due
  [ "$status" -eq 0 ]
}

@test "failed meeting: no member sat, so it is saved as failed-convene and neither due nor review counts it" {
  SCOUT_FAIL="volume friction handoff" run "$AS" convene
  [ "$status" -eq 1 ]
  [[ "$output" == *"not counted"* ]] || false
  [ -f "$AGENT_SCOUT_HR/failed-convene-2026-11-23.json" ] && [ ! -e "$AGENT_SCOUT_HR/quorum-2026-11-23.json" ]
  ! grep -q "상태: 수습" "$AGENT_SCOUT_ROSTER" || false                     # nobody sat: no probation starts
  grep -q "| volume | scan | proposed 0 · passed 0 · error | ref:failed-convene-2026-11-23" "$AGENT_SCOUT_ROSTER"
  SCOUT_FAIL="volume friction handoff" run "$AS" convene         # a second try the same day keeps the first record
  [ -f "$AGENT_SCOUT_HR/failed-convene2-2026-11-23.json" ]
  run "$AS" due
  [ "$status" -eq 0 ]
  # a record from before this fix: every member errored under the quorum- name
  mv "$AGENT_SCOUT_HR/failed-convene-2026-11-23.json" "$AGENT_SCOUT_HR/quorum-2026-11-22.json"
  run "$AS" due
  [ "$status" -eq 0 ]
  run "$AS" review --json --no-apply
  echo "$output" | python3 -c 'import json,sys; assert all(x["runs"]==0 and x["verdict"]=="wait" for x in json.load(sys.stdin))'
}

@test "partial meeting: a member whose pane failed did not sit; the others' run counts" {
  SCOUT_FAIL="handoff" "$AS" convene >/dev/null
  run "$AS" due
  [ "$status" -eq 1 ]
  ! grep -q "^- handoff |.*상태: 수습" "$AGENT_SCOUT_ROSTER" || false
  grep -q "^- volume |.*상태: 수습" "$AGENT_SCOUT_ROSTER"
  run "$AS" review --json --no-apply
  echo "$output" | python3 -c '
import json,sys
r={x["member"]:x for x in json.load(sys.stdin)}
assert r["handoff"]["runs"]==0 and r["handoff"]["verdict"]=="wait", r["handoff"]
assert r["volume"]["runs"]==1
'
}

@test "one control path: every member (claude or codex) runs on a sib pane; never headless" {
  unset AGENT_SCOUT_CMD CMUX_WORKSPACE_ID
  sed -i.bak '/| volume |/d; /| friction |/d' "$AGENT_SCOUT_CONFIG"
  sed -i.bak 's/^- judge: claude:fable/- judge: off/' "$AGENT_SCOUT_CONFIG"
  mkdir -p "$T/bin"; printf '#!/bin/sh\necho called >>"%s"\n' "$T/codex-called" >"$T/bin/codex"; chmod +x "$T/bin/codex"
  PATH="$T/bin:$PATH" run "$AS" convene
  [[ "$output" == *"run on cmux panes via sib"* ]] || false
  [ ! -e "$T/codex-called" ]
  ! grep -q '"codex", "exec"' "$AS" || false
  ! grep -q '"claude", "-p"' "$AS"
}

@test "layers: L1 is refused for company context; the draft must name a layer" {
  printf '\n## Layers\n- L1: %s\n- private: acme\n' "$T/l1" >>"$AGENT_SCOUT_CONFIG"
  "$AS" quorum >/dev/null
  "$AS" new pub --from research --area A --layer L1 >/dev/null
  d="$AGENT_SCOUT_HR/agents/pub.md"
  grep -q "| home | $T/l1 |" "$d"
  python3 - "$d" <<'EOF'
import re,sys
p=sys.argv[1]; s=open(p).read()
s=re.sub(r'"TODO[^"]*"', '"Checks scope for acme."', s); s=re.sub(r"TODO: [^|\n]*", "filled", s)
s=s.replace("filled\n", "Read the request. " * 20 + "\n"); open(p,"w").write(s)
EOF
  run "$AS" install pub --user-approved
  [ "$status" -eq 3 ]
  [[ "$output" == *"L1 is public"* ]] || false
  [ ! -e "$T/l1/pub.md" ]
  sed -i.bak 's/for acme/for anyone/' "$d"
  run "$AS" install pub --user-approved
  [ "$status" -eq 0 ]
  [ -f "$T/l1/pub.md" ] && [ -f "$AGENT_SCOUT_AGENTS/pub.md" ]
}

@test "judge hold: a passed kind the judge rates unfit is held; making it needs the user's OK" {
  # awk, not sed: a "\n" in a sed replacement is a newline in GNU sed and a plain "n" in BSD sed
  awk '{print} /^- slices: 3$/{print "- hold_below: 1"}' "$AGENT_SCOUT_CONFIG" >"$AGENT_SCOUT_CONFIG.tmp" && mv "$AGENT_SCOUT_CONFIG.tmp" "$AGENT_SCOUT_CONFIG"
  grep -qx -- "- slices: 3" "$AGENT_SCOUT_CONFIG" && grep -qx -- "- hold_below: 1" "$AGENT_SCOUT_CONFIG"
  sed -i.bak 's/{"id":"P1","evidence":2,"fit":2/{"id":"P1","evidence":2,"fit":0/; s/{"id":"P3","evidence":2,"fit":1/{"id":"P3","evidence":2,"fit":0/' "$AGENT_SCOUT_CMD"
  run "$AS" convene --json
  echo "$output" | python3 -c '
import json,sys
c={g["kind"]:g for g in json.load(sys.stdin)["candidates"]}
assert c["research"]["result"]=="hold" and c["research"]["judge_fit"]==0, c["research"]
assert c["db-upgrade"]["result"]=="pass"
'
  run "$AS" new rsc --from research --area A
  [ "$status" -eq 3 ]
  run "$AS" new rsc --from research --area A --user-approved
  [ "$status" -eq 0 ]
  grep -q "| committee | lifted | kind research was \`hold\` | by:user" "$AGENT_SCOUT_ROSTER"
}

fill() {
  python3 - "$1" <<'PY'
import re,sys
p=sys.argv[1]; s=open(p).read()
s=re.sub(r'"TODO[^"]*"', '"Checks scope."', s); s=re.sub(r"TODO: [^|\n]*", "filled", s)
s=s.replace("filled\n", "Read the request. " * 20 + "\n"); open(p,"w").write(s)
PY
}

@test "evaluate: a made draft needs the committee; every member reviews it, the judge drops ungrounded reviews" {
  run "$AS" new scope-helper --by-user --title "Checks research scope" --kind research --area A --layer L2 --home "$T/l2"
  [ "$status" -eq 0 ]
  d="$AGENT_SCOUT_HR/agents/scope-helper.md"
  grep -q "| evidence | made by:user 2026-11-23 kind \`research\`" "$d"
  fill "$d"
  run "$AS" install scope-helper
  [ "$status" -eq 3 ]
  [[ "$output" == *"agent-scout evaluate scope-helper"* ]] || false
  run "$AS" evaluate scope-helper --json
  [ "$status" -eq 0 ]
  ! grep -q LEAK "$CALLS" || false
  grep -q "Checks scope." "$CALLS.handoff.evaluate"            # every member reads the draft
  grep -q "사내 말고" "$CALLS.friction.evaluate"                 # its own pack, narrowed to the draft's kind
  ! grep -q "오래 걸려" "$CALLS.friction.evaluate" || false
  echo "$output" | python3 -c '
import json,sys
d=json.load(sys.stdin); x=d["results"]["scope-helper"]
assert d["kinds"]==["research"] and list(d["results"])==["scope-helper"], d["results"].keys()
assert x["result"]=="approve" and x["counts"]=={"hire":2,"revise":0,"reject":0} and x["counted"]==2, x
r={v["member"]:v for v in x["reviews"]}
assert r["handoff"]["verdict"]=="reject" and r["handoff"]["counted"] is False and r["handoff"]["grounded"]==0
'
  ls "$AGENT_SCOUT_HR"/eval-2026-11-23-1.md
  grep -q "| scope-helper | evaluate | approve · hire 2 · revise 0 · reject 0 of 2 counted | ref:eval-2026-11-23-1" "$AGENT_SCOUT_ROSTER"
  run "$AS" report scope-helper
  [[ "$output" == *"위원회 평가 eval-2026-11-23-1: **approve**"* && "$output" == *"- handoff: reject"*"세지 않음"* ]] || false
  run "$AS" install scope-helper --user-approved
  [ "$status" -eq 0 ]
  grep -q "| scope-helper | hire | backers: volume,friction | eval-2026-11-23-1 approve |" "$AGENT_SCOUT_ROSTER"
  run "$AS" review --json --no-apply
  echo "$output" | python3 -c '
import json,sys
r={x["member"]:x for x in json.load(sys.stdin)}
assert r["handoff"]["eval_runs"]==1 and r["handoff"]["judge"]==0.0 and r["handoff"]["verdict"]=="bench", r["handoff"]
assert r["volume"]["judge"]==1.0 and r["volume"]["verdict"]=="keep", r["volume"]   # no propose runs: no pass-rate test
'
}

@test "evaluate: a verdict short of approve blocks install until the user overrules it" {
  "$AS" new scope-helper --by-user --title "Checks research scope" --kind research --area A --layer L2 --home "$T/l2" >/dev/null
  fill "$AGENT_SCOUT_HR/agents/scope-helper.md"
  EVAL_FRICTION=revise run "$AS" evaluate scope-helper
  [ "$status" -eq 0 ]
  [[ "$output" == *"[revise ] scope-helper"* ]] || false
  run "$AS" install scope-helper
  [ "$status" -eq 3 ]
  [[ "$output" == *"verdict on scope-helper is \`revise\`"* ]] || false
  EVAL_FRICTION=hire run "$AS" evaluate scope-helper
  [ -f "$AGENT_SCOUT_HR/eval-2026-11-23-2.json" ]
  run "$AS" install scope-helper --user-approved
  [ "$status" -eq 0 ]
  run "$AS" evaluate
  [ "$status" -eq 2 ]
  run "$AS" new x --by-user
  [ "$status" -eq 2 ]
}

@test "rounds: an evaluate-only member sits out convene; bench still rewrites the status column" {
  awk '{print} /^\| handoff \| codex \| scout-handoff \| default \| c \| decisions \| on \|$/{print "| craft | claude | scout-craft | haiku | d | briefs | on | evaluate |"}' \
    "$AGENT_SCOUT_CONFIG" >"$AGENT_SCOUT_CONFIG.tmp" && mv "$AGENT_SCOUT_CONFIG.tmp" "$AGENT_SCOUT_CONFIG"
  grep -qx "| craft | claude | scout-craft | haiku | d | briefs | on | evaluate |" "$AGENT_SCOUT_CONFIG"
  "$AS" convene >/dev/null
  ! grep -q "^craft " "$CALLS" || false
  "$AS" new scope-helper --by-user --title "Checks research scope" --kind research --area A --layer L2 --home "$T/l2" >/dev/null
  "$AS" evaluate scope-helper >/dev/null
  grep -q "^craft evaluate" "$CALLS"
  grep -q "may open with Read\|MAY open with Read" "$CALLS.craft.evaluate"
  "$AS" review >/dev/null                                      # craft's only review was ungrounded: benched
  grep -q "^| craft | claude | scout-craft | haiku | d | briefs | off | evaluate |$" "$AGENT_SCOUT_CONFIG"
}

@test "evaluate: when every member fails, nothing is recorded as a verdict" {
  "$AS" new scope-helper --by-user --title "Checks research scope" --kind research --area A --layer L2 --home "$T/l2" >/dev/null
  printf '#!/bin/sh\nexit 1\n' >"$AGENT_SCOUT_CMD"
  run "$AS" evaluate scope-helper
  [ "$status" -eq 1 ]
  [[ "$output" == *"no evaluation recorded"* ]] || false
  ! ls "$AGENT_SCOUT_HR"/eval-*.json 2>/dev/null || false
  ! grep -q "| scope-helper | evaluate |" "$AGENT_SCOUT_ROSTER" 2>/dev/null
}

fill() {  # fill a draft's TODOs the way a session would
  python3 - "$1" "${2:-Checks scope.}" <<'EOF'
import re,sys
p=sys.argv[1]; s=open(p).read()
s=re.sub(r'"TODO[^"]*"', '"' + sys.argv[2] + '"', s); s=re.sub(r"TODO: [^|\n]*", "filled", s)
s=s.replace("filled\n", "Read the request. " * 20 + "\n"); open(p,"w").write(s)
EOF
}

@test "quorum: proposals are grouped by idea — another role in the same kind keeps its own backers" {
  sed -i.bak 's/cand db-upgrade widgetdb-plan-reviewer/cand research root-cause-first/' "$AGENT_SCOUT_CMD"
  run "$AS" quorum --json
  [ "$status" -eq 0 ]
  echo "$output" | python3 -c '
import json,sys
d=json.load(sys.stdin)
c={g["idea"]:g for g in d["candidates"]}
assert c["scope-checker"]["backers"]==["volume","friction"], c.keys()    # scope-checker / doc-scope-checker: one idea
assert c["root-cause-first"]["backers"]==["friction"]                   # same kind, other idea: not merged
assert all(p["role"]=="root-cause-first" for p in c["root-cause-first"]["proposals"])
assert all(p["role"]!="root-cause-first" for p in c["scope-checker"]["proposals"])
'
  run "$AS" show research                 # a kind with two ideas is ambiguous
  [ "$status" -eq 2 ]
  [[ "$output" == *"2 ideas"* ]] || false
  run "$AS" show root-cause-first
  [ "$status" -eq 0 ]
}

@test "install: the roster line carries the full contract — extension, 14-day verdicts, re-evaluation model" {
  "$AS" new rsc --by-user --title "Checks scope" --kind research --area A --layer L2 --home "$T/l2" --reeval opus >/dev/null
  d="$AGENT_SCOUT_HR/agents/rsc.md"
  grep -q "Re-evaluation model: opus (5.6)" "$d"
  fill "$d"
  "$AS" install rsc --user-approved >/dev/null
  grep -q "^- rsc | agent | L2 | A | 상태: 수습 | 시작 11-23 | 판정 11-30 | 연장 시 12-07 | 계약 판정 12-14부터 14일마다 | 재평가 모델: opus | 지표: agent-scout measure rsc | 교체선: 5.3·5.5 표 | 판정자: user (역할이 그대로인 결과만 desk 기록) | 원본: " "$AGENT_SCOUT_ROSTER"
}

@test "layers: an ask-first (WidgetDB-like) agent is never defined in L1 — new and install refuse it" {
  printf '\n## Layers\n- L1: %s\n' "$T/l1" >>"$AGENT_SCOUT_CONFIG"
  run "$AS" new widgetdb-claim-checker --by-user --title "Checks widgetdb claims" --kind db-upgrade --area A --layer L1
  [ "$status" -eq 3 ]
  [[ "$output" == *"ask-first area 'WidgetDB'"*"never holds it"* ]] || false
  [ ! -e "$AGENT_SCOUT_HR/agents/widgetdb-claim-checker.md" ]
  # a draft moved to L1 by hand is refused at install, even with the user's OK
  "$AS" new widgetdb-claim-checker --by-user --title "Checks widgetdb claims" --kind db-upgrade --area A --layer L2 --home "$T/l2" >/dev/null
  d="$AGENT_SCOUT_HR/agents/widgetdb-claim-checker.md"
  fill "$d" "Checks widgetdb claims."
  sed -i.bak "s#| layer | L2 |#| layer | L1 |#" "$d"
  run "$AS" install widgetdb-claim-checker --user-approved
  [ "$status" -eq 3 ]
  [[ "$output" == *"L1 is public"* ]] || false
  [ ! -e "$T/l1/widgetdb-claim-checker.md" ] && [ ! -e "$AGENT_SCOUT_AGENTS/widgetdb-claim-checker.md" ]
}

@test "roster corrections: a void line drops a hire backer from review and a use line from measure" {
  printf '## Roles\n\n## Log\n- 11-23 | rsc | hire | backers: volume,friction | x | user-approved\n- 11-23 | rsc | use | ref:bad | corrected\n' >"$AGENT_SCOUT_ROSTER"
  run "$AS" review --json --no-apply
  echo "$output" | python3 -c '
import json,sys
r={x["member"]:x for x in json.load(sys.stdin)}
assert r["volume"]["hired"]==1 and r["volume"]["corrected"]==1, r["volume"]'
  printf -- '- 11-23 | rsc | void | hire backer:volume | grouped by kind | by:desk\n- 11-23 | rsc | void | use ref:bad | not called | by:desk\n' >>"$AGENT_SCOUT_ROSTER"
  run "$AS" review --json --no-apply
  echo "$output" | python3 -c '
import json,sys
r={x["member"]:x for x in json.load(sys.stdin)}
assert r["volume"]["hired"]==0 and r["friction"]["hired"]==1 and r["friction"]["corrected"]==0, r'
}

calls_fixture() {  # a session that calls rsc three times, one trial call in a committee folder, one session that does not
  mkdir -p "$T/claude/p2" "$T/claude/-private-tmp-agent-scout-call-rsc"
  {
    echo '{"type":"user","timestamp":"2026-11-24T01:00:00Z","cwd":"/home/u/research","message":{"content":"/x/sib/briefs/scope-job.md 를 읽고 진행"}}'
    for i in 1 2 3; do
      echo "{\"type\":\"assistant\",\"timestamp\":\"2026-11-24T01:0${i}:00Z\",\"message\":{\"content\":[{\"type\":\"tool_use\",\"id\":\"tu$i\",\"name\":\"Agent\",\"input\":{\"subagent_type\":\"rsc\",\"prompt\":\"scope $i\"}}]}}"
      echo "{\"type\":\"user\",\"timestamp\":\"2026-11-24T01:0${i}:10Z\",\"message\":{\"content\":[{\"type\":\"tool_result\",\"tool_use_id\":\"tu$i\",\"content\":\"source: general\"}]}}"
      echo "{\"type\":\"user\",\"timestamp\":\"2026-11-24T01:0${i}:20Z\",\"message\":{\"content\":\"$([ $i = 2 ] && echo '아니 사내 자료 말고' || echo 'go on')\"}}"
    done
    echo '{"type":"assistant","timestamp":"2026-11-24T01:09:00Z","message":{"content":[{"type":"tool_use","id":"q1","name":"AskUserQuestion","input":{}}]}}'
  } >"$T/claude/p2/cccccccc-0000.jsonl"
  sed 's/cccc/dddd/' "$T/claude/p2/cccccccc-0000.jsonl" >"$T/claude/-private-tmp-agent-scout-call-rsc/dddddddd-0000.jsonl"
  cat >"$T/claude/p2/eeeeeeee-0000.jsonl" <<'EOF'
{"type":"user","timestamp":"2026-11-24T02:00:00Z","cwd":"/home/u/research","message":{"content":"look at caching"}}
{"type":"user","timestamp":"2026-11-24T02:01:00Z","cwd":"/home/u/research","message":{"content":"아니 일반 지식으로"}}
EOF
  printf '## Roles\n- rsc | agent | L2 | A | 상태: 수습 | 시작 11-24 | 판정 12-01 | 연장 시 12-08 | 계약 판정 12-15부터 14일마다 | 재평가 모델: opus | 원본: %s/l2/rsc.md\n\n## Log\n- 11-24 | rsc | use | ref:scope-job | ok\n- 11-24 | rsc | use | ref:wrong-session | miss\n- 11-24 | rsc | void | use ref:wrong-session | not called | by:desk\n' "$T" >"$AGENT_SCOUT_ROSTER"
  mkdir -p "$T/l2"
  printf -- '---\nname: rsc\n---\n## Role card\n| field | value |\n|---|---|\n| done_when | ok when the user keeps the scope |\n| evidence | made by:user kind `research` |\n| contract | re-evaluation model: opus |\n\n## Evidence quotes\n- [research] 2026-11-11 claude:aaaaaaa1 | 아니 사내 말고 일반 지식으로\n' >"$T/l2/rsc.md"
  export AGENT_SCOUT_TODAY=2026-12-01
}

@test "measure: five counts from their sources; trial calls and voided use lines are not counted" {
  calls_fixture
  run "$AS" measure rsc --since 2026-11-24 --json
  [ "$status" -eq 0 ]
  echo "$output" | python3 -c '
import json,sys
d=json.load(sys.stdin); n=d["counts"]
assert d["window"]==["2026-11-24","2026-12-01"], d["window"]
assert n["uses"]==3, n                                  # the -private-tmp-agent-scout-* copy is a trial call
assert [c.get("logged") for c in d["calls"]]==["ok",None,None]   # the use line names the brief; the voided line is gone
assert n["ok"]==1 and n["judged"]==1 and n["corrected"]==0
assert d["calls"][1]["correction"]==["아니 사내 자료 말고"]
assert n["repeat"] is None and len(d["repeat_items"])==2           # unjudged: one in the called session, one outside
assert n["asked"]==1 and n["baseline"]==round(7/21,2)
assert d["result"].startswith("잠정 계약"), d["result"]
'
  run "$AS" measure rsc --since 2026-11-24
  [[ "$output" == *"uses       3"*"Agent/Task subagent_type=rsc"* ]] || false
  [[ "$output" == *"- 12-01 | rsc | verdict | 창 11-24..12-01 · uses 3 · ok 1/1 · corrected 0 · repeat ? (기준 0.33/7일, uncalled ?) · asked 1 | 잠정"* ]] || false
  run "$AS" measure rsc --since 2026-11-24 --write      # provisional numbers are never written
  [ "$status" -eq 3 ]
  ! grep -q "| rsc | verdict |" "$AGENT_SCOUT_ROSTER"
}

@test "measure --judge: the judge settles ok, corrected and repeat; the verdict line follows design 5.3 and is written" {
  calls_fixture
  export MEASURE_REPLY='{"grades":[{"id":"C2","verdict":"miss","why":"x"},{"id":"C3","verdict":"miss","why":"x"},{"id":"C2.k1","verdict":"yes","why":"x"},{"id":"R1","verdict":"yes","why":"x"},{"id":"R2","verdict":"yes","why":"x"}]}'
  run "$AS" measure rsc --since 2026-11-24 --judge --write
  [ "$status" -eq 0 ]
  grep -q "ok when the user keeps the scope" "$CALLS.judge.measure"    # the judge grades by the card's done_when
  ! grep -q "C1 (ok|miss" "$CALLS.judge.measure" || false                          # a call the desk already logged is not re-graded
  grep -q "^- 12-01 | rsc | verdict | 창 11-24..12-01 · uses 3 · ok 1/3 · corrected 1 · repeat 1 (기준 0.33/7일, uncalled 1) · asked 1 | 재평가 opus (5.6) | by:user$" "$AGENT_SCOUT_ROSTER"
}

@test "measure: a roster use line whose session was not found is not an ok (uses 0 never reads ok 1/1)" {
  calls_fixture
  rm "$T/claude/p2/cccccccc-0000.jsonl"
  run "$AS" measure rsc --since 2026-11-24 --json
  [ "$status" -eq 0 ]
  echo "$output" | python3 -c '
import json,sys
d=json.load(sys.stdin); n=d["counts"]
assert n["uses"]==0 and n["ok"]==0 and n["judged"]==0, n
assert [r for _,_,r in d["unmatched_use_lines"]]==["ok"], d["unmatched_use_lines"]'
  run "$AS" measure rsc --since 2026-11-24
  [[ "$output" == *"uses 0 · ok 0/0 ·"* ]] || false
  [[ "$output" == *"세션을 찾지 못한 use 줄 1건은 uses 가 아니라 세지 않음"*"ref:scope-job ok"* || "$output" == *"세션을 찾지 못한 use 줄 1건은 uses 가 아니라 세지 않음"*"scope-job ok"* ]]
}

@test "measure: fewer than 3 uses extends probation once, then the next verdict is dissolution for the user" {
  calls_fixture
  rm "$T/claude/p2/cccccccc-0000.jsonl"
  run "$AS" measure rsc --since 2026-11-24 --write
  [ "$status" -eq 0 ]
  grep -q "| rsc | verdict | .*uses 0 .*| 수습 연장 7일 (uses < 3) | by:desk$" "$AGENT_SCOUT_ROSTER"
  AGENT_SCOUT_TODAY=2026-12-08 run "$AS" measure rsc --since 2026-11-24 --until 2026-12-08
  [[ "$output" == *"| 해체 (연장 뒤에도 uses < 3) | by:user"* ]]
}

@test "usage errors exit 2" {
  run "$AS" new
  [ "$status" -eq 2 ]
  run "$AS" bogus
  [ "$status" -eq 2 ]
  run "$AS" measure
  [ "$status" -eq 2 ]
}

panes_stub() {  # fake sib + cmux: workspaces live in $WS as "workspace:N title"; FAIL_FIRST spawns per slug fail silently
  unset AGENT_SCOUT_CMD; export T CMUX_WORKSPACE_ID=caller WS="$T/ws" FAKE="$T/fake-scout"
  printf '  workspace:1  caller\n* workspace:2  other  [selected]\n' >"$WS"
  mv "$T/fake-scout.real" "$FAKE" 2>/dev/null || true
  mkdir -p "$T/bin"
  cat >"$T/bin/cmux" <<'EOF'
#!/usr/bin/env bash
case "$1" in
  workspace) cat "$WS" ;;
  close-workspace) grep -vw -- "$3" "$WS" >"$WS.n"; mv "$WS.n" "$WS" ;;
esac
EOF
  cat >"$T/bin/sib" <<'EOF'
#!/usr/bin/env bash
echo "$*" >>"$T/sib-args"
cmd=$1 slug=$2; shift 2
newws() { n=$((100 + $(cat "$T/made" 2>/dev/null | wc -l))); echo "$n" >>"$T/made"; echo "  workspace:$n  sib-$slug" >>"$WS"; echo "workspace:$n"; }
case "$cmd" in
  spawn)
    while [ $# -gt 0 ]; do case "$1" in --workdir) w=$2; shift ;; --new-workspace) new=1 ;; --) break ;; esac; shift; done
    tries=$(cat "$T/tries.$slug" 2>/dev/null || echo 0); echo $((tries + 1)) >"$T/tries.$slug"
    if [ "$tries" -lt "${FAIL_FIRST:-0}" ]; then [ -n "$new" ] && newws >/dev/null; exit 1; fi
    [ -n "$new" ] && { ws=$(newws); echo "$ws" >"$T/owner.$slug"; echo "  workspace: $ws"; }
    IFS=- read -r _ who rnd _ <<<"$slug"
    SCOUT_NAME=$who SCOUT_ROUND=$rnd "$FAKE" <"$w/task.md" >"$w/answer.json" ;;
  kill) [ -f "$T/owner.$slug" ] && { ws=$(cat "$T/owner.$slug"); grep -vw -- "$ws" "$WS" >"$WS.n"; mv "$WS.n" "$WS"; }; echo "✓ killed $slug" ;;
  trusted) [ -z "$UNTRUSTED" ] || { echo "not trusted: $slug" >&2; exit 1; } ;;
esac
EOF
  chmod +x "$T/bin/cmux" "$T/bin/sib"
}

codex_models() {
  export AGENT_SCOUT_CODEX_MODELS="$T/models_cache.json"
  printf '%s' '{"models":[{"slug":"gpt-6.2-astra","visibility":"list"},{"slug":"gpt-6.10-astra","visibility":"list"},
    {"slug":"gpt-7-astra","visibility":"hide"},{"slug":"gpt-6.11-sol","visibility":"list"}]}' >"$AGENT_SCOUT_CODEX_MODELS"
}

@test "models: a Codex family name runs as the newest listed model of that family; a slug passes through" {
  codex_models
  sed -i.bak 's/^| handoff | codex | scout-handoff | default |/| handoff | codex | scout-handoff | astra |/; s/^- judge: claude:fable/- judge: off/; s/^- vote: on/- vote: off/' "$AGENT_SCOUT_CONFIG"
  mv "$AGENT_SCOUT_CMD" "$T/fake-scout.real"; panes_stub
  for a in volume friction handoff; do printf -- "---\nname: scout-%s\n---\nbody\n" $a >"$T/agents/scout-$a.md"; done
  printf '\n## Panes\n- root: %s/work\n' "$T" >>"$AGENT_SCOUT_CONFIG"
  PATH="$T/bin:$PATH" AGENT_SCOUT_TIMEOUT=30 run "$AS" convene
  [ "$status" -eq 0 ]
  grep -q "spawn scout-handoff-propose-.* --codex --model gpt-6.10-astra" "$T/sib-args"
  grep -q "spawn scout-friction-propose-.* --model sonnet" "$T/sib-args"
}

@test "models: a judge on the same model as a member is refused, family name or slug" {
  codex_models
  sed -i.bak 's/^- judge: claude:fable/- judge: codex:gpt-6.10-astra/; s/^| handoff | codex | scout-handoff | default |/| handoff | codex | scout-handoff | astra |/' "$AGENT_SCOUT_CONFIG"
  run "$AS" convene --json
  [ "$status" -eq 0 ]
  [[ "$output" == *"is also a member"* ]]
}

@test "panes: a finished run closes every workspace it created, failed spawn attempts included" {
  sed -i.bak 's/^- judge: claude:fable/- judge: off/; s/^- vote: on/- vote: off/' "$AGENT_SCOUT_CONFIG"
  mv "$AGENT_SCOUT_CMD" "$T/fake-scout.real"; panes_stub
  for a in volume friction handoff; do printf -- "---\nname: scout-%s\n---\nbody\n" $a >"$T/agents/scout-$a.md"; done
  printf '\n## Panes\n- root: %s/work\n' "$T" >>"$AGENT_SCOUT_CONFIG"
  FAIL_FIRST=2 PATH="$T/bin:$PATH" AGENT_SCOUT_TIMEOUT=30 run "$AS" convene
  [ "$status" -eq 0 ]
  [[ "$output" == *"member volume"*"proposed 2"* ]] || false           # members answered on sib panes
  [ "$(wc -l <"$T/made")" -eq 3 ]                              # two failed attempts left a workspace each, then the committee's
  [ "$(cat "$WS")" = "$(printf '  workspace:1  caller\n* workspace:2  other  [selected]')" ]
}

@test "panes: a pane root sib does not pre-trust stops the meeting before any pane opens" {
  sed -i.bak 's/^- judge: claude:fable/- judge: off/; s/^- vote: on/- vote: off/' "$AGENT_SCOUT_CONFIG"
  mv "$AGENT_SCOUT_CMD" "$T/fake-scout.real"; panes_stub
  printf '\n## Panes\n- root: %s/work\n' "$T" >>"$AGENT_SCOUT_CONFIG"
  UNTRUSTED=1 PATH="$T/bin:$PATH" run "$AS" convene
  [ "$status" -eq 6 ]
  [[ "$output" == *"not pre-trusted"*"trusted-dirs"* ]] || false
  grep -q "^trusted $T/work/2026-11-23-member-round-0" "$T/sib-args"   # asked about a member folder's shape
  ! grep -q "^spawn" "$T/sib-args" || false
  [ -z "$(ls "$AGENT_SCOUT_HR" 2>/dev/null | grep -E 'quorum|failed')" ]   # no meeting record: none was held
  UNTRUSTED=1 PATH="$T/bin:$PATH" run "$AS" evaluate x
  [ "$status" -eq 6 ]
}

@test "board: the live meeting (members, panes, answers, judge), the latest results and the drafts waiting; read only" {
  printf '\n## Panes\n- root: %s/work\n' "$T" >>"$AGENT_SCOUT_CONFIG"
  mkdir -p "$T/bin" "$T/work/2026-11-23-friction-evaluate-4242" "$T/hr/run/2026-11-23-volume-evaluate-4242" "$T/hr/agents"
  echo task >"$T/hr/run/2026-11-23-volume-evaluate-4242/task.md"
  echo '{"reviews":[{"role":"research-helper","verdict":"hire"}]}' >"$T/hr/run/2026-11-23-volume-evaluate-4242/answer.json"
  echo task >"$T/work/2026-11-23-friction-evaluate-4242/task.md"   # still working: no answer yet
  echo "4242 Mon Nov 23 10:00:00 2026     python3 /x/bin/agent-scout evaluate research-helper --days 21" >"$T/ps"
  echo "9999 Mon Nov 23 10:00:00 2026     zsh -c echo agent-scout evaluate not-a-meeting" >>"$T/ps"
  printf '#!/bin/sh\necho "SLUG AGENT SURFACE WORKTREE"\necho "scout-friction-evaluate-4242 claude surface:1 /w (up)"\n' >"$T/bin/sib"
  chmod +x "$T/bin/sib"
  echo '{"date":"2026-11-22","candidates":[{"n":1,"result":"pass","role":"research-helper","support":2,"backers":["volume","friction"]},{"n":2,"result":"drop","role":"gone","support":0,"backers":[]}]}' >"$T/hr/quorum-2026-11-22.json"
  echo '{"id":"eval-2026-11-22-1","results":{"research-helper":{"result":"approve","counts":{"hire":2,"revise":0,"reject":0},"counted":2}}}' >"$T/hr/eval-2026-11-22-1.json"
  printf -- '---\nname: research-helper\n---\n' >"$T/hr/agents/research-helper.md"
  before=$(cd "$T" && find . -type f | sort | xargs cksum)
  PATH="$T/bin:$PATH" AGENT_SCOUT_PS="$T/ps" run "$AS" board
  [ "$status" -eq 0 ]
  [[ "$output" == *"진행 중: 평가 회의"* ]] || false
  [[ "$output" == *"심사 대상: research-helper"* ]] || false
  [[ "$output" != *"not-a-meeting"* ]] || false                          # a shell line that mentions agent-scout is no meeting
  [[ "$output" == *"위원 1/3 답함"* ]] || false
  echo "$output" | grep -E '^  volume .*답함 .*창 닫힘 .*research-helper hire'
  echo "$output" | grep -E '^  friction .*작업 중 .*창 열림'
  echo "$output" | grep -E '^  handoff .*대기'
  echo "$output" | grep -E '^  심판 .*위원 답을 기다리는 중'
  [[ "$output" == *"[통과] research-helper"* && "$output" != *"gone"* ]] || false
  [[ "$output" == *"[승인] research-helper · hire 2"* ]] || false
  [[ "$output" == *"research-helper: 승인됨"*"--user-approved"* ]] || false
  [ "$before" = "$(cd "$T" && find . -type f | sort | xargs cksum)" ]   # read only: nothing written
  AGENT_SCOUT_PS="$T/empty" run "$AS" board
  [[ "$output" == *"진행 중인 회의 없음"* ]]
}

@test "board: a meeting run by Homebrew's framework Python (argv[0] .../MacOS/Python) is still live" {
  mkdir -p "$T/bin"
  py=/opt/homebrew/Cellar/python@3.13/3.13.1/Frameworks/Python.framework/Versions/3.13/Resources/Python.app/Contents/MacOS/Python
  echo "4242 Mon Nov 23 10:00:00 2026     $py /x/bin/agent-scout evaluate research-helper --days 21" >"$T/ps"
  printf '#!/bin/sh\necho "SLUG AGENT SURFACE WORKTREE"\n' >"$T/bin/sib"
  chmod +x "$T/bin/sib"
  PATH="$T/bin:$PATH" AGENT_SCOUT_PS="$T/ps" run "$AS" board
  [ "$status" -eq 0 ]
  echo "$output" | grep -q "진행 중: 평가 회의"        # grep, not [[ ]]: bash 3.2 ignores a failed [[ ]] mid-test
  echo "$output" | grep -q "심사 대상: research-helper"
  ! echo "$output" | grep -q "진행 중인 회의 없음"
}

desk_fixture() {  # fake `brief audit`: 11-23 has LEFT closes the desk left with work, plus one by the user
  export AGENT_SCOUT_BRIEF="$T/brief" AGENT_SCOUT_DESK_EVAL="$T/desk-eval" AGENT_SCOUT_BOARD="$T/board.jsonl"
  cat >"$T/brief" <<'EOF'
#!/usr/bin/env bash
[ "$1" = audit ] || exit 9
if [ "$3" = 2026-11-23 ]; then
  python3 -c 'import json,os; n=int(os.environ.get("LEFT","3")); print(json.dumps([{"by":"desk","verdict":"left","held":[]}]*n
    + [{"by":"user","verdict":"left","held":[]},{"by":"desk","verdict":"ok","held":[[1,2]]}]))'
else
  echo '[]'
fi
EOF
  chmod +x "$T/brief"
  mkdir -p "$T/desk-eval/scores"
  printf '%s\n' '{"set":"v1","versions":[{"spec":"a","accuracy":0.8,"harm":1,"friction":2},{"spec":"current","accuracy":0.9,"harm":2,"friction":0,"vs_prev":{"new_harm":[]}}]}' >"$T/desk-eval/scores/2026-11-22-v1.json"
  printf '%s\n' '{"day":"2026-11-23","asked":40,"avoidable":7,"corrections":99,"miss":4}' >"$T/board.jsonl"
}

@test "measure desk: closes from brief audit and desk-eval, board values only as context; the verdict is the user's" {
  desk_fixture
  run "$AS" measure desk
  [ "$status" -eq 0 ]
  [[ "$output" == *"일 남은 채 닫음  3"* && "$output" == *"고쳐 말함 99"* ]] || false     # board: shown, not counted
  [[ "$output" == *"v1 정답 90% harm 2 괜히 물음 0 새 harm 0"* ]] || false
  [[ "$output" == *"| desk | verdict | 창 11-17..11-23 · 일 남은 채 닫음 3 · 끝났는데 열어 둠 1 "*"| 수정 (일 남은 채 닫음 3 > 1) | by:user"* ]] || false
  run "$AS" measure desk --write                    # nobody writes its own verdict: not without the user
  [ "$status" -eq 3 ]
  ! grep -q "| desk | verdict" "$AGENT_SCOUT_ROSTER" || false
  run "$AS" measure desk --write --by user
  [ "$status" -eq 0 ]
  grep -q "| desk | verdict | .*| 수정 .*| by:user$" "$AGENT_SCOUT_ROSTER"
  run "$AS" measure desk                            # revised last time and it came back: replacement candidate
  [[ "$output" == *"| 교체 후보 (수정 뒤 재발: 일 남은 채 닫음 3) | by:user"* ]] || false
  export LEFT=5
  run "$AS" measure desk --since 2026-11-22
  [[ "$output" == *"| 교체 후보 (일 남은 채 닫음 5 ≥ 5) | by:user"* ]] || false
  export LEFT=0
  run "$AS" measure desk --since 2026-11-22
  [[ "$output" == *"| 유지 | by:user"* ]] || false
  AGENT_SCOUT_TODAY=2026-12-01 run "$AS" measure desk   # no fresh desk-eval: said, not guessed
  [[ "$output" == *"유지 — 이 창의 desk-eval 없음"* && "$output" == *"창보다 오래됨"* ]]
}

@test "measure lead: by:lead lines and their reversals from the Decision log, whoever reversed them" {
  cat >"$AGENT_SCOUT_AREAS" <<'EOF'
## A. tools
### Trial
- Stage: 2
### Decision log
- 11-20 09:00 | answer | by:lead | kill the shell | ref:x
- 11-20 09:05 | answer | by:desk | did not pass on the lead's 11-20 09:00 decision (전달하지 않음) | ref:x
- 11-21 10:00 | answer | by:lead | keep it as a skill | ref:y | reversed_by:the user chose a skill
- 11-22 10:00 | answer | by:lead | commit it locally | ref:z
- 11-22 11:00 | place | by:desk | placed w | ref:w | asked
### Lessons
## B. other
### Decision log
- 11-22 10:00 | answer | by:lead | not this area | ref:q | reversed_by:no
EOF
  run "$AS" measure lead
  [ "$status" -eq 0 ]
  [[ "$output" == *"11-20 09:00 ← by:desk 11-20 09:05"* && "$output" == *"11-21 10:00 ← reversed_by:the user chose a skill"* ]] || false
  [[ "$output" == *"| lead:A | verdict | 창 11-17..11-23 · by:lead 3 · 뒤집힘 2 (67%) · reversed(영역) 2 · asked 1 (하루 0.1) | 1단계로 되돌림"*"| by:user"* ]] || false
  run "$AS" measure lead:A --since 2026-11-22
  [[ "$output" == *"by:lead 1 · 뒤집힘 0 (0%)"*"| 다음 단계 조건 충족 | by:user"* ]] || false
  run "$AS" measure lead --write
  [ "$status" -eq 3 ]
}

@test "measure judge: lifted holds are its only record, and the missing accuracy measure is stated" {
  mkdir -p "$AGENT_SCOUT_HR"
  echo '{"candidates":[{"result":"hold"},{"result":"pass"}]}' >"$AGENT_SCOUT_HR/quorum-2026-11-20.json"
  printf '## Log\n- 11-20 | committee | lifted | kind a was `hold` | by:user | ref:q\n- 11-21 | committee | lifted | kind b was `hold` | by:user | ref:q\n' >"$AGENT_SCOUT_ROSTER"
  run "$AS" measure judge
  [ "$status" -eq 0 ]
  [[ "$output" == *"채점 정확도 지표 없음"* ]] || false
  [[ "$output" == *"| judge | verdict | 창 11-10..11-23 · claude:fable · hold 1 · lifted 2 · 채점 정확도 지표 없음 | 교체 검토 (lifted 2 ≥ 2) | by:user"* ]]
}

@test "members: evaluate --replacing keeps a member off its own seat; a reject the user overrode counts as reversed" {
  run "$AS" new scope-helper --by-user --title "Checks research scope" --kind research --area A --layer L2 --home "$T/l2"
  fill "$AGENT_SCOUT_HR/agents/scope-helper.md"
  run "$AS" evaluate scope-helper --replacing handoff --json
  [ "$status" -eq 0 ]
  [ ! -e "$CALLS.handoff.evaluate" ]
  echo "$output" | python3 -c 'import json,sys; d=json.load(sys.stdin); assert {r["member"] for r in d["results"]["scope-helper"]["reviews"]}=={"volume","friction"}'
  run "$AS" evaluate scope-helper
  run "$AS" install scope-helper --user-approved
  [ "$status" -eq 0 ]
  grep -q "^- scope-helper | agent | .*| 지표: agent-scout measure scope-helper | 교체선: 5.3·5.5 표 | 판정자: user" "$AGENT_SCOUT_ROSTER"
  run "$AS" measure handoff --json
  [ "$status" -eq 0 ]
  echo "$output" | python3 -c 'import json,sys; d=json.load(sys.stdin); assert d["overruled"]==1 and d["reversed"]>=1, d'
  run "$AS" measure handoff
  [[ "$output" == *"거절했는데 사용자가 들인 역할 1"* && "$output" == *"evaluate --replacing handoff"* ]]
}
