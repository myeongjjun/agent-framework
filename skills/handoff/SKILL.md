---
name: handoff
version: 1.3.0
description: >
  Create a session-focused handoff entry under .agent/entry-*.md when handing work
  to another agent or when context is near limit. Captures conversation context,
  not just project state.
  v1.3.0: surfaces optional session rotation (compress current session's RAM by
  spawning a fresh claude that takes over via /takeover) — see ## Rotation and
  ~/.claude/scripts/handoff-rotate.sh.
trigger_phrases:
  - "handoff"
  - "인계"
  - "정리하고 넘겨"
  - "마지막으로 정리"
  - "limit near"
  - "context limit"
  - "토큰 얼마 안 남"
  - "컨텍스트 한계"
output_dir: ".agent"
entry_filename_pattern: "entry-{YYYYMMDD}-{HHMMSS}-KST.md"
max_entry_size: "~2000 tokens (approx 8KB)"
---

# Handoff — Session Context Writer

## ACP Integration

> 이 스킬은 AGENTS.md의 ACP 규칙을 준수합니다.

**⚠️ 중요:**
- `.agent/` 디렉터리 직접 수정 금지
- 반드시 이 스킬(`/handoff`)을 통해 세션 인계
- 직접 수정 시 context 동기화 깨짐

**Workflow (AGENTS.md 기반):**
1. 세션 종료 또는 컨텍스트 한계
2. `/handoff` 스킬 호출
3. `.agent/entry-*.md` 자동 생성 및 `LATEST.md` 업데이트
4. 다음 agent가 `/takeover`로 이어받기

## Purpose

Create a concise, **conversation-focused** handoff entry so another agent can continue the work with full context of what was discussed, decided, and planned.

**이 스킬이 세션 인계의 유일한 방법입니다.**

## Core Principles

1. **Conversation Context > Project State**: 대화 맥락이 핵심
2. **Git is Optional**: 있으면 bonus, 없어도 동작
3. **Session Metadata from Files**: Agent 요약 + 세션 파일에서 정확한 수치
4. **Compact Format**: 6개 섹션으로 단순화

## Non-negotiable Requirements

- **Project-local only**: Always write under the **current project path**
- **One handoff = one new file**: `.agent/entry-*.md`
- **Never overwrite** existing entry files
- **No secrets**: Replace API keys, tokens, passwords with `<REDACTED>`
- **Concise**: Keep entry under ~2000 tokens

## When to Trigger

| Trigger | Detection |
|---------|-----------|
| User request | "handoff", "인계", "정리하고 넘겨", etc. |
| Limit near | Response truncation observed, or session > 40 messages |
| Long session | > 2 hours elapsed, execution-heavy remaining work |
| Usage hard-limit | `/usage` shows 100% or "You've hit your limit" |
| Usage early-warning | `/usage` shows >= 80% used |
| Long prompt count | Session exceeds 50 prompts — agent should proactively suggest /handoff |

**Proactive suggestion rule**: When the session reaches 50+ prompts, the agent should proactively suggest running `/handoff` to the user. This is a suggestion, not automatic execution. At 80+ prompts, the suggestion should become more prominent. The agent should mention the current prompt count and the potential for context degradation.

## Actions (Mandatory Sequence)

### 1) Identify current session

