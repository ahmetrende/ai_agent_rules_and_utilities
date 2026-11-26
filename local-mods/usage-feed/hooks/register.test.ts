import { expect, mock, test } from 'claude-code/testing'
import type { On } from 'claude-code'

const ORG = '11111111-aaaa-bbbb-cccc-000000000001'
const ACC = '22222222-aaaa-bbbb-cccc-000000000002'
const ACCT = `${ORG}_${ACC}`
const WINDOWS = [
  { kind: 'five_hour', percentUsed: 22.5, resetsAt: '2026-10-27T10:40:00.061Z' },
  { kind: 'seven_day', percentUsed: 91, resetsAt: '2026-10-31T20:00:00Z' },
]
const CONTEXT = { tokens: 90000, window: 1000000, percent: 9 }
const DIR = '/home/u/.claude/usage-feed'
const FEED = `${DIR}/feed-${ACCT}.json`
const HIST = `${DIR}/history-${ACCT}.jsonl`

// The engine beneath the mod: env, store, clock, and the calls the mod makes.
// `files` seeds the disk: fs.read answers from it and from the files written so far, and
// rejects for a missing path. `context` is what session.usage() answers as the context.
// `writes` holds the feed and history writes; the context files are in `ctx`.
const world = (
  on: On,
  env: Record<string, string>,
  store?: Record<string, unknown>,
  files?: Record<string, string>,
  context: typeof CONTEXT = CONTEXT,
) => {
  const writes: { path: string; text: string }[] = []
  const ctx: { path: string; text: string }[] = []
  const disk = new Map<string, string>(Object.entries(files ?? {}))
  const status: (string | undefined)[] = []
  const logs: { text: string; to: string }[] = []
  // The store in memory, readable by the test (the test's $ has no store noun).
  const kept = new Map<string, unknown>(Object.entries(store ?? {}))
  mock.env(on, env)
  on('store.get', (_, e) => ({ value: kept.get(e.key) }))
  on('store.set', (_, e) => (kept.set(e.key, JSON.parse(JSON.stringify(e.value))), { value: undefined }))
  const clock = mock.clock(on, { now: Date.parse('2026-10-27T09:45:00Z') })
  on('session.id', () => ({ value: 'sid-test' }))
  on('session.surfaces', () => ({ value: ['desktop'] as const }))
  on('session.usage', () => ({
    value: { startedAt: 0, context, rateLimits: WINDOWS },
  }))
  on('session.start', (_, e) => ({ cwd: e.cwd }))
  on('session.measure', (_, e) => ({ changed: e.changed }))
  on('tool.call', () => ({ result: {} }))
  on('fs.read', (_, e) => {
    const text = disk.get(e.path)
    if (text === undefined) throw new Error(`ENOENT: ${e.path}`)
    return { value: text }
  })
  on('fs.write', (_, e) => {
    disk.set(e.path, e.text)
    ;(e.path.includes('/context-') ? ctx : writes).push({ path: e.path, text: e.text })
    return { value: undefined }
  })
  on('ui.status', (_, e) => (status.push(e.text), { value: undefined }))
  on('ui.log', (_, e) => (logs.push({ text: e.text, to: e.to }), { value: undefined }))
  return { writes, ctx, disk, status, logs, kept, clock }
}

