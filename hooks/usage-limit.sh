#!/usr/bin/env bash
# Usage-limit guard: two automatic stops near the plan limit, and a warning with a copyable
# prompt at the end of every reply once the first threshold is reached.
#
# TARGET: Linux and macOS, one file. Bash 3.2 compatible. No uname branching.
#
# A command hook cannot read the plan usage itself. The Desktop app gives the model a
# tool, mcp__ccd_session_mgmt__get_usage, and this script is the hook around it.
#
# Stages (the 5-hour and the weekly "all models" window both count):
#   stage 1   a reading at or above STOP1_PCT (default 91, "over 90 %")
#   stage 2   a reading at or above STOP2_PCT (default 96, "over 95 %")
# A session that already had a conversation stops once per stage and window (the stop flags
# carry the window's reset time, so a new window arms the stops again): it writes its handoff,
# shows the prompt for the other account and ends the turn. A session that starts after
# the stage was reached does not stop. After a stop the user may go on working in the
# session: while a stage is reached, every reply updates the handoff and ends with a
# warning line and the copyable prompt. "#limit-devam" in a prompt skips a pending stop.
#
#   PostToolBatch     checkpoint after every tool batch: poll request (one session of the
#                     account, mkdir lock) or the stop instruction. After the handoff of a
#                     stop is saved, the next batch ends the loop (continue:false).
#                     A get_usage call that gave no reading (it failed, or it timed out
#                     because the app did not answer) ends the poll and pauses the polls.
#   PreToolUse        poll asked but not done: deny other tools (fail-open after 3 denials).
#                     No denial after a get_usage call, also when that call fails.
#                     During a stop: allow only reading, the handoff and memory files.
#   PostToolUse       get_usage result -> <state>/<account>/usage.json (the hook records it,
#                     not the model). Write/Edit of the handoff -> stamp line 2, add the
#                     "Ek dosyalar" line, start the transcript dump, check the detail note,
#                     rebuild the index, hand over the warning line and the prompt. Write/Edit
#                     of the detail note (or its worktree draft) -> copy the draft, check it.
#   UserPromptSubmit  pending stop -> stop instruction. Stage reached -> warning instruction
#                     for the end of the reply. Stale reading -> poll request.
#
# Optional usage-feed mod (G04): a Claude Code mod that writes the plan usage the engine
# pushes (session.measure) to <config>/usage-feed/feed-<workspace>_<account>.json, in the
# shape of usage.json. When that file is newer than usage.json, it is the reading: no poll
# request and no denials while the mod keeps it fresh. Without the mod nothing changes.
#
# Three files per handoff (2026-11-23): the handoff H, a detail note D next to it
# (<H without .md>.detay.md, written by the model, no size limit, eight required headings)
# and a transcript dump X ($CFG/handoff-dumps/<H name>.transcript.md) that a hook writes
# with handoff-dump.py. The next session, possibly on another account or in Codex (which
# loads no memory), must go on without loss. The model writes D first, then H. A stop
# allows Write and Edit of D and of its worktree draft. The long prompt file carries D too.
# The dump runs in the background (HANDOFF_DUMP_SYNC=1: foreground, for tests). No python3
# or a dump error is logged and never stops the hook.
#
# State is per workspace and account (CLAUDE_CODE_ORGANIZATION_UUID + CLAUDE_CODE_ACCOUNT_UUID),
# so the sessions of the other workspace are not affected. Settings: ~/.claude/hooks/usage-limit.conf (KEY=VALUE), each key can also be set
# as an environment variable. No set -e and no ERR trap: every path exits 0.

umask 077

CFG="${CLAUDE_CONFIG_DIR:-$HOME/.claude}"
LOG="$CFG/hooks/context-pressure.log"
UL_CONF="${USAGE_LIMIT_CONF:-$CFG/hooks/usage-limit.conf}"
UL_STATE="${USAGE_LIMIT_STATE_DIR:-$CFG/hooks/state/usage}"
UL_INDEX_DIR="${USAGE_LIMIT_INDEX_DIR:-$CFG/limit-handoffs}"
# Same marker directory as context-pressure.sh, so handoff-load.sh lists limit handoffs too.
PENDING_DIR="${CTX_PRESSURE_STATE_DIR:-$CFG/hooks/state}/pending.d"
TOOL_USAGE="mcp__ccd_session_mgmt__get_usage"
FEED_DIR="${USAGE_FEED_DIR:-$CFG/usage-feed}"
LOCK_STALE_S=180
# The long prompt file (<name>.prompt.txt) holds the handoff and the detail note. The
# handoff is cut at HANDOFF_CUT_BYTES, the detail note at the rest of PROMPT_MAX_BYTES
# (60000). Each cut carries the "uzun" note.
PROMPT_MAX_BYTES=72000
HANDOFF_CUT_BYTES=12000
DETAIL_CUT_BYTES=$(( PROMPT_MAX_BYTES - HANDOFF_CUT_BYTES ))
case "$0" in */*) HOOK_DIR="${0%/*}" ;; *) HOOK_DIR="." ;; esac
DUMP_PY="$HOOK_DIR/handoff-dump.py"
DETAIL_HEADINGS='## Decisions and reasons
## User requests in their words
## Open tasks
## Background jobs
## Ruled out and why
## Lessons learned
## Memory changes
## Environment'
# get_usage reports a window's reset time with jitter (measured: 22:00:00.103Z, later
# 21:59:59.733Z for the same window). A next window resets hours later, so two reset
# times within this many seconds belong to the same window.
RESET_TOL_S=1800
# A get_usage call that gives no reading pauses the polls of the session this long. Seen on
# 2026-11-04: "PreToolUse hook did not respond before its timeout (host client may be
# unreachable)" for every get_usage call, while Bash and Read were denied by the poll gate.
POLL_FAIL_OFF_S=600

mkdir -p "${LOG%/*}" 2>/dev/null

clean() {
    printf '%s' "$1" | tr -d '\000-\037\177' | cut -c1-"${2:-200}"
}

log() {
    printf '%s %s\n' "$(date -u +%FT%TZ)" "usage-limit: $*" >> "$LOG" 2>/dev/null
}

trim_log() {
    local size
    [ -f "$LOG" ] || return 0
    size=$(wc -c < "$LOG" 2>/dev/null | tr -d ' ')
    case "$size" in ''|*[!0-9]*) return 0 ;; esac
    if [ "$size" -gt 1048576 ]; then
        tail -n 200 "$LOG" > "$LOG.tmp.$$" 2>/dev/null \
            && mv -f "$LOG.tmp.$$" "$LOG" 2>/dev/null
    fi
}

sha1_16() {
    if command -v sha1sum >/dev/null 2>&1; then
        printf '%s' "$1" | sha1sum | cut -c1-16
    else
        printf '%s' "$1" | shasum -a 1 | cut -c1-16
    fi
}

# Epoch to a readable time in a time zone: GNU date first, BSD date second.
fmt_time() { # epoch, TZ name
    TZ="$2" date -d "@$1" '+%Y-%m-%d %H:%M:%S' 2>/dev/null \
        || TZ="$2" date -r "$1" '+%Y-%m-%d %H:%M:%S' 2>/dev/null
}

# Epoch to Turkey time. Turkey keeps UTC+3 all year (since 2016). Adding the offset
# needs no zone file: date falls back to UTC without a warning when a zone file is
# missing, and the text would then show UTC with a "TR" label.
TR_OFFSET=10800
fmt_tr() { # epoch
    fmt_time "$(( $1 + TR_OFFSET ))" UTC
}

file_mtime() {
    local m
    m=$(stat -c %Y "$1" 2>/dev/null)
    if [ -n "$m" ]; then printf '%s' "$m"; return 0; fi
    m=$(stat -f %m "$1" 2>/dev/null)
    if [ -n "$m" ]; then printf '%s' "$m"; return 0; fi
    return 1
}

# Detail note D of a handoff H: <H without .md>.detay.md in the same folder. The handoff
# globs end in "-handoff-<id>.md", so D is never taken for a handoff. Same in context-pressure.sh.
detail_path() { # handoff path
    printf '%s' "${1%.md}.detay.md"
}

# Transcript dump X of a handoff: written by handoff-dump.py, never by the model.
dump_path() { # handoff path
    printf '%s' "$CFG/handoff-dumps/$(basename "${1%.md}").transcript.md"
}

# The required headings of D that the file lacks, joined by ", " (all of them when the
# file does not exist). Pure bash and grep: it works without python3.
detail_missing() { # detail note path
    local f="$1" h out
    out=""
    while IFS= read -r h; do
        [ -n "$h" ] || continue
        if [ ! -f "$f" ] || ! grep -q -x -F -- "$h" "$f" 2>/dev/null; then
            out="${out:+$out, }$h"
        fi
    done <<EOF
$DETAIL_HEADINGS
EOF
    printf '%s' "$out"
}

# Empty when D is complete, else "does not exist" or "misses sections: ...".
detail_state() { # detail note path
    local m
    m=$(detail_missing "$1")
    [ -n "$m" ] || return 0
    if [ -f "$1" ]; then printf 'misses sections: %s' "$m"; else printf 'does not exist'; fi
}

# The required headings of D, joined by ", ".
detail_headings_text() {
    detail_missing /nonexistent-detail-note
}

# The line after the title of H (and after "Son güncelleme:").
extras_line() { # handoff path
    printf 'Ek dosyalar: detay notu %s · tam döküm %s' "$(detail_path "$1")" "$(dump_path "$1")"
}

# The instructions for the detail note. Same text in context-pressure.sh.
detail_rules_text() { # detail path, dump path, session name
    printf '%s' "Detail note: write ${1} before the handoff. Its first line is '# ${3} — detay notu'. Then these sections, in this order, each as a line exactly like this: $(detail_headings_text). Write 'Yok.' under a section with nothing to report: never leave a heading out. The note holds everything that a fresh session on another account, or in Codex (which loads no memory), needs to go on without loss: every decision with its reason; the user's requests and corrections quoted in their own words; every open task and its exact state; background jobs and how to check them; what was tried and ruled out, and why; lessons learned; the full text of every memory file this session wrote or changed, and why; the environment (branches, commits, uncommitted files, machines, versions). It has no size limit. Write it in the user's language. Never put passwords, tokens or other secrets in it. Leave nothing out with an excuse. The full transcript dump ${2} is written by a hook: do not write it yourself."
}

# Run handoff-dump.py. Any failure is logged.
dump_run() { # transcript, out, title, project
    local err
    err=$(python3 "$DUMP_PY" --transcript "$1" --out "$2" --session "$sid" \
        --project "$4" --title "$3" --config "$CFG" 2>&1 >/dev/null </dev/null) \
        || log "handoff dump failed: $(clean "$err" 300)"
}

# Write the transcript dump of this session's handoff. It runs in the background, unless
# HANDOFF_DUMP_SYNC=1. No python3, no script or no transcript: logged once per session.
start_dump() {
    local t x title pr
    t="$tpath"
    [ -n "$t" ] || t=$(sget transcript)
    if ! command -v python3 >/dev/null 2>&1 || [ ! -f "$DUMP_PY" ] || [ -z "$t" ] || [ ! -r "$t" ]; then
        if [ -z "$(sget dump_skip_logged)" ]; then
            sset dump_skip_logged 1
            log "handoff dump skipped for $sid: python3, $(clean "$DUMP_PY" 160) or a readable transcript is missing"
        fi
        return 0
    fi
    x=$(dump_path "$handoff")
    title=$(sget title)
    pr=$(sget proj)
    [ -n "$pr" ] || pr="$proj"
    if [ "${HANDOFF_DUMP_SYNC:-}" = "1" ]; then
        dump_run "$t" "$x" "$title" "$pr"
    else
        ( dump_run "$t" "$x" "$title" "$pr" ) >/dev/null 2>&1 </dev/null &
    fi
    return 0
}

proj_name() {
    local b n
    b="${1%/}"
    b="${b##*/}"
    n=$(printf '%s' "$b" | tr -c 'A-Za-z0-9_-' '_' | cut -c1-40)
    [ -n "$n" ] || n="proje"
    printf '%s' "$n"
}

