---
name: collab
version: 2.0.0
description: >
  Orchestrate dual-agent collaboration (Claude worker + Codex worker) by
  sending a single collab request to the Global Session Orchestrator, which
  launches both workers in dedicated git worktrees via conductor.sh. The skill
  drives cross-review, synthesis, and merge in the caller's session.
trigger_phrases:
  - "/collab"
  - "collab"
  - "협업 모드"
  - "같이 작업해"
  - "듀얼 에이전트"
  - "병렬 실행"
  - "cross review"
  - "동시 작업"
output_dir: "~/.claude/orchestrator"
---

# Collab — Orchestrator-mediated Dual-Agent Collaboration

## ACP Integration

> 이 스킬은 AGENTS.md의 ACP 규칙을 준수합니다.

- Follows **ADR-013 Pattern 1: Dual-Agent Worktree Review** (`../../agent-context/decisions/2026-01-15-a2a-parallel-distributed-model.md`).
- Follows **ADR-017 Rule 2** language convention: English for workflow/notes, Korean only for trigger phrases and output format examples.
- Follows **ADR-028 Stage 0.2 Phase C**: all multi-agent launches go through the Global Session Orchestrator.
- When new constraints or architecture decisions are discovered during orchestration, record them via `/acp-constraint` or `/acp-decision` (do not edit `agent-context/` directly).

## Purpose

Run two independent workers concurrently (Claude and Codex) on the **same task**
inside **dedicated git worktrees**, then use **cross-review** and **synthesis**
to merge the best result to the main branch with clear provenance.

This is a thin client for the orchestrator's `type: collab` request.
The orchestrator handles worktree creation, sibling spawn, and state tracking
for both workers. The skill handles planning, polling, cross-review dispatch,
synthesis, and merge — the LLM-heavy and context-dependent phases.

## When to Use

Use `/collab` when:
- The task has enough ambiguity or surface area that two independent solutions will likely differ in quality.
- You want higher confidence through adversarial comparison (cross-review), not just faster output.
- You need strong provenance (two branches + commits + review notes) for auditability.

Avoid `/collab` when:
- The task is tiny (a few-line change) where orchestration overhead dominates.
- The task requires shared mutable state (the pattern assumes dedicated worktrees).

**Invocation rule**: `/collab` must only activate on an explicit user command
(`/collab` or a trigger phrase). The agent must NEVER auto-initiate the collab
workflow based on its own assessment of task suitability.

## Task Type Variants

Identify the type in Phase 1 and follow the matching flow:

- **Code production (default)**: workers edit & commit → cross-review via diff → merge best result.
- **Review / analysis**: workers produce `REVIEW.md` → cross-review evaluates findings → synthesis applies fixes to main (no branch merge).

## Non-negotiable Requirements

- Base slug must be lowercase kebab-case, **max 25 chars** (the orchestrator
  appends `-claude` / `-codex` suffixes and conductor.sh caps slugs at 32).
- The orchestrator agent MUST be running before the skill sends a request. If
  not, the skill reports this and suggests
  `bash scripts/orchestrator/start-agent.sh --execute`.
- Every first call is a **dry-run preview**. The skill submits with
  `dry_run: true`, shows both planned dispatches to the user, and only
  re-submits with `dry_run: false` after explicit approval.
- Do not override the orchestrator's worktree default; set `no_worktree: true`
  only for review-only or documentation-only tasks and surface the reason.
- Keep the base slot untouched. The orchestrator refuses any dispatch that
  targets `claude-orchestrator-global` or a project base slot.

## Workflow

### Phase 1 — Task Plan (caller session)

**Goal**: Define scope and produce one identical task brief for both workers.

**Actions**:

1. Choose a short, descriptive `base_slug` (e.g., `rename-skill`, `add-tests`,
   `fix-auth`). Must be ≤25 chars.
2. Identify task type: code production or review/analysis.
3. Write a 5–10 line task plan (scope, constraints, expected outputs).
4. Select reasoning effort for Codex based on task complexity:

   | Effort | Task Type |
   |--------|-----------|
   | `low` | Trivial text edits, formatting |
   | `medium` | Routine code changes |
   | `high` (default) | Complex implementation, review |
   | `xhigh` | Architecture-level work, deep audit |

