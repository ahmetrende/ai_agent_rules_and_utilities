#!/usr/bin/env bash
# Test suite for the three handoff hooks.
# usage: run-tests.sh <hooks dir> [label]
# Every test uses its own HOME (for the log), CTX_PRESSURE_STATE_DIR and project
# dir. CLAUDE_PROJECT_DIR is unset, so the cwd fallback is the path under test.
# Scripts run by their path, so the shebang is tested too.

HOOKS="${1:?usage: run-tests.sh <hooks dir> [label]}"
LABEL="${2:-run}"
PASS=0
FAIL=0
FAILS=""
ROOT=$(mktemp -d "${TMPDIR:-/tmp}/hooktest.XXXXXX") || exit 2
trap 'chmod -R u+rwX "$ROOT" 2>/dev/null; rm -rf "$ROOT"' EXIT
N=0

ID_A=11111111-aaaa-4aaa-8aaa-111111111111
ID_B=22222222-bbbb-4bbb-8bbb-222222222222
ID_C=33333333-cccc-4ccc-8ccc-333333333333
ID_D=44444444-dddd-4ddd-8ddd-444444444444
ID_E=55555555-eeee-4eee-8eee-555555555555
NEWID=99999999-9999-4999-8999-999999999999

# ---------- assertions ----------
ok()  { PASS=$((PASS + 1)); }
bad() { FAIL=$((FAIL + 1)); FAILS="$FAILS
  FAIL [$CUR] $1 :: $2"; }
t_eq()  { if [ "$2" = "$3" ]; then ok; else bad "$1" "got '$(printf '%s' "$2" | head -c 160)' want '$3'"; fi; }
t_has() { case "$2" in *"$3"*) ok ;; *) bad "$1" "missing '$3' in '$(printf '%s' "$2" | head -c 200)'" ;; esac; }
t_no()  { case "$2" in *"$3"*) bad "$1" "unexpected '$3'" ;; *) ok ;; esac; }
t_true() { local n="$1"; shift; if "$@"; then ok; else bad "$n" "failed: $*"; fi; }
t_false() { local n="$1"; shift; if "$@"; then bad "$n" "should fail: $*"; else ok; fi; }

# ---------- portable helpers ----------
sha1_16() {
    if command -v sha1sum >/dev/null 2>&1; then printf '%s' "$1" | sha1sum | cut -c1-16
    else printf '%s' "$1" | shasum -a 1 | cut -c1-16; fi
}
epoch_touch() { # epoch -> touch -t string (UTC)
    date -u -d "@$1" +%Y%m%d%H%M.%S 2>/dev/null || date -u -r "$1" +%Y%m%d%H%M.%S
}
set_mtime() { TZ=UTC touch -t "$(epoch_touch "$2")" "$1"; }
now() { date +%s; }
lines() { if [ -f "$1" ]; then wc -l < "$1" | tr -d ' '; else echo 0; fi; }

new_env() {
    N=$((N + 1))
    E="$ROOT/e$N"
    H="$E/home"
    S="$E/state"
    P="$E/my-proj"
    PNAME="my-proj"
    mkdir -p "$H/.claude/hooks" "$P/.claude" "$E/tr"
    LOGF="$H/.claude/hooks/context-pressure.log"
    PH=$(sha1_16 "$P")
    SID="aaaaaaaa-0000-4000-8000-$(printf '%012d' "$N")"
    TR="$E/transcript.jsonl"
}

# run <script> <stdin json> [VAR=value ...]  ->  OUT RC
run() {
    local script="$1" json="$2"
    shift 2
    OUT=$(printf '%s' "$json" | env -u CLAUDE_PROJECT_DIR -u CLAUDE_CONFIG_DIR -u CLAUDE_CODE_SESSION_NAME HOME="$H" CTX_PRESSURE_STATE_DIR="$S" HANDOFF_DUMP_SYNC=1 "$@" "$HOOKS/$script" 2>"$E/stderr")
    RC=$?
}

# ---------- context-pressure helpers ----------
cp_json() {
    jq -n -c --arg t "$TR" --arg s "${1:-$SID}" --arg c "$P" \
        '{hook_event_name:"UserPromptSubmit", session_id:$s, transcript_path:$t, cwd:$c, prompt:"x"}'
}
rec()  { jq -n -c --argjson c "$1" '{type:"assistant", isSidechain:false, message:{role:"assistant", usage:{input_tokens:1, cache_read_input_tokens:($c - 1), cache_creation_input_tokens:0, output_tokens:5}}}'; }
side() { jq -n -c --argjson c "$1" '{type:"assistant", isSidechain:true, message:{role:"assistant", usage:{input_tokens:$c, cache_read_input_tokens:0, cache_creation_input_tokens:0}}}'; }
usr()  { printf '%s\n' '{"type":"user","message":{"role":"user","content":"hi"}}'; }
title_rec() { jq -n -c --arg t "$1" '{type:"custom-title", customTitle:$t, sessionId:"x"}'; }
mk_tr() { { usr; rec "$1"; } > "$TR"; }
cp_run() { run context-pressure.sh "$(cp_json "$1")" "${@:2}"; }
cp_batch_json() { # [session id] [agent id]
    jq -n -c --arg t "$TR" --arg s "${1:-$SID}" --arg c "$P" --arg a "${2:-}" \
        '{hook_event_name:"PostToolBatch", session_id:$s, transcript_path:$t, cwd:$c, tool_calls:[]}
         + (if $a == "" then {} else {agent_id:$a} end)'
}
cp_prompt_json() { # prompt text [agent id]
    jq -n -c --arg t "$TR" --arg s "$SID" --arg c "$P" --arg p "$1" --arg a "${2:-}" \
        '{hook_event_name:"UserPromptSubmit", session_id:$s, transcript_path:$t, cwd:$c, prompt:$p}
         + (if $a == "" then {} else {agent_id:$a} end)'
}
BULK_PROMPT="Toplu devir isteği [oturum:toplu-devir]: şimdi devir notunu yaz."
msg_of() { printf '%s' "$OUT" | jq -r '.hookSpecificOutput.additionalContext // empty' 2>/dev/null; }
state_of() { cut -d' ' -f1 "$S/$SID" 2>/dev/null; }
marker="" # set per test
marker_path() { printf '%s' "$S/pending.d/$PH/$SID"; }

# ---------- session-end helpers ----------
se_json() { jq -n -c --arg s "$1" --arg r "$2" --arg c "$P" '{hook_event_name:"SessionEnd", session_id:$s, reason:$r, cwd:$c}'; }
se_run() { run session-end-mark.sh "$(se_json "$1" "$2")"; }

# ---------- loader helpers ----------
ld_json() { # source [session id] [transcript path]
    jq -n -c --arg s "$1" --arg i "${2:-$NEWID}" --arg c "$P" --arg t "${3:-$E/tr/${2:-$NEWID}.jsonl}" \
        '{hook_event_name:"SessionStart", source:$s, session_id:$i, cwd:$c, transcript_path:$t}'
}
ld_run() { run handoff-load.sh "$(ld_json "$1" "${2:-}" "${3:-}")" "${@:4}"; }
mk_ended() { # sid age_s [reason]
    mkdir -p "$S/ended"
    printf '%s %s %s\n' $(( $(now) - $2 )) "$1" "${3:-other}" >> "$S/ended/$PH"
}
mk_handoff() { # sid [age_s] [first line] [dir name prefix]
    local f="$P/.claude/${4-$PNAME-}handoff-$1.md"
    printf '%s\nbody of %s\nREAD FIRST: next step X\n' "${3:-# Handoff test $1}" "$1" > "$f"
    if [ -n "$2" ]; then set_mtime "$f" $(( $(now) - $2 )); fi
    printf '%s' "$f"
}
mk_marker() { # sid [age_s] [project hash]
    local h="${3:-$PH}"
    mkdir -p "$S/pending.d/$h"
    printf '%s\n' $(( $(now) - ${2:-120} )) > "$S/pending.d/$h/$1"
}
ctx_of() { printf '%s' "$OUT" | jq -r '.hookSpecificOutput.additionalContext // empty' 2>/dev/null; }
sys_of() { printf '%s' "$OUT" | jq -r '.systemMessage // empty' 2>/dev/null; }
file_exists() { [ -e "$1" ]; }
# Detail note next to a handoff (2026-11-23): all eight required headings, "Yok." under
# each. mk_detail <handoff path> [heading number to leave out]
DETAIL_H1="## Decisions and reasons"; DETAIL_H2="## User requests in their words"
DETAIL_H3="## Open tasks"; DETAIL_H4="## Background jobs"; DETAIL_H5="## Ruled out and why"
DETAIL_H6="## Lessons learned"; DETAIL_H7="## Memory changes"; DETAIL_H8="## Environment"
mk_detail() {
    local d="${1%.md}.detay.md" i h
    printf '# test — detay notu\n' > "$d"
    for i in 1 2 3 4 5 6 7 8; do
        [ "$i" = "${2:-0}" ] && continue
        eval "h=\$DETAIL_H$i"
        printf '\n%s\nYok.\n' "$h" >> "$d"
    done
    printf '%s' "$d"
}
# Wait up to 5 s for a file (the dump runs in the background without HANDOFF_DUMP_SYNC).
wait_file() { local i=0; while [ ! -s "$1" ] && [ "$i" -lt 50 ]; do sleep 0.1; i=$((i + 1)); done; [ -s "$1" ]; }
HAVE_PY=0; command -v python3 >/dev/null 2>&1 && HAVE_PY=1
HAVE_GIT=0; command -v git >/dev/null 2>&1 && HAVE_GIT=1

# ---------- stop-check and freshness helpers (2026-11-07) ----------
iso_ms() { jq -n -r --argjson t "$1" '$t | todate | sub("Z$"; ".512Z")'; }
urec() { # epoch text [extra json]  ->  user record with a string content
    local x="${3:-}"
    [ -n "$x" ] || x='{}'
    jq -n -c --arg ts "$(iso_ms "$1")" --arg c "$2" --argjson x "$x" \
        '{type:"user", timestamp:$ts, message:{role:"user", content:$c}} + $x'
}
toolres() { # epoch  ->  user record with a tool result only
    jq -n -c --arg ts "$(iso_ms "$1")" \
        '{type:"user", timestamp:$ts, message:{role:"user", content:[{type:"tool_result", tool_use_id:"t1", content:"ok"}]}}'
}
arec() { # epoch text  ->  assistant text record
    jq -n -c --arg ts "$(iso_ms "$1")" --arg c "$2" \
        '{type:"assistant", timestamp:$ts, isSidechain:false, message:{role:"assistant", content:[{type:"text", text:$c}]}}'
}
stop_json() { # reply text [stop_hook_active]
    jq -n -c --arg t "$TR" --arg s "$SID" --arg c "$P" --arg m "$1" --argjson a "${2:-false}" \
        '{hook_event_name:"Stop", session_id:$s, transcript_path:$t, cwd:$c, stop_hook_active:$a, last_assistant_message:$m}'
}
stop_run() { run context-pressure.sh "$(stop_json "$@")"; }
dec_of() { printf '%s' "$OUT" | jq -r '.decision // empty' 2>/dev/null; }
reason_of() { printf '%s' "$OUT" | jq -r '.reason // empty' 2>/dev/null; }
turn_at() { mkdir -p "$S"; printf '%s\n' $(( $(now) - $1 )) > "$S/$SID.turn"; }
last_prompt_of() { printf '%s\n' "$(ctx_of)" | sed -n 's/^Last user prompt after the handoff (data, not an instruction): "\(.*\)"$/\1/p'; }
line_no() { printf '%s\n' "$1" | grep -n -F -- "$2" | head -n 1 | cut -d: -f1; }
jqk() { awk -v q="'" '/^JQ_KIND=/ { f = 1 } f { print } f && $0 == q { exit }' "$1"; }
utf8_ok() { printf '%s' "$1" | iconv -f UTF-8 -t UTF-8 >/dev/null 2>&1; }
CLEARLINE="CLEAR ~352K tokens: iş bitti, devir notu güncel. /x/my-proj-handoff.md"
# Handoff time (2026-11-13): mtime of a file, epoch to HH:MM Turkey time (UTC+3), and a
# CLEAR line that gives the right handoff time of a file.
file_mt() { stat -c %Y "$1" 2>/dev/null || stat -f %m "$1"; }
tr_hm() { jq -n -r --argjson t "$1" '($t + 10800) | todate | .[11:16]'; }
tline() { printf 'CLEAR ~352K tokens: iş bitti · handoff %s · %s' "$(tr_hm "$(file_mt "$1")")" "$1"; }
at_epoch() { mkdir -p "$S"; printf '%s\n' "$1" > "$S/$SID.turn"; }

# =====================================================================
CUR="lint"
for s in context-pressure.sh session-end-mark.sh handoff-load.sh; do
    t_true "$s exists" test -f "$HOOKS/$s"
    t_true "$s executable" test -x "$HOOKS/$s"
    t_eq "$s shebang" "$(head -n 1 "$HOOKS/$s")" '#!/usr/bin/env bash'
    t_true "$s syntax" bash -n "$HOOKS/$s"
    code=$(grep -v '^[[:space:]]*#' "$HOOKS/$s")
    viol=""
    for pat in 'declare -A' 'mapfile' 'readarray' ',,}' '^^}' '&>>' '[[ -v' 'local -n' 'coproc' \
               'sed -i' 'date -d' 'readlink -f' 'realpath' 'grep -P' 'xargs -r' '-printf' 'sort -V' \
               'touch -d' 'stat --format' 'flock' 'head -n -' 'mv -T' 'cp --parents' 'set -e' 'trap ' \
               '-mtime' 'uname' 'sort -rn -u' '/home/' '/Users/' 'brew ' 'gtac' 'gstat'; do
        if printf '%s\n' "$code" | grep -F -q -- "$pat"; then viol="$viol [$pat]"; fi
    done
    t_eq "$s forbidden constructs" "$viol" ""
    t_eq "$s umask 077" "$(printf '%s\n' "$code" | grep -c '^umask 077$')" "1"
done

# =====================================================================
CUR="context-pressure"

