# Handoff-Codex Integration Guide (v1.0.0)

## Overview

This guide explains how to integrate the **handoff** skill with **codex** skill to seamlessly transfer context between Claude Code and Codex CLI, enabling efficient agent-to-agent task delegation.

> **Format Version**: This guide uses handoff entry format v1.0.0 (6 sections).
> See `agent-context/constraints/handoff-format-v1.md` for format specification.

---

## Why Integrate Handoff with Codex?

### Problem: Context Loss
When delegating tasks from Claude Code to Codex:
- Codex CLI runs as an independent process
- No automatic access to Claude Code's conversation history, file reads, or work state
- User must manually include all context in the prompt

### Solution: Handoff Entry as Context Bridge
1. **handoff** skill captures current Claude Code context in `.agent/entry-*.md`
2. **codex** skill reads the entry file and includes it in the prompt
3. Codex receives full context and can continue work seamlessly

---

## Integration Scenarios

### Scenario 1: Claude -> Codex (Context Handoff)

**When to use:**
- Long Claude session reaching context limits
- Mechanical/bulk editing tasks better suited for Codex
- User explicitly requests "use codex with current context"

**Workflow:**
```
User Request -> handoff entry creation -> codex exec with entry content -> result
```

**Example:**
```bash
# User: "Use codex to refactor all 47 files, here's what we discussed..."

# Step 1: Create handoff entry (automatic or manual)
# Generates: .agent/entry-20251223-143022-KST.md

# Step 2: Read entry and delegate to codex
LATEST_ENTRY=$(ls -t .agent/entry-*.md | head -1)
ENTRY_CONTENT=$(cat "$LATEST_ENTRY")

codex exec -m gpt-5.4 -s workspace-write \
  -c model_reasoning_effort=xhigh \
  "Context from Claude Code:

${ENTRY_CONTENT}

Task: Refactor all 47 files as discussed. Follow Next Steps section."
```

---

### Scenario 2: Context Limit Approaching

**When to use:**
- Session > 40 messages or > 2 hours
- Response truncation observed
- User indicates "context running out"

**Workflow:**
```
Detect limit -> create handoff entry -> delegate to codex -> continue work
```

**Example:**
```bash
# Claude detects context pressure

# Step 1: Auto-generate handoff entry
# .agent/entry-20251223-150000-KST.md created with:
# - Topic Flow (conversation summary)
# - Decisions Made (including constraints)
# - Objective and Current State
# - Next Steps

# Step 2: Delegate remaining work to codex
codex exec -m gpt-5.4 -s workspace-write \
  -c model_reasoning_effort=xhigh \
  "Read .agent/entry-20251223-150000-KST.md and continue the work.
Follow Next Steps section. Respect Decisions Made strictly."
```

---

### Scenario 3: Codex -> Claude (Result Handoff)

**When to use:**
- Codex completes bulk edits
- Claude needs to review/verify results
- Next steps require Claude's judgment

**Workflow:**
```
Codex completes -> create result handoff -> Claude reads and continues
```

**Example:**
```bash
# After codex completes refactoring

# Step 1: Codex creates result handoff (v1.0.0 format)
cat > .agent/entry-20251223-152000-KST.md <<'EOF'
# Handoff - 2025-12-23 15:20 KST

## Session

| Key | Value |
|-----|-------|
| ID | N/A |
| Agent | Codex 0.80.0 |
| Project | ~/projects/myapp |
| Git | feature/refactor@b4c8d0e |
| Trigger | work_done |

## Conversation Context

> Completed bulk refactoring of userId to accountId.

### Topic Flow

1. **Rename execution**: Renamed userId -> accountId in 47 files
2. **Type updates**: Updated all TypeScript imports
3. **Verification**: Ran tsc --noEmit (passed)

### Decisions Made

- **Used find-replace**: Efficient for consistent naming
- **Preserved backward compat**: Added aliases where needed

## Objective

**Goal**: Rename userId to accountId across codebase

**Done**:
- [x] Renamed userId -> accountId in 47 files
- [x] Updated all TypeScript imports
- [x] Ran tsc --noEmit (passed)

**Remaining**:
- [ ] Code review
- [ ] Update documentation

## Current State

**Last action**: Verified with tsc --noEmit

**Key files**:
- `src/auth/`: All userId references replaced
- `src/user/`: Account model updated
- `src/api/`: API endpoints updated with new param names

## Next Steps

1. Review changes with git diff
2. Run test suite
3. Update API documentation

## Takeover

```bash
claude "Read .agent/entry-20251223-152000-KST.md and review the refactoring results."
```
EOF

# Step 2: Claude continues
# "Read .agent/entry-20251223-152000-KST.md and review the refactoring results"
```

