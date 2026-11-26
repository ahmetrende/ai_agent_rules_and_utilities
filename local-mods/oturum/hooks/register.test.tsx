import { expect, mock, test } from 'claude-code/testing'
import type { TestBody } from 'claude-code/testing'
import type { On } from 'claude-code'

const PANE = {
  plugin: 'oturum',
  component: 'Pane',
  requestId: 'oturum',
  props: {
    title: 'Oturumlar',
    isFocused: false,
    bodyColumns: 60,
    placement: 'dock',
    scroll: { offset: 0, bodyRows: 30 },
    view: {},
  },
} as const

// 2026-11-23 09:05 UTC is 12:05 in Turkey.
const NOW = Date.parse('2026-11-23T09:05:00Z')
// 08:00 UTC is 11:00 in Turkey.
const ACTIVE = Date.parse('2026-11-23T08:00:00Z') / 1000
// 07:30 UTC is 10:30 in Turkey.
const WRITTEN = Date.parse('2026-11-23T07:30:00Z') / 1000

const file = (path: string, exists: boolean) => ({ path, exists })

const OUTPUT = {
  generated: ACTIVE,
  text: 'ÖZET METNİ',
  machines: [
    {
      name: 'mac',
      ok: true,
      error: null,
      sessions: [
        {
          // 30 minutes of work after the handoff, a detail note, account "work".
          sessionId: 'aaaaaaaa-1111',
          title: 'Kart akışı',
          cwd: '/w/cards',
          project: 'cards',
          gitBranch: 'main',
          orgId: 'org-1',
          account: 'work',
          lastActivity: ACTIVE,
          sizeBytes: 100,
          cwdExists: true,
          handoff: {
            path: '/w/cards/.claude/x-handoff-aaaaaaaa-1111.md',
            prompt: 'Devam et: kart akışı testleri.',
            writtenAt: WRITTEN,
            title: 'Devir',
            readFirst: 'Önce migration testini çalıştır.',
            detail: file('/w/cards/.claude/x-handoff-aaaaaaaa-1111.detay.md', true),
            dump: file('/cfg/handoff-dumps/x.transcript.md', false),
          },
        },
        {
          // No title, no account, no detail note, no work after the handoff.
          sessionId: 'bbbbbbbb-2222',
          title: null,
          cwd: '/w/other',
          project: 'other',
          gitBranch: null,
          orgId: null,
          account: null,
          lastActivity: WRITTEN - 7200 + 300,
          sizeBytes: 5,
          cwdExists: true,
          handoff: {
            path: '/w/other/.claude/y-handoff-bbbbbbbb-2222.md',
            prompt: 'Başka oturum prompt.',
            writtenAt: WRITTEN - 7200,
            title: 'Devir',
            readFirst: null,
            detail: file('/w/other/.claude/y-handoff-bbbbbbbb-2222.detay.md', false),
            dump: file('/cfg/handoff-dumps/y.transcript.md', false),
          },
        },
        {
          // No handoff: counted in the footer, never listed.
          sessionId: 'cccccccc-3333',
          title: 'Notsuz oturum',
          cwd: '/w/none',
          project: 'none',
          gitBranch: null,
          orgId: null,
          account: null,
          lastActivity: ACTIVE,
          sizeBytes: 1,
          cwdExists: true,
          handoff: null,
        },
      ],
    },
    {
      name: 'ubuntu',
      ok: true,
      error: null,
      sessions: [
        {
          // 2 h 10 min of work after the handoff, account "personal".
          sessionId: 'dddddddd-4444',
          title: 'Zeta işi',
          cwd: '/srv/zeta',
          project: 'zeta',
          gitBranch: 'dev',
          orgId: 'org-2',
          account: 'personal',
          lastActivity: WRITTEN + 600 + 7800,
          sizeBytes: 9,
          cwdExists: true,
          handoff: {
            path: '/srv/zeta/.claude/z-handoff-dddddddd-4444.md',
            prompt: 'Zeta devam promptu.',
            writtenAt: WRITTEN + 600,
            title: 'Devir',
            readFirst: 'x',
            detail: file('/srv/zeta/.claude/z-handoff-dddddddd-4444.detay.md', true),
            dump: file('/cfg/handoff-dumps/z.transcript.md', true),
          },
        },
      ],
    },
    { name: 'broken', ok: false, error: 'Permission denied (publickey).', sessions: [] },
  ],
  notes: ['ubuntu eski sürüm'],
}

// The full input of command.run: the test's $ takes what the engine stamps itself.
const RUN = {
  command: 'oturum',
  args: '',
  origin: { kind: 'composer' },
  presentation: { isFullscreen: false, columns: 80 },
} as const

type Run ={ argv: readonly string[]; timeoutMs?: number }

// The engine beneath the mod: command and pane registration, the clock, and process.run.
// `outputs` is consumed one per run; the last one repeats.
// What the Desktop app's session list (mcp.call list_sessions) answers: a hook result.
const archiveOf = (rows: unknown) => () => ({
  value: { content: [{ type: 'text', text: JSON.stringify(rows) }], isError: false },
})
const NO_ARCHIVE = archiveOf([])