test('a measurement is written in the usage.json shape, per account', async ($, on) => {
  const w = world(on, {
    HOME: '/home/u',
    CLAUDE_CODE_ORGANIZATION_UUID: ORG,
    CLAUDE_CODE_ACCOUNT_UUID: ACC,
  })
  await $.session.measure({ context: CONTEXT, rateLimits: WINDOWS, changed: ['rateLimits'] })

  const feed = w.writes.find(x => x.path === `/home/u/.claude/usage-feed/feed-${ACCT}.json`)
  expect(feed).toBeDefined()
  const r = JSON.parse(feed!.text)
  expect(r.five).toEqual({ pct: 22, reset: Date.parse('2026-10-27T10:40:00Z') / 1000 })
  expect(r.week).toEqual({ pct: 91, reset: Date.parse('2026-10-31T20:00:00Z') / 1000 })
  expect(r.ts).toBe(Date.parse('2026-10-27T09:45:00Z') / 1000)
  expect(r.by).toBe('sid-test')
  expect(r.source).toBe('mod')
  expect(r.surfaces).toEqual(['desktop'])
  const hist = w.writes.find(x => x.path === `/home/u/.claude/usage-feed/history-${ACCT}.jsonl`)
  expect(hist!.text.trim().split('\n').length).toBe(1)
  expect(w.status.at(-1)).toBe('plan: 5-hour limit 22.5% (04:04), Weekly 91%')
  expect(w.logs.some(l => l.to === 'debug' && /usage-feed \(measure\)/.test(l.text))).toBe(true)
  expect(w.logs.filter(l => l.to === 'transcript').length).toBe(0)
})

test('a measurement where only the context moved logs no transcript line', async ($, on) => {
  const w = world(on, { HOME: '/home/u', CLAUDE_CODE_ORGANIZATION_UUID: ORG, CLAUDE_CODE_ACCOUNT_UUID: ACC })
  await $.session.measure({ context: CONTEXT, rateLimits: WINDOWS, changed: ['context'] })
  expect(w.writes.length).toBe(2)
  expect(w.logs.filter(l => l.to === 'transcript').length).toBe(0)
})

test('no reading yet: nothing is written', async ($, on) => {
  const w = world(on, { HOME: '/home/u', CLAUDE_CODE_ORGANIZATION_UUID: ORG, CLAUDE_CODE_ACCOUNT_UUID: ACC })
  await $.session.measure({ context: CONTEXT, rateLimits: [], changed: ['context'] })
  expect(w.writes.length).toBe(0)
  expect(w.kept.get('last')).toBeUndefined()
})

test('without an account id no file is written, the store still has it', async ($, on) => {
  const w = world(on, { HOME: '/home/u', CLAUDE_CODE_ORGANIZATION_UUID: ORG })
  await $.session.measure({ context: CONTEXT, rateLimits: WINDOWS, changed: ['rateLimits'] })
  expect(w.writes.length).toBe(0)
  expect(w.kept.get('last')).toMatchObject({ five: { pct: 22 } })
})

test('a malformed account id is not used in a path', async ($, on) => {
  const w = world(on, { HOME: '/home/u', CLAUDE_CODE_ORGANIZATION_UUID: '../../etc', CLAUDE_CODE_ACCOUNT_UUID: ACC })
  await $.session.measure({ context: CONTEXT, rateLimits: WINDOWS, changed: ['rateLimits'] })
  expect(w.writes.length).toBe(0)
})

test('CLAUDE_CONFIG_DIR wins over HOME', async ($, on) => {
  const w = world(on, {
    HOME: '/home/u',
    CLAUDE_CONFIG_DIR: '/cfg',
    CLAUDE_CODE_ORGANIZATION_UUID: ORG,
    CLAUDE_CODE_ACCOUNT_UUID: ACC,
  })
  await $.session.measure({ context: CONTEXT, rateLimits: WINDOWS, changed: ['rateLimits'] })
  expect(w.writes[0]!.path).toBe(`/cfg/usage-feed/feed-${ACCT}.json`)
})

test('a reload (session.start) writes nothing: the figures may be old', async ($, on) => {
  const w = world(on, { HOME: '/home/u', CLAUDE_CODE_ORGANIZATION_UUID: ORG, CLAUDE_CODE_ACCOUNT_UUID: ACC })
  await $.session.start({ cwd: '/', surface: 'desktop', isInteractive: true })
  expect(w.writes.length).toBe(0)
})

