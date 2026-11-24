# orch area profiles

<!-- 씨앗. 설치 때 ~/.local/share/cmux/orch/orch-areas.md 로 한 번 복사되고, 그 파일에 이 기기의 영역을 채운다.
     실제 파일은 로컬 전용이다(공유되지 않는다). 설계: docs/area-lead-design.md (9절: 1단계 프로파일만, 2단계 영역 담당 호출 `brief lead`).
     영역 하나 = `## <area>` 절 하나. Scope 와 Permissions 는 사용자의 계약이라 데스크가 고치지 않는다.
     데스크는 Decision log 와 Lessons 에만 한 줄씩 더한다. -->

<!-- Decision log line format (one decision per line):
     - MM-DD HH:MM | <kind> | by:<user|desk|session|lead> | <what was decided> | ref:<session title or commit>[ | asked][ | reversed_by:<ref>]
     kind: place | answer | close | commit | rules
     `by:lead` = the area lead (`brief lead`) decided it; only the tool writes these lines.
     `asked` = the desk put it under 결정 필요 before it was decided.
     `reversed_by` = a later decision or fact undid it (add it to the old line, and log the new decision too). -->

## <area name>

### Scope
- Covers: <!-- folders, repos, skills -->
- Not this area: <!-- work that touches a more cautious area follows that area -->
- User's words: <!-- the user's own words on how much to delegate here, with date -->

### Permissions
<!-- decide = desk decides and reports under 묻지 않고 정한 것; advise = 결정 필요 with a recommendation; user = Ask first -->
| kind | level |
|---|---|
| place | |
| answer | |
| close | |
| commit | |
| rules | |

### Trial
- Stage: <!-- 1 = profile only; 2 = the desk hands judgment questions to `brief lead` -->
- Baseline: <!-- asked / reversed before the trial, and where the numbers came from -->
- Next stage when: <!-- copied from the design doc -->
- Stop when:

### Decision log

### Lessons
