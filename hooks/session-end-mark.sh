#!/usr/bin/env bash
# SessionEnd hook: record which sessions ended in this project.
#
# TARGET: Linux and macOS, one file. Bash 3.2 compatible. No uname branching.
#
# handoff-load.sh (SessionStart) cannot tell which session was cleared, because
# the SessionStart payload does not say so. This hook closes that gap. It appends
#   <state dir>/ended/<first 16 hex of sha1 of the project dir>
# one line per ended session: "<epoch> <session_id> <reason>". The loader injects
# a handoff only when exactly one session ended in the project within its window.
# Lines are appended, never overwritten, so an app restart (several sessions end
# in the same second, all with reason "other") is seen as ambiguous.
#
# Parallel calls are serialized with a mkdir lock. Without it, trimming could drop
# lines. Keep it fast: SessionEnd has a short timeout (registered with 5 s).
# No set -e and no ERR trap. Every path exits 0 and errors go to the log.

umask 077

CFG="${CLAUDE_CONFIG_DIR:-$HOME/.claude}"
LOG="$CFG/hooks/context-pressure.log"
STATE_DIR="${CTX_PRESSURE_STATE_DIR:-$CFG/hooks/state}"
MAX_LINES=20

mkdir -p "${LOG%/*}" 2>/dev/null

clean() {
    printf '%s' "$1" | tr -d '\000-\037\177' | cut -c1-"${2:-200}"
}

log() {
    printf '%s %s\n' "$(date -u +%FT%TZ)" "$*" >> "$LOG" 2>/dev/null
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

jget() {
    jq -r --arg k "$1" '
        if type == "object" then
            (.[$k] | if type == "string" or type == "number" then tostring else empty end)
        else empty end' <<<"$input"
}

main() {
    local sid cwd reason proj phash f lock tries got count re_sid re_reason

    re_sid='^[A-Za-z0-9_-]{1,128}$'
    re_reason='^[A-Za-z0-9_-]{1,64}$'

    input=$(cat) || { log "session-end: could not read stdin"; return; }
    if ! jq -e . >/dev/null 2>&1 <<<"$input"; then
        log "session-end: stdin is not valid JSON"
        return
    fi

    sid=$(jget session_id)
    cwd=$(jget cwd)
    reason=$(jget reason)
    proj="${CLAUDE_PROJECT_DIR:-$cwd}"

    log "session-end: reason=$(clean "${reason:-?}" 64) session=$(clean "${sid:-?}" 128) project=$(clean "${proj:-?}" 200)"

    [[ $sid =~ $re_sid ]] || return
    [ -n "$proj" ] || return
    [[ $reason =~ $re_reason ]] || reason="other"

    phash=$(sha1_16 "$proj")
    f="$STATE_DIR/ended/$phash"
    mkdir -p "$STATE_DIR/ended" 2>/dev/null \
        && chmod 700 "$STATE_DIR" "$STATE_DIR/ended" 2>/dev/null

    # mkdir lock: up to 40 tries; a lock older than 1 minute is stale. Without the
    # lock the line is still appended (an O_APPEND write of one short line does not
    # interleave), but the trim is skipped: a trim racing another writer or the
    # loader could lose lines.
    lock="$f.lock"
    got=0
    tries=0
    while [ "$tries" -lt 40 ]; do
        if mkdir "$lock" 2>/dev/null; then
            got=1
            break
        fi
        find "$lock" -maxdepth 0 -type d -mmin +1 -exec rmdir {} \; 2>/dev/null
        sleep 0.05
        tries=$(( tries + 1 ))
    done

    if printf '%s %s %s\n' "$(date +%s)" "$sid" "$reason" >> "$f" 2>/dev/null; then
        count=$(wc -l < "$f" 2>/dev/null | tr -d ' ')
        case "$count" in ''|*[!0-9]*) count=0 ;; esac
        if [ "$got" -ne 1 ]; then
            log "session-end: lock busy, line appended without trim"
        elif [ "$count" -gt "$MAX_LINES" ]; then
            tail -n "$MAX_LINES" "$f" > "$f.tmp.$$" 2>/dev/null \
                && mv -f "$f.tmp.$$" "$f" 2>/dev/null
        fi
    else
        log "session-end: could not write ended record"
    fi

    [ "$got" -eq 1 ] && rmdir "$lock" 2>/dev/null
}

trim_log
main 2>>"$LOG"
exit 0