jget() {
    jq -r --arg k "$1" '
        if type == "object" then
            (.[$k] | if type == "string" or type == "number" then tostring else empty end)
        else empty end' <<<"$input"
}

# Setting: environment variable first, then the conf file, then the default.
conf() { # key, default
    local v
    v="${!1:-}"
    if [ -z "$v" ] && [ -f "$UL_CONF" ]; then
        v=$(awk -F= -v k="$1" '$1 == k { sub(/^[^=]*=/, ""); print; exit }' "$UL_CONF" 2>/dev/null \
            | tr -d '\r')
    fi
    [ -n "$v" ] || v="$2"
    printf '%s' "$v"
}

conf_num() { # key, default, min, max
    local v re
    re='^[0-9]+$'
    v=$(conf "$1" "$2")
    if ! [[ $v =~ $re ]] || [ "${#v}" -gt 6 ]; then
        log "invalid $1 '$(clean "$v" 20)', using $2"
        printf '%s' "$2"
        return 0
    fi
    # 10#: a leading zero must not turn "010" into octal 8 in later arithmetic.
    v=$(( 10#$v ))
    if [ "$v" -lt "$3" ] || [ "$v" -gt "$4" ]; then
        log "$1=$v out of range $3-$4, using $2"
        v="$2"
    fi
    printf '%s' "$v"
}

# Per-session values: one small file per key.
sget() { cat "$SDIR/$1" 2>/dev/null; }
sset() {
    mkdir -p "$SDIR" 2>/dev/null
    printf '%s' "$2" > "$SDIR/$1.tmp.$$" && mv -f "$SDIR/$1.tmp.$$" "$SDIR/$1"
}
sdel() { rm -f "$SDIR/$1"; }

claim_poll() {
    local lockd owner osid ots
    lockd="$ADIR/poll.lock"
    mkdir -p "$ADIR" 2>/dev/null
    if mkdir "$lockd" 2>/dev/null; then
        printf '%s %s\n' "$sid" "$now" > "$lockd/owner"
        sset poll_asked "$now"
        return 0
    fi
    owner=$(cat "$lockd/owner" 2>/dev/null)
    osid="${owner%% *}"
    ots="${owner##* }"
    # No owner yet: the claimer is between its mkdir and its write. The directory's own
    # mtime is then the lock's age, so a fresh lock is never taken over.
    [ -n "$owner" ] || ots=$(file_mtime "$lockd")
    [ -n "$osid" ] && [ "$osid" = "$sid" ] && return 0
    [[ $ots =~ $re_num ]] || ots=0
    if [ $(( now - ots )) -gt "$LOCK_STALE_S" ]; then
        rm -f "$lockd/owner"
        rmdir "$lockd" 2>/dev/null
        if mkdir "$lockd" 2>/dev/null; then
            printf '%s %s\n' "$sid" "$now" > "$lockd/owner"
            sset poll_asked "$now"
            log "stale poll lock of $(clean "$osid" 12) taken over by $sid"
            return 0
        fi
    fi
    return 1
}

release_poll() {
    rm -f "$ADIR/poll.lock/owner"
    rmdir "$ADIR/poll.lock" 2>/dev/null
}

# Release the poll lock only when this session holds it (the fail-open path). A reading
# releases it for everyone through release_poll, because the poll is then answered.
release_own_poll() {
    local owner
    owner=$(cat "$ADIR/poll.lock/owner" 2>/dev/null)
    [ "${owner%% *}" = "$sid" ] && release_poll
    return 0
}

# The PostToolBatch input has a get_usage call.
batch_has_usage() {
    printf '%s' "$input" | jq -e --arg t "$TOOL_USAGE" \
        'any(.tool_calls[]?; (.tool_name // "") == $t)' >/dev/null 2>&1
}

# Without both workspace and account ids a reading cannot be tied to one plan, and a stop
# could hit the sessions of another workspace or account. The guard is off in such a
# session. It logs that once and tells the user once, on the first prompt.
noid_notice() {
    local d
    d="$UL_STATE/unknown/sessions/$sid"
    mkdir -p "$d" 2>/dev/null && chmod 700 "$UL_STATE" "$UL_STATE/unknown" 2>/dev/null
    if [ ! -f "$d/logged" ]; then
        printf '%s' "$now" > "$d/logged" 2>/dev/null
        log "no workspace or account id in session $sid: guard off in this session"
    fi
    [ "$ev" = "UserPromptSubmit" ] || return 0
    [ -f "$d/noted" ] && return 0
    printf '%s' "$now" > "$d/noted" 2>/dev/null
    emit "$(jq -n -c '{systemMessage: "Kullanım limiti koruması bu oturumda kapalı: workspace veya hesap kimliği yok (CLAUDE_CODE_ORGANIZATION_UUID, CLAUDE_CODE_ACCOUNT_UUID)."}')"
}

load_usage() {
    local u
    five_pct=0; five_reset=0; week_pct=0; week_reset=0; usage_ts=0
    if [ -f "$ADIR/usage.json" ]; then
        u=$(jq -r '[(.ts // 0), (.five.pct // 0), (.five.reset // 0), (.week.pct // 0), (.week.reset // 0)]
                   | map(tostring) | join(" ")' "$ADIR/usage.json" 2>/dev/null)
        set -- $u
        [[ ${1:-} =~ $re_num ]] && usage_ts="$1"
        [[ ${2:-} =~ $re_num ]] && five_pct="$2"
        [[ ${3:-} =~ $re_num ]] && five_reset="$3"
        [[ ${4:-} =~ $re_num ]] && week_pct="$4"
        [[ ${5:-} =~ $re_num ]] && week_reset="$5"
    fi
    load_feed
}

# The usage-feed mod's file (G04). Used only when it is newer than usage.json, owned by
# this user, of source "mod", and not from the future. The mod reads a window up to one
# point below get_usage (measured 2026-10-27: 4/5, 5/6, 22/23, never above), so 1 is added
# to both windows: a stop can come one point early, never late.
load_feed() {
    local f u v
    f="$FEED_DIR/feed-$acct.json"
    [ -f "$f" ] && [ -O "$f" ] || return 0
    u=$(jq -r 'select(.source == "mod")
               | [(.ts // 0), (.five.pct // 0), (.five.reset // 0), (.week.pct // 0), (.week.reset // 0)]
               | map(floor | tostring) | join(" ")' "$f" 2>/dev/null)
    set -- $u
    [ $# -eq 5 ] || return 0
    for v in "$@"; do [[ $v =~ $re_num ]] || return 0; done
    [ "$1" -gt "$usage_ts" ] || return 0
    [ "$1" -le $(( now + 60 )) ] || return 0
    usage_ts="$1"
    five_pct=$(( $2 + 1 )); five_reset="$3"
    week_pct=$(( $4 + 1 )); week_reset="$5"
    [ "$five_pct" -le 100 ] || five_pct=100
    [ "$week_pct" -le 100 ] || week_pct=100
    if [ -z "$(sget feed_used)" ]; then
        sset feed_used "$now"
        log "usage feed of the mod used by $sid: 5h=${five_pct}% week=${week_pct}% (+1 included)"
    fi
}

# Sets: stage (0, 1 or 2), five_stage, week_stage, limit_text, limit_pct, limit_reset (the
# later reset of the windows that count).
eval_stage() {
    stage=0; limit_text=""; limit_pct=0; limit_reset=0
    five_stage=$(win_stage "$five_pct" "$five_reset")
    week_stage=$(win_stage "$week_pct" "$week_reset")
    add_window "$five_pct" "$five_reset" "5 saatlik limit"
    add_window "$week_pct" "$week_reset" "haftalık limit"
}

win_stage() { # pct, reset epoch -> 0, 1 or 2
    if [ "$now" -lt "$2" ] && [ "$1" -ge "$S1" ]; then
        if [ "$1" -ge "$S2" ]; then printf '2'; else printf '1'; fi
    else
        printf '0'
    fi
}

add_window() { # pct, reset epoch, label
    local s
    [ "$now" -lt "$2" ] || return 0
    [ "$1" -ge "$S1" ] || return 0
    s=1
    [ "$1" -ge "$S2" ] && s=2
    [ "$s" -gt "$stage" ] && stage="$s"
    [ "$1" -gt "$limit_pct" ] && limit_pct="$1"
    [ "$2" -gt "$limit_reset" ] && limit_reset="$2"
    if [ -n "$limit_text" ]; then
        limit_text="$limit_text, $3 %$1"
    else
        limit_text="$3 %$1"
    fi
    return 0
}

# The session name the user sees in the app. Order: the payload's session_title, the
# newest customTitle record of the transcript (the sidebar title, renames included),
# CLAUDE_CODE_SESSION_NAME (set by the Desktop app at launch, seen in SSH sessions),
# the newest aiTitle record. Empty when none is set. Same function in context-pressure.sh.
session_title() { # transcript path
    local t m
    t=$(jget session_title)
    if [ -z "$t" ] && [ -n "$1" ] && [ -r "$1" ]; then
        m=$(grep -o '"customTitle":"[^"]*"' "$1" 2>/dev/null | tail -n 1)
        [ -n "$m" ] && t=$(printf '{%s}' "$m" | jq -r '.customTitle // empty' 2>/dev/null)
    fi
    [ -n "$t" ] || t="${CLAUDE_CODE_SESSION_NAME:-}"
    if [ -z "$t" ] && [ -n "$1" ] && [ -r "$1" ]; then
        m=$(grep -o '"aiTitle":"[^"]*"' "$1" 2>/dev/null | tail -n 1)
        [ -n "$m" ] && t=$(printf '{%s}' "$m" | jq -r '.aiTitle // empty' 2>/dev/null)
    fi
    printf '%s' "$t" | LC_ALL=C tr -d '\000-\037\177'
}

# Session name to the first part of the handoff file name: Turkish letters to ASCII,
# every other character outside A-Z a-z 0-9 _ - to "-", case kept, at most 50
# characters. Without a session name: the project folder name.
name_part() { # session name, project dir
    local s
    s=$(printf '%s' "$1" | sed -e 's/ç/c/g' -e 's/Ç/C/g' -e 's/ğ/g/g' -e 's/Ğ/G/g' \
        -e 's/ı/i/g' -e 's/İ/I/g' -e 's/ö/o/g' -e 's/Ö/O/g' -e 's/ş/s/g' -e 's/Ş/S/g' \
        -e 's/ü/u/g' -e 's/Ü/U/g' | LC_ALL=C tr -c 'A-Za-z0-9_-' '-' | tr -s '-' | cut -c1-50)
    while [ "${s#-}" != "$s" ]; do s="${s#-}"; done
    while [ "${s%-}" != "$s" ]; do s="${s%-}"; done
    [ -n "$s" ] || s=$(proj_name "$2")
    printf '%s' "$s"
}

# Handoff path of a session: <project>/.claude/<name part>-handoff-<session id>.md.
# The hooks find the file by session id. A file of this session under another name (an
# older session name, the project folder name, or the older handoff-<session id>.md) is
# renamed to this path, so the file follows the name in the app. When the target
# exists too, nothing is renamed. Same function in context-pressure.sh.
resolve_handoff() { # project dir, name part, session id
    local want f have ht t
    want="$1/.claude/$2-handoff-$3.md"
    have=""
    ht=-1
    for f in "$1/.claude/"*-handoff-"$3".md "$1/.claude/handoff-$3.md"; do
        [ -f "$f" ] && [ "$f" != "$want" ] || continue
        t=$(file_mtime "$f")
        case "$t" in ''|*[!0-9]*) t=0 ;; esac
        if [ "$t" -gt "$ht" ]; then have="$f"; ht="$t"; fi
    done
    if [ -n "$have" ] && [ ! -e "$want" ]; then
        if mv "$have" "$want" 2>/dev/null; then
            log "handoff renamed to the session name: $(clean "${have##*/}" 120) -> $(clean "${want##*/}" 120)"
            # The detail note follows its handoff.
            if [ -f "$(detail_path "$have")" ] && [ ! -e "$(detail_path "$want")" ]; then
                mv "$(detail_path "$have")" "$(detail_path "$want")" 2>/dev/null \
                    || log "could not rename the detail note of $(clean "${have##*/}" 120)"
            fi
        else
            log "could not rename handoff $(clean "$have" 200)"
            want="$have"
        fi
    fi
    printf '%s' "$want"
}

# Assign this session's handoff path once per limit event. Same path as
# context-pressure.sh, so both hooks write one file per session.
ensure_handoff() {
    local title
    handoff=$(sget handoff)
    [ -n "$handoff" ] && return 0
    title=$(session_title "$tpath")
    handoff=$(resolve_handoff "$proj" "$(name_part "$title" "$proj")" "$sid")
    mkdir -p "$proj/.claude" 2>/dev/null
    sset handoff "$handoff"
    sset title "${title:-$(proj_name "$proj")-${sid%%-*}}"
    sset proj "$proj"
    [ -n "$tpath" ] && sset transcript "$tpath"
    # Pending marker for handoff-load.sh (group A): after /clear it lists this handoff
    # even when no exact match is possible.
    phash=$(sha1_16 "$proj")
    mkdir -p "$PENDING_DIR/$phash" 2>/dev/null \
        && chmod 700 "$PENDING_DIR" "$PENDING_DIR/$phash" 2>/dev/null
    printf '%s\n' "$now" > "$PENDING_DIR/$phash/$sid" 2>/dev/null || log "could not write pending marker"
    log "limit: session $sid handoff $handoff (${limit_text})"
}

# Draft path of the handoff for a Desktop worktree session, or nothing.
# Such a session runs in <project>/.claude/worktrees/<name> (or below it). The app
# refuses Write and Edit of files in <project>/.claude/ from there, and a stop blocks
# Bash, so the handoff could not be written at all. The session writes the draft in the
# worktree's own .claude/ folder instead. PostToolUse copies it to the handoff path and
# removes it, so the draft does not stay in the worktree.
draft_of() { # target path: the handoff or its detail note
    local rest
    [ -n "$1" ] && [ -n "$cwd" ] || return 0
    case "$cwd" in "$proj"/.claude/worktrees/?*) ;; *) return 0 ;; esac
    rest="${cwd#"$proj"/.claude/worktrees/}"
    printf '%s' "$proj/.claude/worktrees/${rest%%/*}/.claude/${1##*/}"
}

draft_path() {
    draft_of "$handoff"
}

# The sentence about the drafts for the texts to the model, or nothing. The detail note
# gets a draft in the same folder, named like the note.
draft_text() {
    local d dd
    d=$(draft_path)
    [ -n "$d" ] || return 0
    dd=$(draft_of "$(detail_path "$handoff")")
    printf '%s' " This session runs in a worktree: the app refuses Write and Edit of that path. Write the whole handoff to ${d} instead. A hook copies it to ${handoff} and removes the draft. The detail note works the same way: write it to ${dd}; a hook copies it to $(detail_path "$handoff") and removes the draft."
}

# A session without any assistant record started after the stage was reached.
is_new_session() {
    if [ -z "$tpath" ] || [ ! -f "$tpath" ]; then return 0; fi
    if grep -q '"type":"assistant"' "$tpath" 2>/dev/null; then return 1; fi
    return 0
}

# Stop flags are kept per stage and window: stop<n>_five and stop<n>_week hold
# "<active|done|skipped> <reset epoch of that window>". A flag whose epoch is more than
# RESET_TOL_S away from the window's current reset belongs to an earlier window and
# counts as unset, so the stops of a new window are armed again, also when the other
# window stays high.
flag_state() { # n, window, current reset epoch -> active, done, skipped or empty
    local f r d
    f=$(sget "stop${1}_${2}")
    [ -n "$f" ] || return 0
    r="${f#* }"
    [[ $r =~ $re_num ]] || return 0
    d=$(( r - $3 ))
    [ "$d" -lt 0 ] && d=$(( -d ))
    [ "$d" -le "$RESET_TOL_S" ] && printf '%s' "${f%% *}"
    return 0
}

# Set every unset flag of the windows that count to "<state> <reset epoch>".
arm_flags() { # state
    local w n r s
    for w in five week; do
        if [ "$w" = five ]; then s="$five_stage"; r="$five_reset"; else s="$week_stage"; r="$week_reset"; fi
        n=1
        while [ "$n" -le "$s" ]; do
            [ -n "$(flag_state "$n" "$w" "$r")" ] || sset "stop${n}_${w}" "$1 $r"
            n=$(( n + 1 ))
        done
    done
}

# Sets stopping=1 when this session has a stop to do now. One stop covers every stage
# reached so far, so a jump from below STOP1 to above STOP2 stops only once.
decide_stop() {
    local w n f r s unset_found
    stopping=0
    unset_found=0
    for w in five week; do
        if [ "$w" = five ]; then s="$five_stage"; r="$five_reset"; else s="$week_stage"; r="$week_reset"; fi
        n=1
        while [ "$n" -le "$s" ]; do
            f=$(flag_state "$n" "$w" "$r")
            [ "$f" = "active" ] && stopping=1
            [ -z "$f" ] && unset_found=1
            n=$(( n + 1 ))
        done
    done
    [ "$stopping" -eq 1 ] && return 0
    [ "$unset_found" -eq 1 ] || return 0
    if is_new_session; then
        arm_flags skipped
        log "limit: session $sid started at stage $stage: warnings only, no stop"
        return 0
    fi
    arm_flags active
    sdel written
    stopping=1
    ensure_handoff
    log "limit: stop $stage of 2 for session $sid (${limit_text})"
}

finish_stop() {
    local w n f
    for w in five week; do
        n=1
        while [ "$n" -le 2 ]; do
            f=$(sget "stop${n}_${w}")
            case "$f" in active\ *) sset "stop${n}_${w}" "done ${f#* }" ;; esac
            n=$(( n + 1 ))
        done
    done
    return 0
}

# Files the next session should read, one per line.
related_files() { # project dir, transcript path, handoff path
    local p="$1" t="$2" f
    printf '%s\n' "$3"
    for f in "$p"/.claude/*handoff*"$sid"*.md; do
        [ -f "$f" ] && [ "$f" != "$3" ] && printf '%s\n' "$f"
    done
    if [ -n "$t" ] && [ -f "${t%/*}/memory/MEMORY.md" ]; then
        printf '%s\n' "${t%/*}/memory/MEMORY.md"
    fi
    for f in "$CFG/CLAUDE.md" "$p/CLAUDE.md" "$p/.claude/CLAUDE.md"; do
        [ -f "$f" ] && printf '%s\n' "$f"
    done
    [ -n "$t" ] && [ -f "$t" ] && printf '%s\n' "$t"
}

# The prompt for a session on the other account. It carries the whole handoff, so it is
# self-contained (it also works when the other account runs on another disk), and then
# lists the files to read for more detail.
build_prompt() {
    local files n line out body size note detail dbody dnote
    files=$(related_files "$(sget proj)" "$(sget transcript)" "$handoff")
    detail=$(detail_path "$handoff")
    body=""
    note=""
    dbody=""
    dnote=""
    if [ -f "$handoff" ]; then
        body=$(head -c "$HANDOFF_CUT_BYTES" "$handoff" 2>/dev/null | iconv -c -f UTF-8 -t UTF-8 2>/dev/null)
        size=$(wc -c < "$handoff" 2>/dev/null | tr -d ' ')
        [[ $size =~ $re_num ]] && [ "$size" -gt "$HANDOFF_CUT_BYTES" ] \
            && note="
(Devir notu uzun: burada ilk ${HANDOFF_CUT_BYTES} bayt var. Tamamı dosyada.)"
    fi
    if [ -f "$detail" ]; then
        dbody=$(head -c "$DETAIL_CUT_BYTES" "$detail" 2>/dev/null | iconv -c -f UTF-8 -t UTF-8 2>/dev/null)
        size=$(wc -c < "$detail" 2>/dev/null | tr -d ' ')
        [[ $size =~ $re_num ]] && [ "$size" -gt "$DETAIL_CUT_BYTES" ] \
            && dnote="
(Detay notu uzun: burada ilk ${DETAIL_CUT_BYTES} bayt var. Tamamı dosyada.)"
    fi
    out="Önceki oturumun işine devam ediyorum. Önceki oturum kullanım limiti eşiğinde durdu.
Oturum: $(sget title) · Proje: $(sget proj)
Aşağıda önceki oturumun devir notunun ve detay notunun tamamı var. Önce ikisini de oku.

--- DEVİR NOTU BAŞI (${handoff}) ---
${body:-(Devir notu henüz yazılmadı.)}${note}
--- DEVİR NOTU SONU ---

--- DETAY NOTU BAŞI (${detail}) ---
${dbody:-(Detay notu henüz yazılmadı.)}${dnote}
--- DETAY NOTU SONU ---

Tam transcript dökümü (bir hook yazdı, model yazmadı): $(dump_path "$handoff")
Notlarda bir ayrıntı eksikse önce bu dökümde ara.

Ayrıntı gerekirse şu dosyaları da oku:"
    n=0
    while IFS= read -r line; do
        [ -n "$line" ] || continue
        n=$(( n + 1 ))
        out="$out
$n. $line"
    done <<EOF
$files
EOF
    out="$out
Transcript (.jsonl) yalnız ayrıntı gerekirse okunur.
Sonra devir notundaki READ FIRST bölümünü özetle: yarım kalan iş, açık işler, tek sonraki adım.
Prod veya geri alınamaz adımları onayım olmadan çalıştırma. Onayımı bekle."
    printf '%s' "$out"
}

# Where the copyable prompt of this session's handoff is kept.
prompt_file() {
    printf '%s' "$UL_INDEX_DIR/$(basename "$handoff" .md).prompt.txt"
}

write_prompt_file() {
    local pf
    pf=$(prompt_file)
    mkdir -p "$UL_INDEX_DIR" 2>/dev/null
    if build_prompt > "$pf.tmp.$$" 2>/dev/null && mv -f "$pf.tmp.$$" "$pf" 2>/dev/null; then
        sset prompt_ok 1
        return 0
    fi
    # An older prompt file must not be handed out as the current one.
    rm -f "$pf.tmp.$$" 2>/dev/null
    sset prompt_ok 0
    return 1
}

stamp_handoff() {
    local tst
    [ -f "$handoff" ] || return 1
    # The user reads this line: Turkey time with "TR", no UTC. The "Ek dosyalar" line
    # (detail note and dump) follows it. An older line of either kind is replaced.
    tst=$(fmt_tr "$now")
    awk -v line="Son güncelleme: $tst TR" -v extra="$(extras_line "$handoff")" '
        NR == 1 { print; print line; print extra; next }
        /^Son güncelleme:/ { next }
        /^Ek dosyalar:/ { next }
        { print }' "$handoff" > "$handoff.tmp.$$" 2>/dev/null \
        && cat "$handoff.tmp.$$" > "$handoff" && rm -f "$handoff.tmp.$$"
}

# Copies of handoffs expire (B17). A limit handoff leaves a copy of its text in
# <index dir>/<handoff>.prompt.txt and an index entry (from <state>/<account>/sessions/<id>).
# Once a day, the state of a session whose handoff was written more than
# HANDOFF_COPY_TTL_DAYS days ago is removed with its prompt file, and prompt files of
# that age without a state are removed too. The handoff file itself stays: it is the
# user's file in the project. The index is built again afterwards.
prune_copies() {
    local ttl stamp t d w h f pf
    ttl=$(( $(conf_num HANDOFF_COPY_TTL_DAYS 7 1 365) * 86400 ))
    stamp="$UL_STATE/prune.stamp"
    t=$(file_mtime "$stamp" 2>/dev/null)
    [[ $t =~ ^[0-9]+$ ]] || t=0
    [ "$(( now - t ))" -lt 86400 ] && return 0
    mkdir -p "$UL_STATE" 2>/dev/null && touch "$stamp" 2>/dev/null
    for d in "$UL_STATE"/*/sessions/*; do
        [ -d "$d" ] || continue
        w=$(cat "$d/written" 2>/dev/null)
        [[ $w =~ ^[0-9]+$ ]] || continue
        [ "$(( now - w ))" -gt "$ttl" ] || continue
        h=$(cat "$d/handoff" 2>/dev/null)
        if [ -n "$h" ]; then
            pf="$UL_INDEX_DIR/$(basename "$h" .md).prompt.txt"
            rm -f "$pf" 2>/dev/null
        fi
        for f in "$d"/* "$d"/.[!.]*; do
            [ -f "$f" ] && rm -f "$f" 2>/dev/null
        done
        rmdir "$d" 2>/dev/null
        log "copies of an old handoff removed: $(clean "${h##*/}" 120)"
    done
    for f in "$UL_INDEX_DIR"/*.prompt.txt; do
        [ -f "$f" ] || continue
        t=$(file_mtime "$f" 2>/dev/null)
        [[ $t =~ ^[0-9]+$ ]] || continue
        [ "$(( now - t ))" -gt "$ttl" ] && rm -f "$f" 2>/dev/null
    done
    rebuild_index || log "could not rebuild the limit index"
    return 0
}

# One index for the whole machine: every workspace and account under UL_STATE. Each run
# rebuilds it from all of them, so a write from one account never drops the others.
rebuild_index() {
    local d h t p w r a out
    mkdir -p "$UL_INDEX_DIR" 2>/dev/null || return 1
    out="# Limit devir dizini
Bu makinedeki bütün workspace ve hesaplar. Güncel: $(fmt_tr "$(date +%s)") TR
"
    for d in "$UL_STATE"/*/sessions/*; do
        [ -d "$d" ] || continue
        w=$(cat "$d/written" 2>/dev/null)
        [ -n "$w" ] || continue
        a="${d%/sessions/*}"
        a="${a##*/}"
        h=$(cat "$d/handoff" 2>/dev/null)
        t=$(cat "$d/title" 2>/dev/null)
        p=$(cat "$d/proj" 2>/dev/null)
        r=$(cat "$d/reason" 2>/dev/null)
        out="$out
## ${t} (${p})
- Workspace/hesap: ${a%%-*}… · Sebep: ${r}
- Devir notu: ${h}
- Prompt (kopyala, yeni oturuma yapıştır): Önceki oturumun işine devam ediyorum. ${h} devir notunu ve bağlı detay notunu tamamen oku. READ FIRST bölümünü özetle ve onayımı bekle.
- Uzun sürüm (notun tamamı): ${UL_INDEX_DIR}/$(basename "$h" .md).prompt.txt
- Son yazım: $(fmt_tr "$w") TR
"
    done
    out="$out
Kısa prompt o oturumun son cevabında da verilir. Uzun sürüm devir notunun tamamını içerir.
"
    printf '%s' "$out" > "$UL_INDEX_DIR/INDEX.md.tmp.$$" \
        && mv -f "$UL_INDEX_DIR/INDEX.md.tmp.$$" "$UL_INDEX_DIR/INDEX.md"
}

emit() { # json built by the caller
    printf '%s\n' "$1"
}

ctx_json() { # event, context, [system message]
    jq -n -c --arg e "$1" --arg c "$2" --arg s "${3:-}" \
        '{hookSpecificOutput: {hookEventName: $e, additionalContext: $c}}
         + (if $s == "" then {} else {systemMessage: $s} end)'
}

deny_json() { # reason
    jq -n -c --arg r "$1" \
        '{hookSpecificOutput: {hookEventName: "PreToolUse", permissionDecision: "deny", permissionDecisionReason: $r}}'
}

poll_text() {
    printf '%s' "Usage check required by a hook: before any other tool, load and call the plan-usage tool. Step 1: ToolSearch with query \"select:${TOOL_USAGE}\" (skip if already loaded). Step 2: call ${TOOL_USAGE} with no arguments. If that call fails or times out, do not call it again: continue the current work. The hook does not block other tools after a failed call. A hook records the result; you do not need to write it anywhere or mention it to the user. Then continue the current work."
}

reset_tr() { fmt_tr "$limit_reset"; }

warn_line() {
    local pf more
    pf=$(prompt_file)
    if [ -f "$pf" ] && [ "$(sget prompt_ok)" != "0" ]; then
        more="Uzun sürüm (notun tamamı, başka diskte gerekirse): $pf"
    else
        more="Uzun sürüm dosyası yok: devir notunu doğrudan kullan."
    fi
    printf '%s' "⚠️ Kullanım limiti eşiği aşıldı: ${limit_text} (sıfırlanma $(reset_tr) TR). $(stop_pcts_text) Limiti dolmamış başka bir hesap varsa onunla yeni oturum aç ve aşağıdaki prompt'u yapıştır. Aynı hesapla devam etmek için bu oturumda tekrar yaz. ${more}"
}

# The thresholds in the warning, so a lowered test value is not read as a full limit.
stop_pcts_text() {
    if [ "$S1" -eq 91 ] && [ "$S2" -eq 96 ]; then
        printf '%s' "Durak eşikleri: %${S1} ve %${S2}."
    else
        printf '%s' "Durak eşikleri: %${S1} ve %${S2} (varsayılan %91 ve %96, ayar: usage-limit.conf)."
    fi
}

# The prompt the user pastes into a new session (another account or the same one). It is
# read-only until the user approves, so pasting it twice does no harm.
short_prompt() {
    # Same text as the prompt of /oturum (local-mods/oturum/bin/sessions.py handoff_prompt).
    printf '%s' "Önceki oturumun işine devam ediyorum. ${handoff} devir notunu ve bağlı detay notunu tamamen oku. READ FIRST bölümünü özetle ve onayımı bekle."
}

# The session name for the new session: the name the app shows, else the project folder.
block_title() {
    local t
    t=$(sget title)
    [ -n "$t" ] || t=$(proj_name "$proj")
    printf '%s' "$t"
}

# Warning line, then two code blocks the user copies one by one (2026-11-23): the session
# name and the prompt. The format string is in single quotes: in double quotes bash would
# run the backticks.
warn_block() {
    printf '%s\n\nClaude oturum ismi:\n```text\n%s\n```\n\nPrompt:\n```text\n%s\n```' \
        "$(warn_line)" "$(block_title)" "$(short_prompt)"
}

show_text_model() {
    printf '%s' "Show the user this warning line and prompt block, verbatim, as the last thing in the reply. If a context-pressure note asks for a final CLEAR or COMPACT line, that line goes right before this block:
$(warn_block)"
}

handoff_rules() {
    printf '%s' "Write the detail note first, then the handoff.
$(detail_rules_text "$(detail_path "$handoff")" "$(dump_path "$handoff")" "$(sget title)")
Handoff: Line 1: '# $(sget title) — limit devir notu' (every handoff of this session starts with the session name the user sees in the app). Lines 2 and 3 are filled in by a hook ('Son güncelleme: …' and 'Ek dosyalar: …'); you may leave them out. Put one line in READ FIRST that tells the next session to read the detail note in full.
Sections, in this order: READ FIRST (what is in progress at this exact moment, half-done steps with exact file, line or command, anything waiting on the user, background jobs, watchers or long queries still running and how to check them, and the single next step), Goal, Done (verified only), Key decisions, Ruled out, File paths (absolute paths only). Keep it under 6000 characters and under 7000 bytes (check with wc -c; Turkish letters take 2 bytes), the same limit as the context-pressure handoff: after /clear the SessionStart hook injects only the first 8000 bytes, and the prompt for the other account carries the whole file, so it must stand on its own. Write in the user's language. Never put passwords, tokens or other secrets in it."
}

stop_text_model() {
    printf '%s' "USAGE LIMIT STOP ${stage} of 2 for this account: ${limit_text}, resets $(reset_tr) (Europe/Istanbul). Automatic stops happen when usage first passes ${S1}% and ${S2}%. Stop the current work now: do not start or continue any task and do not run commands. Write a complete handoff so that a session on another account can continue this work cold. File: ${handoff}$(draft_text)
$(handoff_rules)
Also save durable feedback or lessons from this session to memory (update an existing memory file instead of adding a duplicate).
Allowed now: Read, Grep, Glob, writing the detail note and that handoff file (or their worktree drafts) and memory files. A hook blocks everything else.
After the handoff is saved, a hook gives you a warning line and a short prompt for the user. Show them verbatim and end your reply. After this stop the user may continue in this session by writing again."
}

warn_text_model() {
    printf '%s' "USAGE ABOVE ${S1}% for this account: ${limit_text}, resets $(reset_tr) (Europe/Istanbul). Do the user's request normally. Before you end your reply, do two things:
1. Write or update the handoff ${handoff} so that it matches the current state (a hook stamps line 2).$(draft_text)
$(handoff_rules)
2. After the handoff is saved, end your reply as follows. $(show_text_model)"
}

main() {
    local tool fpath agent prompt_text interval maxpct age asked written n msg sys ov fo held cwd draft copied
    local detail ddraft dm dstate dhint dm_all
    re_sid='^[A-Za-z0-9_-]{1,128}$'
    re_num='^[0-9]+$'
    stopping=0
    now=$(date +%s)

    input=$(cat) || return
    if ! jq -e . >/dev/null 2>&1 <<<"$input"; then
        log "stdin is not valid JSON"
        return
    fi
    ev=$(jget hook_event_name)
    sid=$(jget session_id)
    if ! [[ $sid =~ $re_sid ]]; then
        log "invalid session_id on ${ev:-?}"
        return
    fi
    cwd=$(jget cwd)
    proj="${CLAUDE_PROJECT_DIR:-$cwd}"
    tpath=$(jget transcript_path)
    agent=$(jget agent_id)
    tool=$(jget tool_name)

    # One person has the same account id in two Team workspaces, so the workspace
    # (organization) id is part of the key: each workspace has its own plan limits.
    re_acct='^[A-Za-z0-9-]{8,64}$'
    org="${CLAUDE_CODE_ORGANIZATION_UUID:-}"
    acc="${CLAUDE_CODE_ACCOUNT_UUID:-}"
    [[ $org =~ $re_acct ]] || org=""
    [[ $acc =~ $re_acct ]] || acc=""
    if [ -z "$org" ] || [ -z "$acc" ]; then
        noid_notice
        return
    fi
    acct="${org}_${acc}"
    ADIR="$UL_STATE/$acct"
    SDIR="$ADIR/sessions/$sid"
    mkdir -p "$ADIR/sessions" 2>/dev/null && chmod 700 "$UL_STATE" "$ADIR" 2>/dev/null

    S1=$(conf_num STOP1_PCT 91 1 100)
    S2=$(conf_num STOP2_PCT 96 1 101)
    if [ "$S2" -lt "$S1" ]; then
        log "STOP2_PCT $S2 below STOP1_PCT $S1, using $S1"
        S2="$S1"
    fi
    PLOW=$(conf_num POLL_LOW_MIN 10 1 1440)
    PHIGH=$(conf_num POLL_HIGH_MIN 2 1 1440)
    PFROM=$(conf_num POLL_HIGH_FROM_PCT 75 0 100)
    ONLY=$(conf ONLY_SESSIONS "")
    OVW=$(conf OVERRIDE_WORD "#limit-devam")

    [ "$ev" = "UserPromptSubmit" ] && prune_copies

    # Record a get_usage result from any session of the account (also outside ONLY_SESSIONS).
    if [ "$ev" = "PostToolUse" ] && [ "$tool" = "$TOOL_USAGE" ]; then
        record_usage
        return
    fi

    if [ -n "$ONLY" ]; then
        case " $ONLY " in *" $sid "*) ;; *) return ;; esac
    fi

    load_usage
    eval_stage

    # Limit over (window reset or a lower reading): forget this session's limit event.
    if [ "$stage" -eq 0 ] && { [ -n "$(sget stop1_five)$(sget stop1_week)" ] || [ -n "$(sget handoff)" ]; }; then
        sdel stop1_five; sdel stop2_five; sdel stop1_week; sdel stop2_week
        sdel written; sdel handoff; sdel title; sdel hold
        log "limit over for session $sid"
    fi

    maxpct="$five_pct"
    [ "$week_pct" -gt "$maxpct" ] && maxpct="$week_pct"
    interval=$(( PLOW * 60 ))
    [ "$maxpct" -ge "$PFROM" ] && interval=$(( PHIGH * 60 ))
    age=$(( now - usage_ts ))

    case "$ev" in
    PreToolUse)
        case "$tool" in
            "$TOOL_USAGE")
                # The call counts also when it fails or times out later.
                sset usage_tried "$now"
                return ;;
            ToolSearch|SubagentHandback|mcp__ccd_turn__*) return ;;
        esac
        if [ "$stage" -ge 1 ]; then
            decide_stop
            if [ "$stopping" -eq 1 ] || [ -n "$(sget hold)" ]; then
                if [ -n "$agent" ]; then
                    emit "$(deny_json "Usage limit stop (${limit_text}). Stop now and return a short status report to the main agent.")"
                    return
                fi
                ensure_handoff
                case "$tool" in
                    Read|Grep|Glob|LS|NotebookRead) return ;;
                    Write|Edit|MultiEdit|NotebookEdit)
                        fpath=$(printf '%s' "$input" | jq -r '.tool_input.file_path // .tool_input.notebook_path // empty' 2>/dev/null)
                        if [ "$fpath" = "$handoff" ]; then return; fi
                        draft=$(draft_path)
                        if [ -n "$draft" ] && [ "$fpath" = "$draft" ]; then
                            mkdir -p "${draft%/*}" 2>/dev/null
                            return
                        fi
                        # The detail note and its worktree draft.
                        if [ "$fpath" = "$(detail_path "$handoff")" ]; then return; fi
                        ddraft=$(draft_of "$(detail_path "$handoff")")
                        if [ -n "$ddraft" ] && [ "$fpath" = "$ddraft" ]; then
                            mkdir -p "${ddraft%/*}" 2>/dev/null
                            return
                        fi
                        case "$fpath" in */.claude/projects/*/memory/*|"$CFG"/projects/*/memory/*) return ;; esac
                        ;;
                esac
                if [ "$stopping" -eq 1 ]; then
                    emit "$(deny_json "$(stop_text_model)")"
                else
                    emit "$(deny_json "The handoff for this usage-limit stop is saved. Do not do other work: show the warning line and the prompt to the user and end your reply.")"
                fi
                return
            fi
        fi
        asked=$(sget poll_asked)
        if [[ $asked =~ $re_num ]] && [ -z "$agent" ]; then
            if [ "$usage_ts" -ge "$asked" ]; then
                sdel poll_asked; sdel denials
                return
            fi
            # get_usage was called after the request: its result is still on the way (same
            # batch) or the call failed. PostToolBatch ends the poll in both cases.
            tried=$(sget usage_tried)
            if [[ $tried =~ $re_num ]] && [ "$tried" -ge "$asked" ]; then return; fi
            n=$(sget denials); [[ $n =~ $re_num ]] || n=0
            n=$(( n + 1 ))
            if [ "$n" -gt 3 ]; then
                fo=$(sget failopens); [[ $fo =~ $re_num ]] || fo=0
                fo=$(( fo + 1 ))
                sset failopens "$fo"
                sdel poll_asked; sdel denials
                release_own_poll
                if [ "$fo" -ge 2 ]; then
                    # The plan-usage tool is missing here (for example a terminal CLI
                    # session): stop asking for a day instead of every 30 minutes.
                    sset poll_off_until $(( now + 86400 ))
                    log "poll ignored again by $sid, fail-open for 24 h"
                else
                    sset poll_off_until $(( now + 1800 ))
                    log "poll ignored 3 times by $sid, fail-open for 30 min"
                fi
                return
            fi
            sset denials "$n"
            emit "$(deny_json "$(poll_text)")"
        fi
        return
        ;;
    PostToolUse)
        case "$tool" in Write|Edit|MultiEdit) ;; *) return ;; esac
        [ "$stage" -ge 1 ] || return
        handoff=$(sget handoff)
        [ -n "$handoff" ] || return
        fpath=$(printf '%s' "$input" | jq -r '.tool_input.file_path // empty' 2>/dev/null)
        copied=""
        # The detail note, or its worktree draft: copy the draft, check the headings.
        detail=$(detail_path "$handoff")
        ddraft=$(draft_of "$detail")
        if [ "$fpath" = "$detail" ] || { [ -n "$ddraft" ] && [ "$fpath" = "$ddraft" ]; }; then
            if [ "$fpath" != "$detail" ]; then
                [ -f "$ddraft" ] || return
                mkdir -p "${detail%/*}" 2>/dev/null
                if ! cat "$ddraft" > "$detail" 2>/dev/null; then
                    log "could not copy the draft $ddraft to $detail"
                    return
                fi
                rm -f "$ddraft"
                copied=" The hook copied $ddraft to $detail and removed the draft. To change the detail note later, Read $detail and Write the whole text to $ddraft again."
                log "limit: detail draft of $sid copied to $detail"
            fi
            [ -f "$handoff" ] && { write_prompt_file || log "could not write prompt file for $handoff"; }
            dm=$(detail_missing "$detail")
            if [ -n "$dm" ]; then
                msg="The detail note is saved: ${detail}.${copied} It still misses these sections: ${dm}. Add them now: every heading stands as its own line, with 'Yok.' under it when there is nothing to report."
            elif [ -z "$(sget written)" ]; then
                msg="The detail note is saved and complete: ${detail}.${copied} Now write the handoff ${handoff}.$(draft_text)"
            elif [ -n "$(sget hold)" ]; then
                msg="The detail note is saved and complete: ${detail}.${copied} Do not do any other work. $(show_text_model)
Then end your reply."
            else
                msg="The detail note is saved and complete: ${detail}.${copied} Finish the user's request, then end your reply. $(show_text_model)"
            fi
            log "limit: detail note written by $sid: $detail"
            emit "$(ctx_json PostToolUse "$msg" "Detay notu kaydedildi ($(fmt_tr "$(date +%s)" | cut -c12-) TR): ${detail##*/}")"
            return
        fi
        if [ "$fpath" != "$handoff" ]; then
            draft=$(draft_path)
            [ -n "$draft" ] && [ "$fpath" = "$draft" ] && [ -f "$draft" ] || return
            mkdir -p "${handoff%/*}" 2>/dev/null
            if ! cat "$draft" > "$handoff" 2>/dev/null; then
                log "could not copy the draft $draft to $handoff"
                return
            fi
            rm -f "$draft"
            copied=" The hook copied $draft to $handoff and removed the draft. To change the handoff later, Read $handoff and Write the whole text to $draft again."
            log "limit: draft of $sid copied to $handoff"
        fi
        stamp_handoff || log "could not stamp handoff $handoff"
        sset written "$now"
        sset reason "$limit_text"
        start_dump
        write_prompt_file || log "could not write prompt file for $handoff"
        rebuild_index || log "could not rebuild the limit index"
        dstate=$(detail_state "$detail")
        dhint=""
        if [ -n "$dstate" ]; then
            dm_all=$(detail_headings_text)
            dhint=" The detail note ${detail} ${dstate}: write it now, with every required heading (${dm_all}), 'Yok.' where there is nothing to report."
            [ -n "$ddraft" ] && dhint="${dhint} This session runs in a worktree: write it to ${ddraft}; a hook copies it."
        fi
        decide_stop
        if [ "$stopping" -eq 1 ]; then
            finish_stop
            sset hold 1
            log "limit: stop handoff written by $sid: $handoff"
            msg="The handoff is saved: ${handoff}.${copied} Do not do any other work${dstate:+ except the detail note}.${dhint} $(show_text_model)
