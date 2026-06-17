---
name: dispatch
version: 0.6.0
description: >
  Spawn a scoped sibling agent session via `sib` (cmux pane, shared
  working tree — no worktree by default), placing it in the workspace
  that matches the task's working directory. The skill derives slug +
  worker, resolves the target workspace, and executes on mode selection.
  v0.6.0: workspace targeting — find/create the right workspace instead
  of always splitting the caller's pane. dispatch = single-agent branch
  sharing; for dual-agent isolated work, use /collab.
trigger_phrases:
  - "/dispatch"
  - "dispatch"
  - "작업 분기"
  - "사이드퀘스트 넘겨"
  - "새 슬롯으로 보내"
output_dir: "~/.local/share/sib"
---

# Dispatch — sib-based Sibling Session Launch

## ACP Integration

> 이 스킬은 AGENTS.md의 ACP 규칙을 준수합니다.

When new constraints or architecture decisions are discovered during
dispatch, record them via `/acp-constraint` or `/acp-decision` (do not
edit `agent-context/` directly).

## Purpose

`/dispatch` spawns a sibling cmux pane that runs Claude (or Codex). The
sibling picks up a bounded, free-form task and the base session keeps
running. By default the sibling shares the caller's working directory
(no worktree, no branch), but it is placed in **the workspace whose cwd
matches the task** — not blindly split into the caller's current pane.

**Invocation model**: agent-invoked only. There is no user-runnable CLI
form — when the user types `/dispatch X` in chat, the active agent
executes this skill. Treat elided-subject Korean (e.g., `/dispatch 해서
별도로 진행`) as a request to invoke the skill now, not a delegation to
a non-existent user-side path.

**Backend**: `bin/sib` (L1, deployed to `~/.local/bin/sib`). `/dispatch`
uses sib's default — no worktree, because the dispatched sibling is still
*one* agent doing the work. Worktree isolation is a /collab concern (two
agents same task), not a dispatch concern.

Use this skill when:

- The current session must keep running while a sibling agent picks up a
  bounded scoped task
- The work is single-agent — one sibling continues from the same
  working tree without competing with the base session

Do not use this skill for:

- Full session handoff — session continuity is auto-handled by
  agentmemory's `SessionStart` / `Stop` hooks. There is no replacement
  command to call.
- Same-task dual-agent cross review (use `/collab` — that pattern owns
  the worktree-isolation requirement)
- Long-running unrelated work on the base slot (use the base slot directly)

## Non-negotiable Requirements

- Must run from inside a cmux pane (`$CMUX_WORKSPACE_ID` set). `sib spawn`
  refuses without it.
- Slug must be lowercase kebab-case (`[a-z0-9-]+`). sib enforces this.
- The base slot is not a target — `/dispatch` always creates a NEW
  cmux pane via `sib spawn`, never injects into the base.
- **Never split an unrelated workspace.** If the task's working directory
  differs from a candidate workspace's cwd, do not place the sibling
  there. Resolve the target workspace explicitly (Step 3) before spawning.
- Do not pass `--worktree` to sib — that's reserved for /collab. A
  dispatched sibling shares the target directory's working tree.

## Workflow

### Step 1 — Parse input

- Accept free-form input: `/dispatch <description>`
- Optional explicit overrides: `--slug <slug>`, `--worker claude|codex`,
  `--workdir <path>` (force the working directory), `--keep-alive`
  (advisory; sib panes persist until the user closes them)
- Extract description text (everything after the trigger, minus flags)

### Step 2 — Verify environment

```bash
[[ -n "$CMUX_WORKSPACE_ID" ]] || { echo "/dispatch must run inside a cmux pane"; exit 1; }
command -v sib >/dev/null || { echo "sib not found on PATH (expected ~/.local/bin/sib)"; exit 1; }
```

If either check fails, surface the error and stop.

### Step 3 — Resolve the target workdir + workspace

This is the core of v0.6.0. A sibling must start where the work lives,
not wherever the caller happens to be.

**3a — Determine the workdir.** In priority order:

1. Explicit `--workdir <path>` from the user.
2. A path the task description clearly names (e.g. "agent-framework의
   README", "~/foo 에서").
3. Fallback: the caller's cwd (`cmux sidebar-state | grep '^cwd='`).

**3b — Find a workspace already rooted at that workdir.** Enumerate
workspaces and read each one's cwd. `cmux tree` does NOT report cwd —
use `cmux sidebar-state`, which exposes `cwd=` as a first-class field:

```bash
# List workspace refs, then read each one's cwd (sidebar-state has no --all).
for ws in $(cmux list-workspaces | grep -oE 'workspace:[0-9]+'); do
  cwd=$(cmux sidebar-state --workspace "$ws" 2>/dev/null | sed -n 's/^cwd=//p')
  [[ "$cwd" == "$WORKDIR" ]] && echo "match: $ws"
done
```

> Do NOT identify a workspace's directory via `tty`→`lsof`, by parsing
> `cmux tree`'s OSC surface titles, or by hitting the socket directly.
> ttys are reused, so they are not a reliable identity key. `cmux
> sidebar-state`'s `cwd=` (and `focused_cwd=`, `git_branch=`) is the
> supported source of truth.

**3c — Decide placement:**

| Situation | Placement | sib invocation |
|---|---|---|
| A workspace already has cwd == workdir | reuse it | `sib spawn <slug> --workspace <ws>` |
| The caller's own workspace has cwd == workdir | split the caller | `sib spawn <slug>` (default) |
| No workspace matches workdir | dedicated new workspace | `sib spawn <slug> --workdir <workdir> --new-workspace` |

If the workdir differs from the caller's workspace cwd, **warn and
confirm** before spawning (you are placing work outside the base
session):

```
⚠️ base 워크스페이스 cwd = {caller_cwd}
   작업 대상 cwd       = {workdir}
→ {기존 workspace:N 재사용 | 전용 워크스페이스 신규 생성} 예정. 진행할까요?
```

### Step 4 — Derive slug + worker, then ask for mode

**Worker inference** (deterministic, not asked) — `claude` by default.
Pick `codex` only when the description **explicitly mentions codex**
(`codex로`, `codex를 시켜`, `use codex`, `gpt-5`, `openai로`). Do not
infer codex from task-shape keywords.

**Slug derivation** — first 3–5 descriptive nouns from the description,
lowercased, kebab-joined, trimmed to ~24 chars. Avoid reserved names
(`base`, `main`, `master`, `head`, `origin`, `ghost-*`).

**Mode derivation** — scan the user's request for mode signals before
deciding whether to ask:

| Signal in user input | Mode |
|---|---|
| `keep_alive: false` / "fire-and-forget" / "ff" / "FF" | fire-and-forget |
| `keep_alive: true` / "interactive" / "keep alive" / "keep-alive" | interactive |
| No mode signal | ask the user (prompt below) |

Note on the sib model: closing the cmux pane ends the agent. There is no
detached `keep_alive` daemon. So:

- **fire-and-forget** = the sibling runs the task, the user lets the pane
  exit when the agent finishes
- **interactive** = the user keeps the pane open and continues the
  conversation in it manually

Both modes look the same at spawn time; the difference is post-task
intent. The skill records the choice in the message to the user but does
not alter the sib invocation.

When mode is derived, **skip the prompt entirely** and execute
immediately with a one-line status update before the request:

```
Proceeding fire-and-forget per `keep_alive: false`.
- Slug: {slug}
- Worker: {claude|codex}
- Placement: {workspace 재사용 workspace:N | 전용 워크스페이스 신규 | 현재 워크스페이스 split}
```

**Mode selection prompt** (Korean, only when not derived):

```
Dispatch 준비 완료 — 모드 선택 시 즉시 실행됩니다.

- Slug: {slug}
- Worker: {claude|codex}
- Workdir: {workdir}
- Placement: {workspace 재사용 / 전용 신규 / 현재 split}
- Description: "{first 120 chars}..."

(Sibling은 위 workdir의 working tree를 공유합니다 — dispatch는 단일
에이전트 분기이지 격리 작업이 아닙니다. 끝나면 `sib kill {slug}`
또는 cmux 패인을 직접 닫으세요.)

모드를 선택해주세요:
  1) fire-and-forget — worker가 작업 후 pane을 닫는 흐름
  2) interactive — pane을 유지하며 계속 대화

답: 1 / 2  (또는 변경사항, 예: "codex로", "slug=xyz", "cancel")
```

### Step 5 — Execute via sib

```bash
WORKER_FLAG=""
[[ "$worker" == "codex" ]] && WORKER_FLAG="--codex"

# yolo flag — pass through if the user explicitly asked for autonomous
# mode (e.g., a long batch task with no user supervision)
YOLO_FLAG=""
[[ "$yolo" == "true" ]] && YOLO_FLAG="--yolo"

# Placement flag from Step 3c (exactly one of the three):
#   PLACEMENT=""                          # split the caller's workspace
#   PLACEMENT="--workspace $TARGET_WS"    # reuse an existing workspace
#   PLACEMENT="--workdir $WORKDIR --new-workspace"   # dedicated workspace

sib spawn "$slug" $WORKER_FLAG $YOLO_FLAG $PLACEMENT -- "$description"
```

`sib spawn` then:

1. Resolves the start dir (workdir → caller PWD; worktree wins if set)
2. Places the pane per the placement flag (split caller / split named
   workspace / new dedicated workspace rooted at workdir)
3. `cd`s into the start dir and `exec`s the agent in the pane
4. Waits up to 20 s for the agent prompt marker (`❯` claude, `›` codex),
   then sends the task as the first message
5. Persists state to `~/.local/share/sib/state/<slug>.env` (slug, agent,
   surface, workspace, worktree, workdir, worktree_managed,
   workspace_managed)

### Step 6 — Report to the user

On success, sib prints a one-line summary; surface it verbatim plus a
short note:

```markdown
## Dispatch 실행 완료

- Slug: {slug}
- Worker: {claude|codex}
- Workdir: {workdir}
- Placement: {workspace:N 재사용 | 전용 워크스페이스 신규 | 현재 split}
- Surface: {surface from sib output}

Talk to the sibling by focusing its cmux pane, or:
  sib send {slug} "..."

When done:
  sib kill {slug}    # closes the pane; for a dedicated workspace, closes it
```

On failure, sib's error message is printed verbatim. Common cases:

- `sib '<slug>' already exists` — different slug needed
- `failed to create pane` / `failed to split workspace` — cmux state
  issue, inspect with `cmux list-workspaces`
- `start dir does not exist` — workdir typo; re-resolve Step 3

## Integration model

Because the sibling shares the target directory's working tree and
current branch, there is **no promote step** — the sibling's commits land
on the same branch, exactly like a second engineer pushing to the same
checkout.

Implications:

- The base session sees the sibling's commits as soon as they land.
- If the sibling and the base touch overlapping files concurrently,
  expect the usual git lock / file-conflict ergonomics — coordinate by
  topic or hand off the file before the sibling starts.
- If the work needs to be reviewable as a separate branch (PR,
  audit-trail), spawn through `/collab` instead — that pattern owns
  worktree isolation and has the cross-review + merge workflow.

## Relationship to other skills

- **agentmemory hooks**: session continuity is auto-handled. dispatch
  does not need to coordinate.
- **`/collab`**: same-task dual-agent flow with independent workers.
  Owns worktree isolation (`sib spawn --worktree`) because two agents
  on one task need independent branches.
- **`sib list`**: see all live siblings spawned via `/dispatch` or direct
  `sib spawn`.
- **`sib kill <slug>`**: explicit teardown when a sibling is done. For a
  `--new-workspace` sibling, this closes the whole dedicated workspace.

## Notes

- This skill never required an orchestrator daemon.
- v0.6.0 changes from v0.5.0:
  - **Workspace targeting** (Step 3): resolve the task's workdir, find a
    workspace already rooted there (`cmux sidebar-state` cwd), and place
    the sibling there — reuse, caller-split, or a dedicated new
    workspace. Stops dumping unrelated work into the base pane.
  - Uses sib's new placement flags (`--workdir`, `--workspace`,
    `--new-workspace`).
  - Report + mode prompt now state the resolved workdir and placement.
- v0.6.0 retained from v0.5.0: shared working tree (no worktree, no
  branch), no promote step, slug/worker derivation, mode prompt + go-
  signal contract, pane-close cleanup model.
- The sib backend is owned by L1 (`agent-framework/bin/sib`, symlinked to
  `~/.local/bin/sib`). Bug reports / feature requests for sib go to that
  repo.