const world = (
  on: On,
  outputs: (() => { exitCode: number; stdout: string; stderr: string })[],
  archive: () => unknown = NO_ARCHIVE,
) => {
  const registered: { name: string; description: string }[] = []
  const opened: { id: string; title?: string }[] = []
  const runs: Run[] = []
  mock.clock(on, { now: NOW })
  on('session.start', (_, e) => ({ cwd: e.cwd }))
  on('command.register', (_, e) => (registered.push(e), { value: { command: e.name } }))
  on('ui.open', (_, e) => (opened.push(e), { value: { isPlaced: true } }))
  on('ui.log', () => ({ value: undefined }))
  on('mcp.call', () => archive() as never)
  const copied: { text: string; surface?: string }[] = []
  const toasts: string[] = []
  on('ui.copy', (_, e) => (copied.push({ text: e.text, surface: e.surface }), { value: { isCopied: true } }))
  on('ui.toast', (_, e) => (toasts.push(e.text), { value: undefined }))
  on('process.run', (_, e) => {
    runs.push({ argv: e.argv, timeoutMs: e.init?.timeoutMs })
    const make = outputs[Math.min(runs.length - 1, outputs.length - 1)]!
    return {
      value: { ...make(), isStdoutTruncated: false, isStderrTruncated: false },
    }
  })
  return { registered, opened, runs, copied, toasts }
}

const ok = (output: unknown) => () => ({ exitCode: 0, stdout: JSON.stringify(output), stderr: '' })

// The titles of the listed cards ("1. Title" without the number), in the order drawn.
const headings = async (ui: { findAll: (q: { type: 'Text'; text: RegExp }) => Promise<{ text?: string }[]> }) =>
  (await ui.findAll({ type: 'Text', text: /^\d+\. / })).map(f => f.text?.replace(/^\d+\. /, ''))

test('the command registers on session.start', async ($, on) => {
  const w = world(on, [ok(OUTPUT)])
  await $.session.start({ cwd: '/', surface: 'desktop', isInteractive: true })

  expect(w.registered.length).toBe(1)
  expect(w.registered[0]!.name).toBe('oturum')
  expect(w.registered[0]!.description).toMatch(/oturum/i)
})

test('/oturum runs the script with the flags, opens the pane and returns data.text', async ($, on) => {
  const w = world(on, [ok(OUTPUT)])
  await $.session.start({ cwd: '/', surface: 'desktop', isInteractive: true })
  const result = await $.command.run(RUN)

  expect(w.runs.length).toBe(1)
  const run = w.runs[0]!
  expect(run.argv[0]).toBe('python3')
  expect(run.argv[1]).toMatch(/\/bin\/sessions\.py$/)
  expect(run.argv.slice(2)).toEqual(['--all', '--json'])
  expect(run.timeoutMs).toBe(90000)
  expect(w.opened).toEqual([{ id: 'oturum', title: 'Oturumlar' }])
  expect(result.text).toBe('ÖZET METNİ')
})

test('the command answers a short error when the output has no text', async ($, on) => {
  const { text: _text, ...noText } = OUTPUT
  world(on, [ok(noText)])
  await $.session.start({ cwd: '/', surface: 'desktop', isInteractive: true })
  const result = await $.command.run(RUN)

  expect(result.text).toContain('Oturumlar okunamadı')
})

test('the pane lists only sessions with a handoff: bold line, warnings, path, prompt', async ($, on) => {
  world(on, [ok(OUTPUT)])
  await $.session.start({ cwd: '/', surface: 'desktop', isInteractive: true })
  await $.command.run(RUN)

  for (const surface of ['terminal', 'desktop', 'vscode', 'mobile'] as const) {
    const ui = await $.ui.mount({ ...PANE, surface })

    expect((await ui.find({ type: 'Text', text: /^Son yenileme \d{4}-11-23 12:05 TR$/ }))?.text).toBeDefined()
    expect(await ui.find({ type: 'Button', key: 'refresh' })).toBeDefined()
    expect(await ui.find({ type: 'Input', key: 'q' })).toBeDefined()
    expect(await ui.find({ type: 'Select', key: 'account' })).toBeDefined()
    expect(await ui.find({ type: 'Select', key: 'machine' })).toBeDefined()
    expect(await ui.find({ type: 'Select', key: 'sort' })).toBeDefined()

    // Numbered titles, newest handoff first, and the small line under each.
    expect((await ui.findAll({ type: 'Text', text: /^\d+\. / })).map(f => f.text)).toEqual([
      '1. Zeta işi',
      '2. Kart akışı',
      '3. bbbbbbbb',
    ])
    expect(await ui.find({ type: 'Text', text: /^mac · work · son hareket 2026-11-23 11:00 · kapalı$/ })).toBeDefined()
    expect(await ui.find({ type: 'Text', text: /^mac · hesap bilinmiyor · son hareket 2026-11-23 08:35 · kapalı$/ })).toBeDefined()
    expect(await ui.find({ type: 'Text', text: /^ubuntu · personal · / })).toBeDefined()
    // The handoff time is on its own line.
    expect(await ui.find({ type: 'Text', text: /^devir notu 2026-11-23 10:30$/ })).toBeDefined()
    expect(await ui.findAll({ type: 'Text', text: /^devir notu yok$/ })).toHaveLength(0)

    // The folder to open a new session in.
    expect((await ui.find({ type: 'Text', text: /^Klasör: \/w\/cards$/ }))?.text).toBe('Klasör: /w/cards')

    // A session without a handoff is not listed.
    expect(await ui.findAll({ type: 'Text', text: /Notsuz oturum/ })).toHaveLength(0)

    // Warnings: 30 min and 2 h 10 min of later work, one missing detail note.
    expect(await ui.find({ type: 'Text', text: /^⚠ nottan sonra 30 dk daha çalıştı$/ })).toBeDefined()
    expect(await ui.find({ type: 'Text', text: /^⚠ nottan sonra 2 sa 10 dk daha çalıştı$/ })).toBeDefined()
    expect(await ui.findAll({ type: 'Text', text: /nottan sonra/ })).toHaveLength(2)
    expect(await ui.findAll({ type: 'Text', text: /^⚠ detay notu yok$/ })).toHaveLength(1)

    // Path and prompt are not printed: buttons copy them.
    expect(await ui.findAll({ type: 'Text', text: /^Prompt: / })).toHaveLength(0)
    expect(await ui.find({ type: 'Button', key: 'prompt:aaaaaaaa-1111' })).toBeDefined()
    expect(await ui.find({ type: 'Button', key: 'path:aaaaaaaa-1111' })).toBeUndefined()
    expect(await ui.find({ type: 'Button', key: 'folder:aaaaaaaa-1111' })).toBeDefined()
    await ui.unmount()
  }
})

