# ACP Constraint Templates

## Constraint Template (Full)

```markdown
# Constraint: {NAME}

- **Category**: {CATEGORY}
- **Severity**: {SEVERITY}
- **Created**: {YYYY-MM-DD}
- **Last Verified**: {YYYY-MM-DD}

## Description

{CLEAR_DESCRIPTION}

Clear, unambiguous description of the constraint.
One sentence that can be used as a rule check.

## Scope

- **Applies to**: `{GLOB_PATTERN}`
- **Excludes**: `{GLOB_PATTERN_OR_NONE}`

## Rationale

{WHY_THIS_CONSTRAINT_EXISTS}

Why does this constraint exist? What problem does it prevent?
Link to incidents or issues if relevant.

## Verification

{HOW_TO_CHECK_COMPLIANCE}

```bash
# Automated check (if available)
{VERIFICATION_COMMAND}
```

Manual review checklist:
- [ ] Check item 1
- [ ] Check item 2

## Exceptions

{WHEN_CAN_BE_BYPASSED}

- **Never**: This constraint has no exceptions
- **With approval**: Requires sign-off from {role}
- **Temporarily**: During {specific situation}

## Examples

### Allowed

```{LANG}
{COMPLIANT_EXAMPLE}
```

### Not Allowed

```{LANG}
{NON_COMPLIANT_EXAMPLE}
```
```

---

## Constraint Template (Minimal)

```markdown
# Constraint: {NAME}

- **Category**: {CATEGORY}
- **Severity**: {SEVERITY}
- **Created**: {YYYY-MM-DD}

## Description

{What the constraint is}

## Scope

- Applies to: `{glob pattern}`

## Rationale

{Why it exists}
```

---

## INDEX.md Entry Format

Add to `constraints/INDEX.md` under appropriate severity:

```markdown
| [{NAME}]({FILENAME}) | {CATEGORY} | `{SCOPE}` |
```

Example:
```markdown
### Critical

| Constraint | Category | Scope |
|------------|----------|-------|
| [No Secrets in Code](security-no-secrets.md) | security | `src/**` |
```

---

## Common Constraint Examples

### Security: No Secrets in Code

```markdown
# Constraint: No Secrets in Code

- **Category**: security
- **Severity**: critical
- **Created**: 2025-01-09

## Description

No API keys, tokens, passwords, or secrets in source code.

## Scope

- Applies to: `**/*.{ts,js,py,go,java}`
- Excludes: `**/*.example`, `**/*.template`

## Rationale

Secrets in code get committed to version control and exposed.

## Verification

```bash
grep -rE "(api_key|password|secret|token)\s*=" src/ && echo "FAIL" || echo "PASS"
```

## Exceptions

None. Use environment variables or secret managers.
```

### API: Backward Compatibility

```markdown
# Constraint: API Backward Compatibility

- **Category**: api
- **Severity**: critical
- **Created**: 2025-01-09

## Description

Public API endpoints must maintain backward compatibility.

## Scope

- Applies to: `src/api/**/*.ts`
- Excludes: `src/api/internal/**`

## Rationale

Breaking changes affect downstream consumers.

## Verification

- [ ] No removed endpoints
- [ ] No changed response structure
- [ ] Deprecation before removal

## Exceptions

With approval: New major version release.
```
