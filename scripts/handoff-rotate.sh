#!/usr/bin/env bash
#
# handoff-rotate.sh — Thin client for orchestrator-mediated handoff rotation.
#
# Run from INSIDE the heavy session you want to rotate out, AFTER
# you've already run /handoff and have a fresh .agent/entry-*.md on disk.
#
# Architecture (cmux path):
#
#   bash main (inside Y4)
#     1. preflight (env, handoff entry, orchestrator reachability)
#     2. send a file-backed `type: rotate` request to the orchestrator
#     3. return immediately; the orchestrator drives the rotation
#
#   orchestrator session (4-way: cl→cl, cl→cx, cx→cl, cx→cx)
#     same-family (cl→cl, cx→cx):
#       1. resolve original pid from requester slot
#       2. spawn ghost split (`claude --continue -n <slug>` or `codex resume <id>`)
#       3. ghost stability check
#       4. raw zmx `/clear` to origin slot → keep origin pid
#       5. wait_agent_ready
#       6. raw zmx `/takeover` (claude) or `$takeover` (codex)
#     cross-family (cl→cx, cx→cl):
#       1. resolve original pid from requester slot
#       2. spawn-surface fresh target in a new slot/surface (no ghost —
#          origin process stays alive and is itself the lossless archive)
#       3. wait_agent_ready on fresh target
#       4. raw zmx `/takeover` (claude) or `$takeover` (codex)
#       5. user closes the origin pane manually when ready
#
# References: ADR-026, ADR-028, skills/handoff/SKILL.md ## Rotation

set -euo pipefail

err()  { printf '\033[1;31m✗\033[0m %s\n' "$*" >&2; exit 1; }
ok()   { printf '\033[1;32m✓\033[0m %s\n' "$*"; }
info() { printf '\033[1;34mℹ\033[0m %s\n' "$*"; }

DRY_RUN=0
TARGET_AGENT=""
while (( $# > 0 )); do
  case "$1" in
    --dry-run)  DRY_RUN=1 ;;
    --target)   shift; TARGET_AGENT="${1:-}" ;;
    --target=*) TARGET_AGENT="${1#--target=}" ;;
    -h|--help)
      cat <<'USAGE'
Usage: handoff-rotate.sh [--dry-run] [--target claude|codex]

  --dry-run         Plan only; do not kill the current session.
  --target AGENT    Fresh agent family in the rotated slot.
                    Default: match origin.
USAGE
      exit 0 ;;
    *) err "unknown flag: $1 (try --help)" ;;
  esac
  shift
done

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
PROTOCOL_SH="${ORCHESTRATOR_PROTOCOL_SH:-${HOME}/.orchestrator/scripts/orchestrator/protocol.sh}"

# Ghost session guard: ghost slots end in -ghost-N. Rotating from a ghost
# would chain-spawn another ghost and corrupt the archive lineage.
case "$ORIG_ZMX" in
  *-ghost-*) err "rotate refused: $ORIG_ZMX looks like a ghost archive slot. Run rotate from the base session, not an archive." ;;
esac

# Origin family detection. Rotate keeps the ghost/archive in the same
# family as the requester so session continuity uses the family's native
# resume mechanism.
case "$ORIG_ZMX" in
  claude-*) ORIG_AGENT="claude" ;;
  codex-*)  ORIG_AGENT="codex" ;;
  *)        err "ZMX_SESSION='$ORIG_ZMX' is neither claude-* nor codex-*" ;;
esac

# Codex often runs inside a filesystem/process sandbox. In that environment,
# requester-side probes such as kill -0, ps, zmx list, and cmux tree can fail
# even though the host-side orchestrator can handle the rotate. Keep Claude's
# historical strict behavior, but default Codex to minimal client preflight.
ROTATE_PREFLIGHT="${ORCHESTRATOR_ROTATE_PREFLIGHT:-}"
if [[ -z "${ROTATE_PREFLIGHT}" ]]; then
  if [[ "${ORIG_AGENT}" == "codex" ]]; then
    ROTATE_PREFLIGHT="minimal"
  else
    ROTATE_PREFLIGHT="strict"
  fi
fi
case "${ROTATE_PREFLIGHT}" in
  strict|minimal) ;;
  *) err "invalid ORCHESTRATOR_ROTATE_PREFLIGHT='${ROTATE_PREFLIGHT}' (must be strict or minimal)" ;;
esac

