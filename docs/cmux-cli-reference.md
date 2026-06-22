# cmux CLI 레퍼런스 — 에이전트가 cmux를 native하게 다루기

> 작성: 2026-06-17 / 검증 환경: cmux (this build), macOS
> 목적: 에이전트(Claude/Codex)가 cmux 워크스페이스·패인·세션을 **추측 없이** 조작하기 위한 검증된 사실 모음.
> 오늘(2026-06-17) 실제로 CLI를 두드려 확인한 내용. 당장 안 써도 나중에 참조용.
> 위치: **L1 (agent-framework)** — 도메인 무관 프레임워크 지식. `dispatch`/`collab`/`codex` 스킬이 cmux를 다루는 근거.
> 관련: [sib-dispatch-improvement.md](./sib-dispatch-improvement.md)(같은 L1), `agent-workspace/docs/zmx-cmux-guide.md`(L2, sib 전환 전 zmx 중심).

## TL;DR — 가장 자주 틀리는 것

- **워크스페이스의 cwd를 알고 싶으면 `cmux sidebar-state --workspace <ref>`** 를 써라. `cmux tree`에는 cwd가 없다.
- **tty를 워크스페이스 식별키로 쓰지 마라.** tty는 재사용·중복된다(예: ttys000이 두 워크스페이스에).
- **워크스페이스 제목을 신뢰하지 마라.** auto-name(작업 설명)과 cwd 표시가 번갈아 나온다(아래 "제목 이원 구조").
- **TUI 에이전트(claude/codex)에 입력 제출 시, 프롬프트 마커(`❯`/`›`)가 떴다고 enter를 쏘지 마라.** 마커는 "입력창이 그려짐"일 뿐 "입력 수용 준비"가 아니다. 특히 codex는 부팅 직후 MCP 로딩 중 입력을 큐로 돌린다(`tab to queue message`). → 텍스트 안착 + 큐 상태 해제를 확인한 뒤 enter (아래 §9).

---

## 1. 워크스페이스 cwd 확인 — `cmux sidebar-state` ★

워크스페이스별 작업 디렉터리를 **신뢰성 있게 1:1로** 주는 유일한 CLI.

```bash
cmux sidebar-state --workspace workspace:13
```
출력(key=value, 일부):
```
tab=2C8A36F6-...                  # 워크스페이스 UUID
color=none
cwd=/Users/kakao/personal/cmux    # ★ 워크스페이스 cwd
focused_cwd=/Users/kakao/personal/cmux   # 포커스된 패인의 cwd
focused_panel=DC0B94F5-...
git_branch=main dirty             # git 브랜치 + dirty/clean
pr=none / pr_label=none / ports=none / progress=none
status_count=1
  claude_code=Running icon=bolt.fill color=#4C8DFF   # 에이전트 상태
meta_block_count=0 / log_count=0
```
- `--workspace` 생략 시 `$CMUX_WORKSPACE_ID`(현재) 기준.
- **`--all` 플래그는 없다.** 전체 순회는 §2의 `workspace list`로 ref를 얻어 각각 호출.
- 파싱 예: `cmux sidebar-state --workspace "$ref" | awk -F= '/^cwd=/{print $2}'`

### 왜 tree엔 없고 sidebar-state엔 있나 (근거)
cwd는 cmux 내부에서 `Workspace.currentDirectory`(+ 패인별 `panelDirectories`)에 **1급 프로퍼티**로 저장되며,
셸의 `report_pwd`(OSC 7 / shell integration)로 갱신된다. **터미널 OSC 제목(pane title)과는 별개 채널**이다.
`cmux tree`(내부 `system.tree`)는 이 필드를 출력에서 누락하지만, 사이드바와 `sidebar-state`는 노출한다.
→ surface 제목을 cwd로 파싱하는 우회는 하지 말 것.

---

## 2. 워크스페이스 목록 — `cmux workspace list`

```bash
cmux workspace list        # (구) cmux list-workspaces — alias로 계속 동작
```
출력:
```
* workspace:2  ⠐ Approver LaunchAgent 설치 및 검증  [selected]
  workspace:1  bunx tokscale@latest
  workspace:13  ⠂ 최신 기준으로 pull 해주기
  ...
```
- `*` = 현재 선택된 워크스페이스. ref(`workspace:N`)를 §1에 넘겨 cwd를 얻는다.
- 표시 문자열은 **제목**이라 cwd가 아닐 수 있다(아래 §5).

---

## 3. 토폴로지 — `cmux tree`

```bash
cmux tree              # 사람용 트리
cmux tree --json       # 구조화. 단 cwd 필드 없음
cmux tree --all        # 모든 윈도우
cmux tree --workspace workspace:4   # 특정 워크스페이스만
```
`tree --json`의 surface 노드 필드: `ref`, `title`, `tty`, `url`, `surface_type`, `pane_ref`, `selected`, `active` …
**cwd / path / git 필드는 없다.** tty는 있지만 식별키로 부적합(§5).

---

## 4. 워크스페이스/패인 조작 (타겟 지정 가능)

