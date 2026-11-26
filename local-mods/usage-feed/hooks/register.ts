import type { EngineInterface, Register, Timer } from 'claude-code'

// G04 trial. The engine pushes the plan usage to session.measure after each main-thread
// turn and when a rate-limit window moves a whole point. This mod writes it where a
// command hook can read it, in the shape of usage-limit.sh's own usage.json:
//   <config>/usage-feed/feed-<org>_<account>.json      the latest reading
//   <config>/usage-feed/history-<org>_<account>.jsonl  the last HISTORY_MAX readings
// It also keeps both in $.store ("last", "history") and logs a debug line when
// a window moved. It changes no hook, no setting and no tool call.
//
// Two sessions of one account write the same feed file. Before it writes, the mod reads the
// file and merges per window kind: inside the same window a percent never goes down, and a
// later resetsAt wins. "ts" is the time of the write (the heartbeat); "mts" is the time the
// figures were measured. The history file is read back from disk, so it keeps the readings
// of all sessions.
//
// B16: each write also puts <config>/usage-feed/context-<session id>.json with the context
// window size of the session, which only the engine knows (for hooks/context-pressure.sh).
//
// session.measure fires at the first reading, at the end of a main-thread turn and when a
// window moves a whole point, not after every API response (measured: 2 events in a
// 30-second turn with 4 responses). So a long tool loop leaves the file's ts old although
// the figures are current. After a tool call the mod writes the reading again when the
// last write is HEARTBEAT_S or more ago: a hook can then read an old ts as "no mod here".
//
// $.session.usage() answers the figures of the session's last API response. At the start
// of a turn after an idle time they are old, and the first tool calls of the turn run
// before the new response's figures are in (measured 2026-10-27: a heartbeat wrote 13 %
// two seconds before session.measure brought 17 %, while another session had written
// 16 %). So the heartbeat writes only after a session.measure in the current turn, and a
// reload writes nothing: the figures are trusted again at the next session.measure.
//
// Status line (2026-11-08): "plan: 5-hour limit 6% (02:47), Weekly 45%". The time in
// brackets (hours:minutes) is how much of the 5-hour window has gone by: the window ends at resetsAt, so
// it began FIVE_HOUR_S before that. A timer started at session.start draws the line again
// every REFRESH_MS from the last reading of this module, so the time stays current between
// readings; the percentages change only with a reading. After resetsAt the line says
// "5-hour limit reset" until the next reading. A reload shows the session's own last reading
// again (from $.store, written by this session), and writes no file.

const ID = /^[A-Za-z0-9-]{8,64}$/
const SESSION_ID = /^[A-Za-z0-9_-]{1,128}$/
const HISTORY_MAX = 200
const HEARTBEAT_S = 60
const FIVE_HOUR_S = 5 * 3600
const REFRESH_MS = 60_000

// Time of the last write; a reload starts it over, which only means one early write.
let lastWrite = 0
// Time of this module's last session.measure: the mts of a heartbeat reading.
let lastMeasure = 0
// True once a session.measure came in the current main turn; a reload starts it false.
let isFresh = false
// The windows of the last reading this module showed, and the status text it drew last.
let shown: readonly Window[] = []
let lastText = ''
// The refresh timer of this module; a reload drops it with the old module.
let timer: Timer | undefined

type Window = { kind: string; percentUsed: number; resetsAt?: string }
type Reading = {
  ts: number
  mts: number
  by: string
  source: 'mod'
  event: string
  five?: { pct: number; reset: number }
  week?: { pct: number; reset: number }
  windows: Window[]
  context?: { percent?: number | null }
  changed: string[]
  surfaces: string[]
}

// Two reset times this close belong to the same window.
const SAME_WINDOW_S = 300

const epoch = (iso?: string): number => {
  if (typeof iso !== 'string') return 0
  const ms = Date.parse(iso)
  return Number.isFinite(ms) ? Math.floor(ms / 1000) : 0
}

// usage-limit.sh compares whole numbers: 22.5 % counts as 22 %, as get_usage reports it.
const whole = (n: unknown): number =>
  typeof n === 'number' && Number.isFinite(n) ? Math.floor(n) : 0

const pick = (ws: readonly Window[], kind: string) => {
  const w = ws.find(x => x.kind === kind)
  return w ? { pct: whole(w.percentUsed), reset: epoch(w.resetsAt) } : undefined
}

// 3 h 5 min -> "03:05"; 42 min -> "00:42". Whole minutes, rounded down.
const span = (s: number): string => {
  const m = Math.floor(Math.max(0, s) / 60)
  const two = (n: number) => String(n).padStart(2, '0')
  return `${two(Math.floor(m / 60))}:${two(m % 60)}`
}

// One window as the status line shows it, at the time nowMs.
// The names the app's usage card uses (2026-11-24): "5-hour limit", "Weekly". A weekly
// window of one model, for example seven_day_opus, reads "Weekly · Opus".
const windowName = (kind: string): string => {
  if (kind === 'five_hour') return '5-hour limit'
  if (kind === 'seven_day') return 'Weekly'
  const model = /^seven_day_(.+)$/.exec(kind)
  if (model) return `Weekly · ${model[1]!.charAt(0).toUpperCase()}${model[1]!.slice(1)}`
  return kind
}

