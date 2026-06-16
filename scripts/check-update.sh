#!/usr/bin/env bash
# check-update.sh — pull agent-framework updates from origin and re-install.
#
# Intended for periodic (cron) invocation:
#   */30 * * * * ~/personal/agent-framework/scripts/check-update.sh
#
# Behaviour:
#   1. git fetch origin (HEAD of default branch)
#   2. If local HEAD != origin HEAD → git pull --ff-only
#   3. On any update: run scripts/install.sh
#   4. On any error: log to ~/.claude/.framework-check.log, exit non-zero,
#      do NOT block (caller is cron / SessionStart hook).
#
# Always exits 0 unless --strict given (so a cron miss does not spam).
# Logs a single line per run for traceability.

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FRAMEWORK_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
LOG="${HOME}/.claude/.framework-check.log"
STRICT=0

while (( $# > 0 )); do
  case "$1" in
    --strict) STRICT=1 ;;
    -h|--help) sed -n '2,16p' "$0" >&2; exit 0 ;;
    *) echo "unknown flag: $1" >&2; exit 1 ;;
  esac
  shift
done

mkdir -p "$(dirname "${LOG}")"

log() {
  printf '%s [check-update] %s\n' "$(date -u '+%Y-%m-%dT%H:%M:%SZ')" "$*" >> "${LOG}"
}

bail() {
  log "FAIL: $*"
  if (( STRICT == 1 )); then
    echo "[check-update] FAIL: $*" >&2
    exit 1
  fi
  exit 0
}

cd "${FRAMEWORK_ROOT}" || bail "framework root not accessible: ${FRAMEWORK_ROOT}"

# Determine remote + tracking branch
remote="$(git remote 2>/dev/null | head -1)"
[[ -n "${remote}" ]] || bail "no git remote configured"

branch="$(git rev-parse --abbrev-ref HEAD 2>/dev/null || true)"
[[ -n "${branch}" && "${branch}" != "HEAD" ]] || bail "not on a branch"

# Fetch — short timeout so network issues don't hang cron
if ! timeout 20s git fetch --quiet "${remote}" "${branch}" 2>>"${LOG}"; then
  bail "git fetch ${remote}/${branch} failed (network? auth?)"
fi

local_head="$(git rev-parse HEAD 2>/dev/null || true)"
remote_head="$(git rev-parse "${remote}/${branch}" 2>/dev/null || true)"

if [[ -z "${local_head}" || -z "${remote_head}" ]]; then
  bail "could not resolve local or remote head"
fi

if [[ "${local_head}" == "${remote_head}" ]]; then
  log "OK: up-to-date at ${local_head:0:8}"
  exit 0
fi

# Refuse to update if working tree dirty — would lose work
if ! git diff --quiet || ! git diff --cached --quiet; then
  bail "working tree dirty; refusing to pull (manual fix required)"
fi

log "INFO: updating ${local_head:0:8} → ${remote_head:0:8}"

if ! git pull --ff-only --quiet "${remote}" "${branch}" 2>>"${LOG}"; then
  bail "git pull --ff-only failed (non-fast-forward?)"
fi

if ! "${SCRIPT_DIR}/install.sh" >>"${LOG}" 2>&1; then
  bail "install.sh failed"
fi

log "OK: installed ${remote_head:0:8}"
exit 0
