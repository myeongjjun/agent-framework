#!/bin/bash
set -euo pipefail

input=$(cat)
command=$(echo "$input" | jq -r '.tool_input.command // empty')

# kubectl exec on prod context with dangerous SQL
if [[ "$command" =~ kubectl.*prod.*exec ]] || [[ "$command" =~ kubectl.*--context=.*prod.*exec ]]; then
  if [[ "$command" =~ (ALTER|DROP|INSERT|TRUNCATE|DELETE|RENAME|KILL) ]]; then
    echo "{\"hookSpecificOutput\":{\"permissionDecision\":\"deny\"},\"systemMessage\":\"BLOCKED: prod context에서 쓰기 명령(ALTER/DROP/INSERT 등)은 사용자 승인 없이 실행할 수 없습니다.\"}" >&2
    exit 2
  fi
fi

exit 0
