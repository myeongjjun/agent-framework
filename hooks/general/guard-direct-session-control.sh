#!/bin/bash
# guard-direct-session-control.sh
# @hook event: PreToolUse
# @hook matcher: Bash
# @hook timeout: 5
#
# Role-based access control for orchestrator lifecycle and effect operations.
#
# Role is derived from the zmx slot in the PPID ancestor chain:
#   orchestrator  = zmx attach <family>-orchestrator-global
#   approver      = zmx attach <family>-approver-global
#   base          = zmx attach <family>-agent-framework[-<digits>]    (rotation
#                   target or numbered base when family slot collides)
#   worker        = zmx attach <family>-agent-framework-<slug>-<digits> (any
#                   slot with a slug segment + trailing index, e.g.
#                   ...-dispatch-foo-1, ...-collab-bar-2, ...-ghost-1776...-1)
#   unknown       = no recognized slot in chain
#
# Permission matrix:
#   base           → start/stop orchestrator+approver (bootstrap only),
#                    read-only conductor commands (list/status)
#   orchestrator   → daemon invokes conductor.sh outside Claude hooks,
#                    agent itself may need `cmux send` for prompt inject
#   approver       → `cmux send-key` only
#   worker/unknown → read-only inspection only, no writes
#
# All mutation goes through `orchestrator_request --type <...>`:
#   dispatch, collab, inject, rotate, gc, tidy, done, cleanup, shutdown
#
# Rationale for slug-based worker detection (whitelist over blacklist): the
# previous rule "trailing hyphen → worker" misclassified numbered base slots
# (e.g. codex-agent-framework-2 created by cross-family rotation when the
# default codex slot is already in use). The slug+index pattern only matches
# conductor-spawned workers, so any other agent-framework slot defaults to
# base — which preserves the invariant "rotation chain stays base".

set -euo pipefail

input=$(cat)
tool_name=$(echo "$input" | jq -r '.tool_name // empty')

case "$tool_name" in
  Bash) ;;
  *) exit 0 ;;
esac

command=$(echo "$input" | jq -r '.tool_input.command // empty')
[[ -n "$command" ]] || exit 0

# --- Role detection via PPID chain ------------------------------------------
# Walk up the process tree looking for `zmx attach <slot>` in the command
# line. Order: orchestrator/approver (fixed names) → extract slot for
# agent-framework and classify by suffix shape.
detect_role() {
  local pid=$$ depth=0 max_depth=10 cmdline role="unknown" slot
  while (( depth < max_depth && pid > 1 )); do
    cmdline="$(ps -o command= -p "${pid}" 2>/dev/null || true)"
    case "${cmdline}" in
      *"zmx attach claude-orchestrator-global"*|*"zmx attach codex-orchestrator-global"*)
        role="orchestrator"; break ;;
      *"zmx attach claude-approver-global"*|*"zmx attach codex-approver-global"*)
        role="approver"; break ;;
    esac
    if [[ "${cmdline}" =~ zmx[[:space:]]+attach[[:space:]]+((claude|codex)-agent-framework[^[:space:]]*) ]]; then
      slot="${BASH_REMATCH[1]}"
      if [[ "${slot}" =~ ^(claude|codex)-agent-framework-.+-[0-9]+$ ]]; then
        role="worker"; break
      elif [[ "${slot}" =~ ^(claude|codex)-agent-framework(-[0-9]+)?$ ]]; then
        role="base"; break
      fi
    fi
    pid="$(ps -o ppid= -p "${pid}" 2>/dev/null | tr -d ' ' || echo 1)"
    (( depth++ )) || true
  done
  printf '%s' "${role}"
}

CALLER_ROLE="$(detect_role)"

# --- Always-allowed paths ---------------------------------------------------

# orchestrator_request — the canonical protocol for mutations
if echo "$command" | grep -q 'orchestrator_request'; then
  exit 0
fi

# git commands (commit messages may contain blocked keywords)
if echo "$command" | grep -qE '(^|&&\s*)git\s'; then
  exit 0
fi

# Approved build/deploy wrappers
if echo "$command" | grep -qE 'sync-framework|sync-all|test-conductor'; then
  exit 0
fi

# Read-only orchestrator inspection
if echo "$command" | grep -qE 'scripts/orchestrator/health\.sh([[:space:]]|$)'; then
  exit 0
fi
if echo "$command" | grep -qE 'scripts/orchestrator/team\.sh[[:space:]]+(health|status|list|card)([[:space:]]|$)'; then
  exit 0
fi
if echo "$command" | grep -qE 'conductor\.sh[[:space:]]+(list|status|help|--help)([[:space:]]|$)'; then
  exit 0
fi

