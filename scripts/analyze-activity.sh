#!/usr/bin/env bash

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"

LOG_DIR="${HOME}/.claude/logs"
REPORT_DIR="${LOG_DIR}/reports"
SKILL_DIR="${HOME}/.claude/skills"

RANGE_MODE="all"
DAY_COUNT=""
VIEW_MODE="full"
WRITE_REPORT=false
COMPARE_TAG=""
COMPARE_TAG_DATE=""
COMPARE_TAG_EPOCH=""
SOURCE_MODE=""
READ_STDIN=false
TEMP_INPUT_FILE=""

usage() {
  cat <<'EOF'
Usage: ./scripts/analyze-activity.sh [OPTIONS]

Analyze ~/.claude/logs/activity-*.jsonl files using jq.

OPTIONS:
  --source MODE Analyze transcript data via extract-traces.sh (claude|codex|all)
  --stdin       Read unified JSONL events from stdin
  --today       Analyze today's log file only
  --days N      Analyze the last N days (inclusive)
  --compare TAG Compare metrics before and after the given git tag
  --errors      Show failure-focused output only
  --prompts     Show prompt-focused output only
  --skills      Show skill-focused output only
  --report      Write a markdown report to ~/.claude/logs/reports/activity-YYYY-MM-DD.md
  -h, --help    Show this help message

DEFAULT:
  No arguments analyzes all available activity logs.
EOF
}

die() {
  echo "Error: $*" >&2
  exit 1
}

require_command() {
  command -v "$1" >/dev/null 2>&1 || die "Required command not found: $1"
}

format_pct() {
  local numerator="$1"
  local denominator="$2"
  awk -v num="$numerator" -v den="$denominator" 'BEGIN {
    if (den == 0) {
      printf "0.0"
    } else {
      printf "%.1f", (num / den) * 100
    }
  }'
}

format_avg() {
  local total="$1"
  local count="$2"
  awk -v total="$total" -v count="$count" 'BEGIN {
    if (count == 0) {
      printf "0.0"
    } else {
      printf "%.1f", total / count
    }
  }'
}

calculate_start_date() {
  local days="$1"
  python3 - "$days" <<'PY'
from datetime import date, timedelta
import sys

days = int(sys.argv[1])
if days < 1:
    raise SystemExit("days must be >= 1")

print((date.today() - timedelta(days=days - 1)).isoformat())
PY
}

resolve_compare_tag() {
  [[ -n "$COMPARE_TAG" ]] || return 0

  require_command git

  COMPARE_TAG_DATE="$(
    git -C "$REPO_ROOT" log -1 --format='%ai' "$COMPARE_TAG" 2>/dev/null || true
  )"
  [[ -n "$COMPARE_TAG_DATE" ]] || die "Tag not found: ${COMPARE_TAG}"

  COMPARE_TAG_EPOCH="$(
    python3 - "$COMPARE_TAG_DATE" <<'PY'
from datetime import datetime
import sys

raw = sys.argv[1]
parsed = datetime.strptime(raw, "%Y-%m-%d %H:%M:%S %z")
print(int(parsed.timestamp()))
PY
  )"
}

cleanup_temp_input() {
  if [[ -n "$TEMP_INPUT_FILE" && -f "$TEMP_INPUT_FILE" ]]; then
    rm -f "$TEMP_INPUT_FILE"
  fi
}

build_source_period_label() {
  local today
  local start_date

  today="$(date '+%F')"

  case "$RANGE_MODE" in
    all)
      PERIOD_LABEL="all available [source:${SOURCE_MODE}]"
      ;;
    today)
      PERIOD_LABEL="${today} [source:${SOURCE_MODE}]"
      ;;
    days)
      start_date="$(calculate_start_date "$DAY_COUNT")"
      if [[ "$start_date" == "$today" ]]; then
        PERIOD_LABEL="${today} [source:${SOURCE_MODE}]"
      else
        PERIOD_LABEL="${start_date} ~ ${today} [source:${SOURCE_MODE}]"
      fi
      ;;
    *)
      die "Unsupported range mode: $RANGE_MODE"
      ;;
  esac
}

contains_name() {
  local needle="$1"
  shift || true

  local item
  for item in "$@"; do
    if [[ "$item" == "$needle" ]]; then
      return 0
    fi
  done

  return 1
}

collect_log_files() {
  local today
  local start_date=""
  local file
  local basename
  local file_date

  today="$(date '+%F')"

  case "$RANGE_MODE" in
    all)
      ;;
    today)
      start_date="$today"
      ;;
    days)
      start_date="$(calculate_start_date "$DAY_COUNT")"
      ;;
    *)
      die "Unsupported range mode: $RANGE_MODE"
      ;;
  esac

  shopt -s nullglob
  local candidates=("${LOG_DIR}"/activity-*.jsonl)
  shopt -u nullglob

  SELECTED_FILES=()
  SELECTED_DATES=()

  for file in "${candidates[@]}"; do
    basename="$(basename "$file")"

    if [[ ! "$basename" =~ ^activity-([0-9]{4}-[0-9]{2}-[0-9]{2})\.jsonl$ ]]; then
      continue
    fi

    file_date="${BASH_REMATCH[1]}"

    case "$RANGE_MODE" in
      all)
        SELECTED_FILES+=("$file")
        SELECTED_DATES+=("$file_date")
        ;;
      today)
        if [[ "$file_date" == "$today" ]]; then
          SELECTED_FILES+=("$file")
          SELECTED_DATES+=("$file_date")
        fi
        ;;
      days)
        if [[ "$file_date" > "$today" ]]; then
          continue
        fi
        if [[ "$file_date" < "$start_date" ]]; then
          continue
        fi
        SELECTED_FILES+=("$file")
        SELECTED_DATES+=("$file_date")
        ;;
    esac
  done

  if [[ ${#SELECTED_FILES[@]} -eq 0 ]]; then
    case "$RANGE_MODE" in
      all) die "No activity logs found in ${LOG_DIR}" ;;
      today) die "No activity logs found for ${today}" ;;
      days) die "No activity logs found for the last ${DAY_COUNT} day(s)" ;;
    esac
  fi
}

