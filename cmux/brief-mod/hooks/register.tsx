// brief-nav: 브리핑 세션에서 모델 턴 없이 cmux pane 으로 이동하는 슬래시 명령.
// 각 명령은 `brief` CLI (~/.local/bin/brief) 를 그대로 실행하고 그 출력을 보여 준다.
//   /go <번호|이름>    그 세션의 pane 으로 이동
//   /ping <번호|이름>  이동 없이 깜빡이기
//   /done <번호|이름>  완료 검토 시작: 세션이 보고 → 데스크가 대조 → 완료·기록·닫기 (/done 2 now 검토 없이 바로, /done 2 undo 되돌림)
//   /today             TODO 목록
//   /desk              Desk 패널 열기
// 그리고 데스크 문서(Desk/YYMMDD.md)의 위 블록을 프롬프트 위 띠와 Desk 패널에 그린다.
import { atom, read, update } from 'claude-code'
import type { EngineInterface, Register } from 'claude-code'

import type { DeskView, TodoItem } from '../types'

const PANE = 'desk'
const desk = atom({ plugin: 'brief-nav', key: 'desk' } as const, null, { shape: 'desk-2' })
const SEP = '\u001e'
// 가장 최근 데스크 문서와 TODO 파일을 한 번에 읽는다.
// 문서 경로는 brief 에 묻는다: 세션의 cwd 가 바뀌어도(orch 가 cd 한 경우) 같은 문서를 읽어야 한다.
const LOAD = `f=$("$HOME/.local/bin/brief" doc 2>/dev/null); printf '%s\\n' "Desk/\${f##*/}"; [ -n "$f" ] && cat "$f"; printf '\\n${SEP}\\n'; cat "$HOME/.cache/cmux/brief-plan.json" 2>/dev/null; printf '\n${SEP}\n'; "$HOME/.local/bin/brief" board --json 2>/dev/null`

const SECTIONS: Record<string, 'decisions' | 'running' | 'standing' | 'finished'> = {
  '결정 필요': 'decisions',
  '진행 중': 'running',
  '예약': 'standing',
  '오늘 끝난 것': 'finished',
}

