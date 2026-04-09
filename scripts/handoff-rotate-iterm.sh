#!/usr/bin/env bash
#
# handoff-rotate-iterm.sh — iTerm2 split-control port of handoff-rotate.sh.
#
# Same intent as the cmux variant: rotate the current heavy Claude session
# out, replace it with a fresh one in the SAME iTerm2 pane, preserve the old
# jsonl via a ghost split, and auto-inject /takeover.
#
# This script only owns iTerm2 split control (the two primitives `osascript
# split vertically` and `osascript write text`). It is agnostic to whether
# the user launched Claude through zmx (`c` wrapper) or as bare `claude` —
# the launch pattern is detected via $ZMX_SESSION at runtime and the ghost
# / base commands adapt accordingly.
#
# Run from INSIDE the Claude session you want to rotate out, AFTER running
# /handoff so that .agent/entry-*.md is on disk.
#
# Architecture:
#
#   bash main (inside Claude tool call)
#     ├─ preflight: env vars, handoff entry, ORIG_PID discovery
#     ├─ spawn detached background zsh                ─┐
#     └─ exit immediately                               │
#                                                       │ runs in independent
#   detached zsh                                        │ process tree
#     1. sleep (let bash main return cleanly)           │
#     2. osascript: split vertically (ghost pane)       │
#          → run `<ghost-launch>` there to inherit the  │
#            current jsonl BEFORE Y' creates a newer    │
#            one (Rule 1: ghost-first jsonl ordering)   │
#     3. wait for ghost boot                            │
#     4. kill -QUIT $ORIG_PID                           │
#     5. wait for Y4 death                              │
#     6. osascript: write `<base-launch>` to ORIG       │
#          → fresh Y' boots in the same pane            │
#     7. wait for Y' boot                               │
#     8. osascript: write `/takeover` to ORIG           │
#     9. log result, exit                              ─┘
#
# Launch-pattern detection:
#
#   ZMX_SESSION set → user is inside `zmx attach <name> claude [...]`
#     ghost = `cd <pwd> && zmx attach <name>-ghost-<ts> claude --continue`
#     base  = `zmx attach <name> claude`
#     ORIG_PID via `zmx list` (mirror cmux version)
#
#   ZMX_SESSION unset → user ran bare `claude`
#     ghost = `cd <pwd> && claude --continue`
#     base  = `claude`
#     ORIG_PID via $PPID walk looking for `claude` ancestor
#
# References: ADR-026, scripts/handoff-rotate.sh,
#             .agent/entry-20260408-144408-KST.md (Round 9 design notes)

set -euo pipefail

DRY_RUN=0
[[ "${1:-}" == "--dry-run" ]] && DRY_RUN=1

err()  { printf '\033[1;31m✗\033[0m %s\n' "$*" >&2; exit 1; }
ok()   { printf '\033[1;32m✓\033[0m %s\n' "$*"; }
info() { printf '\033[1;34mℹ\033[0m %s\n' "$*"; }

# --- 1. Preflight: iTerm2 env -----------------------------------------------

[[ "${TERM_PROGRAM:-}" == "iTerm.app" ]] \
  || err "TERM_PROGRAM='${TERM_PROGRAM:-}' — this script is iTerm2-only. Use the main handoff-rotate.sh for cmux.app."
[[ -n "${ITERM_SESSION_ID:-}" ]] \
  || err "ITERM_SESSION_ID not set — are you inside an iTerm2 pane?"
[[ -z "${CMUX_SURFACE_ID:-}" ]] \
  || err "CMUX_SURFACE_ID is set — you are inside cmux.app. Use the main handoff-rotate.sh."
command -v osascript >/dev/null || err "osascript not in PATH (macOS only)"

ORIG_SESSION_ID="$ITERM_SESSION_ID"
PROJECT_DIR="$PWD"

# --- 2. Detect launch pattern (zmx vs bare) ---------------------------------

if [[ -n "${ZMX_SESSION:-}" ]]; then
  LAUNCH_MODE="zmx"
  ORIG_ZMX="$ZMX_SESSION"
  command -v zmx >/dev/null || err "ZMX_SESSION set but zmx not in PATH"
  GHOST_ZMX="${ORIG_ZMX}-ghost-$(date +%s)"
  GHOST_LAUNCH="cd $PROJECT_DIR && zmx attach $GHOST_ZMX claude --continue"
  BASE_LAUNCH="zmx attach $ORIG_ZMX claude"
  info "launch mode: zmx ($ORIG_ZMX)"
else
  LAUNCH_MODE="bare"
  GHOST_LAUNCH="cd $PROJECT_DIR && claude --continue"
  BASE_LAUNCH="claude"
  info "launch mode: bare claude"
