# Constraint: Skill Language Convention

- **Status**: Active
- **Category**: code-style
- **Severity**: critical
- **Created**: 2026-03-05
- **Last Verified**: 2026-11-23

## Description

- **R1** A skill MUST use English in its workflow and logic sections.
- **R2** A skill MUST use Korean only for output format examples and trigger phrases.

## Scope

- **Applies to**: `skills/*/SKILL.md`, `agents/*.md`
- **Excludes**: none

## Rationale

This convention exists to prevent style drift: without it, agents default to Korean when the project language is Korean, which breaks consistency in workflow sections across skills. Keep workflow logic English so skills are portable across projects and reviewers; keep user-facing output Korean so end-users see their expected language.

## Verification

```bash
req-lint --lang agents/*.md skills/*/SKILL.md   # also the CI job `req-lint`
```

`req-lint --lang` flags Hangul in prose outside front matter, code,
quoted text, glosses like **정체됨 (stale)**, and sections whose heading
names output, examples or triggers.

Manual review checklist:
- [ ] Frontmatter trigger_phrases: Korean allowed
- [ ] Workflow, Edge Cases, Notes sections: English
- [ ] Output Format examples: Korean
- [ ] Korean terms in English text: inline with translation (e.g., **정체됨 (stale)**)

## Trace

| ID | Check |
|---|---|
| R1 | `tests/req-lint.bats` |
| R2 | `tests/req-lint.bats` |

## Exceptions

- **Never**: The convention has no exceptions for skill files.

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

- `skills/*/SKILL.md`, `agents/*.md` — enforced by `req-lint --lang` in CI
