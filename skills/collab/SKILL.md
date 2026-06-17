---
name: collab
version: 4.0.0
description: >
  Orchestrate dual-agent collaboration (Claude worker + Codex worker) on
  the same task by spawning two sib siblings, each in its own git
  worktree. The skill drives cross-review, synthesis, and merge in the
  caller's session. v4.0.0: promoted to L1 baseline; merge uses L1's
  agent-promote.sh; ADR references generalized.
trigger_phrases:
  - "/collab"
  - "collab"
  - "협업 모드"
  - "같이 작업해"
  - "듀얼 에이전트"
  - "병렬 실행"
  - "cross review"
  - "동시 작업"
output_dir: "~/.local/share/sib"
---

# Collab — Dual-Agent Same-Task Cross-Review (on sib)

## ACP Integration

> 이 스킬은 AGENTS.md의 ACP 규칙을 준수합니다.

- Follows the **Dual-Agent Worktree Review** pattern: two independent
  workers solve the same task in isolated worktrees, then cross-review.
- Follows the L1 language convention: English for workflow/notes, Korean
  only for trigger phrases and output format examples.
- No orchestrator daemon: collab drives sib directly (`sib spawn`,
  `sib send`, `sib kill`).
- When new constraints or architecture decisions are discovered during
  orchestration, record them via `/acp-constraint` or `/acp-decision`
  (do not edit `agent-context/` directly).

## Purpose

Run two independent workers concurrently (Claude and Codex) on the **same task**
inside **dedicated git worktrees**, then use **cross-review** and **synthesis**
to merge the best result to the main branch with clear provenance.

The skill is a thin orchestrator written in markdown — it spawns two
sib siblings with `--worktree` (each gets its own branch), polls for
commits, injects a cross-review prompt into each, then synthesizes and
merges. All session lifecycle is driven by `sib` directly; there is no
daemon mediating requests.

## When to Use

Use `/collab` when:
- The task has enough ambiguity or surface area that two independent solutions will likely differ in quality.
- You want higher confidence through adversarial comparison (cross-review), not just faster output.
- You need strong provenance (two branches + commits + review notes) for auditability.

Avoid `/collab` when:
- The task is tiny (a few-line change) where orchestration overhead dominates — use `/dispatch` or just do it in the base session.
- The task requires shared mutable state — the pattern assumes dedicated worktrees.

**Invocation rule**: `/collab` must only activate on an explicit user command
(`/collab` or a trigger phrase). The agent must NEVER auto-initiate the collab
workflow based on its own assessment of task suitability.

## Task Type Variants

Identify the type in Phase 1 and follow the matching flow:

- **Code production (default)**: workers edit & commit → cross-review via diff → merge best result.
- **Review / analysis**: workers produce `REVIEW.md` → cross-review evaluates findings → synthesis applies fixes to main (no branch merge).

## Non-negotiable Requirements

- Base slug must be lowercase kebab-case, **max 28 chars** (the two
  worker slugs are `<base>-claude` and `<base>-codex`; a 28-char base
  leaves room for the longest suffix).
- Both `sib spawn` calls must pass `--worktree` — that is the entire
  reason `/collab` exists on top of `/dispatch`. Forgetting it makes
  the two workers fight over the same checkout.
- Every first call is a **dry-run preview** (default). The skill writes
  out the two planned `sib spawn` invocations to the user, and only
  proceeds after explicit approval. Dry-run is skipped only when the
  user has already given a go-signal in the same turn (see Phase 2 table).
- Both worker panes are created in the caller's cmux workspace. The
  caller must be running inside a cmux pane (`$CMUX_WORKSPACE_ID` set).
- Slug collision: if `<base>-claude.env` or `<base>-codex.env` already
  exists in `~/.local/share/sib/state/`, fail with the existing-slug
  message and ask the user to pick a different base.

## Workflow

### Phase 1 — Task Plan (caller session)

**Goal**: Define scope and produce one identical task brief for both workers.

**Actions**:

1. Choose a short, descriptive `base_slug` (e.g., `rename-skill`, `add-tests`,
   `fix-auth`). Must be ≤28 chars.
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
   dispatch — sib worktrees branch from HEAD, and uncommitted changes
   on the caller branch will NOT be visible to workers. Commit first if
   needed:

   ```bash
   git add <target-files> && git commit -m "WIP: stage files for collab"
   ```

