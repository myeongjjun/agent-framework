# Hooks Manifest

Hook source of truth for `agent-framework/scripts/install.sh`. Each row maps
to a hook entry that gets registered in `~/.claude/settings.json` when L1
is installed on a machine.

| Hook | Category | Event | Matcher | Timeout | Purpose |
|------|----------|-------|---------|---------|---------|
| guard-acp-direct-edit.sh | general | PreToolUse | Edit,Write,MultiEdit | 3 | Warn on direct edits to `agent-context/` (enforces ACP skill usage) |
| guard-deployed-artifact-edit.sh | general | PreToolUse | Edit,Write | 3 | Warn on edits to deployed runtime (`~/.claude/skills/`, `~/.codex/skills/`, etc.) instead of source |
| guard-permission-bypass.sh | general | PreToolUse | Edit,Write,MultiEdit | 3 | Block agent edits to permission / hook / MCP config (`~/.claude/settings.json`, hooks, etc.). Enforces `no-permission-bypass.md` constraint. |
| guard-cherry-pick.sh | general | PreToolUse | Bash | 5 | Warn on ad-hoc `git cherry-pick` in routine worker→base integration; steer to `agent-promote.sh`. Supports `/collab` merge flow. |
| turn-end-wip-commit.sh | general | Stop | — | 30 | Auto-commit each turn's work inside a sib worker worktree (`sib/<slug>`) so `agent-promote.sh` can squash-merge cleanly. Supports `/dispatch` + `/collab`. |

> **Stop / Bash hook registration is a settings.json change.** install.sh
> copies hook *sources* into `~/.claude/hooks/`, but wiring an event →
> hook entry in `~/.claude/settings.json` is gated by the
> `no-permission-bypass` constraint. A maintainer registers these
> explicitly; the agent must not auto-edit settings.json to enable them.