---

## Implementation Patterns

### Pattern 1: Automatic Context Collection

**Claude collects context before delegating to Codex:**

```bash
# Function to gather current context
gather_claude_context() {
  PROJECT_ROOT=$(git rev-parse --show-toplevel 2>/dev/null || pwd)

  # Git info (optional)
  if git rev-parse --is-inside-work-tree >/dev/null 2>&1; then
    BRANCH=$(git rev-parse --abbrev-ref HEAD 2>/dev/null || echo "unknown")
    HEAD=$(git rev-parse --short HEAD 2>/dev/null || echo "unknown")
    GIT_INFO="${BRANCH}@${HEAD}"
    CHANGED=$(git diff --name-only 2>/dev/null; git diff --cached --name-only 2>/dev/null)
  else
    GIT_INFO="N/A"
    CHANGED=""
  fi

  # Construct context (v1.0.0 format)
  cat <<EOF
## Current Context from Claude Code

### Project State
- **Root**: ${PROJECT_ROOT}
- **Git**: ${GIT_INFO}
- **Changed files**:
$(echo "${CHANGED}" | sed 's/^/  - /')

### Conversation Summary
[Claude provides conversation summary here]

### Decisions Made
[Claude provides key decisions here]

### Next Steps
[Claude provides next steps here]
EOF
}

# Use in codex delegation
CONTEXT=$(gather_claude_context)
codex exec -m gpt-5.4 -s workspace-write \
  -c model_reasoning_effort=xhigh \
  "${CONTEXT}

Task: [user's request]"
```

---

### Pattern 2: Handoff Entry as Primary Context

**Use full handoff entry format for comprehensive context:**

```bash
# Step 1: Create complete handoff entry
# (Use handoff skill or manual creation following v1.0.0 format)

# Step 2: Reference entry in codex prompt
LATEST_ENTRY=$(ls -t .agent/entry-*.md | head -1)

codex exec -m gpt-5.4 -s workspace-write \
  -c model_reasoning_effort=xhigh \
  "Read the handoff entry at ${LATEST_ENTRY} and continue the work.

Follow Next Steps section in order.
Respect Decisions Made strictly (including constraints).
If unclear, make best-effort assumptions and document them in code comments.

After completion, summarize what was done and any issues encountered."
```

---

### Pattern 3: Inline Context in Prompt

**For shorter contexts, include directly in prompt:**

```bash
codex exec -m gpt-5.4 -s workspace-write \
  -c model_reasoning_effort=xhigh \
  "## Context from Claude Code

We are refactoring the authentication system:

### Decisions Made
- **Rename userId to accountId**: Aligns with domain model
- **Do not modify tests/ or __mocks__/**: Keep test isolation
- **Preserve TypeScript types**: Maintain type safety
- **Maintain API backward compatibility**: Support both params during transition

### Progress
- [x] Analyzed 47 files that need changes
- [x] Verified no breaking changes to API
- [ ] Actual refactoring (next step)

### Next Steps
1. Rename userId to accountId in src/**/*.ts
2. Update imports and type definitions
3. Run 'npx tsc --noEmit' to verify
4. Output minimal diff summary"
```

---

## Best Practices

### 1. Context Size Management

**Keep handoff entries concise (~2000 tokens):**
- Summarize conversation, don't include verbatim
- List key file paths, not full file contents
- Use bullet points and checklists
- Separate large diffs into `.diff` files

### 2. Decisions Made Include Constraints