```bash
# 특정 cwd로 새 워크스페이스 생성 (전용 작업 공간 만들 때)
cmux new-workspace --name "infra" --cwd /path/to/repo --command "claude --continue"

# 특정 워크스페이스에 split pane 추가
cmux new-split right --workspace workspace:4    # left|right|up|down

# 특정 세션에 텍스트/명령 전달 (\n=Enter)
cmux send --workspace workspace:4 --surface surface:5 "echo hi\n"

# 워크스페이스 제목/설명/색/핀 등 컨텍스트 액션
cmux workspace-action --workspace workspace:4 --action rename --title "infra"
cmux workspace-action --workspace workspace:4 --action clear-name   # ⚠ §5 주의
```
포인트: `new-split`·`send`·`workspace-action` 모두 `--workspace`로 **base가 아닌 다른 워크스페이스를 타겟**할 수 있다.
dispatch가 "현재 워크스페이스에 무조건 split"하지 않으려면 이 타겟팅을 써야 한다.

---

## 5. 워크스페이스 제목의 이원 구조 (함정)

제목은 두 출처가 번갈아 나온다:

| 출처 | 언제 | 예 |
|---|---|---|
| `customTitle` (.auto) | auto-naming이 제목을 붙였을 때 | `저장소 내용 변경 사항 확인` |
| `processTitle` (셸 OSC) | custom title이 없을 때 | `~/personal/cmux` |
| `customTitle` (.user) | 수동 rename | (사용자 지정) |

provenance 규칙: **.auto는 .user를 덮어쓰지 못한다.** 수동 `rename`으로 박은 제목은 auto가 못 건드린다.

### auto-name은 앱 설정이 아니라 Claude 훅으로 돈다 (중요)
- 앱 defaults `workspaceAutoNamingEnabled=0`이어도, 이미 떠 있는 Claude 세션은 시작 시 주입된
  **`Stop` 훅 `cmux hooks claude auto-name`** 으로 매 턴 종료마다 제목을 다시 붙인다.
- 따라서 `workspace-action clear-name`을 해도 그 세션이 턴을 끝내면 **즉시 되돌아간다.**
- 잔재를 cwd 제목으로 되돌리려면: (a) 해당 세션 종료/재시작, 또는 (b) `rename`으로 .user 제목 고정.

→ 제목으로 워크스페이스를 식별하지 말 것. 식별은 **UUID(`tab=`) 또는 ref**, cwd는 **§1 sidebar-state**.

---

## 6. tty는 식별키로 쓰지 말 것

`cmux tree`의 `tty=ttysNNN`은 **재사용·중복된다.** 실측에서 `ttys000`이 두 워크스페이스에,
`ttys008`도 두 곳에 나타났다. tty→`lsof -a -d cwd -p <pid>`로 cwd를 역추적하는 우회는:
(1) tty 중복으로 엉뚱한 워크스페이스를 짚을 수 있고, (2) 느리고 깨지기 쉽다.
→ §1 `sidebar-state`를 쓰면 이 우회가 전부 불필요.

---

## 7. 헬스/자동화 모드 확인

```bash
cmux ping     # → PONG  (소켓 살아있음 + 자동화 모드 동작 확인)
```

---

## 8. 알아두면 좋은 것

- `cmux rpc <method> [json]` — CLI에 없는 v2 소켓 메서드를 직접 호출하는 탈출구.
  예: `cmux rpc surface.report_tty '{"workspace_id":"...","surface_id":"...","tty_name":"ttys001"}'`.
  대부분의 일상 작업은 전용 CLI로 충분하므로 rpc는 최후수단.
- 내부적으로 모든 CLI는 cmux 앱과 unix 소켓으로 통신한다. **사용자/에이전트는 소켓을 직접 다룰 필요 없다** — CLI만 쓰면 된다.
- `CMUX_QUIET=1` — alias 안내 등 부가 출력 억제.

---

## 9. TUI 에이전트에 입력 제출하기 (claude/codex) — 함정 + 검증된 패턴 ★

`cmux send`(텍스트) + `cmux send-key enter`로 TUI 에이전트에게 작업을 주는 흐름은
**언제 enter를 보내느냐**가 전부다. 2026-06-17 codex/claude로 실측한 사실:

### 함정 1 — 프롬프트 마커는 "ready"가 아니다
- `❯`(claude) / `›`(codex)는 **입력창이 그려졌다**는 뜻일 뿐, 입력을 받아 **제출**할 준비가
  됐다는 뜻이 아니다. 마커 줄에는 placeholder(예: codex `Run /review on my current changes`)가
  들어있는 빈 입력창도 포함된다.

### 함정 2 — codex는 부팅 직후 입력을 "큐"로 돌린다
- codex는 시작 시 **MCP 서버를 로딩**한다(`• Starting MCP servers (1/2)`). 이 구간엔 입력이
  제출되지 않고 큐에 쌓인다 — 화면 하단에 **`tab to queue message`** 가 뜬다.
