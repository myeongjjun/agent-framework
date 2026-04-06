---
name: acp-constraint
version: 1.3.1
description: >
  Add or review constraints in /agent-context/constraints/ directory.
  Use to define rules that must not be violated.
trigger_phrases:
  - "add constraint"
  - "check constraints"
  - "project constraints"
  - "제약조건"
  - "제약 추가"
  - "constraint 추가"
  - "list constraints"
  - "sync constraints"
  - "constraint 동기화"
---

# ACP Constraint — Manage Project Constraints

## ACP Integration

This skill follows the ACP rules defined in AGENTS.md.

**Important:**
- Do not edit `agent-context/constraints/` directly.
- Create constraints through this skill (`/acp-constraint`) only.
- Direct edits can break context synchronization.

**Workflow:**
1. Define a non-negotiable rule.
2. Invoke the `/acp-constraint` skill.
3. Create the constraint and update `INDEX.md`.
4. If severity is `critical`, sync an inline summary to `AGENTS.md`.

## Purpose

Create and manage immutable constraints in the `/agent-context/constraints/` directory. Constraints are rules that must always be followed.

This skill is the only supported way to create constraints.

## When to Use

- Defining security requirements (no secrets in code)
- API compatibility rules (backward compatibility)
- Code style requirements (strict mode)
- Architecture boundaries (module dependencies)
- Performance requirements (latency SLOs)

## Modes

### Mode 1: List Constraints

Trigger: "check constraints", "list constraints"

List all constraints with name and severity.

### Mode 2: Add Constraint

Trigger: "add constraint"

1. **Verify ACP structure** - Check `agent-context/constraints/` directory exists
2. **Gather information** - Name, Category, Severity, Description, Scope, Rationale
3. **Generate filename** - `<category>-<name-slug>.md`
4. **Create constraint file** - Use template from [templates.md](templates.md)
5. **Update INDEX.md** - Add entry to constraints index
6. **Sync to AGENTS.md** (critical only) - if severity is `critical`:
   - Find the `<!-- ACP:CRITICAL_CONSTRAINTS -->` to `<!-- ACP:CRITICAL_CONSTRAINTS_END -->` block in `AGENTS.md`.
   - If the block is missing, create it right below `<!-- ACP:TEMPLATE_END -->`.
   - If the block exists, merge with existing items and rewrite with deduplication (idempotent).
   - Keep items sorted by filename (ascending).
   - If severity is not `critical`, skip this step.
   - Recognize both severity formats:
     - `## Severity: Critical`
     - `- **Severity**: critical`
7. **Report completion** - Show created file path (+ whether AGENTS.md sync ran)
8. **Demotion/Deletion guard** - after `critical`→`high` demotion or deletion, run Mode 3.

### Mode 3: Sync Constraints

Trigger: "sync constraints"

Scan `agent-context/constraints/` and rebuild the AGENTS.md inline block in one pass.

1. **Scan** - scan constraint files only in `agent-context/constraints/`
   - Exclude: `INDEX.md`, `README.md`
   - Include only `.md` files that contain a `# Constraint:` header
   - Recognize both severity formats (case-insensitive):
     - `## Severity: Critical`
     - `- **Severity**: critical`
2. **Rebuild block** - fully regenerate the `<!-- ACP:CRITICAL_CONSTRAINTS -->` block in `AGENTS.md`
   - Replace the full content between markers (do not append)
   - Sort items by filename (ascending)
   - Remove duplicates (by filename)
   - If generated content is identical, do not modify the file (no-op)
3. **Remove if empty** - if there are zero critical constraints, remove the block entirely
4. **Report** - report sync result (added/removed/no change)

## AGENTS.md Inline Block Format

Location: immediately after `<!-- ACP:TEMPLATE_END -->`, before `## Project Info`.

```markdown
<!-- ACP:CRITICAL_CONSTRAINTS -->
### Critical Constraints (auto-synced)

- **{Constraint Name}**: {One-line description summary} → [`{filename}`](agent-context/constraints/{filename})
<!-- ACP:CRITICAL_CONSTRAINTS_END -->
```

## Quick Reference

**Filename format:** `agent-context/constraints/<category>-<name>.md`

**Categories:** security, api, code-style, architecture, other

**Severity levels:**
| Severity | Meaning |
|----------|---------|
| `critical` | Must never be violated |
| `high` | Should not be violated |
| `medium` | Prefer to follow |

**Required fields:** Category, Severity, Description, Scope, Rationale

## Templates

For detailed constraint template, see [templates.md](templates.md).

## Notes

- Constraints are immutable rules; they should rarely change
- Use decisions (ADR) for choices; use constraints for rules
- Review constraints periodically (update `Last Verified` date)
- **Sync on deletion/demotion**: if a constraint is deleted or demoted (`critical`→`high`), remove it from the AGENTS.md inline block as well. If unsure, run Mode 3 to re-sync.
- **Scoped block update**: updates are marker-based (`<!-- ACP:CRITICAL_CONSTRAINTS -->`) and should not affect other sections.
- **Validation checklist**: verify all 4 scenarios: `critical create`, `critical→high demotion`, `critical delete`, `critical count = 0`.
