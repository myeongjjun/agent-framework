#!/bin/bash
# guard-acp-direct-edit.sh
#
# Warn when Edit/Write/MultiEdit targets a file under agent-context/.
#
# Enforces (warn-level) the AGENTS.md critical rule:
#   "agent-context/ 파일 직접 수정 금지. 반드시 ACP Skills 사용."
#
# Background: the 2026-04-07 industry alignment review (see
# .agent/observe/reports/2026-04-07-industry-alignment-review.md finding E)
# flagged that the ACP write-discipline rule existed only as documentation
# with no runtime enforcement. This hook adds runtime visibility.
#
# Design decision: WARN, not BLOCK. The /acp-decision and /acp-constraint
# skills themselves need to write to agent-context/, and we cannot
# distinguish skill-authorized writes from direct writes from hook context
# alone. Instead, every such write is logged to .agent/acp-writes.log and
# flagged via systemMessage so the drift is observable and auditable.
# Strengthening to BLOCK/ASK should only happen after skills gain a way to
# signal authorized writes (e.g., an env var or marker file).
#
# Added: 2026-04-07 as part of .collab/adr-audit-2604 follow-up.

set -euo pipefail

input=$(cat)
tool_name=$(echo "$input" | jq -r '.tool_name // empty')
file_path=$(echo "$input" | jq -r '.tool_input.file_path // empty')

# Only inspect Edit/Write/MultiEdit
case "$tool_name" in
  Edit|Write|MultiEdit) ;;
  *) exit 0 ;;
esac

[[ -z "$file_path" ]] && exit 0

# Match agent-context/ anywhere in the path (absolute or repo-relative)
case "$file_path" in
  */agent-context/*|agent-context/*)
    ;;
  *)
    exit 0
    ;;
esac

# Audit log
LOG_DIR="${CLAUDE_PROJECT_DIR:-${HOME}/agent-framework}/.agent"
LOG_FILE="${LOG_DIR}/acp-writes.log"
mkdir -p "$LOG_DIR"
TIMESTAMP="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
printf '%s\t%s\t%s\n' "$TIMESTAMP" "$tool_name" "$file_path" >> "$LOG_FILE"

# Surface warning via systemMessage — visible in transcript even on exit 0
MSG="ACP write detected: ${tool_name} on ${file_path}. The AGENTS.md critical rule says agent-context/ files must be modified via /acp-decision or /acp-constraint skills. This write has been logged to .agent/acp-writes.log. If this is an ACP skill workflow or a user-approved exception, proceed; otherwise use the appropriate /acp-* skill."

jq -n --arg msg "$MSG" '{systemMessage: $msg}'

exit 0