test('the copy buttons put the prompt and the folder on the clipboard', async ($, on) => {
  const w = world(on, [ok(OUTPUT)])
  await $.session.start({ cwd: '/', surface: 'desktop', isInteractive: true })
  await $.command.run(RUN)
  const ui = await $.ui.mount({ ...PANE, surface: 'desktop' })
  await ui.press({ key: 'prompt:aaaaaaaa-1111' })
  await ui.press({ key: 'folder:aaaaaaaa-1111' })
  expect(w.copied.map(c => c.text)).toEqual([
    'Devam et: kart akışı testleri.',
    '/w/cards',
  ])
  expect(w.toasts).toEqual(['Prompt kopyalandı', 'Klasör kopyalandı'])
  await ui.unmount()
})

test('cards are apart by a blank line, with no separator line', async ($, on) => {
  world(on, [ok(OUTPUT)])
  await $.session.start({ cwd: '/', surface: 'desktop', isInteractive: true })
  await $.command.run(RUN)
  const ui = await $.ui.mount({ ...PANE, surface: 'desktop' })

  // Three cards: a blank line between them, no line of "━".
  expect(await ui.findAll({ type: 'Text', text: /━/ })).toHaveLength(0)
  expect(await ui.findAll({ type: 'Text', text: /^ $/ })).toHaveLength(2)
  await ui.unmount()
})

test('the default order is the handoff time, newest first', async ($, on) => {
  world(on, [ok(OUTPUT)])
  await $.session.start({ cwd: '/', surface: 'desktop', isInteractive: true })
  await $.command.run(RUN)
  const ui = await $.ui.mount({ ...PANE, surface: 'desktop' })

  const list = await headings(ui)
  expect(list.map(t => t?.split(' · ')[0])).toEqual(['Zeta işi', 'Kart akışı', 'bbbbbbbb'])
  await ui.unmount()
})

test('the sort select changes the order: oldest first, and by name', async ($, on) => {
  world(on, [ok(OUTPUT)])
  await $.session.start({ cwd: '/', surface: 'desktop', isInteractive: true })
  await $.command.run(RUN)
  const ui = await $.ui.mount({ ...PANE, surface: 'desktop' })

  await ui.select({ key: 'sort', value: 'handoff-old' })
  await ui.redraw()
  expect((await headings(ui)).map(t => t?.split(' · ')[0])).toEqual(['bbbbbbbb', 'Kart akışı', 'Zeta işi'])

  await ui.select({ key: 'sort', value: 'name' })
  await ui.redraw()
  expect((await headings(ui)).map(t => t?.split(' · ')[0])).toEqual(['bbbbbbbb', 'Kart akışı', 'Zeta işi'])

  await ui.select({ key: 'sort', value: 'handoff-new' })
  await ui.redraw()
  expect((await headings(ui)).map(t => t?.split(' · ')[0])).toEqual(['Zeta işi', 'Kart akışı', 'bbbbbbbb'])
  await ui.unmount()
})

test('the search matches the title, the handoff path and the account, in Turkish case rules', async ($, on) => {
  world(on, [ok(OUTPUT)])
  await $.session.start({ cwd: '/', surface: 'desktop', isInteractive: true })
  await $.command.run(RUN)
  const ui = await $.ui.mount({ ...PANE, surface: 'desktop' })

  // Title, capital dotted İ and dotless I fold the Turkish way.
  await ui.input({ key: 'q', text: 'KART AKIŞI' })
  await ui.redraw()
  expect((await headings(ui)).length).toBe(1)
  expect(await headings(ui)).toEqual(['Kart akışı'])
  expect(await ui.find({ type: 'Text', text: /Gösterilen: 1 oturum · açık 0 ·/ })).toBeDefined()

  // Handoff path.
  await ui.input({ key: 'q', text: 'z-handoff-dddd' })
  await ui.redraw()
  expect((await headings(ui)).length).toBe(1)
  expect(await headings(ui)).toEqual(['Zeta işi'])

  // Account.
  await ui.input({ key: 'q', text: 'PERSONAL' })
  await ui.redraw()
  expect((await headings(ui)).length).toBe(1)
  expect(await headings(ui)).toEqual(['Zeta işi'])

  // No match, then cleared.
  await ui.input({ key: 'q', text: 'nothing-matches' })
  await ui.redraw()
  expect((await headings(ui)).length).toBe(0)
  expect(await ui.find({ type: 'Text', text: /Gösterilen: 0 oturum · açık 0 ·/ })).toBeDefined()

  await ui.input({ key: 'q', text: '' })
  await ui.redraw()
  expect((await headings(ui)).length).toBe(3)
  await ui.unmount()
})

