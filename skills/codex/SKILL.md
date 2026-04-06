---
name: codex
version: 2.3.0
description: Invoke Codex CLI for complex coding tasks requiring high reasoning capabilities. Trigger phrases include "use codex", "ask codex", "run codex", "call codex", "codex cli", "GPT-5 reasoning", "OpenAI reasoning", or when users request complex implementation challenges, advanced reasoning, architecture design, or high-reasoning model assistance. Automatically triggers on codex-related requests and supports session continuation for iterative development.
---

# Codex: High-Reasoning AI Assistant for Claude Code

---

## DEFAULT MODEL: GPT-5.4 with Dynamic Reasoning Effort

**The default model for ALL Codex invocations is `gpt-5.4` with `high` reasoning effort.**

- Always use `gpt-5.4` with `-c model_reasoning_effort=high` unless task complexity dictates otherwise
- GPT-5.4 is the latest model with full support for all reasoning levels (low, medium, high, xhigh)
- Use `workspace-write` sandbox for code editing, `read-only` for analysis only

```bash
# Default invocation - ALWAYS use gpt-5.4 with high reasoning, MCP disabled
codex exec -m gpt-5.4 -s workspace-write \
  -c model_reasoning_effort=high \
  "your prompt here"
```

### Reasoning Effort Selection

Choose the reasoning effort level based on task complexity:

| Effort | Task Type | Examples |
|--------|-----------|----------|
| `low` | Trivial text edits, formatting | Typo fix, comment change, whitespace |
| `medium` | Routine code changes | File rename, simple function edit, config update |
| `high` | Complex implementation (default) | New feature, refactoring, multi-file changes |
| `xhigh` | Architecture-level work | Design decisions, complex algorithms, system design |

**Guidelines**:
- Default to `high` when unsure about complexity.
- Use `xhigh` only when deep reasoning is required (architecture, algorithms, design trade-offs).
- Use `low` or `medium` for mechanical, repetitive tasks to reduce latency and cost.

### MCP Servers

MCP is **disabled by default in `~/.codex/config.toml`** to avoid startup latency (see [ADR-019](../../agent-context/decisions/2026-03-05-codex-mcp-less-execution.md)).

Codex does not need MCP directly. If external data is needed (Jira, Wiki, Calendar, etc.), the orchestrator (Claude) fetches it and includes it in the Codex prompt.

Verification: logs should show `mcp startup: no servers` for default invocations.

---

## Codex Invocation Modes

Detect dispatch mode before invoking Codex:

```bash
if command -v cmux &>/dev/null && command -v zmx &>/dev/null && cmux ping &>/dev/null; then
  DISPATCH_MODE="cmux"   # interactive codex via cmux+zmx
else
  DISPATCH_MODE="exec"   # codex exec (non-interactive fallback)
fi
```

### Mode A: cmux+zmx dispatch (recommended when available)

Run interactive codex in a cmux split pane, controlled via `cmux send`. Session persists via zmx.

**Prerequisites:**
- cmux with socket control mode set to "자동화 모드"
- zmx installed and in PATH
- Verify: `cmux ping` returns PONG

```bash
# 1. Create cmux split pane
SURFACE=$(cmux new-split right 2>&1 | awk '{print $2}')

# 2. Start zmx session + codex
cmux send --surface $SURFACE "zmx attach codex-{task} codex --full-auto -C $(pwd)\n"

# 3. Wait for codex ready
while ! cmux read-screen --surface $SURFACE --lines 5 2>/dev/null | grep -q "gpt-5"; do sleep 5; done

# 4. Send prompt
cmux send --surface $SURFACE "prompt text"
cmux send-key --surface $SURFACE enter

# 5. Cleanup when done
cmux close-surface --surface $SURFACE
zmx kill codex-{task}
```

**Advantages**: Session persistence, real-time observation, context retention across prompts.

### Mode B: codex exec fallback (no cmux/zmx)

**MUST USE** `codex exec` when cmux is unavailable. Claude Code's bash environment is non-terminal.

**Preconditions (verify before dispatch):**
1. Default model: `grep '^model' ~/.codex/config.toml` — use this model. Do NOT hardcode `-m`.
2. Trust: `grep '{repo-name}' ~/.codex/config.toml` — must show `trust_level = "trusted"`.
3. No pipe: do NOT append `| tail`, `| head`, or any pipe to `codex exec`.

```bash
codex exec -s workspace-write \
  -c model_reasoning_effort=high \
  "prompt"
```

**Never use** bare `codex` (interactive mode) without cmux — will fail with "stdout is not a terminal".

---

## IMPORTANT: Interactive vs Exec Mode Flags

**Some Codex CLI flags are ONLY available in interactive mode, NOT in `codex exec`.**

| Flag | Interactive `codex` | `codex exec` | Alternative for exec |
|------|---------------------|--------------|---------------------|
| `--search` | ✅ Available | ❌ NOT available | `--enable web_search_request` |
| `-a/--ask-for-approval` | ✅ Available | ❌ NOT available | `--full-auto` or `-c approval_policy=...` |
| `--add-dir` | ✅ Available | ✅ Available | N/A |
| `--full-auto` | ✅ Available | ✅ Available | N/A |

**For web search in exec mode**:
```bash
# CORRECT - works in codex exec
codex exec --enable web_search_request "research topic"

# WRONG - --search only works in interactive mode
codex --search "research topic"
```

**For approval control in exec mode**:
```bash
# CORRECT - works in codex exec
codex exec --full-auto "task"
codex exec -c approval_policy=on-request "task"

# WRONG - -a only works in interactive mode
codex -a on-request "task"
```

---

## EXECUTION WORKFLOW: Full Cycle (Required)

**When this skill is invoked for implementation tasks, Claude MUST execute the following steps in order:**

### Step 1: Handoff (Before Codex)

**Invoke the `/handoff` skill** to preserve current context:

```
/handoff
```

This will:
- Create `.agent/entry-{timestamp}-KST.md` with v1.0.0 format
- Update `.agent/LATEST.md`
- Capture current conversation context, decisions, objective