- 이 상태에서 텍스트를 보내고 enter(또는 `\n`)를 쏘면 **제출되지 않고 입력창에 남는다.**
  (collab에서 codex worker가 작업을 시작 안 했던 실제 원인이 이것.)
- MCP 로딩이 끝나면(모델 배너 `model: gpt-5.5 …` 표시 + `tab to queue` 사라짐) enter가 제출된다.

### 함정 3 — `send "텍스트\n"` 원자 전송도 해결책이 아니다
- `cmux send`는 `\n`/`\r`을 Enter로 처리하지만(help 명시), **큐 상태에선 `\n`도 똑같이 큐잉**된다.
  한 방에 보낸다고 타이밍 문제가 사라지지 않는다.

### 검증된 패턴 — send → 안착·ready 확인 → enter → 제출 확인
```bash
# 1) 텍스트를 입력창에 넣는다 (enter 아직 X)
cmux send --surface "$SURF" --workspace "$WS" "$PROMPT"

# 2) 텍스트가 입력창에 보이고 + 큐 상태가 아닌지 확인 (최대 N초 폴링)
for _ in $(seq 1 60); do
  screen=$(cmux read-screen --surface "$SURF" --workspace "$WS" --lines 40 2>/dev/null)
  # codex: 'tab to queue message'가 사라져야 제출 가능
  if grep -qF "$PROMPT_HEAD" <<<"$screen" && ! grep -qF "tab to queue message" <<<"$screen"; then
    break
  fi
  sleep 0.5
done

# 3) enter로 제출
cmux send-key --surface "$SURF" --workspace "$WS" enter

# 4) 제출됐는지 확인 (claude/codex 공통: 'Working'/'esc to interrupt' 등 작업 신호)
#    안 떴으면 enter를 한 번 더 (codex 큐 해제 직후 1회 재시도가 안전)
sleep 1
cmux read-screen --surface "$SURF" --workspace "$WS" --lines 20 2>/dev/null \
  | grep -qiE 'working|esc to interrupt' || cmux send-key --surface "$SURF" --workspace "$WS" enter
```

### 함정 4 — 좁은 pane의 wrap이 에코 확인을 깨뜨린다 (2026-06-22 실측)
- 제출 전 "텍스트 안착 확인"으로 프롬프트 앞 N자를 `grep -F`로 찾는 패턴은, split
  pane이 좁아 입력 텍스트를 **soft-wrap**하면 그 N자가 줄 경계에 걸려 한 줄로
  안 나타나 **매칭이 영영 실패**한다. → 루프가 상한까지 헛돌다 제출(실측: codex
  27자 프롬프트가 42초). pane이 우연히 한 줄로 리플로우되면 그제서야 통과.
- 해결: 화면과 needle **양쪽에서 공백·개행을 제거(`tr -d ' \n'`)하고 비교**하면
  wrap 위치와 무관하게 매칭된다. 자세한 분해·근거는 [sib-spawn-timing.md](./sib-spawn-timing.md).
- 부수 교훈: 체감 느림의 주범은 codex 큐가 아니라 **프롬프트 길이 × pane 폭**이라
  긴 프롬프트면 claude도 똑같이 느려진다.

### 자동완성/탭 변형 (과거 사례)
- 입력창에 텍스트를 넣었을 때 셸/에이전트가 **자동완성 후보**를 띄우면, enter가 그 후보를
  선택해버리거나 첫 enter가 후보 확정에 먹히는 경우가 있었다. 이때는 **탭으로 후보를 확정/해제한
  뒤 enter**, 또는 제출 신호가 안 보이면 enter를 한 번 더 보내는 재시도가 필요하다.
- 공통 교훈: **키를 보낸 뒤 화면으로 결과를 확인하지 않고 다음 키를 보내지 마라.** send → read-screen
  확인 → 다음 키. 이 "확인 사이클"이 claude/codex/자동완성 모든 변형을 흡수한다.

### 마커별 신호 요약
| 에이전트 | 입력창 마커 | 진짜 ready 신호 | 제출됨 신호 |
|---|---|---|---|
| claude | `❯` | 마커 + 입력 즉시 수용(보통 빠름) | `Working`, `esc to interrupt`, 토큰 카운터 |
| codex | `›` | `tab to queue message` **없음** + 모델 배너 | `• Working (… esc to interrupt)` |

→ sib(`bin/sib`)는 이 패턴을 구현한다: spawn 후 마커만이 아니라 입력 수용 상태를 확인하고,
codex는 큐 해제까지 기다린 뒤 제출 + 1회 재시도.

---

## 미해결/개선 후보 (cmux 본체 작업)
- `cmux tree`(및 `--json`)에 워크스페이스/surface 레벨 `cwd` 필드 추가하면 §1 우회 호출이 불필요해진다.
  데이터·계산 함수는 cmux에 이미 존재(`TerminalController+ControlSystemContext.swift`의
  `extensionSidebarWorkspaceRow`가 `currentDirectory`/`panelDirectories` 사용). 출력 스키마에 한 필드 추가 수준.