```bash
# Detect agent type and find session file
if [ -n "$CODEX_HOME" ] || command -v codex &>/dev/null; then
  AGENT_TYPE="Codex"
  CODEX_SESSION_DIR="$HOME/.codex/sessions/$(date +%Y/%m/%d)"
  SESSION_FILE=$(ls -t "$CODEX_SESSION_DIR"/rollout-*.jsonl 2>/dev/null | head -1)
  if [ -n "$SESSION_FILE" ]; then
    SESSION_ID=$(head -1 "$SESSION_FILE" | jq -r '.payload.id // empty')
    SESSION_START=$(head -1 "$SESSION_FILE" | jq -r '.payload.timestamp // empty')
    GIT_BRANCH=$(head -1 "$SESSION_FILE" | jq -r '.payload.git.branch // empty')
    GIT_SHA=$(head -1 "$SESSION_FILE" | jq -r '.payload.git.commit_hash // empty' | cut -c1-7)
    CLI_VERSION=$(head -1 "$SESSION_FILE" | jq -r '.payload.cli_version // empty')
    # Get token info from last token_count event
    TOKEN_INFO=$(grep '"type":"token_count"' "$SESSION_FILE" | tail -1 | jq -r '.payload.info // empty')
  fi
else
  AGENT_TYPE="Claude Code"
  PROJECT_ENCODED=$(echo "$PWD" | tr '/' '-' | sed 's/^-//')
  CLAUDE_SESSION_DIR="$HOME/.claude/projects/$PROJECT_ENCODED"
  SESSION_FILE=$(ls -t "$CLAUDE_SESSION_DIR"/*.jsonl 2>/dev/null | head -1)
  if [ -n "$SESSION_FILE" ]; then
    SESSION_ID=$(basename "$SESSION_FILE" .jsonl)
    # Claude stores version in messages
    CLI_VERSION=$(grep -m1 '"version"' "$SESSION_FILE" 2>/dev/null | jq -r '.version // empty')
    GIT_BRANCH=$(grep -m1 '"gitBranch"' "$SESSION_FILE" 2>/dev/null | jq -r '.gitBranch // empty')
  fi
fi
```

### 2) Gather context (Git optional)

```bash
# Git info - optional, with graceful fallback
GIT_BRANCH=${GIT_BRANCH:-$(git rev-parse --abbrev-ref HEAD 2>/dev/null || echo "")}
GIT_SHA=${GIT_SHA:-$(git rev-parse --short HEAD 2>/dev/null || echo "")}

# Format git info
if [ -n "$GIT_BRANCH" ] && [ -n "$GIT_SHA" ]; then
  GIT_INFO="${GIT_BRANCH}@${GIT_SHA}"
else
  GIT_INFO="N/A"
fi
```

### 3) Create entry file

```bash
mkdir -p .agent
TIMESTAMP=$(TZ=Asia/Seoul date +%Y%m%d-%H%M%S)
ENTRY_FILE=".agent/entry-${TIMESTAMP}-KST.md"

# Handle collision
if [ -f "$ENTRY_FILE" ]; then
  ENTRY_FILE=".agent/entry-${TIMESTAMP}-KST-$(printf '%02d' $RANDOM).md"
fi
```

### 4) Update LATEST.md pointer

Create/overwrite `.agent/LATEST.md`:

```markdown
# Latest Handoff

- **Entry**: {entry filename}
- **Time**: {YYYY-MM-DD HH:MM KST}
- **From**: {Agent type and version}
- **Objective**: {one-liner}
- **Next**: {immediate next step}
```

## Handoff Entry Format (6 Sections)

```markdown
# Handoff — {YYYY-MM-DD HH:MM} KST

## Session

| Key | Value |
|-----|-------|
| ID | {session_uuid or "N/A"} |
| Agent | {Claude Code X.X.X | Codex X.X.X} |
| Project | {cwd} |
| Git | {branch}@{sha} or N/A |
| Duration | ~{N} messages, started {HH:MM} |
| Tokens | {used}/{limit} ({percent}%) or N/A |
| Trigger | {user_request | limit_near | work_done} |

## Conversation Context

> Agent가 직접 요약한 이 세션의 대화 흐름

### Topic Flow

1. {topic 1}: {what was discussed, outcome}
2. {topic 2}: {what was discussed, outcome}
3. {topic 3}: {current focus}

### Decisions Made

- **{decision}**: {rationale}

### Clarifications

- {user clarification that shaped the work}

## Objective

**Goal**: {one sentence describing what we're trying to achieve}

**Done**:
- [x] {completed item}

**Remaining**:
- [ ] {remaining item}

## Current State

**Last action**: {what was being done before handoff}

**Blockers** (if any):
- {blocker description}

**Key files**:
- `{path}`: {state/changes}

## Next Steps

1. {step 1 - specific, actionable}
   - Expected: {what success looks like}
2. {step 2}
3. {step 3}

## Takeover

```bash
# For Claude Code
claude "Read .agent/{ENTRY_FILE} and continue. Follow Next Steps section."

