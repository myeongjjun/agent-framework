#!/usr/bin/env bash
#
# effects/guard.sh — caller-chain guard for orchestrator effect scripts.
#
# Source this file at the top of any effect script that must only be called
# through conductor.sh or the orchestrator pipeline.
#
# Usage (in effect scripts):
#   . "$(dirname -- "${BASH_SOURCE[0]}")/guard.sh"
#
# Two checks, both must pass:
#   1. ORCHESTRATOR_CALLER_TOKEN env var is set (set by conductor/daemon/start-agent)
#   2. Ancestor process chain includes a known orchestrator caller
#      (conductor.sh, daemon.sh, start-agent.sh). This prevents AI agents
#      from bypassing the guard by simply setting the env var.

_guard_check_ancestor() {
  # Walk the process tree up to 8 levels looking for a known caller.
  local pid=$$ depth=0 max_depth=8
  local known_pattern='conductor\.sh|daemon\.sh|start-agent\.sh'

  while (( depth < max_depth && pid > 1 )); do
    local cmdline
    cmdline="$(ps -o command= -p "${pid}" 2>/dev/null || true)"
    if [[ "${cmdline}" =~ ${known_pattern} ]]; then
      return 0
    fi
    pid="$(ps -o ppid= -p "${pid}" 2>/dev/null | tr -d ' ' || echo 1)"
    (( depth++ )) || true
  done
  return 1
}

require_caller_token() {
  if [[ -z "${ORCHESTRATOR_CALLER_TOKEN:-}" ]]; then
    echo "REFUSED: $(basename "${BASH_SOURCE[1]:-$0}") must be called through conductor.sh or the orchestrator pipeline, not directly." >&2
    echo "  Missing ORCHESTRATOR_CALLER_TOKEN." >&2
    exit 2
  fi

  if ! _guard_check_ancestor; then
    echo "REFUSED: $(basename "${BASH_SOURCE[1]:-$0}") caller chain does not include conductor.sh/daemon.sh/start-agent.sh." >&2
    echo "  ORCHESTRATOR_CALLER_TOKEN is set but the process tree does not show a valid orchestrator caller." >&2
    exit 2
  fi
}

require_caller_token
