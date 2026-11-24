# 에이전트 제어 경로를 하나로 — 목록과 통합 계획

- 작성: 2026-11-23, 영역 A(에이전트 도구)
- 원칙: [`architecture-one-agent-control-path`](../agent-context/constraints/architecture-one-agent-control-path.md) (R1–R10)
- 관련: [ADR-008 Codex 는 cmux pane 에서만](../agent-context/decisions/2026-11-23-codex-runs-in-cmux-panes-only.md)

## 1. 원칙 한 줄

에이전트를 **띄우고 · 보고 · 일을 보내고 · 멈추고 · 보고받는** 방식은 하나만 둔다.
모델(Codex·Claude)과 쓰임(단독·collab·위원회)은 그 하나로 보내는 *내용*만 다르다.
도구(cmux·sib)가 바뀌어도 원칙은 남고, 다섯 단계가 함께 새 도구로 옮겨 간다.

사용자 원문(11-23 21:20): "codex, claude 동일한 구조 1개로 제어하게 하는거 맞지? collab 도 결국
두 에이전트를 어떻게 제어하냐의 차이지 제어방식에 대해서는 여러 방식을 둘필요없어 가장 좋은
방식 1가지를 유지해야 품질이 올라와 방식자체를 아예 다르게 하더라도 cmux 를 대체하더라도 이
원칙을 유지해"

## 2. 지금의 "그 하나"

| 단계 | 명령 | 비고 |
|---|---|---|
| 띄우기 | `sib spawn <slug> [--codex] [--worktree] [--workdir] -- <brief>` | Claude·Codex 같은 명령, 플래그만 다름 |
| 보기 | `brief sessions` · `brief tree` · Sessions 패널 · 사무실 화면 | pane 이 단위 |
| 일 보내기 | `brief send <ref> <글>` (내부: `pane-deliver.sh`) | 전달 확인 포함 |
| 멈추기 | `sib kill <slug>` · `brief done` | pane 을 닫으면 에이전트도 끝 |
| 보고받기 | `brief report "done-report: ..."` | 데스크가 실제와 대조 |

## 3. 이 기기의 제어 경로 전체 목록

판정: **맞음** = 위의 하나를 쓴다 · **어긋남** = 다른 방식 · **예외 후보** = 원칙 밖에 둘 근거가 있음(4절).
조사 방법: `bin/ cmux/ skills/ agents/ scripts/`(이 저장소), 하위 계층(L2) 저장소, 개인 스크립트 폴더,
`~/.claude/{skills,agents,hooks,rules}`, `~/.config/cmux`, LaunchAgents·crontab, 실행 중 프로세스를
`codex exec` · `claude -p` · `sib` · `orca` · `claude --agent` 로 grep 했다(11-23).

