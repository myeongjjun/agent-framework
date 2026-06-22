#!/usr/bin/env bash
# live-smoke.sh — live regression check for `sib spawn` prompt injection.
#
# WHY THIS EXISTS (and why it is NOT a bats test):
#   bin/sib drives real TUI agents (claude/codex) by reading their on-screen
#   bytes and timing the enter key. That logic breaks SILENTLY when an agent
#   ships a new version — placeholder text, the queue notice, the prompt marker
#   glyph, or the input-box wrapping changes, and our grep stops matching. The
#   bats suite (tests/sib-spawn.bats) stubs cmux, so it can NEVER catch that
#   class of drift. This script does: it spawns real siblings against the live
#   cmux + real agent binaries, asserts the task was actually SUBMITTED, and
#   asserts spawn→submit stayed under a latency budget. Run it manually after
#   an agent upgrade, or on a schedule.
#
# REQUIREMENTS (why it can't run in GitHub CI): a running cmux.app desktop
#   session (CMUX_WORKSPACE_ID set) plus authenticated claude/codex binaries.
#   None of that exists on a headless CI runner — this is a local-only check.
#
# USAGE:
#   tests/live-smoke.sh                 # claude + codex, default 15s budget
#   tests/live-smoke.sh --budget 20     # custom latency budget (seconds)
#   tests/live-smoke.sh --agents claude # only one agent
#   tests/live-smoke.sh --no-report     # log only, skip the inbox report
#
# EXIT: 0 = all checks passed; 1 = a regression (missed submit or over budget);
#       2 = environment not ready (not in a cmux pane, missing binary).
set -uo pipefail

# --- config -----------------------------------------------------------------
BUDGET=15                       # seconds: spawn→submit ceiling before we flag
AGENTS=(claude codex)
DO_REPORT=1
INBOX="${SIB_SMOKE_INBOX:-$HOME/agent-workspace/.agent/inbox}"
LOG_DIR="${XDG_DATA_HOME:-$HOME/.local/share}/sib"
SOURCE_SLUG="${SIB_SMOKE_SLUG:-sib-live-smoke}"

while (($#)); do case "$1" in
  --budget)    shift; BUDGET="${1:?--budget needs seconds}" ;;
  --agents)    shift; IFS=',' read -ra AGENTS <<<"${1:?--agents needs a list}" ;;
  --no-report) DO_REPORT=0 ;;
  -h|--help)   sed -n '2,33p' "$0"; exit 0 ;;
  *)           echo "live-smoke: unknown arg: $1" >&2; exit 2 ;;
esac; shift || true; done

# --- preconditions ----------------------------------------------------------
[[ -n "${CMUX_WORKSPACE_ID:-}" ]] || { echo "live-smoke: not in a cmux pane (CMUX_WORKSPACE_ID unset)"; exit 2; }
command -v sib  >/dev/null 2>&1 || { echo "live-smoke: sib not on PATH"; exit 2; }
command -v cmux >/dev/null 2>&1 || { echo "live-smoke: cmux not on PATH"; exit 2; }

mkdir -p "$LOG_DIR"
STAMP="$(date +%Y%m%d-%H%M%S)"
LOG="$LOG_DIR/smoke-${STAMP}.log"

# epoch with sub-second precision; falls back to whole seconds if %N is unsupported.
now() { local t; t="$(date +%s.%N)"; [[ "$t" == *N* ]] && date +%s || printf '%s' "$t"; }

# Submission detection is VERSION-DRIFT-PROOF on purpose: we do NOT match
# work-verb vocabulary ("Working", "Discombobulating…", "Brewed for…") — that
# churns every agent release and is the exact drift this script must survive.
# Instead we test the definition of submission: the prompt LEFT the input box.
# submitted_p() returns 0 (submitted) iff the wrap-immune needle is absent from
# the input-box region (everything from the LAST marker line to end of screen).
# The transcript echo of the prompt sits ABOVE that marker, so it's excluded.
submitted_p() {  # $1=screen $2=marker(❯/›) $3=needle(space/newline-stripped)
  local scr="$1" marker="$2" needle="$3" tail
  # Bytes from the last marker occurrence onward = the live input box + footer.
  tail="$(awk -v m="$marker" '{ buf=buf $0 "\n" } $0 ~ m { buf=$0 "\n" } END{ printf "%s", buf }' <<<"$scr")"
  # Fallback: if the marker wasn't found at all, use the whole screen.
  [[ -n "$tail" ]] || tail="$scr"
  local tail_ns; tail_ns="$(printf '%s' "$tail" | tr -d ' \n')"
  ! grep -qF "$needle" <<<"$tail_ns"
}

declare -a RESULTS          # "agent|status|elapsed|detail" per agent
overall=0

log() { printf '%s\n' "$*" | tee -a "$LOG" >&2; }

log "=== sib live-smoke ${STAMP} (budget=${BUDGET}s, agents=${AGENTS[*]}) ==="