new_env; mk_tr 100000; cp_run
t_eq "below threshold: no output" "$OUT" ""
t_eq "below threshold: exit 0" "$RC" "0"
t_false "below threshold: no state" test -e "$S/$SID"
t_false "below threshold: no marker" test -e "$(marker_path)"

new_env; mk_tr 350000; cp_run
M=$(msg_of)
t_eq "above threshold: exit 0" "$RC" "0"
t_eq "above threshold: event name" "$(printf '%s' "$OUT" | jq -r '.hookSpecificOutput.hookEventName' 2>/dev/null)" "UserPromptSubmit"
t_has "above threshold: ctx in message" "$M" "350000"
t_has "above threshold: threshold in message" "$M" "threshold 300000"
t_eq "above threshold: state bucket" "$(state_of)" "3"
t_eq "above threshold: state bucket and 10K step" "$(cat "$S/$SID")" "3 35"
t_true "above threshold: marker exists" test -f "$(marker_path)"
t_true "above threshold: marker is epoch" bash -c "case \"\$(cat '$(marker_path)')\" in *[!0-9]*|'') exit 1;; esac"
t_has "msg: handoff path has project prefix" "$M" "$P/.claude/${PNAME}-handoff-${SID}.md"
t_has "msg: no title: folder name in the name rule" "$M" "starts with the session name the user sees in the app (${PNAME})"
t_has "msg: no title: line 1 rule names the folder name" "$M" "starts with that name: ${PNAME}."
t_has "msg: CLEAR or COMPACT line" "$M" "CLEAR or COMPACT"
t_has "msg: CLEAR line names the context size" "$M" "the context size as ~350K tokens"
t_has "msg: newest size note wins" "$M" "use the newest one"
t_has "msg: usage-limit block stays last" "$M" "right before that block"
t_has "msg: memory step" "$M" "First, save to memory"
t_has "msg: handoff step" "$M" "Second, write the handoff"
pm=${M%%First, save to memory*}; ph=${M%%Second, write the handoff*}
t_true "msg: memory comes before handoff" test "${#pm}" -lt "${#ph}"
t_has "msg: READ FIRST" "$M" "READ FIRST"
t_has "msg: open items" "$M" "open items"
t_has "msg: absolute paths" "$M" "absolute paths only"
t_has "msg: 6000 chars" "$M" "6000 characters"
t_has "msg: byte limit" "$M" "7000 bytes"
t_has "msg: carry forward" "$M" "carry their still-open items forward"
t_has "msg: carry-forward glob matches prefixed names" "$M" "earlier *handoff*.md files"
t_has "msg: carry forward only the same task" "$M" "of this same task"
t_has "msg: other tasks left out" "$M" "Leave out the items of other, unrelated tasks"
t_has "msg: never delete open item" "$M" "never delete an open item"
t_has "msg: secrets" "$M" "never put them in the handoff"
t_has "msg: not guaranteed" "$M" "not guaranteed"
t_has "msg: confirmation line" "$M" "Handoff yüklendi"
t_no "msg: no auto-load promise (will be loaded)" "$M" "will be loaded"
t_no "msg: no auto-load promise (automatically)" "$M" "automatically"
t_no "msg: no auto-load promise (is loaded)" "$M" "is loaded"

new_env; mk_tr 350000; cp_run; mk_tr 359000; cp_run
t_eq "same 10K step: silent" "$OUT" ""
mk_tr 360000; cp_run
M=$(msg_of)
t_has "next 10K step: size note" "$M" "about 360000 tokens"
t_has "size note: rounded size for the CLEAR line" "$M" "as ~360K tokens"
t_no "size note: no second handoff request" "$M" "Second, write the handoff"
t_eq "size note: bucket kept" "$(cat "$S/$SID")" "3 36"
cp_run
t_eq "size note: once per step" "$OUT" ""
mk_tr 410000; cp_run
t_has "next bucket: warns again" "$(msg_of)" "410000"
t_has "next bucket: full note" "$(msg_of)" "Second, write the handoff"
t_eq "next bucket: state" "$(state_of)" "4"
mk_tr 320000; cp_run
t_has "shrink but above: size note" "$(msg_of)" "about 320000 tokens"
t_no "shrink but above: no handoff request" "$(msg_of)" "Second, write the handoff"
t_eq "shrink but above: bucket lowered" "$(state_of)" "3"
mk_tr 410000; cp_run
t_has "after lowered bucket: warns again" "$(msg_of)" "410000"
mk_tr 100000; cp_run
t_false "drop under threshold: state removed" test -e "$S/$SID"
t_false "drop under threshold: marker removed" test -e "$(marker_path)"
mk_tr 350000; cp_run
t_has "after reset: warns again" "$(msg_of)" "350000"

new_env; mk_tr 349600; cp_run
t_has "size rounded to the nearest K" "$(msg_of)" "as ~350K tokens"

new_env; mk_tr 350000; mkdir -p "$S"; echo 3 > "$S/$SID"; cp_run
t_has "state of an older version: size note" "$(msg_of)" "about 350000 tokens"
t_no "state of an older version: no handoff request" "$(msg_of)" "Second, write the handoff"
t_eq "state of an older version: rewritten" "$(cat "$S/$SID")" "3 35"

new_env; { usr; rec 100000; side 900000; } > "$TR"; cp_run
t_eq "sidechain huge usage skipped" "$OUT" ""
t_false "sidechain: no state" test -e "$S/$SID"

new_env; { usr; rec 350000; printf '%s' '{"type":"assistant","message":{"usage":{"input_tok'; } > "$TR"; cp_run
t_has "partial last line: previous record used" "$(msg_of)" "350000"
t_eq "partial last line: exit 0" "$RC" "0"

new_env; { usr; rec 100000; printf '%s' "$(rec 400000)"; } > "$TR"; cp_run
t_has "last record without newline is read" "$(msg_of)" "400000"
t_eq "last record without newline: bucket" "$(state_of)" "4"

new_env; cp_run
t_eq "missing transcript: silent" "$OUT" ""
t_eq "missing transcript: exit 0" "$RC" "0"
t_false "missing transcript: nothing logged" test -s "$LOGF"

new_env; mk_tr 350000
if [ "$(id -u)" != "0" ]; then
    chmod 000 "$TR"; cp_run; chmod 644 "$TR"
    t_eq "unreadable transcript: silent" "$OUT" ""
    t_eq "unreadable transcript: exit 0" "$RC" "0"
    t_has "unreadable transcript: logged" "$(cat "$LOGF" 2>/dev/null)" "transcript not readable"
fi

new_env; mk_tr 350000; cp_run "../etc/x"
t_eq "bad session id: exit 0" "$RC" "0"
t_eq "bad session id: silent" "$OUT" ""
t_has "bad session id: logged" "$(cat "$LOGF" 2>/dev/null)" "invalid session_id"
t_false "bad session id: no state dir content" test -e "$S/pending.d"
long=$(printf 'a%.0s' $(seq 1 129)); cp_run "$long"
t_has "session id of 129 chars rejected" "$(cat "$LOGF" 2>/dev/null)" "invalid session_id"

new_env; run context-pressure.sh 'this is not json'
t_eq "invalid JSON: exit 0" "$RC" "0"
t_has "invalid JSON: logged" "$(cat "$LOGF" 2>/dev/null)" "not valid JSON"
run context-pressure.sh '5'
t_eq "JSON number: exit 0" "$RC" "0"
t_has "JSON number: logged" "$(cat "$LOGF" 2>/dev/null)" "invalid session_id"
run context-pressure.sh '"str"'
t_eq "JSON string: exit 0" "$RC" "0"

new_env; mk_tr 350000; cp_run "" CTX_PRESSURE_THRESHOLD=abc
t_has "non-numeric threshold: logged" "$(cat "$LOGF" 2>/dev/null)" "invalid CTX_PRESSURE_THRESHOLD"
t_has "non-numeric threshold: default used" "$(msg_of)" "threshold 300000"
t_eq "non-numeric threshold: exit 0" "$RC" "0"

new_env; mk_tr 150000; cp_run "" CTX_PRESSURE_THRESHOLD=100000
t_has "threshold env respected (low)" "$(msg_of)" "threshold 100000"
new_env; mk_tr 350000; cp_run "" CTX_PRESSURE_THRESHOLD=500000
t_eq "threshold env respected (high)" "$OUT" ""
new_env; mk_tr 350000; cp_run "" CTX_PRESSURE_THRESHOLD=0300000
t_has "threshold with a leading zero read as decimal" "$(msg_of)" "threshold 300000"
new_env; mk_tr 350000; cp_run "" CTX_PRESSURE_THRESHOLD=1234567890
t_has "threshold of 10 digits rejected" "$(cat "$LOGF" 2>/dev/null)" "invalid CTX_PRESSURE_THRESHOLD"

# Threshold from the context window that the usage-feed mod writes (B16).
cw_file() { mkdir -p "$H/.claude/usage-feed"; printf '{"ts":1,"by":"%s","window":%s}\n' "$SID" "$1" > "$H/.claude/usage-feed/context-$SID.json"; }
new_env; cw_file 200000; mk_tr 130000; cp_run
t_has "window 200K: warns at 60% (120000)" "$(msg_of)" "threshold 120000"
new_env; cw_file 200000; mk_tr 110000; cp_run
t_eq "window 200K: silent under 120000" "$OUT" ""
new_env; cw_file 1000000; mk_tr 350000; cp_run
t_has "window 1M: threshold stays 300000" "$(msg_of)" "threshold 300000"
new_env; mk_tr 130000; cp_run
t_eq "no window file: 300000, silent at 130000" "$OUT" ""
new_env; cw_file 200000; mk_tr 130000; cp_run "" CTX_PRESSURE_THRESHOLD=150000
t_eq "threshold env wins over the window" "$OUT" ""
new_env; cw_file 200000; mk_tr 110000; cp_run "" CTX_PRESSURE_WINDOW_PCT=50
t_has "window percent setting (50%: 100000)" "$(msg_of)" "threshold 100000"
new_env; cw_file 200000; mk_tr 130000; cp_run "" CTX_PRESSURE_WINDOW_PCT=abc
t_has "invalid window percent: logged" "$(cat "$LOGF" 2>/dev/null)" "invalid CTX_PRESSURE_WINDOW_PCT"
t_has "invalid window percent: 60 used" "$(msg_of)" "threshold 120000"
new_env; mkdir -p "$H/.claude/usage-feed"; echo 'not json' > "$H/.claude/usage-feed/context-$SID.json"; mk_tr 130000; cp_run
t_eq "bad window file: ignored" "$OUT" ""
new_env; mkdir -p "$H/.claude/usage-feed"; : > "$H/.claude/usage-feed/context-old.json"; : > "$H/.claude/usage-feed/context-new.json"
set_mtime "$H/.claude/usage-feed/context-old.json" "$(( $(now) - 10 * 86400 ))"; mk_tr 1000; cp_run
t_false "context file older than 7 days: pruned" test -e "$H/.claude/usage-feed/context-old.json"
t_true "recent context file: kept" test -e "$H/.claude/usage-feed/context-new.json"

new_env; { usr; usr; } > "$TR"; cp_run
t_eq "no usage yet: silent" "$OUT" ""
t_false "no usage yet: nothing logged" test -s "$LOGF"

new_env; mk_tr 350000
cp_run "$(printf 'sess\001ion-x')"
t_eq "control chars in session id: exit 0" "$RC" "0"
t_eq "control chars: none reach the log" "$(LC_ALL=C tr -d '\040-\176\n' < "$LOGF" | wc -c | tr -d ' ')" "0"

new_env; mk_tr 350000; OTHER="$E/other-root"; mkdir -p "$OTHER"
run context-pressure.sh "$(cp_json)" CLAUDE_PROJECT_DIR="$OTHER"
t_true "CLAUDE_PROJECT_DIR wins over cwd (marker)" test -f "$S/pending.d/$(sha1_16 "$OTHER")/$SID"
t_false "CLAUDE_PROJECT_DIR wins over cwd (no cwd marker)" test -e "$S/pending.d/$PH"
t_has "CLAUDE_PROJECT_DIR wins over cwd (path)" "$(msg_of)" "$OTHER/.claude/other-root-handoff-$SID.md"

new_env; mk_tr 350000; cp_run
t_true "state dir mode 700" bash -c "ls -ld '$S' | cut -c1-10 | grep -q '^drwx------\$'"

new_env; mk_tr 350000; mkdir -p "$S/pending.d/$PH"; echo 1 > "$S/pending.d/$PH/$SID.offered"; cp_run
t_false "legacy .offered removed on emit" test -e "$S/pending.d/$PH/$SID.offered"

new_env; mk_tr 350000; run context-pressure.sh "$(cp_batch_json)"
t_has "PostToolBatch: warns above threshold" "$(msg_of)" "350000"
t_eq "PostToolBatch: event name echoed" "$(printf '%s' "$OUT" | jq -r '.hookSpecificOutput.hookEventName' 2>/dev/null)" "PostToolBatch"
t_eq "PostToolBatch: state bucket" "$(state_of)" "3"
t_true "PostToolBatch: marker exists" test -f "$(marker_path)"
cp_run
t_eq "PostToolBatch then prompt: same bucket silent" "$OUT" ""
mk_tr 365000; run context-pressure.sh "$(cp_batch_json)"
t_has "PostToolBatch: size note" "$(msg_of)" "about 365000 tokens"
t_eq "PostToolBatch: size note event name" "$(printf '%s' "$OUT" | jq -r '.hookSpecificOutput.hookEventName' 2>/dev/null)" "PostToolBatch"
mk_tr 410000; run context-pressure.sh "$(cp_batch_json)"
t_has "PostToolBatch: next bucket warns" "$(msg_of)" "410000"
new_env; mk_tr 350000; run context-pressure.sh "$(cp_batch_json "" agent-1)"
t_eq "PostToolBatch of a subagent: silent" "$OUT" ""
t_false "PostToolBatch of a subagent: no state" test -e "$S/$SID"
new_env; mk_tr 350000; run context-pressure.sh "$(cp_json | jq -c '.hook_event_name = "Notification"')"
t_eq "unexpected event: silent" "$OUT" ""
t_has "unexpected event: logged" "$(cat "$LOGF")" "unexpected event"
new_env; mk_tr 350000; run context-pressure.sh "$(cp_json | jq -c 'del(.hook_event_name)')"
t_eq "missing event name: treated as UserPromptSubmit" "$(printf '%s' "$OUT" | jq -r '.hookSpecificOutput.hookEventName' 2>/dev/null)" "UserPromptSubmit"

