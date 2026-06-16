---
name: codex
version: 3.0.0
description: >
  Invoke Codex CLI for high-reasoning coding tasks. Trigger phrases:
  "use codex", "ask codex", "run codex", "call codex", "codex cli",
  "GPT-5 reasoning", "OpenAI reasoning", or any request for advanced
  reasoning / complex implementation that benefits from Codex's
  configured model. Two invocation modes:
    - sib (interactive, when inside a cmux pane)
    - codex exec (non-interactive fallback)
---

# Codex

High-reasoning sibling-agent integration. Codex runs in its own process
(separate from the calling Claude Code session) so its reasoning effort
and context budget are independent.

## Default model & reasoning effort

Codex's model is **whatever `~/.codex/config.toml` says** — do not
hard-code `-m <model>`. The user controls model + reasoning effort
globally; this skill respects that.

| Reasoning effort | Use when |
|---|---|
| `low` | Mechanical edits, formatting, repetitive refactors |
| `medium` | Standard implementation tasks |
| `high` (default) | Complex logic, architectural choices, multi-step reasoning |
| `xhigh` | Hard algorithms, deep correctness analysis (rare) |

Override only when the task clearly warrants it:

```bash
codex exec -c model_reasoning_effort=high "prompt"
```

## MCP servers

Codex's MCP is **disabled by default** in `~/.codex/config.toml` to
avoid startup latency. If external data is needed, the caller (Claude
or another agent) fetches it and inlines it into the Codex prompt.

Verification: Codex's log shows `mcp startup: no servers` for default
invocations.

## Invocation modes

Detect mode before calling:

```bash
if [[ -n "${CMUX_WORKSPACE_ID:-}" ]] && command -v sib >/dev/null; then
  MODE="sib"     # interactive sibling session in a new cmux pane
else
  MODE="exec"   # codex exec (non-interactive)
fi
```

### Mode A: sib spawn --codex (interactive)

Spawn a codex sibling into a new cmux pane via `sib spawn --codex` (L1
sibling-agent launcher, installed by `agent-framework/scripts/install.sh`).

Preconditions:
- `$CMUX_WORKSPACE_ID` set (running inside a cmux pane)
- `sib` on PATH

```bash
sib spawn "codex-<slug>" --codex -- "<task description>"
```

`sib spawn` does:
1. Open a new cmux pane (right split) in the caller's working directory
2. Boot `codex` in that pane
3. Poll for the codex marker `›` (race-prevention)
4. Send the initial prompt
5. Persist state to `~/.local/share/sib/state/<slug>.env`

Add `--worktree` if codex needs an isolated branch (parallel edits with
the caller, audit-friendly provenance). Default = shared workdir, which
matches the single-agent dispatch model.

Talk back: `sib send codex-<slug> "..."`
Tear down: `sib kill codex-<slug>` (closes pane; with `--worktree`, also
removes the worktree + branch)

Use Mode A when:
- You need an interactive back-and-forth with codex
- The task is iterative (codex partial result → user feedback → codex continues)
- You want full visibility of codex's screen via the cmux pane

### Mode B: codex exec (non-interactive)

Use when not running inside a cmux pane (headless scripts, CI, one-shot
invocations).

Preconditions (verify before invoking):
1. **Model**: `grep '^model' ~/.codex/config.toml` — accept that value.
   Do NOT hard-code `-m`.
2. **Trust**: the current repo path must have `trust_level = "trusted"`
   in `~/.codex/config.toml`.
3. **No pipe**: do NOT append `| tail`, `| head`, or any pipe to
   `codex exec` — output is structured and pipes mangle it.

```bash
codex exec -s workspace-write -a never \
  -c model_reasoning_effort=high \
  "<prompt>"
```

Flag notes:
- `-s workspace-write` — sandboxed write to cwd workspace only.
- `-a never` — no approval prompts (autonomous run). Use this for
  unattended work; require explicit user approval for interactive runs.
- The pre-0.129 `--full-auto` flag is REMOVED; use `-s workspace-write -a never`.

### What NOT to do

- **Never** call bare `codex` (interactive TUI) without a real
  terminal — fails with "stdout is not a terminal".
- **Never** `codex exec | tail`, `codex exec | head`, etc. Output is
  structured; pipes break it.
- **Never** hard-code `-m <model>` unless the user has explicitly asked
  for a specific model. Honor `~/.codex/config.toml`.

## When to delegate to Codex (vs. handle in Claude)

Delegate to Codex when:
- Task is **compute-heavy** (algorithm work, deep code reasoning).
- Task is **iterative implementation** that would consume Claude's
  context window quickly.
- Task is **bounded** and benefits from a fresh, isolated session.
- The user explicitly asks ("ask codex to...", "codex로 해줘").

Do NOT delegate when:
- Task is **conversational** (Q&A, explanation, planning).
- Task is **integrative** — needs cross-tool orchestration (MCP, hooks,
  user clarifications).
- Task is a **single small edit** — overhead of spawning Codex isn't
  justified.
- Task **requires user context** that lives only in the current Claude
  conversation (handing off the whole conversation is wasteful).

## Reading Codex's reply (Mode A)

When using `sib spawn --codex`, observe the pane via:

```bash
SURFACE=$(grep '^surface=' ~/.local/share/sib/state/codex-<slug>.env | cut -d= -f2)
WORKSPACE=$(grep '^workspace=' ~/.local/share/sib/state/codex-<slug>.env | cut -d= -f2)
cmux read-screen --surface "$SURFACE" --workspace "$WORKSPACE" --lines 60
```

Codex marks readiness with `›` on a fresh line. Mid-response, it shows
`• <verb>...` (e.g., `• Reading`, `• Editing`).

## Reading Codex's reply (Mode B)

`codex exec` returns its result on stdout when the run completes.
Capture in a variable:

```bash
result=$(codex exec -s workspace-write -a never -c model_reasoning_effort=high "<prompt>")
```

Or write to a file:

```bash
codex exec ... "<prompt>" > /tmp/codex-out.md
```

## Promote codex work back to base (Mode A only)

After codex finishes a sib-spawned task, the worktree (branch
`sib/<slug>`) holds the changes. Promote to the base branch via:

```bash
./scripts/agent-promote.sh codex-<slug>
```

(`agent-promote.sh` is a persona-level helper; L1 sib only handles
spawn/kill.)

## Common errors

| Symptom | Cause | Fix |
|---|---|---|
| `stdout is not a terminal` | Called bare `codex` without TTY | Use Mode A (`sib spawn --codex`) or Mode B (`codex exec`) |
| `unexpected argument '--full-auto'` | Pre-0.129 flag | Replace with `-s workspace-write -a never` |
| `trust_level required` | repo path not trusted | `cd <repo> && codex login --trust` (or edit `~/.codex/config.toml`) |
| Slow startup, MCP loading | MCP enabled in config | Disable MCP in `~/.codex/config.toml` (default state) |

## Notes

- v3.0.0 (2026-06-16) is a lean rewrite. Earlier versions wove
  Codex invocation through the workspace orchestrator + handoff/takeover
  skills (now retired in ADR-035 / ADR-036). The current skill is
  scoped to two invocation modes only and depends only on what L1
  installs (sib).
- The `references/` and `scripts/` subdirectories were removed in the
  v3.0.0 rewrite. The earlier `codex-auto-handoff.sh` and
  `codex-with-context.sh` helpers wired Codex into the workspace
  handoff system, which no longer exists.