**Always include "Do Not Change" rules in Decisions Made:**
```markdown
### Decisions Made

- **Do not modify production config files**: config/production.yml is off-limits
- **Preserve backward compatibility with v2 API**: Existing clients must work
- **Keep existing test structure**: No test refactoring in this PR
- **Do not change database schema**: Schema changes require separate migration
- **Use JWT with refresh tokens**: Security best practice, stateless
```

Codex needs these to avoid breaking changes.

### 3. Actionable Next Steps

**Make Next Steps immediately actionable:**

Bad:
```markdown
## Next Steps

1. Fix the bugs
2. Improve performance
```

Good:
```markdown
## Next Steps

1. Fix TypeError in src/auth/login.ts:42 - add null check for user.profile
   - Expected: login() handles missing profile gracefully
2. Optimize database query in src/api/users.ts:67 - add index on email field
   - Expected: user lookup < 100ms
```

### 4. Secret Redaction

**Always redact sensitive information:**
```markdown
Bad: API_KEY=your-secret-key-here
Good: API_KEY=<REDACTED>

Bad: DATABASE_URL=postgres://user:password@host/db
Good: DATABASE_URL=<REDACTED>
```

---

## Integration Checklist

When delegating from Claude to Codex with handoff:

- [ ] Session info collected (Agent, Git, Trigger)
- [ ] Current objective clearly stated
- [ ] Decisions Made documented (including constraints)
- [ ] Work completed is listed (checkboxes)
- [ ] Current state described (last action, key files)
- [ ] Next steps are ordered and actionable
- [ ] Secrets redacted
- [ ] Handoff entry saved to `.agent/entry-*.md`
- [ ] Entry content included in codex prompt or referenced by path

---

## Automation Scripts

### Helper Script: codex-with-context.sh

See `scripts/codex-with-context.sh` for a ready-to-use helper script.

Usage:
```bash
chmod +x scripts/codex-with-context.sh
./scripts/codex-with-context.sh "Implement authentication changes"
```

### Auto-Handoff Script: codex-auto-handoff.sh

See `scripts/codex-auto-handoff.sh` for automatic context collection and delegation.

Usage:
```bash
chmod +x scripts/codex-auto-handoff.sh
./scripts/codex-auto-handoff.sh "Implement JWT authentication"
```

---

## Error Handling

### Handoff Entry Not Found

```bash
LATEST_ENTRY=$(ls -t .agent/entry-*.md 2>/dev/null | head -1)

if [ -z "$LATEST_ENTRY" ]; then
  echo "No handoff entry found."
  echo "Options:"
  echo "1. Create entry manually: /handoff"
  echo "2. Proceed without context (risky)"
  echo "3. Include context inline in prompt"
  exit 1
fi
```

### Entry Too Large

```bash
ENTRY_SIZE=$(wc -c < "$LATEST_ENTRY")
MAX_SIZE=8192  # ~2000 tokens

if [ "$ENTRY_SIZE" -gt "$MAX_SIZE" ]; then
  echo "Handoff entry is too large (${ENTRY_SIZE} bytes > ${MAX_SIZE} bytes)"
  echo "Consider:"
  echo "1. Summarize the entry"
  echo "2. Move large diffs to separate .diff files"
  echo "3. Split into multiple smaller entries"
fi
```

---

## Examples

### Example 1: Bulk Refactor with Full Context

**User request:**
> "We've been discussing renaming userId to accountId for 30 messages. Use codex to do the actual refactoring across all 47 files."

**Claude's approach:**