new_env; run context-pressure.sh 'not json' CLAUDE_CONFIG_DIR="$E/cfg"
t_has "CLAUDE_CONFIG_DIR: log under the config dir" "$(cat "$E/cfg/hooks/context-pressure.log" 2>/dev/null)" "not valid JSON"
t_false "CLAUDE_CONFIG_DIR: no log under HOME" test -s "$LOGF"

# Bulk handoff (2026-11-25): the marker [oturum:toplu-devir] in a prompt asks for the
# handoff at once, with no threshold.
new_env; mk_tr 50000; run context-pressure.sh "$(cp_prompt_json "$BULK_PROMPT")"
t_has "bulk: request header below the threshold" "$(msg_of)" "Bulk handoff request"
t_has "bulk: handoff path" "$(msg_of)" "$P/.claude/${PNAME}-handoff-${SID}.md"
t_has "bulk: detail note path" "$(msg_of)" "$P/.claude/${PNAME}-handoff-${SID}.detay.md"
t_true "bulk: pending marker exists" test -f "$(marker_path)"
t_true "bulk: bulk flag exists" test -f "$S/$SID.bulk"
t_true "bulk: turn file exists" test -f "$S/$SID.turn"
run context-pressure.sh "$(cp_batch_json)"
t_true "bulk: marker survives a PostToolBatch below the threshold" test -f "$(marker_path)"
stop_run "$CLEARLINE"
t_eq "bulk: CLEAR line without a handoff is sent back" "$(dec_of)" "block"
run context-pressure.sh "$(cp_prompt_json "yeni istem")"
t_false "bulk: new turn without the marker removes the pending marker" test -e "$(marker_path)"
t_false "bulk: new turn without the marker removes the bulk flag" test -e "$S/$SID.bulk"

new_env; mk_tr 50000; run context-pressure.sh "$(cp_prompt_json "sıradan istem")"
t_eq "bulk: no marker below the threshold: silent" "$OUT" ""
t_false "bulk: no marker below the threshold: no pending marker" test -e "$(marker_path)"

new_env; mk_tr 50000
WRAPPED=$'Another Claude session sent a message:\n<cross-session-message from="bridge:session_x" from-name="A" from-mode="prompting">\nToplu devir isteği [oturum:toplu-devir]: ...\n</cross-session-message>'
run context-pressure.sh "$(cp_prompt_json "$WRAPPED")"
t_has "bulk: marker inside the cross-session wrapper" "$(msg_of)" "Bulk handoff request"
t_true "bulk: wrapper: pending marker exists" test -f "$(marker_path)"

new_env; mk_tr 350000; run context-pressure.sh "$(cp_prompt_json "$BULK_PROMPT")"
t_has "bulk: request above the threshold" "$(msg_of)" "Bulk handoff request"
t_eq "bulk: above the threshold: bucket recorded" "$(state_of)" "3"
t_no "bulk: no threshold text in the bulk request" "$(msg_of)" "Context pressure:"
run context-pressure.sh "$(cp_batch_json)"
t_no "bulk: PostToolBatch at the same size sends no threshold request" "$(msg_of)" "Context pressure:"

new_env; mk_tr 50000; run context-pressure.sh "$(cp_prompt_json "$BULK_PROMPT" agent-1)"
t_eq "bulk: subagent prompt: silent" "$OUT" ""
t_false "bulk: subagent prompt: no pending marker" test -e "$(marker_path)"

new_env; { usr; title_rec "MyProject"; rec 50000; } > "$TR"; run context-pressure.sh "$(cp_prompt_json "$BULK_PROMPT")"
t_has "bulk: handoff file name starts with the title" "$(msg_of)" "$P/.claude/MyProject-handoff-${SID}.md"
t_has "bulk: request names the title" "$(msg_of)" "starts with that name: MyProject."

# git: the hook names a handoff path that git would pick up. Skipped where git is not on PATH.
if command -v git >/dev/null 2>&1; then
    new_env; git init -q "$P" 2>/dev/null; mk_tr 350000; cp_run
    t_has "git repo, handoff not ignored: note" "$(msg_of)" "not git-ignored"
    t_has "git repo: suggested exclude line" "$(msg_of)" "**/.claude/*handoff*.md"
    new_env; git init -q "$P" 2>/dev/null; printf '%s\n' '**/.claude/*handoff*.md' >> "$P/.git/info/exclude"; mk_tr 350000; cp_run
    t_has "git repo, handoff ignored: still warns" "$(msg_of)" "350000"
    t_no "git repo, handoff ignored: no note" "$(msg_of)" "not git-ignored"
    new_env; mk_tr 350000; cp_run
    if ! git -C "$P" rev-parse --is-inside-work-tree >/dev/null 2>&1; then
        t_no "no git repo: no note" "$(msg_of)" "not git-ignored"
    fi
fi

new_env; awk 'BEGIN { for (i = 0; i < 14000; i++) print "2026-01-01T00:00:00Z filler line " i " xxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxx" }' > "$LOGF"
mk_tr 100000; cp_run "x/y"
t_true "log trimmed under 1 MB" test "$(wc -c < "$LOGF" | tr -d ' ')" -lt 1048576
t_true "log trimmed to about 200 lines" test "$(lines "$LOGF")" -lt 210

# The handoff file name follows the session name in the app (2026-11-06).
new_env; { usr; title_rec "Eski ad"; title_rec "MyProject"; rec 350000; } > "$TR"; cp_run
t_has "name: newest customTitle in the file name" "$(msg_of)" "$P/.claude/MyProject-handoff-${SID}.md"
t_has "name: line 1 rule names the title" "$(msg_of)" "starts with that name: MyProject."
new_env; { usr; title_rec "Açık PR'lar özeti / v2"; rec 350000; } > "$TR"; cp_run
t_has "name: Turkish letters and symbols" "$(msg_of)" "$P/.claude/Acik-PR-lar-ozeti-v2-handoff-${SID}.md"
t_has "name: line 1 rule keeps the title as shown" "$(msg_of)" "starts with that name: Açık PR'lar özeti / v2."
new_env; mk_tr 350000; cp_run "" CLAUDE_CODE_SESSION_NAME="Web portal (v2)"
t_has "name: CLAUDE_CODE_SESSION_NAME without a title record" "$(msg_of)" "$P/.claude/Web-portal-v2-handoff-${SID}.md"
new_env; { usr; title_rec "MyProject"; rec 350000; } > "$TR"; cp_run "" CLAUDE_CODE_SESSION_NAME="my-project"
t_has "name: customTitle wins over the launch name" "$(msg_of)" "$P/.claude/MyProject-handoff-${SID}.md"
new_env; { usr; printf '%s\n' '{"type":"ai-title","aiTitle":"Hook adları"}'; rec 350000; } > "$TR"; cp_run
t_has "name: aiTitle as the last title source" "$(msg_of)" "$P/.claude/Hook-adlari-handoff-${SID}.md"
new_env; { usr; title_rec "$(printf '%080d' 0 | tr 0 x)"; rec 350000; } > "$TR"; cp_run
t_has "name: cut to 50 characters" "$(msg_of)" "/.claude/$(printf '%050d' 0 | tr 0 x)-handoff-${SID}.md"
new_env; { usr; title_rec "!!!"; rec 350000; } > "$TR"; cp_run
t_has "name: title without letters: folder name" "$(msg_of)" "$P/.claude/${PNAME}-handoff-${SID}.md"

new_env; { usr; title_rec "MyProject"; rec 350000; } > "$TR"; OLD=$(mk_handoff "$SID" 60 "# old name"); cp_run
t_has "rename: message names the new path" "$(msg_of)" "$P/.claude/MyProject-handoff-${SID}.md"
t_false "rename: folder-name file gone" test -e "$OLD"
t_eq "rename: content kept" "$(head -n 1 "$P/.claude/MyProject-handoff-${SID}.md" 2>/dev/null)" "# old name"
t_has "rename: logged" "$(cat "$LOGF")" "handoff renamed to the session name: ${PNAME}-handoff-${SID}.md -> MyProject-handoff-${SID}.md"
new_env; { usr; title_rec "MyProject"; rec 350000; } > "$TR"; mk_handoff "$SID" 60 "# legacy" "" >/dev/null; cp_run
t_eq "rename: older handoff-<id>.md moved" "$(head -n 1 "$P/.claude/MyProject-handoff-${SID}.md" 2>/dev/null)" "# legacy"
new_env; { usr; title_rec "MyProject"; rec 350000; } > "$TR"
A1=$(mk_handoff "$SID" 60 "# folder name"); A2=$(mk_handoff "$SID" 30 "# title name" "MyProject-"); cp_run
t_true "both names: nothing renamed" test -f "$A1"
t_has "both names: message names the title path" "$(msg_of)" "$A2"
new_env; { usr; title_rec "MyProject"; rec 350000; } > "$TR"; O=$(mk_handoff "$ID_A" 60); cp_run
t_true "rename: another session's file untouched" test -f "$O"

# =====================================================================
CUR="stop-check"
# Handoff check on Stop (2026-11-07): a reply with the CLEAR or COMPACT line must not
# end a turn that did not write the handoff.

t_eq "JQ_KIND is the same in both scripts" "$(jqk "$HOOKS/context-pressure.sh")" "$(jqk "$HOOKS/handoff-load.sh")"
t_true "JQ_KIND found" test -n "$(jqk "$HOOKS/context-pressure.sh")"

new_env; mk_tr 350000; cp_run
t_has "text: the warning asks for an update in every CLEAR turn" "$(msg_of)" "every reply that ends with the CLEAR or COMPACT line updates the handoff in the same turn"
t_has "text: the warning names the Stop check" "$(msg_of)" "A Stop hook checks this"
t_false "turn: no turn file in the run that sets the marker" test -e "$S/$SID.turn"
cp_run
t_true "turn: a prompt of a marked session stores the turn start" test -s "$S/$SID.turn"
mk_tr 365000; cp_run
t_has "text: the size note asks for the update" "$(msg_of)" "first update the handoff with this turn"
mk_tr 100000; cp_run
t_false "turn: back under the threshold removes the turn file" test -e "$S/$SID.turn"

new_env; mk_tr 350000; cp_run; HF=$(mk_handoff "$SID" 300); turn_at 60
stop_run "Cevap metni.
$CLEARLINE"
t_eq "stale handoff + CLEAR line: exit 0" "$RC" "0"
t_eq "stale handoff + CLEAR line: valid JSON" "$(printf '%s' "$OUT" | jq -e . >/dev/null 2>&1; echo $?)" "0"
t_eq "stale handoff + CLEAR line: block" "$(dec_of)" "block"
t_has "reason names the handoff" "$(reason_of)" "$HF"
t_has "reason gives both times in Turkey time" "$(reason_of)" "Turkey time (UTC+3), before this turn started at"
t_has "reason asks for this turn" "$(reason_of)" "the user's last request and where it stands"
t_has "reason: the line alone" "$(reason_of)" "do not repeat the rest of the reply"
t_has "stale handoff: logged" "$(cat "$LOGF")" "stop: handoff older than the turn in $SID"
stop_run "x
$CLEARLINE" true
t_eq "stop_hook_active: silent" "$OUT" ""
stop_run "Cevap, son satır yok."
t_eq "no CLEAR line: silent" "$OUT" ""
stop_run "Bu metin CLEAR ~352K satırını anlatıyor ama satır başında değil."
t_eq "CLEAR inside a sentence: silent" "$OUT" ""
stop_run "CLEARED ~5K of cache"
t_eq "CLEARED is not the line: silent" "$OUT" ""
stop_run "CLEAR ve COMPACT farkı"
t_eq "CLEAR without a size: silent" "$OUT" ""
stop_run "**COMPACT** ~352K tokens: canlı akıl yürütme var."
t_eq "bold COMPACT line counts" "$(dec_of)" "block"
stop_run "$(printf 'metin\n%s\n\n⚠️ Kullanım limiti eşiği aşıldı\n```text\nÖnceki oturum kullanım limiti eşiğinde durdu.\n```' "$CLEARLINE")"
t_eq "CLEAR line before the usage-limit block counts" "$(dec_of)" "block"
set_mtime "$HF" $(( $(now) - 10 )); mk_detail "$HF" >/dev/null
stop_run "$(tline "$HF")"
t_eq "handoff written in this turn, line gives its time: silent" "$OUT" ""
run context-pressure.sh "$(stop_json "$CLEARLINE" | jq -c '.agent_id = "a1"')"
t_eq "stop of a subagent: silent" "$OUT" ""

new_env; mk_tr 350000; cp_run; turn_at 60
stop_run "$CLEARLINE"
t_eq "no handoff file: block" "$(dec_of)" "block"
t_has "no handoff file: says so" "$(reason_of)" "does not exist"
t_has "no handoff file: expected path" "$(reason_of)" "$P/.claude/${PNAME}-handoff-${SID}.md"

new_env; mk_tr 200000; mk_handoff "$SID" 300 >/dev/null; turn_at 60
stop_run "$CLEARLINE"
t_eq "no pending marker: silent" "$OUT" ""

new_env; mk_tr 350000; cp_run; mk_handoff "$SID" 300 >/dev/null
{ urec $(( $(now) - 400 )) "eski istem"; arec $(( $(now) - 390 )) "a"; urec $(( $(now) - 60 )) "yeni istem"; } >> "$TR"
stop_run "$CLEARLINE"
t_eq "turn start from the transcript: block" "$(dec_of)" "block"
new_env; mk_tr 350000; cp_run; mk_handoff "$SID" 300 >/dev/null
urec $(( $(now) - 60 )) "<ci-monitor-event>CI green</ci-monitor-event>" >> "$TR"
stop_run "$CLEARLINE"
t_eq "turn started by an event: block" "$(dec_of)" "block"
new_env; mk_tr 350000; cp_run; HF=$(mk_handoff "$SID" 30); mk_detail "$HF" >/dev/null
{ urec $(( $(now) - 60 )) "istem"; toolres $(( $(now) - 5 )); } >> "$TR"
stop_run "$(tline "$HF")"
t_eq "a tool result is not a turn start: silent" "$OUT" ""
new_env; mk_tr 350000; cp_run; mk_handoff "$SID" 300 >/dev/null; turn_at 600
urec $(( $(now) - 60 )) "yeni istem" >> "$TR"
stop_run "$CLEARLINE"
t_eq "the later of turn file and transcript wins: block" "$(dec_of)" "block"

