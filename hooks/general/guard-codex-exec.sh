#!/bin/bash
# guard-codex-exec.sh — block headless Codex runs (`codex exec`, its alias
# `codex e`, and `codex review`). Codex runs only in a cmux pane, started
# with `sib spawn --codex`, so the desk and the user can see, answer and
# stop it (ADR-008, user ruling 2026-11-23).
# @hook event: PreToolUse
# @hook matcher: Bash
# @hook timeout: 5
#
# Works for Claude Code and Codex: both send
# {"tool_name":"Bash","tool_input":{"command":"..."}} on stdin.
# No opt-out: the user ruled "무조건 cmux 위에서".
#
# Exit 2 = block (stderr goes back to the agent).

set -euo pipefail

input=$(cat)
tool_name=$(printf '%s' "$input" | jq -r '.tool_name // empty')
[[ "$tool_name" == "Bash" || "$tool_name" == "shell" || "$tool_name" == "exec_command" ]] || exit 0

command=$(printf '%s' "$input" | jq -r '.tool_input.command // .tool_input.cmd // empty | if type == "array" then join(" ") else . end')
[[ -n "$command" ]] || exit 0

# `codex` as a command word (bare, a path, or npx @openai/codex), then any
# global flags with optional values, then a headless subcommand.
pattern='(^|[[:space:];&|(`"'\'']|\$\()([^[:space:];&|(`]*/)?codex[[:space:]]+((-[^[:space:]]+)([[:space:]]+[^-[:space:];&|][^[:space:];&|]*)?[[:space:]]+)*(exec|e|review)([[:space:];&|)]|$)'

# Drop quoted strings first so `git commit -m "remove codex exec"` and
# `grep "codex exec"` pass.
# Whole input at once (perl -0), not line by line: a quoted string may span lines.
sanitized=$(printf '%s' "$command" | perl -0pe "s/'[^']*'/''/g; s/\"[^\"]*\"/\"\"/g")

# A shell string (`bash -c "codex exec ..."`, `eval '...'`) is code, not text:
# check the raw command when one is present.
shell_string='(^|[[:space:];&|(])((ba|z)?sh[[:space:]]+(-[a-z]+[[:space:]]+)*-[a-z]*c|eval)[[:space:]]'

hit=0
if [[ "$sanitized" =~ $pattern ]]; then
  hit=1
elif [[ "$sanitized" =~ $shell_string ]] && [[ "$command" =~ $pattern ]]; then
  hit=1
fi
(( hit )) || exit 0

cat >&2 <<'EOF'
BLOCKED: headless Codex (`codex exec` / `codex e` / `codex review`) is not allowed.

Codex runs only in a cmux pane, so the desk and the user can see, answer
and stop it (ADR-008; user ruling 2026-11-23).

Use a pane instead:
  sib spawn codex-<slug> --codex -- "<the whole brief>"   # --worktree to isolate
  sib send codex-<slug> "..."                        # talk to it
  sib kill codex-<slug>                              # close it when done

A one-shot job also gets a pane: put the whole brief in the prompt, ask for
a short result summary, read the pane, then `sib kill`. Outside cmux, stop
and ask the user to run the task in cmux. See the `codex` skill.
EOF
exit 2