# --- Direct mutation of runtime state files ---------------------------------
# (regardless of role — these must only change via orchestrator_request or
# approved lifecycle paths)
if echo "$command" | grep -qE '\.orchestrator/(state\.json|agents/registry\.json)|\.approver/(RUNNING|BOOTSTRAPPED|pid|scan\.pid|slot|surface_id|workspace_id|pending_surface_id|pending_workspace_id)'; then
  if echo "$command" | grep -qE '(^|[[:space:]])(mv|cp|rm|tee|sed[[:space:]]+-i|perl[[:space:]]+-pi|python[0-9.]*|node|ruby|ed)([[:space:]]|$)|[<>]{1,2}'; then
    echo "BLOCKED: direct mutation of orchestrator/approver runtime state is forbidden." >&2
    echo "  Use orchestrator_request or the approved lifecycle path." >&2
    exit 2
  fi
fi

# --- Lifecycle: start-agent / stop-agent (orchestrator, approver) -----------
# Only base role may bootstrap/stop these daemons. Both source and deployed
# paths are subject to the same rule — no path-based bypass.
if echo "$command" | grep -qE '(scripts|\.orchestrator/scripts)/orchestrator/(start-agent|stop-agent)\.sh([[:space:]]|$)'; then
  if [[ "${CALLER_ROLE}" != "base" ]]; then
    echo "BLOCKED: start-agent.sh / stop-agent.sh require role=base (got role=${CALLER_ROLE})." >&2
    echo "  Only the primary agent-framework session (slot: claude-agent-framework) may bootstrap orchestrator/approver." >&2
    exit 2
  fi
  exit 0
fi

# team.sh start/stop/restart/close-surface → same rule as start-agent/stop-agent
if echo "$command" | grep -qE 'scripts/orchestrator/team\.sh[[:space:]]+(start|stop|restart|close-surface)([[:space:]]|$)'; then
  if [[ "${CALLER_ROLE}" != "base" ]]; then
    echo "BLOCKED: team.sh lifecycle commands require role=base (got role=${CALLER_ROLE})." >&2
    exit 2
  fi
  # Even from base, team.sh close-surface should go through gc for safety
  if echo "$command" | grep -qE 'team\.sh[[:space:]]+close-surface'; then
    echo "BLOCKED: team.sh close-surface must go through orchestrator gc. Direct close may hit the wrong surface." >&2
    exit 2
  fi
  exit 0
fi

# --- Conductor mutations — must go through orchestrator_request -------------
# conductor.sh dispatch|collab|done|cleanup|gc|tidy|resume are mutations.
# From a Claude session they are always blocked; only the daemon (running
# outside Claude Code hooks) may invoke conductor.sh directly.
if echo "$command" | grep -qE 'conductor\.sh[[:space:]]+(dispatch|collab|done|cleanup|gc|tidy|resume)([[:space:]]|$)'; then
  echo "BLOCKED: direct conductor.sh mutations bypass the orchestrator." >&2
  echo "  Use: orchestrator_request --type <dispatch|collab|gc|tidy|inject|rotate|shutdown>" >&2
  exit 2
fi

# --- Effect-level blocks ----------------------------------------------------

# zmx kill — always blocked; use orchestrator_request --type gc
if echo "$command" | grep -qE 'zmx\s+kill'; then
  echo "BLOCKED: zmx kill bypasses orchestrator state sync. Use: orchestrator_request --type gc --force" >&2
  exit 2
fi

# cmux close-surface — always blocked; use orchestrator gc
if echo "$command" | grep -qE 'cmux\s+close-surface'; then
  echo "BLOCKED: cmux close-surface may hit the wrong surface. Use: orchestrator_request --type gc" >&2
  exit 2
fi

# Allow approver's send-key.sh wrapper before the generic send-key block
if echo "$command" | grep -qE '(scripts/orchestrator/effects/approver-send-key\.sh|(\.approver|\.orchestrator/agents/approver|agents/approver)/(approver-)?send-key\.sh)'; then
  exit 0
fi

# cmux send-key — approver role only
if echo "$command" | grep -qE 'cmux\s+send-key'; then
  if [[ "${CALLER_ROLE}" == "approver" ]]; then
    exit 0
  fi
  echo "BLOCKED: cmux send-key requires role=approver (got role=${CALLER_ROLE})." >&2
  echo "  Direct key injection bypasses approval logging and policy analysis." >&2
  exit 2
fi

# cmux send (prompt) — orchestrator role only
if echo "$command" | grep -qE 'cmux\s+send\b'; then
  if [[ "${CALLER_ROLE}" == "orchestrator" ]]; then
    exit 0
  fi
  echo "BLOCKED: cmux send requires role=orchestrator (got role=${CALLER_ROLE})." >&2
  echo "  Use: orchestrator_request --type inject" >&2
  exit 2
fi

# Direct process kill on zmx/claude/codex
if echo "$command" | grep -qE 'kill\s+(-9\s+)?(zmx|claude|codex)'; then
  echo "BLOCKED: direct process kill bypasses orchestrator. Use: orchestrator_request --type gc --force" >&2
  exit 2
fi

exit 0
