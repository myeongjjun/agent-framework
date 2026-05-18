# Agent Framework

An **opinionated agent-ops kit** for managing AI agent capabilities: skills, hooks, constraints, an autonomous improvement loop, **a long-lived orchestrator daemon, and an auto-approver agent pattern**. Supports **Claude Code** and **Codex CLI**.

## Scope

agent-framework is deliberately opinionated. It bundles the specific primitives we have found effective for running AI agents over long sessions — not a minimal primitives library. Adopting agent-framework means adopting these opinions:

- **Session backend**: [`cmux`](https://github.com/myeongjjun/cmux) + [`zmx`](https://github.com/myeongjjun/zmx) for persistent agent sessions. The orchestrator and conductor scripts assume these tools are available.
- **Long-lived orchestrator daemon**: a single bash daemon at `~/.orchestrator/` mediates dispatch, rotation, cleanup, and health. Direct session mutations are blocked by `guard-direct-session-control.sh`; all changes go through `orchestrator_request --type <...>`.
- **Auto-approver agent**: an approver agent watches permission prompts and auto-approves the safe subset, backed by a policy file and audit log.
- **Worktree-isolated workers**: dispatched workers always run in their own git worktree (non-negotiable for execute mode).

If you want pure skill/hook infrastructure without the orchestrator stack, the `skills/` and `hooks/` subtrees work standalone — the orchestrator scripts only activate when you deploy and start them.

## Quick Start

```bash
# Clone
git clone https://github.com/<your-username>/agent-framework.git
cd agent-framework

# Deploy all skills + hooks
./scripts/sync-all.sh

# Check status
./sync-skills.sh --status
```

## What's Included

This repo is the **opinionated agent-ops kit** — the specific primitives we run in production, not a generic primitives library. Add your own domain skills on top.

### Skills (11)

| Category | Skills | Purpose |
|----------|--------|---------|
| **ACP** | `acp-init`, `acp-decision`, `acp-constraint` | Agent Context Pack: decisions, constraints, project context |
| **Collaboration** | `collab`, `codex`, `handoff`, `takeover`, `harness` | Multi-agent coordination, context handoff, meta-skill design |
| **Observability** | `observe`, `improve` | Analyze agent activity, propose and apply improvements |
| **Utility** | `quick-dashboard` | Instant Streamlit dashboard from any data source |

### Hooks

| Category | Hooks | Purpose |
|----------|-------|---------|
| `general` | `guard-prod-kubectl.sh` | Block kubectl writes on prod context |
| `general` | `guard-acp-direct-edit.sh` | Enforce ACP skill usage for agent-context/ edits |
| `general` | `guard-deployed-artifact-edit.sh` | Block direct edits of deployed runtime (~/.orchestrator/, ~/.approver/) |
| `general` | `guard-direct-session-control.sh` | Role-based access: block direct session mutations, force orchestrator_request path |
| `observability` | `session-start-review.sh` | Review previous session on start |

### Scripts

| Script | Purpose |
|--------|---------|
| `scripts/sync-all.sh` | Unified deploy: skills + hooks + agents + orchestrator |
| `scripts/conductor.sh` | Dispatch + cleanup + tidy + gc lifecycle for sibling sessions |
| `scripts/orchestrator/` | Long-lived daemon subtree — `daemon.sh`, `protocol.sh`, `health.sh`, `start-agent.sh`, `stop-agent.sh`, `team.sh`, `effects/`, `core/` |
| `scripts/agent-release.sh` | Capability versioning (tag, rollback, diff) |
| `scripts/extract-traces.py` | Unified Claude + Codex transcript extractor |
| `scripts/analyze-activity.sh` | Activity analysis with per-agent breakdown |
| `scripts/apply-proposal.sh` | Proposal lifecycle management |
| `scripts/handoff-rotate.sh` | Session rotation via orchestrator (compress RAM without losing context) |
| `scripts/test-conductor.sh` | End-to-end conductor test suite |

### Agents

| Agent | Role |
|-------|------|
| `agents/approver.md` | Monitors cmux surfaces for stuck workers, auto-approves safe operations, performs root-cause analysis on why approval was needed |

## Architecture

```
agent-framework/
├── skills/                            # 11 framework skills
├── hooks/                             # Guard + observability hooks
│   ├── general/                       # Common guards
│   └── observability/                 # Session review
├── scripts/                           # Deploy, analyze, release, extract
├── agent-context/                     # ACP: decisions + constraints
│   ├── decisions/                     # Architecture Decision Records
│   └── constraints/                   # Immutable project rules
├── templates/                         # Skill, agent, plugin templates
├── configs/                           # Claude, Codex, Cursor configs
├── sync-skills.sh                     # Skill sync (Claude/Codex)
├── sync-hooks.sh                      # Hook sync (category + profile)
├── AGENTS.md                          # ACP guide for agents
└── FORKING.md                         # Fork and customization guide
```

## Adding Your Domain

1. **Fork** this repo
2. **Add domain skills** as `skills/<domain>-<name>/` directories
3. **Add domain hooks** under `hooks/<domain>/` and register in `hooks/HOOKS.md`
4. **Deploy**: `./scripts/sync-all.sh`
5. **Initialize ACP** in your project: `/acp-init`

See [FORKING.md](FORKING.md) for the full step-by-step guide.

## Agent Observability Loop

Autonomous improvement cycle: observe agent behavior, diagnose issues, propose changes, apply with human approval.

```
[Use agent normally] --> transcripts auto-recorded
        |
/observe --> analyze traces --> generate proposals
        |
/improve --> select proposal --> preview --> approve --> deploy
        |
/observe --> verify improvement --> next cycle
```

## Deployment

```bash
# Deploy everything (recommended)
./scripts/sync-all.sh

# Skills only
./sync-skills.sh --target both --push

# Hooks only (with profile)
./sync-hooks.sh --push --profile myproject

# Preview changes
./scripts/sync-all.sh --dry-run
```

## Release Management

```bash
./scripts/agent-release.sh tag "Description"    # Tag current state
./scripts/agent-release.sh list                  # List releases
./scripts/agent-release.sh rollback v1.0.3       # Rollback
./scripts/agent-release.sh current               # Show current version
```

## Project Aliases (ADR-033)

The orchestrator's zmx session names follow the format
`{family}-{project_slug}-{task_slug}-{index}` and must fit within
zmx's 44-char limit. Projects whose directory basename is **27 or
more characters** (e.g. `clickhouse-upgrade-framework`) overflow
this limit because the project portion alone consumes the entire
budget left for the task slug.

The orchestrator handles this with a two-layer mechanism:

1. **Explicit alias (preferred)** — register a short name for the
   project in `~/.orchestrator/project-aliases.json`. The
   orchestrator substitutes the alias for the long basename when
   constructing the slot.
2. **Hash safety net** — if no alias is registered and the slot
   would overflow, the orchestrator falls back to
   `{family}-{6-char-hash}-{index}`. The slot loses zmx-grep
   readability but never fails; the original task name is still
   visible in `claude --name` and `state.json`.

### Managing aliases

```bash
# List registered aliases
team.sh alias list

# Register a new alias (validated: kebab-case, 2–25 chars, no collisions)
team.sh alias add /path/to/your-very-long-project-dir my-proj

# Preview what an alias lookup returns for a given cwd
team.sh alias check /path/to/your-very-long-project-dir

# Remove an alias
team.sh alias rm /path/to/your-very-long-project-dir
```

`check` additionally warns when an unaliased cwd has a basename
of 27+ chars (the threshold beyond which the hash fallback fires).
The alias file is stored at `~/.orchestrator/project-aliases.json`
and is per-user/per-machine local — fork adopters seed their own.

### What aliases don't change

- `cwd`, `task_slug`, `worktree_path`, `claude --name`, and
  `state.json` task keys are all preserved verbatim regardless of
  alias resolution.
- Only the zmx session identifier (`slot_name`) is affected.
- `claude --resume <session-id>` continues to work as normal —
  session storage is keyed by cwd, not by slot name.

## Prerequisites

| Requirement | Version | Notes |
|-------------|---------|-------|
| `bash` | 4.0+ | Required by sync/release scripts |
| `jq` | 1.6+ | Required by analysis and hook workflows |
| `python3` | 3.8+ | Required for `extract-traces.py` |
| `rsync` | current | Required by `sync-all.sh` Step 5 (orchestrator subtree) |
| Claude Code CLI | current | Required for Claude deployment target |
| Codex CLI | current | Optional, required for `codex`/`collab` skills |
| [`cmux`](https://github.com/myeongjjun/cmux) + [`zmx`](https://github.com/myeongjjun/zmx) | current | Required for orchestrator, conductor, handoff-rotate. Without these, only the standalone skill/hook subset works. |

## License

MIT