| # | 경로 | 어디 | 무엇을 띄우나 | 판정 | 근거 |
|---|---|---|---|---|---|
| P1 | `sib spawn` (claude · `--codex`) | `bin/sib` | 대화형 Claude·Codex, pane | **맞음** | 기준 경로 |
| P2 | `/dispatch` | `skills/dispatch` | `sib spawn` 1개 | **맞음** | sib 위의 배치 규칙일 뿐 |
| P3 | `/collab` | `skills/collab` | `sib spawn --worktree` 2개(claude·codex) | **맞음**(보고는 P6) | 두 모델이 같은 명령으로 뜬다 |
| P4 | 데스크 기동 | `cmux/morning-brief.sh:56` | `cmux new-pane --command "claude --agent orch"` | **어긋남(경미)** | pane 이고 보이지만 `sib` 를 거치지 않는다. `sib` 에 `--agent` 가 없어서 |
| P5 | 일 보내기 3갈래 | `sib send`(`bin/sib`, 맨 `cmux send`) · `brief send` · `/pane-msg` | 열린 pane 에 글 | **맞음(11-23)** | 셋 다 `pane-deliver.sh` 하나를 부른다(5절 3단계). 전에는 `sib send` 만 전달 확인이 없었다 |
| P6 | 보고 2갈래 | `brief report` · `/collab` 워커(완료 계약 없음, 호출자가 폴링) · `agent-scout` pane(answer.json 파일 폴링) | 결과 회수 | **어긋남(경미)** | 결과 파일은 내용물이라 괜찮지만, "끝났다"는 신호가 쓰임마다 다르다 |
| P7 | `codex exec` | `skills/codex` Mode B(4.0.0 에서 삭제), `hooks/general/guard-codex-exec.sh`(차단, 작업 중) | 헤드리스 Codex | **어긋남 → 처리 중** | ADR-008. 'codex exec 제거, cmux pane 강제 가드' 세션 범위 |
| P8 | `xreview` | 개인 스크립트(`xreview`) | `codex exec -s read-only` | **어긋남** | 남은 `codex exec` 사용처. P7 세션 범위에 넘김 |
| P9 | 발굴 위원회 Claude 위원 | `bin/agent-scout:430` | `claude -p --agent scout-*` (도구 Read·Grep·Glob) | **어긋남** | 도구 있는 헤드리스 에이전트(R1). 같은 위원회의 Codex 위원은 pane(R3·R9) — 모델별로 다른 길 |
| P10 | 새 에이전트 써 보기 안내 | `bin/agent-scout:903`, `skills/agent-scout/SKILL.md:81` | `claude -p --agent <name>` | **어긋남** | P9 와 같은 이유 |
| P11 | 영역 담당 | `cmux/brief-lead:139` | `claude -p --tools "" --no-session-persistence`, timeout 300 | **예외(R7), 조건 미충족** | 도구 없는 한 번 답. 단 MCP·훅 격리(`CLAUDE_ISOLATED`)와 프로세스 트리 회수가 없어 R7 조건을 다 채우지는 못함 |
| P12 | 가드 루프 판정·검사 | L2 의 가드 루프 스크립트 | `claude -p --tools ""` + 격리 + `proctree` | **예외(R7)** | R7 조건을 모두 채움(도구 없음, stdin 닫힘, 타임아웃, 트리 회수) |
| P13 | 가드 루프 제안자 | `improve.py:179,599` (launchd 매일) | `claude -p --permission-mode acceptEdits --tools Read,Edit,Write,Glob,Grep,Bash` | **어긋남** | 파일을 고치는 헤드리스 에이전트, 밤에 아무도 안 보는 곳에서 |
| P14 | 분류기 탐침 | 하위 계층의 분류기 탐침 스크립트 | `claude -p --permission-mode auto`, OS 샌드박스·스텁 CLI | **예외(R10)** | 일꾼이 아니라 *측정 대상*. 4절 B |
| P15 | 세션 안 서브에이전트·워크플로 | Claude Code `Agent` · `Workflow`, pstack `arena`·`swarm`·`interrogate` | 부모 세션 안의 Claude | **예외(R8·R9)** | 4절 C |
| P16 | 클라우드 에이전트 | `Agent isolation:"remote"`, `/schedule`·RemoteTrigger 루틴, pstack swarm `environment:"cloud"` | 이 기기 밖 에이전트 | **어긋남** | 데스크가 못 본다. 이 기기에서 쓴 흔적은 찾지 못함(확인 범위: 위 grep) |
| P17 | Orca 워커 (11-23 제거 완료) | `~/.claude/skills/{orca-cli,orchestration}` → `~/.agents/skills`, `/usr/local/bin/orca`, Orca.app 실행 중(11일째) | Orca 터미널의 Claude·Codex 워커, 자체 worktree·ask/reply | **어긋남** | 두 번째 오케스트레이터. 띄우기·보기·멈추기·보고를 전부 따로 가짐(R4) |
| P18 | skill-creator 평가 스크립트 | `~/.claude/skills/synced/.../skill-creator/scripts/{run_eval,improve_description}.py` | `claude -p` (도구 제한 없음) | **어긋남(외부)** | 동기화되는 남의 스킬이라 여기서 못 고친다 |
| — | cmux automations | `cmux/automations.json` | `brief render/patrol`, `morning-brief.sh` | 대상 아님 | 스크립트일 뿐. 데스크 기동은 P4 |
| — | 메모리 데몬 | LaunchAgents `agentmemory`, `ai-memory` | 저장·검색 서버 | 대상 아님 | 에이전트를 띄우지 않음(내부 LLM 호출 여부는 확인 안 함) |
| — | 사람이 직접 친 명령 | 예: `otel-stack/README.md` 의 `claude -p "say hi"` | — | 대상 아님 | 제약의 Excludes |
| — | 옛 L2 문서 | L2 저장소의 ADR·문서 | `codex exec` 폴백 서술 | 문서만 낡음 | ADR-008 Neutral 에 이미 적힘 |

