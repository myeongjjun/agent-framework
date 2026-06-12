#!/usr/bin/env bash

set -euo pipefail
IFS=$'\n\t'

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
LOOP_LOG="${SCRIPT_DIR}/loop.log"

# cmux 0.64+ changed default socket path to ~/.local/state/cmux/cmux.sock
export CMUX_SOCKET_PATH="${CMUX_SOCKET_PATH:-${HOME}/.local/state/cmux/cmux.sock}"

timestamp_utc() {
  date -u +"%Y-%m-%dT%H:%M:%SZ"
}

if [[ "${1:-}" == "--dry-run" ]]; then
  printf '{"action":"approver-run","mode":"dry-run","script_dir":"%s","loop_log":"%s"}\n' "${SCRIPT_DIR}" "${LOOP_LOG}"
  exit 0
fi

printf 'READY\n' > "${SCRIPT_DIR}/BOOTSTRAPPED"
: >> "${LOOP_LOG}"
printf '%s approver-run starting scan loop pid=%s\n' "$(timestamp_utc)" "$$" >> "${LOOP_LOG}"
exec "${SCRIPT_DIR}/approver-scan.sh" --loop
