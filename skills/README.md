# Skills (L1)

Skills delivered by the L1 framework. Installed automatically into
`~/.claude/skills/<name>` and `~/.codex/skills/<name>` (symlinks back
to this directory) by `scripts/install.sh`.

| Skill | Description | Required runtime |
|---|---|---|
| `acp-init` | Initialize ACP structure (`agent-context/`) in a project | None |
| `acp-decision` | Record an Architecture Decision Record | None |
| `acp-constraint` | Add or review a project constraint | None |
| `codex` | Codex CLI integration and full-cycle delegation | `codex` CLI on PATH |

## What's NOT here

Anything persona-specific (organisation MCP wiring, ticket-system skills,
domain dashboards) lives in the persona's L2 repo, not here.
