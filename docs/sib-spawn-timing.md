# sib spawn 타이밍 — TUI 에이전트 부팅·제출 latency 분해

> 작성: 2026-06-22 / 검증 환경: cmux (this build), macOS, claude (Opus 4.8 1M), codex v0.141.0
> 위치: **L1 (agent-framework)** — `bin/sib`의 프롬프트 주입 타이밍 근거.
> 관련: [cmux-cli-reference.md §9](./cmux-cli-reference.md)(입력 제출 함정 정본), [sib-dispatch-improvement.md](./sib-dispatch-improvement.md).

`sib spawn ... -- "<prompt>"`는 새 pane에서 에이전트를 띄우고, 그 에이전트의
입력창에 task 프롬프트를 넣은 뒤 enter를 쳐서 제출한다. "프롬프트를 넣고 enter를
치기까지" 걸리는 시간이 체감 latency다. 이 문서는 그 latency가 **어디서 나오는지**
2026-06-22 실측으로 분해하고, 적용한 개선과 그 근거를 남긴다.

## TL;DR

- 체감 latency의 주범은 에이전트 종류가 아니라 **프롬프트 길이 × pane 폭**이었다.
  좁은 split pane이 입력 텍스트를 줄바꿈(soft-wrap)하면, 제출 대기 루프의 24자
  "에코 확인" `grep -F`가 줄 경계에 걸려 매칭 실패 → pane이 한 줄로 리플로우될
  때까지(≈21초) 헛돌다 30초 상한 직전에야 제출.
- **실측: codex 27자 프롬프트 42초, claude 21자 프롬프트 2.9초.** 같은 코드 경로,
  차이는 오직 wrap 여부였다. → 긴 프롬프트면 claude도 똑같이 느려진다.
- 마커(`❯`/`›`) 매칭 실패(ANSI/글리프 문제)는 **이번 실측에서 재현되지 않았다.**
  read-screen이 마커를 그대로(`\u{276f}`/`\u{203a}`) 내보내 부팅 대기는 빨랐다.
- 고친 뒤: **codex 42초 → 4.7초, claude 긴 프롬프트 → 3.1초.**

## spawn의 3단계 타이밍 모델

`bin/sib`의 spawn은 프롬프트 주입을 세 구간으로 처리한다:

| 단계 | 무엇을 기다리나 | 신호 | 의도된 상한 |
|---|---|---|---|
| ① 부팅 대기 | 입력창이 **그려질** 때까지 | 마커 `❯`(claude) / `›`(codex) | ~20초 |
| ② 제출 대기 | 텍스트가 **안착**하고 제출 가능 상태까지 | 프롬프트 에코 보임 + (codex) 큐 해제 | ~30초 |
| ③ 보험 엔터 | 제출이 **먹혔는지** | 작업 신호 없으면 enter 1회 더 | 1초 |

세 단계 모두 "키를 보내고 → read-screen으로 확인 → 다음 단계"라는 확인 사이클을
지킨다(cmux-cli-reference §9의 핵심 교훈). 문제는 **확인 신호를 무엇으로 잡느냐**에
있었다.

## 근본 원인 — ② 제출 대기의 wrap 매칭 실패

개선 전 코드(요지):

```bash
head_chars="${prompt:0:24}"
for _ in $(seq 1 60); do
  scr="$(cmux read-screen ... --lines 40)"
  if grep -qF "${head_chars}" <<<"${scr}" && ! grep -qF "tab to queue message" <<<"${scr}"; then
    break
  fi
  sleep 0.5
done
cmux send-key ... enter
```

`head_chars`는 **공백 포함 첫 24자**, `grep -qF`는 **한 화면 줄 안에서만** 매칭한다.
sib sibling은 split pane(좁음)이라 입력창이 텍스트를 wrap한다:

```
› echo hello from
  codex probe
```

찾으려는 `echo hello from codex pr`(24자)가 두 줄로 쪼개져 한 줄로는 절대 안 나타난다.
`bash -x` 타임스탬프 트레이스로 확인한 실제 진행:

```
10:14  for _ ... ; grep 'echo hello from codex pr' → 실패 ; sleep 0.5   ← 텍스트는 화면에 있음
 ...   (≈21초간 매 0.5초 반복, 매번 매칭 실패)
10:35  scr=... '› echo hello from codex probe'  ← pane이 한 줄로 리플로우됨
10:35  grep 'echo hello from codex pr' → 성공 ; break ; send-key enter
```

큐 통지(`tab to queue message`)는 **트레이스 전체에서 한 번도 나타나지 않았다.**
즉 이번 느림은 codex 큐 문제가 아니라 **순수하게 wrap 매칭 실패**였다.

### 왜 claude도 "은근히" 느린가

codex vs claude 문제가 아니라 **프롬프트 길이 vs pane 폭** 문제다.

| 케이스 | 프롬프트 | pane에서 | 결과 |
|---|---|---|---|
| claude | `echo hello from probe` (21자) | 한 줄에 들어감 | 즉시 매칭 → 2.9초 |
| codex | `echo hello from codex probe` (27자) | wrap | 30초 루프 → 42초 |

dispatch가 던지는 task 프롬프트는 보통 길다 → claude에서도 wrap → 같은 30초 헛돔.

## 적용한 개선 (커밋 참조)

### 개선 1 — 제출 에코 매칭을 wrap 면역으로

화면과 needle 양쪽에서 공백·개행을 제거하고 비교한다. 줄바꿈 위치와 무관하게
매칭되며, 24자 특이성은 유지돼 오탐 위험이 낮다.