prepare_source_input() {
  local extract_args=()

  TEMP_INPUT_FILE="$(mktemp "${TMPDIR:-/tmp}/analyze-activity-source.XXXXXX.jsonl")"

  extract_args+=(--agent "$SOURCE_MODE")
  case "$RANGE_MODE" in
    today)
      extract_args+=(--date "$(date '+%F')")
      ;;
    days)
      extract_args+=(--days "$DAY_COUNT")
      ;;
    all)
      extract_args+=(--days 3650)
      ;;
    *)
      die "Unsupported range mode: $RANGE_MODE"
      ;;
  esac

  "${SCRIPT_DIR}/extract-traces.sh" "${extract_args[@]}" >"$TEMP_INPUT_FILE"

  SELECTED_FILES=("$TEMP_INPUT_FILE")
  SELECTED_DATES=()
}

prepare_stdin_input() {
  TEMP_INPUT_FILE="$(mktemp "${TMPDIR:-/tmp}/analyze-activity-stdin.XXXXXX.jsonl")"
  cat >"$TEMP_INPUT_FILE"

  if [[ ! -s "$TEMP_INPUT_FILE" ]]; then
    die "No unified JSONL received on stdin"
  fi

  SELECTED_FILES=("$TEMP_INPUT_FILE")
  SELECTED_DATES=()
}

prepare_input_files() {
  if [[ "$READ_STDIN" == true ]]; then
    prepare_stdin_input
    return
  fi

  if [[ -n "$SOURCE_MODE" ]]; then
    prepare_source_input
    return
  fi

  collect_log_files
}

