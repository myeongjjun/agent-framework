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
  `bash ~/.orchestrator/scripts/orchestrator/start-agent.sh --execute`.
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
bash ~/.orchestrator/scripts/orchestrator/health.sh
```

If the exit code is non-zero, stop and tell the user to start the orchestrator
with `bash ~/.orchestrator/scripts/orchestrator/start-agent.sh --execute`. Do not auto-start.

**Step 2b — Dry-run preview (conditional)**:

Run dry-run **only when the user requested a preview** or the task
carries explicit risk signals. Otherwise skip directly to Step 2c.

| Trigger | Action |
|---|---|
| User said "dry-run" / "preview" / "plan 먼저" / "확인하고" / "검토 먼저" | run dry-run, then ask `Proceed with --execute? (y/n)` |
| User wrote a plan and asked the agent to review it before launching | run dry-run, then ask |
| User gave full /collab spec (slug + description, or a brief file) and said "진행" / "수행해" / "바로" / "execute" / "go" | **skip 2b, go straight to 2c** |
| User invoked /collab after a prior planning turn the agent already echoed back | **skip 2b** (plan was already reviewed) |
| Ambiguous — first-time pattern, large blast radius, unclear acceptance criteria | run dry-run, then ask |

When running dry-run, use `build_collab_payload` to construct the payload.
The builder emits `description` as a YAML block scalar so multi-line task
descriptions survive the request → work-item path intact. Never substitute
a multi-line `<task description>` into a raw `- description: %s` template,
as that truncates to the first line.

```bash
bash -c '
  . ~/.orchestrator/scripts/orchestrator/protocol.sh
  payload="$(build_collab_payload \
    --slug "<base_slug>" \
    --description "<task description>" \
    --dry-run)"
  orchestrator_request --type collab --slug "<base_slug>" --timeout 120 --payload "## Payload
${payload}
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

**Step 2c — Execute** (default path when 2b skipped; or after y on 2b):

Re-submit using `build_collab_payload` without `--dry-run`, with a
longer timeout (both dispatches run sequentially, each with a ~10s
post-spawn wait):