// Changed with B07: the history file is read back from disk, so the old lines are seeded
// as a file (the store seed stays for the store check).
test('the history keeps the last 200 readings', async ($, on) => {
  const old = Array.from({ length: 200 }, (_, i) => ({ ts: i }))
  const w = world(
    on,
    { HOME: '/home/u', CLAUDE_CODE_ORGANIZATION_UUID: ORG, CLAUDE_CODE_ACCOUNT_UUID: ACC },
    { history: old },
    { [HIST]: old.map(r => JSON.stringify(r)).join('\n') + '\n' },
  )
  await $.session.measure({ context: CONTEXT, rateLimits: WINDOWS, changed: ['rateLimits'] })
  const h = w.kept.get('history') as { ts: number }[]
  expect(h.length).toBe(200)
  expect(h[0]!.ts).toBe(1)
  const hist = w.writes.find(x => x.path.includes('history-'))
  const lines = hist!.text.trim().split('\n')
  expect(lines.length).toBe(200)
  expect(JSON.parse(lines[0]!).ts).toBe(1)
})

test('a failing write does not break the measurement chain', async ($, on) => {
  mock.env(on, { HOME: '/home/u', CLAUDE_CODE_ORGANIZATION_UUID: ORG, CLAUDE_CODE_ACCOUNT_UUID: ACC })
  mock.store(on)
  mock.clock(on, { now: 0 })
  on('session.id', () => ({ value: 'sid-test' }))
  on('session.surfaces', () => ({ value: [] }))
  on('session.measure', (_, e) => ({ changed: e.changed }))
  on('fs.write', () => {
    throw new Error('EACCES')
  })
  on('ui.status', () => ({ value: undefined }))
  on('ui.log', () => ({ value: undefined }))
  const r = await $.session.measure({ context: CONTEXT, rateLimits: WINDOWS, changed: ['rateLimits'] })
  expect(r.changed).toEqual(['rateLimits'])
})

test('a tool call rewrites the reading at most once per 60 seconds', async ($, on) => {
  const env = { HOME: '/home/u', CLAUDE_CODE_ORGANIZATION_UUID: ORG, CLAUDE_CODE_ACCOUNT_UUID: ACC }
  const writes: string[] = []
  const kept = new Map<string, unknown>()
  mock.env(on, env)
  const clock = mock.clock(on, { now: 1_000_000_000_000 })
  on('store.get', (_, e) => ({ value: kept.get(e.key) }))
  on('store.set', (_, e) => (kept.set(e.key, e.value), { value: undefined }))
  on('session.id', () => ({ value: 'sid-test' }))
  on('session.surfaces', () => ({ value: [] }))
  on('session.usage', () => ({ value: { startedAt: 0, context: CONTEXT, rateLimits: WINDOWS } }))
  on('session.measure', (_, e) => ({ changed: e.changed }))
  on('fs.write', (_, e) => (e.path.includes('/context-') || writes.push(e.path), { value: undefined }))
  on('ui.status', () => ({ value: undefined }))
  on('ui.log', () => ({ value: undefined }))
  on('tool.call', () => ({ result: {} }))

  await $.session.measure({ context: CONTEXT, rateLimits: WINDOWS, changed: ['rateLimits'] })
  expect(writes.length).toBe(2)
  await clock.advance(30_000)
  await $.tool.call({ tool: 'Bash', command: 'ls' })
  expect(writes.length).toBe(2)
  await clock.advance(31_000)
  const ran = await $.tool.call({ tool: 'Bash', command: 'ls' })
  expect(ran).toBeDefined()
  expect(writes.length).toBe(4)
  expect((kept.get('last') as { event: string }).event).toBe('tick')
})

test('a failing tick does not change the tool result', async ($, on) => {
  mock.env(on, { HOME: '/home/u', CLAUDE_CODE_ORGANIZATION_UUID: ORG, CLAUDE_CODE_ACCOUNT_UUID: ACC })
  mock.clock(on, { now: 1_000_000_000_000 })
  on('session.usage', () => {
    throw new Error('no usage')
  })
  on('ui.log', () => ({ value: undefined }))
  on('tool.call', () => ({ result: { text: 'ok' } }))
  const ran = await $.tool.call({ tool: 'Bash', command: 'ls' })
  expect(ran).toMatchObject({ result: { text: 'ok' } })
})