build_period_label() {
  local last_index

  if [[ "$READ_STDIN" == true ]]; then
    PERIOD_LABEL="stdin"
    return
  fi

  if [[ -n "$SOURCE_MODE" ]]; then
    build_source_period_label
    return
  fi

  if [[ ${#SELECTED_DATES[@]} -eq 1 ]]; then
    PERIOD_LABEL="${SELECTED_DATES[0]}"
  else
    last_index=$((${#SELECTED_DATES[@]} - 1))
    PERIOD_LABEL="${SELECTED_DATES[0]} ~ ${SELECTED_DATES[$last_index]}"
  fi
}

build_summary_json() {
  local scope="${1:-all}"

  jq -s \
    --arg scope "$scope" \
    --argjson cutoff "${COMPARE_TAG_EPOCH:-0}" '
      def scoped_events:
        if $scope == "before" then
          [ .[] | select(
              (try (.ts | fromdateiso8601) catch null) as $ts
              | $ts != null and $ts < $cutoff
            ) ]
        elif $scope == "after" then
          [ .[] | select(
              (try (.ts | fromdateiso8601) catch null) as $ts
              | $ts != null and $ts >= $cutoff
            ) ]
        else
          .
        end;

      def tool_events($events):
        [ $events[] | select(.evt == "tool") ];

      def skill_events($events):
        [ $events[] | select(.evt == "skill") ];

      def prompt_events($events):
        [ $events[] | select(.evt == "prompt") ];

      def agent_breakdown($events):
        [ $events[] | select(.agent != null) ]
        | group_by(.agent)
        | map({
            agent: .[0].agent,
            sessions: ([ .[] | .sid? // empty ] | unique | length),
            tool_calls: ([ .[] | select(.evt == "tool") ] | length),
            failures: ([ .[] | select(.evt == "tool" and .ok == false) ] | length),
            prompts: ([ .[] | select(.evt == "prompt") ] | length),
            skills: ([ .[] | select(.evt == "skill") ] | length)
          })
        | sort_by(.agent);

      def count_by($field; $events):
        $events
        | group_by(.[$field] // "unknown")
        | map({
            name: (.[0][$field] // "unknown"),
            count: length
          })
        | sort_by(-.count, .name);

      def consecutive_failures($events; $min):
        $events
        | sort_by(.sid // "", .ts // "")
        | group_by(.sid // "unknown")
        | map(
            reduce .[] as $event (
              {current: null, runs: []};
              if ($event.ok == false) then
                if (.current != null and .current.tool == ($event.tool // "unknown")) then
                  .current.count += 1
                  | .current.last_ts = ($event.ts // "")
                else
                  (if (.current != null and .current.count >= $min) then
                     .runs += [.current]
                   else
                     .
                   end)
                  | .current = {
                      sid: ($event.sid // "unknown"),
                      tool: ($event.tool // "unknown"),
                      count: 1,
                      first_ts: ($event.ts // ""),
                      last_ts: ($event.ts // "")
                    }
                end
              else
                (if (.current != null and .current.count >= $min) then
                   .runs += [.current]
                 else
                   .
                 end)
                | .current = null
              end
            )
            | if (.current != null and .current.count >= $min) then
                .runs + [.current]
              else
                .runs
              end
          )
        | add // [];

      def prompt_tool_counts($events):
        [ $events[] | select(.evt == "prompt" or .evt == "tool") ]
        | sort_by(.sid // "", .ts // "")
        | group_by(.sid // "unknown")
        | map(
            reduce .[] as $event (
              {current: null, counts: []};
              if ($event.evt == "prompt") then
                (if .current != null then
                   .counts += [.current]
                 else
                   .
                 end)
                | .current = {
                    sid: ($event.sid // "unknown"),
                    ts: ($event.ts // ""),
                    text: ($event.text // ""),
                    tool_count: 0
                  }
              elif ($event.evt == "tool" and .current != null) then
                .current.tool_count += 1
              else
                .
              end
            )
            | if .current != null then
                .counts + [.current]
              else
                .counts
              end
          )
        | add // [];

      (scoped_events) as $events
      | (tool_events($events)) as $tools
      | (skill_events($events)) as $skills
      | (prompt_events($events)) as $prompts
      | (count_by("tool"; $tools)) as $tool_counts
      | (count_by("skill"; $skills)) as $skill_counts
      | (count_by("sid"; $prompts)
          | map({
              sid: .name,
              count: .count
            })) as $prompt_session_counts
      | (consecutive_failures($tools; 3)) as $runs
      | (prompt_tool_counts($events)) as $prompt_tool_stats
      | ($prompts
          | map(select((.text // "") | test("다시|아니|그거 말고|틀렸|아닌데")))
          | length) as $correction_prompts
      | ($prompts
          | map({
              pattern: ((.text // "") | gsub("\\s+"; " ") | .[0:50]),
              count: 1
            })
          | group_by(.pattern)
          | map({
              pattern: .[0].pattern,
              count: length
            })
          | map(select(.pattern != "" and .count > 1))
          | sort_by(-.count, .pattern)) as $repeated_prompt_patterns
      | {
          total_tool_calls: ($tools | length),
          unique_sessions: ([ $events[] | .sid? // empty ] | unique | length),
          total_failures: ($tools | map(select(.ok == false)) | length),
          bash_tool_calls: ($tools | map(select((.tool // "") == "Bash")) | length),
          bash_failures: ($tools | map(select((.tool // "") == "Bash" and .ok == false)) | length),
          top_tools: ($tool_counts[:10]),
          tool_counts: $tool_counts,
          skill_counts: $skill_counts,
          skill_invocations: ($skills | length),
          invoked_skills: ($skill_counts | map(.name)),
          total_prompts: ($prompts | length),
          prompt_session_counts: $prompt_session_counts,
          prompt_tool_counts: $prompt_tool_stats,
          avg_tool_calls_per_prompt: (
            if ($prompt_tool_stats | length) == 0 then
              0
            else
              (($prompt_tool_stats | map(.tool_count) | add) / ($prompt_tool_stats | length))
            end
          ),
          correction_prompts: $correction_prompts,
          repeated_prompt_patterns: $repeated_prompt_patterns,
          consecutive_failure_runs: $runs,
          alert_failure_runs: ($runs | map(select(.count > 3))),
          agent_breakdown: (agent_breakdown($events))
        }
    ' "${SELECTED_FILES[@]}"
}

load_deployed_skill_data() {
  local summary_json="${1:-$SUMMARY_JSON}"
  local skill_dir

  DEPLOYED_SKILLS=()
  if [[ -d "$SKILL_DIR" ]]; then
    while IFS= read -r skill_dir; do
      [[ -n "$skill_dir" ]] || continue
      DEPLOYED_SKILLS+=("$(basename "$skill_dir")")
    done < <(find "$SKILL_DIR" -mindepth 1 -maxdepth 1 -type d ! -name '.*' | sort)
  fi

  mapfile -t INVOKED_SKILLS < <(jq -r '.invoked_skills[]?' <<<"$summary_json")

  UNUSED_SKILLS=()
  local skill_name
  for skill_name in "${DEPLOYED_SKILLS[@]}"; do
    if ! contains_name "$skill_name" "${INVOKED_SKILLS[@]}"; then
      UNUSED_SKILLS+=("$skill_name")
    fi
  done
}

load_scalar_metrics() {
  local summary_json="${1:-$SUMMARY_JSON}"

  TOTAL_TOOL_CALLS="$(jq -r '.total_tool_calls' <<<"$summary_json")"
  UNIQUE_SESSIONS="$(jq -r '.unique_sessions' <<<"$summary_json")"
  TOTAL_FAILURES="$(jq -r '.total_failures' <<<"$summary_json")"
  BASH_TOOL_CALLS="$(jq -r '.bash_tool_calls' <<<"$summary_json")"
  BASH_FAILURES="$(jq -r '.bash_failures' <<<"$summary_json")"
  SKILL_INVOCATIONS="$(jq -r '.skill_invocations' <<<"$summary_json")"
  TOTAL_PROMPTS="$(jq -r '.total_prompts' <<<"$summary_json")"
  CORRECTION_PROMPTS="$(jq -r '.correction_prompts' <<<"$summary_json")"
  AVG_TOOL_CALLS_PER_PROMPT="$(jq -r '.avg_tool_calls_per_prompt' <<<"$summary_json")"

  FAILURE_RATE_PCT="$(format_pct "$TOTAL_FAILURES" "$TOTAL_TOOL_CALLS")"
  BASH_FAILURE_RATE_PCT="$(format_pct "$BASH_FAILURES" "$BASH_TOOL_CALLS")"
  CORRECTION_RATE_PCT="$(format_pct "$CORRECTION_PROMPTS" "$TOTAL_PROMPTS")"
  AVG_PROMPTS_PER_SESSION="$(format_avg "$TOTAL_PROMPTS" "$UNIQUE_SESSIONS")"
  AVG_TOOL_CALLS_PER_PROMPT="$(awk -v value="$AVG_TOOL_CALLS_PER_PROMPT" 'BEGIN { printf "%.1f", value }')"
}

activate_summary() {
  SUMMARY_JSON="$1"
  load_deployed_skill_data "$SUMMARY_JSON"
  load_scalar_metrics "$SUMMARY_JSON"
}

print_top_tools() {
  local lines=()
  mapfile -t lines < <(jq -r '.top_tools[]? | "\(.name)\t\(.count)"' <<<"$SUMMARY_JSON")

  echo "Per-tool usage (top 10):"
  if [[ ${#lines[@]} -eq 0 ]]; then
    echo "  (none)"
    return
  fi

  local line
  local name
  local count
  for line in "${lines[@]}"; do
    name="${line%%$'\t'*}"
    count="${line##*$'\t'}"
    printf '  %-24s %s\n' "$name" "$count"
  done
}

print_skill_usage() {
  local lines=()
  mapfile -t lines < <(jq -r '.skill_counts[]? | "\(.name)\t\(.count)"' <<<"$SUMMARY_JSON")

  echo "/slash skill invocation frequency:"
  if [[ ${#lines[@]} -eq 0 ]]; then
    echo "  (none)"
  else
    local line
    local name
    local count
    for line in "${lines[@]}"; do
      name="${line%%$'\t'*}"
      count="${line##*$'\t'}"
      printf '  %-24s %s\n' "$name" "$count"
    done
  fi

  echo "Unused skills:"
  if [[ ${#UNUSED_SKILLS[@]} -eq 0 ]]; then
    echo "  (none)"
    return
  fi

  local skill_name
  for skill_name in "${UNUSED_SKILLS[@]}"; do
    echo "  $skill_name"
  done
}

print_consecutive_failure_runs() {
  local lines=()
  mapfile -t lines < <(jq -r '.consecutive_failure_runs[]? | "\(.sid)\t\(.tool)\t\(.count)\t\(.first_ts)\t\(.last_ts)"' <<<"$SUMMARY_JSON")

  echo "Consecutive failure runs (3+):"
  if [[ ${#lines[@]} -eq 0 ]]; then
    echo "  (none)"
    return
  fi

  local line
  local sid
  local tool
  local count
  local first_ts
  local last_ts
  for line in "${lines[@]}"; do
    IFS=$'\t' read -r sid tool count first_ts last_ts <<<"$line"
    printf '  %s | %s | %s failures | %s -> %s\n' "$sid" "$tool" "$count" "$first_ts" "$last_ts"
  done
}

print_threshold_alerts() {
  local alert_lines=()
  local has_alerts=false

  echo "Threshold alerts:"

  if awk -v rate="$BASH_FAILURE_RATE_PCT" 'BEGIN { exit !(rate > 10.0) }'; then
    has_alerts=true
    echo "  ALERT: Bash failure rate ${BASH_FAILURE_RATE_PCT}% (threshold: 10.0%)"
  fi

  mapfile -t alert_lines < <(jq -r '.alert_failure_runs[]? | "\(.sid)\t\(.tool)\t\(.count)\t\(.first_ts)\t\(.last_ts)"' <<<"$SUMMARY_JSON")
  if [[ ${#alert_lines[@]} -gt 0 ]]; then
    has_alerts=true
    local line
    local sid
    local tool
    local count
    local first_ts
    local last_ts
    for line in "${alert_lines[@]}"; do
      IFS=$'\t' read -r sid tool count first_ts last_ts <<<"$line"
      echo "  ALERT: ${count} consecutive ${tool} failures in session ${sid} (${first_ts} -> ${last_ts})"
    done
  fi

  if [[ "$has_alerts" == false ]]; then
    echo "  (none)"
  fi
}

print_agent_breakdown() {
  local lines=()

  mapfile -t lines < <(jq -r '.agent_breakdown[]? | "\(.agent)\t\(.sessions)\t\(.prompts)\t\(.tool_calls)\t\(.failures)\t\(.skills)"' <<<"$SUMMARY_JSON")

  if [[ ${#lines[@]} -eq 0 ]]; then
    return
  fi

  echo "Per-agent breakdown:"

  local line
  local agent
  local sessions
  local prompts
  local tool_calls
  local failures
  local skills
  local failure_rate

  for line in "${lines[@]}"; do
    IFS=$'\t' read -r agent sessions prompts tool_calls failures skills <<<"$line"
    failure_rate="$(format_pct "$failures" "$tool_calls")"
    printf '  %-8s sessions=%-4s prompts=%-4s tools=%-4s failures=%-4s failure_rate=%s%% skills=%s\n' \
      "$agent" "$sessions" "$prompts" "$tool_calls" "$failures" "$failure_rate" "$skills"
  done
}

print_full_summary() {
  echo "Agent Activity Summary"
  echo "Period: ${PERIOD_LABEL}"
  echo "Log files: ${#SELECTED_FILES[@]}"
  echo
  echo "Total tool calls: ${TOTAL_TOOL_CALLS}"
  echo "Unique sessions: ${UNIQUE_SESSIONS}"
  echo "Failure rate: ${FAILURE_RATE_PCT}% (${TOTAL_FAILURES}/${TOTAL_TOOL_CALLS})"
  echo "Bash failure rate: ${BASH_FAILURE_RATE_PCT}% (${BASH_FAILURES}/${BASH_TOOL_CALLS})"
  echo "Skill invocations: ${SKILL_INVOCATIONS}"
  echo "Total prompts: ${TOTAL_PROMPTS}"
  echo "Avg tool calls per prompt: ${AVG_TOOL_CALLS_PER_PROMPT}"
  echo "Correction rate: ${CORRECTION_RATE_PCT}% (${CORRECTION_PROMPTS}/${TOTAL_PROMPTS})"
  echo
  print_agent_breakdown
  echo
  print_threshold_alerts
  echo
  print_top_tools
  echo
  print_consecutive_failure_runs
  echo
  print_skill_usage
}

print_error_summary() {
  echo "Agent Activity Error Summary"
  echo "Period: ${PERIOD_LABEL}"
  echo "Log files: ${#SELECTED_FILES[@]}"
  echo
  echo "Total tool calls: ${TOTAL_TOOL_CALLS}"
  echo "Total failures: ${TOTAL_FAILURES}"
  echo "Failure rate: ${FAILURE_RATE_PCT}% (${TOTAL_FAILURES}/${TOTAL_TOOL_CALLS})"
  echo "Bash failure rate: ${BASH_FAILURE_RATE_PCT}% (${BASH_FAILURES}/${BASH_TOOL_CALLS})"
  echo
  print_agent_breakdown
  echo
  print_threshold_alerts
  echo
  print_consecutive_failure_runs
}

print_skill_summary() {
  echo "Agent Activity Skill Summary"
  echo "Period: ${PERIOD_LABEL}"
  echo "Log files: ${#SELECTED_FILES[@]}"
  echo
  echo "Skill invocations: ${SKILL_INVOCATIONS}"
  echo "Unused skills: ${#UNUSED_SKILLS[@]}"
  echo
  print_agent_breakdown
  echo
  print_skill_usage
}

print_prompt_summary() {
  local session_lines=()
  local pattern_lines=()

  echo "Agent Activity Prompt Summary"
  echo "Period: ${PERIOD_LABEL}"
  echo "Log files: ${#SELECTED_FILES[@]}"
  echo
  echo "Total prompts: ${TOTAL_PROMPTS}"
  echo "Prompts per session: ${AVG_PROMPTS_PER_SESSION} avg"
  echo "Avg tool calls per prompt: ${AVG_TOOL_CALLS_PER_PROMPT}"
  echo "Correction rate: ${CORRECTION_RATE_PCT}% (${CORRECTION_PROMPTS}/${TOTAL_PROMPTS})"
  echo
  print_agent_breakdown
  echo

  echo "Prompt counts by session:"
  mapfile -t session_lines < <(jq -r '.prompt_session_counts[]? | "\(.sid)\t\(.count)"' <<<"$SUMMARY_JSON")
  if [[ ${#session_lines[@]} -eq 0 ]]; then
    echo "  (none)"
  else
    local line
    local sid
    local count
    for line in "${session_lines[@]}"; do
      IFS=$'\t' read -r sid count <<<"$line"
      printf '  %-36s %s\n' "$sid" "$count"
    done
  fi

  echo
  echo "Repeated prompt patterns (>1):"
  mapfile -t pattern_lines < <(jq -r '.repeated_prompt_patterns[]? | "\(.pattern)\t\(.count)"' <<<"$SUMMARY_JSON")
  if [[ ${#pattern_lines[@]} -eq 0 ]]; then
    echo "  (none)"
  else
    local line
    local pattern
    local count
    for line in "${pattern_lines[@]}"; do
      pattern="${line%%$'\t'*}"
      count="${line##*$'\t'}"
      printf '  [%s] %s\n' "$count" "$pattern"
    done
  fi
}

write_report() {
  local report_date
  report_date="$(date '+%F')"
  mkdir -p "$REPORT_DIR"

  REPORT_PATH="${REPORT_DIR}/activity-${report_date}.md"

  {
    echo "# Agent Activity Report"
    echo "> Period: ${PERIOD_LABEL}"
    echo
    echo "## Raw Metrics"
    echo "| Metric | Value |"
    echo "|--------|-------|"
    echo "| Total tool calls | ${TOTAL_TOOL_CALLS} |"
    echo "| Sessions | ${UNIQUE_SESSIONS} |"
    echo "| Failure rate | ${FAILURE_RATE_PCT}% (${TOTAL_FAILURES}/${TOTAL_TOOL_CALLS}) |"
    echo "| Bash failure rate | ${BASH_FAILURE_RATE_PCT}% (${BASH_FAILURES}/${BASH_TOOL_CALLS}) |"
    echo "| Skill invocations | ${SKILL_INVOCATIONS} |"
    echo "| Unused skills | ${#UNUSED_SKILLS[@]} |"
    echo
    echo "## Per-Agent Breakdown"
    echo "| Agent | Sessions | Prompts | Tool calls | Failures | Failure rate | Skills |"
    echo "|-------|----------|---------|------------|----------|--------------|--------|"
    mapfile -t report_agent_lines < <(jq -r '.agent_breakdown[]? | "\(.agent)\t\(.sessions)\t\(.prompts)\t\(.tool_calls)\t\(.failures)\t\(.skills)"' <<<"$SUMMARY_JSON")
    if [[ ${#report_agent_lines[@]} -eq 0 ]]; then
      echo "| (none) | 0 | 0 | 0 | 0 | 0.0% | 0 |"
    else
      local report_line
      local agent
      local sessions
      local prompts
      local tool_calls
      local failures
      local skills
      local failure_rate
      for report_line in "${report_agent_lines[@]}"; do
        IFS=$'\t' read -r agent sessions prompts tool_calls failures skills <<<"$report_line"
        failure_rate="$(format_pct "$failures" "$tool_calls")"
        echo "| ${agent} | ${sessions} | ${prompts} | ${tool_calls} | ${failures} | ${failure_rate}% | ${skills} |"
      done
    fi
    echo
    echo "## Prompt Analysis"
    echo "| Metric | Value |"
    echo "|--------|-------|"
    echo "| Total prompts | ${TOTAL_PROMPTS} |"
    echo "| Prompts per session | ${AVG_PROMPTS_PER_SESSION} avg (${TOTAL_PROMPTS}/${UNIQUE_SESSIONS}) |"
    echo "| Avg tool calls per prompt | ${AVG_TOOL_CALLS_PER_PROMPT} |"
    echo "| Correction rate | ${CORRECTION_RATE_PCT}% (${CORRECTION_PROMPTS}/${TOTAL_PROMPTS}) |"
    echo
    echo "### Prompt Counts by Session"
    echo "| Session | Prompts |"
    echo "|---------|---------|"
    mapfile -t report_prompt_session_lines < <(jq -r '.prompt_session_counts[]? | "\(.sid)\t\(.count)"' <<<"$SUMMARY_JSON")
    if [[ ${#report_prompt_session_lines[@]} -eq 0 ]]; then
      echo "| (none) | 0 |"
    else
      local report_line
      local sid
      local count
      for report_line in "${report_prompt_session_lines[@]}"; do
        IFS=$'\t' read -r sid count <<<"$report_line"
        echo "| ${sid} | ${count} |"
      done
    fi
    echo
    echo "### Repeated Prompt Patterns"
    echo "| Pattern (first 50 chars) | Count |"
    echo "|--------------------------|-------|"
    mapfile -t report_prompt_pattern_lines < <(jq -r '.repeated_prompt_patterns[]? | "\(.pattern)\t\(.count)"' <<<"$SUMMARY_JSON")
    if [[ ${#report_prompt_pattern_lines[@]} -eq 0 ]]; then
      echo "| (none) | 0 |"
    else
      local report_line
      local pattern
      local escaped_pattern
      local count
      for report_line in "${report_prompt_pattern_lines[@]}"; do
        pattern="${report_line%%$'\t'*}"
        escaped_pattern="${pattern//|/\\|}"
        count="${report_line##*$'\t'}"
        echo "| ${escaped_pattern} | ${count} |"
      done
    fi
    echo
    echo "## Threshold Alerts"
    if awk -v rate="$BASH_FAILURE_RATE_PCT" 'BEGIN { exit !(rate > 10.0) }'; then
      echo "- ALERT: Bash failure rate ${BASH_FAILURE_RATE_PCT}% (threshold: 10.0%)"
    fi

    mapfile -t report_alert_lines < <(jq -r '.alert_failure_runs[]? | "\(.sid)\t\(.tool)\t\(.count)\t\(.first_ts)\t\(.last_ts)"' <<<"$SUMMARY_JSON")
    if [[ ${#report_alert_lines[@]} -eq 0 ]] && ! awk -v rate="$BASH_FAILURE_RATE_PCT" 'BEGIN { exit !(rate > 10.0) }'; then
      echo "- None"
    else
      local report_line
      local sid
      local tool
      local count
      local first_ts
      local last_ts
      for report_line in "${report_alert_lines[@]}"; do
        IFS=$'\t' read -r sid tool count first_ts last_ts <<<"$report_line"
        echo "- ALERT: ${count} consecutive ${tool} failures in session ${sid} (${first_ts} -> ${last_ts})"
      done
    fi

    echo
    echo "## Top Tools"
    echo "| Tool | Count |"
    echo "|------|-------|"
    mapfile -t report_tool_lines < <(jq -r '.top_tools[]? | "\(.name)\t\(.count)"' <<<"$SUMMARY_JSON")
    if [[ ${#report_tool_lines[@]} -eq 0 ]]; then
      echo "| (none) | 0 |"
    else
      local report_line
      local name
      local count
      for report_line in "${report_tool_lines[@]}"; do
        name="${report_line%%$'\t'*}"
        count="${report_line##*$'\t'}"
        echo "| ${name} | ${count} |"
      done
    fi

    echo
    echo "## Consecutive Failure Runs"
    echo "| Session | Tool | Count | Window |"
    echo "|---------|------|-------|--------|"
    mapfile -t report_run_lines < <(jq -r '.consecutive_failure_runs[]? | "\(.sid)\t\(.tool)\t\(.count)\t\(.first_ts)\t\(.last_ts)"' <<<"$SUMMARY_JSON")
    if [[ ${#report_run_lines[@]} -eq 0 ]]; then
      echo "| (none) | - | 0 | - |"
    else
      local report_line
      local sid
      local tool
      local count
      local first_ts
      local last_ts
      for report_line in "${report_run_lines[@]}"; do
        IFS=$'\t' read -r sid tool count first_ts last_ts <<<"$report_line"
        echo "| ${sid} | ${tool} | ${count} | ${first_ts} -> ${last_ts} |"
      done
    fi

    echo
    echo "## Skill Usage"
    echo "| Skill | Count |"
    echo "|-------|-------|"
    mapfile -t report_skill_lines < <(jq -r '.skill_counts[]? | "\(.name)\t\(.count)"' <<<"$SUMMARY_JSON")
    if [[ ${#report_skill_lines[@]} -eq 0 ]]; then
      echo "| (none) | 0 |"
    else
      local report_line
      local name
      local count
      for report_line in "${report_skill_lines[@]}"; do
        name="${report_line%%$'\t'*}"
        count="${report_line##*$'\t'}"
        echo "| ${name} | ${count} |"
      done
    fi

    echo
    echo "## Unused Skills"
    if [[ ${#UNUSED_SKILLS[@]} -eq 0 ]]; then
      echo "- None"
    else
      local skill_name
      for skill_name in "${UNUSED_SKILLS[@]}"; do
        echo "- ${skill_name}"
      done
    fi
  } >"$REPORT_PATH"
}

json_value() {
  local summary_json="$1"
  local query="$2"
  jq -r "$query" <<<"$summary_json"
}

format_delta() {
  local before="$1"
  local after="$2"
  local precision="${3:-1}"
  local suffix="${4:-}"

  awk -v before="$before" -v after="$after" -v precision="$precision" -v suffix="$suffix" 'BEGIN {
    diff = after - before
    if (diff > 0) {
      arrow = "↑"
      value = diff
    } else if (diff < 0) {
      arrow = "↓"
      value = diff * -1
    } else {
      arrow = "→"
      value = 0
    }

    if (precision == 0) {
      printf "%s%d%s", arrow, value, suffix
    } else {
      printf "%s%.*f%s", arrow, precision, value, suffix
    }
  }'
}

print_compare_overview() {
  local before_json="$1"
  local after_json="$2"

  local before_total_tool_calls
  local after_total_tool_calls
  local before_unique_sessions
  local after_unique_sessions
  local before_total_failures
  local after_total_failures
  local before_bash_calls
  local after_bash_calls
  local before_bash_failures
  local after_bash_failures
  local before_skill_invocations
  local after_skill_invocations
  local before_total_prompts
  local after_total_prompts
  local before_correction_prompts
  local after_correction_prompts
  local before_avg_tool_calls
  local after_avg_tool_calls
  local before_failure_rate
  local after_failure_rate
  local before_bash_failure_rate
  local after_bash_failure_rate
  local before_correction_rate
  local after_correction_rate
  local before_distinct_skills
  local after_distinct_skills

  before_total_tool_calls="$(json_value "$before_json" '.total_tool_calls')"
  after_total_tool_calls="$(json_value "$after_json" '.total_tool_calls')"
  before_unique_sessions="$(json_value "$before_json" '.unique_sessions')"
  after_unique_sessions="$(json_value "$after_json" '.unique_sessions')"
  before_total_failures="$(json_value "$before_json" '.total_failures')"
  after_total_failures="$(json_value "$after_json" '.total_failures')"
  before_bash_calls="$(json_value "$before_json" '.bash_tool_calls')"
  after_bash_calls="$(json_value "$after_json" '.bash_tool_calls')"
  before_bash_failures="$(json_value "$before_json" '.bash_failures')"
  after_bash_failures="$(json_value "$after_json" '.bash_failures')"
  before_skill_invocations="$(json_value "$before_json" '.skill_invocations')"
  after_skill_invocations="$(json_value "$after_json" '.skill_invocations')"
  before_total_prompts="$(json_value "$before_json" '.total_prompts')"
  after_total_prompts="$(json_value "$after_json" '.total_prompts')"
  before_correction_prompts="$(json_value "$before_json" '.correction_prompts')"
  after_correction_prompts="$(json_value "$after_json" '.correction_prompts')"
  before_avg_tool_calls="$(awk -v value="$(json_value "$before_json" '.avg_tool_calls_per_prompt')" 'BEGIN { printf "%.1f", value }')"
  after_avg_tool_calls="$(awk -v value="$(json_value "$after_json" '.avg_tool_calls_per_prompt')" 'BEGIN { printf "%.1f", value }')"
  before_failure_rate="$(format_pct "$before_total_failures" "$before_total_tool_calls")"
  after_failure_rate="$(format_pct "$after_total_failures" "$after_total_tool_calls")"
  before_bash_failure_rate="$(format_pct "$before_bash_failures" "$before_bash_calls")"
  after_bash_failure_rate="$(format_pct "$after_bash_failures" "$after_bash_calls")"
  before_correction_rate="$(format_pct "$before_correction_prompts" "$before_total_prompts")"
  after_correction_rate="$(format_pct "$after_correction_prompts" "$after_total_prompts")"
  before_distinct_skills="$(json_value "$before_json" '.invoked_skills | length')"
  after_distinct_skills="$(json_value "$after_json" '.invoked_skills | length')"

  echo "Agent Activity Comparison"
  echo "Range: ${PERIOD_LABEL}"
  echo "Tag: ${COMPARE_TAG}"
  echo "Tag date: ${COMPARE_TAG_DATE}"
  echo
  echo "Failure rate: ${before_failure_rate}% → ${after_failure_rate}% ($(format_delta "$before_failure_rate" "$after_failure_rate" 1 "%"))"
  echo "Bash failure rate: ${before_bash_failure_rate}% → ${after_bash_failure_rate}% ($(format_delta "$before_bash_failure_rate" "$after_bash_failure_rate" 1 "%"))"
  echo "Total failures: ${before_total_failures} → ${after_total_failures} ($(format_delta "$before_total_failures" "$after_total_failures" 0))"
  echo "Total tool calls: ${before_total_tool_calls} → ${after_total_tool_calls} ($(format_delta "$before_total_tool_calls" "$after_total_tool_calls" 0))"
  echo "Unique sessions: ${before_unique_sessions} → ${after_unique_sessions} ($(format_delta "$before_unique_sessions" "$after_unique_sessions" 0))"
  echo "Skill invocations: ${before_skill_invocations} → ${after_skill_invocations} ($(format_delta "$before_skill_invocations" "$after_skill_invocations" 0))"
  echo "Total prompts: ${before_total_prompts} → ${after_total_prompts} ($(format_delta "$before_total_prompts" "$after_total_prompts" 0))"
  echo "Avg tool calls per prompt: ${before_avg_tool_calls} → ${after_avg_tool_calls} ($(format_delta "$before_avg_tool_calls" "$after_avg_tool_calls" 1))"
  echo "Correction rate: ${before_correction_rate}% → ${after_correction_rate}% ($(format_delta "$before_correction_rate" "$after_correction_rate" 1 "%"))"
  echo "Distinct invoked skills: ${before_distinct_skills} → ${after_distinct_skills} ($(format_delta "$before_distinct_skills" "$after_distinct_skills" 0))"
}

print_compare_sections() {
  local before_json="$1"
  local after_json="$2"
  local original_period_label="$PERIOD_LABEL"

  echo
  PERIOD_LABEL="Before ${COMPARE_TAG} (< ${COMPARE_TAG_DATE})"
  activate_summary "$before_json"
  case "$VIEW_MODE" in
    full) print_full_summary ;;
    errors) print_error_summary ;;
    prompts) print_prompt_summary ;;
    skills) print_skill_summary ;;
  esac

  echo
  PERIOD_LABEL="After ${COMPARE_TAG} (>= ${COMPARE_TAG_DATE})"
  activate_summary "$after_json"
  case "$VIEW_MODE" in
    full) print_full_summary ;;
    errors) print_error_summary ;;
    prompts) print_prompt_summary ;;
    skills) print_skill_summary ;;
  esac

  PERIOD_LABEL="$original_period_label"
}

write_compare_report() {
  local before_json="$1"
  local after_json="$2"
  local report_date
  local safe_tag
  local before_total_tool_calls
  local after_total_tool_calls
  local before_total_failures
  local after_total_failures
  local before_bash_calls
  local after_bash_calls
  local before_bash_failures
  local after_bash_failures
  local before_total_prompts
  local after_total_prompts
  local before_correction_prompts
  local after_correction_prompts
  local before_failure_rate
  local after_failure_rate
  local before_bash_failure_rate
  local after_bash_failure_rate
  local before_correction_rate
  local after_correction_rate

  report_date="$(date '+%F')"
  safe_tag="${COMPARE_TAG//\//-}"
  mkdir -p "$REPORT_DIR"
  REPORT_PATH="${REPORT_DIR}/activity-compare-${safe_tag}-${report_date}.md"

  before_total_tool_calls="$(json_value "$before_json" '.total_tool_calls')"
  after_total_tool_calls="$(json_value "$after_json" '.total_tool_calls')"
  before_total_failures="$(json_value "$before_json" '.total_failures')"
  after_total_failures="$(json_value "$after_json" '.total_failures')"
  before_bash_calls="$(json_value "$before_json" '.bash_tool_calls')"
  after_bash_calls="$(json_value "$after_json" '.bash_tool_calls')"
  before_bash_failures="$(json_value "$before_json" '.bash_failures')"
  after_bash_failures="$(json_value "$after_json" '.bash_failures')"
  before_total_prompts="$(json_value "$before_json" '.total_prompts')"
  after_total_prompts="$(json_value "$after_json" '.total_prompts')"
  before_correction_prompts="$(json_value "$before_json" '.correction_prompts')"
  after_correction_prompts="$(json_value "$after_json" '.correction_prompts')"
  before_failure_rate="$(format_pct "$before_total_failures" "$before_total_tool_calls")"
  after_failure_rate="$(format_pct "$after_total_failures" "$after_total_tool_calls")"
  before_bash_failure_rate="$(format_pct "$before_bash_failures" "$before_bash_calls")"
  after_bash_failure_rate="$(format_pct "$after_bash_failures" "$after_bash_calls")"
  before_correction_rate="$(format_pct "$before_correction_prompts" "$before_total_prompts")"
  after_correction_rate="$(format_pct "$after_correction_prompts" "$after_total_prompts")"

  {
    echo "# Agent Activity Comparison Report"
    echo "> Range: ${PERIOD_LABEL}"
    echo "> Tag: ${COMPARE_TAG}"
    echo "> Tag date: ${COMPARE_TAG_DATE}"
    echo
    echo "## Metric Delta"
    echo "| Metric | Before | After | Delta |"
    echo "|--------|--------|-------|-------|"
    echo "| Failure rate | ${before_failure_rate}% | ${after_failure_rate}% | $(format_delta "$before_failure_rate" "$after_failure_rate" 1 "%") |"
    echo "| Bash failure rate | ${before_bash_failure_rate}% | ${after_bash_failure_rate}% | $(format_delta "$before_bash_failure_rate" "$after_bash_failure_rate" 1 "%") |"
    echo "| Total failures | ${before_total_failures} | ${after_total_failures} | $(format_delta "$before_total_failures" "$after_total_failures" 0) |"
    echo "| Total tool calls | ${before_total_tool_calls} | ${after_total_tool_calls} | $(format_delta "$before_total_tool_calls" "$after_total_tool_calls" 0) |"
    echo "| Total prompts | ${before_total_prompts} | ${after_total_prompts} | $(format_delta "$before_total_prompts" "$after_total_prompts" 0) |"
    echo "| Correction rate | ${before_correction_rate}% | ${after_correction_rate}% | $(format_delta "$before_correction_rate" "$after_correction_rate" 1 "%") |"
    echo
    echo "## Before Tag"
    activate_summary "$before_json"
    echo
    echo "### Raw Metrics"
    echo "| Metric | Value |"
    echo "|--------|-------|"
    echo "| Total tool calls | ${TOTAL_TOOL_CALLS} |"
    echo "| Sessions | ${UNIQUE_SESSIONS} |"
    echo "| Failure rate | ${FAILURE_RATE_PCT}% (${TOTAL_FAILURES}/${TOTAL_TOOL_CALLS}) |"
    echo "| Bash failure rate | ${BASH_FAILURE_RATE_PCT}% (${BASH_FAILURES}/${BASH_TOOL_CALLS}) |"
    echo "| Skill invocations | ${SKILL_INVOCATIONS} |"
    echo "| Total prompts | ${TOTAL_PROMPTS} |"
    echo "| Avg tool calls per prompt | ${AVG_TOOL_CALLS_PER_PROMPT} |"
    echo "| Correction rate | ${CORRECTION_RATE_PCT}% (${CORRECTION_PROMPTS}/${TOTAL_PROMPTS}) |"
    echo
    echo "## After Tag"
    activate_summary "$after_json"
    echo
    echo "### Raw Metrics"
    echo "| Metric | Value |"
    echo "|--------|-------|"
    echo "| Total tool calls | ${TOTAL_TOOL_CALLS} |"
    echo "| Sessions | ${UNIQUE_SESSIONS} |"
    echo "| Failure rate | ${FAILURE_RATE_PCT}% (${TOTAL_FAILURES}/${TOTAL_TOOL_CALLS}) |"
    echo "| Bash failure rate | ${BASH_FAILURE_RATE_PCT}% (${BASH_FAILURES}/${BASH_TOOL_CALLS}) |"
    echo "| Skill invocations | ${SKILL_INVOCATIONS} |"
    echo "| Total prompts | ${TOTAL_PROMPTS} |"
    echo "| Avg tool calls per prompt | ${AVG_TOOL_CALLS_PER_PROMPT} |"
    echo "| Correction rate | ${CORRECTION_RATE_PCT}% (${CORRECTION_PROMPTS}/${TOTAL_PROMPTS}) |"
  } >"$REPORT_PATH"
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --today)
      [[ "$RANGE_MODE" == "all" ]] || die "Use only one range selector"
      RANGE_MODE="today"
      shift
      ;;
    --source)
      [[ -z "$SOURCE_MODE" ]] || die "Use --source only once"
      [[ -n "${2:-}" ]] || die "--source requires claude, codex, or all"
      case "$2" in
        claude|codex|all)
          SOURCE_MODE="$2"
          ;;
        *)
          die "--source requires claude, codex, or all"
          ;;
      esac
      shift 2
      ;;
    --stdin)
      [[ "$READ_STDIN" == false ]] || die "Use --stdin only once"
      READ_STDIN=true
      shift
      ;;
    --days)
      [[ "$RANGE_MODE" == "all" ]] || die "Use only one range selector"
      [[ -n "${2:-}" ]] || die "--days requires a value"
      [[ "$2" =~ ^[0-9]+$ ]] || die "--days requires a positive integer"
      DAY_COUNT="$2"
      RANGE_MODE="days"
      shift 2
      ;;
    --compare)
      [[ -z "$COMPARE_TAG" ]] || die "Use --compare only once"
      [[ -n "${2:-}" ]] || die "--compare requires a git tag"
      COMPARE_TAG="$2"
      shift 2
      ;;
    --errors)
      [[ "$VIEW_MODE" == "full" ]] || die "Use only one output view selector"
      VIEW_MODE="errors"
      shift
      ;;
    --prompts)
      [[ "$VIEW_MODE" == "full" ]] || die "Use only one output view selector"
      VIEW_MODE="prompts"
      shift
      ;;
    --skills)
      [[ "$VIEW_MODE" == "full" ]] || die "Use only one output view selector"
      VIEW_MODE="skills"
      shift
      ;;
    --report)
      WRITE_REPORT=true
      shift
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      die "Unknown option: $1"
      ;;
  esac
done

if [[ -n "$SOURCE_MODE" && "$READ_STDIN" == true ]]; then
  die "Use only one input source selector (--source or --stdin)"
fi

if [[ "$READ_STDIN" == true && "$RANGE_MODE" != "all" ]]; then
  die "--stdin cannot be combined with --today or --days"
fi

require_command jq
require_command python3
trap cleanup_temp_input EXIT

prepare_input_files
build_period_label
resolve_compare_tag

if [[ -n "$COMPARE_TAG" ]]; then
  BEFORE_SUMMARY_JSON="$(build_summary_json before)"
  AFTER_SUMMARY_JSON="$(build_summary_json after)"

  print_compare_overview "$BEFORE_SUMMARY_JSON" "$AFTER_SUMMARY_JSON"
  print_compare_sections "$BEFORE_SUMMARY_JSON" "$AFTER_SUMMARY_JSON"

  if [[ "$WRITE_REPORT" == true ]]; then
    write_compare_report "$BEFORE_SUMMARY_JSON" "$AFTER_SUMMARY_JSON"
    echo
    echo "Report written: ${REPORT_PATH}"
  fi
else
  SUMMARY_JSON="$(build_summary_json all)"
  activate_summary "$SUMMARY_JSON"

  case "$VIEW_MODE" in
    full) print_full_summary ;;
    errors) print_error_summary ;;
    prompts) print_prompt_summary ;;
    skills) print_skill_summary ;;
  esac

  if [[ "$WRITE_REPORT" == true ]]; then
    write_report
    echo
    echo "Report written: ${REPORT_PATH}"
  fi
fi