const label = (w: Window, nowMs: number): string => {
  const pct = `${windowName(w.kind)} ${w.percentUsed}%`
  if (w.kind !== 'five_hour') return pct
  const end = typeof w.resetsAt === 'string' ? Date.parse(w.resetsAt) : NaN
  if (!Number.isFinite(end)) return pct
  const left = (end - nowMs) / 1000
  if (left <= 0) return `${windowName(w.kind)} reset`
  return `${pct} (${span(Math.min(FIVE_HOUR_S, FIVE_HOUR_S - left))})`
}

// Draws the status line from `shown`; skips the call when the text did not change.
const draw = async ($: EngineInterface) => {
  if (shown.length === 0) return
  const now = await $.clock.now()
  const text = `plan: ${shown.map(w => label(w, now)).join(', ')}`
  if (text === lastText) return
  lastText = text
  $.ui.status(text)
}

const place = async ($: EngineInterface) => {
  const cfgDir = await $.env.get('CLAUDE_CONFIG_DIR')
  const home = await $.env.get('HOME')
  const org = (await $.env.get('CLAUDE_CODE_ORGANIZATION_UUID')) ?? ''
  const acc = (await $.env.get('CLAUDE_CODE_ACCOUNT_UUID')) ?? ''
  const cfg = cfgDir || (home ? `${home}/.claude` : '')
  // Without both ids a reading cannot be tied to one plan: usage-limit.sh is off then.
  const acct = ID.test(org) && ID.test(acc) ? `${org}_${acc}` : ''
  return { dir: cfg ? `${cfg}/usage-feed` : '', acct }
}

// The file's text, or undefined when it is missing or cannot be read.
const readText = async ($: EngineInterface, path: string): Promise<string | undefined> => {
  try {
    return await $.fs.read(path)
  } catch {
    return undefined
  }
}

// The windows and mts of the feed file on disk; undefined when missing, unreadable or invalid.
const readOld = async ($: EngineInterface, path: string) => {
  const text = await readText($, path)
  if (text === undefined) return undefined
  try {
    const o = JSON.parse(text) as { windows?: unknown; mts?: unknown } | null
    if (!o || typeof o !== 'object' || !Array.isArray(o.windows)) return undefined
    const windows: Window[] = []
    for (const w of o.windows as Partial<Window>[]) {
      if (w && typeof w.kind === 'string' && typeof w.percentUsed === 'number') {
        windows.push({
          kind: w.kind,
          percentUsed: w.percentUsed,
          resetsAt: typeof w.resetsAt === 'string' ? w.resetsAt : undefined,
        })
      }
    }
    return { windows, mts: typeof o.mts === 'number' ? o.mts : 0 }
  } catch {
    return undefined
  }
}

// A stale reading must not overwrite a newer one. Per kind: inside the same window the
// percent never goes down; a later resetsAt wins; a kind only the old reading has is kept.
// `fromOld` is true when any figure of the result came from the old reading.
const merge = (old: readonly Window[], incoming: readonly Window[]) => {
  let fromOld = false
  const out: Window[] = incoming.map(w => {
    const o = old.find(x => x.kind === w.kind)
    if (!o) return w
    const oldEnd = epoch(o.resetsAt)
    const newEnd = epoch(w.resetsAt)
    // One window: its reset time can differ by a few milliseconds between readings
    // (seen 2026-11-23: .521Z, then .476Z for the same 5-hour window).
    if (Math.abs(oldEnd - newEnd) <= SAME_WINDOW_S) {
      if (o.percentUsed > w.percentUsed) {
        fromOld = true
        return { ...w, percentUsed: o.percentUsed }
      }
      return w
    }
    if (oldEnd > newEnd) {
      fromOld = true
      return o
    }
    return w
  })
  for (const o of old) {
    if (!incoming.some(w => w.kind === o.kind)) {
      fromOld = true
      out.push(o)
    }
  }
  return { windows: out, fromOld }
}

// The history on disk, one JSON object per line; bad lines are skipped.
const readHistory = async ($: EngineInterface, path: string): Promise<unknown[]> => {
  const text = await readText($, path)
  if (text === undefined) return []
  const out: unknown[] = []
  for (const line of text.split('\n')) {
    if (!line.trim()) continue
    try {
      const v: unknown = JSON.parse(line)
      if (v && typeof v === 'object') out.push(v)
    } catch {
      // A bad line is dropped.
    }
  }
  return out
}

// The context window of this session, for a command hook: only the engine knows it.
const writeContext = async ($: EngineInterface, dir: string, sid: string, ts: number) => {
  if (!SESSION_ID.test(sid)) return
  const c = (await $.session.usage()).context
  if (!c || typeof c.window !== 'number' || !Number.isFinite(c.window) || c.window <= 0) return
  const num = (n: unknown) => (typeof n === 'number' && Number.isFinite(n) ? n : null)
  const body = { ts, by: sid, window: c.window, tokens: num(c.tokens), percent: num(c.percent) }
  await $.fs.write(`${dir}/context-${sid}.json`, JSON.stringify(body) + '\n')
}

