#!/usr/bin/env bash
# 하루 첫 cmux 진입(window.keyed) 때 데스크(오케스트레이터) 세션을 새로 띄운다.
# 역할은 지시문이 아니라 에이전트 정의로 준다: `claude --agent orch` (orch-agent.md).
# 데스크는 항상 하나만 둔다: 새로 띄우기 전에 이전 데스크를 닫는다. 데스크의 상태는 대화가 아니라
# 데스크 문서에 있으므로 닫아도 잃는 것이 없다(대화는 `claude --resume` 로 되살릴 수 있다).
# 닫지 않으려면 MORNING_BRIEF_KEEP_OLD=1.
# cmux 는 계속 켜 두므로 "앱 시작"이 아니라 "그날 처음 창에 들어온 순간"이 기준.
# 05시 이전은 전날로 친다. 강제 실행: morning-brief.sh --force
set -euo pipefail
PATH=/Applications/cmux.app/Contents/Resources/bin:/opt/homebrew/bin:/usr/bin:/bin
STAMP="$HOME/.cache/cmux/morning-brief.date"
PROMPT="$HOME/.config/cmux/morning-brief.md"
MOD="$HOME/.config/cmux/brief-mod"   # /go /ping /done /today: 모델 턴 없이 pane 이동
# 데스크가 뜨는 폴더는 이 기기 전용 설정(~/.config/cmux/local.env 의 BRIEF_DESK_DIR, 레포 밖)에서 읽는다.
[ -f "$HOME/.config/cmux/local.env" ] && . "$HOME/.config/cmux/local.env"
BRIEF_CWD="${MORNING_BRIEF_CWD:-${BRIEF_DESK_DIR:-$HOME/.local/share/cmux/desk}}"
mkdir -p "$BRIEF_CWD"
# 이 기기에서 끄려면 local.env 에 MORNING_BRIEF=0.
[ "${MORNING_BRIEF:-1}" = "0" ] && [ "${1:-}" != "--force" ] && exit 0

today=$(date -v-5H +%F)
if [ "${1:-}" != "--force" ] && [ "$(cat "$STAMP" 2>/dev/null)" = "$today" ]; then
  exit 0
fi
mkdir -p "$(dirname "$STAMP")"
echo "$today" > "$STAMP"   # 띄우기 전에 찍어 중복 실행을 막는다

# orch 가 어제 고친 교훈·글쓰기 규칙을 로컬 전용 기록에 남긴다(remote 없음. 변경 이력을 보기 위한 것).
if [ -d "$HOME/.local/share/cmux/orch/.git" ]; then
  git -C "$HOME/.local/share/cmux/orch" add -A >/dev/null 2>&1 || true
  git -C "$HOME/.local/share/cmux/orch" commit -q -m "orch $today" >/dev/null 2>&1 || true
fi

# 이전 데스크("☀" 로 시작하는 워크스페이스) 정리. 데스크 pane 은 상태와 무관하게 닫는다
# (cmux 가 알려 주는 "working" 은 멈춘 세션에도 남아 있을 수 있어 기준으로 쓰지 않는다).
# 데스크가 아닌 세션은 건드리지 않는다.
# brief 는 cwd 를 "~/..." 로 내놓는다. ${VAR/#$HOME/~} 는 bash 가 ~ 를 다시 홈 경로로 펼쳐 버려 쓸 수 없다.
desk_cwd="~${BRIEF_CWD#"$HOME"}"
if [ "${MORNING_BRIEF_KEEP_OLD:-}" != "1" ]; then
  for ws in $(cmux rpc workspace.list '{}' | jq -r '.workspaces[] | select((.custom_title // .title // "") | startswith("☀")) | .id'); do
    # 데스크가 아닌 세션이 같이 있으면 워크스페이스는 두고 데스크 pane 만 닫은 뒤 "☀" 표시를 뗀다.
    others=$("$HOME/.local/bin/brief" sessions | jq -r --arg ws "$ws" --arg d "$desk_cwd" '[.[] | select(.workspace == $ws and .cwd != $d)] | length')
    if [ "${others:-0}" -gt 0 ]; then
      for p in $("$HOME/.local/bin/brief" sessions | jq -r --arg ws "$ws" --arg d "$desk_cwd" '.[] | select(.workspace == $ws and .cwd == $d) | .panel'); do
        cmux close-surface --surface "$p" --workspace "$ws" --force >/dev/null 2>&1 || true
      done
      cmux rename-workspace --workspace "$ws" "이전 데스크에서 남은 세션" >/dev/null 2>&1 || true
      continue
    fi
    cmux workspace close "$ws" --force >/dev/null 2>&1 || true
  done
fi

# Sessions 패널은 "☀" 로 시작하는 워크스페이스를 데스크로 보고 맨 위에 고정한다.
cmux new-workspace --name "☀ Desk ${today#*-}" --cwd "$BRIEF_CWD" \
  --command "claude --agent orch --plugin-dir '$MOD' \"\$(cat '$PROMPT')\"" --focus false >/dev/null

# 페르소나(L2)가 덧붙이는 아침 작업: ~/.config/cmux/morning-brief.d/*.sh 를 이름순으로 실행한다.
# L1 은 데스크만 띄운다. 각 스크립트는 TODAY 를 받고, 실패해도 다른 스크립트는 계속 돈다.
export TODAY="$today"
for ext in "$HOME/.config/cmux/morning-brief.d"/*.sh; do
  [ -f "$ext" ] || continue
  bash "$ext" || echo "[morning-brief] $(basename "$ext") failed" >&2
done
