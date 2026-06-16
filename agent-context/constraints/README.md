# Project Constraints

This directory contains immutable constraints that must not be violated.

## What is a Constraint?

A constraint is a rule that must always be followed. Unlike decisions (which explain why), constraints define hard boundaries.

## File Naming Convention

```
<category>-<name>.md
```

Categories:
- `security-*` - Security constraints
- `api-*` - API/interface constraints
- `code-*` - Code style constraints
- `architecture-*` - Architecture constraints

Example: `security-no-secrets-in-code.md`

## Template

```markdown
# Constraint: Name

- **Status**: Active | Deprecated | Superseded
- **Category**: security | api | code-style | architecture | other
- **Severity**: critical | high | medium
- **Created**: YYYY-MM-DD
- **Last Verified**: YYYY-MM-DD

## Description

Clear, unambiguous description of the constraint.

## Scope

What files/areas does this constraint apply to?

- Applies to: `glob pattern`
- Excludes: `glob pattern`

## Rationale

Why does this constraint exist?

## Verification

How to check if constraint is being followed.

## Exceptions

When can this constraint be bypassed? Who approves?
```

## Required Fields

- **Category**: Type of constraint
- **Severity**: How critical (critical/high/medium)
- **Description**: What the constraint is
- **Scope**: Where it applies
- **Rationale**: Why it exists

## Index

See [INDEX.md](INDEX.md) for a list of all constraints.
