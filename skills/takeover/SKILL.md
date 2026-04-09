---
name: takeover
version: 1.2.0
description: >
  Read the latest handoff entry and recover session context for continuation.
  Supports cross-referencing with session files for additional context.
  v1.2.0: adds mandatory context load verification step (referenced files,
  git hash, ACP references, next-step prereqs) before declaring completion.
trigger_phrases:
  - "takeover"
  - "작업 인수인계"
  - "작업 결과 회수"
  - "codex가 한 일 요약"
  - "return to claude"
  - "인계 다시"
  - "작업 정리해서 돌려"
  - "continue from handoff"
output_dir: ".agent"
---

# Takeover — Session Context Reader

## ACP Integration

> 이 스킬은 AGENTS.md의 ACP 규칙을 준수합니다.

**⚠️ 중요:**
- 세션 이어받기는 반드시 이 스킬(`/takeover`)을 통해 수행
- `.agent/` 디렉터리 직접 읽기 대신 스킬 사용 권장
- `agent-context/constraints/`와 `decisions/` 자동 확인

**Workflow (AGENTS.md 기반):**
1. 세션 시작 시 `/takeover` 스킬 호출
2. `.agent/LATEST.md` → 최신 entry 자동 탐색
3. Handoff context + ACP constraints/decisions 요약 제공
4. 이전 작업 이어서 진행

## Purpose

Read handoff entries and **recover conversation context** so the receiving agent can continue work seamlessly. Default behavior is **read-only**.

**이 스킬이 세션 이어받기의 유일한 방법입니다.**

## Core Principles

1. **Read-Only by Default**: Do not create files unless explicitly requested
2. **Context Recovery**: Focus on conversation context, not just task list
3. **Cross-Reference Optional**: Can check session files for additional info

## Non-negotiable Requirements

- **Read-only by default**: Do NOT create files unless user explicitly requests
- **Project-local only**: Operate within current project path
- **Respect constraints**: Always check ACP constraints before continuing work

## When to Trigger

| Trigger | Detection |
|---------|-----------|
| Explicit | "takeover", "작업 인수인계", "continue from handoff" |
| Work return | "작업 결과 회수", "codex가 한 일 요약" |
| Session start | When `.agent/LATEST.md` exists and user wants to continue |

## Actions (Mandatory Sequence)

### 1) Find latest handoff entry

```bash
# Check for LATEST.md pointer
if [ -f ".agent/LATEST.md" ]; then
  ENTRY_FILE=$(grep -m1 '^\- \*\*Entry\*\*:' .agent/LATEST.md | sed 's/.*: //')
else
  # Fallback: find newest entry file
  ENTRY_FILE=$(ls -t .agent/entry-*.md 2>/dev/null | head -1)
fi

if [ -z "$ENTRY_FILE" ]; then
  echo "No handoff entry found in .agent/"
  exit 0
fi
```

### 2) Read and parse entry

Read the handoff entry and extract:
- **Session**: ID, Agent, Git, Trigger
- **Conversation Context**: Topic Flow, Decisions, Clarifications
- **Objective**: Goal, Done, Remaining
- **Current State**: Last action, Blockers
- **Next Steps**: Ordered list

### 3) Check ACP context (if exists)

```bash
# Check for ACP structure
if [ -d "agent-context" ]; then
  ACP_STATUS="initialized"
  CONSTRAINTS=$(ls agent-context/constraints/*.md 2>/dev/null | wc -l | tr -d ' ')
  DECISIONS=$(ls agent-context/decisions/*.md 2>/dev/null | wc -l | tr -d ' ')
else
  ACP_STATUS="not found"
  CONSTRAINTS=0
  DECISIONS=0
fi
```

### 4) Optional: Cross-reference session file

If the entry contains a session ID, try to find the original session file:

```bash
if [ -n "$SESSION_ID" ]; then
  # Search Codex sessions
  CODEX_SESSION=$(find ~/.codex/sessions -name "*$SESSION_ID*" -type f 2>/dev/null | head -1)

  # Search Claude sessions
  CLAUDE_SESSION=$(find ~/.claude/projects -name "*$SESSION_ID*" -type f 2>/dev/null | head -1)

  if [ -n "$CODEX_SESSION" ] || [ -n "$CLAUDE_SESSION" ]; then
    SESSION_FILE="${CODEX_SESSION:-$CLAUDE_SESSION}"
    # Can extract additional context from session file if needed
  fi
fi
```

### 4.5) Verify context load completeness (MANDATORY)

