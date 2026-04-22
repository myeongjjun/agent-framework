#!/usr/bin/env bash
# approver-send-key.sh — cmux send-key wrapper for the approver agent.
#
# The guard-direct-session-control.sh hook blocks direct cmux send-key
# calls but allows scripts under the deployed approver runtime dir.
# This wrapper is copied to the approver's runtime dir by daemon.sh.
set -euo pipefail

if [[ "${1:-}" == "--dry-run" ]]; then
  shift
  jq -n \
    --arg args "$*" \
    '{
      action: "approver-send-key",
      backend: "cmux",
      mode: "dry-run",
      args: $args
    }'
  exit 0
fi

surface_id=''
workspace_id=''
key_name=''

while (($# > 0)); do
  case "$1" in
    --surface)
      shift
      surface_id="${1:-}"
      ;;
    --workspace)
      shift
      workspace_id="${1:-}"
      ;;
    -*)
      printf 'approver-send-key.sh: unsupported argument: %s\n' "$1" >&2
      exit 2
      ;;
    *)
      if [[ -n "${key_name}" ]]; then
        printf 'approver-send-key.sh: unsupported argument: %s\n' "$1" >&2
        exit 2
      fi
      key_name="$1"
      ;;
  esac
  shift
done

if [[ -z "${surface_id}" || -z "${workspace_id}" || "${key_name}" != 'enter' ]]; then
  printf 'approver-send-key.sh: only --surface <id> --workspace <id> enter is allowed\n' >&2
  exit 2
fi

exec cmux send-key --surface "${surface_id}" --workspace "${workspace_id}" enter
