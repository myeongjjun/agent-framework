#!/usr/bin/env bats
# Area profiles (docs/area-lead-design.md §9 stage 1: profile only; stage 2: brief lead).
# The desk reads orch-areas.md, follows its permission table, logs decisions,
# and points area sessions at the profile.

ROOT="$BATS_TEST_DIRNAME/.."
SEED="$ROOT/cmux/seeds/orch-areas.md"
ORCH="$ROOT/agents/orch.md"

@test "orch definition: reads orch-areas.md at session start" {
  grep -q '^- `~/.config/cmux/orch-areas.md`' "$ORCH"
  grep -q 'lives in four local files' "$ORCH"
}

@test "orch definition: area permission table replaces the approval rule, never the hard limits" {
  grep -q '^\*Area profiles\.\*' "$ORCH"
  grep -q 'Its permission table replaces the approval rule for that area' "$ORCH"
  grep -q 'never overrides Ask-first areas, \*\*Never\*\*' "$ORCH"
  grep -q 'more cautious area follows that area' "$ORCH"
}

@test "orch definition: reads the decision log first, logs every area decision" {
  grep -q 'read that area.s decision log. A logged decision answers the question' "$ORCH"
  grep -q 'append one line to its decision log' "$ORCH"
  grep -q 'Log a decision the user made in a session pane too' "$ORCH"
}

@test "orch definition: area session briefs carry the profile path" {
  grep -q 'Area profile: `~/.config/cmux/orch-areas.md` (<area>) — read its decision log before you ask the user' "$ORCH"
}

@test "orch definition: may edit only Decision log and Lessons of orch-areas.md" {
  grep -q 'the `Decision log`/`Lessons` sections of `orch-areas.md`' "$ORCH"
}

@test "orch definition: morning report counts asked and reversed per area" {
  grep -q 'count yesterday.s decision-log lines marked `asked` and' "$ORCH"
}

@test "orch-areas seed: one area skeleton with the five sections in order" {
  run awk '/^### /{printf "%s;", $2}' "$SEED"
  [ "$output" = "Scope;Permissions;Trial;Decision;Lessons;" ]
}

@test "orch-areas seed: permission table lists the five decision kinds" {
  for k in place answer close commit rules; do
    grep -q "^| $k |" "$SEED"
  done
}

@test "orch-areas seed: install copies it like the other seeds" {
  # install.sh copies every cmux/seeds/*.md once and links it into ~/.config/cmux/.
  grep -q 'for seed in "${CMUX_SRC}/seeds"/\*.md' "$ROOT/scripts/install.sh"
}

# The counting the morning report relies on, run against a sample log.
count() { grep -c -- "$1" "$2" || true; }

@test "decision log format: asked and reversed_by are countable with grep" {
  log="$BATS_TEST_TMPDIR/areas.md"
  cat >"$log" <<'EOF'
### Decision log
- 11-24 10:00 | answer | by:desk | keep English descriptions | ref:abc123
- 11-24 11:00 | place | by:user | start a session for X | ref:s1 | asked
- 11-24 12:00 | rules | by:desk | rename a field | ref:def456 | reversed_by:ghi789
- 11-24 13:00 | answer | by:lead | keep it | ref:s2
EOF
  [ "$(count '| asked' "$log")" = 1 ]
  [ "$(count '| reversed_by:' "$log")" = 1 ]
  [ "$(count '| by:lead |' "$log")" = 1 ]
  [ "$(grep -c '^- [0-9][0-9]-[0-9][0-9] [0-9][0-9]:[0-9][0-9] | [a-z]* | by:\(user\|desk\|session\|lead\) | ' "$log")" = 4 ]
}

@test "local orch-areas.md (if installed): every decision log line matches the format" {
  f="$HOME/.local/share/cmux/orch/orch-areas.md"
  [ -f "$f" ] || skip "not installed on this machine"
  run awk '
    /^### Decision log/{d=1; next}
    /^#/{d=0}
    d && /^- / && $0 !~ /^- [0-9][0-9]-[0-9][0-9] [0-9][0-9]:[0-9][0-9] \| (place|answer|close|commit|rules) \| by:(user|desk|session|lead) \| / {print "bad: " $0}
  ' "$f"
  [ -z "$output" ]
}

@test "orch definition: stage 2 hands judgment questions to the area lead before the decisions-needed block" {
  grep -q 'The area lead is a one-shot call, not a pane: `brief lead <area>' "$ORCH"
  grep -q 'You MUST call the area lead before you put such a question under `결정 필요`' "$ORCH"
  grep -q 'You MUST NOT override a `by:lead` decision yourself' "$ORCH"
}

@test "no 'PM' name left for the area role" {
  ! grep -n 'PM' "$ORCH" "$SEED" "$ROOT/cmux/brief-lead" "$ROOT/cmux/office/index.html"
  [ ! -e "$ROOT/docs/area-pm-design.md" ]
  [ "$(grep -c 'PM' "$ROOT/docs/area-lead-design.md")" -le 2 ]  # only the naming note quotes the old name
}
