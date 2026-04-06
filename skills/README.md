# Skills Manifest

All skills in `agent-framework`, classified as `framework` (portable, keep when forking).

See [FORKING.md](../FORKING.md) for the full fork workflow and customization order.

## Dependency Baseline

- `bash` 4.0+, `jq` 1.6+, and `python3` 3.8+ are the repo's baseline CLI/runtime dependencies for sync, release, and analysis scripts.
- `quick-dashboard` uses `uv` to install `streamlit`, `plotly`, `pandas`, and `requests`, then adds source-specific drivers only when needed.

## Skill Index

| Skill | Portable? | Dependency Profile | Description |
|-------|-----------|--------------------|-------------|
| `acp-init` | yes | No extra CLI or MCP required. Needs repo write access. | Initialize ACP structure in a project |
| `acp-decision` | yes | No extra service required. Needs `agent-context/decisions/` plus write access. | Record architectural decisions |
| `acp-constraint` | yes | No extra service required. Needs `agent-context/constraints/` plus write access. | Manage project constraints |
| `collab` | yes | Required: Git with `git worktree`, current Codex CLI, and a writable repo. | Dual-agent worktree collaboration with cross-review |
| `codex` | yes | Required: current Codex CLI with `codex exec` support. | Codex CLI integration and full-cycle handoff |
| `handoff` | yes | Recommended: `jq` 1.6+ for automatic session metadata extraction. | Context handoff between agents |
| `takeover` | yes | No extra service required. Reads `.agent/` and ACP files if present. | Recover context from a handoff entry |
| `harness` | yes | No external service required. Needs repo write access. | Meta-skill: design agent teams and skills |
| `observe` | yes | Required: `python3` 3.8+, `jq` 1.6+, and transcript/log access under `~/.claude/`. | Analyze agent activity, diagnose patterns, generate proposals |
| `improve` | yes | Required: proposal files from `/observe`, repo write access, and deploy/tag scripts. | Apply improvement proposals with preview, deploy, and release |
| `quick-dashboard` | yes | Required: `uv`, `streamlit`, `plotly`, `pandas`, and `requests`. | Instant Streamlit dashboard from a data source |

## Notes

- `quick-dashboard` is framework because the delivery pattern is reusable even when the dashboard reads domain-specific data.
- Add your own domain skills as `skills/<domain>-<name>/` directories. See [FORKING.md](../FORKING.md) for guidance.
