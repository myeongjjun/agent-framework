# Constraint: Handoff Entry Format v1.0.0

## Status: Active
## Severity: High
## Scope: All agents (Claude Code, Codex, etc.)

## Rule

모든 agent는 handoff entry 생성 시 **v1.0.0 (6섹션) 포맷**을 사용해야 합니다.

## Required Sections

| Section | Required | Description |
|---------|----------|-------------|
| Session | Yes | 테이블: ID, Agent, Project, Git, Duration, Tokens, Trigger |
| Conversation Context | Yes | Topic Flow, Decisions Made, Clarifications |
| Objective | Yes | Goal, Done, Remaining |
| Current State | Yes | Last action, Blockers, Key files |
| Next Steps | Yes | Ordered, actionable steps |
| Takeover | Yes | Agent 실행 명령어 |

## Entry Template

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

> {one-line summary}

### Topic Flow

1. **{topic}**: {outcome}
2. **{topic}**: {outcome}

### Decisions Made

- **{decision}**: {rationale}

### Clarifications

- {clarification from user}

## Objective

**Goal**: {one sentence}

**Done**:
- [x] {completed item}

**Remaining**:
- [ ] {remaining item}

## Current State

**Last action**: {action}

**Blockers**:
- {blocker or "None"}

**Key files**:
- `{path}`: {state}

## Next Steps

1. {step}
   - Expected: {outcome}
2. {step}
   - Expected: {outcome}

## Takeover

```bash
# For Claude Code
claude "Read .agent/{ENTRY_FILE} and continue. Follow Next Steps section."

# For Codex
codex "Read .agent/{ENTRY_FILE} and continue. Follow Next Steps section."
```
```

## Format Rules

1. **Session 테이블**: Markdown 테이블 형식, Git은 `branch@sha` 또는 `N/A`
2. **Conversation Context**: 반드시 Topic Flow 포함
3. **Next Steps**: 번호 매긴 리스트, 구체적이고 실행 가능하게
4. **Takeover**: Claude와 Codex 모두를 위한 명령어 포함

## Directory Structure

```
.agent/
├── LATEST.md              # 최신 entry 포인터
└── entry-{YYYYMMDD}-{HHMMSS}-KST.md  # Handoff entries
```

## Prohibited

- **구버전 12섹션 포맷 사용 금지**
- **"section 3", "section 8" 등 번호 참조 금지**
- **Git 필수 가정 금지** (Git은 optional)
- **`.ai/` 디렉터리 사용 금지** (`.agent/` 사용)

## Cross-Agent Compatibility

- Claude가 생성한 entry를 Codex가 파싱 가능해야 함
- Codex가 생성한 entry를 Claude가 파싱 가능해야 함
- Agent 버전 정보는 Session 테이블에 포함

## Migration from v0.2.0

| Old (v0.2.0) | New (v1.0.0) |
|--------------|--------------|
| Section 0: Why this handoff | Session 테이블 (Trigger 포함) |
| Section 1: Project snapshot | Session 테이블 (Git, Project) |
| Section 2: Current objective | Objective |
| Section 3: Constraints | Conversation Context → Decisions Made |
| Section 4: Decisions already made | Conversation Context → Decisions Made |
| Section 5: Work completed | Objective → Done |
| Section 6: In-progress | Current State |
| Section 7: Open questions | Conversation Context → Clarifications |
| Section 8: Next steps | Next Steps |
| Section 9: Commands to run | Next Steps (명령어 포함) |
| Section 10: Conversation tail | Conversation Context → Topic Flow |
| Section 11: Agent takeover | Takeover |
| Section 12: Validation checklist | (제거됨) |

## References

- skills/handoff/SKILL.md (v1.0.0)
- skills/takeover/SKILL.md (v1.0.0)
- agent-context/constraints/skill-interdependency.md