const plain = (line: string) =>
  line.replace(/^\s*(?:[-*]|\d+\.)\s+/, '').replace(/\*\*|`/g, '').trim()

// 데스크 문서에서 타임라인 위쪽(지금 상태)만 읽는다.
export function parseDesk(raw: string): DeskView {
  const [docPart = '', planPart = '', boardPart = ''] = raw.split(SEP)
  const lines = docPart.split('\n')
  const view: DeskView = {
    file: (lines.shift() ?? '').trim(), updated: '', now: '',
    decisions: [], running: [], standing: [], finished: [], todo: [], board: [],
  }
  let section = ''
  for (const line of lines) {
    const head = /^#{1,3}\s+(.*)$/.exec(line)
    if (head) {
      const title = (head[1] ?? '').trim()
      if (title.startsWith('타임라인')) break
      const at = /갱신\s*([0-9:]+)/.exec(title)
      if (at) view.updated = at[1] ?? ''
      section = Object.keys(SECTIONS).find(k => title.startsWith(k)) ?? ''
      continue
    }
    const now = /^\*\*지금\*\*\s*[:：]\s*(.*)$/.exec(line.trim())
    if (now) { view.now = plain(now[1] ?? ''); continue }
    const text = plain(line)
    if (!section || !text || text === '없음' || !/^\s*(?:[-*]|\d+\.)\s+/.test(line)) continue
    const key = SECTIONS[section]
    if (key) view[key].push(text)
  }
  try {
    const items = (JSON.parse(planPart).items ?? []) as { title?: string; do?: string; done?: boolean; review?: boolean }[]
    view.todo = items.map((it, i): TodoItem => ({ n: i + 1, title: it.title ?? '', do: it.do ?? '', done: !!it.done, review: !!it.review && !it.done }))
  } catch {
    view.todo = []
  }
  try {
    const rows = JSON.parse(boardPart) as { k?: string; text?: string; warn?: boolean }[]
    view.board = rows.map(r => ({ k: r.k ?? '', text: r.text ?? '', warn: !!r.warn }))
  } catch {
    view.board = []
  }
  return view
}

// 데스크 문서(Desk/YYMMDD.md)를 고치는 Edit/Write 호출인가.
export const isDeskEdit = (tool: string, path: unknown): boolean =>
  (tool === 'Edit' || tool === 'Write') && typeof path === 'string' && /(^|\/)Desk\/\d+\.md$/.test(path)

const COMMANDS = [
  { name: 'go', description: 'TODO 목록의 번호나 세션 이름으로 그 cmux pane 에 이동', argumentHint: '<번호|이름>' },
  { name: 'ping', description: '이동 없이 그 cmux pane 을 깜빡이기', argumentHint: '<번호|이름>' },
  { name: 'done', description: '완료 검토 시작: 세션이 보고하고 데스크가 대조한 뒤 완료·기록·닫기 (now 검토 없이 바로, undo 되돌림)', argumentHint: '<번호|이름> [keep|now|undo]' },
  { name: 'today', description: 'TODO 목록 보기' },
] as const
const DESK_COMMAND = { name: 'desk', description: 'Desk 패널 열기 (지금 상태·결정 필요·진행 중·TODO)', immediate: true } as const

// brief 의 인자 벡터로 바꾼다. 인자가 모자라면 안내문을 돌려준다.
export function toArgv(command: string, args: string | undefined): string[] | string {
  const text = (args ?? '').trim()
  if (command === 'today') return ['show']
  if (!text) return `/${command} 뒤에 번호를 붙여 주세요. 예: /${command} 2`
  if (command === 'done') {
    const words = text.split(/\s+/)
    const last = words[words.length - 1] ?? ''
    const flag = ['undo', 'keep', 'now'].includes(last) ? last : undefined
    const ref = (flag ? words.slice(0, -1) : words).join(' ')
    if (!ref) return `/done ${flag} 앞에 번호나 세션 이름을 붙여 주세요. 예: /done 2 ${flag}`
    return flag ? ['done', ref, `--${flag}`] : ['done', ref]
  }
  return [command, text]
}

// 문서를 다시 읽고, 바뀌었을 때만 상태를 고쳐 다시 그리게 한다.
async function refresh($: EngineInterface): Promise<void> {
  try {
    const ran = await $.process.run(['/bin/sh', '-c', LOAD], { timeoutMs: 5000 })
    const view = parseDesk(ran.stdout ?? '')
    const fresh = view.file || view.todo.length > 0 ? view : null
    const before = await read($, desk)
    if (JSON.stringify(before) !== JSON.stringify(fresh)) await update($, desk, () => fresh)
  } catch {
    // 읽지 못하면 지난 상태를 그대로 둔다.
  }
}

// 결정 줄이 가리키는 TODO 번호("…(1번)"). 없으면 0.
export const todoOf = (text: string): number => Number(/\((\d+)번\)/.exec(text)?.[1] ?? 0)

// 결정 줄의 머리. 결정에는 따로 번호를 매기지 않는다: 화면에 보이는 번호는 TODO 번호 하나뿐이라
// 사용자가 "N번"이라고 하면 늘 같은 세션을 가리킨다. 세션 없는 결정은 번호 없이 글머리표만 둔다.
export const decisionHead = (text: string, full = false): string => {
  const n = todoOf(text)
  return `${n > 0 ? `${n}번 ` : ''}${full ? text : text.split(' — ')[0]}`
}

// brief 를 실행하고 한 줄 결과를 알림으로 보여 준다(패널·띠에서 눌렀을 때).
async function press($: EngineInterface, argv: string[]): Promise<void> {
  try {
    const ran = await $.process.run(
      ['/bin/sh', '-c', 'exec "$HOME/.local/bin/brief" "$@"', 'brief', ...argv],
      { timeoutMs: 10000 },
    )
    const out = (ran.stdout || ran.stderr).trim().split('\n')[0]
    if (out) $.ui.toast(out)
  } catch (error) {
    $.ui.toast(`brief 를 실행하지 못했습니다: ${String(error)}`)
  }
  void refresh($)
}

export const register: Register = on => {
  on('session.start', async ($, e, next) => {
    for (const spec of COMMANDS) await $.command.register({ ...spec, immediate: true })
    await $.command.register(DESK_COMMAND)
    await refresh($)
    $.clock.every(20000, () => void refresh($))
    void $.ui.open({ id: PANE, title: 'Desk' })

    return next(e)
  })

  on('command.run', { command: 'desk' }, async $ => {
    await refresh($)
    const { isPlaced } = await $.ui.open({ id: PANE, title: 'Desk' })

    return { text: isPlaced ? 'Desk 패널을 열었습니다.' : 'Desk 패널을 둘 자리가 없습니다. pane 을 넓히면 열립니다.' }
  })

  on('tool.call', async ($, e, next) => {
    const ran = await next(e)
    if (e.tool === 'Edit' || e.tool === 'Write' || e.tool === 'Bash') void refresh($)

    return ran
  })

  on('turn.complete', async ($, e, next) => {
    await refresh($)

    return next(e)
  })

  on('ui.render', { component: 'AbovePrompt' }, async ($, e, next) => {
    const view = await read($, desk)
    if (e.props.hasSurvey || view === null || (!view.now && view.todo.length === 0)) return next(e)

    const { Box, Text, Button } = $.ui.resolve(e)
    const left = view.todo.filter(it => !it.done).length
    const shown = view.decisions.slice(0, 3)
    const counts = [
      `결정 ${view.decisions.length}`, `진행 ${view.running.length}`, `예약 ${view.standing.length}`,
      `끝남 ${view.finished.length}`, `TODO ${left}/${view.todo.length}`,
      view.updated ? `갱신 ${view.updated}` : '',
    ].filter(Boolean).join(' · ')

    return (
      <Box flexDirection="column">
        {view.now && (
          <Text wrap="wrap">
            <Text bold color="claude">☀ 지금 </Text>
            {view.now}
          </Text>
        )}
        {shown.map((text, i) => {
          const label = `▸ ${decisionHead(text)}`
          const n = todoOf(text)
          // 세션이 딸린 결정은 누르면 그 pane 으로 간다. 띠에는 단축키를 두지 않는다(빈 프롬프트의 숫자 입력을 가로챈다).
          return n > 0
            ? <Button key={`band-go-${i}`} plain onPress={() => void press($, ['go', String(n)])}><Text color="warning">{label}</Text></Button>
            : <Text color="warning" wrap="truncate-end">{label}</Text>
        })}
        {view.decisions.length > shown.length && (
          <Text dimColor>{`  … 결정 ${view.decisions.length - shown.length}건 더 (/desk)`}</Text>
        )}
        <Text dimColor>{counts}</Text>
      </Box>
    )
  })

  // 데스크 문서를 고친 기록(diff)은 대화 영역에서 한 줄로 접는다. 내용은 띠와 Desk 패널에 이미 있다.
  // ctrl+o(펼쳐 보기)와 실패한 호출은 그대로 둔다.
  on('ui.render', { component: 'ToolUse' }, async ($, e, next) => {
    const { tool, input, isExpanded, isErrored } = e.props
    if (isExpanded || isErrored || !isDeskEdit(tool, (input as { file_path?: unknown } | null)?.file_path)) return next(e)
    const { Text } = $.ui.resolve(e)

    return <Text dimColor>{e.props.isRunning ? '✎ Desk 문서 고치는 중' : '✎ Desk 문서 갱신'}</Text>
  })

  on('ui.render', { component: 'ToolResult' }, async ($, e, next) => {
    const { tool, output, isExpanded, isErrored } = e.props
    if (isExpanded || isErrored || !isDeskEdit(tool, (output as { filePath?: unknown } | null)?.filePath)) return next(e)
    const { Box } = $.ui.resolve(e)

    return <Box />
  })

  on('ui.render', { component: 'Pane', requestId: PANE }, async ($, e) => {
    const { Box, Text, Button } = $.ui.resolve(e)
    const view = await read($, desk)
    if (view === null) return <Text dimColor>데스크 문서가 아직 없습니다 (Desk/YYMMDD.md).</Text>
    const go = (n: number) => () => void press($, ['go', String(n)])

    const block = (title: string, rows: string[], color?: 'warning') => (
      <Box flexDirection="column" marginTop={1}>
        <Text bold color={color}>{`${title} ${rows.length}`}</Text>
        {rows.length === 0 && <Text dimColor>  없음</Text>}
        {rows.map((text, i) => (
          <Text wrap="wrap" color={color}>{color ? `${i + 1}. ${text}` : `· ${text}`}</Text>
        ))}
      </Box>
    )

    return (
      <Box flexDirection="column">
        <Text dimColor>{[view.file, view.updated && `갱신 ${view.updated}`].filter(Boolean).join(' · ')}</Text>
        {view.now && <Text bold wrap="wrap">{view.now}</Text>}
        {view.board.length > 0 && (
          <Box flexDirection="column" marginTop={1}>
            <Text bold>지표</Text>
            {view.board.map(row => (
              <Text wrap="wrap" color={row.warn ? 'warning' : undefined}>
                <Text dimColor={!row.warn}>{`${row.warn ? '!' : '·'} ${row.k}  `}</Text>
                {row.text}
              </Text>
            ))}
          </Box>
        )}
        <Box flexDirection="column" marginTop={1}>
          <Text bold color="warning">{`결정 필요 ${view.decisions.length}`}</Text>
          {view.decisions.length === 0 && <Text dimColor>  없음</Text>}
          {view.decisions.map((text, i) => (
            <Box flexDirection="column">
              <Text wrap="wrap" color="warning">{`· ${decisionHead(text, true)}`}</Text>
              {todoOf(text) > 0 && (
                <Button key={`dec-go-${i}`} plain dimColor onPress={go(todoOf(text))}>{`   → ${todoOf(text)}번 세션으로 가기`}</Button>
              )}
            </Box>
          ))}
        </Box>
        {block('진행 중', view.running)}
        {block('예약', view.standing)}
        {block('오늘 끝난 것', view.finished)}
        <Box flexDirection="column" marginTop={1}>
          <Text bold>{`TODO ${view.todo.filter(it => !it.done).length}/${view.todo.length}`}</Text>
          <Text dimColor>줄을 누르면 그 세션으로 갑니다. 패널에 포커스가 있으면 숫자 키로도 갑니다.</Text>
          {view.todo.map(it => (
            <Box flexDirection="column">
              <Button key={`todo-go-${it.n}`} plain dimColor={it.done} hotkey={it.n <= 9 ? String(it.n) : undefined} onPress={go(it.n)}>
                {`${it.n > 9 ? `${it.n}: ` : ''}${it.title}${it.review ? ' · 완료 검토 중' : ''}`}
              </Button>
              {it.do && <Text wrap="wrap" dimColor>{`   ${it.do}`}</Text>}
            </Box>
          ))}
        </Box>
      </Box>
    )
  })

  for (const { name } of COMMANDS) {
    on('command.run', { command: name }, async ($, e) => {
      const argv = toArgv(name, e.args)
      if (typeof argv === 'string') return { text: argv }
      try {
        // PATH 에 기대지 않도록 홈의 brief 를 직접 부른다.
        const ran = await $.process.run(
          ['/bin/sh', '-c', 'exec "$HOME/.local/bin/brief" "$@"', 'brief', ...argv],
          { timeoutMs: 10000 },
        )
        const out = (ran.stdout || ran.stderr).trim()
        void refresh($)

        return { text: out || (ran.exitCode === 0 ? '완료' : `brief 가 코드 ${ran.exitCode} 로 끝났습니다.`) }
      } catch (error) {
        return { text: `brief 를 실행하지 못했습니다: ${String(error)}` }
      }
    })
  }
}
