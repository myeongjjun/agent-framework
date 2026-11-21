---
name: dispatch
version: 0.10.0
description: >
  Spawn a scoped sibling agent session via `sib` (cmux pane, shared
  working tree — no worktree by default), placing it in the workspace
  that matches the task's working directory. The skill derives slug +
  worker + mode and executes immediately — interactive by default (only
  an explicit fire-and-forget signal overrides), never prompting.
  dispatch = single-agent branch sharing; for dual-agent isolated work,
  use /collab.
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

> This skill follows the ACP rules in AGENTS.md.

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

- The current session needs to keep running while a sibling agent picks up a
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

- `/dispatch` MUST run inside a cmux pane (`$CMUX_WORKSPACE_ID` set). `sib spawn`
  refuses without it.
- The slug MUST be lowercase kebab-case (`[a-z0-9-]+`). sib enforces this.
- The base slot is not a target — `/dispatch` always creates a NEW
  cmux pane via `sib spawn`, never injects into the base.
- **Never split an unrelated workspace.** If the task's working directory
  differs from a candidate workspace's cwd, do not place the sibling
  there. Resolve the target workspace explicitly (Step 3) before spawning.
- Do not pass `--worktree` to sib — that's reserved for /collab. A
  dispatched sibling shares the target directory's working tree.
- Never pass `--no-report`. sib appends the completion contract by
  default: the sibling stays inside its task, hands findings outside it
  to the desk with `brief note`, and when finished sends a
  `done-report:` to the desk (orch) and stays open; the desk
  cross-checks it and closes the pane.
- Every task ends with a `Done when: <observable end point>` line
  (Step 4). It is where the sibling stops; without it a session keeps
  absorbing follow-up work.
- Never tell the user a workspace "does not exist" until the reference
  has gone through stableId resolution (Step 3a.0). A
  `cmux://workspace/<UUID>` link carries a stableId that every cmux CLI
  command and `sib --workspace` reject with `not_found`, even for an
  open workspace.
- Never report "Dispatch 실행 완료" unless `sib spawn` exited 0 with its
  `✓` line. Exit 5 (`✗ … prompt not sent / not submitted / unconfirmed`)
  means the sibling is up but did not start the task — recover per
  Step 6.

## Workflow

### Step 1 — Parse input

- Accept free-form input: `/dispatch <description>`
- Optional explicit overrides: `--slug <slug>`, `--worker claude|codex`,
  `--workspace <id|ref>` (target an open workspace directly),
  `--workdir <path>` (force the working directory). Mode is advisory
  only (interactive by default; `keep_alive: false` / "ff" selects
  fire-and-forget) — it is not a sib flag, just how the pane is used.
- Any of these explicit targets — `--workspace`, `--workdir`, or a
  workspace/repo named in the description — is a **go-signal**: resolve
  it and spawn without asking (see Step 3 confirmation policy).
- A `cmux://workspace/<UUID>` link anywhere in the input is a placement
  target, equivalent to `--workspace <UUID>` (normalize it in Step 3a.0).
- Extract description text (everything after the trigger, minus flags)

### Step 2 — Verify environment

```bash
[[ -n "$CMUX_WORKSPACE_ID" ]] || { echo "/dispatch must run inside a cmux pane"; exit 1; }
command -v sib >/dev/null || { echo "sib not found on PATH (expected ~/.local/bin/sib)"; exit 1; }
```

If either check fails, surface the error and stop.

### Step 3 — Resolve the target workdir + workspace

A sibling MUST start in the directory where the work lives, not where the
caller is.

**3a.0 — Normalize an explicit workspace reference** (`--workspace <x>`
or a `cmux://workspace/<UUID>` link). cmux has two UUIDs per workspace:
the runtime `workspaceId` (what `cmux workspace list --json` prints as
`id`, and what every CLI command and `sib --workspace` accept) and a
persistent `stableId` (what a copied `cmux://workspace/…` link holds).
If `<x>` is a `workspace:N` ref, or a UUID that appears as an `id` in
`cmux workspace list --json`, use it as is. Otherwise translate it
through cmux's session file:

```bash
python3 -I - "$uuid" <<'EOF'
import json, os, sys
u = sys.argv[1].upper()
p = os.path.expanduser('~/Library/Application Support/cmux/session-com.cmuxterm.app.json')
for w in json.load(open(p)).get('windows', []):
    for ws in w.get('tabManager', {}).get('workspaces', []):
        if ws.get('stableId', '').upper() == u:
            print(ws['workspaceId'], ws.get('currentDirectory', ''))
EOF
```

