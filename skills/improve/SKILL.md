---
name: improve
version: 1.0.0
description: >
  Review generated improvement proposals, preview concrete source changes, apply approved
  proposals, release them, and record the resulting before/after metrics.
trigger_phrases:
  - "/improve"
  - "개선 적용"
  - "proposal 적용"
  - "에이전트 개선"
---

# Improve — Semi-Autonomous Improvement Loop

## ACP Integration

- Implements **ADR-022 Phase 3** (`../../agent-context/decisions/2026-03-25-agent-observability-improvement-loop.md`).
- Follows **ADR-017 Rule 2** language convention: English for workflow/notes, Korean only for trigger phrases and output examples.
- If a proposal targets `agent-context/constraints/` or `agent-context/decisions/`, do **not** edit those files directly. Route the change through `/acp-constraint` or `/acp-decision` during Preview and Apply.

## Purpose

Close the loop after `/observe` by taking proposal files from `.agent/observe/proposals/`, presenting them for approval, previewing the concrete code changes, applying the approved improvements, releasing them, and recording the measured outcome for the next observation cycle.

## Inputs

Optional:
- `--days N`: Restrict supporting metric context to the same window used by `./scripts/analyze-activity.sh`
- `--file <name>`: Focus on one proposal file first
- `--status <status>`: Filter to `new`, `approved`, `applied`, or `rejected`

Primary data sources:
- `.agent/observe/proposals/*.md`
- `./scripts/apply-proposal.sh`
- `./scripts/analyze-activity.sh`

## Supporting Commands

Use the helper script instead of ad-hoc parsing when possible:

```bash
./scripts/apply-proposal.sh list
./scripts/apply-proposal.sh show observe-2026-03-25.md
PROPOSAL_TAG=agent-v1.2.3 ./scripts/apply-proposal.sh mark observe-2026-03-25.md applied
./scripts/apply-proposal.sh history
```

## Workflow

### Phase 1: Load

1. Run `./scripts/apply-proposal.sh list` to enumerate proposal files and current status.
2. Read the selected proposal file(s) from `.agent/observe/proposals/`.
3. Parse every `## Proposal:` or `## Proposal N:` block in each file.
4. Derive status from the trailing HTML comment:

```html
<!-- status: applied, tag: agent-v1.2.3, date: 2026-03-25 -->
```

5. Treat missing status comments as `new`.
6. Skip `rejected` and `applied` proposals by default unless the user explicitly asks to review them again.

### Phase 2: Select

1. Present a concise numbered list to the user with:
   - proposal title
   - source file
   - current status
   - one-line evidence summary
2. Ask the user which proposal(s) to apply.
3. Do not apply any proposal without explicit user selection.
4. If one file contains multiple proposal blocks, selection can still happen at the block level, but status recording remains anchored to the source proposal file unless the proposals are split first.

### Phase 3: Preview

1. Read the target files mentioned in each selected proposal.
2. Translate the proposal into concrete edits:
   - exact file paths
   - planned code or text changes
   - expected deploy and release commands
3. Produce a diff-style preview before editing any file.
4. Show the expected impact in metric terms whenever the proposal includes evidence, for example failure rate reduction, lower retry count, or fewer repeated deploy commands.
5. If the proposal is ambiguous, stop here and ask the user to clarify before touching files.

### Phase 4: Apply

Apply approved proposals sequentially so each one gets its own release trace.

1. Execute the planned edits with `Edit` or `Write`.
2. If the proposal modifies ACP-managed files under `agent-context/`, invoke `/acp-constraint` or `/acp-decision` instead of direct file edits.
3. Validate the changed files with the smallest useful check for the target area.
4. Create a normal git commit for the applied change set. This is required because `./scripts/agent-release.sh tag` refuses dirty worktrees.
5. Run `./scripts/sync-all.sh`.
6. Run `./scripts/agent-release.sh tag "Improve: {title}"`.
7. Capture the newly created `agent-vX.Y.Z` tag for the record step.
8. If sync or release tagging fails, stop and leave the proposal status at `approved` until the issue is fixed.

### Phase 5: Record

1. Update the proposal footer comment after a successful release:

```html
<!-- status: applied, tag: agent-vX.Y.Z, date: YYYY-MM-DD -->
```

2. Prefer the helper command so the status format stays consistent:

```bash
PROPOSAL_TAG=agent-vX.Y.Z PROPOSAL_DATE=YYYY-MM-DD \
  ./scripts/apply-proposal.sh mark <file> applied
```

3. Run `./scripts/analyze-activity.sh --compare <tag>` to compare before and after metrics around the release tag.
4. Append a short result note to the proposal file summarizing the metric delta so the next `/observe` cycle can reuse it as evidence.
5. Use `./scripts/apply-proposal.sh history` to review the applied proposal trail when deciding what to observe next.

## Output Format

### Proposal Selection Example

```markdown
## 적용할 개선안 선택

1. Unified Deploy Command
   - 파일: observe-2026-03-25.md
   - 상태: new
   - 근거: deploy 명령 2회 반복

2. Stop Hook for Auto-Analysis
   - 파일: observe-2026-03-25.md
   - 상태: approved
   - 근거: ADR-022 Phase 2 gap

선택할 번호를 알려주세요.
```

### Preview Example

~~~markdown
## 변경 미리보기

### Unified Deploy Command
- 대상 파일: `scripts/sync-all.sh`, `skills/improve/SKILL.md`
- 예상 영향: 반복 Bash 호출 감소, 배포 단계 단순화

```diff
- ./sync-skills.sh --target both --push
- ./sync-hooks.sh --push
+ ./scripts/sync-all.sh
```
~~~

### Apply Result Example

```markdown
## 개선 적용 완료

- 적용안: Unified Deploy Command
- 릴리스 태그: agent-v1.2.3
- 상태 기록: applied
- 비교 결과: Failure rate 8.3% → 3.2% (↓5.1%)
- 다음 관찰 포인트: `/observe`에서 배포 관련 실패 패턴 재확인
```

## Notes

- `/improve` is approval-gated. It prepares and applies changes only after the user selects proposals.
- Use one release tag per applied proposal whenever possible. That keeps `proposal -> commit -> tag -> metric delta` traceable.
- Proposal files may contain multiple proposal blocks. Keep previews block-specific even when the source file status is shared.
- Do not mark a proposal as `applied` until the sync and release steps both succeed.