// The world for the heartbeat tests: a clock the test moves, and the engine's turn.start.
const heartbeatWorld = (on: On) => {
  const writes: string[] = []
  const kept = new Map<string, unknown>()
  mock.env(on, { HOME: '/home/u', CLAUDE_CODE_ORGANIZATION_UUID: ORG, CLAUDE_CODE_ACCOUNT_UUID: ACC })
  const clock = mock.clock(on, { now: 2_000_000_000_000 })
  on('store.get', (_, e) => ({ value: kept.get(e.key) }))
  on('store.set', (_, e) => (kept.set(e.key, e.value), { value: undefined }))
  on('session.id', () => ({ value: 'sid-test' }))
  on('session.surfaces', () => ({ value: [] }))
  on('session.usage', () => ({ value: { startedAt: 0, context: CONTEXT, rateLimits: WINDOWS } }))
  on('session.measure', (_, e) => ({ changed: e.changed }))
  on('turn.start', (_, e) => ({ turnId: e.turnId }))
  on('fs.write', (_, e) => (e.path.includes('/context-') || writes.push(e.path), { value: undefined }))
  on('ui.status', () => ({ value: undefined }))
  on('ui.log', () => ({ value: undefined }))
  on('tool.call', () => ({ result: {} }))
  return { writes, kept, clock }
}

test('a new main turn stops the heartbeat until the next measurement', async ($, on) => {
  const w = heartbeatWorld(on)
  await $.session.measure({ context: CONTEXT, rateLimits: WINDOWS, changed: ['rateLimits'] })
  expect(w.writes.length).toBe(2)
  await w.clock.advance(61_000)
  await $.turn.start({ text: 'hi', turnId: 't1' })
  await $.tool.call({ tool: 'Bash', command: 'ls' })
  expect(w.writes.length).toBe(2)
  await $.session.measure({ context: CONTEXT, rateLimits: WINDOWS, changed: ['rateLimits'] })
  expect(w.writes.length).toBe(4)
  await w.clock.advance(61_000)
  await $.tool.call({ tool: 'Bash', command: 'ls' })
  expect(w.writes.length).toBe(6)
  expect((w.kept.get('last') as { event: string }).event).toBe('tick')
})

test('a subagent turn start keeps the heartbeat', async ($, on) => {
  const w = heartbeatWorld(on)
  await $.session.measure({ context: CONTEXT, rateLimits: WINDOWS, changed: ['rateLimits'] })
  await $.turn.start({ text: 'task', turnId: 't2', agentId: 'a1' })
  await w.clock.advance(61_000)
  await $.tool.call({ tool: 'Bash', command: 'ls' })
  expect(w.writes.length).toBe(4)
})

// Status line time (2026-11-08): the part of the 5-hour window gone by, kept current by a timer.
const ENV = { HOME: '/home/u', CLAUDE_CODE_ORGANIZATION_UUID: ORG, CLAUDE_CODE_ACCOUNT_UUID: ACC }
const at = (iso: string) => Date.parse(iso)

test('under an hour into the window the hours read 00', async ($, on) => {
  const w = world(on, ENV)
  const ws = [{ kind: 'five_hour', percentUsed: 10, resetsAt: '2026-10-27T14:05:00Z' }]
  await $.session.measure({ context: CONTEXT, rateLimits: ws, changed: ['rateLimits'] })
  expect(w.status.at(-1)).toBe('plan: 5-hour limit 10% (00:40)')
})

test('past the reset time the status says 5-hour limit reset', async ($, on) => {
  const w = world(on, ENV)
  const ws = [
    { kind: 'five_hour', percentUsed: 80, resetsAt: '2026-10-27T09:44:59Z' },
    { kind: 'seven_day', percentUsed: 50, resetsAt: '2026-10-31T20:00:00Z' },
  ]
  await $.session.measure({ context: CONTEXT, rateLimits: ws, changed: ['rateLimits'] })
  expect(w.status.at(-1)).toBe('plan: 5-hour limit reset, Weekly 50%')
})