const record = async (
  $: EngineInterface,
  event: string,
  windows: readonly Window[],
  context: { percent?: number | null } | undefined,
  changed: readonly string[],
) => {
  // Before the first API response there is no reading: write nothing, keep the last one.
  if (windows.length === 0) return
  const { dir, acct } = await place($)
  const ts = Math.floor((await $.clock.now()) / 1000)
  // mts: when the figures were measured. A tick shows the figures of the last measure.
  let mts = event === 'measure' ? ts : lastMeasure || ts
  if (event === 'measure') lastMeasure = ts
  const sid = await $.session.id()
  const feedPath = `${dir}/feed-${acct}.json`
  const canWrite = Boolean(dir && acct)
  let merged: readonly Window[] = windows
  if (canWrite) {
    // Another session of this account may have written newer figures since.
    const old = await readOld($, feedPath)
    if (old) {
      const m = merge(old.windows, windows)
      merged = m.windows
      if (m.fromOld) mts = Math.max(mts, old.mts)
    }
  }
  const reading: Reading = {
    ts,
    mts,
    by: sid,
    source: 'mod',
    event,
    five: pick(merged, 'five_hour'),
    week: pick(merged, 'seven_day'),
    windows: merged.map(w => ({ kind: w.kind, percentUsed: w.percentUsed, resetsAt: w.resetsAt })),
    context: context ? { percent: context.percent ?? null } : undefined,
    changed: [...changed],
    surfaces: [...(await $.session.surfaces())],
  }
  lastWrite = reading.ts
  const kept = await $.store.get('history')
  const history = [...(Array.isArray(kept) ? kept : []), reading].slice(-HISTORY_MAX)
  await $.store.set('last', reading)
  await $.store.set('history', history)
  if (!canWrite) {
    $.ui.log(`usage-feed: no config dir or account id, file not written`, { to: 'debug' })
    return
  }
  await $.fs.write(feedPath, JSON.stringify(reading) + '\n')
  // The history file holds the readings of all sessions: read it back, append, trim.
  const lines = [...(await readHistory($, `${dir}/history-${acct}.jsonl`)), reading].slice(-HISTORY_MAX)
  await $.fs.write(
    `${dir}/history-${acct}.jsonl`,
    lines.map(r => JSON.stringify(r)).join('\n') + '\n',
  )
  try {
    await writeContext($, dir, sid, ts)
  } catch (err) {
    $.ui.log(`usage-feed: context not written: ${String(err).slice(0, 200)}`, { to: 'debug' })
  }
  shown = reading.windows
  await draw($)
  const text = windows.map(w => `${w.kind} ${w.percentUsed}%`).join(', ')
  // Debug log only (2026-11-24): a dim transcript line per change crowded the chat when
  // parallel agents made the reading go back and forth. The status line shows the figures.
  if (changed.includes('rateLimits')) $.ui.log(`usage-feed (${event}): ${text}`, { to: 'debug' })
}

export const register: Register = on => {
  // Session ready, or a reload: start the timer that keeps the status line's time current.
  // A reload shows this session's own last reading again; another session's is not shown.
  on('session.start', async ($, e, next) => {
    const r = await next(e)
    try {
      const last = (await $.store.get('last')) as Partial<Reading> | undefined
      if (shown.length === 0 && last && last.by === (await $.session.id()) && Array.isArray(last.windows)) {
        shown = last.windows
        await draw($)
      }
      timer?.cancel()
      timer = $.clock.every(REFRESH_MS, () => {
        draw($).catch(err =>
          $.ui.log(`usage-feed: status not drawn: ${String(err).slice(0, 200)}`, { to: 'debug' }),
        )
      })
    } catch (err) {
      $.ui.log(`usage-feed: status timer not started: ${String(err).slice(0, 200)}`, { to: 'debug' })
    }
    return r
  })

  on('session.measure', async ($, e, next) => {
    isFresh = true
    try {
      await record($, 'measure', e.rateLimits, e.context, e.changed)
    } catch (err) {
      $.ui.log(`usage-feed: measure not written: ${String(err).slice(0, 200)}`, { to: 'debug' })
    }
    return next(e)
  })

  // Heartbeat: keep ts fresh during a long tool loop. usage() costs nothing; the figures
  // are those of the last API response, which in a loop is the response before this call.
  on('tool.call', async ($, e, next) => {
    const ran = await next(e)
    try {
      const now = Math.floor((await $.clock.now()) / 1000)
      if (isFresh && now - lastWrite >= HEARTBEAT_S) {
        const u = await $.session.usage()
        await record($, 'tick', u.rateLimits, u.context, [])
      }
    } catch (err) {
      $.ui.log(`usage-feed: tick not written: ${String(err).slice(0, 200)}`, { to: 'debug' })
    }
    return ran
  })

  // A new main turn: the figures are of the last response before it, possibly old.
  on('turn.start', ($, e, next) => {
    if (e.agentId === undefined) isFresh = false
    return next(e)
  })
}