Before declaring takeover complete, run these deterministic checks and
include results in the response. If ANY check fails, the response MUST
open with **"⚠️ Takeover Incomplete"** and enumerate gaps BEFORE
suggesting next actions. Do not proceed to work until the user
acknowledges the gaps.

**Checks:**

1. **Key files exist** — for each file mentioned in `## Current State → Key files`,
   run `test -f` and confirm presence. Missing files = ❌.
2. **Git hash alignment** — extract the git hash from the `## Session` table
   (`| Git |` row) and compare with `git rev-parse HEAD`. Divergence is
   allowed (new commits since handoff) but MUST be reported with the
   delta (`git log <entry-hash>..HEAD --oneline`).
3. **ACP references valid** — grep `agent-context/decisions/` and
   `agent-context/constraints/` for each ADR/constraint name referenced
   in the entry. Missing reference = ❌.
4. **Next-step prereqs loaded** — if any Next Step says "read X first"
   or "re-read X before choosing", actually Read that file (first 50
   lines minimum) BEFORE claiming takeover complete. Unread prereq = ❌.
5. **Deployed artifacts present** — if the entry mentions a newly
   deployed hook/script (e.g. `hooks/general/foo.sh`), verify it exists
   at the expected path.

**Rationale**: Handoff entries are lossy summaries-of-summaries. Without
verification, the receiving agent risks shallow context — it can
paraphrase the entry without actually loading the documents the entry
depends on. This check is deterministic (file existence, grep, git
diff), not LLM-as-judge, so it adds minimal overhead.

### 5) Respond with takeover summary

**Response language**: Match the user's conversation language. If the
user communicates in Korean (default for this workspace), write the
takeover response in Korean — including section headings and narrative
text. The template below is in English for readability of this skill
file, but the agent MUST translate section titles (e.g., "Takeover
Complete" → "인수인계 완료", "Context Recovered" → "복구된 컨텍스트",
"Continue From" → "이어서 진행") when responding. Keep file paths, git
hashes, commit subjects, and identifiers verbatim.

## Takeover Response Format

```markdown
## Takeover Complete

**Entry**: {filename} ({timestamp})
**From**: {Origin Agent} → **To**: {Current Agent}

### Context Recovered

| Metric | Value |
|--------|-------|
| Topics | {N} discussion threads |
| Decisions | {N} recorded |
| Remaining | {N} tasks |
| ACP | {initialized | not found} |
| Constraints | {N} |

### Context Load Verification

| Check | Result |
|---|---|
| Key files present | ✅ / ❌ (list missing) |
| Git hash alignment | ✅ matches / ⚠️ diverged (entry: {X}, HEAD: {Y}, N new commits) |
| ACP references valid | ✅ / ❌ (list missing) |
| Next-step prereqs loaded | ✅ read / ❌ pending ({filenames}) |
| Deployed artifacts present | ✅ / ❌ |

**Overall**: ✅ Ready to continue  **OR**  ⚠️ Takeover Incomplete — gaps: {list}

### Conversation Summary

{1-2 paragraph summary of Topic Flow and key Decisions from the entry}

### Continue From

**Last action**: {what previous agent was doing}

**Immediate next step**: {first item from Next Steps}

### Open Questions

- {questions for user if any, from entry}

---

Ready to continue. Follow Next Steps from the handoff entry.
```

## Parsing the New Entry Format

### Session Table
```markdown
## Session

| Key | Value |
|-----|-------|
| ID | {uuid} |
| Agent | {agent} |
...
```

Extract using pattern matching:
```bash
SESSION_ID=$(grep -A10 '## Session' "$ENTRY_FILE" | grep '| ID |' | sed 's/.*| //' | sed 's/ |$//')
AGENT=$(grep -A10 '## Session' "$ENTRY_FILE" | grep '| Agent |' | sed 's/.*| //' | sed 's/ |$//')
```

### Conversation Context
```markdown
## Conversation Context

### Topic Flow
1. {topic}: {outcome}
...

### Decisions Made
- **{decision}**: {rationale}
...
```

### Objective
```markdown
## Objective

**Goal**: {goal}

**Done**:
- [x] ...

**Remaining**:
- [ ] ...
```

### Next Steps
```markdown
## Next Steps

1. {step 1}
2. {step 2}
...
```

## Creating a New Handoff (Only When Requested)

If user explicitly requests a new handoff entry after takeover:

1. Use the handoff skill format
2. Include reference to the previous entry in Topic Flow
3. Document any new decisions or clarifications

## Notes

- **Default is read-only**: Only summarize, don't write files
- **Session cross-reference is optional**: Provides bonus context if available
- **Quick summary first**: Give the user a quick overview before diving into details
- **Ask before acting**: If handoff entry is unclear, ask user for clarification
