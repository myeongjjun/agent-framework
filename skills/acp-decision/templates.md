# ACP Decision Templates

## ADR Template (Full)

```markdown
# ADR-{NNN}: {TITLE}

- **Date**: {YYYY-MM-DD}
- **Status**: accepted
- **Deciders**: {WHO_DECIDED}
- **Supersedes**: {PREVIOUS_ADR_OR_NONE}

## Context

{CONTEXT_DESCRIPTION}

What is the issue we're facing? What forces are at play?
Include relevant background, constraints, and requirements.

## Decision

{DECISION_DESCRIPTION}

What is the change we're proposing/implementing?
Be specific and unambiguous.

## Alternatives Considered

| Alternative | Pros | Cons |
|-------------|------|------|
| {alt1} | {pros} | {cons} |
| {alt2} | {pros} | {cons} |

## Consequences

### Positive
- {BENEFIT_1}
- {BENEFIT_2}

### Negative
- {TRADEOFF_1}
- {TRADEOFF_2}

### Neutral
- {SIDE_EFFECT}

## Implementation Notes

{IMPLEMENTATION_GUIDANCE_IF_ANY}

## References

- {RELATED_LINKS}
- [Related ADR](./YYYY-MM-DD-related.md)
```

---

## ADR Template (Minimal)

```markdown
# ADR-{NNN}: {TITLE}

- **Date**: {YYYY-MM-DD}
- **Status**: accepted

## Context

{Why this decision was needed}

## Decision

{What was decided}

## Consequences

- {Impact 1}
- {Impact 2}
```

---

## INDEX.md Entry Format

Add to `decisions/INDEX.md`:

```markdown
| [{NNN}]({FILENAME}) | {DATE} | {TITLE} |
```

Example:
```markdown
| [001](2025-01-09-use-postgresql.md) | 2025-01-09 | Use PostgreSQL for user data |
```

---

## Status Transitions

```
proposed → accepted → deprecated
                   → superseded (by ADR-XXX)
```

When superseding:
1. Update old ADR: `Status: superseded`
2. Add to old ADR: `Superseded by: ADR-XXX`
3. New ADR references: `Supersedes: ADR-YYY`
