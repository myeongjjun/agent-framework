#!/usr/bin/env bash
#
# handoff-rotate.sh — Thin client for orchestrator-mediated handoff rotation.
#
# Run from INSIDE the heavy claude session you want to rotate out, AFTER
# you've already run /handoff and have a fresh .agent/entry-*.md on disk.
#
# Architecture (cmux path):
#
#   bash main (inside Y4)
#     1. preflight (env, handoff entry, orchestrator reachability)
#     2. send a file-backed `type: rotate` request to the orchestrator
#     3. return immediately so the current session can be SIGQUITed safely
#
#   orchestrator session
#     1. resolve original pid from requester slot
#     2. spawn ghost split first (`claude --continue`)
#     3. kill -QUIT original pid and wait for death
#     4. inject fresh `zmx attach <orig> claude` into the base surface
#     5. inject `/takeover`
#
# References: ADR-026, ADR-028, skills/handoff/SKILL.md ## Rotation

set -euo pipefail

DRY_RUN=0
[[ "${1:-}" == "--dry-run" ]] && DRY_RUN=1

err()  { printf '\033[1;31m✗\033[0m %s\n' "$*" >&2; exit 1; }
ok()   { printf '\033[1;32m✓\033[0m %s\n' "$*"; }
info() { printf '\033[1;34mℹ\033[0m %s\n' "$*"; }

# --- 0. Multi-environment dispatch -------------------------------------------
#
# If we're inside an iTerm2 pane with no cmux surface, delegate to the
# iTerm2 variant. This keeps the stable entrypoint path
# (~/.claude/scripts/handoff-rotate.sh) while routing to the correct
# implementation per ADR-026 "Multi-Environment Dispatch".

if [[ -z "${CMUX_SURFACE_ID:-}" && "${TERM_PROGRAM:-}" == "iTerm.app" && -n "${ITERM_SESSION_ID:-}" ]]; then
  ITERM_SCRIPT="$(dirname "$0")/handoff-rotate-iterm.sh"
  if [[ ! -x "$ITERM_SCRIPT" ]]; then
    err "iTerm2 environment detected but $ITERM_SCRIPT not found or not executable"
  fi
  info "iTerm2 environment detected → delegating to handoff-rotate-iterm.sh"
  exec "$ITERM_SCRIPT" "$@"
fi

# --- 1. Preflight: env vars ---------------------------------------------------

[[ -n "${ZMX_SESSION:-}"        ]] || err "ZMX_SESSION not set — run from inside a zmx session"
[[ -n "${CMUX_SURFACE_ID:-}"    ]] || err "CMUX_SURFACE_ID not set — run from inside a cmux surface"
[[ -n "${CMUX_WORKSPACE_ID:-}"  ]] || err "CMUX_WORKSPACE_ID not set"
# zmx/cmux binaries not needed — rotation goes through orchestrator.
# Env vars (ZMX_SESSION, CMUX_SURFACE_ID, CMUX_WORKSPACE_ID) are still
# required as they are passed in the orchestrator request payload.

ORIG_ZMX="$ZMX_SESSION"
ORIG_SURF="$CMUX_SURFACE_ID"
ORIG_WS="$CMUX_WORKSPACE_ID"
PROJECT_DIR="$PWD"
PROTOCOL_SH="${HOME}/.orchestrator/scripts/orchestrator/protocol.sh"

# Sanity: this script is claude-only for now. Refuse codex sessions until
# the codex variant of /takeover is wired up.
case "$ORIG_ZMX" in
  claude-*) : ;;
  *) err "ZMX_SESSION='$ORIG_ZMX' is not a claude-* session (codex not yet supported)" ;;
esac

# --- 2. Preflight: handoff entry on disk -------------------------------------

LATEST_ENTRY=$(ls -t .agent/entry-*.md 2>/dev/null | head -1 || true)
[[ -n "$LATEST_ENTRY" ]] || err "no .agent/entry-*.md found — run /handoff first"

if [[ -n "$LATEST_ENTRY" ]]; then
  ENTRY_AGE=$(($(date +%s) - $(stat -f %m "$LATEST_ENTRY" 2>/dev/null || stat -c %Y "$LATEST_ENTRY")))
  if (( ENTRY_AGE > 600 )); then
    info "warning: latest entry is ${ENTRY_AGE}s old — rerun /handoff if context drifted"
  fi
fi
ok "handoff entry: $LATEST_ENTRY"

[[ -r "$PROTOCOL_SH" ]] || err "orchestrator protocol not found at $PROTOCOL_SH"

# --- 3. Orchestrator preflight -----------------------------------------------

# shellcheck source=/dev/null
. "$PROTOCOL_SH"
orchestrator_alive || err "orchestrator not running — start it with: bash ~/.orchestrator/scripts/orchestrator/start-agent.sh --execute"

ENTRY_PATH="$PROJECT_DIR/$LATEST_ENTRY"
PAYLOAD=$(cat <<EOF
- entry_path: $ENTRY_PATH
- surface_id: $ORIG_SURF
- dry_run: $( [[ $DRY_RUN -eq 1 ]] && printf 'true' || printf 'false' )
EOF
)

if [[ $DRY_RUN -eq 1 ]]; then
  info "[dry-run] requesting rotate plan from orchestrator"
  orchestrator_request \
    --type rotate \
    --slug "rotate-${ORIG_ZMX}" \
    --timeout 120 \
    --payload "$PAYLOAD"
  exit $?
fi

# Execute is fire-and-forget: the requester must return before the
# orchestrator SIGQUITs the current session.
REQUEST_ID="$(
  orchestrator_request \
    --type rotate \
    --slug "rotate-${ORIG_ZMX}" \
    --timeout 120 \
    --no-wait \
    --payload "$PAYLOAD"
)"

[[ -n "$REQUEST_ID" ]] || err "orchestrator accepted no request id for rotate"
ok "rotation request queued: $REQUEST_ID"

printf '\n\033[1mNext (orchestrator-managed, ~30s total):\033[0m\n'
cat <<EOF
  request: $REQUEST_ID
  target:  zmx=$ORIG_ZMX surface=$ORIG_SURF workspace=$ORIG_WS
  entry:   $ENTRY_PATH

The orchestrator will:
  1. spawn a ghost split with 'claude --continue'
  2. SIGQUIT the current Claude pid
  3. reattach a fresh 'claude' in $ORIG_SURF
  4. inject /takeover

Inspect response later: ~/.orchestrator/outbox/res-${REQUEST_ID#req-}.md
EOF
