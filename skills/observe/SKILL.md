---
name: observe
version: 1.0.0
description: "에이전트 활동을 분석하고 개선점을 제안합니다. (1) '/observe' 요청 시, (2) '에이전트 분석', '활동 분석' 요청 시, (3) '개선점 찾아줘', '뭐 개선할 수 있어?' 요청 시, (4) 반복 작업 탐지나 스킬 사용 패턴 분석이 필요할 때 사용."
---

# Observe — Agent Activity Analysis & Improvement Proposals

Analyzes transcript-derived agent activity to discover patterns, diagnose issues, and generate actionable improvement proposals. This is the Phase 2 entry point of [ADR-022: Agent Observability and Improvement Loop](../../agent-context/decisions/2026-03-25-agent-observability-improvement-loop.md).

## Input

Optional:
- `--days N`: Analysis period (default: 7)
- `--session <id>`: Focus on specific session
- `--deep`: Include LLM diagnosis of trace segments

## Data Source

Unified transcript events from `./scripts/extract-traces.sh`, typically:

- `./scripts/extract-traces.sh --agent all --days N`
- `./scripts/extract-traces.sh --agent all --date YYYY-MM-DD`

The extractor normalizes Claude and Codex transcripts into these event types:

```jsonl
{"ts":"...","sid":"abc","evt":"prompt","text":"harness 스킬 수정해줘"}
{"ts":"...","sid":"abc","evt":"tool","tool":"Edit","input":{...},"ok":true,"cwd":"..."}
{"ts":"...","sid":"abc","evt":"skill","skill":"collab"}
```

Codex data is included in the same stream. ADR references live in `agent-context/decisions/`.

## Workflow

### Phase 1: Collect

1. Run `./scripts/extract-traces.sh --agent all --days N` for the target period.
2. If no transcript events exist, inform user and suggest running some sessions first.
3. Count total events, sessions, date range.

### Phase 2: Correlate — Build Activity Graph

Group events by session_id, then within each session, link prompts to subsequent tool calls:

```
Session abc123:
  [prompt] "harness 스킬 수정해줘"
    → [tool] Read skills/harness/SKILL.md (ok)
    → [tool] Edit skills/harness/SKILL.md (ok)
    → [tool] Bash sync-skills.sh --push (ok)
  [prompt] "커밋해"
    → [tool] Bash git add ... (ok)
    → [tool] Bash git commit ... (ok)
```

A prompt "owns" all tool calls until the next prompt in the same session.

### Phase 3: Evaluate — Run Metrics

Execute `./scripts/analyze-activity.sh --source all --days N --report` to get baseline metrics, then compute additional context-aware metrics:

| Metric | How |
|--------|-----|
| Prompt-to-completion rate | Prompts where all subsequent tools succeeded |
| Avg tools per prompt | Total tools / total prompts per session |
| Repeated prompts | Same or similar text across sessions (fuzzy match on first 50 chars) |
| Prompt-type distribution | Categorize: command, question, skill invocation, correction |
| Correction rate | Prompts containing "다시", "아니", "그거 말고", "rollback" etc. |

### Phase 4: Diagnose — Find Patterns

Look for these improvement signals:

**4a. Repeated manual work → Skill candidate**

If the same sequence of tool calls appears across multiple sessions (e.g., Read→Edit→sync-skills.sh→commit), propose a new skill or hook to automate it.

**4b. High failure after specific prompt type → Skill gap**

If prompts about topic X consistently lead to tool failures, the relevant skill may need better guidance or the agent needs a constraint.

**4c. ADR vs implementation gap**

Read ADR files in `agent-context/decisions/` and compare stated goals/phases against actual activity patterns. Flag ADR phases marked as targets but with no corresponding activity.

**4d. Unused skills → Trigger problem or deprecation candidate**

Compare deployed skills (`~/.claude/skills/`) against `evt: "skill"` events. If a skill exists but was never invoked in the analysis period, investigate trigger phrases.

**4e. Correction patterns → Agent behavior issue**

High correction rate suggests the agent is misunderstanding requests or producing wrong output. Trace back to which prompts trigger corrections.