test('the account and machine filters narrow the list', async ($, on) => {
  world(on, [ok(OUTPUT)])
  await $.session.start({ cwd: '/', surface: 'desktop', isInteractive: true })
  await $.command.run(RUN)
  const ui = await $.ui.mount({ ...PANE, surface: 'desktop' })

  await ui.select({ key: 'account', value: 'work' })
  await ui.redraw()
  expect((await headings(ui)).map(t => t?.split(' · ')[0])).toEqual(['Kart akışı'])

  // Sessions without an account.
  await ui.select({ key: 'account', value: '__none' })
  await ui.redraw()
  expect((await headings(ui)).map(t => t?.split(' · ')[0])).toEqual(['bbbbbbbb'])

  await ui.select({ key: 'account', value: '__all' })
  await ui.select({ key: 'machine', value: 'ubuntu' })
  await ui.redraw()
  expect((await headings(ui)).map(t => t?.split(' · ')[0])).toEqual(['Zeta işi'])
  expect(await ui.find({ type: 'Text', text: /Gösterilen: 1 oturum · açık 0 ·/ })).toBeDefined()

  await ui.select({ key: 'machine', value: 'mac' })
  await ui.redraw()
  expect((await headings(ui)).length).toBe(2)
  await ui.unmount()
})

test('the footer shows the counts, a failed machine and the notes', async ($, on) => {
  world(on, [ok(OUTPUT)])
  await $.session.start({ cwd: '/', surface: 'desktop', isInteractive: true })
  await $.command.run(RUN)
  const ui = await $.ui.mount({ ...PANE, surface: 'desktop' })

  expect((await ui.find({ type: 'Text', text: /^Gösterilen:/ }))?.text).toBe(
    'Gösterilen: 3 oturum · açık 0 · devir notu olmayan kapalı 1 oturum gösterilmedi',
  )
  expect(
    (await ui.find({ type: 'Text', text: /^Hata: broken:/ }))?.text,
  ).toBe('Hata: broken: Permission denied (publickey).')
  expect((await ui.find({ type: 'Text', text: /^Not: / }))?.text).toBe('Not: ubuntu eski sürüm')
  await ui.unmount()
})

test('the pane without data asks for a refresh', async ($, on) => {
  world(on, [ok(OUTPUT)])
  const ui = await $.ui.mount({ ...PANE, surface: 'desktop' })

  expect(await ui.find({ type: 'Text', text: /Henüz veri yok/ })).toBeDefined()
  expect(await ui.find({ type: 'Button', key: 'refresh' })).toBeDefined()
  await ui.unmount()
})

test('the refresh button runs the script again and redraws', async ($, on) => {
  const second = {
    ...OUTPUT,
    machines: [{ ...OUTPUT.machines[0]!, sessions: [{ ...OUTPUT.machines[0]!.sessions[0]!, title: 'Yeni ad' }] }],
  }
  const w = world(on, [ok(OUTPUT), ok(second)])
  await $.session.start({ cwd: '/', surface: 'desktop', isInteractive: true })
  await $.command.run(RUN)
  expect(w.runs.length).toBe(1)

  let expected = 1
  for (const surface of ['terminal', 'desktop'] as const) {
    const ui = await $.ui.mount({ ...PANE, surface })
    await ui.press({ key: 'refresh' })
    await ui.redraw()

    expected += 1
    expect(w.runs.length).toBe(expected)
    expect(w.runs.at(-1)!.argv.slice(2)).toEqual(['--all', '--json'])
    expect(await headings(ui)).toContain('Yeni ad')
    await ui.unmount()
  }
})

test('a process that exits with an error is shown in the pane and the command text', async ($, on) => {
  world(on, [() => ({ exitCode: 2, stdout: '', stderr: '\npython3: can\'t open file\nmore' })])
  await $.session.start({ cwd: '/', surface: 'desktop', isInteractive: true })
  const result = await $.command.run(RUN)

  expect(result.text).toContain("python3 çıkış kodu 2: python3: can't open file")
  const ui = await $.ui.mount({ ...PANE, surface: 'desktop' })
  expect(await ui.find({ type: 'Text', text: /Hata: python3 çıkış kodu 2/ })).toBeDefined()
  expect(await ui.find({ type: 'Button', key: 'refresh' })).toBeDefined()
  await ui.unmount()
})

test('a process that cannot start does not throw out of the hook', async ($, on) => {
  mock.clock(on, { now: NOW })
  on('session.start', (_, e) => ({ cwd: e.cwd }))
  on('command.register', (_, e) => ({ value: { command: e.name } }))
  on('ui.open', () => ({ value: { isPlaced: true } }))
  on('ui.log', () => ({ value: undefined }))
  // A hook that throws is skipped, so the refusal is spelled { deny }: the call rejects.
  on('process.run', () => ({ deny: 'spawn python3 ENOENT' }))
  await $.session.start({ cwd: '/', surface: 'desktop', isInteractive: true })
  const result = await $.command.run(RUN)

  expect(result.text).toContain('Oturumlar okunamadı')
  const ui = await $.ui.mount({ ...PANE, surface: 'desktop' })
  expect(await ui.find({ type: 'Text', text: /Hata: / })).toBeDefined()
  await ui.unmount()
})

test('output that is not JSON is an error, not a crash', async ($, on) => {
  world(on, [() => ({ exitCode: 0, stdout: 'hello', stderr: '' })])
  await $.session.start({ cwd: '/', surface: 'desktop', isInteractive: true })
  const result = await $.command.run(RUN)

  expect(result.text).toContain('JSON değil')
})

test('a drawing for another pane goes to the engine', async ($, on) => {
  world(on, [ok(OUTPUT)])
  on('ui.render', ($, e) => {
    const { Text } = $.ui.resolve(e)

    return <Text>engine</Text>
  })
  const ui = await $.ui.mount({ ...PANE, requestId: 'other', surface: 'desktop' })

  expect((await ui.find({ type: 'Text', text: /engine/ }))?.text).toBe('engine')
  await ui.unmount()
})