### Step 2: Invoke Codex with Full Cycle Prompt

After handoff completes, invoke Codex using the detected dispatch mode:

**cmux+zmx mode:**
```bash
SURFACE=$(cmux new-split right 2>&1 | awk '{print $2}')
cmux send --surface $SURFACE "zmx attach codex-fullcycle codex --full-auto -C $(pwd)\n"
# Wait for codex ready
while ! cmux read-screen --surface $SURFACE --lines 5 2>/dev/null | grep -q "gpt-5"; do sleep 5; done
# Send the full cycle prompt
cmux send --surface $SURFACE "## Context
Read .agent/LATEST.md for full context from Claude Code.
## Task
{USER_REQUEST}
## Required Actions
1. Read the handoff entry and understand the objective and decisions
2. Complete the task
3. Create handoff entry when done (.agent/entry-{timestamp}-KST.md)
Report what was done and any issues encountered."
cmux send-key --surface $SURFACE enter
```

**exec fallback:**
```bash
codex exec -s workspace-write \
  -c model_reasoning_effort=high \
  "## Context
Read .agent/LATEST.md for full context from Claude Code.

## Task
{USER_REQUEST}

## Required Actions
1. Read the handoff entry and understand:
   - Objective and remaining tasks
   - Decisions Made (these are constraints - MUST respect)

2. Complete the task

3. **CRITICAL: Create handoff entry when done**
   - File: .agent/entry-{YYYYMMDD}-{HHMMSS}-KST.md
   - Update: .agent/LATEST.md
   - Format: v1.0.0 (6 sections)
   - Trigger: work_done

Report what was done and any issues encountered."
```

### Step 3: Takeover (After Codex)

**Invoke the `/takeover` skill** to retrieve Codex's results:

```
/takeover
```

This will:
- Read `.agent/LATEST.md` to find Codex's result entry
- Parse the result entry
- Provide context for reporting to user

### Step 4: Report to User

After takeover, report to user:
- What Codex accomplished (from Objective → Done)
- Any issues encountered (from Current State → Blockers)
- Suggested next steps (from Next Steps)

---

### When to Use Full Cycle

**Use Full Cycle (automatic)** when:
- User requests Codex for implementation work
- Context preservation is important
- User wants results reported back

**Skip Full Cycle** when:
- Simple, one-off query to Codex (e.g., "codex, what is X?")
- User explicitly says "just run codex" without context
- Read-only analysis that doesn't need handoff

---

## When Codex Delegation Beats Claude

This section clarifies **when delegating to Codex provides a real advantage**, using the **Control Plane / Execution Plane** model.

### The Control Plane / Execution Plane Model

| Role | Agent | Responsibility |
|------|-------|----------------|
| **Control Plane** | Claude | Decide, plan, judge, reason about tradeoffs |
| **Execution Plane** | Codex | Implement, edit, transform, produce diffs |

Use Claude for **decisions**, Codex for **execution**.

### Codex Excels At (High ROI Delegation)

Delegate to Codex when the remaining work is **execution-heavy** and **mechanical**, rather than decision-heavy.

**Best-fit task types:**

| Task Type | Examples |
|-----------|----------|
| Large-scale mechanical changes | bulk refactors, repetitive edits, signature updates, mass rename, import rewrites |
| Patch/Diff-first output | PR-ready diffs, minimal prose, "just change the code" |
| Automation-friendly tasks | CI-oriented edits, "try/rollback" style iterations, scripted modifications |
| Repo-wide transformations | applying a consistent transformation across many files |

**Why this works:**
- Codex spends tokens on **code output** rather than conversational explanation
- For repetitive edits, Codex produces cleaner patches with less "discussion overhead"

### Claude Excels At (Do NOT Delegate)

Do **not** delegate to Codex when the work requires **judgment, tradeoffs, or long-form reasoning**.

**Examples:**
- Architectural decision-making
- Comparing design options with constraints
- Ambiguous bug triage that needs hypothesis + reasoning
- Product/behavior interpretation and policy choices

**Exception:** If architectural decision is already made and documented, Codex can implement even complex logic—just provide a detailed spec in the delegation prompt.

---

## Session Overflow Delegation Strategy

When Claude conversation is getting long, delegation can provide a net win **only if** the remaining work is mostly mechanical.

### Delegation Trigger Heuristics

Prefer Codex delegation when any of these are true:

| Signal | Indicator |
|--------|-----------|
| Long conversation | Many back-and-forth exchanges in current session |
| Response degradation | Claude responses show truncation or simplification |
| User indication | User explicitly mentions token/session concerns |
| Mechanical task | "edit N files", "rename X across repo", "apply same change everywhere" |
| Output preference | User asks for "PR-ready diff", "just implement", "don't explain" |
| Plan is stable | Decision/architecture is already established |

### Recommended Workflow (Phase Split)

**Phase 1 (Claude): Decide and Specify**
- Define the goal
- List constraints (files, conventions, "do not change" rules)
- Provide acceptance criteria (tests, behavior, diff size expectations)

**Phase 2 (Codex): Execute**
- Perform code edits
- Produce patch/diff
- Run tests/build steps if available

This preserves Claude tokens for **decision-making** and uses Codex for **hands-on work**.

### Fallback Strategy

If Codex delegation fails or produces unexpected results:

1. Review Codex output with `codex exec resume --last`
2. Claude analyzes and identifies issues
3. Re-delegate with refined constraints and explicit corrections
4. If repeated failures, Claude takes over implementation directly

---

## Handoff Integration — Context Bridge to Codex (v1.0.0)

### Overview

When delegating work from Claude Code to Codex CLI, context loss is a common problem. Codex runs as an independent process with no automatic access to:
- Claude Code's conversation history
- Files read during the session
- Current work state and decisions made
- Todo lists and progress tracking

**Solution**: Use the **handoff** skill to create a structured context entry (`.agent/entry-*.md`), then include this entry in the Codex prompt.

### When to Use Handoff Integration

