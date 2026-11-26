import { atom, read, update } from 'claude-code'
import type { EngineInterface, Register } from 'claude-code'

import type {
  OturumArchived,
  OturumData,
  OturumHandoff,
  OturumPeer,
  OturumPeers,
  OturumSent,
  OturumSession,
  OturumUsage,
} from '../types'

// /oturum and a side pane: Claude sessions and their last handoff notes, on this machine and
// on the machines in local/machines.md (SSH). The data comes from bin/sessions.py --all --json.
// The mod changes no hook, setting or file. It also sends messages, only when the user presses
// the bulk handoff button: each picked live session gets a request to write its handoff note
// (marker [oturum:toplu-devir]). The command answers the Markdown the script made (data.text).
// The pane lists the sessions that have a handoff, with search, account and machine filters
// and a sort order.

const PANE = 'oturum'
const TITLE = 'Oturumlar'
const TIMEOUT_MS = 90_000
// Turkey time is UTC+3 all year.
const TR_OFFSET_S = 10_800
// A handoff older than this many seconds before the last activity gets a warning.
const STALE_GAP_S = 600

const ALL = '__all'
const NO_ACCOUNT = '__none'
const NO_ACCOUNT_LABEL = 'hesap bilinmiyor'

const SORT_NEW = 'handoff-new'
const SORT_OLD = 'handoff-old'
const SORT_NAME = 'name'
const SORT_OPTIONS = [
  { value: SORT_NEW, label: 'Yeniden eskiye' },
  { value: SORT_OLD, label: 'Eskiden yeniye' },
  { value: SORT_NAME, label: 'Ada göre' },
]

// The last refresh. Change the shape tag when OturumData changes: state outlives a reload.
const data = atom({ plugin: 'oturum', key: 'data' } as const, null as OturumData | null, {
  shape: 'oturum-3',
})
// The pane controls.
const query = atom({ plugin: 'oturum', key: 'query' } as const, '', { shape: 'oturum-query-1' })
const account = atom({ plugin: 'oturum', key: 'account' } as const, ALL, { shape: 'oturum-account-1' })
const machine = atom({ plugin: 'oturum', key: 'machine' } as const, ALL, { shape: 'oturum-machine-1' })
const sort = atom({ plugin: 'oturum', key: 'sort' } as const, SORT_NEW, { shape: 'oturum-sort-1' })
// Bulk handoff: the live peers, the picked keys and the last send result per key.
const peers = atom({ plugin: 'oturum', key: 'peers' } as const, null as OturumPeers | null, {
  shape: 'oturum-peers-1',
})
const picked = atom({ plugin: 'oturum', key: 'picked' } as const, [] as string[], {
  shape: 'oturum-picked-1',
})
// Archived sessions from the Desktop app's session list, and the toggle that shows them anyway.
const archived = atom({ plugin: 'oturum', key: 'archived' } as const, null as OturumArchived | null, {
  shape: 'oturum-archived-1',
})
const showArchived = atom({ plugin: 'oturum', key: 'showArchived' } as const, false, {
  shape: 'oturum-show-archived-1',
})
const sent = atom({ plugin: 'oturum', key: 'sent' } as const, {} as Record<string, OturumSent>, {
  shape: 'oturum-sent-1',
})

const two = (n: number) => String(n).padStart(2, '0')

// Epoch seconds -> "YYYY-MM-DD HH:MM" in Turkey time.
const trTime = (epochS: number): string => {
  const d = new Date((epochS + TR_OFFSET_S) * 1000)
  return `${d.getUTCFullYear()}-${two(d.getUTCMonth() + 1)}-${two(d.getUTCDate())} ${two(d.getUTCHours())}:${two(d.getUTCMinutes())}`
}

// Puts a text on the clipboard of the surface the press came from, and says so in a toast.
const copy = async ($: EngineInterface, text: string, surface: string | undefined, what: string) => {
  try {
    const result = await $.ui.copy({ text, surface: surface as never })
    $.ui.toast(result.isCopied ? `${what} kopyalandı` : `${what} kopyalanamadı (${result.reason ?? 'bilinmiyor'})`)
  } catch (err) {
    $.ui.log(`oturum: copy failed: ${String(err).slice(0, 200)}`, { to: 'debug' })
  }
}

