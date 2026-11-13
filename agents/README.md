# Agents

Custom Claude Code agent definitions managed in this repo and deployed
to `~/.claude/agents/` as copies by `scripts/install.sh` (L1).

These are NOT slash-command-invokable skills. They are agents in the
Claude Code sense — separate identities with their own system prompt,
restricted tools, and (optionally) a specific model. They can be:

1. **Spawned as a main session identity** via `claude --agent <name>`,
   in which case the agent's `initialPrompt` runs as the first user turn
2. **Invoked as a subagent** via the `Agent` tool with
   `subagent_type=<name>` from another claude session

Source format follows the official spec:
<https://code.claude.com/docs/en/sub-agents>

## Layout

| Path | Purpose |
|---|---|
| `agents/<name>.md` | Source agent definition (YAML frontmatter + system prompt body) |
| `~/.claude/agents/<name>.md` | Deployed copy (`scripts/install.sh` writes here) |

Files must be flat at the top of `agents/` — no subdirectories.
`README.md` and `INDEX.md` are skipped by `install.sh`.

## Conventions

- **Filename = agent name**: `my-agent.md` → agent `my-agent`
- **YAML frontmatter required**: at minimum `name` + `description`
- **Restrict tools** explicitly when the agent doesn't need everything
  (`tools: Read, Bash, Write` is much safer than inheriting all)
- **Pick the right model**: prefer `haiku` for deterministic workers,
  `sonnet` for code analysis, `opus` only when reasoning depth matters
- **Document the trigger context** in `description` so future readers
  know whether the agent is meant to be invoked manually, by another
  agent, or by a script

## Current agents

| Agent | Purpose |
|---|---|
| `orch` | cmux session desk. Runs in its own pane via `claude --agent orch`, launched each morning by `~/.config/cmux/morning-brief.sh` (see `cmux/`). |

## Deploy

```bash
bash scripts/install.sh            # copy agents/*.md → ~/.claude/agents/
bash scripts/install.sh --dry-run  # preview
bash scripts/verify.sh             # drift check (deployed copy vs source)
```

After deployment, restart any active claude sessions for changes to
take effect (agents load at session start).
