#!/usr/bin/env bash
#
# handoff-rotate.sh — Compress current claude session by rotating to a fresh
# claude in the same zmx base slot, then auto-trigger /takeover.
#
# Run from INSIDE the heavy claude session you want to rotate out, AFTER
# you've already run /handoff and have a fresh .agent/entry-*.md on disk.
#
# Architecture (post-Round-6 simplification, claude-only):
#
#   bash main (inside Y4)
#     ├─ preflight (env, entry, ORIG_PID lookup via zmx list)
#     ├─ spawn detached background zsh subshell      ─┐
#     └─ exit immediately                              │
#                                                      │ runs in independent
#   detached zsh (survives Y4's SIGQUIT)               │ process tree
#     1. sleep (let bash main return cleanly to Y4)    │
#     2. kill -QUIT $ORIG_PID                          │
#     3. wait for Y4 death                             │
#     4. cmux new-split right → ghost split:           │
#          zmx attach <ghost-name> claude --continue   │
#          (inherits Y4's jsonl from cwd; side archive)│
#     5. wait for ghost boot                           │
#     6. cmux send ORIG_SURF                           │
#          "zmx attach $ORIG_ZMX claude"               │
#          (fresh Y' in base slot — c-like behavior    │
#           but no --continue flag)                    │
#     7. wait for Y' boot                              │
#     8. cmux send ORIG_SURF "/takeover"               │
#     9. log result, exit                             ─┘
#
# References: ADR-026, skills/handoff/SKILL.md ## Rotation,
#             .zshrc.d/95-zmx.zsh (c/cx wrappers — pattern reference)

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
command -v zmx  >/dev/null || err "zmx not in PATH"
command -v cmux >/dev/null || err "cmux not in PATH"

ORIG_ZMX="$ZMX_SESSION"
ORIG_SURF="$CMUX_SURFACE_ID"
ORIG_WS="$CMUX_WORKSPACE_ID"
PROJECT_DIR="$PWD"

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

# --- 3. Look up Y4 pid via zmx list ------------------------------------------