// Same rule as duration() in sessions.py: "40 dk", "2 sa 10 dk", "2 sa", "1 gün 2 sa".
const duration = (seconds: number): string => {
  const minutes = Math.floor(seconds / 60)
  if (minutes < 60) return `${minutes} dk`
  const hours = Math.floor(minutes / 60)
  const restMin = minutes % 60
  if (hours < 24) return restMin ? `${hours} sa ${restMin} dk` : `${hours} sa`
  const days = Math.floor(hours / 24)
  const restHours = hours % 24
  return restHours ? `${days} gün ${restHours} sa` : `${days} gün`
}

const firstLine = (text: string): string =>
  text
    .split('\n')
    .map(line => line.trim())
    .find(line => line.length > 0) ?? ''

const failed = (at: number, error: string): OturumData => ({ at, error, machines: [], notes: [] })

const parse = (at: number, stdout: string): OturumData => {
  let raw: unknown
  try {
    raw = JSON.parse(stdout)
  } catch {
    return failed(at, 'sessions.py çıktısı JSON değil')
  }
  const obj = raw as Partial<OturumData> | null
  if (!obj || typeof obj !== 'object' || !Array.isArray(obj.machines)) {
    return failed(at, 'sessions.py çıktısında machines yok')
  }
  return {
    at,
    text: typeof obj.text === 'string' ? obj.text : undefined,
    machines: obj.machines,
    notes: Array.isArray(obj.notes) ? obj.notes : [],
    usage: Array.isArray(obj.usage) ? obj.usage : [],
  }
}

// Same rule as usage_line() in sessions.py. nowS is epoch seconds.
const usageLine = (u: OturumUsage, nowS: number): string => {
  const window = (label: string, pct: number | null, reset: number | null, fmt: (e: number) => string) => {
    if (pct === null || pct === undefined) return `${label} -`
    if (reset && reset <= nowS) return `${label} sıfırlandı`
    return `${label} ${pct}%${reset ? ` (${fmt(reset)})` : ''}`
  }
  const parts = [
    u.account || NO_ACCOUNT_LABEL,
    window('5-hour limit', u.fivePct, u.fiveReset, e => trTime(e).slice(11)),
    window('Weekly', u.weekPct, u.weekReset, trTime),
  ]
  if (u.measuredAt) parts.push(`ölçüm ${trTime(u.measuredAt)}`)
  return parts.join(' · ')
}

const titleOf = (s: OturumSession): string => s.title || String(s.sessionId ?? '').slice(0, 8)

// The folder to open a new session in. sessions.py sends it; older output has only cwd.
const folderOf = (s: OturumSession): string =>
  s.folder || (s.cwd ? s.cwd.split('/.claude/worktrees/')[0]! : '')

// One line of the list. A row has a session (sessions.py), a live peer (ListAgents), or both.
// A row with a peer is open and has a check box. A row with only a session is closed.
// A peer without a session has unknown machine, account and last activity.
type Row = {
  machine: string | null
  session: OturumSession | null
  handoff: OturumHandoff | null
  peer: OturumPeer | null
  title: string
  account: string | null
  // Epoch seconds, or null when unknown (a peer without a session).
  last: number | null
  // True for a closed row whose session the Desktop app archived (shown only by the toggle).
  isArchived: boolean
}

// Key of a session in the archived list: its title and folder.
const archiveKey = (s: OturumSession): string => `${s.title}\n${s.cwd}`