**Outputs**: `base_slug`, task description (identical for both workers),
task type, reasoning effort level.

### Phase 2 — Spawn both workers

**Goal**: Launch two sib siblings in dedicated worktrees, one per family.

**Step 2a — Environment check**:

```bash
[[ -n "$CMUX_WORKSPACE_ID" ]] || { echo "/collab must run inside a cmux pane"; exit 1; }
command -v sib >/dev/null || { echo "sib not on PATH (expected ~/.local/bin/sib)"; exit 1; }
```

**Step 2b — Dry-run preview (default ON)**:

`/collab` has a larger blast radius than `/dispatch` (two long-lived
panes, two branches, two worktrees), so dry-run is the default. Skip
2b only when the user gave an explicit go-signal in the same turn:

| Trigger | Action |
|---|---|
| User said "dry-run" / "preview" / "plan 먼저" / "확인하고" / "검토 먼저" | run 2b, ask `Proceed? (y/n)` |
| Ambiguous — first-time pattern, large blast radius, unclear acceptance criteria | run 2b, ask |
| User gave full /collab spec (slug + description) and said "진행" / "수행해" / "바로" / "execute" / "go" | **skip 2b, go straight to 2c** |
| User invoked /collab after a prior planning turn the agent already echoed back | **skip 2b** (plan was already reviewed) |

Dry-run output to show the user (do NOT execute):

```markdown
## /collab dry-run

### Worker A — Claude
sib spawn "<base_slug>-claude" --worktree -- "<task description>"

### Worker B — Codex (reasoning=<effort>)
sib spawn "<base_slug>-codex" --codex --worktree -- "<task description>"

Worktrees:
  ~/.local/share/sib/worktrees/<repo>-<base_slug>-claude  (branch sib/<base_slug>-claude)
  ~/.local/share/sib/worktrees/<repo>-<base_slug>-codex   (branch sib/<base_slug>-codex)

Proceed? (y/n)
```

**Step 2c — Execute** (default path, or after `y` on 2b):

```bash
# Worker A — Claude
sib spawn "<base_slug>-claude" --worktree -- "<task description>"

# Worker B — Codex
sib spawn "<base_slug>-codex" --codex --worktree -- "<task description>"
```

Each call:

1. Creates `~/.local/share/sib/worktrees/<repo>-<base_slug>-<family>`
   from `HEAD` (branch `sib/<base_slug>-<family>`)