Then end your reply."
            sys="Otomatik durak: devir notu kaydedildi ($(fmt_tr "$(date +%s)" | cut -c12-) TR): ${handoff##*/}. Bu oturumda devam etmek için tekrar yaz."
        else
            log "limit: handoff updated by $sid: $handoff"
            msg="The handoff is saved: ${handoff}.${copied}${dhint} Finish the user's request, then end your reply. $(show_text_model)"
            sys="Devir notu güncellendi ($(fmt_tr "$(date +%s)" | cut -c12-) TR): ${handoff##*/}"
        fi
        emit "$(ctx_json PostToolUse "$msg" "$sys")"
        return
        ;;
    PostToolBatch)
        [ -z "$agent" ] || return
        # A get_usage call in this batch, or since the poll request, gave no reading: the
        # call failed or timed out. End the poll and pause the polls, so that a session
        # whose app does not answer is not told again and again to call a failing tool.
        asked=$(sget poll_asked)
        if [[ $asked =~ $re_num ]] && [ "$usage_ts" -lt "$asked" ]; then
            tried=$(sget usage_tried)
            if { [[ $tried =~ $re_num ]] && [ "$tried" -ge "$asked" ]; } || batch_has_usage; then
                sdel poll_asked; sdel denials; sdel usage_tried
                release_own_poll
                sset poll_off_until $(( now + POLL_FAIL_OFF_S ))
                log "get_usage gave no reading in $sid (failed or timed out), polls paused for $(( POLL_FAIL_OFF_S / 60 )) min"
            fi
        fi
        if [ "$stage" -ge 1 ]; then
            decide_stop
            if [ "$stopping" -eq 1 ]; then
                # A later batch of the same stop: decide_stop did not load the handoff path.
                ensure_handoff
                emit "$(ctx_json PostToolBatch "$(stop_text_model)")"
                return
            fi
            if [ -n "$(sget hold)" ]; then
                handoff=$(sget handoff)
                # The batch that saved the handoff is not stopped: the model still has to
                # show the prompt that PostToolUse handed over. The next batch is stopped.
                if printf '%s' "$input" | jq -e --arg h "$handoff" --arg d "$(draft_path)" \
                    --arg dn "$(detail_path "$handoff")" --arg dd "$(draft_of "$(detail_path "$handoff")")" \
                    '[.tool_calls[]? | select((.tool_name // "") | test("^(Write|Edit|MultiEdit)$"))
                      | .tool_input.file_path] | any(.[]; . == $h or . == $dn or ($d != "" and . == $d) or ($dd != "" and . == $dd))' >/dev/null 2>&1; then
                    return
                fi
                jq -n -c --arg r "Otomatik durak: ${limit_text}. Devir notu: ${handoff}. Bu oturumda devam etmek için tekrar yaz.