| Scenario | Description |
|----------|-------------|
| **Long session delegation** | Claude session > 40 messages or context pressure observed |
| **Context preservation** | User says "use codex with current context" or "handoff to codex" |
| **Mechanical bulk edits** | Large-scale refactoring better suited for Codex execution |
| **Limit approaching** | Session approaching usage limits, need to preserve work |

### Quick Start: Handoff → Codex Workflow

**Step 1: Create handoff entry** (manual or via /handoff skill)
```bash
# Via handoff skill (recommended)
/handoff

# Or manually create .agent/entry-YYYYMMDD-HHMMSS-KST.md
# following the handoff entry format v1.0.0
```

**Step 2: Delegate to Codex with context**
```bash
# Read the latest entry
LATEST_ENTRY=$(ls -t .agent/entry-*.md 2>/dev/null | head -1)
ENTRY_CONTENT=$(cat "$LATEST_ENTRY")

# Delegate with full context
codex exec -m gpt-5.4 -s workspace-write \
  -c model_reasoning_effort=xhigh \
  "Context from Claude Code:

${ENTRY_CONTENT}

---

Task: [specific task to execute]

Follow Next Steps section from the context.
Respect Decisions Made in Conversation Context strictly.
After completion, summarize results."
```

**Step 3: Review and continue**
- Codex completes work with full context
- Claude reviews results and continues next phase

### Handoff Entry Format v1.0.0 (6 Sections)

When creating a handoff entry for Codex, ensure these sections are complete:

**Session** (table)
- Agent info, Project path, Git status, Trigger reason

**Conversation Context**
- Topic Flow: conversation progression
- Decisions Made: technical decisions and rationale (constraints included here)
- Clarifications: user clarifications

**Objective**
- Goal: one-sentence primary objective
- Done: completed items with checkboxes
- Remaining: pending items

**Current State**
- Last action, Blockers, Key files

**Next Steps**
- Ordered, actionable steps
- Expected outcomes for each step
- **This is what Codex will execute**

**Takeover**
- Commands to continue with Claude or Codex

### Example: Long Session with Context Handoff

**Situation**: 50-message session about authentication refactoring, now need to implement changes

**Claude creates handoff entry** (v1.0.0 format):
```markdown
# Handoff — 2025-12-23 14:30 KST

## Session

| Key | Value |
|-----|-------|
| ID | abc-123-def |
| Agent | Claude Code 1.0.0 |
| Project | /home/user/myapp |
| Git | feature/auth@a3b7c9d |
| Duration | ~50 messages, started 12:00 |
| Tokens | 45000/100000 (45%) |
| Trigger | user_request |

## Conversation Context

> Authentication system refactoring discussion and implementation planning.

### Topic Flow

1. **Auth requirements**: Discussed JWT vs session-based auth
2. **Token strategy**: Decided on access + refresh token approach
3. **Implementation plan**: Outlined file changes needed

### Decisions Made

- **JWT with refresh tokens**: Security best practice, stateless
- **15min access token TTL**: Balance security vs UX
- **Redis for token storage**: Fast, supports TTL natively
- **Do not modify production config**: config/production.yml is off-limits
- **Keep API v2 backward compatible**: Existing clients must work

## Objective

**Goal**: Implement JWT authentication with refresh token rotation

**Done**:
- [x] Analyzed existing auth code
- [x] Designed token flow

**Remaining**:
- [ ] Implement JWT signing
- [ ] Add refresh token logic
- [ ] Update login endpoint

## Current State

**Last action**: Completed implementation design

**Key files**:
- `src/auth/jwt.ts`: needs implementation
- `src/auth/refresh.ts`: needs creation
- `src/api/login.ts`: needs token response update

## Next Steps

1. Implement JWT signing in src/auth/jwt.ts
   - Expected: generateToken() and verifyToken() functions
2. Add refresh token logic in src/auth/refresh.ts
   - Expected: Refresh endpoint with token rotation
3. Update login endpoint to return both tokens
4. Run `npm run build && npm test -- auth && npx tsc --noEmit`

## Takeover

\`\`\`bash
codex "Read .agent/entry-20251223-143000-KST.md and continue."
\`\`\`
```

**Delegate to Codex**:
```bash
ENTRY=$(cat .agent/entry-20251223-143000-KST.md)

codex exec -m gpt-5.4 -s workspace-write \
  -c model_reasoning_effort=xhigh \
  "${ENTRY}

Implement the authentication changes from Next Steps.
CRITICAL: Respect all decisions in Conversation Context (especially constraints).
After implementation, run verification commands and report results."
```

### Context Collection Best Practices

**What to include in handoff entry:**
- ✅ Session info (Agent, Git status, Trigger)
- ✅ Clear objective and definition of done
- ✅ **Decisions Made** (includes constraints - what NOT to change)
- ✅ Work completed (checkboxes)
- ✅ Ordered next steps with expected outcomes

**What to exclude (keep entry concise):**
- ❌ Verbatim conversation transcripts
- ❌ Full file contents (use file paths instead)
- ❌ Large diffs (separate into .diff files)
- ❌ Secrets, API keys, tokens (redact!)

**Target size**: ~2000 tokens (~8KB)

### Integration Patterns

**Pattern 1: Auto-include latest handoff entry**
```bash
# Check for latest entry
LATEST_ENTRY=$(ls -t .agent/entry-*.md 2>/dev/null | head -1)

if [ -n "$LATEST_ENTRY" ]; then
  echo "Found handoff entry: $LATEST_ENTRY"
  CONTEXT=$(cat "$LATEST_ENTRY")

  codex exec -m gpt-5.4 -s workspace-write \
    -c model_reasoning_effort=xhigh \
    "${CONTEXT}

    Task: ${USER_REQUEST}"
else
  echo "No handoff entry found. Proceeding without context."
  codex exec -m gpt-5.4 -s workspace-write \
    -c model_reasoning_effort=xhigh \
    "${USER_REQUEST}"
fi
```

**Pattern 2: Reference entry by path**
```bash
# Instead of inlining full content, reference the file
LATEST_ENTRY=$(ls -t .agent/entry-*.md | head -1)

codex exec -m gpt-5.4 -s workspace-write \
  -c model_reasoning_effort=xhigh \
  "Read the handoff entry at ${LATEST_ENTRY} for full context.

Task: Implement the Next Steps from the entry.
Respect Decisions Made strictly."
```

