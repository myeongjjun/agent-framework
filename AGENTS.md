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

```bash
# 스킬 동기화 상태 확인 (Claude, 기본)
./sync-skills.sh --status

# 소스 → Claude 배포
./sync-skills.sh --push

# 소스 → Codex 배포
./sync-skills.sh --codex --push

# 소스 → 양쪽 배포
./sync-skills.sh --target both --push

# 미리보기 (dry-run)
./sync-skills.sh --push --dry-run

# 스킬 목록
./sync-skills.sh --list
```

---

| Section | Reference | Added |
|---------|-----------|-------|
| Project Info | - | 2026-01-15 |
| Build & Deploy | - | 2026-01-15 |