A hit gives the runtime id (and the workspace cwd). The file is saved
periodically, so a workspace created moments ago can be missing — only
then ask the user for the workspace title or the `$CMUX_WORKSPACE_ID`
printed in one of its panes. See also `docs/cmux-cli-reference.md`.

**3a — Determine the workdir.** In priority order. Track whether the
result was **explicit** (1–3) or **inferred** (4) — it decides whether
3c confirms:

1. Explicit `--workspace <id|ref>` from the user → that workspace is the
   target; its cwd is the workdir (skip 3b). **Explicit.**
2. Explicit `--workdir <path>` from the user. **Explicit.**
3. A path/repo the request clearly names (e.g. "agent-framework에서",
   "~/foo 에서", "cmux repo에서"). Resolve the repo name to its path.
   **Explicit.**
4. Fallback: the caller's cwd (`cmux sidebar-state | grep '^cwd='`).
   **Inferred.**

**3b — Find a workspace already rooted at that workdir.** This check is
MANDATORY before any spawn — skipping it and running `sib spawn
--new-workspace` blind creates redundant workspaces (observed failure).
Use /pane-msg's resolution primitive, which returns matches plus a
reuse-or-create verdict:

```bash
skills/pane-msg/scripts/pane-resolve.sh --cwd "$WORKDIR"
# exit 0 → exactly one workspace rooted there: reuse it (--workspace <ws>)
# exit 3 → none: --new-workspace is justified
# exit 4 → several: present candidates, ask the user — never pick silently
```

Fallback (primitive unavailable): `cmux workspace list --json | jq -r
'.workspaces[] | [.ref, .current_directory] | @tsv'` and match
`current_directory` against `$WORKDIR`. `cmux tree` does NOT report cwd,
and titles/statusline text are not cwd sources.

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

**Confirmation policy — do not ask when the target is explicit.** When
the workdir/workspace came from 3a.1–3a.3 (the user named a workspace,
a path, or a repo), **proceed immediately** — no confirmation prompt,
even when the target differs from the caller's workspace. That explicit
naming *is* the go-signal; asking again is exactly the friction to avoid.