**Pattern 3: Helper script** (recommended for frequent use)

See `scripts/codex-with-context.sh` for a ready-to-use helper script.

### Bi-directional Handoff: Codex → Claude

After Codex completes work, create a result handoff entry for Claude to continue:

```bash
# Codex creates result entry (v1.0.0 format)
cat > .agent/entry-20251223-152000-KST.md <<'EOF'
# Handoff — 2025-12-23 15:20 KST

## Session

| Key | Value |
|-----|-------|
| ID | N/A |
| Agent | Codex 0.80.0 |
| Project | /home/user/myapp |
| Git | feature/auth@b4c8d0e |
| Trigger | work_done |

## Conversation Context

> Completed JWT authentication implementation.

### Topic Flow

1. **JWT implementation**: Created signing and verification functions
2. **Refresh tokens**: Implemented rotation with Redis
3. **Verification**: All tests passing

### Decisions Made

- **Used jose library**: Modern JWT implementation
- **Token rotation on refresh**: Security best practice

## Objective

**Goal**: Implement JWT authentication with refresh token rotation

**Done**:
- [x] Implemented JWT signing (src/auth/jwt.ts)
- [x] Added refresh token logic (src/auth/refresh.ts)
- [x] Updated login endpoint
- [x] All tests passing

**Remaining**:
- [ ] Security review
- [ ] API documentation update

## Current State

**Last action**: Verified with npm test

**Key files**:
- `src/auth/jwt.ts`: generateToken(), verifyToken() implemented
- `src/auth/refresh.ts`: Token rotation with Redis storage
- `src/api/login.ts`: Returns access + refresh tokens

## Next Steps

1. Review implementation for security issues
2. Update API documentation
3. Deploy to staging

## Takeover

\`\`\`bash
claude "Read .agent/entry-20251223-152000-KST.md and review the implementation."
\`\`\`
EOF
```

### Troubleshooting

**Issue**: Codex doesn't respect constraints
- **Fix**: Make Decisions Made section explicit and include constraints there
- **Fix**: Emphasize in delegation prompt: "CRITICAL: Respect Decisions Made"

**Issue**: Codex asks questions already discussed
- **Fix**: Ensure Conversation Context has complete Topic Flow
- **Fix**: Add key decisions to Decisions Made section

**Issue**: Handoff entry too large
- **Fix**: Summarize conversation instead of full transcript
- **Fix**: Reference files by path, don't include full contents
- **Fix**: Move diffs to separate .diff files

**Issue**: No handoff entry exists
- **Fix**: Create one manually or use /handoff skill
- **Fix**: For simple tasks, skip handoff and include context inline

### Quick Reference

```bash
# Complete handoff → codex workflow (v1.0.0)

# 1. Create handoff entry
/handoff  # creates .agent/entry-*.md

# 2. Delegate to codex
ENTRY=$(cat $(ls -t .agent/entry-*.md | head -1))
codex exec -m gpt-5.4 -s workspace-write \
  -c model_reasoning_effort=xhigh \
  "${ENTRY}

  Task: [user request]"

# 3. Review results
# Read Codex output, continue next phase
```

### Additional Resources

For comprehensive integration guide:
- See `references/handoff-integration.md` - Complete integration patterns, examples, automation scripts
- See `handoff/SKILL.md` - Handoff entry format specification (v1.0.0)
- See `references/session-workflows.md` - Session continuation patterns

---

## Full Cycle Workflow

### Overview

Full Cycle은 Claude와 Codex 간의 완전한 context 전달 흐름입니다:

```
Claude(handoff) → Codex(takeover→작업→handoff) → Claude(takeover→보고)
```

### When to Use Full Cycle

- 복잡한 구현 작업을 Codex에 위임할 때
- Context 보존이 중요한 작업
- 결과를 Claude가 검토해야 할 때

### Workflow Diagram

```
┌─────────────────────────────────────────────────────────────┐
│ User: "codex로 검색 기능 구현해줘"                            │
└─────────────────────────────────────────────────────────────┘
                              │
                              ▼
┌─────────────────────────────────────────────────────────────┐
│ Phase 1: Claude Handoff                                     │
│ - 현재 세션 context를 .agent/entry-*.md에 저장               │
│ - Topic Flow, Decisions, Objective 포함                     │
└─────────────────────────────────────────────────────────────┘
                              │
                              ▼
┌─────────────────────────────────────────────────────────────┐
│ Phase 2: Codex Invocation                                   │
│ codex "                                                     │
│   1. Read .agent/LATEST.md → takeover context               │
│   2. 검색 기능 구현                                          │
│   3. 완료 후 .agent/entry-*.md에 handoff 작성                │
│ "                                                           │
└─────────────────────────────────────────────────────────────┘
                              │
                              ▼
┌─────────────────────────────────────────────────────────────┐
│ Phase 3: Claude Takeover                                    │
│ - .agent/LATEST.md 읽어서 Codex 결과 확인                    │
│ - 사용자에게 결과 보고                                       │
└─────────────────────────────────────────────────────────────┘
```

### Codex Prompt Template for Full Cycle

```markdown
## Context
Read `.agent/LATEST.md` to understand the current work context.

## Task
{user_task}

## Instructions
1. First, read the handoff entry and understand:
   - Objective and remaining tasks
   - Decisions already made
   - Constraints to respect (in Decisions Made)

2. Complete the task

3. When finished, create a handoff entry:
   - File: `.agent/entry-{YYYYMMDD}-{HHMMSS}-KST.md`
   - Update: `.agent/LATEST.md`
   - Format: Use the 6-section v1.0.0 format

## Handoff Format (v1.0.0)
Use the structure defined in agent-context/constraints/handoff-format-v1.md
```

### Example Full Cycle Invocation

