#!/bin/bash
# guard-cherry-pick.sh — warn-mode guard against ad-hoc `git cherry-pick`
# in routine worker → base integration. Steers users toward
# `./scripts/agent-promote.sh <slug>` for that flow while keeping
# cherry-pick available for legitimate uses.
# @hook event: PreToolUse
# @hook matcher: Bash
# @hook timeout: 5
#
# Cherry-pick remains valid for:
#   - /collab synthesis (mixing best commits from two worker branches)
#   - selective hotfix (porting a single commit between long-lived branches)
#   - recovery operations (--abort, --continue, --skip, --quit)
#
# Opt-out (per command):
#   CHERRY_PICK_OK=1 git cherry-pick <ref>
#
# Exit 1 = warn (stderr surfaced, command still executes in Claude hooks).
# Promote to exit 2 (block) after false-positive rate stabilises.

set -euo pipefail

input=$(cat)
tool_name=$(echo "$input" | jq -r '.tool_name // empty')
[[ "$tool_name" == "Bash" ]] || exit 0

command=$(echo "$input" | jq -r '.tool_input.command // empty')
[[ -n "$command" ]] || exit 0

# Per-command opt-out
if [[ "$command" =~ CHERRY_PICK_OK=1 ]]; then
  exit 0
fi

# Neutralise quoted strings before matching so `git commit -m '... cherry-pick ...'`
# (or any other quoted occurrence) doesn't trigger false positives. This is
# more robust than positional regex (from Codex synth).
sanitized=$(printf '%s' "$command" | sed -E "s/'[^']*'/''/g; s/\"[^\"]*\"/\"\"/g")

# Detect a `git cherry-pick` invocation. Pattern: `git` + optional dash-flags
# (git-level options like -c, -C, --git-dir, plus their values if separated)
# + literal `cherry-pick`. Operates on the sanitized command so quoted
# message bodies can't smuggle the keyword through.
if ! [[ "$sanitized" =~ (^|[[:space:]]|&&[[:space:]]*|;[[:space:]]*|\|[[:space:]]*|\([[:space:]]*)git[[:space:]]+(-[A-Za-z][^[:space:]]*[[:space:]]+|--[A-Za-z][^[:space:]]*[[:space:]]+|[^[:space:]]+[[:space:]]+)*cherry-pick([[:space:]]|$) ]]; then
  exit 0
fi

# Recovery operations — always allowed silently.
if [[ "$command" =~ cherry-pick[[:space:]]+(--abort|--continue|--skip|--quit) ]]; then
  exit 0
fi

cat >&2 <<'EOF'
WARNING: `git cherry-pick` invoked outside the standard integration flow.

For routine dispatched-worker → base integration, prefer:
  ./scripts/agent-promote.sh <slug>

Cherry-pick remains valid for:
  - /collab synthesis (mixing best commits from two worker branches)
  - selective hotfix (porting a single commit between long-lived branches)
  - recovery (--abort / --continue / --skip / --quit)

Opt-out (per command):
  CHERRY_PICK_OK=1 git cherry-pick <ref>

This guard is warn-mode (exit 1) — the command still runs. It will be
escalated to BLOCK once false-positive rate stabilises.
EOF

exit 1
