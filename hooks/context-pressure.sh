#!/usr/bin/env bash
# UserPromptSubmit, PostToolBatch and Stop hook: warn Claude when the main-thread context
# gets large. The same script serves all three events and answers with the event name it
# was called for, so a long tool loop gets the warning without waiting for the next user
# prompt.
#
# TARGET: Linux and macOS, one file. Bash 3.2 compatible. It never branches on
# uname: it probes each tool (sha1sum or shasum, tac or tail -r).
#
# Reads the hook payload from stdin, finds the newest main-thread assistant
# record in the transcript tail, and sums its input tokens. When that total
# first enters a new 100K bucket above the threshold, it injects a note that
# asks Claude to save memory, then write a per-session handoff file:
#   <project>/.claude/<session name>-handoff-<session_id>.md
# and leaves a pending marker for that session. handoff-load.sh (SessionStart)
# reads the markers after the user types /clear. The session name is the name the
# app shows for the session (without one: the project folder name).
# Inside a bucket, each new 10K step gets a one-line size note, so the final
# CLEAR or COMPACT line can name the current context size.
#
# Threshold (2026-11-23): CTX_PRESSURE_THRESHOLD when set. Otherwise 300000 tokens, or
# CTX_PRESSURE_WINDOW_PCT (default 60) percent of the session's context window when that
# is lower. The window comes from the usage-feed mod (<config>/usage-feed/context-<id>.json);
# without the mod the threshold stays 300000, so a 200K window gets no warning.
#
# Handoff check (2026-11-07): once the pending marker exists, every reply that ends
# with the CLEAR or COMPACT line must update the handoff in the same turn. Each
# UserPromptSubmit of such a session stores the turn start (<state>/<session>.turn).
# On Stop, when the reply (last_assistant_message) holds the CLEAR or COMPACT line and
# the newest handoff of the session is older than the turn start (the stored time or
# the newest prompt or event record of the transcript, whichever is later), the hook
# sends the reply back once with decision "block". stop_hook_active stops a loop.
#
# Handoff time (2026-11-13): the CLEAR or COMPACT line names the handoff's last write
# time in Turkey time, as "handoff HH:MM". After the handoff request, each PostToolBatch
# that finds a newer write of the handoff (newer than the request and than the last
# note, <state>/<session>.hnote) tells Claude that time. On Stop, when the handoff was
# written in this turn but the line names no time or another time, the hook sends the
# reply back once with the right time. Turkey keeps UTC+3 all year (since 2016), so the
# hook adds TR_OFFSET and needs no zone file.
#
# Three files per handoff (2026-11-23): next to the handoff H sits a detail note D
# (<H without .md>.detay.md, written by the model, no size limit), and a hook writes a
# transcript dump X ($CFG/handoff-dumps/<H name>.transcript.md) with handoff-dump.py. A
# fresh session on another account, or Codex (which loads no memory), must go on without
# losing anything. D must hold the eight required headings (detail_missing). On a new write
# of H the hook adds the line "Ek dosyalar: ..." after the title, checks D and starts the
# dump. On Stop, a reply with the CLEAR or COMPACT line is also sent back once when D is
# missing or incomplete. The dump runs in the background (the hook timeout is short and a
# transcript can be tens of MB). HANDOFF_DUMP_SYNC=1 runs it in the foreground (tests).
# No python3, no handoff-dump.py or a dump error is logged and never stops the hook.
#
# Bulk handoff (2026-11-25): a message from another session (or the user) that holds the
# fixed marker [oturum:toplu-devir] asks this session for its handoff at once. On
# UserPromptSubmit the hook then needs no threshold: it creates the pending marker, writes
# the bulk flag (<state>/<session>.bulk) and the turn start, and sends the same rules,
# paths and later checks as the threshold request, under a "Bulk handoff request" header.
# The threshold reset (context below the threshold) keeps the pending marker, the turn file
# and the checks of such a turn while the bulk flag and the marker exist. The next
# UserPromptSubmit without the marker removes the bulk flag with the other files.
#
# No set -e and no ERR trap. Every path exits 0 and errors go to the log.

umask 077

CFG="${CLAUDE_CONFIG_DIR:-$HOME/.claude}"
LOG="$CFG/hooks/context-pressure.log"
STATE_DIR="${CTX_PRESSURE_STATE_DIR:-$CFG/hooks/state}"
PENDING_DIR="$STATE_DIR/pending.d"
BUCKET=100000
STEP=10000
TAIL_LINES=500
TR_OFFSET=10800
BULK_MARKER='[oturum:toplu-devir]'
HNOTE=""
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

mkdir -p "${LOG%/*}" 2>/dev/null

# Strip control characters and cap the length of a value before it is logged.
clean() {
    printf '%s' "$1" | tr -d '\000-\037\177' | cut -c1-"${2:-200}"
}