요약: 맞음 3 · 어긋남 11(처리 중 1, 제거 완료 1 포함) · 예외 4(R7 둘, R8, R10).

## 4. 판단이 갈리는 것

**사용자 판정(11-23): "3개 예외로해 그럼"** — A·B·C 셋 다 예외로 둔다(R7, R10, R8+R9).
판정 전에 "예외 없이도 되는가"를 물었고, 답은 '구조상 된다(`sib` 가 pane 안에서 아무 명령이나 실행할 수 있음),
단 B 는 pane 에서 측정값이 같은지 비교 실행이 필요'였다. 그 위에서 예외를 택했다.

### A. 도구 없이 한 번 답하고 끝나는 `claude -p` 는 에이전트 제어인가 (P11, P12)

- **에이전트로 본다(pane 으로 옮긴다)**: 모델이 돌고 시간과 돈을 쓰며, 멈추거나 MCP·훅을 끌고
  오면 보이지 않는 프로세스가 남는다(11-23 가드 루프 판정 호출이 MCP 서버를 띄운 사례). "방식은 하나"를
  글자 그대로 지키면 예외가 없다.
- **함수 호출로 본다(예외)**: 도구가 없으면 세상을 바꾸지 못하고, 대화도 없어 "보고·일 보내기"가 의미가
  없다. 결과는 호출자가 검사하는 데이터다. 판정 수십 번(가드 루프 ~35회/세트)을 pane 으로 띄우면 화면과
  비용만 늘고 얻는 통제가 없다. 호출자(스크립트·세션)가 이미 보이는 곳이다.
- **권고: 예외(R7)로 두되 조건을 강제한다.** 조건: `--tools ""`, stdin 닫힘, 세션 기록 없음, 타임아웃,
  MCP·훅 격리, 호출자가 프로세스 트리를 회수. 하나라도 빠지면 에이전트로 본다. P12 는 이미 채움,
  P11(`brief-lead`)은 격리·트리 회수를 더해야 한다.

### B. 측정 대상으로 띄우는 헤드리스 세션 (P14 분류기 탐침)

- **어긋남으로 본다**: 도구가 있고 `--permission-mode auto` 로 실제로 실행까지 한다. 제약의 "Never"
  (도구 있는 헤드리스 에이전트)에 정면으로 걸린다.
- **예외로 본다**: 이 세션은 일을 맡기는 대상이 아니라 *자동 모드 분류기를 재는 계측기*다. pane 으로
  띄우면 사용자의 설정·훅이 섞여 측정이 틀어진다. OS 샌드박스(임시 폴더 밖 쓰기 금지, 네트워크 없음)와
  echo 만 하는 스텁 CLI 로 실제 영향이 없다.