# Target family resolution: default to origin, validate claude|codex.
[[ -z "$TARGET_AGENT" ]] && TARGET_AGENT="$ORIG_AGENT"
case "$TARGET_AGENT" in
  claude|codex) : ;;
  *)            err "invalid --target: '$TARGET_AGENT' (must be claude or codex)" ;;
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
# Enable selected-workspace fallback for cases where CMUX_WORKSPACE_ID
# is a stale UUID (e.g., after cmux restart). The currently selected
# workspace is a reasonable target for rotate since the user is looking
# at it right now.
export ORCHESTRATOR_ALLOW_SELECTED_WS_FALLBACK=1
if ! orchestrator_alive; then
  if [[ "${ROTATE_PREFLIGHT}" == "minimal" ]]; then
    info "orchestrator alive probe failed in minimal preflight; attempting request enqueue anyway"
    export ORCHESTRATOR_REQUEST_SKIP_ALIVE=1
  else
    err "orchestrator not running — start it with: bash ~/.orchestrator/scripts/orchestrator/start-agent.sh --execute"
  fi
fi

# --- 3.5 Base-session guard (rotate refused on worker slots) -----------------
# rotate is base-session only. Workers (dispatch/collab) must not rotate
# themselves — their lifecycle is owned by the caller. We probe state.json
# via the canonical reader (concurrent-write safe) for either:
#   - tasks[*].agents[] containing this slot
#   - agents[<slot>].task non-empty
# Either match → worker → refuse.
STATE_READ="${HOME}/.orchestrator/scripts/orchestrator/core/state-read.sh"
if [[ -x "$STATE_READ" ]]; then
  _state_json="$("$STATE_READ" 2>/dev/null || true)"
  if [[ -n "$_state_json" ]]; then
    _is_worker="$(jq -re --arg slot "$ORIG_ZMX" '
      (.tasks // {} | to_entries[]? | select((.value.agents // []) | index($slot)) | .key) //
      (.agents // {} | .[$slot] // {} | .task // empty)
    ' <<<"$_state_json" 2>/dev/null | head -1 || true)"
    [[ -z "$_is_worker" ]] || err "rotate refused: $ORIG_ZMX is registered as a worker (task=$_is_worker). rotate is base-session only."
  else
    if [[ "${ROTATE_PREFLIGHT}" == "minimal" ]]; then
      info "cannot read orchestrator state in minimal preflight; continuing to request enqueue"
    else
      err "rotate refused: cannot read orchestrator state — investigate before retrying"
    fi
  fi
fi

# --- 3a. Surface UUID validation + tty fallback -------------------------------
# If CMUX_SURFACE_ID is a stale UUID (cmux restarted since session start),
# daemon's cmux send to that UUID silently fails and fresh claude never
# boots in the original surface. Validate and re-derive if needed.
_resolved_surf="$(_cmux_resolve_surface_ref "${ORIG_SURF}" 2>/dev/null || true)"
if [[ -z "${_resolved_surf}" ]]; then
  # Stale UUID — find surface by the base claude's tty.
  # ZMX_SESSION is reliable (zmx slot names don't change with cmux restart).
  _claude_pid="$(zmx list 2>/dev/null \
    | awk -v n="${ORIG_ZMX}" '$0 ~ "name=" n "\t" {
        for (i=1; i<=NF; i++) if ($i ~ /^pid=/) { sub(/^pid=/, "", $i); print $i; exit }
      }' || true)"

  # The cmux-side tty is the tty of the LIVE `zmx attach <slot>` client,
  # not claude's own tty (claude sits on the zmx-internal PTY slave that
  # cmux never sees). Prefer the live attach client; fall back to claude
  # for non-zmx-host launches.
  _claude_tty=""
  while read -r _attach_pid; do
    [[ -n "${_attach_pid}" ]] || continue
    _t="$(ps -o tty= -p "${_attach_pid}" 2>/dev/null | tr -d ' ' || true)"
    if [[ -n "${_t}" && "${_t}" != "?" && "${_t}" != "??" ]]; then
      _claude_tty="${_t}"
      break
    fi
  done < <(pgrep -f "^zmx attach ${ORIG_ZMX}( |$)" 2>/dev/null || true)
  if [[ -z "${_claude_tty}" && -n "${_claude_pid}" ]]; then
    _claude_tty="$(ps -o tty= -p "${_claude_pid}" 2>/dev/null | tr -d ' ' || true)"
  fi

  if [[ -n "${_claude_tty}" && "${_claude_tty}" != "?" ]]; then
    _resolved_surf="$(cmux tree --all 2>/dev/null \
      | awk -v tty="tty=${_claude_tty}" '
          index($0, tty) {
            match($0, /surface:[0-9]+/)
            if (RSTART > 0) { print substr($0, RSTART, RLENGTH); exit }
          }' || true)"
  fi
  if [[ -n "${_resolved_surf}" ]]; then
    info "resolved stale CMUX_SURFACE_ID via tty → ${_resolved_surf}"
    ORIG_SURF="${_resolved_surf}"
  elif [[ "${ROTATE_PREFLIGHT}" == "minimal" ]]; then
    info "CMUX_SURFACE_ID could not be verified in minimal preflight; passing original env value to daemon"
  else
    err "CMUX_SURFACE_ID stale and tty fallback failed (claude_pid=${_claude_pid:-?} tty=${_claude_tty:-?})"
  fi
fi

ENTRY_PATH="$PROJECT_DIR/$LATEST_ENTRY"

# For codex-origin rotates, codex exports CODEX_THREAD_ID into agent-spawned
# shells. This env var is the only authoritative source for the calling
# thread's UUID. If absent, abort — no fallback to heuristics. Hard fail makes
# regressions easy to pinpoint ("codex CLI removed/renamed CODEX_THREAD_ID").
if [[ "${ORIG_AGENT}" == "codex" ]]; then
  if [[ -z "${CODEX_THREAD_ID:-}" ]]; then
    err "CODEX_THREAD_ID env var is empty.
  /handoff must run inside a shell spawned by the codex agent (which exports CODEX_THREAD_ID).
  If this is a current codex session, the env var may have been removed in a codex CLI update —
  check the codex shell environment and update handoff-rotate.sh to the new identifier."
  fi
  info "codex session id from CODEX_THREAD_ID: ${CODEX_THREAD_ID}"
fi

PAYLOAD=$(cat <<EOF
- entry_path: $ENTRY_PATH
- surface_id: $ORIG_SURF
- target_agent: $TARGET_AGENT
- dry_run: $( [[ $DRY_RUN -eq 1 ]] && printf 'true' || printf 'false' )
$( [[ -n "${CODEX_THREAD_ID:-}" ]] && printf -- '- codex_session_id: %s' "${CODEX_THREAD_ID}" )
EOF
)

if [[ $DRY_RUN -eq 1 ]]; then
  info "[dry-run] requesting rotate plan from orchestrator"
  set +e
  _dry_run_output="$(orchestrator_request \
    --type rotate \
    --slug "rotate-${ORIG_ZMX}" \
    --timeout 120 \
    --payload "$PAYLOAD" 2>&1)"
  _dry_run_rc=$?
  set -e
  printf '%s\n' "${_dry_run_output}"
  exit "${_dry_run_rc}"
fi

# Execute is fire-and-forget: the requester returns immediately so the
# orchestrator can drive the rotation without blocking on this surface.
set +e
REQUEST_ID="$(
  orchestrator_request \
    --type rotate \
    --slug "rotate-${ORIG_ZMX}" \
    --timeout 120 \
    --no-wait \
    --payload "$PAYLOAD" 2>&1
)"
REQUEST_RC=$?
set -e
if (( REQUEST_RC != 0 )); then
  err "orchestrator request enqueue failed (rc=${REQUEST_RC}): ${REQUEST_ID:-no output}"
