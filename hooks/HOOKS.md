# Hooks Manifest

Hook source of truth for `sync-hooks.sh`. Each row maps to a hook entry in `~/.claude/settings.json`.
The `general` category is always included regardless of `--profile` selection.

| Hook | Category | Event | Matcher | Timeout | Purpose |
|------|----------|-------|---------|---------|---------|
| guard-prod-kubectl.sh | general | PreToolUse | Bash | 5 | Block kubectl write commands on prod context |
| guard-acp-direct-edit.sh | general | PreToolUse | Edit,Write,MultiEdit | 3 | Warn on direct edits to `agent-context/` (enforces ACP skill usage) |
| guard-deployed-artifact-edit.sh | general | PreToolUse | Edit,Write | 3 | Warn on edits to deployed runtime (`~/.orchestrator/`, `~/.claude/skills/`, etc.) instead of source |
| guard-direct-session-control.sh | general | PreToolUse | Bash | 5 | Role-based access: block direct session mutations, require `orchestrator_request` |
| session-start-review.sh | observability | SessionStart | | 5 | Review previous session on new session start |