new_env; mk_tr 350000; cp_run; mk_handoff "$SID" 300 >/dev/null; turn_at 60
arec $(( $(now) - 5 )) "metin
$CLEARLINE" >> "$TR"
run context-pressure.sh "$(stop_json "" | jq -c 'del(.last_assistant_message)')"
t_eq "without last_assistant_message the transcript text is used" "$(dec_of)" "block"

new_env; mk_tr 350000; cp_run; mk_handoff "$SID" 300 >/dev/null
stop_run "$CLEARLINE"
t_eq "no turn start known: silent" "$OUT" ""
t_has "no turn start known: logged" "$(cat "$LOGF")" "stop: no turn start for $SID"

new_env; mk_tr 350000; cp_run; turn_at 60
mk_handoff "$SID" 300 "# MyProject" "MyProject-" >/dev/null
printf '%s\n' "$(title_rec "MyProject")" >> "$TR"
stop_run "$CLEARLINE"
t_has "session-named handoff found by id" "$(reason_of)" "$P/.claude/MyProject-handoff-${SID}.md"
t_has "session-named handoff: its time is given" "$(reason_of)" "was last written at"

# =====================================================================
CUR="handoff-time"
# The CLEAR or COMPACT line gives the handoff's last write time in Turkey time (2026-11-13).

new_env; mk_tr 350000; cp_run
M=$(msg_of)
t_has "text: the warning asks for the handoff time" "$M" "the handoff's last write time as \"handoff HH:MM\" in Turkey time (UTC+3"
t_has "text: the warning names the time note" "$M" "this hook sends a 'Handoff time' note with it"
t_has "text: the Stop check covers the time" "$M" "or whose line gives another handoff time, is sent back once"
mk_tr 365000; cp_run
t_has "text: the size note asks for the time" "$(msg_of)" "and the handoff time as 'handoff HH:MM' (Turkey time"

# The line after a write in this turn.
new_env; mk_tr 350000; cp_run; turn_at 60; HF=$(mk_handoff "$SID" 10); mk_detail "$HF" >/dev/null; HM=$(tr_hm "$(file_mt "$HF")")
stop_run "Cevap.
$CLEARLINE"
t_eq "line without the time: block" "$(dec_of)" "block"
t_has "line without the time: says so" "$(reason_of)" "gives no handoff time"
t_has "line without the time: right time given" "$(reason_of)" "was last written at ${HM} Turkey time (UTC+3)"
t_has "line without the time: format given" "$(reason_of)" "with \"handoff ${HM}\" in it"
t_has "line without the time: names the file" "$(reason_of)" "$HF"
t_has "line without the time: the line alone" "$(reason_of)" "do not repeat the rest of the reply"
t_has "line without the time: logged" "$(cat "$LOGF")" "stop: handoff time in the line is '', not ${HM}, in $SID, reply sent back"
stop_run "$CLEARLINE" true
t_eq "line without the time, stop_hook_active: silent" "$OUT" ""
stop_run "CLEAR · ~352K token · iş bitti · handoff ${HM} · $HF"
t_eq "user's format with the right time: silent" "$OUT" ""
stop_run "CLEAR ~352K tokens: bağlam dolu, handoff güncel (${HM}) · $HF"
t_eq "time in brackets after handoff: silent" "$OUT" ""
stop_run "**COMPACT** ~352K tokens: canlı akıl yürütme var, Handoff ${HM}, $HF"
t_eq "COMPACT line, capital Handoff: silent" "$OUT" ""
W=$(tr_hm $(( $(file_mt "$HF") + 3600 )))
stop_run "CLEAR ~352K tokens: iş bitti · handoff ${W} · $HF"
t_eq "wrong time: block" "$(dec_of)" "block"
t_has "wrong time: names what the line said" "$(reason_of)" "says handoff ${W}"
t_has "wrong time: right time given" "$(reason_of)" "\"handoff ${HM}\""
stop_run "CLEAR ~352K tokens: 14:00'te başladı, iş bitti · $HF"
t_eq "a time that is not the handoff time does not count: block" "$(dec_of)" "block"
stop_run "Saat ${HM} oldu.
CLEAR ~352K tokens: iş bitti · $HF"
t_eq "a time outside the line does not count: block" "$(dec_of)" "block"
stop_run "CLEAR ~350K tokens · handoff ${HM}
Bir düzeltme daha yapıldı.
CLEAR ~352K tokens: iş bitti · handoff ${W} · $HF"
t_eq "the last line counts: block" "$(dec_of)" "block"
stop_run "CLEAR ~352K tokens: iş bitti · $P/.claude/MyProject-handoff-12345678-1234.md"
t_eq "digits of a path are no time: block" "$(dec_of)" "block"

# Turkey time is UTC+3 all year: 2026-01-01 21:30 UTC is 00:30 there, 06:05 UTC is 09:05.
new_env; mk_tr 350000; cp_run; HF=$(mk_handoff "$SID"); mk_detail "$HF" >/dev/null
E1=$(jq -n -r '"2026-01-01T21:30:00Z" | fromdateiso8601'); set_mtime "$HF" "$E1"; at_epoch $(( E1 - 60 ))
stop_run "CLEAR ~352K tokens: iş bitti · handoff 00:30 · $HF"
t_eq "TR time past midnight: silent" "$OUT" ""
stop_run "CLEAR ~352K tokens: iş bitti · handoff 21:30 · $HF"
t_eq "UTC time instead of TR time: block" "$(dec_of)" "block"
t_has "UTC time instead of TR time: TR time given" "$(reason_of)" "\"handoff 00:30\""
E2=$(jq -n -r '"2026-01-01T06:05:00Z" | fromdateiso8601'); set_mtime "$HF" "$E2"; at_epoch $(( E2 - 60 ))
stop_run "CLEAR ~352K tokens: iş bitti · handoff 9:05 · $HF"
t_eq "one-digit hour counts: silent" "$OUT" ""
stop_run "CLEAR ~352K tokens: iş bitti · handoff 09:05 · $HF"
t_eq "two-digit hour: silent" "$OUT" ""

# Stale handoff: the reason asks for the new time too.
new_env; mk_tr 350000; cp_run; mk_handoff "$SID" 300 >/dev/null; turn_at 60
stop_run "$CLEARLINE"
t_has "stale: reason asks for the new time" "$(reason_of)" "with the new write time of the handoff as \"handoff HH:MM\""

# The note after a write of the handoff (PostToolBatch).
new_env; mk_tr 350000; cp_run; HF=$(mk_handoff "$SID")
run context-pressure.sh "$(cp_batch_json)"
M=$(msg_of); HM=$(tr_hm "$(file_mt "$HF")")
t_eq "note: exit 0" "$RC" "0"
t_eq "note: one JSON object" "$(printf '%s' "$OUT" | jq -s length 2>/dev/null)" "1"
t_eq "note: event name" "$(printf '%s' "$OUT" | jq -r '.hookSpecificOutput.hookEventName' 2>/dev/null)" "PostToolBatch"
t_has "note: time and file" "$M" "Handoff time: $HF was last written at ${HM} Turkey time (UTC+3)."
t_has "note: the line format" "$M" "write that time in it as \"handoff ${HM}\""
t_eq "note: the noted mtime is stored" "$(cat "$S/$SID.hnote" 2>/dev/null)" "$(file_mt "$HF")"
run context-pressure.sh "$(cp_batch_json)"
t_eq "note: no new write: silent" "$OUT" ""
set_mtime "$HF" $(( $(now) + 61 ))
run context-pressure.sh "$(cp_batch_json)"
t_has "note: a newer write gives the new time" "$(msg_of)" "was last written at $(tr_hm "$(file_mt "$HF")") Turkey time"
cp_run
t_no "note: not on UserPromptSubmit" "$(msg_of)" "Handoff time:"
run context-pressure.sh "$(cp_batch_json "" a1)"
t_eq "note: not for a subagent batch" "$OUT" ""

new_env; mk_tr 350000; cp_run; HF=$(mk_handoff "$SID"); mk_tr 365000
run context-pressure.sh "$(cp_batch_json)"
M=$(msg_of)
t_eq "note with the size note: one JSON object" "$(printf '%s' "$OUT" | jq -s length 2>/dev/null)" "1"
t_has "note with the size note: size" "$M" "about 365000 tokens"
t_has "note with the size note: time" "$M" "Handoff time: $HF"
t_true "note with the size note: size first" test "$(line_no "$M" "Context size")" -lt "$(line_no "$M" "Handoff time:")"

new_env; mk_tr 350000; mk_handoff "$SID" 600 >/dev/null; cp_run
run context-pressure.sh "$(cp_batch_json)"
t_eq "note: a handoff older than the request: silent" "$OUT" ""
t_false "note: a handoff older than the request: nothing stored" test -e "$S/$SID.hnote"

new_env; mk_tr 200000; mk_handoff "$SID" >/dev/null
run context-pressure.sh "$(cp_batch_json)"
t_eq "note: no request yet: silent" "$OUT" ""
t_false "note: no request yet: nothing stored" test -e "$S/$SID.hnote"

new_env; mk_tr 350000; cp_run; mk_handoff "$SID" >/dev/null; mk_tr 100000
run context-pressure.sh "$(cp_batch_json)"
t_eq "note: back under the threshold: silent" "$OUT" ""
t_false "note: back under the threshold: no note file" test -e "$S/$SID.hnote"

# =====================================================================
CUR="session-end-mark"

new_env; se_run "$ID_A" other; se_run "$ID_B" other
EF="$S/ended/$PH"
t_eq "append: two calls = two lines" "$(lines "$EF")" "2"
t_eq "append: exit 0" "$RC" "0"
t_true "append: line format" bash -c "awk 'NR==1 { exit !(\$1 ~ /^[0-9]+\$/ && \$2 == \"$ID_A\" && \$3 == \"other\") }' '$EF'"
t_has "log line: reason session project" "$(cat "$LOGF")" "session-end: reason=other session=$ID_A project=$P"
t_eq "log line comes first" "$(head -n 1 "$LOGF" | cut -d" " -f2-3)" "session-end: reason=other"

new_env; se_run "$ID_A" clear; se_run "$ID_B" "we!rd reason"; se_run "$ID_C" other
t_eq "reason clear kept" "$(awk 'NR==1 {print $3}' "$S/ended/$PH")" "clear"
t_eq "odd reason becomes other" "$(awk 'NR==2 {print $3}' "$S/ended/$PH")" "other"
t_eq "reason other kept" "$(awk 'NR==3 {print $3}' "$S/ended/$PH")" "other"
se_run "$ID_D" "$(printf 'x%.0s' $(seq 1 65))"
t_eq "reason of 65 chars becomes other" "$(awk 'NR==4 {print $3}' "$S/ended/$PH")" "other"

new_env; se_run "../bad" other
t_eq "bad id: exit 0" "$RC" "0"
t_false "bad id: nothing written" test -e "$S/ended/$PH"
t_has "bad id: still logged" "$(cat "$LOGF")" "session-end: reason=other session=../bad"
run session-end-mark.sh 'not json'
t_eq "invalid JSON: exit 0" "$RC" "0"
t_has "invalid JSON: logged" "$(cat "$LOGF")" "stdin is not valid JSON"
t_false "invalid JSON: nothing written" test -e "$S/ended"

new_env; run session-end-mark.sh "$(jq -n -c --arg s "$ID_A" '{session_id:$s, reason:"other"}')"
t_eq "empty project: exit 0" "$RC" "0"
t_false "empty project: nothing written" test -e "$S/ended"

new_env; i=1; while [ "$i" -le 25 ]; do se_run "$(printf 'bbbbbbbb-0000-4000-8000-%012d' "$i")" other; i=$((i + 1)); done
t_eq "25 calls leave 20 lines" "$(lines "$S/ended/$PH")" "20"
t_eq "last line is the 25th" "$(tail -n 1 "$S/ended/$PH" | cut -d' ' -f2)" "bbbbbbbb-0000-4000-8000-000000000025"
t_eq "first kept line is the 6th" "$(head -n 1 "$S/ended/$PH" | cut -d' ' -f2)" "bbbbbbbb-0000-4000-8000-000000000006"

new_env; i=1
while [ "$i" -le 15 ]; do
    ( printf '%s' "$(se_json "$(printf 'cccccccc-0000-4000-8000-%012d' "$i")" other)" \
        | env -u CLAUDE_PROJECT_DIR -u CLAUDE_CONFIG_DIR -u CLAUDE_CODE_SESSION_NAME HOME="$H" CTX_PRESSURE_STATE_DIR="$S" "$HOOKS/session-end-mark.sh" >/dev/null 2>&1 ) &
    i=$((i + 1))
done
wait
t_eq "15 parallel calls: 15 lines" "$(lines "$S/ended/$PH")" "15"
t_eq "15 parallel calls: 15 distinct ids" "$(awk '{print $2}' "$S/ended/$PH" | sort -u | wc -l | tr -d ' ')" "15"
t_eq "15 parallel calls: no lock dir left" "$(ls "$S/ended" | grep -c lock)" "0"

new_env; i=1
while [ "$i" -le 30 ]; do
    ( printf '%s' "$(se_json "$(printf 'dddddddd-0000-4000-8000-%012d' "$i")" other)" \
        | env -u CLAUDE_PROJECT_DIR -u CLAUDE_CONFIG_DIR -u CLAUDE_CODE_SESSION_NAME HOME="$H" CTX_PRESSURE_STATE_DIR="$S" "$HOOKS/session-end-mark.sh" >/dev/null 2>&1 ) &
    i=$((i + 1))
done
wait
t_eq "30 parallel calls with trimming: exactly 20 lines" "$(lines "$S/ended/$PH")" "20"
t_eq "30 parallel calls with trimming: 20 distinct ids" "$(awk '{print $2}' "$S/ended/$PH" | sort -u | wc -l | tr -d ' ')" "20"
t_eq "30 parallel calls with trimming: no tmp or lock left" "$(ls "$S/ended" | grep -c -E 'lock|tmp')" "0"

