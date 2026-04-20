#!/usr/bin/env bash
#
# backends/iterm2/inject.sh — iTerm2 backend for injecting /takeover-task
# or an arbitrary prompt.
#
# SIDE EFFECT: osascript write text. Dry-run by default.
# `write text` delivers its own newline — no separate enter keystroke.

set -euo pipefail
IFS=$'\n\t'

mode='dry-run'
as_prompt=0
family='claude'
while (($# > 0)); do
  case "$1" in
    --dry-run) mode='dry-run'; shift ;;
    --execute) mode='execute'; shift ;;
    --as-prompt) as_prompt=1; shift ;;
    --family) shift; family="${1:-claude}"; shift ;;
    --help|-h) sed -n '2,9p' "$0" >&2; exit 0 ;;
    *) break ;;
  esac
done

[[ $# -eq 2 ]] || { echo "backends/iterm2/inject.sh: usage: inject.sh [--dry-run|--execute] [--as-prompt] [--family claude|codex] <surface-id> <payload>" >&2; exit 1; }
surface_id="$1"
payload="$2"

# Determine inject content. Default mode sends a plain prompt telling the
# worker to read its work item file. --as-prompt sends arbitrary text.
if (( as_prompt == 1 )); then
  if [[ -f "${payload}" ]]; then
    prompt_mode='file'
    prompt_source="${payload}"
    prompt_text="$(<"${payload}")"
  else
    prompt_mode='literal'
    prompt_source=''
    prompt_text="${payload}"
  fi
  inject_action='inject-prompt'
  inject_command="${prompt_text}"
else
  prompt_mode='work-item'
  prompt_source="${payload}"
  inject_action='inject-takeover'
  inject_command="Read ${payload} and follow the instructions in it. Do not ask for confirmation — start working immediately."
fi

prompt_preview="$(printf '%s' "${inject_command}" | tr '\n' ' ' | sed -E 's/[[:space:]]+/ /g')"
if [[ ${#prompt_preview} -gt 120 ]]; then
  prompt_preview="${prompt_preview:0:117}..."
fi

if [[ "${mode}" == 'dry-run' ]]; then
  jq -n \
    --arg surface_id "${surface_id}" \
    --arg inject_action "${inject_action}" \
    --arg inject_command "${inject_command}" \
    --arg prompt_mode "${prompt_mode}" \
    --arg prompt_source "${prompt_source}" \
    --arg prompt_preview "${prompt_preview}" \
    '{
      action: $inject_action,
      backend: "iterm2",
      mode: "dry-run",
      surface_id: $surface_id,
      prompt_mode: $prompt_mode,
      prompt_source: (if $prompt_source == "" then null else $prompt_source end),
      prompt_preview: $prompt_preview,
      commands: [
        ("osascript -e \"tell application \\\"iTerm2\\\" to tell session id \\\"" + $surface_id + "\\\" to write text \" -e " + ($inject_command | @json))
      ]
    }'
  exit 0
fi

command -v osascript >/dev/null 2>&1 || { echo "backends/iterm2/inject.sh: osascript not found" >&2; exit 1; }

osascript <<OSA
tell application "iTerm2"
  tell session id "${surface_id}"
    write text "${inject_command}"
  end tell
end tell
OSA

jq -n \
  --arg surface_id "${surface_id}" \
  --arg inject_action "${inject_action}" \
  --arg inject_command "${inject_command}" \
  --arg prompt_mode "${prompt_mode}" \
  --arg prompt_source "${prompt_source}" \
  --arg prompt_preview "${prompt_preview}" \
  '{
    action: $inject_action,
    backend: "iterm2",
    mode: "execute",
    surface_id: $surface_id,
    prompt_mode: $prompt_mode,
    prompt_source: (if $prompt_source == "" then null else $prompt_source end),
    prompt_preview: $prompt_preview,
    command: $inject_command
  }'
