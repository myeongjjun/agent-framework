---
name: acp-init
version: 1.4.0
description: >
  Initialize or upgrade Agent Context Pack (ACP) structure in the current project.
  Creates AGENTS.md (pure ACP guide), decisions/, constraints/ directories.
  Supports Init mode (new) and Upgrade mode (existing AGENTS.md).
trigger_phrases:
  - "init acp"
  - "setup acp"
  - "initialize agent context"
  - "ACP 초기화"
  - "에이전트 컨텍스트 설정"
  - "acp 설정"
---

# ACP Init — Initialize Agent Context Pack

## Purpose

Set up the ACP directory structure in a project so any agent can share context through standard files.

**핵심 원칙:**
- AGENTS.md = 순수 ACP 가이드 (프로젝트 정보 없음)
- agent-context/ = READ-ONLY (스킬로만 수정)
- `<!-- ACP:TEMPLATE_END -->` 마커로 템플릿/커스텀 영역 구분

## What Gets Created

```
project/
├── CLAUDE.md → AGENTS.md       # Symlink for Claude Code auto-loading
├── AGENTS.md                   # ACP guide for agents (source of truth)
├── agent-context/
│   ├── decisions/              # Architecture Decision Records
│   │   ├── README.md           # ADR format guide
│   │   └── INDEX.md            # Decision index
│   └── constraints/            # Immutable constraints
│       ├── README.md           # Constraint format guide
│       └── INDEX.md            # Constraint index
└── .gitignore                  # Updated to exclude .agent/
```

## Modes

### Init Mode (default)

- **조건**: AGENTS.md 없음
- **동작**: 템플릿으로 새로 생성 (마커 포함)

### Upgrade Mode

- **조건**: AGENTS.md 있음
- **동작**:
  1. `<!-- ACP:TEMPLATE_END -->` 마커 찾기
  2. 마커 이후 내용 추출 (프로젝트 커스텀 영역)
  3. 최신 템플릿 생성 (마커까지)
  4. 추출한 커스텀 내용 붙이기

**경계선**: `<!-- ACP:TEMPLATE_END -->` 마커

**Fallback** (마커 없는 구버전):
- `## Project-Specific Sections` 헤더 찾기
- 또는 첫 번째 `---` 구분선 찾기
- 없으면 전체 교체 + 경고

## Actions

### Init Mode

1. **Check if already initialized** - AGENTS.md 있으면 → Upgrade Mode로 전환
2. **Create directories** - `mkdir -p agent-context/decisions agent-context/constraints`
3. **Create AGENTS.md** - Use template from [templates.md](templates.md)
4. **Create CLAUDE.md symlink** - `ln -s AGENTS.md CLAUDE.md`
   - If CLAUDE.md already exists and is NOT a symlink to AGENTS.md, warn user and skip
5. **Create agent-context/decisions/README.md** - ADR format guide
6. **Create agent-context/decisions/INDEX.md** - Empty index
7. **Create agent-context/constraints/README.md** - Constraint format guide
8. **Create agent-context/constraints/INDEX.md** - Empty index
9. **Update .gitignore** - Add `.agent/` if not present
10. **Report completion** - Show created files and next steps

### Upgrade Mode

1. **Read existing AGENTS.md**
2. **Find marker** - `<!-- ACP:TEMPLATE_END -->` 찾기
3. **Extract custom content** - 마커 이후 내용 보존
4. **Generate new template** - 최신 템플릿 (마커까지)
5. **Append custom content** - 보존한 내용 붙이기
6. **Verify CLAUDE.md symlink** - If missing or not a symlink to AGENTS.md, create/fix it
7. **Update other ACP files if needed** - decisions/constraints 디렉터리 확인
8. **Report changes** - 업데이트 완료 보고

## Templates

For detailed templates, see [templates.md](templates.md).

## Notes

- AGENTS.md에 프로젝트 정보 없음 (README.md, package.json 참조)
- agent-context/ 직접 수정 금지 → 스킬 사용 강제
- 마커 이후 영역에 프로젝트별 커스텀 내용 추가 가능
