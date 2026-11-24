---
name: pane-msg
version: 1.2.0
description: >
  Deliver a message/task to an ALREADY-OPEN cmux pane — never spawn a new
  session (that is /dispatch). Makes target resolution and delivery
  deterministic: one resolution primitive (slug | cwd | title | explicit
  refs → {workspace, surface} + live state), a reuse-or-create verdict for
  placement decisions, and a verified send→confirm→enter→confirm delivery
  that refuses approval-prompt and busy screens. Kills the two flaky
  behaviours: guessing the target without confirmation, and submitting
  without verifying.
trigger_phrases:
  - "/pane-msg"
  - "pane-msg"
  - "패인에 보내"
  - "그 세션에 전달"
  - "옆 세션에 시켜"
  - "떠있는 세션에 메시지"
  - "이미 열린 pane에"
---

# Pane-Msg — Deterministic Delivery to an Open cmux Pane

## ACP Integration

> This skill follows the ACP rules in AGENTS.md.

- Follows the L1 language convention: English for workflow/logic, Korean
  only for trigger phrases and output format examples.
- When new constraints or architecture decisions are discovered while
  using this skill, record them via `/acp-constraint` or `/acp-decision`
  (do not edit `agent-context/` directly).

## Purpose

`/pane-msg` sends a message or task to an agent session that is **already
running** in a cmux pane. It exists because the ad-hoc approach ("find the
pane and send") failed in two specific ways:

1. **Guessed targets** — the agent picked a pane from titles or memory and
   injected without confirming, or spawned a redundant workspace without
   checking whether one already existed at the target cwd.
2. **Unverified delivery** — text was sent and enter fired blind; the
   message ended up half-typed, queued, or eaten by an autocomplete.

The fix is two scripts with deterministic contracts:

| Script | Contract |
|---|---|
| `scripts/pane-resolve.sh` | selector → ALL matching `{workspace, surface}` + live state; verdict `MATCH:<n>`; exit 0 = one, 3 = none ("safe to create"), 4 = ambiguous |
| `scripts/pane-deliver.sh` | refs → safety-gated, verified injection (§9 pattern); machine-readable outcome |

Use this skill when:

- The user names an existing session/pane/sibling and wants it told
  something ("agent-framework 세션에 이거 전달해", "그 sib한테 물어봐")
- A skill/agent routes work to a repo and needs to know whether an
  open workspace already covers it (**placement reuse check**)

Do not use this skill for:

- Starting new work in a new pane — that is `/dispatch` (which spawns via
  `sib`); `/pane-msg`'s resolution primitive only tells dispatch whether
  spawning is warranted
- Talking to a pane you just spawned in the same turn — `sib spawn`
  already delivered the first prompt; use `sib send <slug>` for quick
  follow-ups to a pane you are certain about

## Non-negotiable Requirements

- **Never guess.** Every injection needs either a deterministic selector
  (sib slug, explicit `surface:N`+`workspace:N`, exact cwd with exactly
  one match) or the user's explicit pick from presented candidates.
- **Never inject into a busy pane by default.** An active session is doing
  real work; a mid-run message steers it. If the user did not
  explicitly choose that target, the skill MUST NOT deliver (`--queue` overrides).
- **Never self-deliver.** `pane-deliver.sh` hard-refuses the caller's own
  pane (from `cmux identify --json` `.caller`).
- **Never touch an approval prompt.** If the target screen shows an
  approval/permission prompt, delivery is refused — that screen belongs to
  the user.
- **Never route around a hook block.** If a PreToolUse hook denies
  `cmux send`/`send-key` (`BLOCKED:`), stop and follow the
  `no-permission-bypass` constraint. Re-sending through `sib send` is a
  forbidden bypass.
- **Never silently create-new when a match exists.** For placement
  questions, `MATCH:0` is the only "safe to create" signal; `MATCH:1`
  means evaluate reuse; `MATCH:2+` means present candidates and ask.

## Target resolution — the primitive

```bash
skills/pane-msg/scripts/pane-resolve.sh --slug <slug>
skills/pane-msg/scripts/pane-resolve.sh --spawner-of <slug>   # who spawned sib <slug>
skills/pane-msg/scripts/pane-resolve.sh --cwd <path>
skills/pane-msg/scripts/pane-resolve.sh --title <hint>
skills/pane-msg/scripts/pane-resolve.sh --surface surface:N --workspace workspace:N
```

Output: one tab-separated line per match —
`workspace= surface= slug= cwd= self= state= ws_title= title= last_at= last_msg=`
— then a `MATCH:<n>` verdict. `state` is a live screen classification:
`busy` (esc-to-interrupt hint OR an agent spinner line like
`· Orchestrating… (12m …)` — newer Claude Code builds show only the
spinner while working, keeping the `❯` marker drawn, so the marker alone
is not a sign of idle), `approval` (approval prompt visible), `idle`
(input marker, no busy signal), `unknown`.

**Selector reliability order** (use the strongest available):

| Selector | Reliability | Why |
|---|---|---|
| `--slug` | strongest | sib records surface+workspace refs in `~/.local/share/sib/state/<slug>.env` at spawn time; no inference. Detects stale state (dead pane) and says so. |
| `--spawner-of` | strongest | sib spawn records the caller's own refs (`spawner_surface`/`spawner_workspace` from `cmux identify`) — a worker's "report back to whoever spawned me" without guessing. `MATCH:0` with a clear message for pre-recording state files. |
| explicit refs | strongest | user-provided; liveness-checked only |
| `--cwd` | strong | `cmux workspace list --json` → `.current_directory` is the authoritative workspace root. NOT titles, NOT statusline grep. |
| `--title` | weakest | titles are auto-named per turn and flip between task summary and path (cmux title dual-source problem); a match is a *candidate*, never an identity |

**cwd caveat (documented divergence)**: `.current_directory` is the
workspace's launch/root directory. A long-running shell or agent can have
`cd`'d elsewhere since — a cwd match means "this workspace is rooted
there", not "the process is currently there". For placement decisions this
is exactly the right key; for "which repo is that agent editing right
now" it is not a guarantee.

**Reuse is not automatic.** A cwd-matched workspace can hold an unrelated,
busy, or stale session (real case: a workspace rooted at agent-framework
held an idle 251k-token session on a completely different topic). The
match lines carry `state`, `ws_title`, `last_at`, and `last_msg` precisely
so the caller can judge *free and relevant* — and when in doubt, ask the
user rather than inject or create.

## Workflow

### Step 1 — Parse input

- Accept free-form: `/pane-msg <target hint> <message>` or structured
  `--slug/--surface+--workspace/--cwd/--title` plus the message after `--`.
- Classify the intent: **delivery** (a message goes to a pane) vs
  **placement query** (a caller — usually `/dispatch` — asks "is there an
  open workspace for path X?").

### Step 2 — Verify environment

```bash
command -v cmux >/dev/null || { echo "cmux CLI not found"; exit 1; }
cmux ping >/dev/null       || { echo "cmux socket not responding"; exit 1; }
```

### Step 3 — Resolve deterministically

Pick the strongest selector the input supports (slug > explicit refs >
cwd > title) and run `pane-resolve.sh`. Then branch on the verdict:

| Verdict | Delivery intent | Placement intent |
|---|---|---|
| `MATCH:1` via slug/refs/cwd | proceed to Step 4 | evaluate reuse (below) |
| `MATCH:1` via title | show the candidate, **ask before injecting** | same |
| `MATCH:0` | report "no such pane" — offer `/dispatch` to create one; never spawn from this skill | **safe to create** — caller can spawn/`--new-workspace` |
| `MATCH:2+` | present candidates (state + titles + last_msg), ask the user to pick | same — never silently create-new |

**Reuse evaluation** (placement, `MATCH:1`): reuse only if the matched
pane is *free and relevant* — `state=idle` AND its `ws_title`/`last_msg`
plausibly relate to the incoming task. An idle-but-unrelated long session
is NOT a reuse target for message delivery (it would hijack an unrelated
context); for pure workspace placement (`/dispatch` splitting a new pane
into it) unrelatedness of the *existing* pane is fine — the split creates
a fresh pane. When the judgment is not obvious, present the match and ask.

### Step 4 — Confirm (only when required)

- Selector was explicit (slug, refs, unique cwd) **and** target is
  `state=idle` → proceed without asking. Explicit naming is the go-signal
  (same policy as /dispatch).
- Target is `state=busy` → stop and ask, always. Show what the pane is
  doing (title + last_msg). Only on the user's explicit "yes, that one"
  proceed with `--queue`.
- Target is `state=approval` → do not deliver. Report the pending prompt.
- Selector was fuzzy (title) or verdict ambiguous → present candidates:

```
대상 pane 후보가 2개입니다. 어디로 보낼까요?
1. workspace:7  surface:13  [idle]  ✳ agentmemory MCP 도구 빈 결과 진단 — cwd ~/src/agent-framework
2. workspace:12 surface:35  [busy]  sib-pane-msg-skill — cwd ~/src/agent-framework
```

### Step 5 — Deliver (verified)

```bash
skills/pane-msg/scripts/pane-deliver.sh \
  --surface "$surface" --workspace "$workspace" [--queue] -- "$message"
# or, for a sib sibling:
skills/pane-msg/scripts/pane-deliver.sh --slug "$slug" -- "$message"
```

The helper implements the verified submit pattern
(`docs/cmux-cli-reference.md` §9) — the thing `sib send` and ad-hoc
`cmux send` skip:

1. Pre-injection gates: pane alive, not self, no approval prompt, not
   busy (unless `--queue`).
2. `cmux send` text only (newlines flattened — `\n` would submit early).
   A message over `PANE_DELIVER_INLINE_MAX` characters (default 160) is
   written to `~/.local/share/pane-msg/<time>-<surface>.md`, and the pane
   gets one line: the message head plus that path. A long typed message
   outgrows a narrow pane's input box, so its head scrolls away.
   Stdout names the typed line (`TYPED:`) and the file (`FILE:`).
3. Poll until the text is in the input box, whitespace-stripped on both
   sides so a narrow pane's soft-wrap can't break the match. The text is
   in when its tail is newly on screen (text arrives in order, so the head
   came first — this covers a box Claude scrolled with `↑ N more` and a
   pane so narrow that the head wrapped away with no marker), when head
   and tail are both visible, or when a new paste placeholder is followed
   only by the message's end (`…[Pasted text #1].`). Codex's
   `tab to queue message` notice is waited out; when only the notice stays
   up, the submit check decides. When the text never lands, the helper
   clears a Claude box with Esc Esc and says what it saw.
4. `cmux send-key enter`, then confirm a work signal (esc-to-interrupt
   hint or agent spinner line, also when wrapped) or an emptied box; one
   retry; report `DELIVERED` / `QUEUED` / `UNCONFIRMED` with exit codes 0/0/5.

A narrow, short pane (about 12 columns by 24 rows) draws no spinner and
no `esc to interrupt` hint while Claude works. The screen alone then
cannot prove busy or submit. `brief send` (the desk's path) checks cmux's
session state first and the session transcript after an `UNCONFIRMED`.

Never bypass the helper with a bare `cmux send-key` chain: the gates and
the landed-check are the reliability fix this skill exists for.

### Step 6 — Report

```markdown
## Pane-Msg 전달 완료

- 대상: workspace:7 / surface:13 (✳ agentmemory MCP 도구 빈 결과 진단)
- 선택 근거: --cwd ~/src/agent-framework 단일 매치 (idle)
- 결과: DELIVERED (work signal 확인됨)
- 메시지: "..."
```

On `UNCONFIRMED` (exit 5), report it as is and attach a screen snapshot
(`cmux read-screen`). The skill MUST NOT report it as a success.

## Relationship to other skills

- **`/dispatch`** — spawns NEW panes. Its Step 3b ("find a workspace
  already rooted at the workdir") calls
  `pane-resolve.sh --cwd <workdir>`: `MATCH:0` is the only case where
  `--new-workspace` is justified. /pane-msg never spawns.
- **`pane-deliver.sh` is the one deliverer** (one control path,
  `docs/agent-control-one-path.md` §5 step 3). `sib spawn` sends its first
  prompt through it (inline, `--queue`), `sib send <slug>` execs it (no
  plain-send fallback; `--queue` passes through), and `brief send` (the
  desk) calls it — `--queue` for a working session, never
  `cmux agent message`, which wakes the workspace's agent rather than the
  pane's (11-23: a desk message reached the wrong session).
- **`/collab`** — orchestrates its own workers via sib; it uses
  `pane-deliver.sh` for mid-flight nudges to a worker.

## Notes

- Discovery commands this skill trusts, and why:
  `cmux workspace list --json` (`.current_directory`, `.custom_title`,
  `.latest_submitted_at`, `.latest_conversation_message`),
  `cmux list-pane-surfaces --workspace <ref>` (surface refs + titles),
  `cmux identify --json` (`.caller` self refs),
  `~/.local/share/sib/state/*.env` (slug → surface/workspace).
  Explicitly distrusted: workspace/surface titles as identity, tty as a
  key, statusline-grepping for cwd (all documented failure modes —
  `docs/cmux-cli-reference.md` §5/§6).
- `CMUX_QUIET=1` is set in both scripts: `cmux list-workspaces` prints an
  alias-migration notice on stdout that corrupts JSON parsing otherwise.
- Two live-measured races are compensated in `pane-deliver.sh` (2026-07-08
  E2E): the spinner line is redrawn every frame, so a single read-screen
  can miss it — the busy precheck samples 3× over ~1s; and prompt-submit
  hooks (e.g. agentmemory) can delay the post-submit work signal by
  several seconds — the confirmation polls up to ~8s before reporting
  `UNCONFIRMED`. Residual limit: a message delivered in the moment an
  agent finishes one task and before its screen settles can still race;
  `UNCONFIRMED` therefore means "inspect", never "failed".
- sib state files record `workspace=` as a ref (`workspace:N`) for
  `--workspace`/`--new-workspace` spawns but as a raw UUID for default
  caller-splits; `pane-resolve.sh` normalizes UUIDs to refs via
  `sidebar-state`'s `tab=` field before joining against workspace
  metadata.