**4f. `--deep` mode → LLM diagnosis input selection**

When `--deep` is enabled, only feed bounded, high-signal trace segments to the LLM:

- Sessions with more than 3 consecutive failures
- Sessions with correction rate above 20%

For each selected segment, include:

- The prompt that started the segment
- All `evt:tool` and `evt:skill` entries until the next prompt
- The failure streak, correction prompt, and any recovery attempt
- Relevant ADR references from `agent-context/decisions/` when diagnosing intent vs implementation

Prompt template for LLM diagnosis:

```text
You are diagnosing agent execution traces.

Goal:
- Identify the most likely root cause
- Recommend the smallest effective change to a skill, hook, constraint, or workflow

Context:
- Analysis period: {date range}
- Session: {session_id}
- Signal: {consecutive failures > 3 | correction rate > 20%}
- ADR directory: agent-context/decisions/

Trace segment:
{prompt + linked tool/skill events}

Respond in this format:
1. Root cause
2. Evidence from trace
3. Recommended change
4. Target file(s)
5. Expected metric improvement
6. Risk and validation check
```

### Phase 5: Prescribe — Generate Proposals

For each diagnosis finding, generate an Improvement Proposal:

```markdown
## Proposal: {title}

**Evidence**: {specific log entries, metrics}
**Diagnosis**: {root cause}
**Proposed change**:
  - Type: skill-update | skill-create | hook-add | hook-modify | constraint-add | trigger-fix
  - File: {target file}
  - Change: {description of what to change}
**Expected impact**: {which metric improves}
**Risk**: {what could go wrong}
```

Save proposals to `.agent/observe/proposals/observe-YYYY-MM-DD.md`.

### Phase 6: Report

Present summary to user in Korean:

```
## 에이전트 활동 분석 결과
> 분석 기간: 2026-03-19 ~ 2026-03-25 (7일)

### 요약
- 세션: 15개, 프롬프트: 89개, 도구 호출: 847회
- 프롬프트 성공률: 91.0% (81/89)
- 수정 요청 비율: 8.9% (8/89)

### 발견 사항

1. **반복 작업 탐지**: "sync-skills.sh --push" 후 "sync-hooks.sh --push"가 12회 반복
   → 제안: 통합 배포 스킬 또는 단일 스크립트

2. **미사용 스킬**: wiki-edit (0회), postmortem (0회)
   → 제안: 트리거 키워드 리뷰 또는 deprecation 검토

3. **ADR-022 gap**: Phase 2 "Stop hook 자동 분석" 미구현
   → 제안: Stop hook 추가하여 세션 종료 시 자동 요약

### 개선 제안서
.agent/observe/proposals/observe-2026-03-25.md 에 3건 저장됨

### 다음 단계
- 승인하려면 해당 제안을 /collab으로 구현하세요
- 루프: /observe → proposals → /collab → implement → /observe again
```

## Automated Scheduling

### Weekly /observe via /schedule

Set up automatic weekly analysis using Claude Code's `/schedule` skill:

```
/schedule create "weekly-observe" --cron "0 10 * * 1" --prompt "/observe --days 7"
```

This creates a cloud-backed remote agent that runs `/observe --days 7` every Monday at 10:00 AM.

### Managing the schedule

```
/schedule list                          # View active schedules
/schedule delete "weekly-observe"       # Remove the schedule
```

### What happens automatically

1. Remote agent runs `/observe --days 7` on schedule
2. Proposals are saved to `.agent/observe/proposals/observe-YYYY-MM-DD.md`
3. On your next session, run `/improve` to review and apply proposals

### What still requires human approval

- Reviewing generated proposals
- Selecting which proposals to apply
- Confirming deployment and release tagging

This is by design (ADR-022 Phase 4 safety boundary): observe and propose automatically, apply only with human approval.

## Notes

- This skill reads logs but never modifies them.
- Proposals are suggestions — human approval required before any change.
- For `--deep` mode, LLM analyzes specific trace segments for root cause (uses more tokens).
- Run periodically (weekly recommended) or when performance feels degraded.
- Integrates with `/daily` closing mode: daily closing can auto-invoke a lightweight version.