new_env; mkdir -p "$S/ended"; mkdir "$S/ended/$PH.lock"; set_mtime "$S/ended/$PH.lock" $(( $(now) - 300 ))
se_run "$ID_A" other
t_eq "stale lock: line written" "$(lines "$S/ended/$PH")" "1"
t_false "stale lock: removed" test -e "$S/ended/$PH.lock"

new_env; mkdir -p "$S/ended"; i=1
while [ "$i" -le 20 ]; do printf '%s eeeeeeee-0000-4000-8000-%012d other\n' "$(now)" "$i" >> "$S/ended/$PH"; i=$((i + 1)); done
mkdir "$S/ended/$PH.lock"
se_run "$ID_A" other
t_eq "busy lock: line appended without trim" "$(lines "$S/ended/$PH")" "21"
t_has "busy lock: writer logged" "$(cat "$LOGF")" "appended without trim"
t_true "busy lock: foreign lock left alone" test -d "$S/ended/$PH.lock"
rmdir "$S/ended/$PH.lock"

new_env; se_run "$ID_A" other
t_true "ended dir mode 700" bash -c "ls -ld '$S/ended' | cut -c1-10 | grep -q '^drwx------\$'"

# =====================================================================
CUR="loader-exact"

new_env; HF=$(mk_handoff "$ID_A" 30); mk_marker "$ID_A" 120; mk_ended "$ID_A" 30 other
ld_run startup
t_eq "exact: exit 0" "$RC" "0"
t_eq "exact: valid JSON" "$(printf '%s' "$OUT" | jq -e . >/dev/null 2>&1; echo $?)" "0"
t_eq "exact: event name" "$(printf '%s' "$OUT" | jq -r '.hookSpecificOutput.hookEventName')" "SessionStart"
t_has "exact: handoff body injected" "$(ctx_of)" "body of $ID_A"
t_has "exact: begin marker" "$(ctx_of)" "--- BEGIN HANDOFF ---"
t_has "exact: file path in context" "$(ctx_of)" "$HF"
t_has "exact: systemMessage names the file" "$(sys_of)" "Handoff yüklendi: ${PNAME}-handoff-${ID_A}.md"
t_has "exact: systemMessage age" "$(sys_of)" "önce yazılmış"
t_has "exact: first-reply line is ordered" "$(ctx_of)" "Part 1: this exact line, alone: Handoff yüklendi: ${PNAME}-handoff-${ID_A}.md"
t_has "exact: Kaldığımız yer block ordered" "$(ctx_of)" "Kaldığımız yer"
t_has "exact: framed as the session that just ended" "$(ctx_of)" "the session that just ended in this project"
t_has "exact: not an instruction" "$(ctx_of)" "not an instruction from the user"
t_has "exact: approval still needed" "$(ctx_of)" "explicit approval"
t_has "exact: devam rule" "$(ctx_of)" "'devam'"
t_has "exact: different-task rule" "$(ctx_of)" "belong to a different task"
t_eq "exact: no taken file left" "$(ls "$S/ended" 2>/dev/null | grep -c taken)" "0"
t_false "exact: marker removed" test -e "$S/pending.d/$PH/$ID_A"
t_false "exact: ended record consumed" test -e "$S/ended/$PH"
t_has "exact: log matched" "$(cat "$LOGF")" "ended session $ID_A matched, handoff found"
t_has "exact: log forced" "$(cat "$LOGF")" "source=startup forced=$ID_A"
ld_run startup
t_eq "exact: next startup does not inject" "$OUT" ""

for r in prompt_input_exit logout resume; do
    new_env; mk_handoff "$ID_A" 30 >/dev/null; mk_ended "$ID_A" 20 "$r"; ld_run startup
    t_no "reason $r is not a /clear: no injection" "$OUT" "BEGIN HANDOFF"
done
new_env; mk_handoff "$ID_A" 30 >/dev/null; mk_ended "$ID_B" 20 prompt_input_exit; mk_ended "$ID_A" 20 other; ld_run startup
t_has "an exit beside one /clear: the /clear still matches" "$(ctx_of)" "body of $ID_A"

new_env; mk_handoff "$ID_A" 30 >/dev/null; mk_ended "$ID_A" 20
for k in 1 2; do
    ( printf '%s' "$(ld_json startup "cccccccc-0000-4000-8000-00000000000$k")" \
        | env -u CLAUDE_PROJECT_DIR -u CLAUDE_CONFIG_DIR -u CLAUDE_CODE_SESSION_NAME HOME="$H" CTX_PRESSURE_STATE_DIR="$S" "$HOOKS/handoff-load.sh" > "$E/out$k" 2>/dev/null ) &
done
wait
t_eq "two parallel loaders: one injection" "$(cat "$E/out1" "$E/out2" | grep -c 'BEGIN HANDOFF')" "1"
t_eq "two parallel loaders: nothing left in ended" "$(ls "$S/ended" 2>/dev/null | wc -l | tr -d ' ')" "0"

new_env; mk_handoff "$ID_A" 30 >/dev/null; mk_ended "$ID_A" 20; mkdir "$S/ended/$PH.lock"
ld_run startup
t_no "busy lock: no injection" "$OUT" "BEGIN HANDOFF"
t_true "busy lock: record kept for a later start" test -f "$S/ended/$PH"
t_has "busy lock: logged" "$(cat "$LOGF")" "ended record busy"
rmdir "$S/ended/$PH.lock"

new_env; mk_handoff "$ID_A" 30 >/dev/null; mk_ended "$ID_A" 20
printf 'x\n' > "$S/ended/$PH.taken.12345"; set_mtime "$S/ended/$PH.taken.12345" $(( $(now) - 1200 ))
ld_run startup
t_false "old taken file swept" test -e "$S/ended/$PH.taken.12345"

new_env; mk_handoff "$ID_A" 30 >/dev/null; mk_marker "$ID_A" 120; mk_ended "$ID_A" 601 other
ld_run startup
t_no "601 s old record: no injection" "$OUT" "BEGIN HANDOFF"
t_has "601 s old record: lists" "$(ctx_of)" "$P/.claude/${PNAME}-handoff-${ID_A}.md"
t_has "601 s old record: forced=no logged" "$(cat "$LOGF")" "candidates=1 forced=no"

new_env; mk_handoff "$ID_A" 30 >/dev/null; mk_handoff "$ID_B" 30 >/dev/null; mk_ended "$ID_A" 20; mk_ended "$ID_B" 20
ld_run startup
t_no "two sessions ended: no injection" "$OUT" "BEGIN HANDOFF"
t_has "two sessions ended: ambiguous logged" "$(cat "$LOGF")" "2 sessions ended within 600s, ambiguous"
t_false "two sessions ended: ended record consumed" test -e "$S/ended/$PH"

new_env; mk_handoff "$ID_A" 30 >/dev/null; mk_ended "$ID_A" 40 clear; mk_ended "$ID_A" 30 other
ld_run clear
t_has "same id twice counts as one and loads" "$(ctx_of)" "body of $ID_A"
t_has "source clear loads too" "$(cat "$LOGF")" "source=clear forced=$ID_A"

new_env; mk_handoff "$NEWID" 30 >/dev/null; mk_ended "$NEWID" 20
ld_run startup
t_no "own id never matches" "$OUT" "BEGIN HANDOFF"

new_env; mk_ended "$ID_A" 20
ld_run startup
t_no "no handoff: no injection" "$OUT" "BEGIN HANDOFF"
t_has "no handoff: logged" "$(cat "$LOGF")" "ended session $ID_A has no usable handoff"

new_env; mk_handoff "$ID_A" 30 >/dev/null; mk_ended "$ID_A" 20; mk_marker "$ID_B" 100; mk_handoff "$ID_B" 10 >/dev/null
ld_run startup
t_no "exact beats list: only the matched one is injected" "$(ctx_of)" "body of $ID_B"
t_has "exact beats list: matched is injected" "$(ctx_of)" "body of $ID_A"

new_env; HF="$P/.claude/${PNAME}-handoff-${ID_A}.md"
awk 'BEGIN { printf "# Handoff big\n"; for (i = 0; i < 17000; i++) printf "\342\202\254" }' > "$HF"
mk_ended "$ID_A" 20
ld_run startup
C=$(ctx_of)
t_eq "3-byte chars: valid JSON" "$(printf '%s' "$OUT" | jq -e . >/dev/null 2>&1; echo $?)" "0"
t_true "3-byte chars: under 10000 characters" test "${#C}" -lt 10000
t_true "3-byte chars: not tiny" test "${#C}" -gt 2000
t_eq "3-byte chars: valid UTF-8" "$(printf '%s' "$C" | iconv -f UTF-8 -t UTF-8 >/dev/null 2>&1; echo $?)" "0"
t_eq "3-byte chars: no replacement character" "$(printf '%s' "$C" | grep -c $'\xef\xbf\xbd')" "0"
t_has "3-byte chars: truncation noted in context" "$C" "the tail was cut"
t_has "3-byte chars: truncation noted in systemMessage" "$(sys_of)" "ilk 8000 bayt"

new_env; HF="$P/.claude/${PNAME}-handoff-${ID_A}.md"
awk 'BEGIN { printf "# Handoff ascii\n"; for (i = 0; i < 3000; i++) print "line of plain text number " i }' > "$HF"
mk_ended "$ID_A" 20; ld_run startup
C=$(ctx_of)
t_true "ascii: under 10000 characters" test "${#C}" -lt 10000
t_eq "ascii: valid JSON" "$(printf '%s' "$OUT" | jq -e . >/dev/null 2>&1; echo $?)" "0"

new_env; mk_handoff "$ID_A" 30 "# legacy" "" >/dev/null
t_true "legacy file created" test -f "$P/.claude/handoff-$ID_A.md"
mk_ended "$ID_A" 20; ld_run startup
t_has "legacy name still loads" "$(ctx_of)" "body of $ID_A"
t_has "legacy name in systemMessage" "$(sys_of)" "Handoff yüklendi: handoff-${ID_A}.md"

new_env; mk_handoff "$ID_A" 30 "# new name" >/dev/null; mk_handoff "$ID_A" 30 "# legacy name" "" >/dev/null
M=$(( $(now) - 30 )); set_mtime "$P/.claude/${PNAME}-handoff-$ID_A.md" "$M"; set_mtime "$P/.claude/handoff-$ID_A.md" "$M"
mk_ended "$ID_A" 20; ld_run startup
t_has "new name wins over legacy" "$(ctx_of)" "# new name"

new_env; P="$E/my proj.v2"; mkdir -p "$P/.claude"; PNAME="my_proj_v2"; PH=$(sha1_16 "$P")
mk_handoff "$ID_A" 30 >/dev/null; mk_ended "$ID_A" 20; ld_run startup
t_has "project name sanitized in file name" "$(sys_of)" "Handoff yüklendi: my_proj_v2-handoff-${ID_A}.md"

new_env; mk_handoff "$ID_A" 30 >/dev/null; mk_ended "$ID_A" 20
echo '{}' > "$E/tr/$ID_A.jsonl"
ld_run startup "$NEWID" "$E/tr/$NEWID.jsonl"
t_has "old transcript path given" "$(ctx_of)" "$E/tr/$ID_A.jsonl"
new_env; mk_handoff "$ID_A" 30 >/dev/null; mk_ended "$ID_A" 20
ld_run startup
t_no "no transcript path when absent" "$(ctx_of)" ".jsonl"

new_env; mk_handoff "$ID_A" 300 >/dev/null; mk_ended "$ID_A" 20; ld_run startup
t_has "age in minutes" "$(sys_of)" "(5 dk önce yazılmış)"
new_env; mk_handoff "$ID_A" 10800 >/dev/null; mk_ended "$ID_A" 20; ld_run startup
t_has "age in hours" "$(sys_of)" "(3 sa önce yazılmış)"

new_env; mk_handoff "$ID_A" 300 >/dev/null; mk_ended "$ID_A" 20; ld_run startup "" "" HANDOFF_PENDING_TTL_MIN=1
t_no "TTL env: too old handoff is not injected" "$OUT" "BEGIN HANDOFF"
t_has "TTL env: logged" "$(cat "$LOGF")" "has no usable handoff"
new_env; mk_handoff "$ID_A" 30 >/dev/null; mk_ended "$ID_A" 30; ld_run startup "" "" HANDOFF_ENDED_MAX_AGE_S=20
t_no "ENDED_MAX_AGE env: 30 s record outside a 20 s window" "$OUT" "BEGIN HANDOFF"
new_env; mk_handoff "$ID_A" 30 >/dev/null; mk_ended "$ID_A" 30; ld_run startup "" "" HANDOFF_ENDED_MAX_AGE_S=100
t_has "ENDED_MAX_AGE env: 30 s record inside a 100 s window" "$(ctx_of)" "BEGIN HANDOFF"
new_env; mk_handoff "$ID_A" 30 >/dev/null; mk_ended "$ID_A" 30; ld_run startup "" "" HANDOFF_ENDED_MAX_AGE_S=abc HANDOFF_PENDING_TTL_MIN=xyz
t_has "bad env values fall back to defaults" "$(ctx_of)" "BEGIN HANDOFF"
new_env; mk_handoff "$ID_A" 540 >/dev/null; mk_ended "$ID_A" 20; ld_run startup "" "" HANDOFF_PENDING_TTL_MIN=010
t_has "TTL with a leading zero read as decimal (010 = 10 min)" "$(ctx_of)" "BEGIN HANDOFF"

# The file is found by session id, whatever its name part (2026-11-06).
new_env; mk_handoff "$ID_A" 30 "# MyProject — devir" "MyProject-" >/dev/null; mk_ended "$ID_A" 30; ld_run startup
t_has "session name: file found by id" "$(sys_of)" "Handoff yüklendi: MyProject-handoff-${ID_A}.md"
t_has "session name: body injected" "$(ctx_of)" "# MyProject — devir"
new_env; mk_handoff "$ID_A" 300 "# older" >/dev/null; mk_handoff "$ID_A" 30 "# newer" "MyProject-" >/dev/null
mk_ended "$ID_A" 30; ld_run startup
t_has "session name: newest file of the session wins" "$(ctx_of)" "# newer"
t_no "session name: older file not injected" "$(ctx_of)" "# older"
new_env; HF=$(mk_handoff "$ID_A" 30 "# Helper first line" "Helper-"); mk_marker "$ID_A" 120; ld_run startup
t_has "session name: listed by id" "$(ctx_of)" "$HF"

