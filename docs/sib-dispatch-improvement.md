# Improvement Spec: sib `--workdir` + dispatch workspace targeting

> 작성: 2026-06-17 / 대상 리포: `/Users/kakao/personal/agent-framework`
> sib 소스: `bin/sib` (→ `~/.local/bin/sib` symlink). dispatch 스킬 소스: `skills/dispatch/`(위치는 grep으로 확인).
> 동기: `/dispatch`를 실제로 써보니 sibling이 **엉뚱한 워크스페이스/디렉터리**에 배치되는 버그를 반복 재현함.

## 재현된 버그 (실제 사례)

1. base 세션 cwd = `/Users/kakao/personal/cmux` 상태에서 agent-workspace 작업을 dispatch
   → sibling이 cmux 디렉터리에서 시작됨 (잘못).
2. agent-framework 작업을 dispatch
   → sibling이 base 세션(cmux pull 작업, workspace:13)에 split pane으로 붙음.
   agent-framework 전용 워크스페이스가 따로 있어도 거기로 안 감 (잘못).

근본 원인: `sib spawn`은 (a) workdir 지정 수단이 없어 항상 호출자 cwd에서 시작하고,
(b) 항상 호출자의 현재 워크스페이스에 split할 뿐, 작업 대상에 맞는 워크스페이스를 탐색/타겟하지 않는다.

## 개선 요구사항

### 결함 1 — `sib spawn --workdir <path>` (cwd 지정)
- `sib spawn`에 `--workdir <path>`(별칭 `--cwd`) 플래그 추가.
- 지정 시 pane 부팅 후 해당 경로로 `cd`한 뒤 agent(`claude`/`codex`)를 exec.
- `--worktree`와의 상호작용 정의: worktree 모드면 worktree 경로가 우선인지 명시.
- state 파일(`~/.local/share/sib/state/<slug>.env`)의 `worktree=`/`workdir=` 기록을 일관되게.

### 결함 2 (최우선) — dispatch 워크스페이스 탐색 & 타겟팅
dispatch 스킬 워크플로에 다음을 명시:
1. 작업 대상 디렉터리(workdir)를 먼저 확정한다.
2. `cmux list-workspaces`로 워크스페이스 ref를 조회하고, 각 ref에 대해
   `cmux sidebar-state --workspace <ref>`의 `cwd=` 필드를 읽어 workdir와 일치하는 워크스페이스를 찾는다.
   (tty→lsof 우회·OSC 제목 파싱 금지 — 아래 "워크스페이스 cwd 확인의 정답" 참고.)
3. **일치하는 워크스페이스가 있으면** → 그쪽에서 진행 (그 워크스페이스에 `cmux new-split`으로 pane을 붙이거나,
   `cmux send`로 기존 세션에 작업 전달; 사용자에게 "거기로 보낼까요" 확인).
4. **없으면** → `cmux new-workspace --cwd <workdir> --command ...`로 전용 새 워크스페이스를 만들어 거기서 시작.
5. **어떤 경우에도 base 세션의 워크스페이스에 무관한 작업을 split하지 않는다.** base cwd ≠ workdir이면 반드시 경고/확인.

`sib spawn`도 다음 옵션을 갖도록 확장:
- `--workspace <id|ref>` — 기존 워크스페이스를 타겟해 거기에 split.
- `--new-workspace` — workdir 전용 새 워크스페이스를 생성해 거기서 시작.

### 활용 가능한 cmux 명령 (검증됨)
- `cmux list-workspaces [--window <id>]` — 워크스페이스 목록(ref)
- `cmux tree [--all]` — 전체 토폴로지 (workspace/pane/surface/tty). **단 cwd는 안 줌**
- `cmux new-split <left|right|up|down> --workspace <id>` — 특정 워크스페이스에 split pane
- `cmux new-workspace --name <t> --cwd <path> --command <text>` — 특정 cwd로 새 워크스페이스
- `cmux send --workspace <id> --surface <id> <text>` — 기존 세션에 메시지 전달

### ★ 워크스페이스 cwd 확인의 정답: `cmux sidebar-state`
조사 결과, 워크스페이스별 cwd를 **신뢰성 있게 1:1로** 주는 CLI가 이미 존재한다.
`tty→lsof` 우회나 OSC 제목 파싱, 소켓 직접 호출은 **쓰지 말 것** (tty는 재사용되어 식별키로 부적합).

```bash
cmux sidebar-state --workspace workspace:4
# tab=4156EAAD-...                              ← 워크스페이스 UUID
# cwd=/Users/kakao/personal/agent-framework     ← 워크스페이스 cwd ★
# focused_cwd=/Users/kakao/personal/agent-framework  ← 포커스된 패인 cwd
# git_branch=main clean                         ← git 정보까지
```

- 전체 순회: `cmux list-workspaces`로 ref 목록을 얻은 뒤, 각 ref에 대해
  `cmux sidebar-state --workspace <ref>`를 호출해 `cwd=` 라인을 파싱한다.
  (`sidebar-state`에는 `--all` 플래그가 없음.)
- 근거: cwd는 `tree`의 OSC surface title이 아니라 `Workspace.currentDirectory`(report_pwd/OSC7로 갱신)에
  1급 프로퍼티로 저장된다. `cmux tree`(system.tree)는 이 필드를 출력에서 누락하지만,
  `cmux sidebar-state`는 노출한다.

### (선택) cmux 본체 개선 후보 — 별개 작업
`cmux tree`/`tree --json` 출력에도 워크스페이스/surface 레벨 `cwd` 필드를 추가하면 더 깔끔하다.
데이터·계산 함수는 이미 존재(`Sources/TerminalController+ControlSystemContext.swift`의
`extensionSidebarWorkspaceRow` 가 `currentDirectory`/`panelDirectories`를 이미 사용). 이건 cmux 리포
(`~/personal/cmux`) 작업이라 이 spec의 범위 밖. 당장은 `sidebar-state`로 충분하다.

## 설계 노트
- 결함 1(workdir)과 결함 2(워크스페이스 탐색/타겟)는 함께 설계. workdir가 정해지면 그에 맞는
  워크스페이스 탐색/생성이 자연스럽게 따라온다.
- sib는 bash 스크립트. 변경 후 `~/.local/bin/sib` symlink로 자동 반영되는지 확인.
- tests/ 하위에 bats가 있으면 회귀 테스트 추가.
- 커밋은 하되 **push는 사용자 확인 전까지 보류**.

## 작업 순서 제안
1. `bin/sib`와 dispatch 스킬 소스를 읽고 현재 spawn/타겟 로직 파악.
2. 결함 1 구현 (`--workdir`).
3. 결함 2 구현 (`--workspace`/`--new-workspace` + dispatch 워크플로의 탐색 로직 문서화).
4. bats 테스트 추가, symlink 반영 확인.
5. 커밋 (push 보류).