1. **Create handoff entry** (via /handoff or manual):
```markdown
# Handoff - 2025-12-23 14:30 KST

## Session

| Key | Value |
|-----|-------|
| ID | abc-123-def |
| Agent | Claude Code 1.0.0 |
| Project | ~/projects/myapp |
| Git | feature/refactor@a3b7c9d |
| Duration | ~30 messages, started 13:00 |
| Tokens | 35000/100000 (35%) |
| Trigger | user_request |

## Conversation Context

> Discussed renaming userId to accountId for alignment with domain model.

### Topic Flow

1. **Analysis**: Identified 47 files needing changes
2. **Strategy**: Agreed on two-phase migration approach
3. **Constraints**: Established do-not-modify rules

### Decisions Made

- **Use accountId instead of userId**: Aligns with domain model (account-centric)
- **Keep backward compatibility**: Avoid breaking existing API clients
- **Two-phase migration**: Phase 1: add accountId, Phase 2: deprecate userId
- **Do not modify files in tests/ or __mocks__/**: Keep test isolation
- **Preserve all TypeScript types**: Maintain type safety

## Objective

**Goal**: Rename userId to accountId across entire codebase

**Done**:
- [x] Analyzed codebase - identified 47 files
- [x] Verified no database schema changes needed
- [x] Confirmed test coverage exists

**Remaining**:
- [ ] Execute rename in 47 files
- [ ] Update imports
- [ ] Verify with tsc and tests

## Current State

**Last action**: Completed analysis and planning

**Key files**:
- `src/auth/`: User authentication files
- `src/api/`: API endpoint handlers
- `src/models/`: Data models

## Next Steps

1. Rename userId to accountId in src/**/*.ts (exclude tests/, __mocks__/)
   - Expected: All userId references updated
2. Update all import statements
   - Expected: No import errors
3. Run 'npx tsc --noEmit' to verify type safety
   - Expected: No type errors
4. Run test suite to ensure no breakage
   - Expected: All tests pass

## Takeover

```bash
codex "Read .agent/entry-20251223-143000-KST.md and continue."
```
```

2. **Delegate to Codex:**
```bash
ENTRY_CONTENT=$(cat .agent/entry-20251223-143000-KST.md)

codex exec -m gpt-5.4 -s workspace-write \
  -c model_reasoning_effort=xhigh \
  "${ENTRY_CONTENT}

Execute the refactoring as described in Next Steps.
Follow all Decisions Made (especially constraints).
After completion, provide a summary of:
- Files modified
- Any issues encountered
- Verification results (tsc, tests)"
```

3. **Codex completes work and reports back**

4. **Claude continues** with review/next phase

---

## Troubleshooting

### Issue: Codex doesn't understand context

**Symptom**: Codex asks questions that were already discussed

**Causes**:
- Handoff entry missing key information
- Entry not included in prompt
- Entry too vague

**Solutions**:
- Review handoff entry sections (Conversation Context, Decisions Made)
- Ensure entry content is in codex prompt
- Add more specificity to Topic Flow and Next Steps

---

### Issue: Codex violates constraints

**Symptom**: Codex modifies files it shouldn't

**Causes**:
- Decisions Made missing constraints
- Constraints buried in prose instead of bullet list
- Codex prompt doesn't emphasize constraints

**Solutions**:
- Use clear bullet list in Decisions Made
- Explicitly mention constraints in codex prompt:
  ```bash
  codex exec ... "CRITICAL: Respect Decisions Made - do not modify tests/ or config files."
  ```
- Review entry format - constraints should be prominent in Decisions Made

---

### Issue: Handoff entry too large

**Symptom**: Entry file > 8KB, may exceed prompt limits

**Solutions**:
- Summarize conversation instead of full transcript
- Move diffs to separate `.diff` files
- Use references to files instead of including content
- Split complex handoffs into multiple entries

---

## Related Documentation

- **Handoff Skill**: `skills/handoff/SKILL.md` (v1.0.0)
- **Takeover Skill**: `skills/takeover/SKILL.md` (v1.0.0)
- **Format Spec**: `agent-context/constraints/handoff-format-v1.md`
- **Skill Interdependency**: `agent-context/constraints/skill-interdependency.md`

---

## Summary

**Key Takeaways:**

1. **Handoff entry = context bridge** between Claude Code and Codex
2. **Decisions Made includes constraints** to prevent breaking changes
3. **Make Next Steps actionable** for smooth delegation
4. **Use v1.0.0 (6-section) format** for all handoff entries
5. **Redact secrets** always

**Quick Reference:**
```bash
# Complete handoff -> codex workflow (v1.0.0)

# 1. Create entry (handoff skill or manual)
/handoff

# 2. Delegate to codex with context
ENTRY=$(cat $(ls -t .agent/entry-*.md | head -1))
codex exec -m gpt-5.4 -s workspace-write \
  -c model_reasoning_effort=xhigh \
  "${ENTRY}

  Task: [user's request]"

# 3. Review results and continue
# (Claude reads codex output and proceeds)
```