// Builds the rows. A live peer is paired with a session by the exact title: for each peer name,
// the sessions with that title (newest activity first) meet the peers of that name in list order.
// A session without a handoff and without a peer is not a row; it is only counted (hidden).
// A closed session the Desktop app archived is left out unless showAll, and counted in
// archivedHidden. A row with a live peer is never left out.
const buildRows = (
  d: OturumData,
  pe: OturumPeers | null,
  archivedKeys: ReadonlySet<string>,
  showAll: boolean,
): { rows: Row[]; hidden: number; archivedHidden: number } => {
  const all = d.machines.flatMap(m => (m.sessions ?? []).map(session => ({ machine: m.name, session })))
  const byTitle = new Map<string, typeof all>()
  for (const x of all) {
    if (!x.session.title) continue
    byTitle.set(x.session.title, [...(byTitle.get(x.session.title) ?? []), x])
  }
  for (const list of byTitle.values()) {
    list.sort((a, b) => (b.session.lastActivity ?? 0) - (a.session.lastActivity ?? 0))
  }
  const taken = new Map<string, number>()
  const pairs = new Map<OturumSession, OturumPeer>()
  const peerOnly: Row[] = []
  for (const peer of pe?.rows ?? []) {
    const i = taken.get(peer.name) ?? 0
    taken.set(peer.name, i + 1)
    const hit = byTitle.get(peer.name)?.[i]
    if (hit) {
      pairs.set(hit.session, peer)
    } else {
      peerOnly.push({ machine: null, session: null, handoff: null, peer, title: peer.name, account: null, last: null, isArchived: false })
    }
  }
  const rows: Row[] = []
  let hidden = 0
  let archivedHidden = 0
  for (const x of all) {
    const peer = pairs.get(x.session) ?? null
    if (!peer && !x.session.handoff) {
      hidden += 1
      continue
    }
    const isArchived = !peer && !!x.session.title && !!x.session.cwd && archivedKeys.has(archiveKey(x.session))
    if (isArchived && !showAll) {
      archivedHidden += 1
      continue
    }
    rows.push({
      isArchived,
      machine: x.machine,
      session: x.session,
      handoff: x.session.handoff,
      peer,
      title: titleOf(x.session),
      account: x.session.account,
      last: x.session.lastActivity ?? 0,
    })
  }
  return { rows: [...rows, ...peerOnly], hidden, archivedHidden }
}

const lower = (text: string): string => text.toLocaleLowerCase('tr')

const matches = (r: Row, q: string): boolean => {
  const needle = lower(q.trim())
  if (!needle) return true
  return [r.title, r.handoff?.path ?? '', r.account ?? '']
    .some(field => lower(field).includes(needle))
}

// A peer-only row has no machine and no account: it shows only when both filters are Tümü.
const view = (rows: Row[], q: string, acc: string, mach: string, order: string): Row[] => {
  const out = rows.filter(r => {
    if (!r.session) return mach === ALL && acc === ALL && matches(r, q)
    if (mach !== ALL && r.machine !== mach) return false
    if (acc === NO_ACCOUNT && r.account) return false
    if (acc !== ALL && acc !== NO_ACCOUNT && r.account !== acc) return false
    return matches(r, q)
  })
  // A row without a known last activity counts as the newest.
  const lastOf = (r: Row) => r.last ?? Number.POSITIVE_INFINITY
  const byLast = (a: Row, b: Row) => (lastOf(a) === lastOf(b) ? 0 : lastOf(a) < lastOf(b) ? -1 : 1)
  if (order === SORT_NAME) {
    out.sort((a, b) => a.title.localeCompare(b.title, 'tr'))
  } else if (order === SORT_OLD) {
    out.sort(byLast)
  } else {
    out.sort((a, b) => byLast(b, a))
  }
  return out
}

const accountOptions = (d: OturumData) => {
  const all = d.machines.flatMap(m => m.sessions ?? [])
  const names = [...new Set(all.map(s => s.account).filter((a): a is string => !!a))].sort()
  return [
    { value: ALL, label: 'Tümü' },
    ...names.map(n => ({ value: n, label: n })),
    ...(all.some(s => !s.account) ? [{ value: NO_ACCOUNT, label: NO_ACCOUNT_LABEL }] : []),
  ]
}

const machineOptions = (d: OturumData) => [
  { value: ALL, label: 'Tümü' },
  ...d.machines.map(m => ({ value: m.name, label: m.name })),
]

// The text of /oturum: the Markdown the script made.
const commandText = (d: OturumData): string => {
  if (d.error) return `Oturumlar okunamadı: ${d.error}`
  return d.text ?? 'Oturumlar okunamadı: sessions.py çıktısında text yok'
}

