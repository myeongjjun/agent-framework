---
name: acp-decision
version: 1.2.0
description: >
  Record an architectural decision to /agent-context/decisions/ directory.
  Use when a significant technical decision has been made that future agents need to know.
trigger_phrases:
  - "record decision"
  - "ADR"
  - "architectural decision"
  - "결정 기록"
  - "아키텍처 결정"
  - "의사결정 기록"
  - "add decision"
---

# ACP Decision — Record Architectural Decisions

## ACP Integration

This skill follows the ACP rules in AGENTS.md.

**Important:**
- The agent MUST NOT edit `agent-context/decisions/` directly.
- The agent MUST create an ADR through this skill (`/acp-decision`).
- A direct edit breaks context synchronization.

**Workflow:**
1. An architectural decision comes up during the session.
2. Invoke the `/acp-decision` skill.
3. The skill creates the ADR and updates `INDEX.md`.

## Purpose

Create an Architecture Decision Record (ADR) in the `/agent-context/decisions/` directory so future agents understand why certain choices were made.

**This skill is the only way to create an ADR.**

## When to Use

- A significant technical decision was made
- Choosing between multiple valid approaches
- Establishing a pattern or convention
- Deprecating or changing a previous decision

## Actions

1. **Verify ACP structure** - Check `agent-context/decisions/` directory exists
2. **Gather information** - Title, Context, Decision, Alternatives, Consequences
3. **Generate filename** - `YYYY-MM-DD-<slug>.md`
4. **Determine ADR number** - Increment from last ADR
5. **Create decision file** - Use template from [templates.md](templates.md)
6. **Update INDEX.md** - Add entry to decisions index
7. **Report completion** - Show created file path

## Quick Reference

**Filename format:** `agent-context/decisions/YYYY-MM-DD-<slug>.md`

**Status values:**
| Status | Meaning |
|--------|---------|
| `proposed` | Under discussion |
| `accepted` | Decided and in effect |
| `deprecated` | No longer recommended |
| `superseded` | Replaced by another ADR |

**Required fields:** Date, Status, Context, Decision, Consequences

## Templates

For detailed ADR template, see [templates.md](templates.md).

## Notes

- Default status is `accepted` (most decisions recorded after being made)
- When superseding, update old ADR's status and link to new one
- Keep decisions concise but complete