$(warn_block)" '{continue: false, stopReason: $r}'
                log "limit: loop stopped for $sid"
                return
            fi
        fi
        ov=$(sget poll_off_until)
        if [[ $ov =~ $re_num ]] && [ "$now" -lt "$ov" ]; then return; fi
        if [ "$age" -gt "$interval" ] && claim_poll; then
            emit "$(ctx_json PostToolBatch "$(poll_text)")"
        fi
        return
        ;;
    UserPromptSubmit)
        prompt_text=$(jget prompt)
        # UserPromptSubmit also fires for turns the user did not type (a background
        # agent's result, a scheduled task, a message from another session), and the
        # payload has no field that tells them apart. The hold is lifted, but the model
        # gets the rule for such a turn.
        held=""
        [ -n "$(sget hold)" ] && held=1
        sdel hold
        msg=""
        sys=""
        if [ "$stage" -ge 1 ]; then
            decide_stop
            if [ "$stopping" -eq 1 ] && [ -n "$OVW" ]; then
                case "$prompt_text" in
                *"$OVW"*)
                    finish_stop
                    stopping=0
                    log "limit: stop skipped by $sid (${OVW})"
                    sys="Otomatik durak atlandı (${OVW}). Uyarılar sürüyor."
                    ;;
                esac
            fi
            ensure_handoff
            if [ "$stopping" -eq 1 ]; then
                msg="$(stop_text_model)