// Runs the script, keeps the result in $.state and answers the command text. It never throws.
const refresh = async ($: EngineInterface): Promise<string> => {
  let at = 0
  let result: OturumData
  try {
    at = await $.clock.now()
    const script = `${$.plugin.root}/bin/sessions.py`
    const run = await $.process.run(['python3', script, '--all', '--json'], { timeoutMs: TIMEOUT_MS })
    result =
      run.exitCode === 0
        ? parse(at, run.stdout)
        : failed(at, `python3 çıkış kodu ${run.exitCode}: ${firstLine(run.stderr)}`)
  } catch (err) {
    result = failed(at, String(err).slice(0, 200))
  }
  try {
    await update($, data, () => result)
  } catch (err) {
    $.ui.log(`oturum: state not written: ${String(err).slice(0, 200)}`, { to: 'debug' })
  }
  return commandText(result)
}

type ListAgentsRows = { name?: string; ref?: string; type?: string; status?: string }[]

// Lists the live peers (ListAgents) into the peers atom. Offline rows are left out, and picked
// keys that are no longer listed are dropped. It never throws.
const loadPeers = async ($: EngineInterface): Promise<void> => {
  let at = 0
  let result: OturumPeers
  try {
    at = await $.clock.now()
    const res = (await $.tool.call({ tool: 'ListAgents' })) as unknown as {
      deny?: string
      result?: { sections?: { rows?: ListAgentsRows }[] }
    }
    if (res.deny !== undefined) {
      result = { at, error: `Oturum listesi alınamadı: ${String(res.deny).slice(0, 120)}`, rows: [] }
    } else {
      const rows: OturumPeer[] = []
      const seen = new Set<string>()
      for (const section of res.result?.sections ?? []) {
        for (const r of section.rows ?? []) {
          if (!r.name || !r.status || r.status === 'offline') continue
          const key = r.ref ? `${r.name} [${r.ref}]` : r.name
          if (seen.has(key)) continue
          seen.add(key)
          rows.push({ key, name: r.name, ref: r.ref, status: r.status, type: r.type })
        }
      }
      result = { at, rows }
    }
  } catch (err) {
    result = { at, error: `Oturum listesi alınamadı: ${String(err).slice(0, 120)}`, rows: [] }
  }
  try {
    await update($, peers, () => result)
    const listed = new Set(result.rows.map(r => r.key))
    await update($, picked, keys => (keys ?? []).filter(k => listed.has(k)))
  } catch (err) {
    $.ui.log(`oturum: peers not written: ${String(err).slice(0, 200)}`, { to: 'debug' })
  }
}

// The message a picked session gets. The marker lets a hook in that session add the full rules.
const bulkText = (name: string): string =>
  [
    'Toplu devir isteği [oturum:toplu-devir]: kullanıcı /oturum panelinden bu oturum için şimdi devir notu yazılmasını istedi.',
    'Bir hook notu bu turda kuralları ve dosya yolunu verir. Hook notu yoksa şu kurallarla yaz:',
    '1. Yeni iş başlatma. Mevcut işi güvenli bir noktada bırak.',
    `2. Önce detay notu, sonra ana not. Ana not: projenin .claude/ klasöründe '${name}-handoff-<bu oturumun session id'si>.md'. İlk satır '# ${name} — devir notu'. Bölümler: READ FIRST, Goal, Done, Key decisions, Ruled out, File paths. 6000 karakterin altında.`,
    "3. Detay notu: aynı ad, '.detay.md' uzantısı. Bölümler: Decisions and reasons, User requests in their words, Open tasks, Background jobs, Ruled out and why, Lessons learned, Memory changes, Environment.",
    '4. Secret yazma. Bitince iki dosyanın yolunu tek satırla yaz.',
  ].join('\n')

