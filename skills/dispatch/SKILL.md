---
name: dispatch
version: 0.3.2
description: >
  Create a scoped sibling-session work item by sending a dispatch request
  to the Global Session Orchestrator. The orchestrator then drives
  scripts/conductor.sh on your behalf, so this skill stays a thin client
  with no direct spawn or git-worktree logic.
trigger_phrases:
  - "/dispatch"
  - "dispatch"
  - "작업 분기"
  - "사이드퀘스트 넘겨"
  - "새 슬롯으로 보내"
output_dir: "~/.claude/orchestrator"
---

# Dispatch — Orchestrator-mediated Sibling Session Launch

## ACP Integration

> 이 스킬은 AGENTS.md의 ACP 규칙을 준수합니다.

## Purpose

`/dispatch` is a thin client for the Global Session Orchestrator. The user
types a free-form task description, the skill derives slug + worker
deterministically, and **asks the user to pick the execution mode**
(fire-and-forget vs interactive). The mode answer doubles as the go
signal — the skill executes immediately via `orchestrator_request --type
dispatch`. There is no dry-run round trip and no separate y/n confirmation.

**Invocation model**: This skill is **agent-invoked only**. There is no
user-runnable CLI form of `/dispatch` — when the user types `/dispatch X`
in chat or mentions "/dispatch" mid-conversation, the active agent
executes the skill. Treat any sentence implying "the user will dispatch
separately" (e.g., elided-subject Korean like "/dispatch 해서 별도로
진행") as a request for the agent to invoke the skill now, not as a
delegation to a non-existent user-side path.
Worktree is **always created** — dispatch execute mandates an isolated
worktree (see `scripts/conductor.sh:781`); the only exception is `ghost-*`
session archives, which this skill does not produce.

Use this skill when:

- The current session must keep running while a sibling claude or codex
  session picks up a bounded scoped task
- You want the dispatch to be recorded in the global orchestrator state so
  later cross-session visibility (`status`, `daily`) sees it

Do not use this skill for:

- Full session handoff (use `/handoff` instead)
- Same-task dual-agent cross review (use `/collab`)
- Long-running unrelated work on the base slot (use the base slot directly)

## Non-negotiable Requirements

- The orchestrator agent MUST be running before the skill sends a request.
  If it is not, the skill reports this and suggests
  `bash ~/.orchestrator/scripts/orchestrator/start-agent.sh --execute`.
- Slug must be lowercase kebab-case, max 32 characters, not a reserved name
  (`base`, `main`, `master`, `head`, `origin`). If the skill auto-generates
  a slug from the description, the same rules apply.