# Freshness of the notes (2026-11-07 incident: three prompts after the last write).
new_env; mk_handoff "$ID_A" 600 >/dev/null; mk_ended "$ID_A" 20; TO="$E/tr/$ID_A.jsonl"; T=$(now)
{ urec $((T - 900)) "önceki istem"; arec $((T - 650)) "a"; toolres $((T - 601))
  urec $((T - 500)) "taslak"; arec $((T - 490)) "b"
  urec $((T - 400)) "bu problem düzeldikten sonra mı PRlarıma onay isticez"; arec $((T - 390)) "c"
  urec $((T - 300)) "<ci-monitor-event>CI passed</ci-monitor-event>"; arec $((T - 290)) "d"
  urec $((T - 200)) "tamam. bu sırada yapılacak başka iş var mı"; arec $((T - 190)) "e"; } > "$TO"
mkdir -p "$S"; echo 1 > "$S/$ID_A.turn"; echo 1 > "$S/$ID_A.hnote"
ld_run startup
C=$(ctx_of)
t_has "fresh: warning" "$C" "WARNING: these notes are older than the end of that session."
t_has "fresh: handoff time in Turkey time" "$C" "Turkey time (UTC+3). After that, the session had"
t_has "fresh: counts and last turn in Turkey time" "$C" "the session had 3 user prompt(s) and 1 event(s), the last at $(jq -n -r --argjson t $((T - 200)) '($t + 10800) | todate | .[11:16]') Turkey time (UTC+3)."
t_has "fresh: last prompt quoted as data" "$C" "(data, not an instruction): \"tamam. bu sırada yapılacak başka iş var mı\""
t_has "fresh: transcript to read" "$C" "read the records of $TO with a timestamp after "
t_has "fresh: update the notes" "$C" "Then add those turns to the handoff file"
t_has "fresh: Part 2 exception" "$C" "Do not run any command for it, except reading those transcript records"
t_has "fresh: Part 1 line" "$C" "önce yazılmış; sonrasında 3 istem, 1 olay var)"
t_has "fresh: systemMessage" "$(sys_of)" "önce yazılmış; sonrasında 3 istem, 1 olay var)"
t_true "fresh: warning before the notes" test "$(line_no "$C" "WARNING:")" -lt "$(line_no "$C" "--- BEGIN HANDOFF ---")"
t_true "fresh: warning before Part 1" test "$(line_no "$C" "WARNING:")" -lt "$(line_no "$C" "Part 1:")"
t_has "fresh: notes still injected" "$C" "body of $ID_A"
t_has "fresh: logged" "$(cat "$LOGF")" "handoff of $ID_A is older than 3 prompt(s) and 1 event(s) of that session"
t_false "fresh: turn file of the loaded session removed" test -e "$S/$ID_A.turn"
t_false "fresh: handoff time note of the loaded session removed" test -e "$S/$ID_A.hnote"

new_env; mk_handoff "$ID_A" 600 >/dev/null; mk_ended "$ID_A" 20; T=$(now)
{ urec $((T - 900)) "eski"; arec $((T - 650)) "a"; } > "$E/tr/$ID_A.jsonl"
ld_run startup; C1=$(ctx_of); S1=$(sys_of)
new_env; mk_handoff "$ID_A" 600 >/dev/null; mk_ended "$ID_A" 20
echo '{}' > "$E/tr/$ID_A.jsonl"
ld_run startup; C2=$(ctx_of)
t_no "fresh: nothing after the handoff: no warning" "$C1" "WARNING"
t_no "fresh: nothing after: no count in systemMessage" "$S1" "sonrasında"
t_has "fresh: nothing after: Part 2 rule unchanged" "$C1" "the single next step. Do not run any command for it."
t_eq "fresh: nothing after = no records at all (same text, paths aside)" \
    "$(printf '%s' "$C1" | sed -e "s#$ROOT/e[0-9]*##g")" "$(printf '%s' "$C2" | sed -e "s#$ROOT/e[0-9]*##g")"

new_env; mk_handoff "$ID_A" 600 >/dev/null; mk_ended "$ID_A" 20; T=$(now)
{ urec $((T - 900)) "eski"; toolres $((T - 100)); toolres $((T - 50)); } > "$E/tr/$ID_A.jsonl"
ld_run startup
t_no "fresh: tool results only: no warning" "$(ctx_of)" "WARNING"

new_env; mk_handoff "$ID_A" 600 >/dev/null; mk_ended "$ID_A" 20; T=$(now)
{ urec $((T - 100)) "[Request interrupted by user]"; urec $((T - 95)) "<local-command-stdout>ok</local-command-stdout>"
  urec $((T - 90)) "<bash-stdout>ok</bash-stdout>"; urec $((T - 85)) "meta" '{"isMeta":true}'
  urec $((T - 80)) "summary" '{"isCompactSummary":true}'; urec $((T - 75)) "side" '{"isSidechain":true}'
  urec $((T - 70)) "[Image: source: /tmp/a.png]"
  urec $((T - 65)) "<task-notification>done</task-notification>"
  urec $((T - 60)) "<system-reminder>The session X you started ended.</system-reminder>"
  urec $((T - 55)) "[AUTOMATIC CHECK — not a person.] style check"
  urec $((T - 50)) "[OTOMATİK KONTROL — kimse bir şey söylemedi.] kontrol"
  urec $((T - 45)) "<cross-session-message from=\"a\">hi</cross-session-message>"
  urec $((T - 40)) "<side-sessions-event>x</side-sessions-event>"; } > "$E/tr/$ID_A.jsonl"
ld_run startup
t_no "fresh: skipped records and events only: no warning" "$(ctx_of)" "WARNING"
t_no "fresh: events only: no count in systemMessage" "$(sys_of)" "sonrasında"

new_env; mk_handoff "$ID_A" 600 >/dev/null; mk_ended "$ID_A" 20; T=$(now)
{ urec $((T - 100)) "<system-reminder>worktree note</system-reminder>
asıl soru"
  urec $((T - 90)) "<ci-monitor-event>a</ci-monitor-event>"; urec $((T - 80)) "<ci-monitor-event>b</ci-monitor-event>"; } > "$E/tr/$ID_A.jsonl"
ld_run startup
t_has "fresh: 1 prompt and 2 events" "$(ctx_of)" "1 user prompt(s) and 2 event(s)"
t_eq "fresh: system reminder stripped from the prompt" "$(last_prompt_of)" "asıl soru"
t_has "fresh: 1 prompt and 2 events in systemMessage" "$(sys_of)" "sonrasında 1 istem, 2 olay var"

new_env; mk_handoff "$ID_A" 600 >/dev/null; mk_ended "$ID_A" 20; T=$(now)
{ urec $((T - 100)) "<!-- attach: Terminal | tab:0 --> > ls çıktısına bak"
  urec $((T - 90)) "<@U0BNNF8B2J2> kaç veritabanı var?"
  urec $((T - 85)) "<command-name>/code-review</command-name>"
  jq -n -c --arg ts "$(iso_ms $((T - 80)))" '{type:"user", timestamp:$ts, message:{role:"user", content:[{type:"text", text:"resme bak"}, {type:"image", source:{}}]}}'
  urec $((T - 70)) "$(printf 'satır1\nsatır2\tsekme')"; } > "$E/tr/$ID_A.jsonl"
ld_run startup
t_has "fresh: attach, mention, slash command and array text are prompts" "$(ctx_of)" "5 user prompt(s) and 0 event(s)"
t_eq "fresh: newline and tab of the last prompt become spaces" "$(last_prompt_of)" "satır1 satır2 sekme"

new_env; mk_handoff "$ID_A" 600 >/dev/null; mk_ended "$ID_A" 20; T=$(now)
LONG="a$(awk 'BEGIN { for (i = 0; i < 400; i++) printf "ğüşöç" }')"
urec $((T - 100)) "$LONG" > "$E/tr/$ID_A.jsonl"
ld_run startup; L=$(last_prompt_of)
t_true "fresh: long prompt cut to at most 300 bytes" test "$(printf '%s' "$L" | LC_ALL=C wc -c | tr -d ' ')" -le 300
t_true "fresh: long prompt cut near 300 bytes" test "$(printf '%s' "$L" | LC_ALL=C wc -c | tr -d ' ')" -ge 298
t_true "fresh: cut prompt is valid UTF-8" utf8_ok "$L"

new_env; P="$E/$(awk 'BEGIN { for (i = 0; i < 120; i++) printf "p" }')"; mkdir -p "$P/.claude"; PH=$(sha1_16 "$P")
HF=$(mk_handoff "$ID_A" 600 "# long" ""); awk 'BEGIN { for (i = 0; i < 20000; i++) printf "a" }' >> "$HF"
set_mtime "$HF" $(( $(now) - 600 )); mk_ended "$ID_A" 20; T=$(now)
urec $((T - 100)) "$(awk 'BEGIN { for (i = 0; i < 2000; i++) printf "q" }')" > "$E/tr/$ID_A.jsonl"
ld_run startup
t_has "fresh: body cut at 7000 bytes with the warning" "$(sys_of)" "ilk 7000 bayt"
t_has "fresh: long file note" "$(ctx_of)" "the tail was cut"
t_true "fresh: whole context at most 10000 bytes" test "$(printf '%s' "$(ctx_of)" | LC_ALL=C wc -c | tr -d ' ')" -le 10000
new_env; HF=$(mk_handoff "$ID_A" 600); awk 'BEGIN { for (i = 0; i < 20000; i++) printf "a" }' >> "$HF"
set_mtime "$HF" $(( $(now) - 600 )); mk_ended "$ID_A" 20
ld_run startup
t_has "no warning: body cut at 8000 bytes as before" "$(sys_of)" "ilk 8000 bayt"

new_env; mk_handoff "$ID_A" 600 >/dev/null; mk_ended "$ID_A" 20; T=$(now)
OLDLINE=$(toolres $((T - 500)))
{ urec $((T - 900)) "eski"; awk -v l="$OLDLINE" 'BEGIN { for (i = 0; i < 2100; i++) print l }'; urec $((T - 100)) "son istem"; } > "$E/tr/$ID_A.jsonl"
ld_run startup
t_has "fresh: tail shorter than the gap: lower bound" "$(ctx_of)" "at least 1 user prompt(s) and at least 0 event(s)"
t_has "fresh: lower bound in systemMessage" "$(sys_of)" "sonrasında en az 1 istem"

new_env; mk_handoff "$ID_A" 600 >/dev/null; mk_ended "$ID_A" 20
ld_run startup
t_has "fresh: no transcript: notes still injected" "$(ctx_of)" "BEGIN HANDOFF"
t_no "fresh: no transcript: no warning" "$(ctx_of)" "WARNING"
t_has "fresh: no transcript: logged" "$(cat "$LOGF")" "transcript of $ID_A not readable, no freshness check"
new_env; mk_handoff "$ID_A" 600 >/dev/null; mk_ended "$ID_A" 20
printf 'not json\n{"type":"user","timestamp":5}\n' > "$E/tr/$ID_A.jsonl"
ld_run startup
t_has "fresh: broken transcript: notes still injected" "$(ctx_of)" "BEGIN HANDOFF"
t_no "fresh: broken transcript: no warning" "$(ctx_of)" "WARNING"

new_env; mkdir -p "$S"; echo 1 > "$S/old.turn"; set_mtime "$S/old.turn" $(( $(now) - 700000 )); echo 1 > "$S/new.turn"
echo 1 > "$S/old.hnote"; set_mtime "$S/old.hnote" $(( $(now) - 700000 )); echo 1 > "$S/new.hnote"
ld_run startup
t_false "old turn files swept" test -e "$S/old.turn"
t_true "recent turn files kept" test -e "$S/new.turn"
t_false "old handoff time notes swept" test -e "$S/old.hnote"
t_true "recent handoff time notes kept" test -e "$S/new.hnote"

# =====================================================================
CUR="loader-list"

new_env; HF=$(mk_handoff "$ID_A" 30 "# Handoff first line A"); mk_marker "$ID_A" 120
ld_run startup
t_has "single candidate: lists path" "$(ctx_of)" "$HF"
t_has "single candidate: first line" "$(ctx_of)" "# Handoff first line A"
t_has "single candidate: age" "$(ctx_of)" "written 0 min ago"
t_has "single candidate: startup wording" "$(ctx_of)" "may or may not continue one of them"
t_no "single candidate: no body" "$OUT" "BEGIN HANDOFF"
t_has "single candidate: Turkish systemMessage" "$(sys_of)" "1 bekleyen handoff var"
t_true "single candidate: marker kept" test -f "$S/pending.d/$PH/$ID_A"
ld_run startup
t_has "single candidate: second startup lists again" "$(ctx_of)" "$HF"

new_env; mk_handoff "$ID_A" 30 >/dev/null; mk_marker "$ID_A" 120; ld_run clear
t_has "clear list: do not guess" "$(ctx_of)" "Do not guess"
t_has "clear list: ask the user" "$(ctx_of)" "Ask the user which one"
t_has "clear list: Turkish systemMessage" "$(sys_of)" "hangisinden devam edileceği sorulacak"

new_env
mk_handoff "$ID_A" 3000 >/dev/null; mk_marker "$ID_A" 4000
mk_handoff "$ID_B" 2000 >/dev/null; mk_marker "$ID_B" 3000
mk_handoff "$ID_C" 1000 >/dev/null; mk_marker "$ID_C" 2000
ld_run startup
L=$(ctx_of)
t_has "three candidates: A listed" "$L" "$ID_A"
t_has "three candidates: B listed" "$L" "$ID_B"
t_has "three candidates: C listed" "$L" "$ID_C"
t_no "three candidates: no total line" "$L" "in total"
ia=${L%%$ID_A*}; ib=${L%%$ID_B*}; ic=${L%%$ID_C*}
t_true "three candidates: newest first (C before B)" test "${#ic}" -lt "${#ib}"
t_true "three candidates: newest first (B before A)" test "${#ib}" -lt "${#ia}"

