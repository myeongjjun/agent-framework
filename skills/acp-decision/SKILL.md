---
name: acp-decision
version: 1.2.0
description: >
  Record an architectural decision to /agent-context/decisions/ directory.
  Use when a significant technical decision has been made that future agents should know about.
trigger_phrases:
  - "record decision"
  - "ADR"
  - "architectural decision"
  - "결정 기록"
  - "아키텍처 결정"
  - "의사결정 기록"
  - "add decision"
---

# ACP Decision — Record Architectural Decisions

## ACP Integration

> 이 스킬은 AGENTS.md의 ACP 규칙을 준수합니다.

**⚠️ 중요:**
- `agent-context/decisions/` 직접 수정 금지
- 반드시 이 스킬(`/acp-decision`)을 통해 ADR 생성
- 직접 수정 시 context 동기화 깨짐

**Workflow:**
1. 세션 중 아키텍처 결정 발생
2. `/acp-decision` 스킬 호출
3. ADR 자동 생성 및 INDEX.md 업데이트

## Purpose

Create an Architecture Decision Record (ADR) in the `/agent-context/decisions/` directory so future agents understand why certain choices were made.

**이 스킬이 ADR 생성의 유일한 방법입니다.**

## When to Use

- A significant technical decision was made
- Choosing between multiple valid approaches
- Establishing a pattern or convention
- Deprecating or changing a previous decision

## Actions

1. **Verify ACP structure** - Check `agent-context/decisions/` directory exists
2. **Gather information** - Title, Context, Decision, Alternatives, Consequences
3. **Generate filename** - `YYYY-MM-DD-<slug>.md`
4. **Determine ADR number** - Increment from last ADR
5. **Create decision file** - Use template from [templates.md](templates.md)
6. **Update INDEX.md** - Add entry to decisions index
7. **Report completion** - Show created file path

## Quick Reference

**Filename format:** `agent-context/decisions/YYYY-MM-DD-<slug>.md`

**Status values:**
| Status | Meaning |
|--------|---------|
| `proposed` | Under discussion |
| `accepted` | Decided and in effect |
| `deprecated` | No longer recommended |
| `superseded` | Replaced by another ADR |

**Required fields:** Date, Status, Context, Decision, Consequences

## Templates

For detailed ADR template, see [templates.md](templates.md).

## Notes

- Default status is `accepted` (most decisions recorded after being made)
- When superseding, update old ADR's status and link to new one
- Keep decisions concise but complete