Confirm in **only one** case: the workdir was **inferred** (3a.4, the
caller's cwd fallback) AND it resolves to placing work in a workspace
other than the caller's. Then print the warning below and wait. If the
inferred workdir is the caller's own workspace, just proceed.

```
⚠️ 작업 대상을 명시하지 않아 caller cwd로 추론했습니다.
   base 워크스페이스 cwd = {caller_cwd}
   작업 대상 cwd        = {workdir}
→ {기존 workspace:N 재사용 | 전용 워크스페이스 신규 생성} 예정. 진행할까요?
   (다음부터는 workspace/경로/repo를 명시하면 바로 실행됩니다.)
```

### Step 4 — Derive slug + worker + mode

**Worker inference** (deterministic, not asked) — `claude` by default.
Pick `codex` only when the description **explicitly mentions codex**
(`codex로`, `codex를 시켜`, `use codex`, `gpt-5`, `openai로`). Do not
infer codex from task-shape keywords.

**Slug derivation** — first 3–5 descriptive nouns from the description,
lowercased, kebab-joined, trimmed to ~24 chars. Avoid reserved names
(`base`, `main`, `master`, `head`, `origin`, `ghost-*`).

**Mode derivation** — `interactive` is the default. Never ask; only an
explicit fire-and-forget signal overrides it:

| Signal in user input | Mode |
|---|---|
| `keep_alive: false` / "fire-and-forget" / "ff" / "FF" | fire-and-forget |
| Anything else (incl. no mode signal, `keep_alive: true`, "interactive") | **interactive** (default) |

Note on the sib model: closing the cmux pane ends the agent. There is no
detached `keep_alive` daemon. So:

- **interactive** (default) = the user can keep talking to the sibling
  while it works; when the task is done it reports and the desk closes it
- **fire-and-forget** = the user does not plan to look at the pane; the
  report + desk review is the only follow-up

Both modes use the same sib invocation (completion contract included); the
difference is post-task intent, recorded in the message to the user.
A pane outlives its task only while the desk review finds something
left (`not-ready`).

**End point** — append one line to the description: `Done when:
<observable end point>` — an artifact that exists, a test that passes, a
report that was sent, a PR that is open. Derive it from the request;
never ask. If the request names several outcomes, name all of them in
that one line; anything beyond it is a new task for the desk.

Mode is **always derived, never prompted** — proceed immediately with a
one-line status update before the request:

```
Proceeding interactive (default).
- Slug: {slug}
- Worker: {claude|codex}
- Placement: {workspace 재사용 workspace:N | 전용 워크스페이스 신규 | 현재 워크스페이스 split}
```

### Step 5 — Execute via sib

```bash
WORKER_FLAG=""
[[ "$worker" == "codex" ]] && WORKER_FLAG="--codex"

# yolo flag — pass through if the user explicitly asked for autonomous
# mode (e.g., a long batch task with no user supervision)
YOLO_FLAG=""
[[ "$yolo" == "true" ]] && YOLO_FLAG="--yolo"

# Placement flags from Step 3c (exactly one of the three). An array so
# paths with spaces survive:
#   PLACEMENT=()                                       # split the caller's workspace
#   PLACEMENT=(--workspace "$TARGET_WS")               # reuse an existing workspace
#   PLACEMENT=(--workdir "$WORKDIR" --new-workspace)   # dedicated workspace

# Brief delivery — sib types the first message into the agent's input
# box flattened to one line (newlines become spaces). A multi-line
# description, or one over ~1000 bytes, goes into a brief file instead
# (structure preserved, audit trail kept) and the sibling gets a
# one-line pointer. sib itself does not do this.
first_msg="$description"
if [[ "$description" == *$'\n'* ]] || (( $(printf '%s' "$description" | wc -c) > 1000 )); then
  brief_dir="${XDG_DATA_HOME:-$HOME/.local/share}/sib/briefs"
  mkdir -p "$brief_dir"
  brief="$brief_dir/$slug.md"
  printf '%s\n' "$description" > "$brief"
  first_msg="$brief 를 읽고 그 작업을 진행해줘."
fi

# The completion contract is sib's default; never pass --no-report here.
sib spawn "$slug" $WORKER_FLAG $YOLO_FLAG "${PLACEMENT[@]}" -- "$first_msg"
rc=$?
```

`sib spawn` then:

1. Resolves the start dir (workdir → caller PWD; worktree wins if set)
2. Places the pane per the placement flag (split caller / split named
   workspace / new dedicated workspace rooted at workdir)
3. `cd`s into the start dir and `exec`s the agent in the pane
4. Persists state to `~/.local/share/sib/state/<slug>.env` (slug, agent,
   surface, workspace, worktree, workdir, worktree_managed,
   workspace_managed)
5. Waits up to ~30 s for the agent's own input box (marker at line
   start, plus claude's input-box rule line — a shell prompt's `❯` does
   not count), types the task — with the completion contract appended
   (sib's default) — confirms its head AND tail are visible, submits, and
   confirms a work signal
6. Exits 0 with `✓ … [booted]` only when all of that held. Otherwise
   exits 5 with `✗ … prompt <not sent | not submitted | unconfirmed>` —
   the pane and state file stay up

### Step 6 — Verify, then report to the user

Branch on `rc`:

- **`rc == 0`** (`✓` line) — the task was submitted. Report below.
- **`rc == 5`** (`✗` line) — the sibling exists but did not start. Do not
  report success. Recover:
  1. `cmux read-screen --surface <surface> --workspace <ws> --lines 60`
     to see the input box.
  2. If text is sitting in the input box, clear it:
     `cmux send-key --surface <surface> --workspace <ws> ctrl+c`.
  3. `sib kill "$slug"` and run Step 5 once more. A respawn re-appends
     the completion contract; `sib send` would deliver the task without
     it, leaving a session that never reports or closes.
  4. If that also fails, tell the user the sibling is up but idle, with
     the surface ref and what the screen shows.
- **other non-zero** — spawn itself failed; print sib's error verbatim
  (common cases below).

On success, surface sib's `✓` line verbatim plus a short note:

```markdown
## Dispatch 실행 완료

- Slug: {slug}
- Worker: {claude|codex}
- Mode: {interactive | fire-and-forget}
- Workdir: {workdir}
- Placement: {workspace:N 재사용 | 전용 워크스페이스 신규 | 현재 split}
- Surface: {surface from sib output}
- Brief: {brief path, if the description went through a file}

Talk to the sibling by focusing its cmux pane, or:
  sib send {slug} "..."

When done: the sibling sends a done-report to the desk, which checks it
and closes the pane. Manual teardown if needed:
  sib kill {slug}    # closes the pane; for a dedicated workspace, closes it
```

On failure, sib's error message is printed verbatim. Common cases:

- `sib '<slug>' already exists` — a sibling with that slug is still
  open (a slug whose pane is gone is reused automatically); pick another
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

- The sib backend is owned by L1 (`agent-framework/bin/sib`, symlinked to
  `~/.local/bin/sib`). Bug reports / feature requests for sib go to that
  repo.
