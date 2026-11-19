import { expect, test } from 'claude-code/testing'

function harness(on: any, calls: string[][], answer = { exitCode: 0, stdout: '이동: 세션\n', stderr: '' }) {
  const registered: string[] = []
  on('command.register', (_: unknown, e: any) => {
    registered.push(e.name ?? e.command?.name)
    return { value: { command: e.name ?? e.command?.name } }
  })
  on('session.start', (_: unknown, e: any) => ({ cwd: e.cwd }))
  on('ui.open', () => ({ value: { isPlaced: false } }))
  on('clock.every', () => ({ value: undefined }))
  on('process.run', (_: unknown, e: any) => {
    // 데스크 문서를 다시 읽는 호출은 세지 않는다. brief 호출만 센다.
    if ((e.argv ?? [])[3] === 'brief') calls.push([...(e.argv ?? [])])
    return { value: answer }
  })
  return registered
}

test('/go 2 runs `brief go 2` and shows its output', async ($, on) => {
  const calls: string[][] = []
  harness(on, calls)
  await $.session.start({ cwd: '/', surface: 'terminal', isInteractive: true })

  const ran = await $.command.run({ command: 'go', args: '2' })

  expect(ran.text).toBe('이동: 세션')
  expect(calls.length).toBe(1)
  expect(calls[0].slice(-3)).toEqual(['brief', 'go', '2'])
})

test('/done 3 undo maps to --undo, /today to show, and a bare /go explains itself', async ($, on) => {
  const calls: string[][] = []
  harness(on, calls)
  await $.session.start({ cwd: '/', surface: 'terminal', isInteractive: true })

  await $.command.run({ command: 'done', args: '3 undo' })
  await $.command.run({ command: 'today' })
  const bare = await $.command.run({ command: 'go' })

  expect(calls[0].slice(-3)).toEqual(['done', '3', '--undo'])
  expect(calls[1].slice(-1)).toEqual(['show'])
  expect(calls.length).toBe(2)
  expect(bare.text).toMatch(/번호/)
})

test('a brief failure is shown, not swallowed', async ($, on) => {
  const calls: string[][] = []
  harness(on, calls, { exitCode: 1, stdout: '', stderr: 'brief: 목록에 9번이 없습니다 (총 7개)\n' })
  await $.session.start({ cwd: '/', surface: 'terminal', isInteractive: true })

  const ran = await $.command.run({ command: 'go', args: '9' })

  expect(ran.text).toBe('brief: 목록에 9번이 없습니다 (총 7개)')
})

test('/done 2 keep maps to --keep and a session name passes through', async ($, on) => {
  const calls: string[][] = []
  harness(on, calls)
  await $.session.start({ cwd: '/', surface: 'terminal', isInteractive: true })

  await $.command.run({ command: 'done', args: '2 keep' })
  await $.command.run({ command: 'done', args: '세션 이름 now' })
  const bare = await $.command.run({ command: 'done', args: 'keep' })

  expect(calls[0].slice(-3)).toEqual(['done', '2', '--keep'])
  expect(calls[1].slice(-3)).toEqual(['done', '세션 이름', '--now'])
  expect(calls.length).toBe(2)
  expect(bare.text).toContain('/done')
})

