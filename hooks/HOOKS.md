# Hooks Manifest

Hook source of truth for `agent-framework/scripts/install.sh`. Each row maps
to a hook entry that gets registered in `~/.claude/settings.json` when L1
is installed on a machine.

| Hook | Category | Event | Matcher | Timeout | Purpose |
|------|----------|-------|---------|---------|---------|
| guard-acp-direct-edit.sh | general | PreToolUse | Edit,Write,MultiEdit | 3 | Warn on direct edits to `agent-context/` (enforces ACP skill usage) |
| guard-deployed-artifact-edit.sh | general | PreToolUse | Edit,Write | 3 | Warn on edits to deployed runtime (`~/.claude/skills/`, `~/.codex/skills/`, etc.) instead of source |
| guard-permission-bypass.sh | general | PreToolUse | Edit,Write,MultiEdit | 3 | Block agent edits to permission / hook / MCP config (`~/.claude/settings.json`, hooks, etc.). Enforces `no-permission-bypass.md` constraint. |