fi

[[ -n "$REQUEST_ID" ]] || err "orchestrator accepted no request id for rotate"
ok "rotation request queued: $REQUEST_ID"

printf '\n\033[1mNext (orchestrator-managed, ~30s total):\033[0m\n'
cat <<EOF
  request: $REQUEST_ID
  target:  zmx=$ORIG_ZMX surface=$ORIG_SURF workspace=$ORIG_WS
  entry:   $ENTRY_PATH
  agent:   $ORIG_AGENT → $TARGET_AGENT

The orchestrator will:
EOF

if [[ "$ORIG_AGENT" == "$TARGET_AGENT" ]]; then
  cat <<EOF
  1. spawn a ghost split with '$ORIG_AGENT' archive (--continue or resume)
  2. raw inject '/clear' to origin slot $ORIG_ZMX (origin pid kept)
  3. wait for the fresh agent to be input-ready
  4. raw inject takeover command
EOF
else
  cat <<EOF
  1. spawn-surface fresh '$TARGET_AGENT' in a new slot (no ghost — origin
     pane stays alive as the archive; close it manually when done)
  2. wait for the fresh agent to be input-ready
  3. raw inject takeover command
EOF
fi

cat <<EOF

Inspect response later: ~/.orchestrator/outbox/res-${REQUEST_ID#req-}.md
EOF
