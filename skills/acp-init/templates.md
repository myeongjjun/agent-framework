# ACP Init Templates

## AGENTS.md Template

```markdown
# AGENTS.md

> ACP guide for AI agents.

## ⚠️ Critical Rule

**agent-context/ 파일 직접 수정 금지.**
**반드시 ACP Skills 사용.**

위반 시 context 동기화 깨짐.

---

## Agent Context Pack (ACP) v1.0

### Directory Structure

| Directory | Access |
|-----------|--------|
| `/agent-context/decisions/` | **READ-ONLY** → `/acp-decision` |
| `/agent-context/constraints/` | **READ-ONLY** → `/acp-constraint` |
| `/.agent/` | **VIA SKILL** → `/handoff`, `/takeover` |

### Session Workflow

| Phase | Action |
|-------|--------|
| **Start** | Read constraints/ → Read decisions/ → `/takeover` |
| **During** | `/acp-decision`, `/acp-constraint` |
| **End** | `/handoff` |

### ACP Skills

| Skill | When |
|-------|------|
| `/acp-decision` | 아키텍처 결정 |
| `/acp-constraint` | 제약 추가 |
| `/handoff` | 세션 종료 |
| `/takeover` | 세션 시작 |

### Agent Notes

- **Codex**: Auto-reads AGENTS.md
- **Claude Code**: Auto-loaded via CLAUDE.md → AGENTS.md symlink

<!-- ACP:TEMPLATE_END -->
```

---

## decisions/README.md Template

```markdown
# Architecture Decision Records (ADR)

This directory contains Architecture Decision Records for this project.

## File Naming Convention

```
YYYY-MM-DD-<slug>.md
```

## Template

```markdown
# ADR-NNN: Title

- **Date**: YYYY-MM-DD
- **Status**: proposed | accepted | deprecated | superseded
- **Deciders**: who made the decision
- **Supersedes**: previous ADR if any

## Context

What is the issue we're facing?

## Decision

What is the change we're proposing/implementing?

## Consequences

### Positive
- benefit 1

### Negative
- tradeoff 1

## References

- related links
```

## Required Fields

- Date, Status, Context, Decision, Consequences
```

---

## decisions/INDEX.md Template

```markdown
# Decisions Index

> Last updated: {YYYY-MM-DD}

## By Status

### Accepted

_None yet_

### Proposed

_None yet_

## Recent

_No decisions recorded yet_
```

---

## constraints/README.md Template

```markdown
# Project Constraints

This directory contains immutable constraints that must not be violated.

## File Naming Convention

```
<category>-<name>.md
```

Categories: security, api, code-style, architecture, other

## Template

```markdown
# Constraint: Name

- **Category**: security | api | code-style | architecture | other
- **Severity**: critical | high | medium
- **Created**: YYYY-MM-DD

## Description

Clear description of the constraint.

## Scope

- Applies to: `glob pattern`
- Excludes: `glob pattern`

## Rationale

Why does this constraint exist?

## Exceptions

When can this be bypassed?
```

## Required Fields

- Category, Severity, Description, Scope, Rationale
```

---

## constraints/INDEX.md Template

```markdown
# Constraints Index

> Last updated: {YYYY-MM-DD}

## By Severity

### Critical

_None yet_

### High

_None yet_

### Medium

_None yet_
```

---

## .gitignore Addition

```gitignore
# ACP session handoffs
.agent/
```