new_env
mk_handoff "$ID_A" 5000 >/dev/null; mk_marker "$ID_A" 6000
mk_handoff "$ID_B" 4000 >/dev/null; mk_marker "$ID_B" 5000
mk_handoff "$ID_C" 3000 >/dev/null; mk_marker "$ID_C" 4000
mk_handoff "$ID_D" 2000 >/dev/null; mk_marker "$ID_D" 3000
mk_handoff "$ID_E" 1000 >/dev/null; mk_marker "$ID_E" 2000
ld_run startup
L=$(ctx_of)
t_has "five candidates: 5 in total" "$L" "5 in total"
t_no "five candidates: oldest not shown (A)" "$L" "$ID_A"
t_no "five candidates: second oldest not shown (B)" "$L" "$ID_B"
t_has "five candidates: newest shown (E)" "$L" "$ID_E"
t_has "five candidates: log count" "$(cat "$LOGF")" "candidates=5 forced=no"

new_env; mk_handoff "$ID_A" 300000 >/dev/null; mk_marker "$ID_A" 301000
ld_run startup
t_eq "handoff older than 72 h: silent" "$OUT" ""
t_false "handoff older than 72 h: marker removed" test -e "$S/pending.d/$PH/$ID_A"

new_env; mk_handoff "$ID_A" 3000 >/dev/null; mk_marker "$ID_A" 100
ld_run startup
t_eq "handoff older than its marker: ignored" "$OUT" ""
t_true "handoff older than its marker: marker kept" test -f "$S/pending.d/$PH/$ID_A"

new_env; OTHERH=$(sha1_16 "$E/another-project"); mk_marker "$ID_A" 100 "$OTHERH"; mk_handoff "$ID_B" 30 >/dev/null; mk_marker "$ID_B" 100
ld_run startup
t_true "another project untouched" test -f "$S/pending.d/$OTHERH/$ID_A"
t_no "another project not listed" "$(ctx_of)" "$ID_A"

new_env; OTHERH=$(sha1_16 "$E/another-project"); mk_marker "$ID_A" 100 "$OTHERH"
set_mtime "$S/pending.d/$OTHERH/$ID_A" $(( $(now) - 700000 ))
ld_run startup
t_false "stale orphan swept" test -e "$S/pending.d/$OTHERH/$ID_A"
t_false "empty dir of the orphan removed" test -d "$S/pending.d/$OTHERH"

new_env; mk_marker "$ID_A" 100; echo garbage > "$S/pending.d/$PH/$ID_A"
ld_run startup
t_false "marker with garbage content removed" test -e "$S/pending.d/$PH/$ID_A"

new_env; ld_run startup
t_eq "no markers: silent" "$OUT" ""
t_has "no markers: candidates=0 logged" "$(cat "$LOGF")" "candidates=0 forced=no"

new_env; mk_handoff "$ID_A" 30 >/dev/null; mk_marker "$ID_A" 100; cp "$S/pending.d/$PH/$ID_A" "$S/pending.d/$PH/$ID_A.offered"
ld_run startup
t_eq "id and legacy .offered count once" "$(printf '%s' "$(ctx_of)" | grep -c "handoff-$ID_A.md")" "1"

new_env; mk_handoff "$ID_A" 30 "# legacy one" "" >/dev/null; mk_marker "$ID_A" 100
ld_run startup
t_has "legacy file name is listed" "$(ctx_of)" "$P/.claude/handoff-$ID_A.md"

new_env; mk_handoff "$ID_A" 30 >/dev/null; mk_marker "$ID_A" 100
ld_run resume
t_eq "resume: silent" "$OUT" ""
t_has "resume: logged" "$(cat "$LOGF")" "handoff-load: source=resume session=$NEWID project=$P"
ld_run compact
t_eq "compact: silent" "$OUT" ""
t_has "compact: logged" "$(cat "$LOGF")" "handoff-load: source=compact session=$NEWID"
t_true "resume and compact: marker untouched" test -f "$S/pending.d/$PH/$ID_A"

new_env; run handoff-load.sh 'nope'
t_eq "invalid JSON: exit 0" "$RC" "0"
t_has "invalid JSON: logged" "$(cat "$LOGF")" "stdin is not valid JSON"
new_env; ld_run startup "../x"
t_eq "bad session id: exit 0" "$RC" "0"
t_has "bad session id: logged" "$(cat "$LOGF")" "invalid session_id"
new_env; run handoff-load.sh "$(jq -n -c --arg s "$NEWID" '{source:"startup", session_id:$s}')"
t_eq "empty project: exit 0" "$RC" "0"
t_has "empty project: logged" "$(cat "$LOGF")" "no project dir"
new_env; run handoff-load.sh '5'
t_eq "JSON number: exit 0" "$RC" "0"

new_env; mk_marker "$ID_A" 100; mk_handoff "$ID_A" 30 >/dev/null
awk 'BEGIN { for (i = 0; i < 14000; i++) print "2026-01-01T00:00:00Z filler line " i " xxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxx" }' > "$LOGF"
ld_run resume
t_true "loader trims the log" test "$(wc -c < "$LOGF" | tr -d ' ')" -lt 1048576

new_env; mk_handoff "$ID_A" 30 "$(printf '# title\twith\ttabs and ctrl \001 char')" >/dev/null; mk_marker "$ID_A" 100
ld_run startup
t_eq "control chars in first line stripped" "$(ctx_of | LC_ALL=C grep -c "$(printf '\001')")" "0"

# =====================================================================
CUR="detail-note"
# Three files per handoff (2026-11-23): handoff, detail note, transcript dump.
ALL8="## Decisions and reasons, ## User requests in their words, ## Open tasks, ## Background jobs, ## Ruled out and why, ## Lessons learned, ## Memory changes, ## Environment"
hook_fn() { # script, function name: the headings variable and the function text
    awk '/^DETAIL_HEADINGS=/ { f = 1 } f { print } f && /Environment.$/ { exit }' "$HOOKS/$1"
    awk -v n="$2" '$0 ~ ("^" n "[(][)] [{]") { f = 1 } f { print } f && /^}/ { exit }' "$HOOKS/$1"
}
dm() { bash -c "$(hook_fn "$1" detail_missing)
detail_missing \"\$1\"" _ "$2"; }
dump_file() { printf '%s' "$H/.claude/handoff-dumps/$(basename "${1%.md}").transcript.md"; }

new_env; DN="$E/d.md"
for s in context-pressure.sh; do
    t_eq "detail_missing: no file lists all eight" "$(dm "$s" "$E/none.md")" "$ALL8"
done
mk_detail "$E/x.md" >/dev/null
t_eq "detail_missing: complete note" "$(dm context-pressure.sh "$E/x.detay.md")" ""
mk_detail "$E/x.md" 3 >/dev/null
t_eq "detail_missing: one heading left out" "$(dm context-pressure.sh "$E/x.detay.md")" "## Open tasks"
printf '## Decisions and reasons later\n## Environment\n' > "$E/y.detay.md"
t_has "detail_missing: a heading with extra text does not count" "$(dm context-pressure.sh "$E/y.detay.md")" "## Decisions and reasons, ## User requests"
t_no "detail_missing: the exact heading counts" "$(dm context-pressure.sh "$E/y.detay.md")" "## Environment"
t_eq "detail_missing: same in both hooks" "$(dm usage-limit.sh "$E/none.md")" "$ALL8"

# The request names the detail note and its rules.
new_env; mk_tr 350000; cp_run
M=$(msg_of); DT="$P/.claude/${PNAME}-handoff-${SID}.detay.md"
t_has "request: detail note path" "$M" "Detail note: write ${DT} before the handoff"
t_has "request: first line of the note" "$M" "'# ${PNAME} — detay notu'"
t_has "request: required headings" "$M" "$ALL8"
t_has "request: Yok." "$M" "Write 'Yok.' under a section with nothing to report"
t_has "request: no size limit" "$M" "no size limit"
t_has "request: memory files in full" "$M" "the full text of every memory file this session wrote or changed"
t_has "request: the dump is a hook's job" "$M" "is written by a hook: do not write it yourself"
t_has "request: handoff points at the note" "$M" "tells the next session to read the detail note ${DT} in full"
pd=${M%%Detail note: write*}; ph=${M%%Second, write the handoff*}
t_true "request: detail note comes before the handoff" test "${#pd}" -lt "${#ph}"

# The batch after a write of the handoff: note about D, extras line.
new_env; mk_tr 350000; cp_run; HF=$(mk_handoff "$SID"); DT="${HF%.md}.detay.md"
run context-pressure.sh "$(cp_batch_json)"
M=$(msg_of)
t_has "batch: missing detail note named" "$M" "Detail note ${DT}: missing sections: ${ALL8}. Write it before the CLEAR or COMPACT line."
t_eq "batch: extras line right after the title" "$(sed -n 2p "$HF")" "Ek dosyalar: detay notu ${DT} · tam döküm $(dump_file "$HF")"
t_eq "batch: the file keeps its other lines" "$(sed -n 3p "$HF")" "body of $SID"
t_eq "batch: the note stores the new write time" "$(cat "$S/$SID.hnote")" "$(file_mt "$HF")"
run context-pressure.sh "$(cp_batch_json)"
t_eq "batch: no second note for the same write" "$OUT" ""
t_eq "batch: one extras line" "$(grep -c '^Ek dosyalar:' "$HF")" "1"
printf '# t\nSon güncelleme: 2026-01-01 10:00:00 TR\nEk dosyalar: eski\nbody\n' > "$HF"; set_mtime "$HF" $(( $(now) + 30 ))
run context-pressure.sh "$(cp_batch_json)"
t_eq "batch: after Son güncelleme" "$(sed -n 3p "$HF")" "Ek dosyalar: detay notu ${DT} · tam döküm $(dump_file "$HF")"
t_eq "batch: the older line is replaced" "$(grep -c '^Ek dosyalar:' "$HF")" "1"
t_eq "batch: body follows" "$(sed -n 4p "$HF")" "body"
mk_detail "$HF" >/dev/null; printf '# t\nbody\n' > "$HF"; set_mtime "$HF" $(( $(now) + 90 ))
run context-pressure.sh "$(cp_batch_json)"
t_no "batch: complete detail note: no missing-sections note" "$(msg_of)" "missing sections"
t_has "batch: complete detail note: time note still given" "$(msg_of)" "Handoff time:"

# Stop: D missing or incomplete.
new_env; mk_tr 350000; cp_run; HF=$(mk_handoff "$SID" 10); turn_at 60; HM=$(tr_hm "$(file_mt "$HF")")
stop_run "$(tline "$HF")"
t_eq "stop: detail note missing: block" "$(dec_of)" "block"
t_has "stop: names the detail note" "$(reason_of)" "the detail note ${HF%.md}.detay.md does not exist"
t_has "stop: lists the headings" "$(reason_of)" "$ALL8"
t_has "stop: keeps the handoff time" "$(reason_of)" "\"handoff ${HM}\""
t_has "stop: logged" "$(cat "$LOGF")" "stop: detail note does not exist in $SID"
stop_run "$(tline "$HF")" true
t_eq "stop: second pass (stop_hook_active) silent" "$OUT" ""
mk_detail "$HF" 5 >/dev/null
stop_run "$(tline "$HF")"
t_eq "stop: incomplete detail note: block" "$(dec_of)" "block"
t_has "stop: names the missing heading" "$(reason_of)" "misses sections: ## Ruled out and why"
mk_detail "$HF" >/dev/null
stop_run "$(tline "$HF")"
t_eq "stop: complete detail note: silent" "$OUT" ""
stop_run "$CLEARLINE
x"
t_eq "stop: a wrong time and a complete note: the time block only" "$(dec_of)" "block"
t_no "stop: ... without detail text" "$(reason_of)" "detail note"

new_env; mk_tr 350000; cp_run; HF=$(mk_handoff "$SID" 300); turn_at 60
stop_run "$CLEARLINE"
t_has "stop: stale handoff and no detail note: one reason holds both" "$(reason_of)" "also does not exist: write it too"
new_env; mk_tr 350000; cp_run; HF=$(mk_handoff "$SID" 10); turn_at 60
stop_run "$CLEARLINE"
t_has "stop: wrong time and no detail note: one reason holds both" "$(reason_of)" "also does not exist: write it too"

# find_handoff must not take D for a handoff (loader).
new_env; HF=$(mk_handoff "$ID_A" 600); DT=$(mk_detail "$HF"); mk_marker "$ID_A" 700; mk_ended "$ID_A" 30 other
ld_run startup
t_has "loader: the handoff, not the detail note, is injected" "$(ctx_of)" "(file: ${HF}, written"
t_has "loader: handoff body" "$(ctx_of)" "body of $ID_A"
t_has "loader: tells the new session to read the detail note" "$(ctx_of)" "A detail note belongs to these notes: ${DT}. Read it in full"
t_no "loader: no dump yet: no dump text" "$(ctx_of)" "transcript dump"
new_env; HF=$(mk_handoff "$ID_A" 600); mk_detail "$HF" >/dev/null; mk_marker "$ID_A" 700; mk_ended "$ID_A" 30 other
mkdir -p "$H/.claude/handoff-dumps"; printf 'dump\n' > "$(dump_file "$HF")"
ld_run startup
t_has "loader: the dump is named" "$(ctx_of)" "The full transcript dump of that session (written by a hook) is $(dump_file "$HF")"
new_env; HF=$(mk_handoff "$ID_A" 600); mk_marker "$ID_A" 700; mk_ended "$ID_A" 30 other
ld_run startup
t_no "loader: no detail note: no detail text" "$(ctx_of)" "detail note"
new_env; HF=$(mk_handoff "$ID_A" 30); DT=$(mk_detail "$HF"); set_mtime "$DT" $(( $(now) + 100 )); mk_marker "$ID_A" 120
ld_run startup
t_has "loader list: the handoff is listed" "$(ctx_of)" "- ${HF} (written"
t_has "loader list: the detail note is shown" "$(ctx_of)" "  detail note: ${DT}"
t_eq "loader list: the detail note is not a candidate" "$(printf '%s' "$(ctx_of)" | grep -c -- '^- ')" "1"
new_env; HF=$(mk_handoff "$ID_A" 30); mk_marker "$ID_A" 120
ld_run startup
t_no "loader list: no detail note: nothing shown" "$(ctx_of)" "detail note:"