// Live peers as ListAgents answers them. "Kart akışı" pairs with a session that has a handoff,
// "Notsuz oturum" with one that has none, "Yalnız peer" with no session. The offline "Zeta işi"
// is left out, so that session stays closed.
const AGENTS = {
  listing: 'x',
  sections: [
    {
      kind: 'peers',
      total: 4,
      rows: [
        { name: 'Kart akışı', ref: 'k1', type: 'remote_control', status: 'idle' },
        { name: 'Notsuz oturum', ref: 'n1', type: 'interactive', status: 'running' },
        { name: 'Zeta işi', ref: 'z1', type: 'interactive', status: 'offline' },
      ],
    },
    { kind: 'local', total: 1, rows: [{ name: 'Yalnız peer', ref: 'p1', status: 'idle' }] },
  ],
}

// The bulk world: the base world, ListAgents answered by `agents`, and sends answered per target.
const bulkWorld = (
  on: On,
  agents: unknown,
  deliver: (to: string) => { isDelivered: true } | { isDelivered: false; reason: string } = () => ({ isDelivered: true }),
  output: unknown = OUTPUT,
  archive: () => unknown = NO_ARCHIVE,
) => {
  const w = world(on, [ok(output)], archive)
  const sends: { to: unknown; text: string }[] = []
  const calls = { agents: 0 }
  on('tool.call', () => {
    calls.agents += 1
    return typeof agents === 'string' ? { deny: agents } : { result: agents as never }
  })
  on('session.send', (_, e) => {
    sends.push({ to: e.to, text: e.text })
    return deliver(e.to)
  })
  return { ...w, sends, calls }
}

// /oturum loads the sessions and the live peers, then the pane is drawn.
const openBulk = async ($: Parameters<TestBody>[0], _on: On) => {
  await $.session.start({ cwd: '/', surface: 'desktop', isInteractive: true })
  await $.command.run(RUN)
  return $.ui.mount({ ...PANE, surface: 'desktop' })
}

// The labels of the check box buttons, in the order drawn.
const peerButtons = async (ui: { findAll: (q: { type: 'Button'; text: RegExp }) => Promise<{ text?: string }[]> }) =>
  (await ui.findAll({ type: 'Button', text: /^[☐☑] \d+\. / })).map(b => b.text)

const handoffOf = (written: number) => ({
  path: '/p/.claude/h.md',
  prompt: 'p',
  writtenAt: written,
  title: 'Devir',
  readFirst: null,
  detail: file('/p/.claude/h.detay.md', true),
  dump: file('/d/h.transcript.md', false),
})

const sessionOf = (id: string, title: string, last: number, written: number | null) => ({
  sessionId: id,
  title,
  cwd: '/w/x',
  project: 'x',
  gitBranch: null,
  orgId: null,
  account: null,
  lastActivity: last,
  sizeBytes: 1,
  cwdExists: true,
  handoff: written === null ? null : handoffOf(written),
})

const outputWith = (sessions: unknown[]) => ({
  ...OUTPUT,
  machines: [{ name: 'mac', ok: true, error: null, sessions }],
})

test('open sessions get a check box, offline and closed ones do not', async ($, on) => {
  bulkWorld(on, AGENTS)
  const ui = await openBulk($, on)

  // Peer-only row first (newest), then the paired sessions. Zeta (offline) is closed: bold Text.
  expect(await peerButtons(ui)).toEqual(['☐ 1. Yalnız peer', '☐ 3. Kart akışı', '☐ 4. Notsuz oturum'])
  expect(await headings(ui)).toContain('Zeta işi')
  expect(await ui.find({ type: 'Button', key: 'pick:Zeta işi [z1]' })).toBeUndefined()
  expect(await ui.find({ type: 'Text', text: /^Kutu yalnız açık oturumlarda var\./ })).toBeDefined()
  expect(await ui.find({ type: 'Text', text: /^2\. Zeta işi$/ })).toBeDefined()
  await ui.unmount()
})

test('a closed session has no box and says kapalı', async ($, on) => {
  bulkWorld(on, { listing: '', sections: [] })
  const ui = await openBulk($, on)

  expect(await peerButtons(ui)).toHaveLength(0)
  expect(await ui.findAll({ type: 'Text', text: / · kapalı$/ })).toHaveLength(3)
  expect(await ui.findAll({ type: 'Text', text: / · (boşta|çalışıyor)$/ })).toHaveLength(0)
  await ui.unmount()
})

test('a deny from ListAgents shows an error text and the closed rows stay', async ($, on) => {
  bulkWorld(on, 'no access')
  const ui = await openBulk($, on)

  expect(await ui.find({ type: 'Text', text: /^Oturum listesi alınamadı: no access$/ })).toBeDefined()
  expect(await peerButtons(ui)).toHaveLength(0)
  expect((await headings(ui)).length).toBe(3)
  await ui.unmount()
})

test('a live peer is paired with the session of the same title and gets a box', async ($, on) => {
  bulkWorld(on, AGENTS)
  const ui = await openBulk($, on)

  expect(await ui.find({ type: 'Text', text: /^mac · work · son hareket 2026-11-23 11:00 · boşta$/ })).toBeDefined()
  // The paired row keeps its handoff data and buttons, and is not listed twice.
  expect(await ui.find({ type: 'Text', text: /^devir notu 2026-11-23 10:30$/ })).toBeDefined()
  expect(await ui.find({ type: 'Button', key: 'prompt:aaaaaaaa-1111' })).toBeDefined()
  expect((await headings(ui)).filter(t => t === 'Kart akışı')).toHaveLength(0)
  expect(await peerButtons(ui)).toContain('☐ 3. Kart akışı')
  await ui.unmount()
})