5. Produce one **identical base prompt** for both workers, including:
   - Required outputs (patch, commands run, files changed)
   - What to do if blocked (ask vs assume)
   - Definition-of-done checklist
6. **Precondition**: all target files must be committed to HEAD before
   dispatch — worktrees branch from HEAD, and uncommitted changes on main
   will NOT be visible to workers. Commit first if needed:

   ```bash
   git add <target-files> && git commit -m "WIP: stage files for collab"
   ```

**Outputs**: `base_slug`, task description (identical for both workers),
task type, reasoning effort level.

### Phase 2 — Orchestrator collab dispatch (thin client)

**Goal**: Launch both workers via a single orchestrator request.

**Step 2a — Verify orchestrator is alive**:

```bash
bash scripts/orchestrator/health.sh
```

If the exit code is non-zero, stop and tell the user to start the orchestrator
with `bash scripts/orchestrator/start-agent.sh --execute`. Do not auto-start.

**Step 2b — Dry-run preview**:

```bash
bash -c '
  . scripts/orchestrator/protocol.sh
  orchestrator_request --type collab --slug "<base_slug>" --timeout 120 --payload "## Payload
- slug: <base_slug>
- description: <task description>
- reasoning_effort: <low|medium|high|xhigh>
- dry_run: true
- no_worktree: false
"
'
```

Display the response `## Result` section to the user. It contains the planned
Claude and Codex dispatches (slot names, worktree paths, work_item paths).
Ask explicitly:

```
Orchestrator returned the paired dispatch plan above.
Proceed with --execute? (y/n)
```

**Step 2c — Execute on approval**:

Re-submit with `dry_run: false` and a longer timeout (both dispatches run
sequentially, each with a ~10s post-spawn wait):

```bash
bash -c '
  . scripts/orchestrator/protocol.sh
  orchestrator_request --type collab --slug "<base_slug>" --timeout 300 --payload "## Payload
- slug: <base_slug>
- description: <task description>
- reasoning_effort: <level>
- dry_run: false
- no_worktree: false
"
'
```

Exit codes from `orchestrator_request`:
- `0` = ok, both workers launched
- `1` = orchestrator not running
- `2` = timeout
- `3` = orchestrator returned `status: error` or `status: partial`
- `4` = protocol error

On `status: partial` (Claude launched but Codex failed), the Claude worker is
still alive; decide whether to clean it up via
`bash scripts/conductor.sh done {base_slug}-claude --cleanup --execute`
and retry, or continue with a single-worker fallback.

**Step 2d — Capture worker handles**:

From the response Result section, extract for each worker:
- `slot` (e.g., `claude-agent-framework-<slug>-claude-1`)
- `worktree_path` (e.g., `.worktrees/<slug>-claude`)
- `work_item_path`
- `done_report_path`

Store these for Phases 3–5. The two branches are
`agent/claude-<slug>-claude` and `agent/codex-<slug>-codex` (or whatever
conductor.sh produced; read the worktree branch from the JSON).

### Phase 3 — Cross Review

**Goal**: Each worker reviews the other's output and produces actionable findings.

**Precondition**: Both workers have committed their work (code production) or
produced `REVIEW.md` at the worktree root (review task). Poll until both
conditions hold:

```bash
# Code production: wait for commit on each worker branch
while [ -z "$(git -C <claude_worktree_path> log --oneline main..HEAD 2>/dev/null)" ]; do sleep 10; done
while [ -z "$(git -C <codex_worktree_path> log --oneline main..HEAD 2>/dev/null)" ]; do sleep 10; done

# Review task: wait for REVIEW.md file
while [ ! -f "<claude_worktree_path>/REVIEW.md" ]; do sleep 10; done
while [ ! -f "<codex_worktree_path>/REVIEW.md" ]; do sleep 10; done
```

Timeout: 10 minutes per worker. If no progress, inspect the sibling slot via
the backend (`cmux read-screen`, etc.) to diagnose.

**Step 3a — Collect outputs**:

```bash
# Code production
git -C <claude_worktree_path> diff --unified=5 main..HEAD > /tmp/<slug>-claude.diff
git -C <codex_worktree_path>  diff --unified=5 main..HEAD > /tmp/<slug>-codex.diff

# Review task
cp <claude_worktree_path>/REVIEW.md /tmp/<slug>-claude.review.md
cp <codex_worktree_path>/REVIEW.md  /tmp/<slug>-codex.review.md
```

