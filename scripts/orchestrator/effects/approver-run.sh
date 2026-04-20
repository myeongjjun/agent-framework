#!/usr/bin/env bash

set -euo pipefail
IFS=$'\n\t'

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"

if [[ "${1:-}" == "--dry-run" ]]; then
  printf '{"action":"approver-run","mode":"dry-run","script_dir":"%s"}\n' "${SCRIPT_DIR}"
  exit 0
fi

printf 'READY\n' > "${SCRIPT_DIR}/BOOTSTRAPPED"
exec "${SCRIPT_DIR}/approver-scan.sh" --loop