- **Mode is asked only when not derivable from user input** — if the
  user's request already encodes the mode, skip the prompt and execute
  immediately with a one-line status update ("Proceeding fire-and-forget
  per `keep_alive: false`"). Derivation triggers:
  - `keep_alive: false` / "fire-and-forget" / "ff" / "FF" → mode=FF
  - `keep_alive: true` / "interactive" / "keep alive" / "keep-alive" → mode=interactive
  When no mode signal is present, fall back to the explicit prompt below
  (presents derived slug + worker as fixed, asks the user to pick mode).
  The mode answer is the go signal; no separate y/n confirmation follows.
- **Worker is inferred, not asked** — defaults to `claude`; chosen as
  `codex` only when the description explicitly names codex. The user can
  override inline (e.g., "codex로") in the same mode-selection reply.
- **Worktree is always yes** — the skill never offers worktree as a knob
  because `conductor.sh` rejects `no_worktree: true` for dispatch execute
  (only `ghost-*` slugs are exempt, and those are produced by rotation,
  not by this skill).
- Execute directly on approval — no intermediate `dry_run: true` request.
  Conflict detection (slug already in use, slot collision) is performed by
  the orchestrator's plan stage and surfaced as an error before effects.
- Keep the base slot untouched. The orchestrator refuses any dispatch that
  targets `claude-orchestrator-global` or a project base slot.

## Workflow

### Step 1 — Parse input

- Accept free-form input: `/dispatch <description>`
- Accept optional explicit overrides (skill-resolved, not re-asked):
  `--slug <slug>`, `--worker claude|codex`, `--keep-alive`
- Extract description text (everything after the trigger, minus recognized flags).
- Do NOT accept `--no-worktree` — worktree is mandatory for dispatch execute.

### Step 2 — Verify orchestrator is alive

Run:

```bash
bash ~/.orchestrator/scripts/orchestrator/health.sh
```

If the exit code is non-zero (`status=dead` or `status=unresponsive`), stop
and tell the user to start the orchestrator with:

```bash
bash ~/.orchestrator/scripts/orchestrator/start-agent.sh --execute
```

Do not auto-start the orchestrator from this skill. Starting the orchestrator
is a user-visible event.

### Step 3 — Derive slug + worker, then ask for mode (if needed)

**Worker inference** (deterministic, not asked) — `claude` by default.
Pick `codex` only when the description **explicitly mentions codex**
(e.g., "codex로", "codex를 시켜", "use codex", "gpt-5", "openai로"). Do
not infer codex from task-shape keywords; those do not imply codex.

**Slug derivation** — take the first 3–5 descriptive nouns from the
description, lowercase, kebab-joined, trimmed to 32 chars. If the result
is ambiguous or collides with reserved names, surface it in the prompt
so the user can override.

**Mode derivation (before prompting)** — scan the user's request for
mode signals before deciding whether to ask:

| Signal in user input | Mode |
|---|---|
| `keep_alive: false` / "fire-and-forget" / "ff" / "FF" | fire-and-forget |
| `keep_alive: true` / "interactive" / "keep alive" / "keep-alive" | interactive |
| No mode signal | ask the user (prompt below) |

When mode is derived, **skip the prompt entirely** and execute
immediately with a one-line status update before the request:

```
Proceeding fire-and-forget per `keep_alive: false`.
- Slug: {slug}
- Worker: {claude|codex}
```

The user can still abort by interrupting the run; this is faster than a
mandatory prompt when the request was already explicit.

**Mode selection prompt** (Korean, only when not derived) — show the
derived values and ask for mode. The mode answer is the execute go
signal; do NOT require a separate "y" afterward.

```
Dispatch 준비 완료 — 모드 선택 시 즉시 실행됩니다.

- Slug: {slug}
- Worker: {claude|codex}
- Description: "{first 120 chars of description}..."

(Worktree는 dispatch 정책상 항상 생성됩니다.)

모드를 선택해주세요:
  1) fire-and-forget — worker가 작업 후 자동 종료
  2) interactive — worker가 keep_alive, 계속 대화 가능

답: 1 / 2  (또는 변경사항, 예: "codex로", "slug=xyz", "cancel")
```

Parse the reply:
- `1` / `ff` / `fire` / `fire-and-forget` → mode=FF, **execute immediately**
- `2` / `i` / `interactive` → mode=interactive (keep_alive=true), **execute immediately**
- Free-form correction (e.g., "codex로", "slug=new-name") → apply change,
  re-show the prompt once, wait for mode answer
- `n` / `cancel` / `아니` → abort, do not send request

### Step 4 — Execute on approval

Source `protocol.sh` in a bash subshell and use `build_dispatch_payload`
to construct the payload. The builder emits the `description` as a YAML
block scalar, which the conductor's `parse_request_file` reassembles
back into the original multi-line text — never substitute a multi-line
`<description>` into a raw `- description: %s` template, as that path
truncates to the first line.

```bash
bash -c '
  . ~/.orchestrator/scripts/orchestrator/protocol.sh
  payload="$(build_dispatch_payload \
    --slug "<slug>" \
    --description "<description>" \
    --worker-family "<claude|codex>" \
    <optional: --keep-alive>)"
  orchestrator_request --type dispatch --slug "<slug>" --timeout 180 --payload "## Payload
${payload}
"
'
```

Pass `--keep-alive` only when mode=interactive. The builder omits
optional flags whose values are unset and always emits `dry_run: false`
implicitly (omits the field; conductor defaults to execute).

Omit `no_worktree` from the payload entirely — conductor defaults to
creating a worktree, and passing `no_worktree: true` would be rejected
with `--no-worktree is disabled for execute`.

The orchestrator runs `conductor.sh dispatch --execute` and returns the
execute output. Exit codes from `orchestrator_request`:

- 0 = ok, task dispatched successfully
- 1 = orchestrator not running (shouldn't happen after Step 2)
- 2 = timeout (orchestrator did not respond within 180 seconds)
- 3 = orchestrator returned `status: error` — may include `conflict: slug-exists`
  or `conflict: slot-taken`; report and suggest a different slug
- 4 = protocol error (schema mismatch, IO failure)

If rc=3 with a conflict, surface the conflict to the user and offer to
retry with a new slug (single follow-up prompt, no new confirmation round).

### Step 5 — Report to the user

Display the final Result section. For a successful dispatch:

- New slot name (e.g. `claude-agent-framework-<slug>-1`)
- Surface id
- Worktree path (if worktree was created)
- Work item path (where the delegated brief was written)
- Done-report path (where the sibling will self-report completion)

Remind the user that the sibling runs independently. When the worker's
agent process exits, an **EXIT trap** runs `auto-done.sh` automatically
to close the cmux surface and kill the zmx session. The git worktree
and branch are preserved for inspection and can be cleaned up later
with `conductor.sh tidy [--execute]`.

## Output Format

Mode selection (before execute):

```markdown
Dispatch 준비 완료 — 모드 선택 시 즉시 실행됩니다.

- Slug: collab-retry-probe
- Worker: claude
- Description: "/collab Phase 2a를 재시도해서 3-layer health가 정상 동작하는지 검증..."

(Worktree는 dispatch 정책상 항상 생성됩니다.)

모드를 선택해주세요:
  1) fire-and-forget — worker가 작업 후 자동 종료
  2) interactive — worker가 keep_alive, 계속 대화 가능

답: 1 / 2  (또는 변경사항, 예: "codex로", "slug=xyz")
```

On execute success:

```markdown
## Dispatch 실행 완료

- 슬롯: {slot_name} (pid {pid})
- Surface: {surface_id}
- Worktree: {worktree_path}
- 작업 파일: {work_item_path}
- Done: sibling 종료 시 EXIT trap이 surface/zmx 자동 정리. worktree는 보존되며 `conductor.sh tidy`로 정리
```

### Promote when done

After the sibling commits its work (the `turn-end-wip-commit.sh` Stop
hook auto-commits each turn as `wip(<slug>): ...`), integrate the worker
branch into the base session's current branch:

```bash
./scripts/agent-promote.sh <slug>
```

Defaults: `--squash` merge into the current branch with `wip(<slug>)`
commits collapsed, a risk scan over changed files (`.env`, `*.key`,
`id_rsa*`, `*.log`, `.DS_Store`, files > 1 MB), and refusal when the
base working tree is dirty.

Common flags:

- `--dry-run` — preview the plan; no mutations
- `--cleanup` — delete the worker branch and worktree after the merge
- `--no-ff` — preserve worker history instead of squashing
- `--branch <name>` — disambiguate when the slug matches multiple
  worker branches (e.g., a `/collab` slug producing both
  `dispatch/<slug>-claude-1` and `dispatch/<slug>-codex-1`)

Cherry-pick is **not** the routine path — `guard-cherry-pick.sh` emits a
warning on bare `git cherry-pick`. Use `agent-promote.sh` for ordinary
dispatch integration; reserve cherry-pick for `/collab` synthesis,
selective hotfix, or recovery (`--abort` / `--continue` / `--skip`).

On orchestrator error:

```markdown
## Dispatch 실패

- 원인: {error message from orchestrator Error section}
- 권장: {next action — retry with different slug, check orchestrator logs, restart agent}
```

## Relationship to other skills

- **`/handoff` / `/takeover`**: per-session lifecycle; do not route through
  orchestrator. Local file operations only.
- **auto-done (EXIT trap)**: the sibling's cmux surface and zmx session are
  automatically cleaned up when the agent process exits — no manual `done`
  call required.
- **`conductor.sh tidy`**: run `conductor.sh tidy [--execute]` to remove
  worktrees and branches for finished workers. Resource-based — safe to
  run anytime; skips live workers.
- **`/collab`**: same-task dual-agent flow with independent workers.
  Retains its own confirmation flow because the two-worker + merge shape
  benefits from explicit plan preview; `/dispatch` does not.

## Notes

- The skill deliberately refuses to auto-start the orchestrator. Keeping
  the start action explicit makes ownership of the long-lived session visible.
- Inference rules are heuristics. When the description is ambiguous, the
  single confirmation prompt is the safety net — the user corrects in one
  reply and execution proceeds.
- Previous versions (0.2.x) required a dry-run round trip. That step was
  removed in 0.3.0 because explicit `/dispatch` invocations are by definition
  intentional; the conflict-detection it provided is preserved via the
  orchestrator's plan stage.
- 0.3.1 removed the worktree toggle (was misleading — `conductor.sh` rejects
  `no_worktree: true` for dispatch execute). Worker inference also tightened:
  `claude` is always the default; `codex` is chosen only when the description
  explicitly mentions codex by name.
- 0.3.2 removed mode inference — the fire-and-forget vs interactive choice
  is now asked explicitly (plan-mode style). The mode answer doubles as
  the execute go signal, so there is no separate y/n confirmation. Slug +
  worker are still derived silently; the user can override inline in the
  mode-selection reply.