2. Opens a new cmux pane (right split of the caller's workspace)
3. Boots the agent in that worktree and sends the task as the first
   message

Sib prints a one-line summary per spawn (slug, agent, surface,
worktree). Capture the worktree path from each output for Phase 3
polling.

If the **second** spawn fails (e.g. cmux pane creation hits a state
issue) after the **first** succeeded, decide before retrying: tear
down the first via `sib kill <base_slug>-claude` and start over, or
continue as a single-worker fallback (collab degrades to a
single-agent dispatch, no cross-review).

### Phase 3 — Cross Review

**Goal**: Each worker reviews the other's output and produces actionable findings.

**Precondition**: Both workers have committed their work (code production) or
produced `REVIEW.md` at the worktree root (review task). Poll until both
conditions hold:

```bash
# Code production: wait for commit on each worker branch
while [ -z "$(git -C ~/.local/share/sib/worktrees/<repo>-<base_slug>-claude log --oneline HEAD ^sib/<base_slug>-claude~0 2>/dev/null)" ]; do
  sleep 10
done
# (equivalent for codex)

# Review task: wait for REVIEW.md file
while [ ! -f "~/.local/share/sib/worktrees/<repo>-<base_slug>-claude/REVIEW.md" ]; do sleep 10; done
while [ ! -f "~/.local/share/sib/worktrees/<repo>-<base_slug>-codex/REVIEW.md" ]; do sleep 10; done
```

Timeout: 10 minutes per worker. If no progress, inspect the sibling
pane directly (`cmux read-screen --surface <surface> --workspace <ws>`)
to diagnose. Surface and workspace IDs are recorded in
`~/.local/share/sib/state/<slug>.env`.

**Step 3a — Collect outputs**:

```bash
# Code production
git -C ~/.local/share/sib/worktrees/<repo>-<base_slug>-claude diff --unified=5 HEAD^..HEAD > /tmp/<base_slug>-claude.diff
git -C ~/.local/share/sib/worktrees/<repo>-<base_slug>-codex  diff --unified=5 HEAD^..HEAD > /tmp/<base_slug>-codex.diff

# Review task
cp ~/.local/share/sib/worktrees/<repo>-<base_slug>-claude/REVIEW.md /tmp/<base_slug>-claude.review.md
cp ~/.local/share/sib/worktrees/<repo>-<base_slug>-codex/REVIEW.md  /tmp/<base_slug>-codex.review.md
```

> **Important**: Paste the collected diff/review content directly into
> the cross-review prompts. Do NOT instruct workers to read files from
> the other worktree — it adds reasoning overhead and pulls in
> unrelated history.

**Step 3b — Inject cross-review into existing workers**:

Workers from Phase 2 are still alive in their panes with full task
context. Reuse them with `sib send`, which pastes the prompt into the
agent's input box:

```bash
CLAUDE_XR_PROMPT='CROSS-REVIEW round. Worker B (Codex) produced this diff
(commit your verdict as CROSS-REVIEW.md in your worktree then commit):

<paste contents of /tmp/<base_slug>-codex.diff>

Produce CROSS-REVIEW.md with per-item verdicts (Agree/Disagree/Partially),
new findings, and overall verdict. Then:
  git add CROSS-REVIEW.md && git commit -m "cross-review: <base_slug>"'

CODEX_XR_PROMPT='CROSS-REVIEW round. Worker A (Claude) produced this diff
(commit your verdict as CROSS-REVIEW.md in your worktree then commit):

<paste contents of /tmp/<base_slug>-claude.diff>

Produce CROSS-REVIEW.md with per-item verdicts (Agree/Disagree/Partially),
new findings, and overall verdict. Then:
  git add CROSS-REVIEW.md && git commit -m "cross-review: <base_slug>"'

sib send "<base_slug>-claude" "$CLAUDE_XR_PROMPT"
sib send "<base_slug>-codex"  "$CODEX_XR_PROMPT"
```

Two workers total for the whole collab (not four). Each worker keeps
its task context, worktree, and Phase 2 output — `sib send` continues
the same agent session with new input.

Poll for the CROSS-REVIEW.md commit on each worker's branch (or file
existence in the worktree):

```bash
while [ ! -f "~/.local/share/sib/worktrees/<repo>-<base_slug>-claude/CROSS-REVIEW.md" ]; do sleep 10; done
while [ ! -f "~/.local/share/sib/worktrees/<repo>-<base_slug>-codex/CROSS-REVIEW.md" ]; do sleep 10; done
```

Then read both `CROSS-REVIEW.md` files from the worktrees.

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
- [ ] Best result merged to the caller branch
- [ ] Both worker panes ended (sib kill on each, which also removes
      worktrees + branches since they were spawned with `--worktree`)
- [ ] Archive saved under `.collab/<base_slug>.md`
- [ ] Final commit SHA recorded

**Code production merge**:

Use `agent-promote.sh` (L1, `bin/agent-promote.sh`, on PATH after L1
install — symlinked to `~/.local/bin/` like sib) for both worker
branches. It squashes
each worker's `wip(<slug>)` commits, runs a risk scan, and squash-merges
into the current branch. It resolves the worker branch by slug
(`sib/<slug>`).

When one worker is clearly best (synthesis chose its diff wholesale):

```bash
agent-promote.sh <base_slug>-claude --cleanup
# or:
agent-promote.sh <base_slug>-codex --cleanup
```

When synthesis blends both — promote the chosen "base" worker first,
then layer the second worker's specific commits via cherry-pick. This
is the legitimate cherry-pick use case the guard hook still allows;
prefix with `CHERRY_PICK_OK=1` to silence the warning:

```bash
agent-promote.sh <base_slug>-claude
CHERRY_PICK_OK=1 git cherry-pick <commit-from-codex-branch>
agent-promote.sh <base_slug>-codex --cleanup   # optional, only if anything
                                                # else in that branch is worth
                                                # landing
```

To preserve the worker's commit history instead of squashing, pass
`--no-ff` to `agent-promote.sh`. The merge commit's message embeds the
worker branch name for provenance.

**Review task merge**: apply synthesized fixes directly to main files, then
commit with collab provenance.

**Clean up both worker panes**:

```bash
sib kill <base_slug>-claude
sib kill <base_slug>-codex
```

