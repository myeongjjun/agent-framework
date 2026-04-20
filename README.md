# Agent Framework

An **opinionated agent-ops kit** for managing AI agent capabilities: skills, hooks, constraints, an autonomous improvement loop, **a long-lived orchestrator daemon, and an auto-approver agent pattern**. Supports **Claude Code** and **Codex CLI**.

## Scope

agent-framework is deliberately opinionated. It bundles the specific primitives we have found effective for running AI agents over long sessions — not a minimal primitives library. Adopting agent-framework means adopting these opinions:

- **Session backend**: [`cmux`](https://github.com/myeongjjun/cmux) + [`zmx`](https://github.com/myeongjjun/zmx) for persistent agent sessions. The orchestrator and conductor scripts assume these tools are available.
- **Long-lived orchestrator daemon**: a single bash daemon at `~/.orchestrator/` mediates dispatch, rotation, cleanup, and health. Direct session mutations are blocked by `guard-direct-session-control.sh`; all changes go through `orchestrator_request --type <...>`.
- **Auto-approver agent**: an approver agent watches permission prompts and auto-approves the safe subset, backed by a policy file and audit log.
- **Worktree-isolated workers**: dispatched workers always run in their own git worktree (non-negotiable for execute mode).

If you want pure skill/hook infrastructure without the orchestrator stack, the `skills/` and `hooks/` subtrees work standalone — the orchestrator scripts only activate when you deploy and start them.

See ADR: `agent-context/decisions/2026-04-20-agent-framework-opinionated-kit.md` for the scope decision.

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