- **권고였던 것: 예외.** 판정대로 제약에 "계측용 세션" 예외(샌드박스·스텁·임시 폴더 조건)를 R10 으로 더했다. 판정이 어긋남이면 가드 루프의 분류기 측정을 다른 방법으로 바꿔야
  하므로 비용이 크다 — 그래서 예외 쪽을 권한다.

### C. 세션 안의 서브에이전트·워크플로 (P15)

- **어긋남으로 본다**: 데스크의 `brief tree` 에 따로 안 보이고, 사용자가 서브에이전트에 직접 말을 걸 수
  없다. pstack `arena` 처럼 "여러 모델이 겨루는" 쓰임은 사실상 위원회인데 길이 다르다.
- **예외로 본다**: 서브에이전트는 부모 세션의 내부 작업이다. 부모 pane 에 보이고, 부모가 멈추며
  (`TaskStop`), 결과는 부모에게 돌아오고, 부모가 `brief report` 한다 — 제어의 단위는 여전히 pane 하나.
  Claude Code 세션에서 Codex 를 서브에이전트로 띄울 수는 없으므로 모델 간 비대칭도 생기지 않는다.
- **권고: 예외(R8)로 두되 R9 로 막는다.** 같은 묶음(위원회·collab·arena) 안에서 한 모델은 서브에이전트,
  다른 모델은 `sib` 로 띄우는 것은 금지. 모델이 섞이는 묶음은 전부 `sib`.

## 5. 하나로 모으는 순서

앞 단계가 뒤 단계의 전제다. 각 단계는 따로 배치할 수 있는 크기로 잘랐다.

1. ~~사용자 판정 받기~~ — 11-23 완료: 셋 다 예외(R7, R8+R9, R10). 예외는 측정·평가하고 문제가 되면 바꾼다(R11–R13, 7절).
1a. **예외 측정 도구** — 제약의 측정표를 주 1회 뽑는 검사(예: `brief audit` 의 한 항목 또는 `agent-scout` 식 스크립트).
   R7: `claude -p` 호출 수·타임아웃·호출자 종료 뒤 남은 모델 프로세스(`ps`), 조건을 빠뜨린 호출처(grep).
   R8: 데스크 결정 기록에서 서브에이전트 때문에 멈추거나 놓친 건. R10: 탐침 실행 기록의 임시 폴더 밖 쓰기·네트워크 시도,
   같은 입력 재실행 시 판정 차이. 도구가 생기기 전 11-30 평가는 손으로 센다.
2. **`codex exec` 마무리 (P7, P8)** — 진행 중인 'codex exec 제거, cmux pane 강제 가드' 세션이 끝내고,
   `xreview` 의 빠른 경로를 `sib spawn --codex` 로 바꾸거나 없앤다. 가드가 막으니 새로 생기지 않는다.
3. **보내기 한 갈래로 (P5)** — `pane-deliver.sh` 를 유일한 전달기로 삼고 `sib send` 가 그것을 부르게 한다.
   `brief send`·`/pane-msg` 는 그 위의 이름만 남는다. 이게 먼저여야 4·5 단계가 같은 전달 확인을 얻는다.
   **완료(11-23)**: `sib spawn` 의 첫 글·`sib send`·`brief send` 가 모두 `pane-deliver.sh` 를 부른다(`sib send` 의 맨
   `cmux send` 대체 경로 삭제). `brief send` 는 일하는 세션에도 `cmux agent message` 대신 그 pane 의 입력 대기열(`--queue`)을
   쓴다: cmux 는 pane 이 아니라 워크스페이스의 에이전트를 깨워, 한 pane 으로 보낸 글을 같은 워크스페이스의 다른 에이전트가 읽었다. 도착 확인은
   '보내기 전에 없던 꼬리가 새로 보임'과 '붙여넣기 자리표시 뒤가 글의 끝'을 더해, `…[Pasted text #1].` 와 폭 4칸 pane 을 통과한다.
   남은 것: `brief report`·순찰 알림의 데스크행 `cmux agent message` 는 5단계(보고)에서 본다.
