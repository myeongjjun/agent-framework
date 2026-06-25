# Constraints Index

> Last updated: 2026-06-25

## By Severity

### Critical

| Constraint | Category | Scope |
|------------|----------|-------|
| [no-permission-bypass](no-permission-bypass.md) | security | All personas |
| [code-style-skill-language-convention](code-style-skill-language-convention.md) | code-style | `skills/*/SKILL.md` |

### High

| Constraint | Description |
|------------|-------------|
| [hook-source-of-truth](hook-source-of-truth.md) | Hooks managed in `hooks/<category>/` + deployed via `scripts/install.sh` only |
| [agent-behavior-verify-before-conclude](agent-behavior-verify-before-conclude.md) | Require quantitative + qualitative evidence before conclusions |
| [git-workflow](git-workflow.md) | Work directly on `main`; review before pushing (public repo). Repo-scoped, not inherited |

### Medium

_None yet_