The user wrote a new message during this automatic stop. Start your reply with: '⏸️ Otomatik durak (${limit_text}): bu mesajı işlemedim. Tekrar yazarsan bu oturumda devam ederim.' Then write the handoff. Do not do the request itself."
                sys="⏸️ Otomatik durak: ${limit_text}. Devir notu yazılıyor. Bu oturumda devam etmek için tekrar yaz."
                emit "$(ctx_json UserPromptSubmit "$msg" "$sys")"
                return
            fi
            msg="$(warn_text_model)"
            [ -n "$sys" ] || sys="⚠️ Kullanım limiti eşiği aşıldı: ${limit_text}. $(stop_pcts_text)"
        fi
        ov=$(sget poll_off_until)
        if ! { [[ $ov =~ $re_num ]] && [ "$now" -lt "$ov" ]; }; then
            if [ "$age" -gt "$interval" ] && claim_poll; then
                if [ -n "$msg" ]; then msg="$(poll_text)

$msg"; else msg="$(poll_text)"; fi
            fi
        fi
        if [ -n "$held" ]; then
            msg="This turn comes right after an automatic usage-limit stop. It may not be the user's own message: UserPromptSubmit also fires for a background agent's result, a scheduled task and a message from another session. If this turn is not the user's own typed message, do not continue the stopped work: say in one line what arrived and end the reply. The user resumes the session by writing.${msg:+

