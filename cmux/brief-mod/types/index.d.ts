export type TodoItem = { n: number; title: string; do: string; done: boolean; review: boolean }

// 데스크 문서(Desk/YYMMDD.md)의 위 블록과 TODO 목록.
export type DeskView = {
  file: string
  updated: string
  now: string
  decisions: string[]
  running: string[]
  standing: string[]
  finished: string[]
  todo: TodoItem[]
  // 에이전트 전체 지표(`brief board`): 세션, 오늘 완료, 개선 루프.
  board: { k: string; text: string; warn: boolean }[]
  // decisions 와 같은 순서: 그 결정이 올라온 뒤 그 세션 pane 에 사용자가 입력했으면 그 시각(HH:MM), 아니면 ''.
  answered: string[]
}

declare module 'claude-code' {
  interface PluginState {
    'brief-nav': { desk: Shaped<DeskView | null> }
  }
}