// Sends the handoff request to each picked peer, one at a time, and says the result in a toast.
// It never throws.
const sendBulk = async ($: EngineInterface): Promise<void> => {
  try {
    const keys = (await read($, picked)) ?? []
    const list = ((await read($, peers))?.rows ?? []).filter(r => keys.includes(r.key))
    if (list.length === 0) {
      $.ui.toast('Önce oturum seç')
      return
    }
    const results: Record<string, OturumSent> = {}
    let okCount = 0
    for (const peer of list) {
      const at = await $.clock.now()
      try {
        const res = await $.session.send({ to: peer.key, text: bulkText(peer.name) })
        if (res.isDelivered) {
          okCount += 1
          results[peer.key] = { at, ok: true }
        } else {
          results[peer.key] = { at, ok: false, reason: String(res.reason ?? 'bilinmiyor').slice(0, 120) }
        }
      } catch (err) {
        results[peer.key] = { at, ok: false, reason: String(err).slice(0, 120) }
      }
    }
    await update($, sent, () => results)
    const failCount = list.length - okCount
    $.ui.toast(failCount === 0 ? `${okCount} oturuma gönderildi` : `${okCount} gönderildi, ${failCount} gönderilemedi`)
  } catch (err) {
    $.ui.log(`oturum: bulk send failed: ${String(err).slice(0, 200)}`, { to: 'debug' })
  }
}

const STATUS_TR: Record<string, string> = { idle: 'boşta', running: 'çalışıyor' }

// Reads the Desktop app's session list (include_archived) into the archived atom. A key
// "<title>\n<cwd>" is kept only when every session with that title and folder is archived.
// On any failure the atom holds an error and no keys, so nothing is hidden. It never throws.
const loadArchived = async ($: EngineInterface): Promise<void> => {
  let at = 0
  let result: OturumArchived
  try {
    at = await $.clock.now()
    const res = await $.mcp.call('ccd_session_mgmt', 'list_sessions', { include_archived: true, limit: 500 })
    const text = res.content.find(b => b.type === 'text')?.text
    if (res.isError) {
      result = { at, error: `araç hata verdi: ${String(text ?? '').slice(0, 80)}`, keys: [] }
    } else {
      let list: unknown
      try {
        list = JSON.parse(text ?? '')
      } catch {
        list = null
      }
      if (!Array.isArray(list)) {
        result = { at, error: 'cevap JSON liste değil', keys: [] }
      } else {
        const groups = new Map<string, boolean>()
        for (const row of list as { title?: unknown; cwd?: unknown; isArchived?: unknown }[]) {
          if (!row || typeof row.title !== 'string' || typeof row.cwd !== 'string' || !row.title || !row.cwd) continue
          const key = `${row.title}\n${row.cwd}`
          groups.set(key, (groups.get(key) ?? true) && row.isArchived === true)
        }
        result = { at, keys: [...groups].filter(([, all]) => all).map(([key]) => key) }
      }
    }
  } catch (err) {
    result = { at, error: String(err).slice(0, 80), keys: [] }
  }
  try {
    await update($, archived, () => result)
  } catch (err) {
    $.ui.log(`oturum: archived not written: ${String(err).slice(0, 200)}`, { to: 'debug' })
  }
}

// The sessions.py data, the live peers and the archived list, one after the other.
// It answers the command text.
// The three loads run at the same time. None of them throws.
const refreshAll = async ($: EngineInterface): Promise<string> => {
  const [text] = await Promise.all([refresh($), loadPeers($), loadArchived($)])
  return text
}

// What "Seçilenlerin bilgilerini kopyala" puts on the clipboard: name, folder and prompt of each
// picked session, a blank line between sessions. A session whose handoff is not listed yet says
// so: the user presses Yenile after the notes are written.
const pickedText = (rows: Row[], keys: string[]): string =>
  rows
    .filter(r => r.peer && keys.includes(r.peer.key))
    .map(r =>
      [
        `Oturum ismi: ${r.title}`,
        `Klasör: ${(r.session && folderOf(r.session)) || 'bilinmiyor'}`,
        `Prompt: ${r.handoff ? r.handoff.prompt : "devir notu henüz yok (notlar yazılınca Yenile'ye bas)"}`,
      ].join('\n'),
    )
    .join('\n\n')

