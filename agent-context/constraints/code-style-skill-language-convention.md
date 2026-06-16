# Constraint: Skill Language Convention

- **Status**: Active
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

This convention exists to prevent style drift: without it, agents default to Korean when the project language is Korean, which breaks consistency in workflow sections across skills. Keep workflow logic English so skills are portable across projects and reviewers; keep user-facing output Korean so end-users see their expected language.

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

- `skills/*/SKILL.md` — enforce on every skill at review time
