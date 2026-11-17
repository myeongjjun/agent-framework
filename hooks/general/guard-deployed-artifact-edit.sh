#!/bin/bash
# guard-deployed-artifact-edit.sh
# @hook event: PreToolUse
# @hook matcher: Edit,Write
# @hook timeout: 3
#
# Warn when Edit/Write targets a deployed artifact path instead of the
# source in agent-framework/.
#
# Deployed artifact paths:
#   ~/.orchestrator/   (orchestrator scripts and agent state)
#   ~/.claude/skills/  (deployed skills)
#   ~/.claude/hooks/   (deployed hooks)
#   ~/.claude/agents/  (deployed agents)
#   ~/.codex/skills/   (deployed codex skills)
#   ~/.codex/hooks/    (deployed codex hooks)
#   ~/.codex/hooks.json / ~/.codex/config.toml (codex hook config)
#
# Deployed copies are written by more than one layer's installer, so the
# block message names the owning layer:
#   - path listed in ~/.claude/.framework-owned, or a symlink resolving
#     into agent-framework/  → L1: edit agent-framework/, run scripts/install.sh
#   - symlink resolving elsewhere → edit that source path and redeploy with
#     its repo's installer
#   - anything else → another layer's copy: edit that layer's source repo and
#     redeploy with its installer
#
# No cwd/project scope check: the guard applies in every session.
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
#   Deployed (block): scripts/
#   Runtime (allow):  state.json, activity.jsonl, locks/, agent/pid, agent/RUNNING, etc.
#   Communication (allow): inbox/, outbox/, mailbox/, tasks/, done/
is_deployed=0
case "$expanded" in
  ${HOME}/.orchestrator/scripts/*)        is_deployed=1 ;;
  ${HOME}/.claude/skills/*)               is_deployed=1 ;;
  ${HOME}/.claude/hooks/*)                is_deployed=1 ;;
  ${HOME}/.claude/agents/*)               is_deployed=1 ;;
  ${HOME}/.codex/skills/*)                is_deployed=1 ;;
  ${HOME}/.codex/hooks/*)                 is_deployed=1 ;;
  ${HOME}/.codex/hooks.json)              is_deployed=1 ;;
  ${HOME}/.codex/config.toml)             is_deployed=1 ;;
esac

[[ "$is_deployed" -eq 0 ]] && exit 0

# Name the owning layer so the advice is right for L1 and L2+ copies alike.
L1_HINT="L1 (agent-framework): edit the source in agent-framework/ and redeploy with scripts/install.sh."
owned=0
if [[ -f "${HOME}/.claude/.framework-owned" ]] &&
   awk -v p="$expanded" '{sub(/^[^ ]+  /,""); if ($0==p) f=1} END{exit !f}' "${HOME}/.claude/.framework-owned"; then
  owned=1
fi

# Find a symlink between $HOME and the target (skills are dir symlinks) and
# resolve it to the real source path. Symlinks above $HOME are ignored.
real=""
probe="$expanded"
while [[ "$probe" == "$HOME"/* ]]; do
  if [[ -L "$probe" ]]; then
    if [[ -d "$probe" ]]; then
      real="$(cd -P "$probe" 2>/dev/null && pwd || true)${expanded#"$probe"}"
    else
      real=$(readlink "$probe")
      [[ "$real" == /* ]] || real="$(dirname "$probe")/$real"
    fi
    break
  fi
  probe=$(dirname "$probe")
done

if [[ "$owned" -eq 1 ]]; then
  HINT="$L1_HINT"
elif [[ -n "$real" ]]; then
  src_root=$(git -C "$(dirname "$real")" rev-parse --show-toplevel 2>/dev/null || true)
  if [[ "${src_root##*/}" == "agent-framework" ]]; then
    HINT="$L1_HINT (source: ${real})"
  else
    HINT="This path links to ${real}; edit it there and redeploy with ${src_root:-its repo}'s installer."
  fi
else
  HINT="Owned by another layer (persona/domain pack): edit that layer's source repo and redeploy with its installer."
fi

MSG="BLOCKED: ${tool_name} targets deployed artifact ${file_path}. ${HINT}"

jq -n --arg msg "$MSG" '{decision: "block", reason: $msg}'

exit 0
