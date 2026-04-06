---
name: collab
version: 1.4.0
description: >
  Orchestrate dual-agent collaboration (Claude worker + Codex worker) in dedicated git
  worktrees keyed by task slug, with cross-review and synthesis into a single merged result.
trigger_phrases:
  - "/collab"
  - "collab"
  - "협업 모드"
  - "같이 작업해"
  - "듀얼 에이전트"
  - "병렬 실행"
  - "cross review"
  - "동시 작업"
---

# Collab — Dual-Agent Worktree Orchestration

## ACP Integration

- Follows **ADR-013 Pattern 1: Dual-Agent Worktree Review** (`../../agent-context/decisions/2026-01-15-a2a-parallel-distributed-model.md`).
- Follows **ADR-017 Rule 2** language convention: English for workflow/notes, Korean only for trigger phrases and output format examples (`../../agent-context/decisions/2026-02-26-skill-authoring-conventions-and-auto-loading.md`).
- When new constraints or architecture decisions are discovered during orchestration, record them via `/acp-constraint` or `/acp-decision` (do not edit `agent-context/` directly).

## Purpose

Run two independent workers concurrently (Claude#2 and Codex) on the **same task** inside **dedicated git worktrees** keyed by a task slug, then use **cross-review** + **synthesis** to merge the best result to the main branch with clear provenance.

This skill is an orchestration playbook for the five required components in ADR-013:
**Work Distribution**, **State Consistency**, **Checkpointing**, **Result Aggregation**, **Observability**.

## When to Use

Use `/collab` when:
- The task has enough ambiguity or surface area that two independent solutions will likely differ in quality.
- You want higher confidence through adversarial comparison (cross-review), not just faster output.
- You need strong provenance (two branches + commits + review notes) for auditability.

Avoid `/collab` when:
- The task is tiny (a few-line change) where orchestration overhead dominates.
- The task requires shared mutable state (the pattern assumes dedicated worktrees).

**Invocation rule**: `/collab` must only activate on an explicit user command (`/collab` or a trigger phrase). The agent must NEVER auto-initiate the collab workflow based on its own assessment of task suitability. If the user did not explicitly invoke collab, do not enter this workflow.

## Task Type Variants

This skill supports two task patterns. Identify the type in Phase 1 and follow the corresponding flow.

### Code Production (default)

Workers produce code changes → cross-review via diff → merge best result.

Phase flow: Plan → Dispatch (workers edit & commit) → Cross-review (diff branches) → Synthesis → Merge

### Review / Analysis

Workers produce analysis documents → cross-review evaluates each other's findings → synthesis applies fixes.

Phase flow: Plan → Dispatch (workers produce REVIEW.md) → Cross-review (evaluate findings) → Synthesis → Apply fixes to main (no branch merge)

Key differences from code production:
- Workers create `REVIEW.md` (analysis), not code changes
- Cross-review evaluates the _quality of findings_, not code diffs
- Phase 5 applies fixes to original files on main, not branch merge/cherry-pick
- Branch-level diff is not useful; review content comparison is the mechanism

## Role Structure

```text
Claude#1 (Orchestrator)
├── Claude#2 (Worker A, Agent tool, explicit worktree path, background)
└── Codex    (Worker B, codex exec, separate git worktree)
```

## Worker Output Conventions

Workers must create well-known files in their worktree root so the orchestrator can reliably collect results.

| Phase | File | Contents |
|-------|------|----------|
| Phase 2 (code) | committed changes on branch | Code edits + self-review in commit message |
| Phase 2 (review) | `REVIEW.md` | Strengths, Issues, Suggestions, Risk notes |
| Phase 3 | `CROSS-REVIEW.md` | Per-item verdict on other worker's output, new findings |

The orchestrator reads these files after each phase via `Read` tool on the worktree path:
```
/repo/.worktrees/{task-slug}-claude/REVIEW.md
/repo/.worktrees/{task-slug}-codex/REVIEW.md
```

## Full Workflow (5 Phases, Cyclic)

### Phase 1 — Task Plan (Claude#1)

**Goal**: Define scope and create one identical task prompt for both workers.

**Inputs**:
- Task statement (what to do)
- Target files / directories
- Constraints (language, style, safety, deadlines)
- Acceptance criteria (what "done" means)

**Actions**:
1. Choose a short, descriptive `{task-slug}` (e.g., `rename-skill`, `add-tests`, `fix-auth`) for observability and deterministic naming.
2. **Identify the task type**: code production or review/analysis (see Task Type Variants above).
3. Write a 5-10 line task plan (scope, constraints, expected outputs).
4. Select reasoning effort for Worker B (Codex) based on task complexity:

   | Effort | Task Type | Examples |
   |--------|-----------|----------|
   | `low` | Trivial text edits, formatting | Typo fix, comment change, whitespace |
   | `medium` | Routine code changes | File rename, simple function edit, config update |
   | `high` | Complex implementation (default) | New feature, refactoring, multi-file changes |
   | `high` | Code review, ADR review | Review with cross-referencing, analysis |
   | `xhigh` | Architecture-level work | Design decisions, complex algorithms, system design |
   | `xhigh` | Deep audit, security review | Cross-codebase audit, architectural analysis |

   Default to `high` when unsure. Use `xhigh` for deep reasoning or review tasks requiring extensive cross-referencing.

5. Produce one **identical base prompt** for both workers, including:
   - Required outputs (patch, commands run, files changed)
   - What to do if blocked (ask questions vs make assumptions)
   - A "definition of done" checklist
6. Decide worktree names and branch names up front:
   - Worktrees: `.worktrees/{task-slug}-claude`, `.worktrees/{task-slug}-codex`
   - Branches: `collab/{task-slug}-claude`, `collab/{task-slug}-codex`
7. Build worker-specific prompt wrappers that prepend explicit path instructions while keeping the task content identical.

**Outputs**:
- `PROMPT_WORKER_BASE` (identical task content)
- `PROMPT_WORKER_CLAUDE`, `PROMPT_WORKER_CODEX` (path-prepended wrappers)
- Worktree/branch naming plan
- Task type (code production / review)
- Reasoning effort level for Worker B

---

### Phase 2 — Task Dispatch (Claude#1 → Claude#2, Codex)

**Goal**: Start both workers concurrently in dedicated worktrees.

#### Precondition: Target files must be committed

**All files that workers need to read or modify must be committed to HEAD before creating worktrees.** Worktrees branch from the current HEAD — uncommitted or staged changes on main will NOT be present in the worktree.

If the task involves reviewing recently created files, commit them first:
```bash
git add <target-files> && git commit -m "WIP: stage files for collab review"
```

#### Step 0: Manual worktree setup (required before any dispatch)

```bash
# From repo root (main worktree)
mkdir -p .worktrees
git worktree add -b collab/{task-slug}-claude .worktrees/{task-slug}-claude
git worktree add -b collab/{task-slug}-codex .worktrees/{task-slug}-codex
```

#### Worker A: Claude#2 dispatch (Agent tool; explicit path; background)

```text
Agent(
  subagent_type: "general-purpose",
  run_in_background: true,
  prompt: PROMPT_WORKER_CLAUDE
)
```

> **Permission note**: Sub-agents inherit the user's permission settings. If Write/Bash permissions are not pre-approved, Worker A will be blocked from editing files and running git commands. In that case, the **orchestrator must handle file writes and commits on Worker A's behalf** after the agent returns its analysis.

`PROMPT_WORKER_CLAUDE` must include an explicit path preamble, for example:

```text
You are Worker A (Claude#2) in a dual-agent collaboration pattern.
Your working directory: /repo/.worktrees/{task-slug}-claude
Work ONLY inside this directory.
```

**Expectations for Claude#2**:
- Work only inside `.worktrees/{task-slug}-claude`.
- Code production: create a clean commit (or a short commit series) on `collab/{task-slug}-claude`.
- Review/analysis: produce `REVIEW.md` at the worktree root; optionally commit for provenance.
- Produce a short self-review (strengths / risks / assumptions).
- If permission-blocked: return the intended file content in the response text so the orchestrator can write it.

#### Worker B: Codex dispatch (separate git worktree + codex exec)

**Preconditions (verify before dispatch):**
1. Default model: `grep '^model' ~/.codex/config.toml` — use this model. Do NOT hardcode `-m` with older models.
2. Trust: `grep '{repo-name}' ~/.codex/config.toml` — must show `trust_level = "trusted"`. If missing, add it.
3. No pipe: do NOT append `| tail`, `| head`, or any pipe to `codex exec` — causes stdout buffering that makes the process appear stuck and output file empty.

```bash
# Run Codex inside the pre-created worktree (MCP is disabled by default in ~/.codex/config.toml; see ADR-019)
cd .worktrees/{task-slug}-codex
codex exec -s workspace-write \
  -c model_reasoning_effort={reasoning_effort} \
  "$PROMPT_WORKER_CODEX"
```

#### Codex exec resilience (timeout, retry, fallback)

**Timeout handling**:
1. At 5 minutes with no output: check process status (`ps aux | grep codex`) and worktree for file changes. If files are being modified, wait.
2. At 10 minutes with no output and no file changes: kill the process and proceed to retry.

**Retry logic** (max 2 retries):
- Retry 1: re-run `codex exec` with a simplified prompt. Remove verbose context, keep only the essential task description and path preamble. Lower reasoning effort by one level (e.g., `high` → `medium`).
- Retry 2: minimal 3-line prompt — path preamble + single-sentence task + "commit when done". Keep reasoning effort at `low`.
- After each retry, wait up to 10 minutes before declaring failure.

**Fallback — Claude#1 takes over Worker B**:
If Codex fails after all retries (2 retries = 3 total attempts), Claude#1 (orchestrator) takes over:
1. Work directly in the Codex worktree (`.worktrees/{task-slug}-codex`).
2. Execute the original task prompt.
3. Commit on `collab/{task-slug}-codex` branch.
4. Proceed to Phase 3 (cross-review) normally.

This guarantees the collab workflow completes even when Codex is unavailable.

`PROMPT_WORKER_CODEX` must include an explicit path preamble, for example:

```text
You are Worker B (Codex) in a dual-agent collaboration pattern.
Your working directory: /repo/.worktrees/{task-slug}-codex
Work ONLY inside this directory.
```

**Expectations for Codex**:
- Work only inside `.worktrees/{task-slug}-codex`.
- Code production: create a clean commit (or a short commit series) on `collab/{task-slug}-codex`.
- Review/analysis: produce `REVIEW.md` at the worktree root; optionally commit for provenance.
- Produce a short self-review (strengths / risks / assumptions).

**Checkpointing (lightweight)**:
- Code production: each worker must commit before cross-review. Treat "commit exists" as the checkpoint.
- Review/analysis: treat "`REVIEW.md` exists" as the checkpoint (committing is optional but recommended).

---

### Phase 3 — Cross Review (Claude#2 ↔ Codex)

**Goal**: Each worker reviews the other's output and produces actionable findings.

**Precondition**: Both workers have committed work on their branches (or produced REVIEW.md for review tasks).

#### Cross-review dispatch

The orchestrator dispatches cross-review as a **new round of concurrent workers**, passing each worker the other's output.

**Step 1**: Collect outputs from Phase 2.

> **Important**: Paste the collected diff/review content directly into the cross-review prompt. Do NOT instruct Codex to read files from another worktree path — this causes excessive reasoning overhead and long delays. Inline the content; do not pass file path references.

For code production tasks:
```bash
git diff --unified=5 main..collab/{task-slug}-claude   # Worker A's changes
git diff --unified=5 main..collab/{task-slug}-codex     # Worker B's changes
```

For review tasks:
```bash
cat .worktrees/{task-slug}-claude/REVIEW.md   # Worker A's review
cat .worktrees/{task-slug}-codex/REVIEW.md    # Worker B's review
```

**Step 2**: Create cross-review worktrees (or reuse existing ones).

```bash
# Option A: Reuse existing worktrees (simpler)
# Workers write CROSS-REVIEW.md in their existing worktree

# Option B: Create dedicated cross-review worktrees (cleaner separation)
git worktree add -b collab/{task-slug}-xreview-claude .worktrees/{task-slug}-xreview-claude
git worktree add -b collab/{task-slug}-xreview-codex .worktrees/{task-slug}-xreview-codex
```

**Step 3**: Dispatch both cross-reviews concurrently.

Worker A cross-reviews Worker B's output:
```text
Agent(
  subagent_type: "general-purpose",
  run_in_background: true,
  prompt: "You are Worker A performing a CROSS-REVIEW.
    Your working directory: /repo/.worktrees/{task-slug}-xreview-claude

    ## Worker B's output to review:
    {paste Worker B's diff or REVIEW.md content here}

    ## Current state for context:
    Read {target files} to check what has already been applied.

    ## Output:
    Create CROSS-REVIEW.md with per-item verdicts (Agree/Disagree/Partially),
    new findings the other worker missed, and overall verdict.
    Then commit."
)
```

Worker B cross-reviews Worker A's output:
```bash
cd .worktrees/{task-slug}-xreview-codex
codex exec -s workspace-write \
  -c model_reasoning_effort={reasoning_effort} \
  "You are Worker B performing a CROSS-REVIEW.
   Worker A's output to review: {paste Worker A's diff or REVIEW.md content}
   Read target files for current state context.
   Create CROSS-REVIEW.md with per-item verdicts and new findings.
   Then commit."
```

#### Cross-review output format

Each worker produces `CROSS-REVIEW.md`:
- **Per-item verdict**: For each issue/suggestion from the other worker: Agree / Disagree / Partially + rationale + whether already addressed
- **New findings**: Issues the other worker missed
- **Overall verdict**: Summary assessment

**Observability**:
- Capture: branch names, commit SHAs, and the exact diff command used.

---

### Phase 4 — Synthesis (Claude#1)

**Goal**: Aggregate outputs + cross-review findings into one best plan, then decide: merge vs re-dispatch.

**Data collection**: The orchestrator reads outputs from well-known file locations:
```
.worktrees/{task-slug}-claude/REVIEW.md          # or branch diff for code tasks
.worktrees/{task-slug}-codex/REVIEW.md            # or branch diff for code tasks
.worktrees/{task-slug}-xreview-claude/CROSS-REVIEW.md
.worktrees/{task-slug}-xreview-codex/CROSS-REVIEW.md
```

If Worker A was permission-blocked, extract content from the agent's response text or output log instead.

**Actions**:
1. Collect:
   - Worker A output + self-review
   - Worker B output + self-review
   - Cross-review findings from both sides (CROSS-REVIEW.md files)
2. Build a comparison table (1 row per key decision area):

```markdown
| Item | Worker A | Worker B | Winner | Decision / Rationale | Merge Action |
|------|----------|----------|--------|----------------------|--------------|
| ... | ... | ... | A/B | ... | cherry-pick / rework |
```

3. Decide:
   - **Merge now** (go to Phase 5) if one solution is clearly superior or the merge is trivial.
   - **Re-dispatch** (go back to Phase 2) if both are incomplete or reviews reveal serious gaps.

---

### Phase 5 — Final Merge (Claude#1)

**Goal**: Merge the best combined result into main, preserve provenance, and clean up worktrees.

**Checklist** (all items required before Phase 5 is complete):
- [ ] Merge: best result merged to main
- [ ] Cleanup: worktrees removed, worker branches deleted
- [ ] Archive: `.collab/{task-slug}.md` created with comparison table, cross-review, decision
- [ ] Observability: final commit SHA and included commits recorded

#### For code production tasks:

```bash
# Option A: merge one winner branch, then cherry-pick best from the other
git checkout main
git merge --no-ff collab/{task-slug}-claude
git cherry-pick <commit-from-collab/{task-slug}-codex>

# Option B: create integration branch and merge both
git checkout -b collab/{task-slug}-integration
git merge --no-ff collab/{task-slug}-claude
git merge --no-ff collab/{task-slug}-codex
```

#### For review tasks:

The orchestrator applies synthesized fixes directly on main — there are no branches to merge.

```bash
# Orchestrator edits target files on main based on synthesis results
# Then commits with collab provenance
git add <modified-files>
git commit -m "Apply collab review findings from {task-slug}"
```

**Cleanup**:

```bash
# Remove worktree directories (only after merge is complete)
git worktree remove .worktrees/{task-slug}-claude
git worktree remove .worktrees/{task-slug}-codex

# Remove cross-review worktrees if created separately
git worktree remove .worktrees/{task-slug}-xreview-claude 2>/dev/null || true
git worktree remove .worktrees/{task-slug}-xreview-codex 2>/dev/null || true

# Delete worker branches
git branch -D collab/{task-slug}-claude collab/{task-slug}-codex 2>/dev/null || true
git branch -D collab/{task-slug}-xreview-claude collab/{task-slug}-xreview-codex 2>/dev/null || true
```

**Archive**:

After merge, save the collaboration record for future reference:

```bash
mkdir -p .collab
cat > .collab/{task-slug}.md << 'ARCHIVE'
# Collab: {task-slug}

## Meta
- Date: {date}
- Branches: collab/{task-slug}-claude, collab/{task-slug}-codex
- Final commit: {sha}

## Task
{original task description}

## Comparison
{comparison table from Phase 4}

## Cross Review Summary
- Worker A findings: {summary}
- Worker B findings: {summary}

## Decision
{merge strategy and rationale}
ARCHIVE
```

**Observability**:
- Record final merged commit SHA and which worker commits were included.
- If deployment is required, run the project's standard deploy workflow after merge.

## Cycle Support

Phases 2-4 can repeat. Common cycle triggers:

- Both outputs miss a constraint or convention
- Cross-review reveals a fundamental design disagreement
- User requests a different approach after seeing Phase 4 synthesis

**Re-dispatch rule**: Keep the original prompt, but append "Feedback to address" with the comparison findings. Each cycle should narrow scope.

## Output Format Examples

### 실행 계획 예시

```markdown
## /collab 실행 계획

### 1) 작업 정의
- 목표: {한 줄 목표}
- 범위: {대상 파일/디렉터리}
- 완료 조건: {체크리스트}
- task-slug: {task-slug}
- 작업 유형: 코드 생산 / 리뷰

### 2) 워커 디스패치
- 사전 준비: 대상 파일 커밋 확인 → Claude#1이 두 worktree 생성
  - `.worktrees/{task-slug}-claude`
  - `.worktrees/{task-slug}-codex`
- Worker A(Claude#2): 명시적 경로 지시 + 백그라운드 실행
- Worker B(Codex): 명시적 경로 지시 + codex exec

### 3) 교차 리뷰
- 양쪽 출력 수집 (REVIEW.md 또는 branch diff)
- 교차 리뷰 worktree 생성 (또는 기존 재사용)
- A → B 출력 리뷰: CROSS-REVIEW.md 생성
- B → A 출력 리뷰: CROSS-REVIEW.md 생성

### 4) 합성(Synthesis)
- CROSS-REVIEW.md 수집
- 비교표 작성 후 "병합" 또는 "재디스패치" 결정

### 5) 최종 병합
- main에 반영, worktree 정리, 필요 시 배포
```

### 리뷰 비교 테이블 예시

```markdown
| 항목 | Worker A | Worker B | 판정 | 근거 |
|------|----------|----------|------|------|
| ADR-017 준수 | 한국어 혼용 | 영어 준수 | B | 컨벤션 위반 |
| Idempotency | 없음 | 명시적 | B | 반복 실행 안전 |
| No-op 정책 | 명시적 | 없음 | A | 불필요한 수정 방지 |
```

### 아카이브 예시

```markdown
.collab/
└── rename-skill.md    # 협업 기록: 작업 요약, 비교표, 리뷰, 결정 근거

# 예시: .collab/rename-skill.md

# Collab: rename-skill

## Meta
- Date: 2026-03-06
- Branches: collab/rename-skill-claude, collab/rename-skill-codex
- Final commit: abc1234

## Task
스킬 파일명을 snake_case에서 kebab-case로 변경

## Comparison
| 항목 | Worker A | Worker B | 판정 | 근거 |
|------|----------|----------|------|------|
| 파일명 변환 | 수동 mv | 스크립트 | B | 반복 가능 |
| import 업데이트 | 누락 | 완료 | B | 깨진 참조 방지 |

## Cross Review Summary
- Worker A findings: Worker B의 스크립트 방식이 재현 가능하고 안전
- Worker B findings: Worker A가 README 업데이트를 포함한 점이 우수

## Decision
Worker B 기반 병합 + Worker A의 README 변경 cherry-pick
```

## Notes

- Claude#1 must create both worker worktrees before dispatching either worker.
- **All target files must be committed to HEAD** before worktree creation — uncommitted changes are not visible in worktrees.
- Do not use Agent `isolation: "worktree"` in this pattern; pass explicit working-directory instructions to Claude#2.
- Cross-review is the key differentiator; skipping it removes most of the pattern's value.
- **Cross-review must be dispatched explicitly** as a new round of concurrent workers with the other's output embedded in the prompt.
- Prefer `run_in_background: true` for Claude#2 so both workers run truly concurrently.
- **Worker A permission fallback**: If Claude#2 is blocked on Write/Bash permissions, the orchestrator must write files and run git commands on its behalf using the agent's response content.
- This pattern maximizes state consistency by avoiding shared mutable state: each worker edits only its own worktree.
- Keep task content identical across workers; only path preambles should differ.
- If workers disagree, prefer objective criteria (tests, lints, reproducibility) over stylistic preference.
- Clean up worktrees after merge to avoid git worktree clutter. Use `git branch -D` (force) instead of `-d` because worker branches are typically not merged via `git merge` and will appear unmerged.
- The `{task-slug}` naming convention ensures multiple concurrent collab sessions do not collide.
- This is v1.4.0. Changes from v1.3.0: added explicit invocation-only rule, Codex exec retry/timeout/fallback resilience, Claude#1 fallback for Worker B failure.

## References

- [ADR-013: A2A Parallel and Distributed Execution Model](../../agent-context/decisions/2026-01-15-a2a-parallel-distributed-model.md)
- [ADR-017: Skill Authoring Conventions](../../agent-context/decisions/2026-02-26-skill-authoring-conventions-and-auto-loading.md)
- [ADR-020: Harness Engineering Adoption](../../agent-context/decisions/2026-03-10-harness-engineering-adoption.md)