fi

# --- 3. Preflight: handoff entry on disk ------------------------------------

LATEST_ENTRY=$(ls -t .agent/entry-*.md 2>/dev/null | head -1 || true)
[[ -n "$LATEST_ENTRY" ]] || err "no .agent/entry-*.md found — run /handoff first"

ENTRY_AGE=$(($(date +%s) - $(stat -f %m "$LATEST_ENTRY" 2>/dev/null || stat -c %Y "$LATEST_ENTRY")))
if (( ENTRY_AGE > 600 )); then
  info "warning: latest entry is ${ENTRY_AGE}s old — rerun /handoff if context drifted"
fi
ok "handoff entry: $LATEST_ENTRY"

# --- 4. Discover ORIG_PID ---------------------------------------------------

find_pid_via_zmx() {
  local name="$1"
  zmx list 2>/dev/null | awk -v n="name=$name" '
    $0 ~ n {
      for (j=1; j<=NF; j++) {
        if ($j ~ /^pid=/) { sub(/^pid=/, "", $j); print $j; exit }
      }
    }
  '
}

find_claude_ancestor() {
  local pid="${1:-$PPID}"
  local comm
  local hops=0
  while [[ -n "$pid" && "$pid" != "0" && "$pid" != "1" ]]; do
    (( hops++ ))
    if (( hops > 20 )); then
      return 1
    fi
    comm=$(ps -o comm= -p "$pid" 2>/dev/null | awk '{print $1}' | xargs -I{} basename {} 2>/dev/null || true)
    if [[ "$comm" == "claude" ]]; then
      printf '%s\n' "$pid"
      return 0
    fi
    pid=$(ps -o ppid= -p "$pid" 2>/dev/null | tr -d ' ' || true)
  done
  return 1
}

ORIG_PID=""
if [[ "$LAUNCH_MODE" == "zmx" ]]; then
  ORIG_PID=$(find_pid_via_zmx "$ORIG_ZMX")
fi
if [[ -z "$ORIG_PID" ]]; then
  ORIG_PID=$(find_claude_ancestor "$PPID" || true)
fi

if [[ -n "$ORIG_PID" ]]; then
  kill -0 "$ORIG_PID" 2>/dev/null || err "pid $ORIG_PID not running"
  ok "Y4: pid=$ORIG_PID session=$ORIG_SESSION_ID"
elif [[ $DRY_RUN -eq 1 ]]; then
  ORIG_PID="<unknown — bare-shell dry-run>"
  info "Y4: pid=$ORIG_PID session=$ORIG_SESSION_ID (dry-run tolerant)"
else
  err "could not find claude pid — neither zmx list nor PPID walk succeeded"
fi

# --- 5. Plan ghost + log + AppleScript helpers ------------------------------

LOG_FILE="/tmp/handoff-rotate-iterm-$$.log"
SCPT_DIR="/tmp/handoff-rotate-iterm-$$-scpt"
mkdir -p "$SCPT_DIR"
info "bg log: $LOG_FILE"

# ORIG_SESSION_ID format is "wWtTpP:UUID". AppleScript `unique id` property
# is just the UUID, so strip the wWtTpP: prefix before matching.
ORIG_UUID="${ORIG_SESSION_ID##*:}"

# Helper script: split the session matching targetUUID and write text into
# the NEW (ghost) pane. Avoids any id-lookup for the new session by using
# the object reference returned from `split vertically`.
cat > "$SCPT_DIR/ghost-split.scpt" <<'APPLESCRIPT'
on run argv
  set targetUUID to item 1 of argv
  set ghostCmd to item 2 of argv
  tell application "iTerm2"
    set origSess to my findSession(targetUUID)
    if origSess is missing value then error "orig session not found: " & targetUUID
    tell origSess
      set newSess to (split vertically with default profile)
    end tell
    delay 0.5
    tell newSess to write text ghostCmd
  end tell
end run

on findSession(targetUUID)
  tell application "iTerm2"
    repeat with aWindow in windows
      repeat with aTab in tabs of aWindow
        repeat with aSession in sessions of aTab
          try
            if unique id of aSession is targetUUID then
              return aSession
            end if
          end try
        end repeat
      end repeat
    end repeat
    return missing value
  end tell
end findSession
APPLESCRIPT

# Helper script: find the session matching targetUUID and write text to it.
cat > "$SCPT_DIR/write-text.scpt" <<'APPLESCRIPT'
on run argv
  set targetUUID to item 1 of argv
  set textToWrite to item 2 of argv
  tell application "iTerm2"
    set targetSess to my findSession(targetUUID)
    if targetSess is missing value then error "session not found: " & targetUUID
    tell targetSess to write text textToWrite
  end tell