4. **위원회를 한 길로 (P9, P10)** — `agent-scout` 의 claude 위원도 `run_pane()` 으로(`sib spawn` + 결과 파일).
   `sib spawn` 에 `--agent <name>` 을 더해 에이전트 정의를 pane 에서 쓰게 하고, 안내 문구도 그것으로 바꾼다.
   같은 `--agent` 로 **데스크 기동(P4)** 도 `sib spawn --agent orch` 로 옮긴다.
5. **보고 한 갈래로 (P6)** — 결과는 파일로 두되 "끝남" 신호는 모두 `brief report`(또는 그 한 함수)로.
   `/collab` 워커와 위원회 pane 도 같은 완료 계약을 받는다.
6. **가드 루프 제안자 (P13)** — 권고: 제안자를 *도구 없는 호출*로 바꿔 diff 를 데이터로 받고, 스크립트가
   worktree 에 적용·검증한다(R7 로 들어옴). 대안은 launchd 에서 `sib spawn` 으로 pane 을 여는 것인데,
   `sib` 가 cmux pane 밖에서 못 돌고 밤에 사람이 없어 얻는 통제가 적다.
7. **영역 담당 격리 (P11)** — `brief-lead` 의 호출에 `CLAUDE_ISOLATED` 와 프로세스 트리 회수를 더해
   R7 조건을 채운다(`guard-loop/proctree.py` 를 공용으로 옮기는 것도 이 단계).
8. **Orca 걷어내기 (P17)** — 11-23 사용자 지시("orca 걷어 내")로 진행. 끝냄: Orca.app 종료·휴지통,
   `~/.claude/skills/{orca-cli,orchestration}` 링크 제거, `~/.agents/skills/` 의 원본을
   `~/.local/share/orca-removed-20261123/` 로 옮김(Codex 도 더는 못 봄). 사용자가 실행: Orca 훅 제거
   (`~/.claude/settings.json` 16개, `~/.codex/hooks.json` 9개, 백업 `*.before-orca-removal`), `/usr/local/bin/orca` 삭제.
   `~/.orca` 는 같은 백업 폴더로 옮김. **완료(11-23).**
9. **바깥 에이전트 막기 (P16, P18)** — 클라우드 에이전트와 skill-creator 평가 스크립트는 사용자가 직접
   시킬 때만 쓴다는 줄을 `cmux/session-report.md` 규칙 또는 별도 가드에 둔다. 가능하면
   `guard-codex-exec.sh` 를 일반화해 도구 있는 `claude -p` 도 막는 가드(예외 조건 검사 포함)로 만든다.
10. **제약 승격** — 1–9 가 끝나 grep·`ps` 에 예외(R7·R8·R10) 밖의 경로가 0 이면 제약 Severity 를 High → Critical 로
    올리고 AGENTS.md 에 싣는다.

## 6. 도구가 바뀔 때 (R5)

cmux 나 sib 를 다른 것으로 바꾸면, 2절 표의 다섯 줄을 새 도구의 명령으로 한꺼번에 다시 채운다.
옛 도구를 "폴백"으로 남기지 않는다(ADR-008 이 `codex exec` 폴백을 없앤 것과 같은 이유).
이 문서의 3절 목록은 그때 다시 grep 해서 새로 만든다.

## 7. 예외 결정 기록과 평가

예외는 결정이지 고정된 사실이 아니다. 측정하고, 정한 날에 평가하고, 문제가 되면 바꾼다(제약 R11–R13).
형식은 영역 프로파일의 결정 기록과 같다: `날짜 | 예외 | 측정값 | 판정(유지·조건 고침·제거) | by`.

- 11-23 | R7·R8·R10 | — | 채택 | by:user ("3개 예외로해 그럼")
- 11-30 | R7·R8·R10 | (영역 A 시험 판정과 함께 첫 평가) | | 
