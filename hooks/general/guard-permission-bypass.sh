#!/bin/bash
# guard-permission-bypass.sh
# @hook event: PreToolUse
# @hook matcher: Edit,Write,MultiEdit
# @hook timeout: 3
#
# Block agent edits to permission / hook / MCP configuration files.
# Enforces agent-framework constraint `no-permission-bypass.md`.
#
# Protected paths:
#   ~/.claude/settings.json
#   ~/.claude/settings.local.json
#   <project>/.claude/settings.local.json (any cwd)
#   ~/.claude.json                              (Claude Code mcpServers, etc.)
#   ~/.claude/hooks/**/*.sh                     (deployed hook source)
#   ~/.codex/config.toml
#   ~/.codex/hooks.json
#   ~/.codex/hooks/**
#
# Rationale: an agent that silently adds an entry to permissions.allow
# (or rewrites a hook) erases the user's intentional safety boundary
# from history. See agent-context/constraints/no-permission-bypass.md
# for the full policy.
#
# Exception path: the user can edit these files directly outside of
# the agent (e.g. `vim ~/.claude/settings.json`). This hook only fires
# when the agent uses Edit/Write/MultiEdit tools.

set -euo pipefail

input=$(cat)
tool_name=$(echo "$input" | jq -r '.tool_name // empty')
file_path=$(echo "$input" | jq -r '.tool_input.file_path // empty')

case "$tool_name" in
  Edit|Write|MultiEdit) ;;
  *) exit 0 ;;
esac

[[ -z "$file_path" ]] && exit 0

# Expand ~ to $HOME
expanded="${file_path/#\~/$HOME}"

# Normalise: resolve symlinks for the parent if it exists so relative
# `.claude/settings.local.json` inside a project hits the same pattern.
parent="$(dirname "$expanded" 2>/dev/null || true)"
if [[ -d "$parent" ]]; then
  real_parent="$(cd "$parent" 2>/dev/null && pwd -P || echo "$parent")"
  expanded="${real_parent}/$(basename "$expanded")"
fi

blocked=0
case "$expanded" in
  ${HOME}/.claude/settings.json)        blocked=1; reason="user-level Claude Code settings" ;;
  ${HOME}/.claude/settings.local.json)  blocked=1; reason="user-level Claude Code local settings" ;;
  */.claude/settings.local.json)        blocked=1; reason="project-level Claude Code local settings" ;;
  ${HOME}/.claude.json)                 blocked=1; reason="Claude Code config (mcpServers, etc.)" ;;
  ${HOME}/.claude/hooks/*.sh)           blocked=1; reason="deployed hook script" ;;
  ${HOME}/.claude/hooks/*/*.sh)         blocked=1; reason="deployed hook script" ;;
  ${HOME}/.codex/config.toml)           blocked=1; reason="Codex CLI config" ;;
  ${HOME}/.codex/hooks.json)            blocked=1; reason="Codex CLI hooks config" ;;
  ${HOME}/.codex/hooks/*)               blocked=1; reason="deployed Codex hook" ;;
esac

if (( blocked == 1 )); then
  cat >&2 <<EOF
BLOCKED: $tool_name on $reason ($expanded)

  Agent must not modify permission / hook / MCP configuration files
  without explicit user approval.

  Required action: ask the user using the approval format defined in
    agent-framework/agent-context/constraints/no-permission-bypass.md

    ## 권한 추가 / 우회 승인 요청

    **무엇**: <어떤 도구/권한/설정 파일>
    **어디**: $expanded
    **왜**: <왜 이 권한이 필요한지>
    **위험**: <부수 효과>
    **대안**: <우회 안 하고 가능한 다른 방법>
    **승인 효과**: 영구적 (config file)

  After user approval, the user themselves edits the file (outside the
  agent), or explicitly tells the agent to proceed; the agent does not
  edit unilaterally even after verbal acknowledgement of the issue.
EOF
  exit 2
fi

exit 0
