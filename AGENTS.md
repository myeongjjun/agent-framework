# AGENTS.md

> ACP guide for AI agents.

## ⚠️ Critical Rule

**agent-context/ 파일 직접 수정 금지.**
**반드시 ACP Skills 사용.**

위반 시 context 동기화 깨짐.

---

## Agent Context Pack (ACP) v1.0

### Directory Structure

| Directory | Access |
|-----------|--------|
| `/agent-context/decisions/` | **READ-ONLY** → `/acp-decision` |
| `/agent-context/constraints/` | **READ-ONLY** → `/acp-constraint` |
| `/.agent/` | **VIA SKILL** → `/handoff`, `/takeover` |

### Session Workflow

| Phase | Action |
|-------|--------|
| **Start** | Read constraints/ → Read decisions/ → `/takeover` |
| **During** | `/acp-decision`, `/acp-constraint` |
| **End** | `/handoff` |

### ACP Skills

| Skill | When |
|-------|------|
| `/acp-decision` | 아키텍처 결정 |
| `/acp-constraint` | 제약 추가 |
| `/handoff` | 세션 종료 |
| `/takeover` | 세션 시작 |

### Agent Notes

- **Codex**: Auto-reads AGENTS.md
- **Claude Code**: Auto-loaded via CLAUDE.md → AGENTS.md symlink

<!-- ACP:TEMPLATE_END -->

<!-- ACP:CRITICAL_CONSTRAINTS -->
### Critical Constraints (auto-synced)

- **Framework Push Dual Review**: Public agent-framework push requires Claude + Codex review PASS → [`security-framework-push-dual-review.md`](agent-context/constraints/security-framework-push-dual-review.md)
- **Skill Language Convention**: English for workflow/logic sections, Korean only for output format examples and trigger phrases → [`code-style-skill-language-convention.md`](agent-context/constraints/code-style-skill-language-convention.md)
<!-- ACP:CRITICAL_CONSTRAINTS_END -->

## Project Info

**Name**: Agent Framework
**Purpose**: ACP 스킬 개발 및 Agent Context Pack 표준 정의
**Stack**: Markdown, Bash, YAML

## Build & Deploy

**Canonical entry point**: `./scripts/sync-all.sh` — deploys skills,
hooks, **and agents** in one call. Prefer this for day-to-day use.
See ADR-016 (amended by ADR-025) and ADR-027 (agents).

```bash
# Canonical: deploy skills + hooks + agents together
./scripts/sync-all.sh

# Dry-run preview
./scripts/sync-all.sh --dry-run
```

Lower-level tools (used by `sync-all.sh` or when you need fine-grained
control):

```bash
# Skill sync (see ADR-016)
./sync-skills.sh --status                 # status only
./sync-skills.sh --push                   # Claude only
./sync-skills.sh --codex --push           # Codex only
./sync-skills.sh --target both --push     # both
./sync-skills.sh --push --dry-run         # preview
./sync-skills.sh --list                   # list skills

# Hook sync (see ADR-021)
./sync-hooks.sh --status
./sync-hooks.sh --push                    # all categories
./sync-hooks.sh --push --profile <name>   # general + observability + <name>

# Agent sync (see ADR-027)
./sync-agents.sh --status                 # status only
./sync-agents.sh --push                   # source → ~/.claude/agents/
./sync-agents.sh --list                   # show name + model + tools
./sync-agents.sh --push --dry-run         # preview
```

**Source layout**:
- `skills/<name>/SKILL.md` — user-facing slash commands
- `hooks/<category>/<name>.sh` — lifecycle hooks
- `agents/<name>.md` — internal worker agent definitions (NOT slash
  commands; spawned via `claude --agent <name>`)

---

| Section | Reference | Added |
|---------|-----------|-------|
| Project Info | - | 2026-01-15 |
| Build & Deploy | - | 2026-01-15 |