export const register: Register = on => {
  on('session.start', async ($, e, next) => {
    try {
      await $.command.register({
        name: 'oturum',
        description: 'Claude oturumları ve son devir notları (yerel ve SSH)',
      })
    } catch (err) {
      $.ui.log(`oturum: command not registered: ${String(err).slice(0, 200)}`, { to: 'debug' })
    }
    return next(e)
  })

  on('command.run', { command: 'oturum' }, async $ => {
    const text = await refreshAll($)
    try {
      await $.ui.open({ id: PANE, title: TITLE })
    } catch (err) {
      $.ui.log(`oturum: pane not opened: ${String(err).slice(0, 200)}`, { to: 'debug' })
    }
    return { text }
  })

  on('ui.render', { component: 'Pane', requestId: PANE }, async ($, e) => {
    const { Box, Text, Button, Input, Select } = $.ui.resolve(e)
    const d = await read($, data)

    if (!d) {
      return (
        <Box flexDirection="column">
          <Button key="refresh" variant="primary" onPress={() => refreshAll($).then(() => undefined)}>
            Yenile
          </Button>
          <Text dimColor>Henüz veri yok. Yenile'ye bas veya /oturum çalıştır.</Text>
        </Box>
      )
    }

    const q = (await read($, query)) ?? ''
    const acc = (await read($, account)) ?? ALL
    const mach = (await read($, machine)) ?? ALL
    const order = (await read($, sort)) ?? SORT_NEW

    const pe = (await read($, peers)) ?? null
    const pickedKeys = (await read($, picked)) ?? []
    const sentMap = (await read($, sent)) ?? {}
    const arch = (await read($, archived)) ?? null
    const showAll = (await read($, showArchived)) ?? false
    const built = buildRows(d, pe, new Set(arch?.keys ?? []), showAll)
    const shown = view(built.rows, q, acc, mach, order)
    const liveShown = shown.filter(r => r.peer)
    const n = pickedKeys.length

    // One flat column: a nested Box per session drew a second line in the desktop app.
    const cards = shown.flatMap((r, i) => {
      const s = r.session
      const ho = r.handoff
      const peer = r.peer
      const sendInfo = peer ? sentMap[peer.key] : undefined
      const gap = ho && r.last !== null ? r.last - ho.writtenAt : 0
      const id = String(s?.sessionId ?? peer?.key ?? i)
      const durum = peer ? (STATUS_TR[peer.status] ?? peer.status) : r.isArchived ? 'arşivlendi' : 'kapalı'
      const head = `${i + 1}. ${r.title}`
      const caption = s
        ? `${r.machine || 'makine bilinmiyor'} · ${r.account || NO_ACCOUNT_LABEL} · son hareket ${trTime(r.last ?? 0)} · ${durum}`
        : `son hareket bilinmiyor · ${durum}`
      return [
        // A blank line between cards, no separator line (easier on the eyes).
        ...(i > 0 ? [<Text>{' '}</Text>] : []),
        peer ? (
          <Button
            key={`pick:${peer.key}`}
            onPress={() =>
              update($, picked, keys =>
                (keys ?? []).includes(peer.key) ? (keys ?? []).filter(k => k !== peer.key) : [...(keys ?? []), peer.key],
              ).then(() => undefined)
            }
          >
            {`${pickedKeys.includes(peer.key) ? '☑' : '☐'} ${head}`}
          </Button>
        ) : (
          <Text bold>{head}</Text>
        ),
        <Text dimColor size="caption">{caption}</Text>,
        ...(s && folderOf(s) ? [<Text>{`Klasör: ${folderOf(s)}`}</Text>] : []),
        ...(ho
          ? [<Text dimColor size="caption">{`devir notu ${trTime(ho.writtenAt)}`}</Text>]
          : s
            ? [<Text dimColor size="caption">devir notu yok</Text>]
            : []),
        ...(gap > STALE_GAP_S ? [<Text>{`⚠ nottan sonra ${duration(gap)} daha çalıştı`}</Text>] : []),
        ...(ho && !ho.detail?.exists ? [<Text>⚠ detay notu yok</Text>] : []),
        ...(sendInfo
          ? [
              <Text dimColor size="caption">
                {sendInfo.ok
                  ? `devir isteği gönderildi ${trTime(sendInfo.at / 1000).slice(11)} TR`
                  : `gönderilemedi: ${sendInfo.reason ?? 'bilinmiyor'}`}
              </Text>,
            ]
          : []),
        ...(ho && s
          ? [
              <Box flexDirection="row" gap={1}>
                <Button key={`prompt:${id}`} onPress={press => copy($, ho.prompt, press.surface, 'Prompt')}>
                  Prompt'u kopyala
                </Button>
                {!!folderOf(s) && (
                  <Button key={`folder:${id}`} onPress={press => copy($, folderOf(s), press.surface, 'Klasör')}>
                    Klasörü kopyala
                  </Button>
                )}
              </Box>,
            ]
          : []),
      ]
    })

    return (
      <Box flexDirection="column" gap={1}>
        <Box flexDirection="row" gap={1} alignItems="center">
          <Text dimColor>{`Son yenileme ${trTime(d.at / 1000)} TR`}</Text>
          <Button key="refresh" variant="primary" onPress={() => refreshAll($).then(() => undefined)}>
            Yenile
          </Button>
        </Box>
        {(d.usage ?? []).map(u => (
          <Text dimColor size="caption">{usageLine(u, d.at / 1000)}</Text>
        ))}
        <Box flexDirection="column">
          {!!pe?.error && <Text>{pe.error}</Text>}
          <Box flexDirection="row" gap={1} flexWrap="wrap">
            <Button
              key="send"
              onPress={() => sendBulk($)}
              {...(n > 0 ? { variant: 'primary' as const } : { dimColor: true })}
            >
              {`Seçilenler için devir notu yazdır (${n})`}
            </Button>
            <Button
              key="all"
              onPress={() => update($, picked, () => liveShown.map(r => r.peer!.key)).then(() => undefined)}
            >
              Tümünü seç
            </Button>
            <Button key="clear" onPress={() => update($, picked, () => []).then(() => undefined)}>
              Seçimi temizle
            </Button>
            <Button
              key="copy-picked"
              onPress={press => {
                const text = pickedText(built.rows, pickedKeys)
                if (!text) {
                  $.ui.toast('Önce oturum seç')
                  return
                }
                return copy($, text, press.surface, 'Seçilenlerin bilgileri')
              }}
              {...(n > 0 ? {} : { dimColor: true })}
            >
              {`Seçilenlerin bilgilerini kopyala (${n})`}
            </Button>
          </Box>
          <Text dimColor size="caption">
            Kutu yalnız açık oturumlarda var. Kapalı bir oturum için önce onu Desktop'ta aç, sonra Yenile'ye bas. Devir notları yazılınca Yenile'ye bas, sonra bilgileri kopyala.
          </Text>
        </Box>
        <Input
          key="q"
          value={q}
          placeholder="Ara: oturum adı, yol veya hesap"
          onSubmit={v => update($, query, () => v).then(() => undefined)}
        />
        <Box flexDirection="row" gap={1} flexWrap="wrap">
          <Select
            key="account"
            label="Hesap"
            options={accountOptions(d)}
            value={acc}
            onSelect={v => update($, account, () => v).then(() => undefined)}
          />
          <Select
            key="machine"
            label="Makine"
            options={machineOptions(d)}
            value={mach}
            onSelect={v => update($, machine, () => v).then(() => undefined)}
          />
          <Select
            key="sort"
            label="Sıralama"
            options={SORT_OPTIONS}
            value={order}
            onSelect={v => update($, sort, () => v).then(() => undefined)}
          />
          <Button key="archived:toggle" onPress={() => update($, showArchived, v => !v).then(() => undefined)}>
            {`${showAll ? '☑' : '☐'} Arşivlenenleri göster`}
          </Button>
        </Box>
        {!!arch?.error && (
          <Text dimColor size="caption">{`Arşiv listesi okunamadı: ${arch.error}. Arşivlenenler de görünüyor.`}</Text>
        )}
        {!!d.error && <Text>{`Hata: ${d.error}`}</Text>}
        <Box flexDirection="column">
          {cards}
        </Box>
        <Text dimColor size="caption">{`Gösterilen: ${shown.length} oturum · açık ${liveShown.length} · devir notu olmayan kapalı ${built.hidden} oturum gösterilmedi${built.archivedHidden > 0 && !showAll ? ` · arşivlenen ${built.archivedHidden} gizli` : ''}`}</Text>
        {d.machines
          .filter(m => !m.ok)
          .map(m => (
            <Text>{`Hata: ${m.name}: ${m.error ?? 'bilinmiyor'}`}</Text>
          ))}
        {d.notes.map(note => (
          <Text dimColor size="caption">{`Not: ${note}`}</Text>
        ))}
      </Box>
    )
  })
}