end run

on findSession(targetUUID)
  tell application "iTerm2"
    repeat with aWindow in windows
      repeat with aTab in tabs of aWindow
        repeat with aSession in sessions of aTab
          try
            if unique id of aSession is targetUUID then
              return aSession
            end if
          end try
        end repeat
      end repeat
    end repeat
    return missing value
  end tell
end findSession
APPLESCRIPT

# --- 6. Dry-run: print the plan and exit ------------------------------------

if [[ $DRY_RUN -eq 1 ]]; then
  info "[dry-run] would spawn detached zsh background subshell"
  info "[dry-run] AppleScript helpers: $SCPT_DIR"
  info "[dry-run] orig UUID: $ORIG_UUID"
  info "[dry-run] sequence:"
  info "  sleep 3"
  info "  osascript ghost-split.scpt <uuid> '$GHOST_LAUNCH'"
  info "  sleep 12 (ghost boot)"
  info "  kill -QUIT $ORIG_PID"
  info "  wait for death"
  info "  osascript write-text.scpt <uuid> '$BASE_LAUNCH'"
  info "  sleep 10 (Y' boot)"
  info "  osascript write-text.scpt <uuid> '/takeover'"
  rm -rf "$SCPT_DIR"
  exit 0
fi

# --- 7. Spawn detached background zsh ---------------------------------------

nohup zsh -c "
  set -u
  exec >> '$LOG_FILE' 2>&1
  echo \"[\$(date +%H:%M:%S)] bg zsh started, pid=\$\$ launch_mode=$LAUNCH_MODE\"

  # 1. Let bash main return cleanly to Y4 before we touch anything.
  sleep 3

  # 2. Ghost split FIRST — must capture the current jsonl before Y'
  #    creates a newer one (Rule 1: ghost-first ordering).
  echo \"[\$(date +%H:%M:%S)] creating ghost split for uuid=$ORIG_UUID\"
  if ! osascript '$SCPT_DIR/ghost-split.scpt' '$ORIG_UUID' '$GHOST_LAUNCH'; then
    echo 'ERROR: ghost-split.scpt failed — aborting before SIGQUIT'
    exit 1
  fi
  echo \"[\$(date +%H:%M:%S)] ghost split dispatched\"

  # 3. Wait for ghost claude to actually inherit the current jsonl.
  sleep 12
  echo \"[\$(date +%H:%M:%S)] ghost should be loaded\"

  # 4. SIGQUIT Y4. ADR-026 Rule 2: signal the pid directly.
  echo \"[\$(date +%H:%M:%S)] SIGQUIT $ORIG_PID\"
  kill -QUIT '$ORIG_PID' 2>/dev/null || echo 'WARN: kill -QUIT failed'

  # 5. Wait for death (max 10s).
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

  # Brief grace for the shell prompt to reappear in ORIG pane.
  sleep 2

  # 6. Y' — fresh launch in the ORIG pane.
  if ! osascript '$SCPT_DIR/write-text.scpt' '$ORIG_UUID' '$BASE_LAUNCH'; then
    echo 'WARN: write-text.scpt failed for Y dispatch'
  fi
  echo \"[\$(date +%H:%M:%S)] Y' dispatched ($BASE_LAUNCH)\"

  # 7. Wait for Y' to boot.
  sleep 10

  # 8. Inject /takeover.
  if ! osascript '$SCPT_DIR/write-text.scpt' '$ORIG_UUID' '/takeover'; then
    echo 'WARN: write-text.scpt failed for /takeover inject'
  fi
  echo \"[\$(date +%H:%M:%S)] /takeover injected\"

  # 9. Cleanup helper scripts.
  rm -rf '$SCPT_DIR'

  echo \"[\$(date +%H:%M:%S)] rotation complete\"
" </dev/null >/dev/null 2>&1 &
disown
BG_PID=$!
ok "background zsh spawned: pid=$BG_PID"

# --- 8. Final instructions ---------------------------------------------------

printf '\n\033[1mNext (automated, ~30s total):\033[0m\n'
cat <<EOF
  T+3s   ghost split opens (inherits current jsonl via $LAUNCH_MODE mode)
  T+15s  Y4 (pid $ORIG_PID) gets SIGQUIT
  T+19s  Y' spawns in original pane ($BASE_LAUNCH)
  T+29s  /takeover injected to Y'

Watch progress:    tail -f $LOG_FILE
Close ghost later: just close the iTerm2 split manually
Recover Y4 later:  claude --resume <session-uuid>  (jsonl preserved)
EOF