test('a five_hour window without a reset time shows no time', async ($, on) => {
  const w = world(on, ENV)
  const ws = [{ kind: 'five_hour', percentUsed: 7 }, { kind: 'seven_day', percentUsed: 3, resetsAt: 'x' }]
  await $.session.measure({ context: CONTEXT, rateLimits: ws, changed: ['rateLimits'] })
  expect(w.status.at(-1)).toBe('plan: 5-hour limit 7%, Weekly 3%')
})

test('the debug line keeps the percentages alone, and nothing goes to the transcript', async ($, on) => {
  const w = world(on, ENV)
  await $.session.measure({ context: CONTEXT, rateLimits: WINDOWS, changed: ['rateLimits'] })
  expect(w.logs.find(l => /usage-feed \(measure\)/.test(l.text))!).toEqual({
    text: 'usage-feed (measure): five_hour 22.5%, seven_day 91%',
    to: 'debug',
  })
  expect(w.logs.filter(l => l.to === 'transcript').length).toBe(0)
})

test('the status line uses the names of the usage card', async ($, on) => {
  const w = world(on, ENV)
  const ws = [
    { kind: 'five_hour', percentUsed: 7 },
    { kind: 'seven_day', percentUsed: 3 },
    { kind: 'seven_day_opus', percentUsed: 1 },
  ]
  await $.session.measure({ context: CONTEXT, rateLimits: ws, changed: ['rateLimits'] })
  expect(w.status.at(-1)).toBe('plan: 5-hour limit 7%, Weekly 3%, Weekly · Opus 1%')
})

test('a timer keeps the time current between readings and writes no file', async ($, on) => {
  const w = world(on, ENV)
  const clock = w.clock
  await clock.set(at('2026-10-27T09:45:00Z'))
  await $.session.start({ cwd: '/', surface: 'desktop', isInteractive: false })
  await $.session.measure({ context: CONTEXT, rateLimits: WINDOWS, changed: ['rateLimits'] })
  expect(w.status.at(-1)).toBe('plan: 5-hour limit 22.5% (04:04), Weekly 91%')
  expect(w.writes.length).toBe(2)
  await clock.advance(60_000)
  expect(w.status.at(-1)).toBe('plan: 5-hour limit 22.5% (04:05), Weekly 91%')
  await clock.advance(30 * 60_000)
  expect(w.status.at(-1)).toBe('plan: 5-hour limit 22.5% (04:35), Weekly 91%')
  await clock.set(at('2026-10-27T10:41:30Z'))
  expect(w.status.at(-1)).toBe('plan: 5-hour limit reset, Weekly 91%')
  expect(w.writes.length).toBe(2)
})

test('the timer draws only when the text changed', async ($, on) => {
  const w = world(on, ENV)
  const clock = w.clock
  await clock.set(at('2026-10-27T09:45:10Z'))
  await $.session.start({ cwd: '/', surface: 'desktop', isInteractive: false })
  await $.session.measure({ context: CONTEXT, rateLimits: WINDOWS, changed: ['rateLimits'] })
  await $.session.measure({ context: CONTEXT, rateLimits: WINDOWS, changed: ['context'] })
  expect(w.status.length).toBe(1)
  await clock.set(at('2026-10-27T10:41:30Z'))
  await clock.advance(5 * 60_000)
  expect(w.status.filter(t => t === 'plan: 5-hour limit reset, Weekly 91%').length).toBe(1)
})

test('before the first reading the timer draws nothing', async ($, on) => {
  const w = world(on, ENV)
  const clock = w.clock
  await clock.set(at('2026-10-27T09:45:00Z'))
  await $.session.start({ cwd: '/', surface: 'desktop', isInteractive: false })
  await clock.advance(3 * 60_000)
  expect(w.status.length).toBe(0)
})

test("a reload shows this session's last reading again, with the time now", async ($, on) => {
  const last = { ts: 1, by: 'sid-test', source: 'mod', windows: WINDOWS }
  const w = world(on, ENV, { last })
  await w.clock.set(at('2026-10-27T10:00:00Z'))
  await $.session.start({ cwd: '/', surface: 'desktop', isInteractive: false })
  expect(w.status.at(-1)).toBe('plan: 5-hour limit 22.5% (04:19), Weekly 91%')
  expect(w.writes.length).toBe(0)
})