$msg}"
        fi
        [ -n "$msg" ] || return
        emit "$(ctx_json UserPromptSubmit "$msg" "$sys")"
        return
        ;;
    esac
}

record_usage() {
    local txt parsed f5 r5 fw rw
    txt=$(printf '%s' "$input" | jq -r '
        .tool_response
        | if type == "array" then (map(select(type == "object" and .type == "text") | .text) | join(""))
          elif type == "string" then .
          elif type == "object" then (.text // tojson)
          else "" end' 2>/dev/null)
    parsed=$(printf '%s' "$txt" | jq -c '
        def ep: if type == "string" then (sub("\\.[0-9]+Z$"; "Z") | fromdateiso8601? // 0) else 0 end;
        def pc: if type == "number" then floor else 0 end;
        select(type == "object" and .plan.status == "ok")
        | (.plan.windows // []) as $w
        | ($w | map(select((.label // "") | test("^5-hour"; "i"))) | first) as $f
        | ($w | map(select((.label // "") | test("weekly.*all models"; "i"))) | first) as $k
        | select($f != null or $k != null)
        | {five: {pct: ($f.percentUsed | pc), reset: ($f.resetsAt | ep)},
           week: {pct: ($k.percentUsed | pc), reset: ($k.resetsAt | ep)},
           windows: $w}' 2>/dev/null)
    if [ -z "$parsed" ]; then
        log "get_usage result not usable in session $sid (status not ok or no windows)"
        sset poll_off_until $(( now + 1800 ))
        sdel poll_asked
        release_poll
        return
    fi
    mkdir -p "$ADIR" 2>/dev/null
    printf '%s' "$parsed" | jq -c --argjson ts "$now" --arg s "$sid" '. + {ts: $ts, by: $s}' \
        > "$ADIR/usage.json.tmp.$$" 2>/dev/null \
        && mv -f "$ADIR/usage.json.tmp.$$" "$ADIR/usage.json"
    sdel poll_asked
    sdel denials
    release_poll
    f5=$(printf '%s' "$parsed" | jq -r '.five.pct')
    fw=$(printf '%s' "$parsed" | jq -r '.week.pct')
    log "usage recorded by $sid: 5h=${f5}% week=${fw}%"
}

trim_log
main 2>>"$LOG"
exit 0
