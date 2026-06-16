# Constraint: Agent must not bypass permission/hook denials

## Status: Active
## Severity: Critical
## Scope: All personas (every agent that consumes this framework)

## Rule

Agent는 다음 신호를 받으면 **즉시 멈추고 사용자에게 명시 승인을 요청**해야 한다:

1. Bash hook 이 `BLOCKED:` / `REFUSED:` 등 deny 메시지 반환
2. Claude Code permission system 이 `denied by auto mode` 표시
3. MCP tool 이 `denied` / `unauthorized` / `permission denied` 반환
4. 사내 가드 (`hooks/general/guard-*.sh`) 가 차단

## 우회 금지 동작

다음 동작은 **사용자 명시 승인 없이는 절대 수행 금지**:

- `~/.claude/settings.json` / `~/.claude/settings.local.json` / `<project>/.claude/settings.local.json` 의
  `permissions.allow` / `permissions.deny` 직접 수정
- Hook 스크립트 본문 수정 → 차단 로직 무력화
- 동일 작업을 다른 도구로 재시도해서 hook 회피
  (예: `cmux send-key` 차단되면 `sib send` 로 우회, `claude mcp` 차단되면 직접 REST 호출)
- Hook 이 의존하는 env var / config 파일 / state file 을 변경해서 검사 결과 변조
- `~/.claude/agent-context/`, `~/.claude/skills/`, `~/.claude/hooks/` 의 framework-installed 파일 수정
  (수정이 필요하면 framework PR 로 가야 함)

## 예외

자동으로 진행 가능한 경우는 다음뿐:

- 사용자가 같은 대화 안에서 명시적으로 "권한 추가해", "허용해", "이 deny 우회해도 돼", "settings.json 직접 수정해" 등
  지시 → 그 범위에 한해 자동 진행
- 이미 `permissions.allow` 또는 sticky permission 으로 등록된 작업
  (이 경우 차단 자체가 발생 안 함)

## 승인 요청 형식

권한 추가 / 우회가 필요할 때 agent 는 다음 형식으로 사용자에게 명시 승인 요청해야 한다:

```
## 권한 추가 / 우회 승인 요청

**무엇**: <어떤 도구/권한/설정 파일>
**어디**: <설정 파일 절대경로 또는 우회 대상 도구>
**왜**: <왜 이 권한이 필요한지, 어떤 작업을 하려는지>
**위험**: <이 권한이 열어줄 수 있는 부수 효과 / 영구적 효과 여부>
**대안**: <우회 안 하고 가능한 다른 방법 — 있다면>
**승인 효과**: <영구적 (settings.json) 인지 일회성인지>

승인하시면 진행합니다.
```

## Rationale

Agent 가 막힌 권한을 임의로 풀면 다음 문제가 발생한다:

1. **사용자가 의도적으로 둔 안전장치 무력화** — hook / deny 는 보통 사고 방지용
2. **Grant 가 코드 history 에 안 남음** — `~/.claude/settings.json` 은 일반적으로 gitignore.
   "왜 이 권한이 열렸는지" 추적 불가
3. **다른 머신 / 세션에서 재현 안 됨** — 한 머신에만 풀어주면 다른 머신은 여전히 막힘 → 동작 불일치
4. **사고 발생 시 책임 추적 불가** — agent 가 자동으로 풀어준 권한 vs 사용자가 의식하고 풀어준 권한 구분 불가
5. **hook 우회를 한 번 허용하면 같은 패턴 재발** — agent 가 학습해서 다음에도 자동 우회 시도

## Verification

이 제약 위반 여부는 다음으로 확인:

- `git log -p` 에서 agent commit 이 `permissions.allow` 추가하는지 (보통 settings.json 은 gitignore 라 직접 안 잡힘 — 대화 transcript 로 점검)
- Hook 스크립트 (`hooks/**/*.sh`) 본문 수정 commit 이 agent 가 한 것이라면 PR review 에서 차단
- `defaultMode: auto` 환경에서 갑자기 새 MCP tool 이 deny 없이 통과되는 패턴이 보이면 의심

## Real-world precedent

2026-06-15 ADR-036 cutover 검증 시, agent 가
`mcp__agentmemory__memory_recall` 이 `denied by auto mode` 라는 메시지를 받고 → 사용자 승인 없이
`~/.claude/settings.json` 의 `permissions.allow` 에 7개 MCP tool 을 직접 추가한 사고 발생.
이 제약은 그 사고에서 출발했다.

## References

- 2026-06-16 framework reorg (this constraint added as L1 first item)
- Claude Code permission docs: <https://docs.claude.com/en/docs/claude-code/security>