log() {
    printf '%s %s\n' "$(date -u +%FT%TZ)" "$*" >> "$LOG" 2>/dev/null
}

# Keep the log under 1 MB: when it is larger, keep the last 200 lines.
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

reverse_lines() {
    if command -v tac >/dev/null 2>&1; then tac; else tail -r; fi
}

# Project name for the handoff file name: last path segment, safe characters only.
proj_name() {
    local b n
    b="${1%/}"
    b="${b##*/}"
    n=$(printf '%s' "$b" | tr -c 'A-Za-z0-9_-' '_' | cut -c1-40)
    [ -n "$n" ] || n="proje"
    printf '%s' "$n"
}

# One string or number field of the payload; empty for anything else.
jget() {
    jq -r --arg k "$1" '
        if type == "object" then
            (.[$k] | if type == "string" or type == "number" then tostring else empty end)
        else empty end' <<<"$input"
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
# globs end in "-handoff-<id>.md", so D is never taken for a handoff.
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

# The line after the title of H. The loader and the next session read it.
extras_line() { # handoff path
    printf 'Ek dosyalar: detay notu %s · tam döküm %s' "$(detail_path "$1")" "$(dump_path "$1")"
}

# Put the "Ek dosyalar" line right after the title line of H, after the "Son güncelleme:"
# line when there is one. An older "Ek dosyalar" line is replaced, never doubled. A file
# that is already right is not rewritten (a rewrite would change its write time).
add_extras_line() { # handoff path
    local f="$1" line second third have
    [ -f "$f" ] || return 1
    line=$(extras_line "$f")
    second=$(sed -n 2p "$f" 2>/dev/null)
    third=$(sed -n 3p "$f" 2>/dev/null)
    case "$second" in "Son güncelleme:"*) have="$third" ;; *) have="$second" ;; esac
    [ "$have" = "$line" ] && return 0
    awk -v line="$line" '
        function put() { if (!done) { print line; done = 1 } }
        NR == 1 { print; next }
        /^Ek dosyalar:/ { next }
        NR <= 3 && !done && /^Son güncelleme:/ { print; put(); next }
        { put(); print }
        END { put() }' "$f" > "$f.tmp.$$" 2>/dev/null \
        && cat "$f.tmp.$$" > "$f" 2>/dev/null
    rm -f "$f.tmp.$$" 2>/dev/null
    return 0
}

# Run handoff-dump.py. Any failure is logged. Same function body in usage-limit.sh.
dump_run() { # transcript, out, title
    local err
    err=$(python3 "$DUMP_PY" --transcript "$1" --out "$2" --session "$session" \
        --project "$proj" --title "$3" --config "$CFG" 2>&1 >/dev/null </dev/null) \
        || log "handoff dump failed: $(clean "$err" 300)"
}

# Write the transcript dump of a handoff. It runs in the background, unless
# HANDOFF_DUMP_SYNC=1. No python3 or no script: logged once per session.
start_dump() { # handoff path
    local x title mark
    mark="$STATE_DIR/$session.nodump"
    if ! command -v python3 >/dev/null 2>&1 || [ ! -f "$DUMP_PY" ]; then
        if [ ! -e "$mark" ]; then
            mkdir -p "$STATE_DIR" 2>/dev/null
            : > "$mark" 2>/dev/null
            log "handoff dump skipped for $(clean "$session" 60): python3 or $(clean "$DUMP_PY" 160) is missing"
        fi
        return 0
    fi
    x=$(dump_path "$1")
    title=$(session_title "$transcript")
    [ -n "$title" ] || title=$(name_part "" "$proj")
    if [ "${HANDOFF_DUMP_SYNC:-}" = "1" ]; then
        dump_run "$transcript" "$x" "$title"
    else
        ( dump_run "$transcript" "$x" "$title" ) >/dev/null 2>&1 </dev/null &
    fi
    return 0
}

# The session name the user sees in the app. Order: the payload's session_title, the
# newest customTitle record of the transcript (the sidebar title, renames included),
# CLAUDE_CODE_SESSION_NAME (set by the Desktop app at launch, seen in SSH sessions),
# the newest aiTitle record. Empty when none is set. Same function in usage-limit.sh.
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
# exists too, nothing is renamed. Same function in usage-limit.sh.
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

# Hook output: <event name> <note for Claude>. A pending handoff time note (HNOTE) is
# added to the note, so one run gives one JSON object.
emit() {
    local msg="$2"
    if [ -n "$HNOTE" ]; then
        msg="${msg:+$msg
}$HNOTE"
        HNOTE=""
    fi
    jq -n -c --arg ev "$1" --arg msg "$msg" \
        '{hookSpecificOutput: {hookEventName: $ev, additionalContext: $msg}}' \
        || log "could not build output JSON"
}