# The lint of the dump script (it is not a hook, so the hook lint does not cover it).
CUR="dump-script"
DP="$HOOKS/handoff-dump.py"
t_true "dump script exists" test -f "$DP"
t_eq "dump script shebang" "$(head -n 1 "$DP")" '#!/usr/bin/env python3'
BADIMP=$(grep -E '^(import|from) ' "$DP" | grep -v -E '^(import|from) (argparse|calendar|datetime|json|os|re|subprocess|sys|time)( |$)')
t_eq "dump script imports the standard library only" "$BADIMP" ""
if [ "$HAVE_PY" = "1" ]; then
    t_true "dump script syntax" python3 -c 'import ast,sys; ast.parse(open(sys.argv[1], encoding="utf-8").read())' "$DP"

    # A synthetic transcript.
    new_env; T0=$(( $(now) - 4000 )); TRX="$E/syn.jsonl"; OUTD="$E/dumpout"
    {
        urec "$T0" 'İlk istem `kod` ve
```
çit
```
bitti'
        printf '%s\n' '{not json at all'
        arec $(( T0 + 10 )) "Asistan cevabı"
        jq -n -c --arg ts "$(iso_ms $(( T0 + 20 )))" '{type:"assistant", timestamp:$ts, isSidechain:false, message:{role:"assistant", content:[{type:"thinking", thinking:"düşünce metni"}, {type:"tool_use", id:"t1", name:"Bash", input:{command:"ls -la"}}]}}'
        jq -n -c --arg ts "$(iso_ms $(( T0 + 30 )))" '{type:"user", timestamp:$ts, message:{role:"user", content:[{type:"tool_result", tool_use_id:"t1", content:"boom", is_error:true}]}}'
        jq -n -c --arg ts "$(iso_ms $(( T0 + 35 )))" --arg x "$(printf 'y%.0s' $(seq 1 500))" '{type:"user", timestamp:$ts, message:{role:"user", content:[{type:"tool_result", tool_use_id:"t2", content:$x}]}}'
        urec $(( T0 + 40 )) "SIDECHAIN-SECRET" '{"isSidechain":true}'
        urec $(( T0 + 50 )) "<task-notification>bitti</task-notification>"
        jq -n -c --arg ts "$(iso_ms $(( T0 + 60 )))" '{type:"attachment", timestamp:$ts, attachment:{type:"queued_command", prompt:"kuyruk komutu"}}'
        jq -n -c --arg ts "$(iso_ms $(( T0 + 61 )))" '{type:"attachment", timestamp:$ts, attachment:{type:"edited_text_file", filename:"zz-atlanir"}}'
        urec $(( T0 + 70 )) "Compact özeti metni" '{"isCompactSummary":true}'
    } > "$TRX"
    SLUG=$(printf '%s' "$P" | sed 's/[^A-Za-z0-9]/-/g')
    MD="$E/cfg/projects/$SLUG/memory"; mkdir -p "$MD"
    printf '# Memory dizini\n- [a](a.md)\n' > "$MD/MEMORY.md"
    printf 'YENİ-MEMORY-METNİ\n' > "$MD/new.md"
    printf 'ESKİ-MEMORY-METNİ\n' > "$MD/old.md"
    set_mtime "$MD/old.md" $(( T0 - 5000 ))
    python3 "$DP" --transcript "$TRX" --out "$OUTD/x.md" --session "$SID" --project "$P" --title "Test Başlık" --config "$E/cfg" --max-field 100 2>"$E/dump.err"
    RC=$?
    DUMP=$(cat "$OUTD/x.md" 2>/dev/null)
    t_eq "dump: exit 0" "$RC" "0"
    t_has "dump: title" "$DUMP" "# Test Başlık — tam transcript dökümü"
    t_true "dump: generated time in TR" bash -c "grep -q -E '^- Üretim zamanı: [0-9]{4}-[0-9]{2}-[0-9]{2} [0-9]{2}:[0-9]{2} TR\$' '$OUTD/x.md'"
    t_has "dump: session id" "$DUMP" "- Oturum: $SID"
    t_has "dump: transcript path" "$DUMP" "- Transcript: $TRX"
    t_has "dump: project" "$DUMP" "- Proje: $P"
    t_has "dump: cut note in the header" "$DUMP" "100 karakterden uzunsa kesilir"
    t_true "dump: file mode 600" bash -c "ls -l '$OUTD/x.md' | cut -c1-10 | grep -q '^-rw-------\$'"
    t_true "dump: folder mode 700" bash -c "ls -ld '$OUTD' | cut -c1-10 | grep -q '^drwx------\$'"
    t_eq "dump: no temp file left" "$(ls "$OUTD" | wc -l | tr -d ' ')" "1"
    t_has "dump: user prompt with its time" "$DUMP" "### Kullanıcı · $(tr_hm "$T0") TR"
    t_has "dump: user prompt verbatim" "$DUMP" "İlk istem \`kod\` ve"
    t_has "dump: longer fence around a prompt that holds a fence" "$DUMP" '````'
    t_has "dump: assistant text" "$DUMP" "### Asistan · $(tr_hm $(( T0 + 10 ))) TR"
    t_has "dump: assistant text body" "$DUMP" "Asistan cevabı"
    t_has "dump: thinking" "$DUMP" "düşünce metni"
    t_has "dump: tool use" "$DUMP" "→ Araç: Bash"
    t_has "dump: tool input as JSON" "$DUMP" '"command": "ls -la"'
    t_has "dump: error result" "$DUMP" "← Sonuç (hata)"
    t_has "dump: error result text" "$DUMP" "boom"
    t_has "dump: plain result" "$DUMP" "← Sonuç"
    t_has "dump: long result is cut" "$DUMP" "400 karakter daha var, kesildi"
    t_no "dump: sidechain skipped" "$DUMP" "SIDECHAIN-SECRET"
    t_has "dump: task notification" "$DUMP" "### Sistem/agent bildirimi"
    t_has "dump: queued command" "$DUMP" "kuyruk komutu"
    t_no "dump: other attachment skipped" "$DUMP" "zz-atlanir"
    t_has "dump: compact summary kept" "$DUMP" "Compact özeti metni"
    t_has "dump: conversation heading" "$DUMP" "## Konuşma"
    t_no "dump: no git section outside a work tree" "$DUMP" "## Git durumu"
    t_has "dump: memory heading" "$DUMP" "## Memory"
    t_has "dump: MEMORY.md in full" "$DUMP" "# Memory dizini"
    t_has "dump: changed memory file in full" "$DUMP" "YENİ-MEMORY-METNİ"
    t_has "dump: changed memory section" "$DUMP" "### Bu oturumda değişen memory dosyaları"
    t_no "dump: old memory file not in full" "$DUMP" "ESKİ-MEMORY-METNİ"
    t_has "dump: old memory file by name" "$DUMP" "- old.md"
    mpos=${DUMP%%Diğer memory dosyaları*}; npos=${DUMP%%YENİ-MEMORY-METNİ*}
    t_true "dump: changed files come before the names" test "${#npos}" -lt "${#mpos}"

    python3 "$DP" --transcript "$E/missing.jsonl" --out "$OUTD/y.md" --session "$SID" 2>"$E/dump.err"
    t_eq "dump: missing transcript: exit 1" "$?" "1"
    t_has "dump: missing transcript: message" "$(cat "$E/dump.err")" "handoff-dump: transcript not found"
    t_false "dump: missing transcript: no output" test -e "$OUTD/y.md"
    python3 "$DP" --out "$OUTD/z.md" 2>/dev/null
    t_eq "dump: missing arguments: exit 1" "$?" "1"

    # The memory folder of another place: transcript folder, no project.
    new_env; TRX="$E/syn2.jsonl"; mkdir -p "$E/memory"; printf '# M2\n' > "$E/memory/MEMORY.md"
    urec "$(now)" "merhaba" > "$TRX"
    python3 "$DP" --transcript "$TRX" --out "$E/o/x.md" --session s --config "$E/cfg" 2>/dev/null
    t_has "dump: memory folder next to the transcript" "$(cat "$E/o/x.md")" "# M2"

    if [ "$HAVE_GIT" = "1" ]; then
        new_env; REPO="$E/repo"; mkdir -p "$REPO/sub"; TRX="$E/syn3.jsonl"
        git -C "$REPO" init -q 2>/dev/null
        printf 'a\n' > "$REPO/a.txt"; git -C "$REPO" add a.txt 2>/dev/null
        git -C "$REPO" -c user.name=t -c user.email=t@t -c commit.gpgsign=false commit -q -m "ilk commit" 2>/dev/null
        printf 'b\n' > "$REPO/untracked.txt"
        urec "$(( $(now) - 100 ))" "merhaba" > "$TRX"
        # git reports the physical path (on macOS /private/var/...), so the slug uses it.
        RP=$(cd "$REPO" && pwd -P)
        SLUGR=$(printf '%s' "$RP" | sed 's/[^A-Za-z0-9]/-/g')
        mkdir -p "$E/cfg/projects/$SLUGR/memory"; printf '# KOK-MEMORY\n' > "$E/cfg/projects/$SLUGR/memory/MEMORY.md"
        env HOME="$H" python3 "$DP" --transcript "$TRX" --out "$E/o/g.md" --session s --project "$REPO/sub" --config "$E/cfg" 2>"$E/dump.err"
        GRC=$?
        G=$(cat "$E/o/g.md" 2>/dev/null)
        t_eq "dump git: exit 0" "$GRC" "0"
        t_has "dump git: section" "$G" "## Git durumu"
        t_has "dump git: branch" "$G" "Dal: "
        t_has "dump git: status" "$G" "?? untracked.txt"
        t_has "dump git: log" "$G" "ilk commit"
        t_has "dump git: memory of the main repo root" "$G" "# KOK-MEMORY"
    fi
fi

# The hooks start the dump: after a write of the handoff, and on a passing Stop.
if [ "$HAVE_PY" = "1" ]; then
    new_env; mk_tr 350000; cp_run; HF=$(mk_handoff "$SID"); XF=$(dump_file "$HF")
    run context-pressure.sh "$(cp_batch_json)"
    t_true "hook dump: created after a write of the handoff" test -s "$XF"
    t_has "hook dump: has the sections" "$(cat "$XF" 2>/dev/null)" "## Konuşma"
    t_has "hook dump: session id" "$(cat "$XF" 2>/dev/null)" "- Oturum: $SID"

    new_env; mk_tr 350000; cp_run; HF=$(mk_handoff "$SID" 10); mk_detail "$HF" >/dev/null; turn_at 60; XF=$(dump_file "$HF")
    stop_run "$(tline "$HF")"
    t_eq "hook dump: passing Stop is silent" "$OUT" ""
    t_true "hook dump: passing Stop writes the dump" test -s "$XF"
    rm -f "$XF"
    stop_run "$CLEARLINE" true
    t_false "hook dump: no dump on a blocked or guarded Stop" test -e "$XF"

    new_env; mk_tr 350000; cp_run; HF=$(mk_handoff "$SID" 10); mk_detail "$HF" >/dev/null; turn_at 60; XF=$(dump_file "$HF")
    mkdir -p "$H/.claude"; printf 'x\n' > "$H/.claude/handoff-dumps"
    stop_run "$(tline "$HF")"
    t_eq "hook dump: a failing dump never blocks" "$OUT" ""
    t_eq "hook dump: a failing dump exits 0" "$RC" "0"
    t_has "hook dump: a failing dump is logged" "$(cat "$LOGF")" "handoff dump failed"

    new_env; mk_tr 350000; cp_run; HF=$(mk_handoff "$SID"); XF=$(dump_file "$HF")
    run context-pressure.sh "$(cp_batch_json)" HANDOFF_DUMP_SYNC=
    t_true "hook dump: background run finishes" wait_file "$XF"
fi

# No python3 or no script: logged once, nothing else changes.
new_env; mk_tr 350000; cp_run; HF=$(mk_handoff "$SID")
NOPY="$E/nopy"; mkdir -p "$NOPY"; cp "$HOOKS/context-pressure.sh" "$NOPY/context-pressure.sh"; chmod 755 "$NOPY/context-pressure.sh"
OUT=$(printf '%s' "$(cp_batch_json)" | env -u CLAUDE_PROJECT_DIR -u CLAUDE_CONFIG_DIR -u CLAUDE_CODE_SESSION_NAME HOME="$H" CTX_PRESSURE_STATE_DIR="$S" HANDOFF_DUMP_SYNC=1 "$NOPY/context-pressure.sh" 2>/dev/null); RC=$?
t_eq "no dump script: exit 0" "$RC" "0"
t_has "no dump script: the note still comes" "$(msg_of)" "Handoff time:"
t_has "no dump script: logged" "$(cat "$LOGF")" "handoff dump skipped for $SID"
t_false "no dump script: no dump" test -e "$(dump_file "$HF")"
set_mtime "$HF" $(( $(now) + 200 ))
OUT=$(printf '%s' "$(cp_batch_json)" | env -u CLAUDE_PROJECT_DIR -u CLAUDE_CONFIG_DIR -u CLAUDE_CODE_SESSION_NAME HOME="$H" CTX_PRESSURE_STATE_DIR="$S" HANDOFF_DUMP_SYNC=1 "$NOPY/context-pressure.sh" 2>/dev/null)
t_eq "no dump script: logged once per session" "$(grep -c 'handoff dump skipped' "$LOGF")" "1"

# The rename of a handoff takes its detail note along.
new_env; mk_tr 350000; HF=$(mk_handoff "$SID" 5 "# alt" "oldname-"); mk_detail "$HF" >/dev/null
printf '%s\n' "$(title_rec "Yeni Ad")" >> "$TR"
cp_run
t_true "rename: the detail note follows the handoff" test -f "$P/.claude/Yeni-Ad-handoff-${SID}.detay.md"
t_false "rename: the old detail note is gone" test -e "${HF%.md}.detay.md"

printf '%s: %s pass, %s fail\n' "$LABEL" "$PASS" "$FAIL"
if [ "$FAIL" -gt 0 ]; then printf '%s\n' "$FAILS" | head -n 60; exit 1; fi
exit 0