> **Important**: Paste the collected diff/review content directly into the
> cross-review prompts. Do NOT instruct workers to read files from another
> worktree path — it causes excessive reasoning overhead.

**Step 3b — Dispatch cross-review**:

Option A (simplest, recommended): mark Phase 2 workers done first, then send a
second `/collab` request with different base slug (`<slug>-xr`) and descriptions
that embed the other worker's diff. This reuses the full orchestrator flow.

```bash
bash scripts/conductor.sh done <base_slug>-claude --execute
bash scripts/conductor.sh done <base_slug>-codex  --execute
```

Then the caller composes the cross-review descriptions:

```
CLAUDE_XR_DESC="You are performing a CROSS-REVIEW. Worker B (Codex) produced
the following diff:

<paste /tmp/<slug>-codex.diff>

Create CROSS-REVIEW.md at the worktree root with per-item verdicts
(Agree/Disagree/Partially), new findings, and overall verdict. Then commit."

CODEX_XR_DESC="You are performing a CROSS-REVIEW. Worker A (Claude) produced
the following diff:

<paste /tmp/<slug>-claude.diff>

Create CROSS-REVIEW.md at the worktree root with per-item verdicts
(Agree/Disagree/Partially), new findings, and overall verdict. Then commit."
```

The cross-review descriptions differ per worker, so the collab handler (which
sends the same description to both) is not a perfect fit. Use two direct
`/dispatch` calls instead — each with `--agent claude` or `--agent codex` — to
spawn the cross-review round:

```bash
bash -c '
  . scripts/orchestrator/protocol.sh
  orchestrator_request --type dispatch --slug "<base_slug>-xr-claude" --timeout 180 --payload "## Payload
- slug: <base_slug>-xr-claude
- description: $CLAUDE_XR_DESC
- worker_family: claude
- dry_run: false
- no_worktree: false
"
'

bash -c '
  . scripts/orchestrator/protocol.sh
  orchestrator_request --type dispatch --slug "<base_slug>-xr-codex" --timeout 180 --payload "## Payload
- slug: <base_slug>-xr-codex
- description: $CODEX_XR_DESC
- worker_family: codex
- dry_run: false
- no_worktree: false
"
'
```

Poll for cross-review commits the same way, then read the resulting
`CROSS-REVIEW.md` files from the xreview worktrees.

### Phase 4 — Synthesis (caller)

**Goal**: Aggregate both worker outputs + both cross-reviews into one best
plan, then decide: merge vs re-dispatch.

**Actions**:

1. Read:
   - Worker A output (diff or REVIEW.md) + self-review
   - Worker B output (diff or REVIEW.md) + self-review
   - Cross-review findings from both sides (CROSS-REVIEW.md x2)
2. Build a comparison table:

   ```markdown
   | Item | Worker A | Worker B | Winner | Rationale | Merge Action |
   |------|----------|----------|--------|-----------|--------------|
   | ... | ... | ... | A/B | ... | cherry-pick / rework |
   ```

3. Decide:
   - **Merge now** (Phase 5) if one solution is clearly superior or merge is trivial.
   - **Re-dispatch** (back to Phase 2) with the same base slug plus a feedback
     appendix if both outputs are incomplete.

### Phase 5 — Final Merge + Cleanup

**Checklist** (all required before Phase 5 completes):
- [ ] Best result merged to main
- [ ] All four task slugs marked done via `conductor.sh done --execute`
- [ ] Worktrees cleaned up by conductor (or manually `git worktree remove`)
- [ ] Archive saved under `.collab/<base_slug>.md`
- [ ] Final commit SHA recorded

**Code production merge**:

```bash
git checkout main
git merge --no-ff <claude_worker_branch>
# Optionally layer cherry-picks from the other worker
git cherry-pick <commit-from-codex_worker_branch>
```

**Review task merge**: apply synthesized fixes directly to main files, then
commit with collab provenance.

**Mark all four tasks done** (Phase 2 pair + Phase 3 xreview pair):

```bash
bash scripts/conductor.sh done <base_slug>-claude     --execute
bash scripts/conductor.sh done <base_slug>-codex      --execute
bash scripts/conductor.sh done <base_slug>-xr-claude  --execute
bash scripts/conductor.sh done <base_slug>-xr-codex   --execute
```

`conductor.sh done --execute` removes the per-task worktree by default.

