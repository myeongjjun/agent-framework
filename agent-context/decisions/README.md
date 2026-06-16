# Architecture Decision Records (ADR)

This directory contains Architecture Decision Records for the Agent Framework project.

## What is an ADR?

An ADR is a document that captures an important architectural decision made along with its context and consequences.

## File Naming Convention

```
YYYY-MM-DD-<slug>.md
```

Example: `2025-01-09-adopt-acp-standard.md`

## Template

```markdown
# ADR-NNN: Title

- **Date**: YYYY-MM-DD
- **Status**: Proposed | Accepted | Rejected | Deprecated | Superseded
- **Deciders**: who made the decision
- **Supersedes**: previous ADR if any
- **Superseded by**: successor ADR if any
- **Amends**: ADR partially amended
- **Amended by**: successor that partially amended this

## Context

What is the issue we're facing? What forces are at play?

## Decision

What is the change we're proposing/implementing?

## Consequences

### Positive
- benefit 1
- benefit 2

### Negative
- tradeoff 1
- tradeoff 2

## References

- link to related decisions
- link to external resources
```

## Required Fields

- **Date**: When decision was made
- **Status**: Current status (Proposed/Accepted/Rejected/Deprecated/Superseded — AWS Well-Architected ADR convention)
- **Context**: Why this decision was needed
- **Decision**: What was decided
- **Consequences**: Impact of the decision

## Index

See [INDEX.md](INDEX.md) for a list of all decisions.