test('the band shows the desk document: now line, decisions, counts', async ($, on) => {
  const doc = [
    'Desk/261112.md',
    '# Desk 11-12  ·  갱신 14:20',
    '**지금**: 2번 세션이 결정을 기다린다. 미루면 다음 일이 밀린다.',
    '## 결정 필요',
    '- **정할 것 하나** — `세션 A` · 권고: 고정',
    '- **정할 것 둘** — `세션 B`(2번) · 권고: 시험',
    '## 진행 중',
    '- `세션 B` — 작업 중',
    '## 예약',
    '없음',
    '## 오늘 끝난 것',
    '## 타임라인 (최신이 위)',
    '- 14:20 무시되어야 하는 줄',
    '\u001e',
    JSON.stringify({ items: [{ title: 'A', do: 'x', done: true }, { title: 'B', do: 'y', done: false }] }),
  ].join('\n')
  const calls: string[][] = []
  harness(on, calls, { exitCode: 0, stdout: doc, stderr: '' })
  await $.session.start({ cwd: '/', surface: 'terminal', isInteractive: true })

  const ui = await $.ui.mount({
    plugin: 'brief-nav', component: 'AbovePrompt', surface: 'terminal',
    props: { hasSurvey: false, isCollapsed: false, isWorking: false, maxRows: 10 },
  } as any)

  expect((await ui.find({ type: 'Text', text: /2번 세션이 결정을/ }))?.text).toContain('지금')
  // 결정에는 자기 번호가 없다: 세션이 딸린 결정은 그 세션의 TODO 번호로, 아니면 번호 없이 보인다.
  expect((await ui.find({ type: 'Text', text: /정할 것 하나/ }))?.text).toBe('▸ 정할 것 하나')
  expect((await ui.find({ type: 'Text', text: /정할 것 둘/ }))?.text).toBe('▸ 2번 정할 것 둘')
  expect((await ui.find({ type: 'Text', text: /TODO/ }))?.text).toBe('결정 2 · 진행 1 · 예약 0 · 끝남 0 · TODO 1/2 · 갱신 14:20')
  expect(await ui.find({ type: 'Text', text: /무시되어야/ })).toBeFalsy()
  await ui.unmount()
})

test('desk document edits fold to one line; other edits and ctrl+o stay as they are', async ($, on) => {
  const calls: string[][] = []
  harness(on, calls, { exitCode: 0, stdout: '', stderr: '' })
  await $.session.start({ cwd: '/', surface: 'terminal', isInteractive: true })
  const row = (file_path: string, isExpanded = false) => $.ui.mount({
    plugin: 'brief-nav', component: 'ToolUse', surface: 'terminal',
    props: { tool_use_id: 't1', tool: 'Edit', input: { file_path, old_string: 'a', new_string: 'b' }, isRunning: false, isErrored: false, isInterrupted: false, isExpanded },
  } as any)

  const folded = await row('/vault/Daily/Desk/261112.md')
  expect((await folded.find({ type: 'Text', text: /Desk 문서 갱신/ }))?.text).toBe('✎ Desk 문서 갱신')
  await folded.unmount()
  for (const ui of [await row('/vault/Daily/2026-11-12.md'), await row('/vault/Daily/Desk/261112.md', true)]) {
    expect(await ui.find({ type: 'Text', text: /Desk 문서 갱신/ })).toBeFalsy()
    await ui.unmount()
  }
})

test('pressing a TODO row in the Desk pane runs `brief go <n>`', async ($, on) => {
  const doc = ['Desk/261112.md', '# Desk 11-12  ·  갱신 14:20', '**지금**: x.', '## 결정 필요',
    '- **시험 먼저 할지** — `리뷰`(2번) · 권고: 시험', '\u001e',
    JSON.stringify({ items: [{ title: 'A', do: 'x', done: false }, { title: 'B', do: 'y', done: false }] })].join('\n')
  const calls: string[][] = []
  harness(on, calls, { exitCode: 0, stdout: doc, stderr: '' })
  await $.session.start({ cwd: '/', surface: 'terminal', isInteractive: true })
  const ui = await $.ui.mount({ plugin: 'brief-nav', component: 'Pane', surface: 'terminal', requestId: 'desk', props: { id: 'desk', title: 'Desk', placement: 'dock' } } as any)

  await ui.press({ key: 'todo-go-2' } as any)
  await ui.press({ key: 'dec-go-0' } as any)

  expect(calls.filter(c => c.includes('go')).map(c => c.slice(-2))).toEqual([['go', '2'], ['go', '2']])
  expect((await ui.find({ type: 'Text', text: /시험 먼저/ }))?.text).toBe('· 2번 시험 먼저 할지 — 리뷰(2번) · 권고: 시험')
  await ui.unmount()
})
