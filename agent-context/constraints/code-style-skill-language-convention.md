# Constraint: Skill Language Convention

- **Category**: code-style
- **Severity**: critical
- **Created**: 2026-03-05
- **Last Verified**: 2026-03-05

## Description

Skill instructions must follow the language convention: English for workflow/logic sections, Korean only for output format examples and trigger phrases.

## Scope

- **Applies to**: `skills/*/SKILL.md`
- **Excludes**: none

## Rationale

ADR-017 Rule 2 established this convention after repeated incidents where Korean instructions in workflow sections broke consistency. Without an explicit constraint, agents default to Korean when the project language is Korean, causing style drift across skills.

## Verification

Manual review checklist:
- [ ] Frontmatter trigger_phrases: Korean allowed
- [ ] Workflow, Edge Cases, Notes sections: English
- [ ] Output Format examples: Korean
- [ ] Korean terms in English text: inline with translation (e.g., **정체됨 (stale)**)

## Exceptions

- **Never**: All skill files must follow this convention without exception.

## Examples

### Allowed

```markdown
## Workflow
1. Fetch Jira issues assigned to the current user.
2. Group by status: Done, In Progress, To Do.

## Output Format
### 완료된 이슈 (Done)
- [KEY-123] 이슈 제목
```

### Not Allowed

```markdown
## 워크플로우
1. 현재 사용자에게 할당된 Jira 이슈를 가져옵니다.
2. 상태별로 그룹화: 완료, 진행 중, 할 일.
```

## References

- [ADR-017: Skill Authoring Conventions and AGENTS.md Auto-Loading](../decisions/2026-02-26-skill-authoring-conventions-and-auto-loading.md)
