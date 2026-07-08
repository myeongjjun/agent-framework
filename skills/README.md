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
| `dispatch` | Single-agent sibling launch via sib, placed in the workspace matching the task's workdir | `sib` + `cmux` |
| `collab` | Dual-agent same-task cross-review in sib worktrees, merge via `agent-promote.sh` | `sib` + `cmux` + `git` |
| `pane-msg` | Deterministic message delivery to an already-open cmux pane (resolve → gate → verified send); placement reuse-or-create verdicts | `cmux` + `jq` |

## What's NOT here

Anything persona-specific (organisation MCP wiring, ticket-system skills,
domain dashboards) lives in the persona's L2 repo, not here.
