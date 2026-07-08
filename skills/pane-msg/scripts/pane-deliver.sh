#!/usr/bin/env bash
# pane-deliver.sh — verified message delivery to an already-open cmux pane.
#
# Implements the verified submit pattern from docs/cmux-cli-reference.md §9:
#   send text → confirm it landed in the input box (wrap-immune match, codex
#   queue cleared) → send-key enter → confirm a work signal appeared (one
#   retry) → report.
#
# Safety gates (before any injection):
#   - refuses a pane showing an approval prompt (the approver daemon's
#     territory — injecting there could alter or double-fire an approval)
#   - refuses a busy pane ('esc to interrupt') unless --queue is passed,
#     which the calling skill may only pass after the user chose that target
#
# Usage:
#   pane-deliver.sh --surface <ref> --workspace <ref> [--queue] [--dry-run] -- <message...>
#   pane-deliver.sh --slug <slug>                     [--queue] [--dry-run] -- <message...>
#
# Newlines in the message are flattened to spaces: cmux send treats \n as
# Enter, which would submit a half-typed message.
#
# Exit codes:
#   0 delivered (submit confirmed, or queued under --queue)
#   2 usage error                    3 refused: approval prompt on screen
#   4 refused: pane busy (no --queue) 5 submitted but unconfirmed — inspect pane
#   6 target pane gone
set -euo pipefail
export PATH="/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:$PATH"
export CMUX_QUIET=1

STATE_DIR="${XDG_DATA_HOME:-$HOME/.local/share}/sib/state"

usage() { sed -n '2,27p' "$0" >&2; exit 2; }
die() { echo "pane-deliver: $1" >&2; exit "${2:-2}"; }

surface="" workspace="" slug="" queue=0 dry_run=0 msg=""
while (($#)); do case "$1" in
  --surface)   shift; surface="${1:?}" ;;
  --workspace) shift; workspace="${1:?}" ;;
  --slug)      shift; slug="${1:?}" ;;
  --queue)     queue=1 ;;
  --dry-run)   dry_run=1 ;;
  --)          shift; msg="$*"; break ;;
  *)           usage ;;
esac; shift || true; done

if [[ -n "${slug}" ]]; then
  [[ -n "${surface}" ]] && die "--slug and --surface are mutually exclusive"
  f="${STATE_DIR}/${slug}.env"
  [[ -f "$f" ]] || die "no sib state for slug '${slug}'" 6
  surface="$(sed -n 's/^surface=//p' "$f")"
  workspace="$(sed -n 's/^workspace=//p' "$f")"
fi
[[ -n "${surface}" && -n "${workspace}" ]] || usage
[[ -n "${msg}" ]] || die "empty message (put it after --)"

# Refuse to message the caller's own pane — a self-injection loops the
# session. surface refs are a global namespace, so the surface alone
# identifies self (workspace field format varies: ref vs UUID in sib state).
if ident="$(cmux identify --json 2>/dev/null)"; then
  self_surface="$(jq -r '.caller.surface_ref // empty' <<<"${ident}" 2>/dev/null || true)"
  [[ -n "${self_surface}" && "${surface}" == "${self_surface}" ]] \
    && die "target is the caller's own pane — refusing self-delivery" 2
fi

read_screen() { cmux read-screen --surface "${surface}" --workspace "${workspace}" --lines "${1:-40}" 2>/dev/null; }

read_screen 1 >/dev/null || die "pane ${surface} in ${workspace} is not readable (gone?)" 6

# Trailing-blank-stripped last 25 lines (Claude pads below prompts with blank
# lines; a naive tail sees only blanks). Same trick as the approver daemon.
screen_tail() {
  read_screen 40 \
    | awk '/[^[:space:]]/ { last = NR } { buf[NR] = $0 } END { for (i = 1; i <= last; i++) print buf[i] }' \
    | tail -n 25
}