test('a session without a handoff becomes a row when a live peer pairs with it', async ($, on) => {
  bulkWorld(on, AGENTS)
  const ui = await openBulk($, on)

  expect(await ui.find({ type: 'Text', text: /^mac · hesap bilinmiyor · son hareket 2026-11-23 11:00 · çalışıyor$/ })).toBeDefined()
  expect(await ui.findAll({ type: 'Text', text: /^devir notu yok$/ })).toHaveLength(1)
  // No handoff, so no copy buttons.
  expect(await ui.find({ type: 'Button', key: 'prompt:cccccccc-3333' })).toBeUndefined()
  expect(await ui.find({ type: 'Text', text: /^Gösterilen: 5 oturum · açık 3 · devir notu olmayan kapalı 0 oturum/ })).toBeDefined()
  await ui.unmount()
})

test('a live peer without a session is a row with an unknown last activity', async ($, on) => {
  bulkWorld(on, AGENTS)
  const ui = await openBulk($, on)

  expect(await ui.find({ type: 'Text', text: /^son hareket bilinmiyor · boşta$/ })).toBeDefined()
  expect(await ui.find({ type: 'Button', key: 'pick:Yalnız peer [p1]' })).toBeDefined()
  // Machine and account filters hide it: its machine and account are unknown.
  await ui.select({ key: 'machine', value: 'mac' })
  await ui.redraw()
  expect(await ui.find({ type: 'Button', key: 'pick:Yalnız peer [p1]' })).toBeUndefined()
  await ui.unmount()
})

test('two live peers with the same name pair with the two newest sessions', async ($, on) => {
  const two = outputWith([
    sessionOf('dd1', 'Çift', ACTIVE - 3600, null),
    sessionOf('dd2', 'Çift', ACTIVE, null),
    sessionOf('dd3', 'Çift', ACTIVE - 7200, null),
  ])
  const agents = {
    listing: '',
    sections: [
      {
        kind: 'peers',
        total: 2,
        rows: [
          { name: 'Çift', ref: 'a1', status: 'idle' },
          { name: 'Çift', ref: 'a2', status: 'running' },
        ],
      },
    ],
  }
  bulkWorld(on, agents, undefined, two)
  const ui = await openBulk($, on)

  // First peer (idle) pairs with the newest session (11:00), second (running) with 10:00.
  expect(await ui.find({ type: 'Text', text: /^mac · hesap bilinmiyor · son hareket 2026-11-23 11:00 · boşta$/ })).toBeDefined()
  expect(await ui.find({ type: 'Text', text: /^mac · hesap bilinmiyor · son hareket 2026-11-23 10:00 · çalışıyor$/ })).toBeDefined()
  expect(await peerButtons(ui)).toEqual(['☐ 1. Çift', '☐ 2. Çift'])
  // The oldest session has no peer and no handoff: not shown.
  expect(await ui.find({ type: 'Text', text: /devir notu olmayan kapalı 1 oturum/ })).toBeDefined()
  await ui.unmount()
})

test('a check box picks and unpicks, and the count follows', async ($, on) => {
  bulkWorld(on, AGENTS)
  const ui = await openBulk($, on)

  await ui.press({ key: 'pick:Kart akışı [k1]' })
  await ui.redraw()
  expect(await peerButtons(ui)).toContain('☑ 3. Kart akışı')
  expect(await ui.find({ type: 'Button', text: /\(1\)$/ })).toBeDefined()

  await ui.press({ key: 'pick:Kart akışı [k1]' })
  await ui.redraw()
  expect(await peerButtons(ui)).toContain('☐ 3. Kart akışı')
  expect(await ui.find({ type: 'Button', text: /\(0\)$/ })).toBeDefined()
  await ui.unmount()
})

test('"Tümünü seç" picks only the live rows and "Seçimi temizle" clears', async ($, on) => {
  bulkWorld(on, AGENTS)
  const ui = await openBulk($, on)

  await ui.press({ key: 'all' })
  await ui.redraw()
  const labels = await peerButtons(ui)
  expect(labels).toHaveLength(3)
  expect(labels.every(l => l?.startsWith('☑'))).toBe(true)
  // Three live rows, not the five rows shown.
  expect(await ui.find({ type: 'Button', text: /\(3\)$/ })).toBeDefined()

  await ui.press({ key: 'clear' })
  await ui.redraw()
  expect((await peerButtons(ui)).every(l => l?.startsWith('☐'))).toBe(true)
  await ui.unmount()
})

test('the send button is dim with nothing picked and not dim with one picked', async ($, on) => {
  bulkWorld(on, AGENTS)
  const ui = await openBulk($, on)

  expect((await ui.find({ type: 'Button', key: 'send' }))?.props.dimColor).toBe(true)
  expect((await ui.find({ type: 'Button', key: 'send' }))?.text).toBe('Seçilenler için devir notu yazdır (0)')

  await ui.press({ key: 'pick:Kart akışı [k1]' })
  await ui.redraw()
  const after = await ui.find({ type: 'Button', key: 'send' })
  expect(after?.props.dimColor).toBeFalsy()
  expect(after?.props.variant).toBe('primary')
  await ui.unmount()
})

test('the send button sends to "Name [ref]" with the marker and the name', async ($, on) => {
  const w = bulkWorld(on, AGENTS)
  const ui = await openBulk($, on)

  await ui.press({ key: 'pick:Kart akışı [k1]' })
  await ui.press({ key: 'pick:Yalnız peer [p1]' })
  await ui.redraw()
  await ui.press({ key: 'send' })
  await ui.redraw()

  // List order: the peer-only row is the newest, so it is first in the pane. Sends follow the
  // peers list order (ListAgents order).
  expect(w.sends.map(s => s.to)).toEqual(['Kart akışı [k1]', 'Yalnız peer [p1]'])
  expect(w.sends[0]!.text).toContain('[oturum:toplu-devir]')
  expect(w.sends[0]!.text).toContain('Kart akışı-handoff-')
  expect(w.sends[0]!.text).toContain('# Kart akışı — devir notu')
  expect(w.toasts.at(-1)).toBe('2 oturuma gönderildi')
  expect(await ui.findAll({ type: 'Text', text: /^devir isteği gönderildi \d{2}:\d{2} TR$/ })).toHaveLength(2)
  await ui.unmount()
})