```bash
# User: "codex로 검색 API 구현해줘"

# Claude creates handoff, then invokes:
codex exec -m gpt-5.4 -s workspace-write \
  -c model_reasoning_effort=xhigh \
  "Read .agent/LATEST.md for context.

Implement search API as described in Next Steps.

IMPORTANT:
- Respect all Decisions Made (including constraints)
- When done, create handoff entry in .agent/entry-{timestamp}-KST.md
- Update .agent/LATEST.md to point to your entry
- Use v1.0.0 (6-section) format for the handoff entry

Report what was done and any issues encountered."
```

### Related Constraints

See `agent-context/constraints/skill-interdependency.md` for dependency rules between handoff, takeover, and codex skills.

---

## Practical Delegation Prompts

### 1) Mechanical Bulk Edit

```
Use Codex to apply this change repo-wide:
- Goal: <describe change>
- Constraints: <do not break API X, preserve formatting, keep behavior>
- Acceptance: <tests pass, lint clean, minimal diff>
```

### 2) Patch-First Output

```
Use Codex to produce a clean diff only:
- No long explanation
- Output should be PR-ready
- Include a short summary of changed files
```

### 3) Long Session Delegation

```
Session is getting long. Use Codex to implement exactly:
- Plan: <bullet list steps>
- Files: <paths>
- Do not change: <list>
- Verify: <commands/tests>
```

### 4) Example: Bulk Rename Refactor

**Situation:** Need to rename `userId` → `accountId` across 47 files in src/

**Claude (Phase 1) establishes:**
> Plan: rename userId to accountId in src/, exclude tests/, preserve type safety, run tsc after

**Delegate (Phase 2):**
```bash
codex exec -m gpt-5.4 -s workspace-write \
  -c model_reasoning_effort=high \
  "Rename userId to accountId in all files under src/. 
   Do not modify files in tests/ or __mocks__/. 
   Preserve TypeScript types and update all imports.
   Output as minimal diff. Run 'npx tsc --noEmit' to verify."
```

---

## Trigger Examples

This skill activates when users say phrases like:
- "Use codex to analyze this architecture"
- "Ask codex about this design decision"
- "Run codex on this problem"
- "Call codex for help with this implementation"
- "I need GPT-5 reasoning for this task"
- "Get OpenAI's high-reasoning model on this"
- "Continue with codex" or "Resume the codex session"
- "Codex, help me with..." or simply "Codex"

## When to Use This Skill

This skill should be invoked when:
- User explicitly mentions "Codex" or requests Codex assistance
- User needs help with complex coding tasks, algorithms, or architecture
- User requests "high reasoning" or "advanced implementation" help
- User needs complex problem-solving or architectural design
- User wants to continue a previous Codex conversation

## How It Works

### Detecting New Codex Requests

When a user makes a request that falls into one of the above categories, determine the task type:

**General Tasks** (architecture, design, reviews, explanations):
- Use model: `gpt-5.1` (high-reasoning general model)
- Example requests: "Design a queue data structure", "Review this architecture", "Explain this algorithm"

**Code Editing Tasks** (file modifications, implementation):
- Use model: `gpt-5.4` (latest model with maximum capability)
- Example requests: "Edit this file to add feature X", "Implement the function", "Refactor this code"

### Bash CLI Command Structure

**IMPORTANT**: Always use `codex exec` for non-interactive execution. Claude Code's bash environment is non-terminal, so the interactive `codex` command will fail with "stdout is not a terminal" error.

#### For Code Editing Tasks (Default)

```bash
codex exec -m gpt-5.4 -s workspace-write \
  -c model_reasoning_effort=xhigh \
  --enable web_search_request \
  "<user's prompt>"
```

#### For Read-Only Analysis Tasks

```bash
codex exec -m gpt-5.4 -s read-only \
  -c model_reasoning_effort=xhigh \
  --enable web_search_request \
  "<user's prompt>"
```

