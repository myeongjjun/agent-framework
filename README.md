# Agent Framework

A portable framework for managing AI agent capabilities: skills, hooks, constraints, and an autonomous improvement loop. Supports **Claude Code** and **Codex CLI**.

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

This repo is the **framework layer** — reusable infrastructure for any AI agent workflow. Add your own domain skills on top.

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
| `observability` | `session-start-review.sh` | Review previous session on start |

### Scripts

| Script | Purpose |
|--------|---------|
| `scripts/sync-all.sh` | Unified deploy: skills + hooks |
| `scripts/agent-release.sh` | Capability versioning (tag, rollback, diff) |
| `scripts/extract-traces.py` | Unified Claude + Codex transcript extractor |
| `scripts/analyze-activity.sh` | Activity analysis with per-agent breakdown |
| `scripts/apply-proposal.sh` | Proposal lifecycle management |

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
| Claude Code CLI | current | Required for Claude deployment target |
| Codex CLI | current | Optional, required for `codex`/`collab` skills |

## License

MIT