test('a failed send records the reason and the toast counts both', async ($, on) => {
  const w = bulkWorld(on, AGENTS, to =>
    to.startsWith('Notsuz') ? { isDelivered: false, reason: 'recipient gone' } : { isDelivered: true },
  )
  const ui = await openBulk($, on)

  await ui.press({ key: 'pick:Kart akışı [k1]' })
  await ui.press({ key: 'pick:Notsuz oturum [n1]' })
  await ui.redraw()
  await ui.press({ key: 'send' })
  await ui.redraw()

  expect(w.sends).toHaveLength(2)
  expect(w.toasts.at(-1)).toBe('1 gönderildi, 1 gönderilemedi')
  expect(await ui.find({ type: 'Text', text: /^gönderilemedi: recipient gone$/ })).toBeDefined()
  await ui.unmount()
})

test('with nothing picked the send button sends nothing and says so', async ($, on) => {
  const w = bulkWorld(on, AGENTS)
  const ui = await openBulk($, on)

  await ui.press({ key: 'send' })
  expect(w.sends).toHaveLength(0)
  expect(w.toasts.at(-1)).toBe('Önce oturum seç')
  await ui.unmount()
})

test('the copy button puts name, folder and prompt of the picked sessions on the clipboard', async ($, on) => {
  const w = bulkWorld(on, AGENTS)
  const ui = await openBulk($, on)

  await ui.press({ key: 'pick:Kart akışı [k1]' })
  await ui.press({ key: 'pick:Notsuz oturum [n1]' })
  await ui.redraw()
  expect(await ui.find({ type: 'Button', text: 'Seçilenlerin bilgilerini kopyala (2)' })).toBeDefined()
  await ui.press({ key: 'copy-picked' })

  const text = w.copied.at(-1)!.text
  const blocks = text.split('\n\n')
  expect(blocks).toHaveLength(2)
  for (const block of blocks) {
    const lines = block.split('\n')
    expect(lines).toHaveLength(3)
    expect(lines[0]).toMatch(/^Oturum ismi: /)
    expect(lines[1]).toMatch(/^Klasör: /)
    expect(lines[2]).toMatch(/^Prompt: /)
  }
  expect(text).toContain('Oturum ismi: Kart akışı')
  expect(text).toContain('Oturum ismi: Notsuz oturum')
  expect(text).toContain("Prompt: devir notu henüz yok (notlar yazılınca Yenile'ye bas)")
  expect(w.toasts.at(-1)).toBe('Seçilenlerin bilgileri kopyalandı')
  await ui.unmount()
})

test('with nothing picked the copy button copies nothing, says so and is dim', async ($, on) => {
  const w = bulkWorld(on, AGENTS)
  const ui = await openBulk($, on)

  const button = await ui.find({ type: 'Button', text: 'Seçilenlerin bilgilerini kopyala (0)' })
  expect(button?.props.dimColor).toBe(true)
  await ui.press({ key: 'copy-picked' })
  expect(w.copied).toHaveLength(0)
  expect(w.toasts.at(-1)).toBe('Önce oturum seç')
  await ui.unmount()
})

test('Yenile runs the script and lists the live peers again', async ($, on) => {
  const w = bulkWorld(on, AGENTS)
  const ui = await openBulk($, on)
  expect(w.calls.agents).toBe(1)
  expect(w.runs.length).toBe(1)

  await ui.press({ key: 'refresh' })
  await ui.redraw()
  expect(w.calls.agents).toBe(2)
  expect(w.runs.length).toBe(2)
  await ui.unmount()
})

test('the list is sorted by last activity, not by handoff time', async ($, on) => {
  // A: newer handoff, older activity. B: older handoff, newer activity.
  const out = outputWith([
    sessionOf('sa', 'A işi', WRITTEN + 1100, WRITTEN + 1000),
    sessionOf('sb', 'B işi', WRITTEN + 5000, WRITTEN),
  ])
  bulkWorld(on, { listing: '', sections: [{ kind: 'peers', total: 1, rows: [{ name: 'Yalnız', ref: 'y1', status: 'idle' }] }] }, undefined, out)
  const ui = await openBulk($, on)

  // The peer-only row counts as the newest.
  expect((await headings(ui)).map(t => t?.split(' · ')[0])).toEqual(['B işi', 'A işi'])
  expect(await peerButtons(ui)).toEqual(['☐ 1. Yalnız'])
  expect(await ui.find({ type: 'Text', text: /^mac · hesap bilinmiyor · son hareket 2026-11-23 10:48 · kapalı$/ })).toBeDefined()

  await ui.select({ key: 'sort', value: 'handoff-old' })
  await ui.redraw()
  expect((await headings(ui)).map(t => t?.split(' · ')[0])).toEqual(['A işi', 'B işi'])
  await ui.unmount()
})

// Rows as the Desktop app's list_sessions prints them (only the fields the mod reads).
const ZETA = { title: 'Zeta işi', cwd: '/srv/zeta' }