Each `sib kill` closes the cmux pane (ending the agent process) and,
because the workers were spawned with `--worktree`, also removes the
worktree directory and deletes the `sib/<base_slug>-<family>` branch.
Pass `--keep-worktree` if you want to retain the worktree for
inspection.

If `agent-promote.sh --cleanup` was already used per worker, the
worktree + branch are gone; `sib kill` then only needs to close the
pane (it tolerates a missing worktree).

**Archive**:

```bash
mkdir -p .collab
cat > .collab/<base_slug>.md << 'ARCHIVE'
# Collab: <base_slug>

## Meta
- Date: <date>
- Worker branches: sib/<base_slug>-claude, sib/<base_slug>-codex
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

### 2) 두 워커 spawn (sib --worktree)
- 사전 확인: cmux 안, sib on PATH, 대상 파일 커밋됨
- dry-run preview → 사용자 승인 → execute
- 결과: 두 워커 (Claude#A, Codex#B) 각자 worktree에서 작업 시작

### 3) 교차 리뷰
- 양쪽 출력 수집 (diff 또는 REVIEW.md)
- 각 워커에 sib send 로 cross-review 프롬프트 주입
- CROSS-REVIEW.md 완료 대기

### 4) 합성(Synthesis)
- 비교표 작성 후 "병합" 또는 "재실행" 결정

### 5) 최종 병합 + 정리
- 선택한 워커 branch를 agent-promote.sh 로 caller branch에 squash-merge
- sib kill <base_slug>-claude / <base_slug>-codex (worktree + branch 정리)
- .collab/{base_slug}.md 아카이브
```

### 비교 테이블 예시

```markdown
| 항목 | Worker A (Claude) | Worker B (Codex) | 판정 | 근거 |
|------|-------------------|------------------|------|------|
| 컨벤션 준수 | 한국어 혼용 | 영어 준수 | B | 컨벤션 위반 |
| Idempotency | 없음 | 명시적 | B | 반복 실행 안전 |
| No-op 정책 | 명시적 | 없음 | A | 불필요한 수정 방지 |
```

## Relationship to other skills

- **`/dispatch`**: single-agent sibling spawn — shares the caller's
  working tree, no worktree. Use `/dispatch` for routine side quests
  and `/collab` only when two independent attempts add value.
- **`sib spawn --worktree`**: the underlying primitive `/collab` runs
  twice. Each call gives a worker its own branch and working dir.
- **`sib send <slug>`**: how Phase 3 injects the cross-review prompt
  into an existing worker pane.
- **`sib kill <slug>`**: how Phase 5 closes a worker (with the
  `--worktree` spawn flag set, also removes the worktree + branch).
- **`agent-promote.sh`** (L1 `bin/`, on PATH): integrates a worker
  branch into the caller branch (squash-merge with risk scan). Required
  for collab code-production merges.
- **`turn-end-wip-commit.sh`** (L1 Stop hook): auto-commits each turn's
  work inside a worker worktree so agent-promote has clean commits to
  squash. Recognizes `sib/<slug>` branches.
- **agentmemory `SessionStart` / `Stop` hooks**: session continuity is
  handled out-of-band. collab does not need to coordinate — workers in
  spawned worktrees pick up agentmemory automatically.

## Notes

- This is v4.0.0. Changes from v3.0.0:
  - **Promoted to L1 baseline.** collab + its merge dependency
    (`bin/agent-promote.sh`) + the supporting Stop/cherry-pick hooks now
    live in `agent-framework` (L1), available in every persona instead
    of one workspace.
  - ADR cross-references generalized to prose (the L1 baseline does not
    carry the persona ADRs collab was originally filed under).
  - `agent-promote.sh` invoked by name (L1 install symlinks it onto PATH
    via `~/.local/bin/`, like sib).
- v3.0.0 (retained): orchestrator daemon retired — `sib spawn`,
  `sib send`, `sib kill` drive everything; `--worktree` mandatory for
  both workers; cross-review injection via `sib send`; cleanup via
  `sib kill`.
- Workers run in full sibling sessions with their own permission
  contexts, not as Agent tool sub-agents.
- Cross-review is the key differentiator of this pattern; skipping it
  removes most of the value.
- Keep task content identical across Phase 2 workers. Phase 3 prompts
  intentionally differ because each worker reviews the other's output.
- Clean up worktrees after merge to avoid git worktree clutter.
  `sib kill <slug>` handles this when the worker was spawned with
  `--worktree`.
