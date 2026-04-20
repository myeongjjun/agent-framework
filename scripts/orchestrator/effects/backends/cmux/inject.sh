#!/usr/bin/env bash
#
# backends/cmux/inject.sh — cmux backend for injecting /takeover-task
# or an arbitrary prompt into a sibling surface.
#
# SIDE EFFECT: cmux send + send-key. Dry-run by default.

set -euo pipefail
IFS=$'\n\t'

mode='dry-run'
as_prompt=0
family='claude'
target_workspace=''
verify=0
while (($# > 0)); do
  case "$1" in
    --dry-run) mode='dry-run'; shift ;;
    --execute) mode='execute'; shift ;;
    --as-prompt) as_prompt=1; shift ;;
    --family) shift; family="${1:-claude}"; shift ;;
    --workspace) shift; target_workspace="${1:-}"; shift ;;
    --verify) verify=1; shift ;;
    --help|-h) sed -n '2,9p' "$0" >&2; exit 0 ;;
    *) break ;;
  esac
done

[[ $# -eq 2 ]] || { echo "backends/cmux/inject.sh: usage: inject.sh [--dry-run|--execute] [--as-prompt] [--family claude|codex] [--workspace <id>] <surface-id> <payload>" >&2; exit 1; }
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
      backend: "cmux",
      mode: "dry-run",
      surface_id: $surface_id,
      prompt_mode: $prompt_mode,
      prompt_source: (if $prompt_source == "" then null else $prompt_source end),
      prompt_preview: $prompt_preview,
      commands: [
        ("cmux send --surface " + $surface_id + " " + ($inject_command | @json)),
        ("cmux send-key --surface " + $surface_id + " enter")
      ]
    }'
  exit 0
fi

command -v cmux >/dev/null 2>&1 || { echo "backends/cmux/inject.sh: cmux not found" >&2; exit 1; }
# Priority: explicit --workspace flag > ORCHESTRATOR_TARGET_WORKSPACE_ID env >
# CMUX_WORKSPACE_ID env (mirrors spawn.sh convention).
[[ -z "${target_workspace}" ]] && target_workspace="${ORCHESTRATOR_TARGET_WORKSPACE_ID:-${CMUX_WORKSPACE_ID:-}}"
ws_args=()
[[ -n "${target_workspace}" ]] && ws_args=(--workspace "${target_workspace}")

# Single send by default. Opt-in --verify for cases where the target is
# a booting agent (dispatch) that may drop the first prompt. Never use
# verify for shell-command inject (rotate's attach_cmd) — the shell
# runs the command and alternate-screen-swaps to the agent UI, so the
# fingerprint disappears and retry re-sends to the newly-booted agent
# as a user prompt.
if (( verify == 1 )); then
  # H9 pre-send readiness gate: wait up to 5s for the agent's input box
  # to be live before the first send. The agent-ready markers ("bypass
  # permissions on" for claude, "gpt-" model line for codex) appear when
  # stdin is actually wired — sending before then frequently gets the
  # text buffered to nowhere. If neither marker shows up, we still send
  # (post-hoc verify + retry below is the safety net).
  _ready_waited=0
  while (( _ready_waited < 10 )); do
    _screen="$(cmux read-screen --surface "${surface_id}" ${ws_args[@]+"${ws_args[@]}"} --lines 15 2>/dev/null || true)"
    if [[ -n "${_screen}" ]]; then
      if printf '%s' "${_screen}" | grep -qiE '(bypass permissions on|gpt-[0-9a-z.]+|auto-accept|high fast)'; then
        break
      fi
    fi
    sleep 0.5
    (( _ready_waited++ )) || true
  done
fi
cmux send --surface "${surface_id}" ${ws_args[@]+"${ws_args[@]}"} "${inject_command}" >/dev/null
cmux send-key --surface "${surface_id}" ${ws_args[@]+"${ws_args[@]}"} enter >/dev/null

if (( verify == 1 )); then
  # Verify the prompt actually reached the screen. If the first attempt
  # was dropped (booting agent stdin not live), retry once more.
  _fp="$(printf '%s' "${inject_command}" | tr '\n' ' ' | sed -E 's/[[:space:]]+/ /g' | cut -c1-40)"
  _verify_waited=0
  _verify_ok=0
  while (( _verify_waited < 6 )); do
    sleep 0.5
    _screen="$(cmux read-screen --surface "${surface_id}" ${ws_args[@]+"${ws_args[@]}"} --lines 30 2>/dev/null || true)"
    if [[ -n "${_screen}" ]] && [[ -n "${_fp}" ]]; then
      _screen_norm="$(printf '%s' "${_screen}" | tr '\n' ' ' | sed -E 's/[[:space:]]+/ /g')"
      if printf '%s' "${_screen_norm}" | grep -qF -- "${_fp}"; then
        _verify_ok=1
        break
      fi
    fi
    (( _verify_waited++ )) || true
  done
  if (( _verify_ok == 0 )); then
    # Single retry, then give up (don't cascade)
    sleep 2
    cmux send --surface "${surface_id}" ${ws_args[@]+"${ws_args[@]}"} "${inject_command}" >/dev/null
    cmux send-key --surface "${surface_id}" ${ws_args[@]+"${ws_args[@]}"} enter >/dev/null
  fi
fi

jq -n \
  --arg surface_id "${surface_id}" \
  --arg inject_action "${inject_action}" \
  --arg inject_command "${inject_command}" \
  --arg prompt_mode "${prompt_mode}" \
  --arg prompt_source "${prompt_source}" \
  --arg prompt_preview "${prompt_preview}" \
  '{
    action: $inject_action,
    backend: "cmux",
    mode: "execute",
    surface_id: $surface_id,
    prompt_mode: $prompt_mode,
    prompt_source: (if $prompt_source == "" then null else $prompt_source end),
    prompt_preview: $prompt_preview,
    command: $inject_command
  }'
