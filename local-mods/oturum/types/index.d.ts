// Contract of the oturum mod: the shape of what bin/sessions.py --all --json prints, and the
// session state the pane draws from. Times in session and handoff fields are epoch seconds;
// OturumData.at is epoch milliseconds (the engine clock).

export type OturumFile = { path: string; exists: boolean }

export type OturumHandoff = {
  path: string
  prompt: string
  writtenAt: number
  title: string | null
  readFirst: string | null
  detail: OturumFile
  dump: OturumFile
}

export type OturumSession = {
  sessionId: string
  title: string | null
  cwd: string | null
  // The folder to open a new session in: the main repo for a worktree session.
  folder?: string | null
  project: string | null
  gitBranch: string | null
  orgId: string | null
  account: string | null
  lastActivity: number
  sizeBytes: number
  cwdExists: boolean
  handoff: OturumHandoff | null
}

export type OturumMachine = {
  name: string
  ok: boolean
  error: string | null
  sessions: OturumSession[]
}

// The last usage reading of one account (bin/sessions.py usage_summary). Times are epoch seconds.
export type OturumUsage = {
  orgId: string
  account: string | null
  fivePct: number | null
  fiveReset: number | null
  weekPct: number | null
  weekReset: number | null
  measuredAt: number | null
}

export type OturumData = {
  at: number
  // One entry per account on this machine, newest reading first. Older data has none.
  usage?: OturumUsage[]
  // Set when the whole refresh failed (the script did not run or printed no usable JSON).
  error?: string
  // Ready Markdown of the slash command, made by the script.
  text?: string
  machines: OturumMachine[]
  notes: string[]
}

// A live Claude session the engine can message (ListAgents). key is the SendMessage spelling:
// "name [ref]", or the bare name when there is no ref.
export type OturumPeer = { key: string; name: string; ref?: string; status: string; type?: string }

// The last ListAgents answer. at is epoch milliseconds. error is set when the call failed.
export type OturumPeers = { at: number; error?: string; rows: OturumPeer[] }

// The result of the last bulk send to one peer. at is epoch milliseconds.
export type OturumSent = { at: number; ok: boolean; reason?: string }

// Sessions the Desktop app archived, from its session list. at is epoch milliseconds. Each key is
// "<title>\n<cwd>" and is listed only when every session with that title and folder is archived.
// error is set when the list could not be read (then keys is empty and nothing is hidden).
export type OturumArchived = { at: number; error?: string; keys: string[] }

declare module 'claude-code' {
  interface PluginState {
    oturum: {
      data: Shaped<OturumData | null>
      // Pane controls: search text, account filter, machine filter, sort order.
      query: Shaped<string>
      account: Shaped<string>
      machine: Shaped<string>
      sort: Shaped<string>
      // Bulk handoff: live peers, the picked keys, and the last send result per key.
      peers: Shaped<OturumPeers | null>
      picked: Shaped<string[]>
      sent: Shaped<Record<string, OturumSent>>
      // Archived sessions (Desktop app list) and the toggle that shows them anyway.
      archived: Shaped<OturumArchived | null>
      showArchived: Shaped<boolean>
    }
  }
}
