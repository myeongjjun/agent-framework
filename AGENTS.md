# AGENTS.md — L1 baseline

> Read by every agent (Claude Code, Codex CLI, ...) in every persona
> that inherits from this framework. Personas append below this base
> with their own AGENTS.md; they never edit the base itself.

## ⚠️ Critical Rule

**agent-context/ 파일 직접 수정 금지.**
**반드시 ACP Skills 사용.**

위반 시 context 동기화 깨짐.

## Agent Context Pack (ACP)

### Directory Structure

| Directory | Access |
|---|---|
| `/agent-context/decisions/` | **READ-ONLY** → `/acp-decision` |
| `/agent-context/constraints/` | **READ-ONLY** → `/acp-constraint` |

### Session Workflow

| Phase | Action |
|---|---|
| **Start** | Read constraints/ → Read decisions/ (agentmemory hooks auto-load recall in supported personas) |
| **During** | `/acp-decision`, `/acp-constraint` for new decisions / constraints |

### Universal ACP skills (delivered by L1 install)

| Skill | When |
|---|---|
| `/acp-init` | Bootstrap a new project's ACP structure |
| `/acp-decision` | Record an architectural decision |
| `/acp-constraint` | Add or review a constraint |

## Layering

| Layer | Repo | Adds |
|---|---|---|
| **L1 — baseline (this repo)** | `agent-framework` | ACP standard, codex skill, sib, security guards, AGENTS.md base |
| **L2 — persona** | Each persona repo | Persona-specific overlay (e.g., domain MCP servers, persona-specific constraints) |
| **L3 — domain pack** | Project-root pack | Project-specific overlay (active by cwd) |

Each layer **appends** to higher layers — lower layers never remove or
override what an upper layer installs.

## L1-installed surfaces

| Surface | Contents |
|---|---|
| `~/.claude/skills/{acp-*,codex}` | symlink to this repo's `skills/` |
| `~/.codex/skills/{acp-*,codex}` | same source |
| `~/.local/bin/sib` | cmux sibling-agent launcher (git-worktree opt-in via `--worktree`) |
| `~/.claude/hooks/guard-acp-direct-edit.sh` | block agent edits to `agent-context/` |
| `~/.claude/hooks/guard-deployed-artifact-edit.sh` | block agent edits to deployed runtime |
| `~/.claude/hooks/guard-permission-bypass.sh` | block agent edits to permission/hook/MCP config |
| `~/.claude/AGENTS.md.framework-base` | the base every persona's AGENTS.md starts from |

Install: `bash ~/personal/agent-framework/scripts/install.sh`.
Update: `bash ~/personal/agent-framework/scripts/check-update.sh` (cron).
Verify: `bash ~/personal/agent-framework/scripts/verify.sh` (called from SessionStart hook).

## ADR / Constraint conventions

L1 uses AWS Well-Architected ADR status terminology:

| Status | Meaning |
|---|---|
| **Proposed** | Drafted, not yet adopted |
| **Accepted** | Adopted and in effect |
| **Rejected** | Considered but not adopted |
| **Deprecated** | No longer recommended, no successor |
| **Superseded** | Replaced by another ADR |

Cross-references in frontmatter: `Supersedes`, `Superseded by`, `Amends`,
`Amended by`. See `README.md` for the full table and references.

## Language Policy

- User-facing responses default to Korean unless the user requests
  another language.
- Agent-facing instructions, task briefs, reviews, handoffs, and
  workflow notes may use English when it improves brevity, token
  efficiency, or technical precision.
- Preserve code, commands, logs, file paths, API names, and exact
  error messages in their original form.

## Critical constraints (active L1)

- **No Permission Bypass** — agent must not auto-grant permissions or
  modify settings.json / hooks / MCP config. See
  [`agent-context/constraints/no-permission-bypass.md`](agent-context/constraints/no-permission-bypass.md).
- **Skill Language Convention** — English for workflow/logic sections,
  Korean reserved for output examples and trigger phrases. See
  [`agent-context/constraints/code-style-skill-language-convention.md`](agent-context/constraints/code-style-skill-language-convention.md).
- **Hook Source of Truth** — hook source lives here; deployed copies
  under `~/.claude/hooks/` are read-only artefacts of `install.sh`.
  See [`agent-context/constraints/hook-source-of-truth.md`](agent-context/constraints/hook-source-of-truth.md).