# For Codex
codex "Read .agent/{ENTRY_FILE} and continue. Follow Next Steps section."
```

## Next Action Options

After this entry is written, you have two ways forward:

| Option | When | Command |
|---|---|---|
| **A. Defer** | Just close session, or keep working in current context | (nothing — exit naturally, next agent runs `/takeover`) |
| **B. Rotate** | Compress this session's RAM by spawning fresh Y in same zmx | `~/.claude/scripts/handoff-rotate.sh` |

See `## Rotation` in SKILL.md for the empirical workflow and caveats.
```

## Section Guidelines

### Session (from session file)
- **ID**: Extract from session file, or "N/A" if unavailable
- **Agent**: Include version (e.g., "Claude Code 2.1.7", "Codex 0.79.0")
- **Git**: Format as `branch@sha` or "N/A" - no detailed status needed
- **Tokens**: If available from session file, include usage percentage

### Conversation Context (agent summarizes)
- **Topic Flow**: 3-5 key topics discussed in this session, in order
- **Decisions Made**: Important decisions with brief rationale
- **Clarifications**: User clarifications that affected understanding

### Objective
- **Goal**: One clear sentence
- **Done/Remaining**: Checklist format, keep brief

### Current State
- **Last action**: What you were doing right before handoff
- **Blockers**: Only if there are actual blockers
- **Key files**: 2-3 most relevant files with brief state description

### Next Steps
- **Ordered**: Most important first
- **Specific**: Actionable without external context
- **Expected outcome**: Optional but helpful for complex steps

### Takeover
- Ready-to-run commands for both Claude and Codex

## Rotation (Optional follow-up to /handoff)

After writing the entry, the user has **two ways forward**:

1. **Defer**: just keep working in this session, or close it. Next agent
   runs `/takeover` whenever they want.
2. **Rotate** (RAM compression): kill the current heavy claude and spawn
   a fresh one in the same zmx that immediately runs `/takeover`. Use
   when this session's context is bloated and the remaining work doesn't
   need the full history.

### Why rotation exists

Handoff entries are designed to be **lossy summaries** (~2000 tokens).
A heavy session may carry 200k+ tokens of internal state. After
`/handoff`, all the load-bearing context is in the entry file. The
rest is dead weight slowing down future turns.

Rotation lets you keep the **canonical zmx name** (`claude-<project>`)
without rename gymnastics, while archiving the heavy session as a
lossless `.jsonl` file you can `claude --resume <uuid>` later.

### Rotation flow (Option 2 — semi-auto, validated 2026-04-07)

```
t=0  /handoff writes .agent/entry-*.md   ← you are here
t=1  ~/.claude/scripts/handoff-rotate.sh           ← orchestrator launches
t=2  orchestrator: kill -QUIT <orig_pid> ← original claude exits
t=3  orchestrator: cmux send "zmx attach <name> claude" ← fresh Y starts
t=4  orchestrator: cmux send "/takeover" ← Y loads handoff entry
t=5  user verifies Y, then: zmx kill <tmp-name>
```

**Critical empirical findings (do NOT regress):**
- ❌ `cmux send-key 'ctrl+\'` does NOT trigger SIGQUIT (key injection
  bypasses tty driver). Use `kill -QUIT <pid>` directly.
- ✅ `claude --continue` brief co-ownership of a session file (~30s) is
  safe — no jsonl corruption observed.
- ✅ The original zmx session ends when its root command (`claude`)
  exits — but the same zmx name can be reattached immediately:
  `zmx attach <same-name> claude`.

### When to use rotation
- Long sessions (>50 messages) where remaining work is small
- Just before tackling a fresh subtask that needs minimal prior context
- Token usage approaching 80% but you're not done with the work

### When NOT to use rotation
- Session is short (<20 messages) — overhead not worth it
- You need to reference recent dialog turns the entry doesn't capture
- You're about to `/exit` anyway

### References
- Proposal + empirical results: `.collab/handoff-rotate-proposal.md`
- Script: `~/.claude/scripts/handoff-rotate.sh`
- Related: ADR-026 (handoff rotation orchestrator pattern)

## Notes

- **Early warning**: At 80% usage, start drafting but don't write until triggered
- **No secrets**: Always redact API keys, tokens, passwords
- **Compact**: Prefer tables and bullet points over prose
- **Rotation is optional**: Never auto-rotate. Always surface it as a
  choice in the response. The user must decide.
