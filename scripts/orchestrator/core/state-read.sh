#!/usr/bin/env bash

set -euo pipefail
IFS=$'\n\t'

usage() {
  cat <<'EOF'
Usage: state-read.sh [--root <path>]

Read orchestrator state JSON from the configured root. If the state file
does not exist, emit the empty schema.
EOF
}

orchestrator_root="${ORCHESTRATOR_ROOT:-${HOME}/.orchestrator}"

while (($# > 0)); do
  case "$1" in
    --root)
      shift
      [[ $# -gt 0 ]] || { echo "state-read.sh: missing value for --root" >&2; exit 1; }
      orchestrator_root="$1"
      ;;
    --help|-h)
      usage
      exit 0
      ;;
    *)
      echo "state-read.sh: unknown argument: $1" >&2
      exit 1
      ;;
  esac
  shift
done

state_file="${orchestrator_root}/state.json"

if [[ -f "${state_file}" ]]; then
  # Read once and reuse the buffer (H1 fix). Re-reading the file between
  # validation and output lets a concurrent writer replace the content
  # under us, so the bytes we emit are not the bytes we validated.
  raw_state="$(cat -- "${state_file}")"
  if [[ -z "${raw_state//[[:space:]]/}" ]]; then
    echo "state-read.sh: state file is blank: ${state_file}" >&2
    exit 1
  fi
  jq -e 'type == "object"' <<<"${raw_state}" >/dev/null
  jq '.' <<<"${raw_state}"
else
  jq -n '{
    version: 1,
    updated_at: null,
    projects: {},
    tasks: {},
    agents: {}
  }'
fi