run_one() {
  local agent="$1" slug flag prompt start elapsed scr status detail marker needle
  slug="smoke-${agent}-${STAMP}"
  flag=""; marker="❯"
  [[ "$agent" == codex ]] && { flag="--codex"; marker="›"; }
  # A prompt long enough to wrap in a narrow split pane — this is exactly the
  # case that used to spin the submit loop to its 30s cap (the bug we fixed).
  prompt="echo sib-smoke-${agent}-ok and report that this prompt was submitted"
  needle="$(printf '%s' "${prompt:0:24}" | tr -d ' \n')"

  start="$(now)"
  if ! sib spawn "$slug" $flag --workdir /tmp -- "$prompt" >>"$LOG" 2>&1; then
    RESULTS+=("$agent|ERROR|-|spawn command failed (see log)")
    overall=1; return
  fi
  elapsed="$(awk -v a="$(now)" -v b="$start" 'BEGIN{printf "%.1f", a-b}')"

  # Resolve the surface/workspace sib just persisted, then read the pane.
  local envf="${XDG_DATA_HOME:-$HOME/.local/share}/sib/state/${slug}.env"
  local surface workspace
  surface="$(sed -n 's/^surface=//p' "$envf" 2>/dev/null)"
  workspace="$(sed -n 's/^workspace=//p' "$envf" 2>/dev/null)"
  # Poll briefly: sib returns the instant it sends enter, so a single read can
  # race the agent's render. Give submission up to ~3s to show in the box.
  local ok=1
  for _ in $(seq 1 15); do
    scr="$(cmux read-screen --surface "$surface" --workspace "$workspace" --lines 40 2>/dev/null || true)"
    if submitted_p "$scr" "$marker" "$needle"; then ok=0; break; fi
    sleep 0.2
  done

  if (( ok == 0 )); then
    if awk -v e="$elapsed" -v b="$BUDGET" 'BEGIN{exit !(e<=b)}'; then
      status="PASS"; detail="submitted (prompt left the box) in ${elapsed}s"
    else
      status="SLOW"; detail="submitted but took ${elapsed}s > ${BUDGET}s budget"; overall=1
    fi
  else
    status="FAIL"; detail="prompt still in input box after ${elapsed}s (enter not submitted)"; overall=1
  fi

  RESULTS+=("$agent|$status|$elapsed|$detail")
  log "  [$status] $agent — $detail"

  sib kill "$slug" >>"$LOG" 2>&1 || true
}

for a in "${AGENTS[@]}"; do run_one "$a"; done

# --- summary ----------------------------------------------------------------
log "--- summary ---"
for r in "${RESULTS[@]}"; do
  IFS='|' read -r a s e d <<<"$r"
  log "  $a: $s (${e}s) — $d"
done
log "result: $([[ $overall == 0 ]] && echo PASS || echo REGRESSION)  | log: $LOG"

# --- inbox report on regression ---------------------------------------------
if (( overall != 0 && DO_REPORT )); then
  if mkdir -p "$INBOX" 2>/dev/null; then
    report="$INBOX/$(date +%Y%m%d)-${SOURCE_SLUG}-spawn-latency-regression.md"
    {
      echo "---"
      echo "status: new"
      echo "priority: high"
      echo "source: ${SOURCE_SLUG}"
      echo "type: bug"
      echo "affected:"
      echo "  - bin/sib"
      echo "  - tests/live-smoke.sh"
      echo "created: $(date -u +%FT%TZ)"
      echo "---"
      echo
      echo "# sib spawn prompt-injection regression (live smoke)"
      echo
      echo "## Summary"
      echo
      echo "tests/live-smoke.sh detected that \`sib spawn\` either failed to submit"
      echo "the task prompt or exceeded the ${BUDGET}s spawn→submit latency budget."
      echo "This is the class of drift bats cannot catch (real TUI agent output)."
      echo "Likely cause: an agent (claude/codex) shipped a new version that changed"
      echo "the prompt marker, placeholder, queue notice, or input-box wrapping, so"
      echo "bin/sib's screen-scrape match in the submit loop no longer fires."
      echo
      echo "## Evidence / Reproduction"
      echo
      echo '```'
      for r in "${RESULTS[@]}"; do IFS='|' read -r a s e d <<<"$r"; echo "$a: $s (${e}s) — $d"; done
      echo '```'
      echo
      echo "Full log: ${LOG}"
      echo "Re-run: \`tests/live-smoke.sh\` (from the agent-framework repo, inside a cmux pane)."
      echo
      echo "## Proposed action"
      echo
      echo "1. Spawn the affected agent manually and capture \`cmux read-screen ... | cat -A\`."
      echo "2. Compare the live marker / placeholder / queue text against bin/sib's"
      echo "   submit loop (the \`needle\` match and the codex \`tab to queue message\` guard)."
      echo "3. Update the match strings; re-run this smoke script to confirm."
    } > "$report"
    log "📥 inbox report written: $report"
  else
    log "⚠ could not write inbox report (mkdir failed: $INBOX) — log only"
  fi
fi

exit "$overall"