test("a new session does not show another session's reading", async ($, on) => {
  const last = { ts: 1, by: 'sid-other', source: 'mod', windows: WINDOWS }
  const w = world(on, ENV, { last })
  const clock = w.clock
  await clock.set(at('2026-10-27T10:00:00Z'))
  await $.session.start({ cwd: '/', surface: 'desktop', isInteractive: false })
  await clock.advance(2 * 60_000)
  expect(w.status.length).toBe(0)
})

// B07: a stale reading must not overwrite a newer one; B16: the context file.
const NOW_S = Date.parse('2026-10-27T09:45:00Z') / 1000
const seedFeed = (windows: unknown[], mts?: number) =>
  JSON.stringify({ ts: NOW_S - 5, mts, by: 'sid-other', source: 'mod', windows }) + '\n'
const feedOf = (w: { disk: Map<string, string> }) => JSON.parse(w.disk.get(FEED)!)

test('an older lower reading with the same resetsAt does not lower the percent', async ($, on) => {
  const old = seedFeed(
    [
      { kind: 'five_hour', percentUsed: 97, resetsAt: WINDOWS[0]!.resetsAt },
      { kind: 'seven_day', percentUsed: 80, resetsAt: WINDOWS[1]!.resetsAt },
      { kind: 'seven_day_opus', percentUsed: 12, resetsAt: WINDOWS[1]!.resetsAt },
    ],
    NOW_S + 300,
  )
  const w = world(on, ENV, undefined, { [FEED]: old })
  await $.session.measure({ context: CONTEXT, rateLimits: WINDOWS, changed: ['rateLimits'] })
  const r = feedOf(w)
  expect(r.five.pct).toBe(97)
  expect(r.windows[0].percentUsed).toBe(97)
  // The incoming seven_day is higher than the old one: it wins.
  expect(r.week.pct).toBe(91)
  // A kind that only the old reading has is kept.
  expect(r.windows.map((x: { kind: string }) => x.kind)).toEqual(['five_hour', 'seven_day', 'seven_day_opus'])
  // Figures came from the old reading and its mts is later: mts is the later one.
  expect(r.mts).toBe(NOW_S + 300)
  expect(r.ts).toBe(NOW_S)
})

test('a reset time that differs by milliseconds is the same window', async ($, on) => {
  const old = seedFeed([{ kind: 'five_hour', percentUsed: 97, resetsAt: '2026-10-27T10:40:00.521Z' }], NOW_S - 100)
  const w = world(on, ENV, undefined, { [FEED]: old })
  await $.session.measure({ context: CONTEXT, rateLimits: WINDOWS, changed: ['rateLimits'] })
  const r = feedOf(w)
  // WINDOWS[0] resets at 10:40:00.061Z with 22.5 %: the old 97 % stays.
  expect(r.five.pct).toBe(97)
})

test('a higher new reading wins although its reset time is a few milliseconds earlier', async ($, on) => {
  const old = seedFeed([{ kind: 'five_hour', percentUsed: 10, resetsAt: '2026-10-27T10:40:00.900Z' }], NOW_S - 100)
  const w = world(on, ENV, undefined, { [FEED]: old })
  await $.session.measure({ context: CONTEXT, rateLimits: WINDOWS, changed: ['rateLimits'] })
  const r = feedOf(w)
  expect(r.five.pct).toBe(22)
})

test('a later resetsAt in the new reading replaces the old window', async ($, on) => {
  const old = seedFeed([{ kind: 'five_hour', percentUsed: 97, resetsAt: '2026-10-27T05:40:00Z' }], NOW_S - 100)
  const w = world(on, ENV, undefined, { [FEED]: old })
  await $.session.measure({ context: CONTEXT, rateLimits: WINDOWS, changed: ['rateLimits'] })
  const r = feedOf(w)
  expect(r.five.pct).toBe(22)
  expect(r.five.reset).toBe(Date.parse('2026-10-27T10:40:00Z') / 1000)
  expect(r.mts).toBe(NOW_S)
})