**Archive**:

```bash
mkdir -p .collab
cat > .collab/<base_slug>.md << 'ARCHIVE'
# Collab: <base_slug>

## Meta
- Date: <date>
- Worker branches: <claude_branch>, <codex_branch>
- Final commit: <sha>

## Task
<original task description>

## Comparison
<comparison table from Phase 4>

## Cross Review Summary
- Worker A findings: <summary>
- Worker B findings: <summary>

## Decision
<merge strategy and rationale>
ARCHIVE
```

## Output Format Examples

### 실행 계획 예시

```markdown
## /collab 실행 계획

### 1) 작업 정의
- 목표: {한 줄 목표}
- 범위: {대상 파일/디렉터리}
- 완료 조건: {체크리스트}
- base_slug: {base_slug}
- 작업 유형: 코드 생산 / 리뷰
- reasoning_effort: {level}

### 2) 오케스트레이터 dispatch
- 사전 확인: `health.sh` PASS, 대상 파일 커밋됨
- dry-run preview → 사용자 승인 → execute
- 결과: 두 워커 (Claude#A, Codex#B) 각자 worktree에서 작업 시작

### 3) 교차 리뷰
- 양쪽 출력 수집 (diff 또는 REVIEW.md)
- 두 개의 /dispatch 요청으로 cross-review worker 생성
- CROSS-REVIEW.md 완료 대기

### 4) 합성(Synthesis)
- 비교표 작성 후 "병합" 또는 "재디스패치" 결정

### 5) 최종 병합 + 정리
- main에 반영
- 4개 task 모두 conductor.sh done --execute
- .collab/{base_slug}.md 아카이브
```

### 비교 테이블 예시

```markdown
| 항목 | Worker A (Claude) | Worker B (Codex) | 판정 | 근거 |
|------|-------------------|------------------|------|------|
| ADR 준수 | 한국어 혼용 | 영어 준수 | B | 컨벤션 위반 |
| Idempotency | 없음 | 명시적 | B | 반복 실행 안전 |
| No-op 정책 | 명시적 | 없음 | A | 불필요한 수정 방지 |
```

## Relationship to other skills

- **`/dispatch`**: sibling sub-dispatch for single-worker side quests; also a
  thin orchestrator client. `/collab` reuses it for Phase 3 cross-review.
- **`conductor.sh done/cleanup`**: Phase 5 calls `conductor.sh done <slug> --cleanup --execute`
  on all four paired slugs. No separate skill needed.
- **`/handoff` / `/takeover`**: per-session lifecycle; do not route through
  the orchestrator.

## Notes

- This is v2.0.0. Changes from v1.6.0:
  - Orchestrator-mediated Phase 2 dispatch (no direct cmux/zmx bash).
  - Worktree + spawn logic deleted from the skill file; delegated to
    `conductor.sh` via the orchestrator's `collab` handler.
  - Phase 3 cross-review uses two `/dispatch` thin-client calls instead of
    re-using the Phase 2 cmux surface (the orchestrator has no
    "inject-into-running-sibling" primitive yet; a future stage may add one).
  - Skill shrank from ~630 lines to ~300 lines.
- The orchestrator agent must be started before `/collab` is invoked. The
  skill does not auto-start it — starting a long-lived session is a
  user-visible event.
- **Worker A permission fallback no longer applies**: Phase 2 workers run in
  full sibling sessions with their own permission contexts, not as Agent tool
  sub-agents.
- Cross-review is the key differentiator of this pattern; skipping it removes
  most of the value.
- Keep task content identical across Phase 2 workers. Phase 3 prompts
  intentionally differ because each worker reviews the other's output.
- Clean up worktrees after merge to avoid git worktree clutter. `conductor.sh
  done --execute` handles this by default.

## References

- [ADR-013: A2A Parallel and Distributed Execution Model](../../agent-context/decisions/2026-01-15-a2a-parallel-distributed-model.md)
- [ADR-017: Skill Authoring Conventions](../../agent-context/decisions/2026-02-26-skill-authoring-conventions-and-auto-loading.md)
- [ADR-020: Harness Engineering Adoption](../../agent-context/decisions/2026-03-10-harness-engineering-adoption.md)
- [ADR-028: Global Session Orchestrator](../../agent-context/decisions/2026-04-08-global-session-orchestrator.md)
