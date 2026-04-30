#!/bin/bash
# guard-prod-kubectl.sh - Block kubectl write operations against prod context
# @hook event: PreToolUse
# @hook matcher: Bash
# @hook timeout: 5
set -euo pipefail

input=$(cat)
command=$(echo "$input" | jq -r '.tool_input.command // empty')

# Skip non-kubectl commands
if [[ ! "$command" =~ kubectl ]]; then
  exit 0
fi

# Only inspect the kubectl pipeline segment (anything before the first |, ;, or
# subshell boundary). Avoids false-positives where a downstream command in a
# pipeline mentions "prod" or a mutating verb.
kubectl_segment="${command%%|*}"
kubectl_segment="${kubectl_segment%%;*}"

# Restrict prod detection to explicit targeting flags. Matching any token that
# merely contains "prod" would false-positive on filenames/labels such as
# `-f prod.yaml` or `-l env=prod` against a staging context.
prod_target_re='(--context(=|[[:space:]])[^[:space:]]*prod[^[:space:]]*|--namespace(=|[[:space:]])[^[:space:]]*prod[^[:space:]]*|-n[[:space:]]+[^[:space:]]*prod[^[:space:]]*)'

if [[ ! "$kubectl_segment" =~ $prod_target_re ]]; then
  exit 0
fi

# High-risk mutating verbs. `cp` covers `kubectl cp` (file copy into pods).
mutating_re='kubectl([[:space:]]+[^[:space:]]+)*[[:space:]]+(apply|delete|patch|scale|edit|replace|rollout|cp|create|annotate|label|taint|drain|cordon|uncordon|set|expose|run|autoscale)([[:space:]]|$)'

if [[ "$kubectl_segment" =~ $mutating_re ]]; then
  verb="${BASH_REMATCH[2]}"
  echo "BLOCKED: prod context에서 kubectl ${verb} 명령은 사용자 승인 없이 실행할 수 없습니다." >&2
  exit 2
fi

# kubectl exec on prod with write-style SQL — preserved from the original guard.
if [[ "$kubectl_segment" =~ [[:space:]]exec([[:space:]]|$) ]]; then
  if [[ "$kubectl_segment" =~ (ALTER|ATTACH|DELETE|DETACH|DROP|INSERT|KILL|RENAME|REVOKE|SYSTEM|TRUNCATE) ]]; then
    echo "BLOCKED: prod context에서 쓰기 명령(ALTER/DROP/INSERT 등)은 사용자 승인 없이 실행할 수 없습니다." >&2
    exit 2
  fi
fi

exit 0
