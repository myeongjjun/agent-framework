#!/bin/bash
# guard-deployed-artifact-edit.sh
#
# Warn when Edit/Write targets a deployed artifact path instead of the
# source in agent-framework/.
#
# Deployed artifact paths:
#   ~/.orchestrator/   (orchestrator scripts, bootstrap, agent state)
#   ~/.claude/skills/  (deployed skills)
#   ~/.claude/hooks/   (deployed hooks)
#   ~/.claude/agents/  (deployed agents)
#   ~/.codex/skills/   (deployed codex skills)
#
# The correct workflow is: edit source in agent-framework/, then deploy
# via sync-all.sh. This hook prevents accidental direct edits to the
# deployed copy.
#
# Scope: only fires for agent-framework project (checked via cwd from
# stdin JSON, since CLAUDE_PROJECT_DIR may not always be set).
#
# Added: 2026-04-10

set -euo pipefail

input=$(cat)
tool_name=$(echo "$input" | jq -r '.tool_name // empty')
file_path=$(echo "$input" | jq -r '.tool_input.file_path // empty')

# Only inspect Edit/Write
case "$tool_name" in
  Edit|Write|MultiEdit) ;;
  *) exit 0 ;;
esac

[[ -z "$file_path" ]] && exit 0

# Expand ~ to $HOME for matching
expanded="${file_path/#\~/$HOME}"

# Check if targeting a deployed artifact path
# ~/.orchestrator/ contains both deployed artifacts and runtime state:
#   Deployed (block): scripts/, agent/bootstrap.md
#   Runtime (allow):  state.json, activity.jsonl, locks/, agent/pid, agent/RUNNING, etc.
#   Communication (allow): inbox/, outbox/, mailbox/, tasks/, done/
is_deployed=0
case "$expanded" in
  ${HOME}/.orchestrator/scripts/*)        is_deployed=1 ;;
  ${HOME}/.orchestrator/agent/bootstrap.md) is_deployed=1 ;;
  ${HOME}/.claude/skills/*)               is_deployed=1 ;;
  ${HOME}/.claude/hooks/*)                is_deployed=1 ;;
  ${HOME}/.claude/agents/*)               is_deployed=1 ;;
  ${HOME}/.codex/skills/*)                is_deployed=1 ;;
esac

[[ "$is_deployed" -eq 0 ]] && exit 0

# Block the write
MSG="BLOCKED: ${tool_name} targets deployed artifact ${file_path}. Edit the source in agent-framework/ and deploy via ./scripts/sync-all.sh instead."

jq -n --arg msg "$MSG" '{decision: "block", reason: $msg}'

exit 0