test('an old reading with a later resetsAt keeps its window', async ($, on) => {
  const old = seedFeed([{ kind: 'five_hour', percentUsed: 5, resetsAt: '2026-10-27T15:40:00Z' }], NOW_S + 10)
  const w = world(on, ENV, undefined, { [FEED]: old })
  await $.session.measure({ context: CONTEXT, rateLimits: WINDOWS, changed: ['rateLimits'] })
  const r = feedOf(w)
  expect(r.five).toEqual({ pct: 5, reset: Date.parse('2026-10-27T15:40:00Z') / 1000 })
  expect(r.week.pct).toBe(91)
  expect(r.mts).toBe(NOW_S + 10)
})

test('the history keeps the lines another session wrote, and skips bad lines', async ($, on) => {
  const lines = [JSON.stringify({ ts: 1, by: 'sid-other' }), 'not json', JSON.stringify({ ts: 2, by: 'sid-other' })]
  const w = world(on, ENV, undefined, { [HIST]: lines.join('\n') + '\n' })
  await $.session.measure({ context: CONTEXT, rateLimits: WINDOWS, changed: ['rateLimits'] })
  const out = w.disk.get(HIST)!.trim().split('\n').map(l => JSON.parse(l))
  expect(out.map(r => r.ts)).toEqual([1, 2, NOW_S])
  expect(out[0].by).toBe('sid-other')
  expect(out[2].by).toBe('sid-test')
})

test('mts is the measure time on a measure and the last measure time on a tick', async ($, on) => {
  const w = world(on, ENV)
  await $.session.measure({ context: CONTEXT, rateLimits: WINDOWS, changed: ['rateLimits'] })
  expect(feedOf(w).mts).toBe(NOW_S)
  expect(feedOf(w).ts).toBe(NOW_S)
  await w.clock.advance(61_000)
  await $.tool.call({ tool: 'Bash', command: 'ls' })
  const r = feedOf(w)
  expect(r.event).toBe('tick')
  expect(r.ts).toBe(NOW_S + 61)
  expect(r.mts).toBe(NOW_S)
})

test('the context file holds the window of the session', async ($, on) => {
  const w = world(on, ENV)
  await $.session.measure({ context: CONTEXT, rateLimits: WINDOWS, changed: ['rateLimits'] })
  expect(w.ctx.length).toBe(1)
  expect(w.ctx[0]!.path).toBe(`${DIR}/context-sid-test.json`)
  expect(JSON.parse(w.ctx[0]!.text)).toEqual({
    ts: NOW_S,
    by: 'sid-test',
    window: 1000000,
    tokens: 90000,
    percent: 9,
  })
})

test('the context file has null tokens and percent before the first response', async ($, on) => {
  const w = world(on, ENV, undefined, undefined, { window: 200000 } as typeof CONTEXT)
  await $.session.measure({ context: CONTEXT, rateLimits: WINDOWS, changed: ['rateLimits'] })
  expect(JSON.parse(w.ctx[0]!.text)).toMatchObject({ window: 200000, tokens: null, percent: null })
})

test('no context file when the window is missing', async ($, on) => {
  const w = world(on, ENV, undefined, undefined, { tokens: 5 } as unknown as typeof CONTEXT)
  await $.session.measure({ context: CONTEXT, rateLimits: WINDOWS, changed: ['rateLimits'] })
  expect(w.ctx.length).toBe(0)
  expect(w.writes.length).toBe(2)
})

test('invalid JSON in the existing feed file is ignored', async ($, on) => {
  const w = world(on, ENV, undefined, { [FEED]: '{"windows": [' })
  await $.session.measure({ context: CONTEXT, rateLimits: WINDOWS, changed: ['rateLimits'] })
  const r = feedOf(w)
  expect(r.five.pct).toBe(22)
  expect(r.mts).toBe(NOW_S)
})