```bash
bash -c '
  . ~/.orchestrator/scripts/orchestrator/protocol.sh
  payload="$(build_collab_payload \
    --slug "<base_slug>" \
    --description "<task description>")"
  orchestrator_request --type collab --slug "<base_slug>" --timeout 300 --payload "## Payload
${payload}
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
`bash ~/.orchestrator/scripts/conductor.sh done {base_slug}-claude --cleanup --execute`
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

**Step 3b — Inject cross-review into existing workers** (was: dispatch new
ones). Phase 2 workers are still alive (keep_alive=true) with their full
task context, worktree, and uncommitted state. We reuse them by injecting
a cross-review prompt via `orchestrator_request --type inject`:

```
CLAUDE_XR_PROMPT="CROSS-REVIEW round. Worker B (Codex) produced this diff
(commit this round's output as CROSS-REVIEW.md in your worktree then commit):

<paste /tmp/<slug>-codex.diff>

Produce CROSS-REVIEW.md with per-item verdicts (Agree/Disagree/Partially),
new findings, and overall verdict. Then: git add CROSS-REVIEW.md &&
git commit -m 'cross-review: <slug>'."

CODEX_XR_PROMPT="CROSS-REVIEW round. Worker A (Claude) produced this diff
(commit this round's output as CROSS-REVIEW.md in your worktree then commit):

<paste /tmp/<slug>-claude.diff>

Produce CROSS-REVIEW.md with per-item verdicts (Agree/Disagree/Partially),
new findings, and overall verdict. Then: git add CROSS-REVIEW.md &&
git commit -m 'cross-review: <slug>'."
```

Inject into each existing worker:

```bash
bash -c '
  . ~/.orchestrator/scripts/orchestrator/protocol.sh
  orchestrator_request --type inject --timeout 30 --payload "## Payload
- slug: <base_slug>-claude
- prompt: '"${CLAUDE_XR_PROMPT}"'
"
'

bash -c '
  . ~/.orchestrator/scripts/orchestrator/protocol.sh
  orchestrator_request --type inject --timeout 30 --payload "## Payload
- slug: <base_slug>-codex
- prompt: '"${CODEX_XR_PROMPT}"'
"
'
```

Only 2 workers total for the whole collab (not 4). Each worker already
has the task brief + worktree + Phase 2 output — injecting the cross-
review prompt continues the same session with new instructions.

Poll for the CROSS-REVIEW.md commit on each worker's branch (or file
existence in the worktree):

```bash
while [ ! -f "<claude_worktree_path>/CROSS-REVIEW.md" ]; do sleep 10; done
while [ ! -f "<codex_worktree_path>/CROSS-REVIEW.md" ]; do sleep 10; done
```

Then read both `CROSS-REVIEW.md` files from the original Phase 2 worktrees.

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
- [ ] Both worker sessions ended (they exit naturally once Phase 3 completes,
      or caller injects `/exit` once outputs are collected)
- [ ] Worktrees cleaned up via `orchestrator_request --type tidy`
- [ ] Archive saved under `.collab/<base_slug>.md`
- [ ] Final commit SHA recorded

**Code production merge**:

Use `./scripts/agent-promote.sh` for both worker branches. It squashes
each worker's `wip(<slug>)` commits, runs a risk scan, and squash-merges
into the current branch.

When one worker is clearly best (synthesis chose its diff wholesale):

```bash
./scripts/agent-promote.sh <base_slug>-claude --cleanup
# or:
./scripts/agent-promote.sh <base_slug>-codex --cleanup
```

When synthesis blends both — promote the chosen "base" worker first,
then layer the second worker's specific commits via cherry-pick. This is
the legitimate cherry-pick use case the guard hook still allows; prefix
with `CHERRY_PICK_OK=1` to silence the warning:

```bash
./scripts/agent-promote.sh <base_slug>-claude
CHERRY_PICK_OK=1 git cherry-pick <commit-from-codex-branch>
./scripts/agent-promote.sh <base_slug>-codex --cleanup   # optional, only
                                                          # if anything else
                                                          # in that branch is
                                                          # worth landing
```

To preserve the worker's commit history instead of squashing, pass
`--no-ff` to `agent-promote.sh`. The merge commit's message embeds the
worker branch name for provenance.

**Review task merge**: apply synthesized fixes directly to main files, then
commit with collab provenance.

**Clean up both worker worktrees** (only 2 workers — Phase 3 reused them):

Once the workers exit (injecting `/exit` after collecting CROSS-REVIEW.md
and diff output is sufficient), their cmux panes auto-close and zmx
sessions die. The daemon's periodic tidy loop (every 30s) removes the
worktrees + branches automatically.

For immediate cleanup, call tidy via orchestrator_request:

```bash
bash -c '
  . ~/.orchestrator/scripts/orchestrator/protocol.sh
  orchestrator_request --type tidy --payload "$(build_tidy_payload)" --timeout 30
'
```

`tidy` is resource-based — it detects which workers have finished
(zmx gone) and removes only those worktrees/branches. Live workers
are protected. Optionally scope to specific slugs:

```bash
build_tidy_payload --slug <base_slug>-claude --slug <base_slug>-codex
```

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
  thin orchestrator client.
- **`orchestrator_request --type inject`**: Phase 3 reuses Phase 2 workers
  via inject (same session, new prompt) — no new worker spawned.
- **`orchestrator_request --type tidy`**: Phase 5 resource cleanup. Also
  runs automatically every ~30s via the daemon's periodic tidy loop.
- **`/handoff` / `/takeover`**: per-session lifecycle; do not route through
  the orchestrator.

## Notes

- This is v2.1.0. Changes from v2.0.0:
  - Phase 3 now uses `orchestrator_request --type inject` to send the
    cross-review prompt to the existing Phase 2 workers (was: dispatch 2
    new workers). Total worker count: 2 (not 4). Each worker keeps its
    task context, worktree, and Phase 2 output.
  - Phase 5 cleanup uses `orchestrator_request --type tidy` (daemon
    routes to conductor.sh). Direct conductor.sh calls are now blocked
    by the role-based guard hook.
- Changes from v1.6.0 to v2.0.0:
  - Orchestrator-mediated Phase 2 dispatch (no direct cmux/zmx bash).
  - Worktree + spawn logic delegated to conductor.sh via the
    orchestrator's `collab` handler.
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