# Busy = classic 'esc to interrupt' OR an agent spinner status line
# ('· Orchestrating… (12m …)') — newer Claude Code builds show only the
# spinner while working, with the ❯ input marker still drawn.
busy_signal() {
  grep -qiF 'esc to interrupt' <<<"$1" && return 0
  grep -qE '^[[:space:]]*(·|✢|✳|✶|✻|✽|\*|\+|•)[[:space:]]+[A-Z][a-z]+(…|\.\.\.)' <<<"$1"
}

tail_text="$(screen_tail)"

if [[ "${tail_text}" == *"Press enter to confirm"* \
   || "${tail_text}" == *"Do you want to proceed?"* \
   || "${tail_text}" == *"Would you like to run the following command?"* \
   || "${tail_text}" == *"Allow once"* || "${tail_text}" == *"Allow always"* \
   || "${tail_text}" == *"[y/N]"* || "${tail_text}" == *"[Y/n]"* ]] \
   || grep -qE '^[[:space:]]*[›❯] 1\. Yes' <<<"${tail_text}"; then
  echo "REFUSED: approval prompt on ${surface} — resolve it (user or approver daemon) before messaging." >&2
  exit 3
fi

# Sample the busy check 3× over ~1s: the spinner line is redrawn every
# frame, and a single read-screen can catch a repaint frame where it is
# momentarily absent (observed live).
busy=0
for _ in 1 2 3; do
  busy_signal "$(screen_tail)" && { busy=1; break; }
  sleep 0.4
done
if (( busy )) && (( ! queue )); then
  echo "REFUSED: ${surface} is busy (work signal visible). Re-run with --queue only if the user explicitly chose this target." >&2
  exit 4
fi

msg_flat="$(printf '%s' "${msg}" | tr '\n\t' '  ')"

if (( dry_run )); then
  echo "DRY-RUN: would deliver to ${surface} in ${workspace} (busy=${busy}, queue=${queue})"
  echo "DRY-RUN message: ${msg_flat}"
  exit 0
fi

# 1) Put the text in the input box (no enter yet).
cmux send --surface "${surface}" --workspace "${workspace}" "${msg_flat}" >/dev/null

# 2) Confirm the text landed. Strip spaces+newlines from BOTH the screen and
# the needle so a narrow pane's soft-wrap cannot break the match (§9 trap 4).
# codex additionally queues input while MCP servers load — wait until the
# 'tab to queue message' notice is gone (never appears for claude; harmless).
needle="$(printf '%s' "${msg_flat:0:24}" | tr -d ' ')"
landed=0
for i in $(seq 1 60); do
  scr="$(read_screen 40 || true)"
  scr_ns="$(printf '%s' "${scr}" | tr -d ' \n')"
  if grep -qF "${needle}" <<<"${scr_ns}" && ! grep -qF 'tab to queue message' <<<"${scr}"; then
    landed=1; break
  fi
  if (( i <= 10 )); then sleep 0.1; else sleep 0.5; fi
done
if (( ! landed )); then
  echo "UNCONFIRMED: text did not appear in ${surface}'s input box within ~30s — not submitting. Inspect the pane." >&2
  exit 5
fi

# 3) Submit.
cmux send-key --surface "${surface}" --workspace "${workspace}" enter >/dev/null

if (( busy )); then
  # Target was already mid-task; the message lands in the agent's input queue.
  # A work-signal check proves nothing here (the signal was already on).
  echo "QUEUED: message queued on busy ${surface} in ${workspace}."
  exit 0
fi

# 4) Confirm submission via a work signal; one retry (autocomplete or a
# late-clearing queue can eat the first enter), then keep polling up to
# ~8s — prompt-submit hooks (e.g. agentmemory) can delay the work signal
# by several seconds after a successful submit (observed live).
sleep 1
if ! busy_signal "$(read_screen 20)"; then
  cmux send-key --surface "${surface}" --workspace "${workspace}" enter >/dev/null
fi
for _ in $(seq 1 14); do
  if busy_signal "$(read_screen 20)"; then
    echo "DELIVERED: submitted to ${surface} in ${workspace} (work signal confirmed)."
    exit 0
  fi
  sleep 0.5
done

echo "UNCONFIRMED: text landed and enter was sent (x2) but no work signal on ${surface} within ~8s. Inspect the pane before retrying." >&2
exit 5
