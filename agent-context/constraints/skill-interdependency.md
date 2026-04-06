# Constraint: Skill Interdependency

## Status: Active
## Severity: High
## Scope: handoff, takeover, codex skills

## Rule

다음 세 skill은 상호 의존 관계이며, 하나를 변경할 때 나머지와의 호환성을 반드시 검토해야 합니다:

| Skill | Depends On | Provides To |
|-------|------------|-------------|
| handoff | - | takeover, codex |
| takeover | handoff | codex |
| codex | handoff, takeover | - |

## Dependency Diagram

```
handoff ──────────┬──────────► takeover
    │             │                │
    │             │                │
    ▼             │                ▼
  entry-*.md      │            (reads entry)
    │             │                │
    └─────────────┼────────────────┘
                  │
                  ▼
               codex
        (reads + creates entries)
```

## Change Protocol

### handoff 변경 시
- [ ] takeover가 새 포맷을 파싱할 수 있는가?
- [ ] codex가 새 포맷을 파싱하고 생성할 수 있는가?
- [ ] codex의 handoff-integration.md 업데이트 필요?
- [ ] codex의 scripts/ 업데이트 필요?

### takeover 변경 시
- [ ] handoff entry 읽기에 영향 있는가?
- [ ] codex의 takeover 호출에 영향 있는가?

### codex 변경 시
- [ ] handoff entry 생성 포맷이 호환되는가?
- [ ] takeover 호출 방식이 호환되는가?
- [ ] handoff-integration.md 예제가 최신 포맷인가?

## Versioning Rule

세 skill의 호환 버전을 명시:

| Skill | Version | Entry Format |
|-------|---------|--------------|
| handoff | v1.0.0 | 6-section |
| takeover | v1.0.0 | 6-section |
| codex | v2.3.0 | 6-section |

버전 변경 시 이 문서도 업데이트할 것.

## Breaking Changes

다음 변경은 **Breaking Change**로 간주:
- Entry 섹션 구조 변경 (추가/제거/이름 변경)
- Session 테이블 필수 필드 변경
- Entry 파일명 규칙 변경
- `.agent/` 디렉터리 구조 변경

Breaking Change 발생 시:
1. 모든 3 skill 동시 업데이트
2. 마이그레이션 가이드 작성
3. ADR 기록

## Testing Protocol

변경 후 반드시 테스트:
1. Claude handoff → Codex takeover
2. Codex handoff → Claude takeover
3. Non-git 환경에서 handoff/takeover

## References

- skills/handoff/SKILL.md
- skills/takeover/SKILL.md
- skills/codex/SKILL.md
- skills/codex/references/handoff-integration.md
- agent-context/constraints/handoff-format-v1.md
