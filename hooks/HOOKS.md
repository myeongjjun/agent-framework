# Hooks Manifest

Hook source of truth for `sync-hooks.sh`. Each row maps to a hook entry in `~/.claude/settings.json`.
The `general` category is always included regardless of `--profile` selection.

| Hook | Category | Event | Matcher | Timeout | Purpose |
|------|----------|-------|---------|---------|---------|
| guard-prod-kubectl.sh | general | PreToolUse | Bash | 5 | kubectl prod context write guard |
| session-start-review.sh | observability | SessionStart | | 5 | review previous session on new session start |