ORIG_PID=$(zmx list 2>/dev/null | awk -v n="name=$ORIG_ZMX" '
  $0 ~ n {
    for (j=1; j<=NF; j++) {
      if ($j ~ /^pid=/) { sub(/^pid=/, "", $j); print $j; exit }
    }
  }
')
[[ -n "$ORIG_PID" ]] || err "could not find pid for zmx session '$ORIG_ZMX'"
kill -0 "$ORIG_PID" 2>/dev/null || err "pid $ORIG_PID not running"
ok "Y4: pid=$ORIG_PID zmx=$ORIG_ZMX surface=$ORIG_SURF"

# --- 4. Plan ghost session name ----------------------------------------------

GHOST_ZMX="${ORIG_ZMX}-ghost-$(date +%s)"
LOG_FILE="/tmp/handoff-rotate-bg-$$.log"
info "ghost zmx: $GHOST_ZMX"
info "bg log:    $LOG_FILE"

if [[ $DRY_RUN -eq 1 ]]; then
  info "[dry-run] would spawn detached zsh background subshell"
  info "[dry-run] sequence:"
  info "  sleep 3"
  info "  kill -QUIT $ORIG_PID"
  info "  wait for death"
  info "  cmux new-split right --workspace $ORIG_WS"
  info "  cmux send <ghost-surf> 'cd $PROJECT_DIR && zmx attach $GHOST_ZMX claude --continue'"
  info "  sleep 12"
  info "  cmux send $ORIG_SURF 'zmx attach $ORIG_ZMX claude'"
  info "  sleep 10"
  info "  cmux send $ORIG_SURF '/takeover'"
  exit 0
fi

# --- 5. Spawn detached background zsh ----------------------------------------
#
# This subshell must survive the SIGQUIT we'll send to Y4. nohup + disown
# detaches it from claude's process tree. setsid would also work; nohup is
# more portable on macOS.

nohup zsh -c "
  set -u
  exec >> '$LOG_FILE' 2>&1
  echo \"[\$(date +%H:%M:%S)] bg zsh started, pid=\$\$\"

  # 1. Let bash main return cleanly to Y4 before we kill it.
  sleep 3

  # 2. SIGQUIT Y4. ADR-026: claude flushes JSONL on SIGQUIT.
  echo \"[\$(date +%H:%M:%S)] SIGQUIT $ORIG_PID\"
  kill -QUIT '$ORIG_PID' 2>/dev/null || echo 'WARN: kill -QUIT failed'

  # 3. Wait for death (max 10s).
  for i in 1 2 3 4 5 6 7 8 9 10; do
    if ! kill -0 '$ORIG_PID' 2>/dev/null; then break; fi
    sleep 1
  done
  if kill -0 '$ORIG_PID' 2>/dev/null; then
    echo 'WARN: Y4 still alive after 10s, sending SIGTERM'
    kill -TERM '$ORIG_PID' 2>/dev/null || true
    sleep 2
  fi
  if kill -0 '$ORIG_PID' 2>/dev/null; then
    echo 'ERROR: Y4 will not die. Aborting rotation.'
    exit 1
  fi
  echo \"[\$(date +%H:%M:%S)] Y4 down\"

  # Brief grace so zmx _cleanup_session in ORIG_SURF can run, freeing the
  # base slot.
  sleep 2

  # 4. Ghost split — captures Y4's jsonl while it's still the most recent
  #    file in cwd. Must run BEFORE Y' creates a newer jsonl.
  GHOST_SURF=\$(cmux new-split right --workspace '$ORIG_WS' 2>&1 | grep -oE 'surface:[0-9]+' | head -1)
  if [[ -z \"\$GHOST_SURF\" ]]; then
    echo 'ERROR: cmux new-split failed for ghost'
    exit 1
  fi
  echo \"[\$(date +%H:%M:%S)] ghost split: \$GHOST_SURF\"
  cmux send --surface \"\$GHOST_SURF\" 'cd $PROJECT_DIR && zmx attach $GHOST_ZMX claude --continue'
  cmux send-key --surface \"\$GHOST_SURF\" enter

  # 5. Wait for ghost claude to actually load Y4's session.
  sleep 12
  echo \"[\$(date +%H:%M:%S)] ghost should be loaded\"

  # 6. Y' in ORIG_SURF — c-like (base zmx slot) but fresh (no --continue).
  cmux send --surface '$ORIG_SURF' 'zmx attach $ORIG_ZMX claude'
  cmux send-key --surface '$ORIG_SURF' enter
  echo \"[\$(date +%H:%M:%S)] Y' dispatched (zmx attach $ORIG_ZMX claude)\"

  # 7. Wait for Y' to boot.
  sleep 10

  # 8. Inject /takeover. Y' reads $LATEST_ENTRY via the takeover skill.
  cmux send --surface '$ORIG_SURF' '/takeover'
  cmux send-key --surface '$ORIG_SURF' enter
  echo \"[\$(date +%H:%M:%S)] /takeover injected\"

  echo \"[\$(date +%H:%M:%S)] rotation complete\"
" </dev/null >/dev/null 2>&1 &
disown
BG_PID=$!
ok "background zsh spawned: pid=$BG_PID"

# --- 6. Final instructions ---------------------------------------------------

printf '\n\033[1mNext (automated, ~30s total):\033[0m\n'
cat <<EOF
  T+3s   Y4 (pid $ORIG_PID) gets SIGQUIT
  T+5s   ghost split opens at right (zmx: $GHOST_ZMX, --continue Y4)
  T+17s  Y' spawns in $ORIG_SURF (zmx: $ORIG_ZMX, fresh)
  T+27s  /takeover injected to Y'

Watch progress:    tail -f $LOG_FILE
Cleanup ghost:     zmx kill $GHOST_ZMX
Recover Y4 later:  claude --resume <session-uuid>  (jsonl preserved)
EOF
