# Agents

Custom Claude Code agent definitions managed in this repo and deployed
to `~/.claude/agents/` via `./sync-agents.sh` (or the canonical
`./scripts/sync-all.sh`).

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
| `~/.claude/agents/<name>.md` | Deployed copy (sync-agents.sh writes here) |

Files must be flat at the top of `agents/` — no subdirectories.
`README.md` and `INDEX.md` are skipped by the sync script.

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

_None._ The previous `handoff-runner` agent was removed in Round 6 of
the handoff-rotation work (see ADR-026 / ADR-027). The rotation flow is
now orchestrated entirely by `scripts/handoff-rotate.sh` with no
helper-agent layer.

This directory and its sync tooling remain in place as infrastructure
for future agent definitions.

## Sync workflow

```bash
# Status (default)
./sync-agents.sh

# Push source → deployed
./sync-agents.sh --push

# Or via the canonical entry point
./scripts/sync-all.sh

# List discovered agents with model/tools summary
./sync-agents.sh --list

# Dry-run preview
./sync-agents.sh --push --dry-run
```

After deployment, restart any active claude sessions for changes to
take effect (agents load at session start).