**Why `codex exec`?**
- Non-interactive mode required for automation and Claude Code integration
- Produces clean output suitable for parsing
- Works in non-TTY environments (like Claude Code's bash)

### Model Selection Logic

**Use `gpt-5.1` (default) when:**
- Designing architecture or data structures
- Reviewing code for quality, security, or performance
- Explaining concepts or algorithms
- Planning implementation strategies
- General problem-solving and reasoning

**Use `gpt-5.4` when:**
- Editing or modifying existing code files
- Implementing specific functions or features
- Refactoring code
- Writing new code with file I/O
- Any task requiring `workspace-write` sandbox
- Complex code editing requiring maximum reasoning capability
- Tasks requiring the latest model capabilities

**Note**: `gpt-5.1-codex-max` and `gpt-5.1-codex` are still available for backward compatibility. Use `gpt-5.4` as the default for latest capabilities.

### Default Configuration

All Codex invocations use these defaults unless user specifies otherwise:

| Parameter | Default Value | CLI Flag | Notes |
|-----------|---------------|----------|-------|
| Model | `gpt-5.4` | `-m gpt-5.4` | Default for ALL tasks (latest model) |
| Sandbox | `workspace-write` | `-s workspace-write` | Allows file modifications (default) |
| Sandbox (analysis) | `read-only` | `-s read-only` | For read-only analysis tasks |
| Reasoning Effort | `high` | `-c model_reasoning_effort=high` | Default for complex implementation work |
| Verbosity | `medium` | `-c model_verbosity=medium` | Balanced output detail |
| Web Search | `enabled` | `--enable web_search_request` | Access to up-to-date information |

### CLI Flags Reference

**Codex CLI Version**: 0.71.0+ (requires 0.71.0+ for latest features)

| Flag | Values | Description |
|------|--------|-------------|
| `-m, --model` | `gpt-5.4`, `gpt-5.1`, `gpt-5.1-codex`, `gpt-5.1-codex-max` | Model selection |
| `-s, --sandbox` | `read-only`, `workspace-write`, `danger-full-access` | Sandbox mode |
| `-c, --config` | `key=value` | Config overrides (e.g., `model_reasoning_effort=high`) |
| `-C, --cd` | directory path | Working directory |
| `-p, --profile` | profile name | Use config profile |
| `--enable` | feature name | Enable a feature (e.g., `web_search_request`) |
| `--disable` | feature name | Disable a feature |
| `-i, --image` | file path(s) | Attach image(s) to initial prompt |
| `--add-dir` | directory path | Additional writable directory (repeatable) |
| `--full-auto` | flag | Convenience for workspace-write sandbox with on-request approval |
| `--oss` | flag | Use local open source model provider |
| `--local-provider` | `lmstudio`, `ollama` | Specify local provider (with --oss) |
| `--skip-git-repo-check` | flag | Allow running outside Git repository |
| `--output-schema` | file path | JSON Schema file for response shape |
| `--color` | `always`, `never`, `auto` | Color settings for output |
| `--json` | flag | Print events as JSONL |
| `-o, --output-last-message` | file path | Save last message to file |
| `--dangerously-bypass-approvals-and-sandbox` | flag | Skip confirmations (DANGEROUS) |

### Configuration Parameters

Pass these as `-c key=value`:

- `model_reasoning_effort`: `minimal`, `low`, `medium`, `high`, `xhigh`
  - **CLI default**: `high` - The Codex CLI defaults to high reasoning
  - **Skill default**: `high` - Default when task complexity is unclear
  - **`xhigh`**: Extra-high reasoning for architecture-level work (supported by gpt-5.4)
  - Use `xhigh` for design decisions, complex algorithms, or system design where quality is more important than speed
- `model_verbosity`: `low`, `medium`, `high` (default: `medium`)
- `model_reasoning_summary`: `auto`, `concise`, `detailed`, `none` (default: `auto`)
- `sandbox_workspace_write.writable_roots`: JSON array of additional writable directories (e.g., `["/path1","/path2"]`)
- `approval_policy`: `untrusted`, `on-failure`, `on-request`, `never` (approval behavior)

**Additional Writable Directories**:

Use `--add-dir` flag (preferred) or config:
```bash
# Preferred - simpler syntax (v0.71.0+)
codex exec --add-dir /path1 --add-dir /path2 "task"

# Alternative - config approach
codex exec -c 'sandbox_workspace_write.writable_roots=["/path1","/path2"]' "task"
```

### Model Selection Guide

**Default Models (Codex CLI v0.71.0+)**

This skill supports the following models:
- `gpt-5.4` - Latest model with all reasoning levels (NEW in 0.71.0)
- `gpt-5.1` - General reasoning, architecture, reviews (default)
- `gpt-5.1-codex-max` - Code editing (legacy, use gpt-5.4 instead)
- `gpt-5.1-codex` - Standard code editing (available for backward compatibility)

**GPT-5.4 Model (NEW)**:
- Supports all reasoning effort levels: `low`, `medium`, `high`, `xhigh`
- Use for cutting-edge tasks requiring latest model capabilities
- Example: `codex exec -m gpt-5.4 -c model_reasoning_effort=xhigh "complex task"`

**Performance Characteristics**:
- `gpt-5.1-codex-max` is 27-42% faster than `gpt-5.1-codex`
- Uses ~30% fewer thinking tokens at the same reasoning effort level
- Supports new `xhigh` reasoning effort for maximum capability
- Requires Codex CLI 0.71.0+ and ChatGPT Plus/Pro/Business/Edu/Enterprise subscription

**Backward Compatibility**

You can override to use older models when needed:

```bash
# Use older gpt-5 model explicitly
codex exec -m gpt-5 -s read-only "Design a data structure"

# Use older gpt-5-codex model explicitly
codex exec -m gpt-5-codex -s workspace-write "Implement feature X"
```

**When to Override**

- **Testing compatibility**: Verify behavior matches older model versions
- **Specific model requirements**: Project requires specific model version
- **Model comparison**: Compare outputs between model versions

**Model Override Examples**

Override via `-m` flag:
```bash
# Override to gpt-5 for general task
codex exec -m gpt-5 "Explain algorithm complexity"

# Override to gpt-5-codex for code task
codex exec -m gpt-5-codex -s workspace-write "Refactor authentication"

# Override to gpt-4 if available
codex exec -m gpt-4 "Review this code"
```

**Default Behavior**

Without explicit `-m` override:
- All tasks → `gpt-5.4` (latest model, recommended default)
- General reasoning → `gpt-5.1` (if explicitly requested)
- Backward compatibility → `gpt-5.1-codex-max` and `gpt-5.1-codex` still work if explicitly specified

## Session Continuation

### Detecting Continuation Requests

When user indicates they want to continue a previous Codex conversation:
- Keywords: "continue", "resume", "keep going", "add to that"
- Follow-up context referencing previous Codex work
- Explicit request like "continue where we left off"

### Resuming Sessions

For continuation requests, use the `codex resume` command:

#### Resume Most Recent Session (Recommended)

```bash
codex exec resume --last
```

This automatically continues the most recent Codex session with all previous context maintained.

#### Resume Specific Session

```bash
codex exec resume <session-id>
```

Resume a specific session by providing its UUID. Get session IDs from previous Codex output or by running `codex exec resume --last` to see the most recent session.

**Note**: The interactive session picker (`codex resume` without arguments) is NOT available in non-interactive/Claude Code environments. Always use `--last` or provide explicit session ID.

### Decision Logic: New vs. Continue

**Use `codex exec -m ... "<prompt>"`** when:
- User makes a new, independent request
- No reference to previous Codex work
- User explicitly wants a "fresh" or "new" session

**Use `codex exec resume --last`** when:
- User indicates continuation ("continue", "resume", "add to that")
- Follow-up question building on previous Codex conversation
- Iterative development on same task

### Session History Management

- Codex CLI automatically saves session history
- No manual session ID tracking needed
- Sessions persist across Claude Code restarts
- Use `codex exec resume --last` to access most recent session
- Use `codex exec resume <session-id>` for specific sessions

## Error Handling

### Simple Error Response Strategy

When errors occur, return clear, actionable messages without complex diagnostics:

**Error Message Format:**
```
Error: [Clear description of what went wrong]

To fix: [Concrete remediation action]

[Optional: Specific command example]
```

### Common Errors

#### Command Not Found

```
Error: Codex CLI not found

To fix: Install Codex CLI and ensure it's available in your PATH

Check installation: codex --version
```

#### Authentication Required

```
Error: Not authenticated with Codex

To fix: Run 'codex login' to authenticate

After authentication, try your request again.
```

#### Invalid Configuration

```
Error: Invalid model specified

To fix: Use 'gpt-5.4' for all tasks (recommended) or 'gpt-5.1' for general reasoning

Example: codex exec -m gpt-5.4 "your prompt here"
Example: codex exec -m gpt-5.4 -s workspace-write "code editing task"
```

### Troubleshooting

**First Steps for Any Issues:**
1. Check Codex CLI built-in help: `codex --help`, `codex exec --help`, `codex exec resume --help`
2. Consult official documentation: [https://github.com/openai/codex/tree/main/docs](https://github.com/openai/codex/tree/main/docs)
3. Verify skill resources in `references/` directory

**Skill not being invoked?**
- Check that request matches trigger keywords (Codex, complex coding, high reasoning, etc.)
- Explicitly mention "Codex" in your request
- Try: "Use Codex to help me with..."

**Session not resuming?**
- Verify you have a previous Codex session (check command output for session IDs)
- Try: `codex exec resume --last` to resume most recent session
- If no history exists, start a new session first

**"stdout is not a terminal" error?**
- Always use `codex exec` instead of plain `codex` in Claude Code
- Claude Code's bash environment is non-interactive/non-terminal

**Errors during execution?**
- Codex CLI errors are passed through directly
- Check Codex CLI logs for detailed diagnostics
- Verify working directory permissions if using workspace-write
- Check official Codex docs for latest updates and known issues

## Examples

### Example 1: Architecture Design Task

**User Request**: "Help me design a binary search tree architecture in Rust"

**Skill Executes**:
```bash
codex exec -m gpt-5.4 -s read-only \
  -c model_reasoning_effort=xhigh \
  "Help me design a binary search tree architecture in Rust"
```

**Result**: Codex provides maximum reasoning architectural guidance using gpt-5.4 with xhigh reasoning. Session automatically saved for continuation.

---

### Example 2: Code Editing Task

**User Request**: "Edit this file to implement the BST insert method"

**Skill Executes**:
```bash
codex exec -m gpt-5.4 -s workspace-write \
  -c model_reasoning_effort=xhigh \
  "Edit this file to implement the BST insert method"
```

**Result**: Codex uses gpt-5.4 with xhigh reasoning and workspace-write permissions to modify files.

---

### Example 3: Session Continuation

**User Request**: "Continue with the BST - add a deletion method"

**Skill Executes**:
```bash
codex exec resume --last
```

**Result**: Codex resumes the previous BST session and continues with deletion method implementation, maintaining full context.

---

### Example 4: With Web Search

**User Request**: "Use Codex with web search to research and implement async patterns"

**Skill Executes**:
```bash
codex exec -m gpt-5.4 -s workspace-write \
  -c model_reasoning_effort=xhigh \
  --enable web_search_request \
  "Research and implement async patterns"
```

**Result**: Codex uses web search capability for latest information, then implements with gpt-5.4 xhigh reasoning.

---

### Example 5: Complex Architectural Refactoring

**User Request**: "Perform complex architectural refactoring of authentication system"

**Skill Executes**:
```bash
codex exec -m gpt-5.4 -s workspace-write \
  -c model_reasoning_effort=xhigh \
  "Perform complex architectural refactoring of authentication system"
```

**Result**: Codex uses gpt-5.4 with xhigh reasoning effort for maximum capability on complex long-horizon tasks. Ideal for architectural refactoring where quality is critical.

---

### Example 6: Delegated Bulk Refactor (Long Session)

**Situation**: Claude session has been long, user needs to rename `userId` → `accountId` across 47 files

**Claude (Phase 1) Response**:
> I'll delegate this mechanical refactor to Codex. The plan:
> - Rename userId to accountId in all src/ files
> - Exclude tests/ and __mocks__/
> - Preserve TypeScript types
> - Verify with tsc

**Skill Executes (Phase 2)**:
```bash
codex exec -m gpt-5.4 -s workspace-write \
  -c model_reasoning_effort=high \
  "Rename userId to accountId in all files under src/. 
   Do not modify files in tests/ or __mocks__/. 
   Preserve TypeScript types and update all imports.
   Output as minimal diff. Run 'npx tsc --noEmit' to verify."
```

**Result**: Codex performs the bulk rename efficiently, preserving Claude's tokens for decision-making.

---

## Code Review Subcommand (v0.71.0+)

The `codex review` subcommand provides non-interactive code review capabilities:

```bash
# Review uncommitted changes (staged, unstaged, untracked)
codex review --uncommitted

# Review changes against a base branch
codex review --base main

# Review a specific commit
codex review --commit abc123

# Review with custom instructions
codex review --uncommitted "Focus on security vulnerabilities"

# Non-interactive via exec
codex exec review --uncommitted
```

**Review Options**:
| Flag | Description |
|------|-------------|
| `--uncommitted` | Review staged, unstaged, and untracked changes |
| `--base <BRANCH>` | Review changes against the given base branch |
| `--commit <SHA>` | Review the changes introduced by a commit |
| `--title <TITLE>` | Optional commit title for review summary |

---

## CLI Features Reference

### Feature Flags (`--enable` / `--disable`)
Enable or disable specific Codex features:
```bash
codex exec --enable web_search_request "Research latest patterns"
codex exec --disable some_feature "Run without feature"
```

### Image Attachment (`-i, --image`)
Attach images to prompts for visual analysis:
```bash
codex exec -i screenshot.png "Analyze this UI design"
codex exec -i diagram1.png -i diagram2.png "Compare these architectures"
```

### Additional Directories (`--add-dir`) (v0.71.0+)
Add writable directories beyond the primary workspace:
```bash
codex exec --add-dir /shared/libs --add-dir /config "task"
```

### Full Auto Mode (`--full-auto`)
Convenience flag for low-friction execution:
```bash
codex exec --full-auto "task"
# Equivalent to: -s workspace-write with on-request approval
```

### Non-Git Environments (`--skip-git-repo-check`)
Run Codex outside Git repositories:
```bash
codex exec --skip-git-repo-check "Help with this script"
```

### Structured Output (`--output-schema`)
Define JSON schema for model responses:
```bash
codex exec --output-schema schema.json "Generate structured data"
```

### Output Coloring (`--color`)
Control colored output (always, never, auto):
```bash
codex exec --color never "Run in CI/CD pipeline"
```

### Web Search in Exec Mode
**Note**: `--search` flag is interactive-only. Use `--enable` for exec mode:
```bash
# CORRECT for codex exec
codex exec --enable web_search_request "research topic"

# WRONG - --search only works in interactive mode
codex --search "research topic"
```

### Feature Flags (`codex features list`) (v0.71.0+)
Inspect and manage Codex feature flags:
```bash
# List all feature flags with their states
codex features list
```

**Current Feature Flags** (as of v0.71.0):

**Stable Features**:
| Feature | Default | Description |
|---------|---------|-------------|
| `web_search_request` | false | Enable web search capability |
| `parallel` | true | Parallel execution |
| `shell_tool` | true | Shell command execution |
| `undo` | true | Undo functionality |
| `view_image_tool` | true | Image viewing capability |
| `warnings` | true | Display warnings |

**Experimental/Beta Features**:
| Feature | Stage | Default | Description |
|---------|-------|---------|-------------|
| `exec_policy` | experimental | true | Execution policy control |
| `remote_compaction` | experimental | true | Remote compaction |
| `unified_exec` | experimental | false | Unified execution mode |
| `rmcp_client` | experimental | false | RMCP client support |
| `apply_patch_freeform` | beta | false | Freeform patch application |
| `skills` | experimental | false | Skills support |
| `shell_snapshot` | experimental | false | Shell state snapshots |
| `remote_models` | experimental | false | Remote model support |

Enable/disable features with `--enable` and `--disable`:
```bash
codex exec --enable web_search_request "research task"
codex exec --disable parallel "run sequentially"
```

### JSONL Output (`--json`) (v0.71.0+)
Stream events as JSONL for programmatic processing:
```bash
codex exec --json "task" > events.jsonl
```

### Save Last Message (`-o/--output-last-message`) (v0.71.0+)
Write the final agent message to a file:
```bash
codex exec -o result.txt "generate summary"
```

---

## When to Use GPT-5.4 vs GPT-5.1

### Use GPT-5.4 (Latest Model) For:
- Cutting-edge tasks requiring latest capabilities
- Complex reasoning with all effort levels (low to xhigh)
- When you want the newest model improvements
- Tasks where latest training data matters

```bash
codex exec -m gpt-5.4 -c model_reasoning_effort=xhigh "complex task"
```

---

## When to Use GPT-5.1 vs GPT-5.1-Codex-Max

### Use GPT-5.1 (General High-Reasoning) For:
- Architecture and system design
- Code reviews and quality analysis
- Security audits and vulnerability assessment
- Performance optimization strategies
- Algorithm design and analysis
- Explaining complex concepts
- Planning and strategy

### Use GPT-5.1-Codex-Max (Maximum Code Capability) For:
- Editing existing code files (27-42% faster than standard codex)
- Implementing specific features
- Refactoring and code transformations
- Writing new code with file I/O
- Code generation tasks
- Debugging and fixes requiring file changes
- Complex architectural refactoring (with `xhigh` reasoning effort)

### Use GPT-5.1-Codex (Standard Code Model) For:
- Backward compatibility scenarios
- When you need to replicate behavior from earlier versions
- Explicit requirement to use the standard (non-max) model

**Default**: Use `gpt-5.4` for all tasks (latest model with best capabilities). Use `gpt-5.1` if you specifically need the older general model, or `gpt-5.1-codex-max` for backward compatibility.

## Best Practices

### 1. Use Descriptive Requests

**Good**: "Help me implement a thread-safe queue with priority support in Python"
**Vague**: "Code help"

Clear, specific requests get better results from high-reasoning models.

### 2. Indicate Continuation Clearly

**Good**: "Continue with that queue implementation - add unit tests"
**Unclear**: "Add tests" (might start new session)

Explicit continuation keywords help the skill choose the right command.

### 3. Specify Permissions When Needed

**Good**: "Refactor this code (allow file writing)"
**Risky**: Assuming permissions without specifying

Make your intent clear when you need workspace-write permissions.

### 4. Leverage High Reasoning

The skill defaults to high reasoning effort - perfect for:
- Complex algorithms
- Architecture design
- Performance optimization
- Security reviews

### 5. Use Delegation for Mechanical Tasks

When conversation is long, delegate execution-heavy work:
- Bulk refactors → Codex
- Mass renames → Codex
- Repetitive edits → Codex
- Design decisions → Keep in Claude

## Platform & Capabilities (v0.71.0)

### Windows Sandbox Support
Windows sandbox is available for filesystem and network access control.

### Interactive Mode Features
The `/exit` slash-command alias is available in interactive `codex` mode (not applicable to `codex exec` non-interactive mode used by this skill).

### Model Verbosity Override
All models (gpt-5.4, gpt-5.1-codex-max, gpt-5.1-codex) support verbosity override via `-c model_verbosity=<level>` for controlling output detail levels.

### Local/OSS Model Support
Use `--oss` with `--local-provider` to use local LLM providers:
```bash
codex exec --oss --local-provider ollama "task"
codex exec --oss --local-provider lmstudio "task"
```

## Pattern References

For command construction examples and workflow patterns, Claude can reference:
- `references/command-patterns.md` - Common codex exec usage patterns
- `references/session-workflows.md` - Session continuation and resume workflows
- `references/advanced-patterns.md` - Complex configuration and flag combinations

These files provide detailed examples for constructing valid codex exec commands for various scenarios.

## Additional Resources

For more details, see:
- `references/codex-help.md` - Codex CLI command reference
- `references/codex-config.md` - Full configuration options
- `README.md` - Installation and quick start guide
