---
name: codex
version: 4.0.0
description: >
  Invoke Codex CLI for high-reasoning coding tasks. Trigger phrases:
  "use codex", "ask codex", "run codex", "call codex", "codex cli",
  "GPT-5 reasoning", "OpenAI reasoning", or any request for advanced
  reasoning / complex implementation that benefits from Codex's
  configured model. Codex always runs in a cmux pane via
  `sib spawn --codex`, so the desk and the user can see and steer it.
  `codex exec` (headless, no pane) is not used.
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

The effort comes from `~/.codex/config.toml` (default `high`). Ask Codex
in the prompt to think harder when a task needs it; do not start a
headless run to change the effort.

## MCP servers

Codex's MCP is **disabled by default** in `~/.codex/config.toml` to
avoid startup latency. If external data is needed, the caller (Claude
or another agent) fetches it and inlines it into the Codex prompt.

Verification: Codex's log shows `mcp startup: no servers` for default
invocations.

## Invocation: a cmux pane only

Codex MUST run in a cmux pane that the desk and the user can see.
The agent MUST NOT start `codex exec` or any other headless Codex run.

Why: a headless run has no pane, so nobody can watch, answer or stop it.
On 11-23 a headless run sat blocked on stdin for 10 minutes unseen. The
user ruled that Codex always runs on cmux to keep it controllable.

Check before calling:

```bash
if [[ -n "${CMUX_WORKSPACE_ID:-}" ]] && command -v sib >/dev/null; then
  : # spawn the pane below
else
  echo "Codex needs a cmux pane: open this task in cmux, then ask again." >&2
fi
```

When the check fails, the agent MUST stop and tell the user. It MUST NOT fall back to `codex exec`.

### sib spawn --codex

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
2. Boot `codex --approve-for-me` in that pane (escalations go to Codex's
   auto-reviewer, not a y/n prompt; `--yolo` bypasses sandbox + approvals)
3. Poll for the codex marker `›` (race-prevention)
4. Send the initial prompt
5. Persist state to `~/.local/share/sib/state/<slug>.env`

Add `--worktree` if codex needs an isolated branch (parallel edits with
the caller, audit-friendly provenance). Default = shared workdir, which
matches the single-agent dispatch model.

Talk back: `sib send codex-<slug> "..."`
Tear down: `sib kill codex-<slug>` (closes pane; with `--worktree`, also
removes the worktree + branch)

For a one-shot job (e.g. "draw these files"), still spawn a pane: put the
whole brief in the prompt, ask Codex to print a short result summary, and
read the pane when it is done. Close it with `sib kill` once the result is
checked.

### What NOT to do

- **Never** call bare `codex` (interactive TUI) without a real
  terminal — fails with "stdout is not a terminal".
- **Never** run `codex exec` (headless). Spawn a pane instead.
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

## Reading Codex's reply

When using `sib spawn --codex`, observe the pane via:

```bash
SURFACE=$(grep '^surface=' ~/.local/share/sib/state/codex-<slug>.env | cut -d= -f2)
WORKSPACE=$(grep '^workspace=' ~/.local/share/sib/state/codex-<slug>.env | cut -d= -f2)
cmux read-screen --surface "$SURFACE" --workspace "$WORKSPACE" --lines 60
```

Codex marks readiness with `›` on a fresh line. Mid-response, it shows
`• <verb>...` (e.g., `• Reading`, `• Editing`).

## Promote codex work back to base

After codex finishes a sib-spawned task, the worktree (branch
`sib/<slug>`) holds the changes. Promote to the base branch via:

```bash
agent-promote.sh codex-<slug>
```

(`agent-promote.sh` is an L1 helper on PATH via `~/.local/bin/`; it
squash-merges the `sib/<slug>` worker branch. sib itself only handles
spawn/kill.)

## Common errors

| Symptom | Cause | Fix |
|---|---|---|
| `stdout is not a terminal` | Called bare `codex` without TTY | Use `sib spawn --codex` (a cmux pane) |
| Not inside cmux (`$CMUX_WORKSPACE_ID` empty) | Headless context | Stop and ask the user to run the task in cmux; never use `codex exec` |
| `trust_level required` | repo path not trusted | `cd <repo> && codex login --trust` (or edit `~/.codex/config.toml`) |
| Slow startup, MCP loading | MCP enabled in config | Disable MCP in `~/.codex/config.toml` (default state) |
