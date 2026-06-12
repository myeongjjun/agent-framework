#!/bin/bash
# session-start-review.sh - Review previous session's activity on new session start
# @hook event: SessionStart
# @hook timeout: 5
# Non-blocking: always exits 0
#
# Checks yesterday's transcript activity for anomalies.
# If issues found, prints alert to stderr (visible at session start).
#
# Replaces auto-analyze.sh (Stop hook disabled due to cmux.sock timing).
set -uo pipefail

input=$(cat)
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TRACE_AGENT="claude"

find_repo_root() {
  local candidate=""
  local probe=""

  if command -v git >/dev/null 2>&1; then
    candidate="$(git -C "${PWD}" rev-parse --show-toplevel 2>/dev/null || true)"
    if [[ -n "$candidate" && -x "${candidate}/scripts/extract-traces.sh" ]]; then
      printf '%s\n' "$candidate"
      return 0
    fi
  fi

  probe="${PWD}"
  while [[ -n "$probe" && "$probe" != "/" ]]; do
    if [[ -x "${probe}/scripts/extract-traces.sh" ]]; then
      printf '%s\n' "$probe"
      return 0
    fi
    probe="$(dirname "$probe")"
  done

  candidate="$(cd "${SCRIPT_DIR}/../.." && pwd)"
  if [[ -x "${candidate}/scripts/extract-traces.sh" ]]; then
    printf '%s\n' "$candidate"
    return 0
  fi

  return 1
}

case "$SCRIPT_DIR" in
  "${HOME}/.codex/hooks"*)
    TRACE_AGENT="codex"
    ;;
esac

REPO_ROOT="$(find_repo_root 2>/dev/null || true)"
[[ -n "$REPO_ROOT" ]] || exit 0
EXTRACT_SCRIPT="${REPO_ROOT}/scripts/extract-traces.sh"

emit_message() {
  local message="$1"
  printf '%s\n' "$message" >&2
}

# Check yesterday's activity (not today — today just started)
YESTERDAY=$(date -u -v-1d '+%Y-%m-%d' 2>/dev/null || date -u -d 'yesterday' '+%Y-%m-%d' 2>/dev/null)
TRACE_FILE="$(mktemp)"
trap 'rm -f "$TRACE_FILE"' EXIT

# Prefer transcript extraction over the legacy activity JSONL hook logs.
"$EXTRACT_SCRIPT" --agent "$TRACE_AGENT" --days 1 >"$TRACE_FILE" 2>/dev/null || exit 0

# extract-traces --days 1 is calendar-day based, so fall back to an exact-date
# query to preserve the original "review yesterday" behavior.
if ! jq -e --arg day "$YESTERDAY" 'select((.ts // "")[:10] == $day)' "$TRACE_FILE" >/dev/null 2>&1; then
  "$EXTRACT_SCRIPT" --agent "$TRACE_AGENT" --date "$YESTERDAY" >"$TRACE_FILE" 2>/dev/null || exit 0
fi

# Quick metrics via jq
result=$(jq -s --arg day "$YESTERDAY" '
  def consecutive_failures($events; $min):
    (
      $events
      | sort_by((.sid // ""), (.ts // ""))
      | reduce .[] as $e (
          {prev_tool: null, prev_sid: null, count: 0, runs: []};
          if ($e.ok == false) then
            if (.prev_tool == ($e.tool // "") and .prev_sid == ($e.sid // "")) then
              .count += 1
            else
              (if (.count >= $min) then .runs += [{sid: .prev_sid, tool: .prev_tool, count: .count}] else . end)
              | .prev_tool = ($e.tool // "")
              | .prev_sid = ($e.sid // "")
              | .count = 1
            end
          else
            (if (.count >= $min) then .runs += [{sid: .prev_sid, tool: .prev_tool, count: .count}] else . end)
            | .prev_tool = null
            | .prev_sid = null
            | .count = 0
          end
        )
      | if (.count >= $min) then .runs + [{sid: .prev_sid, tool: .prev_tool, count: .count}] else .runs end
    );

  [.[] | select(.evt == "tool" and (.ts // "")[:10] == $day)] as $tools |
  ([$tools[] | select(.tool == "Bash")] | length) as $bash_total |
  ([$tools[] | select(.tool == "Bash" and .ok == false)] | length) as $bash_fail |
  (consecutive_failures($tools; 3)) as $runs |
  {
    total: ($tools | length),
    bash_total: $bash_total,
    bash_fail: $bash_fail,
    bash_rate: (if $bash_total > 0 then ($bash_fail * 100 / $bash_total) else 0 end),
    runs: $runs
  }
' "$TRACE_FILE" 2>/dev/null) || exit 0

bash_rate=$(echo "$result" | jq -r '.bash_rate // 0')
total=$(echo "$result" | jq -r '.total // 0')
run_count=$(echo "$result" | jq -r '.runs | length')

# Only alert if there was meaningful activity
[[ "$total" -gt 10 ]] || exit 0

has_alert=false

# Check threshold
if awk -v rate="$bash_rate" 'BEGIN { exit !(rate > 10) }'; then
  bash_fail=$(echo "$result" | jq -r '.bash_fail // 0')
  bash_total=$(echo "$result" | jq -r '.bash_total // 0')
  emit_message "[session-review] Yesterday's Bash failure rate: ${bash_fail}/${bash_total} (${bash_rate}%)"
  has_alert=true
fi

if [[ "$run_count" -gt 0 ]]; then
  runs_summary=$(echo "$result" | jq -r '.runs[] | "\(.sid): \(.tool) x\(.count)"' 2>/dev/null)
  emit_message "[session-review] Consecutive failure runs detected: ${runs_summary}"
  has_alert=true
fi

if [[ "$has_alert" == true ]]; then
  emit_message "[session-review] Run: ./scripts/analyze-activity.sh --source ${TRACE_AGENT} --days 1 --errors"
fi

# Check for recent handoff entry — suggest /takeover if found
LATEST_MD="${REPO_ROOT}/.agent/LATEST.md"
if [ -f "$LATEST_MD" ]; then
  if [[ "$(uname)" == "Darwin" ]]; then
    latest_mtime=$(stat -f '%m' "$LATEST_MD")
  else
    latest_mtime=$(stat -c '%Y' "$LATEST_MD")
  fi
  now=$(date +%s)
  age_hours=$(( (now - latest_mtime) / 3600 ))
  if [ "$age_hours" -lt 24 ]; then
    emit_message "[session-review] Recent handoff found: .agent/LATEST.md (${age_hours}h ago) -- consider running /takeover"
  fi
fi

exit 0