test('an archived closed session is hidden by default and counted in the footer', async ($, on) => {
  world(on, [ok(OUTPUT)], archiveOf([{ ...ZETA, isArchived: true }]))
  const ui = await openBulk($, on)

  expect((await headings(ui)).map(t => t?.split(' · ')[0])).toEqual(['Kart akışı', 'bbbbbbbb'])
  expect((await ui.find({ type: 'Text', text: /^Gösterilen:/ }))?.text).toBe(
    'Gösterilen: 2 oturum · açık 0 · devir notu olmayan kapalı 1 oturum gösterilmedi · arşivlenen 1 gizli',
  )
  expect(await ui.find({ type: 'Button', key: 'archived:toggle' })).toBeDefined()
  expect((await ui.find({ type: 'Button', key: 'archived:toggle' }))?.text).toBe('☐ Arşivlenenleri göster')
  expect(await ui.findAll({ type: 'Text', text: /^Arşiv listesi okunamadı/ })).toHaveLength(0)
  await ui.unmount()
})

test('the toggle shows the archived session with "arşivlendi"', async ($, on) => {
  world(on, [ok(OUTPUT)], archiveOf([{ ...ZETA, isArchived: true }]))
  const ui = await openBulk($, on)

  await ui.press({ key: 'archived:toggle' })
  await ui.redraw()
  expect((await headings(ui)).map(t => t?.split(' · ')[0])).toEqual(['Zeta işi', 'Kart akışı', 'bbbbbbbb'])
  expect(await ui.find({ type: 'Text', text: /^ubuntu · personal · son hareket 2026-11-23 12:50 · arşivlendi$/ })).toBeDefined()
  expect((await ui.find({ type: 'Text', text: /^Gösterilen:/ }))?.text).toBe(
    'Gösterilen: 3 oturum · açık 0 · devir notu olmayan kapalı 1 oturum gösterilmedi',
  )
  expect((await ui.find({ type: 'Button', key: 'archived:toggle' }))?.text).toBe('☑ Arşivlenenleri göster')

  await ui.press({ key: 'archived:toggle' })
  await ui.redraw()
  expect((await headings(ui)).length).toBe(2)
  await ui.unmount()
})

test('the same title and folder with one archived and one not archived stays visible', async ($, on) => {
  world(on, [ok(OUTPUT)], archiveOf([
    { ...ZETA, isArchived: true },
    { ...ZETA, isArchived: false },
  ]))
  const ui = await openBulk($, on)

  expect((await headings(ui)).length).toBe(3)
  expect(await ui.find({ type: 'Text', text: / · kapalı$/ })).toBeDefined()
  expect(await ui.findAll({ type: 'Text', text: / · arşivlendi$/ })).toHaveLength(0)
  expect(await ui.find({ type: 'Text', text: /arşivlenen \d+ gizli/ })).toBeUndefined()
  await ui.unmount()
})

test('a failed archive call shows everything and a caption', async ($, on) => {
  world(on, [ok(OUTPUT)], () => ({ deny: 'server not connected' }))
  const ui = await openBulk($, on)

  expect((await headings(ui)).length).toBe(3)
  expect(
    (await ui.find({ type: 'Text', text: /^Arşiv listesi okunamadı: / }))?.text,
  ).toMatch(/Arşivlenenler de görünüyor\.$/)
  await ui.unmount()
})

test('an archive answer that is not a JSON array shows everything and a caption', async ($, on) => {
  world(on, [ok(OUTPUT)], () => ({ value: { content: [{ type: 'text', text: 'nope' }], isError: false } }))
  const ui = await openBulk($, on)

  expect((await headings(ui)).length).toBe(3)
  expect((await ui.find({ type: 'Text', text: /^Arşiv listesi okunamadı: / }))?.text).toBe(
    'Arşiv listesi okunamadı: cevap JSON liste değil. Arşivlenenler de görünüyor.',
  )
  await ui.unmount()
})

test('a live peer paired with an archived session stays visible', async ($, on) => {
  bulkWorld(on, AGENTS, undefined, OUTPUT, archiveOf([{ title: 'Kart akışı', cwd: '/w/cards', isArchived: true }]))
  const ui = await openBulk($, on)

  expect(await peerButtons(ui)).toContain('☐ 3. Kart akışı')
  expect(await ui.find({ type: 'Text', text: /^mac · work · son hareket 2026-11-23 11:00 · boşta$/ })).toBeDefined()
  expect(await ui.find({ type: 'Text', text: /arşivlenen \d+ gizli/ })).toBeUndefined()
  await ui.unmount()
})

test('the pane shows the last usage reading of each account under the refresh line', async ($, on) => {
  const usage = [
    { orgId: 'o1', account: 'Acme2', fivePct: 15, fiveReset: NOW / 1000 + 3600, weekPct: 90,
      weekReset: NOW / 1000 + 86400, measuredAt: NOW / 1000 - 600 },
    { orgId: 'o2', account: null, fivePct: 29, fiveReset: NOW / 1000 - 60, weekPct: null,
      weekReset: null, measuredAt: null },
  ]
  world(on, [ok({ ...OUTPUT, usage })])
  await $.session.start({ cwd: '/', surface: 'desktop', isInteractive: true })
  await $.command.run(RUN)
  const ui = await $.ui.mount({ ...PANE, surface: 'desktop' })

  expect((await ui.find({ type: 'Text', text: /^Acme2 · / }))?.text).toBe(
    'Acme2 · 5-hour limit 15% (13:05) · Weekly 90% (2026-11-24 12:05) · ölçüm 2026-11-23 11:55',
  )
  expect((await ui.find({ type: 'Text', text: /^hesap bilinmiyor · 5-hour/ }))?.text).toBe(
    'hesap bilinmiyor · 5-hour limit sıfırlandı · Weekly -',
  )
  await ui.unmount()
})