# jq definitions for transcript records. Same text in handoff-load.sh.
# kind: "prompt" (a message of the user), "event" (a turn that the app or a tool
# started: task notification, CI event, side-session event, message from another
# session, automatic check, or a record that holds only system reminders) or "skip"
# (tool results, meta records, compact summaries, command output, interruptions).
# ts19: the timestamp cut to whole seconds, "YYYY-MM-DDTHH:MM:SSZ", or "".
JQ_KIND='
def ts19: (.timestamp // "") | if type == "string" and length >= 19 then .[0:19] + "Z" else "" end;
def text_of: ((try .message.content catch null) // "")
    | if type == "string" then .
      elif type == "array" then ([.[]? | select(type == "object" and .type == "text") | (.text // "") | strings] | join("\n"))
      else "" end;
def bare: text_of | gsub("<system-reminder>[\\s\\S]*?</system-reminder>"; "") | sub("^\\s+"; "");
def kind:
    if type != "object" or .type != "user" or .isMeta == true or .isCompactSummary == true or .isSidechain == true then "skip"
    else (text_of | sub("^\\s+"; "")) as $t
        | if $t == "" then "skip"
          elif ($t | test("^(<local-command-|<bash-stdout>|<bash-stderr>|\\[Request interrupted|\\[Image: )")) then "skip"
          elif ($t | test("^(<task-notification>|<ci-monitor-event>|<side-sessions-event>|<~?cross-session-message|\\[AUTOMATIC CHECK|\\[OTOMATİK KONTROL)")) then "event"
          elif bare == "" then "event"
          else "prompt" end
    end;
'

# True when a line of the reply is the CLEAR or COMPACT line this hook asks for,
# for example "CLEAR ~420K tokens: …". Leading markdown marks are allowed.
has_clear_line() { # reply text
    printf '%s\n' "$1" | sed -e 's/^[[:space:]>*_`#-]*//' \
        | grep -E -q '^(CLEAR|COMPACT)([^A-Za-z].*)?~ ?[0-9]+K'
}

# Epoch seconds to HH:MM in Turkey time (UTC+3 all year).
tr_hhmm() {
    jq -n -r --argjson t "$1" --argjson o "$TR_OFFSET" '($t + $o) | todate | .[11:16]' 2>/dev/null
}

# Newest handoff file of a session. Sets NH_T (its mtime, 0 when there is none) and NH_F.
newest_handoff() { # project dir, session id
    local f t
    NH_T=0
    NH_F=""
    for f in "$1/.claude/"*-handoff-"$2".md "$1/.claude/handoff-$2.md"; do
        [ -f "$f" ] || continue
        t=$(file_mtime "$f")
        case "$t" in ''|*[!0-9]*) t=0 ;; esac
        if [ "$t" -gt "$NH_T" ]; then NH_T="$t"; NH_F="$f"; fi
    done
}

# The time that the last CLEAR or COMPACT line of the reply gives for the handoff
# ("handoff 14:32", "handoff güncel (14:32)"), as HH:MM. Empty when it gives none.
line_handoff_time() { # reply text
    local line said
    line=$(printf '%s\n' "$1" | sed -e 's/^[[:space:]>*_`#-]*//' \
        | grep -E '^(CLEAR|COMPACT)([^A-Za-z].*)?~ ?[0-9]+K' | tail -n 1)
    said=$(printf '%s\n' "$line" | grep -o -i -E 'handoff[^0-9]{0,40}[0-9]{1,2}:[0-9]{2}' \
        | tail -n 1 | grep -o -E '[0-9]{1,2}:[0-9]{2}$')
    [ "${#said}" -eq 4 ] && said="0$said"
    printf '%s' "$said"
}

# PostToolBatch after the handoff request: when the handoff was written after the
# request and after the last note, put its write time in HNOTE. Uses the globals of main.
handoff_note() {
    local since seen hm t dm
    since=$(cat "$pending" 2>/dev/null)
    [[ $since =~ $re_num ]] || return 0
    newest_handoff "$proj" "$session"
    [ "$NH_T" -gt 0 ] && [ "$NH_T" -ge "$since" ] || return 0
    seen=$(cat "$STATE_DIR/$session.hnote" 2>/dev/null)
    [[ $seen =~ $re_num ]] || seen=0
    [ "$NH_T" -gt "$seen" ] || return 0
    hm=$(tr_hhmm "$NH_T")
    [ -n "$hm" ] || return 0
    # The extras line is a write too: read the write time again, so that the time in the
    # note is the file's own and the next batch does not see a new write.
    add_extras_line "$NH_F" || log "could not add the extras line to $(clean "$NH_F" 200)"
    t=$(file_mtime "$NH_F")
    if [[ $t =~ $re_num ]] && [ "$t" -ge "$NH_T" ]; then
        NH_T="$t"
        hm=$(tr_hhmm "$NH_T")
        [ -n "$hm" ] || return 0
    fi
    printf '%s\n' "$NH_T" > "$STATE_DIR/$session.hnote" 2>/dev/null \
        || log "could not write handoff time $(clean "$session" 60)"
    HNOTE="Handoff time: ${NH_F} was last written at ${hm} Turkey time (UTC+3). When this reply ends with the CLEAR or COMPACT line, write that time in it as \"handoff ${hm}\". After another write of the handoff this hook gives the new time."
    dm=$(detail_missing "$(detail_path "$NH_F")")
    if [ -n "$dm" ]; then
        HNOTE="${HNOTE}
Detail note $(detail_path "$NH_F"): missing sections: ${dm}. Write it before the CLEAR or COMPACT line."
    fi
    start_dump "$NH_F"
}

# Stop: send the reply back once when it ends the turn with the CLEAR or COMPACT
# line but the handoff was not written in this turn. Uses the globals of main.
stop_check() {
    local active msg p p_tr h hf title name want what reason hm said ds

    [ -e "$pending" ] || return 0
    active=$(jq -r '.stop_hook_active == true' <<<"$input" 2>/dev/null)
    [ "$active" = "true" ] && return 0

    msg=$(jq -r '.last_assistant_message // empty | strings' <<<"$input" 2>/dev/null)
    if [ -z "$msg" ]; then
        # Versions without last_assistant_message: the newest assistant text record.
        msg=$({ tail -n "$TAIL_LINES" "$transcript"; echo; } | reverse_lines | jq -R -n -r '
            first(inputs | fromjson?
                  | select(type == "object" and .type == "assistant" and (.isSidechain != true))
                  | [(.message.content // [])[]? | select(type == "object" and .type == "text") | (.text // "") | strings]
                  | select(length > 0) | join("\n")) // empty' 2>/dev/null)
    fi
    has_clear_line "$msg" || return 0

    # Turn start: the time stored by UserPromptSubmit, or the newest prompt or event
    # record of the transcript when that is later.
    p=$(cat "$STATE_DIR/$session.turn" 2>/dev/null)
    [[ $p =~ $re_num ]] || p=0
    p_tr=$({ tail -n "$TAIL_LINES" "$transcript"; echo; } | reverse_lines | jq -R -n -r "$JQ_KIND"'
        first(inputs | fromjson? | select(type == "object") | select(kind != "skip")
              | ts19 | select(. != "") | fromdateiso8601 | floor) // empty' 2>/dev/null)
    [[ $p_tr =~ $re_num ]] && [ "$p_tr" -gt "$p" ] && p="$p_tr"
    if [ "$p" -eq 0 ]; then
        log "stop: no turn start for $session, no handoff check"
        return 0
    fi

    newest_handoff "$proj" "$session"
    h="$NH_T"
    hf="$NH_F"
    if [ "$h" -ge "$p" ]; then
        # Written in this turn: the line must give its write time (Turkey time).
        hm=$(tr_hhmm "$h")
        [ -n "$hm" ] || return 0
        said=$(line_handoff_time "$msg")
        ds=$(detail_state "$(detail_path "$hf")")
        if [ "$said" != "$hm" ]; then
            if [ -z "$said" ]; then what="gives no handoff time"; else what="says handoff ${said}"; fi
            reason="Handoff time check (context-pressure hook): the CLEAR or COMPACT line of this reply ${what}, but the handoff ${hf} was last written at ${hm} Turkey time (UTC+3). The line shows the user when the handoff was written, so it must say \"handoff ${hm}\". End the reply with the CLEAR or COMPACT line again, alone, with \"handoff ${hm}\" in it: do not repeat the rest of the reply.$(detail_reason_tail "$hf" "$ds")"
            jq -n -c --arg r "$reason" '{decision: "block", reason: $r}' \
                || { log "could not build output JSON"; return 0; }
            log "stop: handoff time in the line is '$(clean "$said" 5)', not ${hm}, in $session, reply sent back"
            return 0
        fi
        if [ -n "$ds" ]; then
            reason="Detail note check (context-pressure hook): this reply ends with the CLEAR or COMPACT line, but the detail note $(detail_path "$hf") ${ds}. A fresh session on another account, or in Codex, needs that note to go on without loss. Write it now, with every required heading and the content the Context pressure request described. Then end the reply with the CLEAR or COMPACT line again, alone, with \"handoff ${hm}\" in it (the handoff time stays the same unless you write the handoff again; this hook then gives the new time): do not repeat the rest of the reply. Required headings, in this order: $(detail_headings_text)."
            jq -n -c --arg r "$reason" '{decision: "block", reason: $r}' \
                || { log "could not build output JSON"; return 0; }
            log "stop: detail note ${ds} in $session, reply sent back"
            return 0
        fi
        # Everything passes: the dump gets the last turns too.
        start_dump "$hf"
        return 0
    fi

    title=$(session_title "$transcript")
    name=$(name_part "$title" "$proj")
    want=$(resolve_handoff "$proj" "$name" "$session")
    if [ -z "$hf" ]; then
        what="does not exist"
    else
        what="was last written at $(tr_hhmm "$h") Turkey time (UTC+3), before this turn started at $(tr_hhmm "$p") Turkey time"
    fi
    reason="Handoff check (context-pressure hook): this reply ends with the CLEAR or COMPACT line, but the handoff ${want} ${what}. That line tells the user that the handoff is current. Update the handoff now with this turn: the user's last request and where it stands, and any message drafted or sent, decision, approval, open question or new next step. Then end the reply with the CLEAR or COMPACT line again, alone, with the new write time of the handoff as \"handoff HH:MM\" (Turkey time; this hook gives it after the write): do not repeat the rest of the reply.$(detail_reason_tail "$want" "$(detail_state "$(detail_path "$want")")")"
    jq -n -c --arg r "$reason" '{decision: "block", reason: $r}' \
        || { log "could not build output JSON"; return 0; }
    log "stop: handoff older than the turn in $session, reply sent back"
}

# The instructions for the detail note. Same text in usage-limit.sh (handoff_rules).
detail_rules_text() { # detail path, dump path, session name
    printf '%s' "Detail note: write ${1} before the handoff. Its first line is '# ${3} — detay notu'. Then these sections, in this order, each as a line exactly like this: $(detail_headings_text). Write 'Yok.' under a section with nothing to report: never leave a heading out. The note holds everything that a fresh session on another account, or in Codex (which loads no memory), needs to go on without loss: every decision with its reason; the user's requests and corrections quoted in their own words; every open task and its exact state; background jobs and how to check them; what was tried and ruled out, and why; lessons learned; the full text of every memory file this session wrote or changed, and why; the environment (branches, commits, uncommitted files, machines, versions). It has no size limit. Write it in the user's language. Never put passwords, tokens or other secrets in it. Leave nothing out with an excuse. The full transcript dump ${2} is written by a hook: do not write it yourself."
}

# The required headings of D, joined by ", ".
detail_headings_text() {
    detail_missing /nonexistent-detail-note
}

# Extra text for a Stop reason that is sent back anyway: D is incomplete too. Empty when
# D is complete.
detail_reason_tail() { # handoff path, detail state
    [ -n "$2" ] || return 0
    printf ' The detail note %s also %s: write it too, before you end the reply (required headings, in this order: %s).' \
        "$(detail_path "$1")" "$2" "$(detail_headings_text)"
}

# The context window of a session in tokens, or nothing. The usage-feed mod writes it to
# <config>/usage-feed/context-<session id>.json (the engine knows the window, a command
# hook does not). Without the mod the file is missing.
context_window() { # session id
    local f w
    f="$CFG/usage-feed/context-$1.json"
    [ -r "$f" ] || return 0
    w=$(jq -r '.window // empty' "$f" 2>/dev/null)
    [[ $w =~ ^[0-9]{1,9}$ ]] && [ "$((10#$w))" -gt 0 ] && printf '%s' "$((10#$w))"
    return 0
}

# Delete the context files of the mod that are older than 7 days, at most once a day.
# file_mtime keeps it portable (no find -mtime).
prune_context_files() {
    local stamp="$STATE_DIR/context-prune.stamp" now t f
    [ -d "$CFG/usage-feed" ] || return 0
    now=$(date +%s)
    t=$(file_mtime "$stamp")
    [ "$(( now - t ))" -lt 86400 ] && return 0
    for f in "$CFG/usage-feed"/context-*.json; do
        [ -f "$f" ] || continue
        t=$(file_mtime "$f")
        [ "$t" -gt 0 ] && [ "$(( now - t ))" -gt 604800 ] && rm -f "$f" 2>/dev/null
    done
    mkdir -p "$STATE_DIR" 2>/dev/null && touch "$stamp" 2>/dev/null
    return 0
}

# The threshold in tokens. CTX_PRESSURE_THRESHOLD wins when it is set. Otherwise 300000,
# or CTX_PRESSURE_WINDOW_PCT (default 60) percent of the session's context window when
# that is lower: a 200K window warns at 120000, a 1M window at 300000.
pick_threshold() { # session id
    local t pct w
    t="${CTX_PRESSURE_THRESHOLD:-}"
    if [ -n "$t" ]; then
        if ! [[ $t =~ $re_num ]] || [ "${#t}" -gt 9 ]; then
            log "invalid CTX_PRESSURE_THRESHOLD '$(clean "$t" 40)', using 300000"
            t=300000
        fi
        # Leading zeros: 10# keeps "0300000" decimal (bash arithmetic would read it as octal).
        printf '%s' "$(( 10#$t ))"
        return 0
    fi
    t=300000
    w=$(context_window "$1")
    if [ -n "$w" ]; then
        pct="${CTX_PRESSURE_WINDOW_PCT:-60}"
        if ! [[ $pct =~ ^[0-9]{1,3}$ ]] || [ "$((10#$pct))" -lt 1 ] || [ "$((10#$pct))" -gt 100 ]; then
            log "invalid CTX_PRESSURE_WINDOW_PCT '$(clean "$pct" 40)', using 60"
            pct=60
        fi
        pct=$((10#$pct))
        [ "$(( w * pct / 100 ))" -lt "$t" ] && t=$(( w * pct / 100 ))
    fi
    printf '%s' "$t"
}

# Context size in tokens of the newest main-thread assistant record, or nothing. Newest
# record first. fromjson? skips a partial or malformed line. The extra echo matters: a last
# line written without a newline would be glued onto the previous valid record by the line
# reversal.
transcript_ctx() { # transcript path
    { tail -n "$TAIL_LINES" "$1"; echo; } | reverse_lines | jq -R -n -r '
        def n: if type == "number" then floor else 0 end;
        first(inputs
              | fromjson?
              | select(type == "object"
                       and .type == "assistant"
                       and (.isSidechain != true)
                       and ((.message | type) == "object")
                       and ((.message.usage | type) == "object"))
              | .message.usage
              | ((.input_tokens | n)
                 + (.cache_read_input_tokens | n)
                 + (.cache_creation_input_tokens | n))) // empty' 2>/dev/null
}

# A handoff inside a git work tree that is not ignored can end up in a commit. Prints the
# note, or nothing.
git_note() { # project dir, handoff path
    if command -v git >/dev/null 2>&1 \
        && git -C "$1" rev-parse --is-inside-work-tree >/dev/null 2>&1 \
        && ! git -C "$1" check-ignore -q "$2" 2>/dev/null; then
        printf '%s' "Note: ${1} is inside a git repository and the handoff path is not git-ignored. Never commit the handoff. Tell the user once that the line '**/.claude/*handoff*.md' belongs in .git/info/exclude (this clone only) or in .gitignore."
    fi
    return 0
}

# The shared body of a handoff request (the threshold request and the bulk request): sets
# BODY, with its final newline. Same text for both.
handoff_body() { # handoff, name, title, detail, detail_rules
    local handoff="$1" name="$2" title="$3" detail="$4" detail_rules="$5"
    IFS= read -r -d '' BODY <<EOF
Before that line, do these in this order: memory (First), the detail note, the handoff (Second).
First, save to memory what any future session must know beyond this task: feedback or corrections the user gave in this session (what to do or avoid, and why) and durable facts or lessons found here. Update an existing memory instead of adding a duplicate. Skip what memory already holds.
${detail_rules}
Second, write the handoff to ${handoff} so that a fresh session can read it cold. It holds only this task's open state: do not copy memory content into it. The file name starts with the session name the user sees in the app (${name}) on purpose. The first line of the file is a title that starts with that name: ${title:-$name}. A hook adds the line 'Ek dosyalar: detay notu … · tam döküm …' right after the title (and after a 'Son güncelleme:' line): you may leave it out. Put one line in READ FIRST that tells the next session to read the detail note ${detail} in full.
Keep it under 6000 characters and under 7000 bytes (check with wc -c; Turkish letters take 2 bytes): the loader injects only the first 8000 bytes, so a longer file loses its tail. Start with a READ FIRST section that holds the open items (anything still waiting on the user, unverified, or deferred) and the single next step. Then write: goal, done, key decisions, ruled out, file paths. Use absolute paths only, because scratchpad and temp directories change after /clear.
If earlier *handoff*.md files of this same task exist in the same .claude folder, carry their still-open items forward. Leave out the items of other, unrelated tasks: they stay in their own files. When you update the handoff later, never delete an open item: move it to done only once it is verified.
From now on, every reply that ends with the CLEAR or COMPACT line updates the handoff in the same turn, before that line: at least the user's last request and where it stands, and any message drafted or sent, decision, approval, open question or new next step. The line tells the user that the handoff is current, so make that true first. A Stop hook checks this: a reply with the line whose turn did not write the handoff, or whose line gives another handoff time, is sent back once.
After /clear, a SessionStart hook loads the file only when it can match this session exactly. Otherwise the new session gets just a list of handoff paths. This is not guaranteed. A 'Handoff yüklendi' line at the start of the new session's first reply confirms that it loaded.
EOF
    return 0
}

main() {
    local transcript session cwd proj phash pending threshold ctx bucket last state
    local title name handoff msg re_sid re_num ev agent gitnote step shown ctxk
    local detail detail_rules prompt sizetxt

    re_sid='^[A-Za-z0-9_-]{1,128}$'
    re_num='^[0-9]+$'

    input=$(cat) || { log "could not read stdin"; return; }
    if ! jq -e . >/dev/null 2>&1 <<<"$input"; then
        log "stdin is not valid JSON"
        return
    fi

    transcript=$(jget transcript_path)
    session=$(jget session_id)
    cwd=$(jget cwd)

    # The session id becomes a file name, so allow only safe characters.
    if ! [[ $session =~ $re_sid ]]; then
        log "invalid session_id: '$(clean "$session" 60)'"
        return
    fi

    # Registered for UserPromptSubmit, PostToolBatch and Stop; the output names the event
    # it answers. A subagent's batch is skipped: only the main thread's context matters.
    ev=$(jget hook_event_name)
    [ -n "$ev" ] || ev="UserPromptSubmit"
    case "$ev" in
        UserPromptSubmit|PostToolBatch|Stop) ;;
        *) log "unexpected event '$(clean "$ev" 40)'"; return ;;
    esac
    agent=$(jget agent_id)
    [ -z "$agent" ] || return

    # Project root first: cwd follows the shell and can sit inside an unrelated
    # clone, where a handoff file could end up in someone's commit.
    proj="${CLAUDE_PROJECT_DIR:-$cwd}"
    if [ -z "$proj" ]; then
        log "no project dir: CLAUDE_PROJECT_DIR and cwd are both empty"
        return
    fi

    if [ -z "$transcript" ]; then
        log "payload has no transcript_path"
        return
    fi
    # The first prompt of a session can arrive before the transcript file exists.
    [ -e "$transcript" ] || return
    if [ ! -r "$transcript" ]; then
        log "transcript not readable: '$(clean "$transcript" 200)'"
        return
    fi

    phash=$(sha1_16 "$proj")
    pending="$PENDING_DIR/$phash/$session"

    [ "$ev" = "UserPromptSubmit" ] && prune_context_files

    # A session that was asked for a handoff: note when each turn starts (Stop check).
    if [ "$ev" = "UserPromptSubmit" ] && [ -e "$pending" ]; then
        date +%s > "$STATE_DIR/$session.turn" 2>/dev/null \
            || log "could not write turn start $(clean "$session" 60)"
    fi
    if [ "$ev" = "Stop" ]; then
        stop_check
        return
    fi
    # A handoff written in this tool batch: give its time (sent with any other note).
    if [ "$ev" = "PostToolBatch" ] && [ -e "$pending" ]; then
        mkdir -p "$STATE_DIR" 2>/dev/null && chmod 700 "$STATE_DIR" 2>/dev/null
        handoff_note
    fi

    threshold=$(pick_threshold "$session")
    state="$STATE_DIR/$session"

    # Bulk handoff request: the marker in the prompt asks for the handoff at once, with no
    # threshold. Same rules, paths and later checks as the threshold request below.
    if [ "$ev" = "UserPromptSubmit" ]; then
        prompt=$(jget prompt)
        if [[ "$prompt" == *"$BULK_MARKER"* ]]; then
            ctx=$(transcript_ctx "$transcript")
            mkdir -p "$STATE_DIR" 2>/dev/null && chmod 700 "$STATE_DIR" 2>/dev/null
            if [[ $ctx =~ $re_num ]]; then
                ctxk="$(( (ctx + 500) / 1000 ))K"
                sizetxt="~${ctxk} tokens"
                # Above the threshold: record the bucket, so a PostToolBatch of this turn
                # does not send the threshold request again.
                if [ "$ctx" -ge "$threshold" ]; then
                    echo "$(( ctx / BUCKET )) $(( ctx / STEP ))" > "$state.tmp.$$" \
                        && mv -f "$state.tmp.$$" "$state" \
                        || log "could not write state file $(clean "$state" 200)"
                fi
            else
                sizetxt="size unknown"
            fi

            title=$(session_title "$transcript")
            name=$(name_part "$title" "$proj")
            handoff=$(resolve_handoff "$proj" "$name" "$session")
            detail=$(detail_path "$handoff")
            detail_rules=$(detail_rules_text "$detail" "$(dump_path "$handoff")" "${title:-$name}")

            # Marker for handoff-load.sh, the bulk flag and the turn start (Stop check).
            mkdir -p "$PENDING_DIR/$phash" 2>/dev/null \
                && chmod 700 "$PENDING_DIR" "$PENDING_DIR/$phash" 2>/dev/null
            rm -f "$pending.offered" 2>/dev/null
            date +%s > "$pending" 2>/dev/null || log "could not write pending marker"
            date +%s > "$STATE_DIR/$session.bulk" 2>/dev/null \
                || log "could not write bulk flag $(clean "$session" 60)"
            date +%s > "$STATE_DIR/$session.turn" 2>/dev/null \
                || log "could not write turn start $(clean "$session" 60)"

            gitnote=$(git_note "$proj" "$handoff")
            handoff_body "$handoff" "$name" "$title" "$detail" "$detail_rules"
            IFS= read -r -d '' msg <<EOF
Bulk handoff request: the user asked from the /oturum pane of another session that this session writes its handoff now (a usage limit or an account switch is near). Do not start new work. Pause the current work at a safe point in this reply. End this reply with ONE final line: CLEAR, the context size as ${sizetxt}, the reason 'toplu devir', the handoff's last write time as "handoff HH:MM" in Turkey time (UTC+3; this hook sends a 'Handoff time' note after each write of the handoff), and the handoff path. Passwords, tokens and other secrets never go into the handoff.
EOF
            msg="${msg}${BODY}${gitnote}"
            log "bulk handoff request for $(clean "$session" 60)"
            emit "$ev" "$msg"
            return
        fi
    fi

    ctx=$(transcript_ctx "$transcript")

    # No usage yet (for example the first prompt of a session) is not an error.
    [[ $ctx =~ $re_num ]] || return

    mkdir -p "$STATE_DIR" 2>/dev/null && chmod 700 "$STATE_DIR" 2>/dev/null

    # Back under the threshold (for example after /compact): reset, so a later
    # rise warns again, and drop the pending marker of this session. A bulk handoff turn
    # keeps its marker, turn file and checks: only a later prompt without the bulk marker
    # (a new turn) resets it.
    if [ "$ctx" -lt "$threshold" ]; then
        if [ -e "$STATE_DIR/$session.bulk" ] && [ -e "$pending" ] && [ "$ev" != "UserPromptSubmit" ]; then
            # HNOTE stays: a handoff time note of this batch still goes out.
            return
        fi
        rm -f "$state" "$pending" "$pending.offered" "$STATE_DIR/$session.turn" \
            "$STATE_DIR/$session.hnote" "$STATE_DIR/$session.nodump" \
            "$STATE_DIR/$session.bulk" 2>/dev/null
        HNOTE=""
        return
    fi

    bucket=$(( ctx / BUCKET ))
    step=$(( ctx / STEP ))
    ctxk="$(( (ctx + 500) / 1000 ))K"
    # State file: "<bucket> <step>". A file of an older version holds only the bucket.
    read -r last shown <<<"$(cat "$state" 2>/dev/null)"
    [[ $last =~ $re_num ]] || last=-1
    [[ $shown =~ $re_num ]] || shown=-1

    if [ "$bucket" -le "$last" ]; then
        # Same bucket, or the context shrank but is still above the threshold:
        # no new handoff request. The mark follows the bucket down, so the next
        # bucket up warns again. A new 10K step gets a one-line size note.
        [ "$step" -eq "$shown" ] && return
        echo "$bucket $step" > "$state"
        emit "$ev" "Context size: the main thread is now at about ${ctx} tokens (~${ctxk}). When this reply ends with the CLEAR or COMPACT line, write the size in it as ~${ctxk} tokens and the handoff time as 'handoff HH:MM' (Turkey time, from this hook's 'Handoff time' note), and first update the handoff with this turn."
        return
    fi

    echo "$bucket $step" > "$state.tmp.$$" && mv -f "$state.tmp.$$" "$state" \
        || log "could not write state file $(clean "$state" 200)"

    title=$(session_title "$transcript")
    name=$(name_part "$title" "$proj")
    handoff=$(resolve_handoff "$proj" "$name" "$session")
    detail=$(detail_path "$handoff")
    detail_rules=$(detail_rules_text "$detail" "$(dump_path "$handoff")" "${title:-$name}")

    # Marker for handoff-load.sh: this session was asked to write a handoff now.
    mkdir -p "$PENDING_DIR/$phash" 2>/dev/null \
        && chmod 700 "$PENDING_DIR" "$PENDING_DIR/$phash" 2>/dev/null
    rm -f "$pending.offered" 2>/dev/null
    date +%s > "$pending" 2>/dev/null || log "could not write pending marker"

    gitnote=$(git_note "$proj" "$handoff")
    handoff_body "$handoff" "$name" "$title" "$detail" "$detail_rules"

    IFS= read -r -d '' msg <<EOF
Context pressure: the main thread is at about ${ctx} tokens (threshold ${threshold}).
Keep working on the current request as usual. Only at a natural stopping point (a verified unit of work is done, not the middle of a task) end your reply with ONE final line: CLEAR or COMPACT, the context size as ~${ctxk} tokens (a later 'Context size' note of this hook gives a newer number: use the newest one), a one-line reason, the handoff's last write time as "handoff HH:MM" in Turkey time (UTC+3; after each write of the handoff this hook sends a 'Handoff time' note with it), and the handoff path. If a usage-limit hook also asks for a warning line and a prompt block at the end of the reply, put the CLEAR or COMPACT line right before that block: the block stays last.
Default to CLEAR. Choose COMPACT only when live reasoning or unsaved material exists that cannot be written down. Passwords, tokens and other secrets count: never put them in the handoff.
EOF
    msg="${msg}${BODY}${gitnote}"

    emit "$ev" "$msg"
}

trim_log
main 2>>"$LOG"
# A handoff time note that no other note carried goes out alone (PostToolBatch only).
[ -n "$HNOTE" ] && emit PostToolBatch "" 2>>"$LOG"
exit 0