```bash
needle="$(printf '%s' "${prompt:0:24}" | tr -d ' \n')"
...
scr_ns="$(printf '%s' "${scr}" | tr -d ' \n')"
grep -qF "${needle}" <<<"${scr_ns}"
```

### 개선 2 — 에이전트별 제출 게이트 분리

큐 가드는 codex에만 적용한다(회귀-치명). claude는 입력 큐가 없어 텍스트가 보이면
즉시 제출.

```bash
if grep -qF "${needle}" <<<"${scr_ns}"; then
  if [[ "${agent}" == "codex" ]]; then
    grep -qF "tab to queue message" <<<"${scr}" || break   # 큐 해제 후 제출
  else
    break                                                   # claude: 즉시
  fi
fi
```

**codex 큐 삼킴 가드는 그대로 보존**(cmux-cli-reference §9 함정 2, 커밋 9c7f7f8).
보험 엔터(③)도 손대지 않았다 — 큐가 한 박자 늦게 풀리거나 자동완성이 첫 enter를
삼킨 경우의 백스톱.

### 개선 3 — 적응형 폴링

부팅·제출 루프 모두 초반 10회는 0.1초, 이후 0.5초로 backoff. 빠른 렌더를 거의
즉시 잡고 느린 콜드 스타트는 0.5초로 흡수.

```bash
(( i <= 10 )) && sleep 0.1 || sleep 0.5
```

### 적용하지 않은 것 — 마커 ANSI-strip

의심했던 "마커 `❯`가 read-screen 바이트와 매칭 안 됨"은 실측에서 재현되지 않았다
(`cat -A`로 `\u{276f}`/`\u{203a}` 그대로 확인). 실제 원인이 아니라 불필요한 복잡도라
넣지 않았다. 만약 향후 테마/모드/에이전트 버전에서 마커가 ASCII 폴백되거나 escape
코드가 끼면 그때 부팅 루프에도 동일한 "공백/ANSI 제거 후 비교" 또는 하단 바
문자열(`for shortcuts` 등) 폴백을 도입하면 된다.

## 에이전트별 부팅/제출 신호 레퍼런스 (실측 2026-06-22)

> 이 표는 에이전트 버전이 올라가면 바뀔 수 있다. `tests/live-smoke.sh`가 드리프트를
> 감지하도록 설계돼 있으니(아래), 신호가 바뀌면 거기서 먼저 잡힌다.

| 항목 | claude (Opus 4.8) | codex (v0.141.0) |
|---|---|---|
| 입력창 마커 | `❯` (`\u{276f}`) + nbsp | `›` (`\u{203a}`) |
| 빈 입력창 placeholder | (없음) | `› Use /skills to list available skills` |
| 부팅 배너 | (간결) | `>_ OpenAI Codex (vX) / model: … / directory: …` 박스 |
| MCP 로딩 큐 | **없음** | `tab to queue message` (로딩 중에만) |
| 작업 중 신호 | `✻ Discombobulating…`, `running stop hooks…`, `Brewed for Ns` (동적 동사, 가변) | `• Working (… esc to interrupt)`, `• Ran <cmd>` |
| **버전 불변 제출 신호** | **프롬프트가 입력창(마커 줄 이후)을 떠남** | (동일) |

작업-동사 어휘("Working"/"Discombobulating…")는 버전마다 바뀐다. 그래서 제출
판정의 **불변식은 "프롬프트가 입력박스를 떠났는가"** — 마지막 마커 줄 이후 영역에
needle이 없으면 제출된 것이다. live-smoke가 이 불변식을 쓴다.

## 회귀 방어 — 단위(bats) + 라이브(smoke)의 역할 분담

| | `tests/sib-spawn.bats` | `tests/live-smoke.sh` |
|---|---|---|
| 대상 | 플래그/배치/state 로직 | 실제 spawn→제출 동작 + latency |
| cmux | **스텁** | **실제** |
| 에이전트 | 없음 | 실제 claude/codex 바이너리 |
| 실행처 | 로컬 + GitHub CI | **로컬 전용** (cmux.app + 인증 필요) |
| 잡는 것 | 인자 파싱 회귀 | **에이전트 버전 드리프트** (마커/큐/wrap 변경) |
| 빈도 | 매 PR | 에이전트 업그레이드 후 / 주기 수동 |

bats는 스텁이라 마커·placeholder·큐 문구가 바뀌는 드리프트를 **원천적으로 못 잡는다.**
codex v0.141.0 wrap 케이스가 그 산증인. live-smoke는 실제 에이전트를 띄워 그 클래스를
잡고, 회귀(미제출 / latency 초과) 시 `~/agent-workspace/.agent/inbox/`에 리포트를
드롭한다(`/inbox` 스킬이 소비).

```bash
tests/live-smoke.sh                 # claude+codex, 15초 예산
tests/live-smoke.sh --budget 20     # 예산 조정
tests/live-smoke.sh --agents claude # 한 에이전트만
tests/live-smoke.sh --no-report     # 로그만, inbox 리포트 생략
```

## 더 파볼 거리 (향후)

- **에이전트별 콜드 스타트 프로파일**: codex의 MCP 로딩 시간 vs claude의 stop-hook
  주입 시간을 분해해 "진짜 ready"의 정의를 에이전트별로 더 정밀하게.
- **pane 폭 인지**: `cmux`가 pane 폭을 알려준다면 wrap 자체를 예측해 needle 길이를
  적응시킬 수 있다(현재는 wrap 면역 매칭으로 우회).
- **마커 드리프트 대비**: 테마/모드별 마커 변형 수집 → 부팅 루프에 폴백 신호 도입.
- live-smoke를 launchd로 주기 자동화(현재는 수동). plist만 추가하면 됨.
