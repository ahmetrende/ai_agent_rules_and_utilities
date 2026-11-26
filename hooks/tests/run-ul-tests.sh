#!/usr/bin/env bash
# Test suite for usage-limit.sh.
# usage: run-ul-tests.sh <hooks dir> [label]
# Every test uses its own HOME (for the log), state dir, index dir, conf path and
# project dir. CLAUDE_PROJECT_DIR is unset, so the cwd fallback is the path under test.

HOOKS="${1:?usage: run-ul-tests.sh <hooks dir> [label]}"
LABEL="${2:-run}"
PASS=0
FAIL=0
FAILS=""
ROOT=$(mktemp -d "${TMPDIR:-/tmp}/ultest.XXXXXX") || exit 2
trap 'rm -rf "$ROOT"' EXIT
N=0
SCRIPT="$HOOKS/usage-limit.sh"
ACCT_A=aaaaaaaa-1111-4111-8111-aaaaaaaaaaaa
ACCT_B=bbbbbbbb-2222-4222-8222-bbbbbbbbbbbb
ORG_A=cccccccc-3333-4333-8333-cccccccccccc
ORG_B=dddddddd-4444-4444-8444-dddddddddddd
SID2=22222222-0000-4000-8000-000000000002
TOOL_USAGE=mcp__ccd_session_mgmt__get_usage

ok()  { PASS=$((PASS + 1)); }
bad() { FAIL=$((FAIL + 1)); FAILS="$FAILS
  FAIL [$CUR] $1 :: $2"; }
t_eq()  { if [ "$2" = "$3" ]; then ok; else bad "$1" "got '$(printf '%s' "$2" | head -c 200)' want '$3'"; fi; }
t_has() { case "$2" in *"$3"*) ok ;; *) bad "$1" "missing '$3' in '$(printf '%s' "$2" | head -c 240)'" ;; esac; }
t_no()  { case "$2" in *"$3"*) bad "$1" "unexpected '$3'" ;; *) ok ;; esac; }
t_true() { local n="$1"; shift; if "$@"; then ok; else bad "$n" "failed: $*"; fi; }
t_false() { local n="$1"; shift; if "$@"; then bad "$n" "should fail: $*"; else ok; fi; }

now() { date +%s; }
iso() { date -u -d "@$1" +%Y-%m-%dT%H:%M:%S.123Z 2>/dev/null || date -u -r "$1" +%Y-%m-%dT%H:%M:%S.123Z; }

new_env() {
    N=$((N + 1))
    E="$ROOT/e$N"
    H="$E/home"
    P="$E/my-proj"
    ST="$E/state"
    IDX="$E/index"
    CONF="$E/usage-limit.conf"
    TRD="$E/projects/-my-proj"
    mkdir -p "$H/.claude/hooks" "$P/.claude" "$TRD"
    LOGF="$H/.claude/hooks/context-pressure.log"
    SID="11111111-0000-4000-8000-$(printf '%012d' "$N")"
    TR="$TRD/$SID.jsonl"
    printf '%s\n' '{"type":"user","message":{"role":"user","content":"hi"}}' \
        '{"type":"custom-title","customTitle":"Session handoff hooks kurulumu","sessionId":"x"}' \
        '{"type":"assistant","message":{"role":"assistant","content":"ok"}}' > "$TR"
    ACCT="$ACCT_A"
    ORG="$ORG_A"
    AD="$ST/${ORG}_${ACCT}"
}

# run <stdin json> [VAR=value ...] -> OUT RC
run() {
    local json="$1"
    shift
    OUT=$(printf '%s' "$json" | env -u CLAUDE_PROJECT_DIR -u CTX_PRESSURE_STATE_DIR -u CLAUDE_CONFIG_DIR -u USAGE_FEED_DIR -u CLAUDE_CODE_SESSION_NAME HOME="$H" USAGE_LIMIT_STATE_DIR="$ST" HANDOFF_DUMP_SYNC=1 \
        USAGE_LIMIT_INDEX_DIR="$IDX" USAGE_LIMIT_CONF="$CONF" CLAUDE_CODE_ACCOUNT_UUID="$ACCT" CLAUDE_CODE_ORGANIZATION_UUID="$ORG" \
        "$@" "$SCRIPT" 2>"$E/stderr")
    RC=$?
}

# run_noid <stdin json> [VAR=value ...]: like run, without workspace and account ids
run_noid() {
    local json="$1"
    shift
    OUT=$(printf '%s' "$json" | env -u CLAUDE_PROJECT_DIR -u CTX_PRESSURE_STATE_DIR -u CLAUDE_CONFIG_DIR -u USAGE_FEED_DIR -u CLAUDE_CODE_SESSION_NAME \
        -u CLAUDE_CODE_ACCOUNT_UUID -u CLAUDE_CODE_ORGANIZATION_UUID HOME="$H" USAGE_LIMIT_STATE_DIR="$ST" \
        USAGE_LIMIT_INDEX_DIR="$IDX" USAGE_LIMIT_CONF="$CONF" "$@" "$SCRIPT" 2>"$E/stderr")
    RC=$?
}

base() { # event [session id]; the cwd is $CWD when it is set, else $P
    jq -n -c --arg e "$1" --arg s "${2:-$SID}" --arg c "${CWD:-$P}" --arg t "$TR" \
        '{hook_event_name: $e, session_id: $s, cwd: $c, transcript_path: $t}'
}
pre() { # tool [file_path] [agent_id] [session id]
    base PreToolUse "${4:-}" | jq -c --arg t "$1" --arg f "${2:-}" --arg a "${3:-}" \
        '. + {tool_name: $t, tool_input: (if $f == "" then {command: "ls"} else {file_path: $f} end)}
         + (if $a == "" then {} else {agent_id: $a} end)'
}
post_write() { # file_path [tool]
    base PostToolUse | jq -c --arg f "$1" --arg t "${2:-Write}" '. + {tool_name: $t, tool_input: {file_path: $f}, tool_response: {}}'
}
batch() { # tool [file_path] [agent_id]
    base PostToolBatch | jq -c --arg t "${1:-Read}" --arg f "${2:-/x}" --arg a "${3:-}" \
        '. + {tool_calls: [{tool_name: $t, tool_input: {file_path: $f}, tool_use_id: "t1", tool_response: "ok"}]}
         + (if $a == "" then {} else {agent_id: $a} end)'
}
ups() { # prompt [session title]
    base UserPromptSubmit | jq -c --arg p "$1" --arg st "${2:-}" '. + {prompt: $p} + (if $st == "" then {} else {session_title: $st} end)'
}
usage_text() { # five pct, week pct, [status]
    local n r5 r7
    n=$(now); r5=$(iso $(( n + 7000 ))); r7=$(iso $(( n + 200000 )))
    jq -n -c --argjson f "$1" --argjson w "$2" --arg st "${3:-ok}" --arg r5 "$r5" --arg r7 "$r7" \
        '{plan: {status: $st, plan: "Team", windows: [
            {label: "5-hour limit", percentUsed: $f, resetsAt: $r5, resetsIn: "1h"},
            {label: "Weekly · all models", percentUsed: $w, resetsAt: $r7, resetsIn: "2d"},
            {label: "Weekly · Fable", percentUsed: 1, resetsAt: $r7, resetsIn: "2d"}]},
          context: {status: "ok"}}'
}
post_usage() { # five pct, week pct, [status], [shape: array|string]
    local txt
    txt=$(usage_text "$1" "$2" "${3:-ok}")
    if [ "${4:-array}" = "string" ]; then
        base PostToolUse | jq -c --arg t "$TOOL_USAGE" --arg x "$txt" '. + {tool_name: $t, tool_input: {}, tool_response: $x}'
    else
        base PostToolUse | jq -c --arg t "$TOOL_USAGE" --arg x "$txt" '. + {tool_name: $t, tool_input: {}, tool_response: [{type: "text", text: $x}]}'
    fi
}
mk_usage() { # five pct, five reset offset s, week pct, week reset offset s, age s
    local n
    n=$(now)
    mkdir -p "$AD"
    jq -n -c --argjson f "$1" --argjson fr $(( n + $2 )) --argjson w "$3" --argjson wr $(( n + $4 )) --argjson ts $(( n - $5 )) \
        '{five: {pct: $f, reset: $fr}, week: {pct: $w, reset: $wr}, ts: $ts, by: "test"}' > "$AD/usage.json"
}
ctx_of() { printf '%s' "$OUT" | jq -r '.hookSpecificOutput.additionalContext // empty' 2>/dev/null; }
sys_of() { printf '%s' "$OUT" | jq -r '.systemMessage // empty' 2>/dev/null; }
mk_usage_abs() { # five pct, five reset epoch, week pct, week reset epoch, age s
    mkdir -p "$AD"
    jq -n -c --argjson f "$1" --argjson fr "$2" --argjson w "$3" --argjson wr "$4" --argjson ts $(( $(now) - $5 )) \
        '{five: {pct: $f, reset: $fr}, week: {pct: $w, reset: $wr}, ts: $ts, by: "test"}' > "$AD/usage.json"
}
mk_feed() { # five pct, five reset offset s, week pct, week reset offset s, age s, [source], [dir]
    local n d
    n=$(now)
    d="${7:-$H/.claude/usage-feed}"
    mkdir -p "$d"
    jq -n -c --argjson f "$1" --argjson fr $(( n + $2 )) --argjson w "$3" --argjson wr $(( n + $4 )) \
        --argjson ts $(( n - $5 )) --arg src "${6:-mod}" \
        '{ts: $ts, by: "mod-test", source: $src, event: "measure", five: {pct: $f, reset: $fr},
          week: {pct: $w, reset: $wr}, windows: [], changed: ["rateLimits"], surfaces: []}' \
        > "$d/feed-${ORG}_${ACCT}.json"
}
sha1_16() {
    if command -v sha1sum >/dev/null 2>&1; then printf '%s' "$1" | sha1sum | cut -c1-16
    else printf '%s' "$1" | shasum -a 1 | cut -c1-16; fi
}
dec_of() { printf '%s' "$OUT" | jq -r '.hookSpecificOutput.permissionDecision // empty' 2>/dev/null; }
why_of() { printf '%s' "$OUT" | jq -r '.hookSpecificOutput.permissionDecisionReason // empty' 2>/dev/null; }
sv() { cat "$AD/sessions/${2:-$SID}/$1" 2>/dev/null; }
sflag() { sv "stop${1}_${2}" | cut -d' ' -f1; } # stage, five|week -> active, done, skipped or empty

# =====================================================================
CUR="lint"
s=usage-limit.sh
t_true "$s exists" test -f "$HOOKS/$s"
t_true "$s executable" test -x "$HOOKS/$s"
t_eq "$s shebang" "$(head -n 1 "$HOOKS/$s")" '#!/usr/bin/env bash'
t_true "$s syntax" bash -n "$HOOKS/$s"
code=$(grep -v '^[[:space:]]*#' "$HOOKS/$s")
viol=""
for pat in 'declare -A' 'mapfile' 'readarray' ',,}' '^^}' '&>>' '[[ -v' 'local -n' 'coproc' \
           'sed -i' 'readlink -f' 'realpath' 'grep -P' 'xargs -r' '-printf' 'sort -V' \
           'touch -d' 'stat --format' 'flock' 'head -n -' 'mv -T' 'cp --parents' 'set -e' 'trap ' \
           '-mtime' 'uname' 'sort -rn -u' '/home/' '/Users/' 'printenv' '{8,64}$ ]]'; do
    if printf '%s\n' "$code" | grep -F -q -- "$pat"; then viol="$viol [$pat]"; fi
done
t_eq "$s forbidden constructs" "$viol" ""
t_eq "$s umask 077" "$(printf '%s\n' "$code" | grep -c '^umask 077$')" "1"
t_eq "$s no permissionDecision allow" "$(printf '%s\n' "$code" | grep -c 'permissionDecision: "allow"')" "0"

# =====================================================================
CUR="record"

new_env; run "$(post_usage 4 42)"
t_eq "record: exit 0" "$RC" "0"
t_eq "record: silent" "$OUT" ""
t_eq "record: five pct" "$(jq -r '.five.pct' "$AD/usage.json" 2>/dev/null)" "4"
t_eq "record: week pct" "$(jq -r '.week.pct' "$AD/usage.json" 2>/dev/null)" "42"
t_true "record: five reset is a future epoch" test "$(jq -r '.five.reset' "$AD/usage.json")" -gt "$(now)"
t_true "record: week reset after five reset" test "$(jq -r '.week.reset' "$AD/usage.json")" -gt "$(jq -r '.five.reset' "$AD/usage.json")"
t_eq "record: by session" "$(jq -r '.by' "$AD/usage.json")" "$SID"
t_has "record: logged" "$(cat "$LOGF")" "usage recorded by $SID: 5h=4% week=42%"
t_true "record: state dir mode 700" bash -c "ls -ld '$AD' | cut -c1-10 | grep -q '^drwx------\$'"

new_env; mkdir -p "$AD/poll.lock"; echo "$SID 1" > "$AD/poll.lock/owner"; run "$(post_usage 10 20)"
t_false "record: poll lock released" test -d "$AD/poll.lock"

new_env; run "$(post_usage 4 42 unavailable)"
t_false "record: status not ok writes nothing" test -f "$AD/usage.json"
t_true "record: status not ok sets poll_off_until" test -n "$(sv poll_off_until)"
t_has "record: status not ok logged" "$(cat "$LOGF")" "not usable"

new_env; run "$(post_usage 7 8 ok string)"
t_eq "record: string tool_response parsed" "$(jq -r '.five.pct' "$AD/usage.json" 2>/dev/null)" "7"

new_env; run "$(post_usage 9 9)" ONLY_SESSIONS="someone-else"
t_eq "record: works outside ONLY_SESSIONS" "$(jq -r '.five.pct' "$AD/usage.json" 2>/dev/null)" "9"

# =====================================================================
CUR="poll"

new_env; run "$(batch)"
C=$(ctx_of)
t_has "no reading: poll asked" "$C" "select:$TOOL_USAGE"
t_has "no reading: poll names the tool" "$C" "call $TOOL_USAGE"
t_eq "no reading: event name" "$(printf '%s' "$OUT" | jq -r '.hookSpecificOutput.hookEventName')" "PostToolBatch"
t_true "no reading: lock taken" test -d "$AD/poll.lock"
t_eq "no reading: lock owner" "$(cut -d' ' -f1 "$AD/poll.lock/owner" 2>/dev/null)" "$SID"
run "$(base PostToolBatch "$SID2" | jq -c '. + {tool_calls: []}')"
t_eq "second session while lock held: silent" "$OUT" ""

new_env; mkdir -p "$AD/poll.lock"; echo "$SID2 $(( $(now) - 200 ))" > "$AD/poll.lock/owner"
run "$(batch)"
t_has "stale lock: taken over" "$(ctx_of)" "select:$TOOL_USAGE"
t_eq "stale lock: new owner" "$(cut -d' ' -f1 "$AD/poll.lock/owner" 2>/dev/null)" "$SID"

new_env; mk_usage 10 7000 20 200000 60; run "$(batch)"
t_eq "fresh reading: no poll" "$OUT" ""
new_env; mk_usage 10 7000 20 200000 150; run "$(batch)"
t_eq "below 75%: 150 s old is still fresh (10 min)" "$OUT" ""
new_env; mk_usage 80 7000 20 200000 150; run "$(batch)"
t_has "above 75%: 150 s old is stale (2 min)" "$(ctx_of)" "select:$TOOL_USAGE"
new_env; mk_usage 10 7000 20 200000 700; run "$(batch)"
t_has "below 75%: 700 s old is stale" "$(ctx_of)" "select:$TOOL_USAGE"
new_env; mk_usage 10 7000 20 200000 100; run "$(batch)" POLL_LOW_MIN=1
t_has "POLL_LOW_MIN env respected" "$(ctx_of)" "select:$TOOL_USAGE"

new_env; run "$(batch)"; run "$(pre Bash)"
t_eq "poll pending: Bash denied" "$(dec_of)" "deny"
t_has "poll pending: reason names the tool" "$(why_of)" "$TOOL_USAGE"
run "$(pre ToolSearch)"
t_eq "poll pending: ToolSearch allowed" "$OUT" ""
run "$(pre "$TOOL_USAGE")"
t_eq "poll pending: get_usage allowed" "$OUT" ""
run "$(pre mcp__ccd_turn__update_plan)"
t_eq "poll pending: plan tool allowed" "$OUT" ""
run "$(pre Read /x "agent-1")"
t_eq "poll pending: subagent not blocked" "$OUT" ""
run "$(post_usage 5 10)"; run "$(pre Bash)"
t_eq "after reading: Bash allowed" "$OUT" ""
t_eq "after reading: poll_asked cleared" "$(sv poll_asked)" ""

new_env; run "$(batch)"
run "$(pre Bash)"; run "$(pre Bash)"; run "$(pre Bash)"
t_eq "third denial still denies" "$(dec_of)" "deny"
run "$(pre Bash)"
t_eq "fourth call: fail-open" "$OUT" ""
t_has "fail-open logged" "$(cat "$LOGF")" "fail-open"
t_false "fail-open: lock released" test -d "$AD/poll.lock"
t_true "first fail-open: 30 min" test "$(sv poll_off_until)" -le $(( $(now) + 1800 ))
run "$(batch)"
t_eq "fail-open: no new poll while poll_off" "$OUT" ""
printf '%s' $(( $(now) - 1 )) > "$AD/sessions/$SID/poll_off_until"
run "$(batch)"
t_has "after the 30 min: poll asked again" "$(ctx_of)" "select:$TOOL_USAGE"
run "$(pre Bash)"; run "$(pre Bash)"; run "$(pre Bash)"; run "$(pre Bash)"
t_true "second fail-open: off for 24 h" test "$(sv poll_off_until)" -gt $(( $(now) + 80000 ))
t_has "second fail-open: logged" "$(cat "$LOGF")" "fail-open for 24 h"

new_env; mkdir -p "$AD/poll.lock"; run "$(batch)"
t_eq "lock without owner, fresh: not taken over" "$OUT" ""
t_true "lock without owner: left in place" test -d "$AD/poll.lock"

new_env; run "$(ups "merhaba")"
t_has "prompt with no reading: poll asked" "$(ctx_of)" "select:$TOOL_USAGE"
t_eq "prompt poll: event name" "$(printf '%s' "$OUT" | jq -r '.hookSpecificOutput.hookEventName')" "UserPromptSubmit"

new_env; run "$(batch Read /x agent-7)"
t_eq "subagent batch: no poll" "$OUT" ""

# get_usage was called, but no reading came (seen 2026-11-04: the app did not answer).
new_env; run "$(batch)"
t_has "poll text: no retry after a failed call" "$(ctx_of)" "do not call it again"
run "$(pre "$TOOL_USAGE")"; run "$(pre Bash)"
t_eq "usage tried: Bash allowed" "$OUT" ""
t_eq "usage tried: no denial counted" "$(sv denials)" ""
run "$(batch "$TOOL_USAGE")"
t_eq "usage failed: batch silent" "$OUT" ""
t_eq "usage failed: poll_asked cleared" "$(sv poll_asked)" ""
t_false "usage failed: lock released" test -d "$AD/poll.lock"
t_true "usage failed: polls paused" test "$(sv poll_off_until)" -gt "$(now)"
t_true "usage failed: pause is 10 min" test "$(sv poll_off_until)" -le $(( $(now) + 600 ))
t_has "usage failed: logged" "$(cat "$LOGF")" "get_usage gave no reading"
run "$(pre Bash)"
t_eq "usage failed: next Bash allowed" "$OUT" ""
run "$(ups "devam")"
t_eq "usage failed: no poll on the next prompt" "$OUT" ""
printf '%s' $(( $(now) - 1 )) > "$AD/sessions/$SID/poll_off_until"
run "$(batch)"
t_has "usage failed: poll asked again after the pause" "$(ctx_of)" "select:$TOOL_USAGE"

# The app hook timed out before this hook saw the call: the batch input alone shows it.
new_env; run "$(batch)"; run "$(batch "$TOOL_USAGE")"
t_eq "usage in batch, no reading: silent" "$OUT" ""
t_eq "usage in batch, no reading: poll_asked cleared" "$(sv poll_asked)" ""
t_true "usage in batch, no reading: polls paused" test -n "$(sv poll_off_until)"

new_env; run "$(batch)"; run "$(pre "$TOOL_USAGE")"; run "$(post_usage 5 10)"; run "$(batch "$TOOL_USAGE")"
t_eq "usage ok in batch: silent" "$OUT" ""
t_eq "usage ok in batch: no pause" "$(sv poll_off_until)" ""
t_false "usage ok in batch: no failure logged" grep -q "gave no reading" "$LOGF"

new_env; run "$(batch)"; printf '%s' $(( $(now) - 100 )) > "$AD/sessions/$SID/usage_tried"; run "$(pre Bash)"
t_eq "call before the request: Bash denied" "$(dec_of)" "deny"

# =====================================================================
CUR="stop1"

new_env; mk_usage 92 7000 42 200000 30; run "$(batch)"
C=$(ctx_of); HF=$(sv handoff)
t_has "stop 1: model told to stop" "$C" "USAGE LIMIT STOP 1 of 2"
t_has "stop 1: reason with pct" "$C" "5 saatlik limit %92"
t_has "stop 1: both thresholds named" "$C" "first passes 91% and 96%"
t_has "stop 1: handoff path in text" "$C" "$HF"
t_eq "stop 1: handoff name is session name and session id" "$HF" "$P/.claude/Session-handoff-hooks-kurulumu-handoff-$SID.md"
t_has "stop 1: READ FIRST asked" "$C" "READ FIRST"
t_has "stop 1: running jobs asked" "$C" "watchers"
t_has "stop 1: memory asked" "$C" "memory"
t_has "stop 1: no secrets" "$C" "secrets"
t_has "stop 1: 6000 chars like group A" "$C" "under 6000 characters"
t_has "stop 1: byte limit" "$C" "7000 bytes"
t_has "stop 1: line 1 starts with the session name" "$C" "Line 1: '# Session handoff hooks kurulumu — limit devir notu'"
t_has "stop 1: user may continue" "$C" "may continue in this session"
t_eq "stop 1: flag active" "$(sflag 1 five)" "active"
t_eq "stop 1: flag carries the window reset" "$(sv stop1_five | cut -d' ' -f2)" "$(jq -r '.five.reset' "$AD/usage.json")"
t_eq "stop 1: weekly flag not set (weekly below threshold)" "$(sflag 1 week)" ""
t_has "stop 1: logged" "$(cat "$LOGF")" "limit: stop 1 of 2 for session $SID"
t_eq "stop 1: handoff id part is the session id" "$(basename "$HF" .md | sed 's/^.*-handoff-//')" "$SID"

run "$(pre Bash)"
t_eq "stop 1: Bash denied" "$(dec_of)" "deny"
t_has "stop 1: deny reason has the handoff path" "$(why_of)" "$HF"
run "$(pre Edit "$P/src/main.go")"
t_eq "stop 1: Edit of other file denied" "$(dec_of)" "deny"
run "$(pre Write "$HF")"
t_eq "stop 1: Write of handoff allowed" "$OUT" ""
run "$(pre Edit "$H/.claude/projects/-my-proj/memory/x.md")"
t_eq "stop 1: memory file allowed" "$OUT" ""
run "$(pre Read /etc/hosts)"
t_eq "stop 1: Read allowed" "$OUT" ""
run "$(pre ToolSearch)"
t_eq "stop 1: ToolSearch allowed" "$OUT" ""
run "$(pre Agent)"
t_eq "stop 1: Agent denied" "$(dec_of)" "deny"
run "$(pre Read /x agent-3)"
t_eq "stop 1: subagent denied" "$(dec_of)" "deny"
t_has "stop 1: subagent told to return" "$(why_of)" "return a short status report"
run "$(pre SubagentHandback "" "agent-3")"
t_eq "stop 1: SubagentHandback of a subagent allowed" "$OUT" ""
t_eq "stop 1: handoff path stable" "$(sv handoff)" "$HF"
t_true "stop 1: group A pending marker written" test -f "$H/.claude/hooks/state/pending.d/$(sha1_16 "$P")/$SID"
t_true "stop 1: marker holds an epoch" bash -c "case \"\$(cat '$H/.claude/hooks/state/pending.d/$(sha1_16 "$P")/$SID')\" in *[!0-9]*|'') exit 1;; esac"
run "$(batch)"
t_has "stop 1: a later batch still names the handoff path" "$(ctx_of)" "File: $HF"

mkdir -p "$TRD/memory"; echo "# mem" > "$TRD/memory/MEMORY.md"; echo "# proj" > "$P/CLAUDE.md"
echo "# old" > "$P/.claude/my-proj-handoff-$SID.md"
printf '# Session handoff hooks kurulumu — limit devir notu\n\n## READ FIRST\n- x\n' > "$HF"
run "$(post_write "$HF")"
C=$(ctx_of)
t_has "written: line 2 stamped" "$(sed -n 2p "$HF")" "Son güncelleme: 20"
t_eq "written: stamp is Turkey time with TR" "$(sed -n 2p "$HF" | grep -c -E '^Son güncelleme: [0-9]{4}-[0-9]{2}-[0-9]{2} [0-9]{2}:[0-9]{2}:[0-9]{2} TR$')" "1"
t_eq "written: title kept on line 1" "$(sed -n 1p "$HF" | cut -c1-9)" "# Session"
t_true "written: written marker" test -n "$(sv written)"
t_eq "written: stop 1 done" "$(sflag 1 five)" "done"
t_true "written: hold set" test -n "$(sv hold)"
t_has "written: no other work" "$C" "Do not do any other work"
t_has "written: CLEAR line goes before the block" "$C" "right before this block"
t_has "written: warning line" "$C" "⚠️ Kullanım limiti eşiği aşıldı: 5 saatlik limit %92"
t_has "written: warning names default thresholds" "$C" "Durak eşikleri: %91 ve %96."
t_no "written: no test note at default thresholds" "$C" "varsayılan %91"
t_has "written: same account may continue" "$C" "Aynı hesapla devam etmek için bu oturumda tekrar yaz."
t_no "written: no claim that the limit is full" "$C" "limiti doldu"
t_has "written: prompt block" "$C" '```text'
t_has "written: session name block" "$C" "$(printf 'Claude oturum ismi:\n```text\nSession handoff hooks kurulumu\n```')"
t_has "written: prompt label before its block" "$C" "$(printf 'Prompt:\n```text\nÖnceki oturum')"
t_no "written: no four-backtick block" "$C" '````'
t_has "written: short prompt in context" "$C" "Önceki oturumun işine devam ediyorum. $HF devir notunu ve bağlı detay notunu tamamen oku. READ FIRST bölümünü özetle ve onayımı bekle."
t_no "written: long body not in context" "$C" "DEVİR NOTU BAŞI"
PF="$IDX/$(basename "$HF" .md).prompt.txt"; PT=$(cat "$PF" 2>/dev/null)
t_has "written: context names prompt file" "$C" "$PF"
t_has "written: prompt has whole handoff" "$PT" "--- DEVİR NOTU BAŞI ($HF) ---"
t_has "written: prompt has handoff body" "$PT" "## READ FIRST"
t_has "written: prompt has stamp line" "$PT" "Son güncelleme: 20"
t_has "written: prompt has session and project" "$PT" "Oturum: Session handoff hooks kurulumu · Proje: $P"
t_has "written: prompt lists handoff" "$PT" "1. $HF"
t_has "written: prompt has older handoff of the session" "$PT" "$P/.claude/my-proj-handoff-$SID.md"
t_has "written: prompt has MEMORY.md" "$PT" "$TRD/memory/MEMORY.md"
t_has "written: prompt has project CLAUDE.md" "$PT" "$P/CLAUDE.md"
t_has "written: prompt has transcript" "$PT" "$TR"
t_has "written: prompt asks for approval" "$PT" "Onayımı bekle"
t_has "written: systemMessage" "$(sys_of)" "Otomatik durak: devir notu kaydedildi"
t_has "written: systemMessage says how to continue" "$(sys_of)" "devam etmek için tekrar yaz"
t_has "written: index lists handoff" "$(cat "$IDX/INDEX.md" 2>/dev/null)" "$HF"
t_has "written: index lists prompt file" "$(cat "$IDX/INDEX.md" 2>/dev/null)" "$PF"
t_has "written: index has short prompt" "$(cat "$IDX/INDEX.md" 2>/dev/null)" "$HF devir notunu ve bağlı detay notunu tamamen oku. READ FIRST"
t_has "written: logged" "$(cat "$LOGF")" "stop handoff written by $SID"

run "$(pre Bash)"
t_eq "hold: Bash still denied" "$(dec_of)" "deny"
t_has "hold: reason says saved" "$(why_of)" "is saved"
run "$(batch Write "$HF")"
t_eq "hold: batch that wrote the handoff not stopped" "$OUT" ""
run "$(batch Read /x)"
t_eq "hold: next batch continue false" "$(printf '%s' "$OUT" | jq -r '.continue' 2>/dev/null)" "false"
t_has "hold: stopReason has short prompt" "$(printf '%s' "$OUT" | jq -r '.stopReason' 2>/dev/null)" "$HF devir notunu ve bağlı detay notunu tamamen oku. READ FIRST"
t_no "hold: stopReason without long body" "$(printf '%s' "$OUT" | jq -r '.stopReason' 2>/dev/null)" "DEVİR NOTU BAŞI"
t_has "hold: stopReason says how to continue" "$(printf '%s' "$OUT" | jq -r '.stopReason' 2>/dev/null)" "tekrar yaz"

CUR="warn"
run "$(ups "devam et, şu işi bitir")"
C=$(ctx_of)
t_eq "warn: hold cleared by new prompt" "$(sv hold)" ""
t_has "warn: do the request" "$C" "Do the user's request normally"
t_has "warn: rule for an automatic turn after a stop" "$C" "not the user's own typed message"
t_has "warn: update handoff" "$C" "Write or update the handoff $HF"
t_has "warn: warning and prompt at end" "$C" "end your reply as follows"
t_has "warn: warning text" "$C" "⚠️ Kullanım limiti eşiği aşıldı"
t_has "warn: prompt block" "$C" '```text'
t_has "warn: session name block" "$C" "$(printf 'Claude oturum ismi:\n```text\nSession handoff hooks kurulumu\n```')"
t_has "warn: short prompt" "$C" "$HF devir notunu ve bağlı detay notunu tamamen oku. READ FIRST"
t_has "warn: prompt file named" "$C" ".prompt.txt"
t_has "warn: systemMessage" "$(sys_of)" "⚠️ Kullanım limiti eşiği aşıldı"
t_has "warn: systemMessage names thresholds" "$(sys_of)" "Durak eşikleri: %91 ve %96."
run "$(ups "devam")" STOP1_PCT=50 STOP2_PCT=95
t_has "warn: lowered thresholds named as not default" "$(ctx_of)" "Durak eşikleri: %50 ve %95 (varsayılan %91 ve %96, ayar: usage-limit.conf)."
t_has "warn: lowered thresholds in systemMessage" "$(sys_of)" "Durak eşikleri: %50 ve %95 (varsayılan"
t_no "warn: no stop" "$C" "USAGE LIMIT STOP"
run "$(pre Bash)"
t_eq "warn: Bash allowed" "$OUT" ""
run "$(batch Read /x)"
t_eq "warn: batch not stopped" "$(printf '%s' "$OUT" | jq -r '.continue // empty' 2>/dev/null)" ""
run "$(post_write "$HF" Edit)"
t_has "warn: handoff update keeps working" "$(ctx_of)" "Finish the user's request"
t_has "warn: handoff update names prompt file" "$(ctx_of)" "$PF"
t_has "warn: prompt file refreshed after update" "$(cat "$PF")" "Son güncelleme: 20"
t_has "warn: handoff update systemMessage" "$(sys_of)" "Devir notu güncellendi"
t_eq "warn: one stamp line after update" "$(grep -c '^Son güncelleme:' "$HF")" "1"
run "$(ups "bir şey daha")"
t_has "warn: every prompt warns" "$(sys_of)" "⚠️"
t_no "warn: automatic-turn rule only right after a stop" "$(ctx_of)" "not the user's own typed message"

CUR="stop2"
mk_usage 96 7000 42 200000 10; run "$(batch)"
t_has "stop 2: stops again" "$(ctx_of)" "USAGE LIMIT STOP 2 of 2"
t_eq "stop 2: flag active" "$(sflag 2 five)" "active"
t_eq "stop 2: same handoff file" "$(sv handoff)" "$HF"
run "$(post_write "$HF")"
t_eq "stop 2: done after write" "$(sflag 2 five)" "done"
run "$(ups "yine devam")"
t_has "after stop 2: warnings only" "$(ctx_of)" "USAGE ABOVE 91%"
t_no "after stop 2: no third stop" "$(ctx_of)" "USAGE LIMIT STOP"
mk_usage 99 7000 42 200000 10; run "$(batch Read /x)"
t_no "99 percent: still no third stop" "$(ctx_of)" "USAGE LIMIT STOP"

CUR="jump"
new_env; mk_usage 97 7000 10 200000 10; run "$(batch)"
t_has "jump to 97: one stop" "$(ctx_of)" "USAGE LIMIT STOP 2 of 2"
t_eq "jump: stop1 active too" "$(sflag 1 five)" "active"
printf '# t\n' > "$(sv handoff)"; run "$(post_write "$(sv handoff)")"
t_eq "jump: stop1 done" "$(sflag 1 five)" "done"
t_eq "jump: stop2 done" "$(sflag 2 five)" "done"
run "$(ups "x")"
t_no "jump: no second stop" "$(ctx_of)" "USAGE LIMIT STOP"

CUR="window"
new_env; WR=$(( $(now) + 200000 )); F1=$(( $(now) + 7000 )); F2=$(( $(now) + 25000 ))
mk_usage_abs 97 "$F1" 97 "$WR" 10; run "$(batch)"
t_has "window: first stop at 97/97" "$(ctx_of)" "USAGE LIMIT STOP 2 of 2"
t_eq "window: weekly flag active" "$(sflag 2 week)" "active"
printf '# t\n' > "$(sv handoff)"; run "$(post_write "$(sv handoff)")"
run "$(batch Read /x)"; run "$(ups "devam")"
t_no "window: same windows, no new stop" "$(ctx_of)" "USAGE LIMIT STOP"
mk_usage_abs 97 $(( F1 - 1 )) 97 $(( WR + 1 )) 10; run "$(batch)"
t_no "window: reset time jitter of 1 s is the same window" "$(ctx_of)" "USAGE LIMIT STOP"
mk_usage_abs 92 "$F2" 97 "$WR" 10; run "$(batch)"
t_has "window: new 5-hour window stops again while weekly stays high" "$(ctx_of)" "USAGE LIMIT STOP"
t_eq "window: new five flag active with new reset" "$(sv stop1_five)" "active $F2"
t_eq "window: weekly flags untouched" "$(sflag 2 week)" "done"
printf '# t\n' > "$(sv handoff)"; run "$(post_write "$(sv handoff)")"
run "$(batch Read /x)"; run "$(ups "devam")"
mk_usage_abs 92 "$F2" 97 "$WR" 10; run "$(batch)"
t_no "window: weekly alone does not stop again" "$(ctx_of)" "USAGE LIMIT STOP"
t_has "window: warnings continue" "$(cat "$LOGF")" "stop 2 of 2 for session $SID"

CUR="new-session"
new_env; printf '%s\n' '{"type":"user","message":{"role":"user","content":"hi"}}' '{"type":"custom-title","customTitle":"Yeni oturum","sessionId":"x"}' > "$TR"
mk_usage 93 7000 10 200000 10; run "$(ups "ilk mesaj")"
t_no "new session: no stop" "$(ctx_of)" "USAGE LIMIT STOP"
t_has "new session: warnings" "$(ctx_of)" "USAGE ABOVE 91%"
t_eq "new session: stop1 skipped" "$(sflag 1 five)" "skipped"
t_true "new session: own handoff file" bash -c "case '$(sv handoff)' in */Yeni-oturum-handoff-*) exit 0;; *) exit 1;; esac"
t_has "new session: logged" "$(cat "$LOGF")" "warnings only, no stop"
printf '%s\n' '{"type":"assistant","message":{"role":"assistant","content":"ok"}}' >> "$TR"
run "$(pre Bash)"
t_eq "new session: later tool not blocked" "$OUT" ""
mk_usage 96 7000 10 200000 10; run "$(batch)"
t_has "new session: stops at stage 2" "$(ctx_of)" "USAGE LIMIT STOP 2 of 2"

CUR="idle"
new_env; mk_usage 92 7000 10 200000 10; run "$(ups "yarım kalan işe devam")"
t_has "idle session: first prompt stops" "$(ctx_of)" "USAGE LIMIT STOP 1 of 2"
t_has "idle session: request not done" "$(ctx_of)" "Do not do the request itself"
t_has "idle session: tells user to write again" "$(ctx_of)" "Tekrar yazarsan bu oturumda devam ederim"
t_has "idle session: systemMessage" "$(sys_of)" "⏸️ Otomatik durak"

CUR="override"
new_env; mk_usage 92 7000 10 200000 10; run "$(batch)"
run "$(ups "tamam #limit-devam")"
t_has "override: stop skipped" "$(sys_of)" "Otomatik durak atlandı"
t_eq "override: stop1 done" "$(sflag 1 five)" "done"
t_has "override: warnings continue" "$(ctx_of)" "USAGE ABOVE 91%"
run "$(pre Bash)"
t_eq "override: Bash allowed" "$OUT" ""

CUR="thresholds"
new_env; printf '%s\n' '{"type":"user"}' '{"type":"assistant"}' > "$TR"; mk_usage 95 7000 10 200000 10; run "$(batch)"
t_true "no title: project name and session id" bash -c "case '$(sv handoff)' in '$P/.claude/my-proj-handoff-11111111-'*) exit 0;; *) exit 1;; esac"
t_eq "no title: title is the folder name and the short id" "$(sv title)" "my-proj-11111111"
new_env; printf '%s\n' '{"type":"user"}' '{"type":"assistant"}' > "$TR"; mk_usage 95 7000 10 200000 10
run "$(batch)" CLAUDE_CODE_SESSION_NAME="Web portal (v2)"
t_eq "launch name: used without a title record" "$(sv handoff)" "$P/.claude/Web-portal-v2-handoff-$SID.md"
t_eq "launch name: title kept as shown" "$(sv title)" "Web portal (v2)"
new_env; echo "# folder" > "$P/.claude/my-proj-handoff-$SID.md"; mk_usage 95 7000 10 200000 10; run "$(batch)"
t_eq "stop: folder-name handoff renamed to the session name" "$(sed -n 1p "$P/.claude/Session-handoff-hooks-kurulumu-handoff-$SID.md" 2>/dev/null)" "# folder"
t_false "stop: folder-name file gone" test -e "$P/.claude/my-proj-handoff-$SID.md"
t_has "stop: rename logged" "$(cat "$LOGF")" "handoff renamed to the session name"
new_env; mk_usage 90 7000 90 200000 10; run "$(batch)"
t_no "90 percent: nothing" "$(ctx_of)" "USAGE"
new_env; mk_usage 91 7000 10 200000 10; run "$(batch)"
t_has "91 percent: stop 1" "$(ctx_of)" "USAGE LIMIT STOP 1 of 2"
new_env; mk_usage 95 7000 10 200000 10; run "$(batch)"
t_has "95 percent: still stage 1" "$(ctx_of)" "STOP 1 of 2"
new_env; mk_usage 10 7000 92 200000 10; run "$(batch)"
t_has "weekly window counts" "$(ctx_of)" "haftalık limit %92"
t_no "weekly only: no 5h text" "$(ctx_of)" "5 saatlik"
new_env; mk_usage 93 7000 94 200000 10; run "$(batch)"
t_has "both windows listed" "$(ctx_of)" "5 saatlik limit %93, haftalık limit %94"
new_env; mk_usage 6 7000 10 200000 10; run "$(batch)" STOP1_PCT=5
t_has "STOP1_PCT env respected" "$(ctx_of)" "STOP 1 of 2"
new_env; mk_usage 60 7000 10 200000 10; printf 'STOP1_PCT=50\nSTOP2_PCT=55\n' > "$CONF"; run "$(batch)"
t_has "conf thresholds used" "$(ctx_of)" "STOP 2 of 2"
run "$(pre Bash)" STOP1_PCT=70
t_eq "env overrides conf" "$OUT" ""
printf 'STOP1_PCT=abc\n' > "$CONF"; run "$(pre Bash)"
t_eq "invalid conf value: default used (60 < 91)" "$OUT" ""
t_has "invalid conf value: logged" "$(cat "$LOGF")" "invalid STOP1_PCT"
new_env; mk_usage 10 7000 20 200000 500; run "$(batch)" POLL_LOW_MIN=010
t_eq "leading zero read as decimal (010 = 10 min, reading 500 s old)" "$OUT" ""
new_env; mk_usage 92 7000 10 200000 10; run "$(batch)" STOP1_PCT=150
t_has "STOP1_PCT out of range: default used" "$(ctx_of)" "STOP 1 of 2"
t_has "STOP1_PCT out of range: logged" "$(cat "$LOGF")" "STOP1_PCT=150 out of range"
new_env; mk_usage 55 7000 10 200000 10; run "$(batch)" STOP1_PCT=50 STOP2_PCT=40
t_has "STOP2 below STOP1: one stop at STOP1" "$(ctx_of)" "STOP 2 of 2"
t_has "STOP2 below STOP1: logged" "$(cat "$LOGF")" "below STOP1_PCT"
new_env; mk_usage 10 7000 20 200000 100; run "$(batch)" POLL_LOW_MIN=0
t_has "POLL_LOW_MIN=0 out of range: logged" "$(cat "$LOGF")" "POLL_LOW_MIN=0 out of range"
t_eq "POLL_LOW_MIN=0 out of range: default 10 min, no poll" "$OUT" ""

CUR="prompt-file"
if [ "$(id -u)" != "0" ]; then
    new_env; mk_usage 92 7000 10 200000 10; run "$(batch)"; HF=$(sv handoff); printf '# t\n' > "$HF"
    mkdir -p "$IDX"; chmod 500 "$IDX"
    run "$(post_write "$HF")"
    C=$(ctx_of)
    chmod 700 "$IDX"
    t_has "prompt file not written: said so" "$C" "Uzun sürüm dosyası yok"
    t_no "prompt file not written: no path handed out" "$C" ".prompt.txt"
    t_has "prompt file not written: logged" "$(cat "$LOGF")" "could not write prompt file"
    t_has "index not written: logged" "$(cat "$LOGF")" "could not rebuild the limit index"
fi

CUR="config-dir"
new_env; mk_usage 92 7000 10 200000 10; run "$(batch)" CLAUDE_CONFIG_DIR="$E/cfg"
t_true "CLAUDE_CONFIG_DIR: marker under the config dir" test -f "$E/cfg/hooks/state/pending.d/$(sha1_16 "$P")/$SID"
t_has "CLAUDE_CONFIG_DIR: log under the config dir" "$(cat "$E/cfg/hooks/context-pressure.log" 2>/dev/null)" "stop 1 of 2"
run "$(pre Edit "$E/cfg/projects/-my-proj/memory/x.md")" CLAUDE_CONFIG_DIR="$E/cfg"
t_eq "CLAUDE_CONFIG_DIR: memory file of the config dir allowed during a stop" "$OUT" ""

CUR="reset"
new_env; mk_usage 95 -10 10 200000 10; run "$(pre Bash)"
t_eq "window reset: no stop" "$OUT" ""
new_env; mk_usage 95 7000 10 200000 10; run "$(batch)"
mk_usage 95 -10 10 200000 10; run "$(pre Bash)"
t_eq "limit over: Bash allowed" "$OUT" ""
t_eq "limit over: session state cleared" "$(sv handoff)$(sv stop1_five)" ""
t_has "limit over: logged" "$(cat "$LOGF")" "limit over for session $SID"
mk_usage 93 7000 10 200000 10; run "$(batch)"
t_has "next window: stops again" "$(ctx_of)" "STOP 1 of 2"

CUR="scope"
new_env; mk_usage 95 7000 10 200000 10; ACCT="$ACCT_B"; run "$(pre Bash)"
t_eq "other account: not affected" "$OUT" ""
ACCT="$ACCT_A"; run "$(pre Bash)"
t_eq "same account: denied" "$(dec_of)" "deny"
ORG="$ORG_B"; run "$(pre Bash)"
t_eq "same account, other workspace: not affected" "$OUT" ""
t_true "other workspace: own state dir" test -d "$ST/${ORG_B}_${ACCT_A}"
ORG="$ORG_A"
new_env; mk_usage 95 7000 10 200000 10; run "$(pre Bash)" ONLY_SESSIONS="$SID2"
t_eq "ONLY_SESSIONS: other session untouched" "$OUT" ""
run "$(pre Bash)" ONLY_SESSIONS="$SID2 $SID"
t_eq "ONLY_SESSIONS: listed session denied" "$(dec_of)" "deny"
CUR="no-ids"
new_env; mk_usage 95 7000 10 200000 10
run_noid "$(pre Bash)"
t_eq "no ids: not stopped" "$OUT" ""
t_true "no ids: marker dir under unknown" test -d "$ST/unknown"
t_has "no ids: logged" "$(cat "$LOGF")" "guard off in this session"
run_noid "$(ups "merhaba")"
t_has "no ids: one-time notice" "$(sys_of)" "koruması bu oturumda kapalı"
t_no "no ids: no poll" "$(ctx_of)" "select:"
run_noid "$(ups "tekrar")"
t_eq "no ids: notice only once" "$OUT" ""
run_noid "$(post_usage 95 95)"
t_false "no ids: reading not recorded" test -f "$ST/unknown/usage.json"
new_env; AD="$ST/noorg_${ACCT_A}"; mk_usage 95 7000 10 200000 10
run_noid "$(pre Bash)" CLAUDE_CODE_ACCOUNT_UUID="$ACCT_A"
t_eq "account id without workspace id: guard off" "$OUT" ""
AD="$ST/${ORG}_${ACCT}"

CUR="index"
new_env; mk_usage 92 7000 10 200000 10; run "$(batch)"; HF1=$(sv handoff); printf '# a\n' > "$HF1"; run "$(post_write "$HF1")"
SID_KEEP="$SID"; SID="$SID2"; ACCT="$ACCT_B"; AD="$ST/${ORG}_${ACCT}"
mk_usage 93 7000 10 200000 10; run "$(batch)"; HF2=$(sv handoff); printf '# b\n' > "$HF2"; run "$(post_write "$HF2")"
t_has "index: first account kept" "$(cat "$IDX/INDEX.md" 2>/dev/null)" "$HF1"
t_has "index: second account listed" "$(cat "$IDX/INDEX.md" 2>/dev/null)" "$HF2"
t_has "index: reason per entry" "$(cat "$IDX/INDEX.md" 2>/dev/null)" "Sebep: 5 saatlik limit %93"
SID="$SID_KEEP"; ACCT="$ACCT_A"; AD="$ST/${ORG}_${ACCT}"

CUR="feed"
new_env; mk_feed 10 7000 20 200000 5; run "$(batch)"
t_eq "feed: fresh feed, no usage.json: no poll" "$OUT" ""
t_false "feed: no poll lock taken" test -d "$AD/poll.lock"
t_has "feed: use logged once" "$(cat "$LOGF")" "usage feed of the mod used by $SID: 5h=11% week=21%"
run "$(batch)"
t_eq "feed: use logged only once" "$(grep -c 'usage feed of the mod used' "$LOGF")" "1"
run "$(ups "merhaba")"
t_eq "feed: fresh feed: no poll on a prompt" "$OUT" ""
new_env; mk_feed 90 7000 20 200000 5; run "$(batch)"
t_has "feed: 5h 90 counts as 91: stop 1" "$(ctx_of)" "STOP 1 of 2"
t_has "feed: limit text has the +1 value" "$(ctx_of)" "5 saatlik limit %91"
new_env; mk_feed 89 7000 20 200000 5; run "$(batch)"
t_eq "feed: 5h 89 counts as 90: no stop, no poll" "$OUT" ""
new_env; mk_feed 10 7000 90 200000 5; run "$(batch)"
t_has "feed: weekly 90 counts as 91: stop 1" "$(ctx_of)" "haftalık limit %91"
new_env; mk_feed 90.5 7000 20 200000 5; run "$(batch)"
t_has "feed: decimal percent floored, then +1" "$(ctx_of)" "5 saatlik limit %91"
new_env; mk_feed 100 7000 20 200000 5; run "$(batch)" STOP2_PCT=101
t_has "feed: 100 capped at 100: stop 1 only" "$(ctx_of)" "STOP 1 of 2"
t_no "feed: 100 capped at 100: no stop 2" "$(ctx_of)" "STOP 2 of 2"
new_env; mk_usage 92 7000 10 200000 10; mk_feed 10 7000 10 200000 100; run "$(batch)"
t_has "feed: older than usage.json: usage.json wins" "$(ctx_of)" "STOP 1 of 2"
new_env; mk_usage 92 7000 10 200000 100; mk_feed 10 7000 10 200000 5; run "$(batch)"
t_eq "feed: newer than usage.json: feed wins" "$OUT" ""
new_env; mk_feed 10 7000 20 200000 700; run "$(batch)"
t_has "feed: stale feed: poll asked" "$(ctx_of)" "select:$TOOL_USAGE"
new_env; mk_feed 10 7000 20 200000 -3600; run "$(batch)"
t_has "feed: ts in the future: ignored" "$(ctx_of)" "select:$TOOL_USAGE"
new_env; mk_feed 10 7000 20 200000 5 other; run "$(batch)"
t_has "feed: source not mod: ignored" "$(ctx_of)" "select:$TOOL_USAGE"
new_env; mkdir -p "$H/.claude/usage-feed"; printf 'not json' > "$H/.claude/usage-feed/feed-${ORG}_${ACCT}.json"; run "$(batch)"
t_eq "feed: bad JSON: exit 0" "$RC" "0"
t_has "feed: bad JSON: poll asked" "$(ctx_of)" "select:$TOOL_USAGE"
new_env; mkdir -p "$H/.claude/usage-feed"; printf '{"source":"mod","ts":%s,"five":{"pct":"x","reset":1}}' "$(now)" > "$H/.claude/usage-feed/feed-${ORG}_${ACCT}.json"; run "$(batch)"
t_has "feed: non-number field: ignored" "$(ctx_of)" "select:$TOOL_USAGE"
new_env; ACCT="$ACCT_B"; mk_feed 95 7000 20 200000 5; ACCT="$ACCT_A"; run "$(batch)"
t_has "feed: other account's feed: ignored" "$(ctx_of)" "select:$TOOL_USAGE"
t_no "feed: other account's feed: no stop" "$(ctx_of)" "STOP"
new_env; run "$(batch)"; run "$(pre Bash)"
t_eq "feed: poll pending: Bash denied" "$(dec_of)" "deny"
mk_feed 10 7000 20 200000 0; run "$(pre Bash)"
t_eq "feed: fresh feed answers a pending poll" "$OUT" ""
t_eq "feed: poll_asked cleared" "$(sv poll_asked)" ""
new_env; mk_feed 10 7000 20 200000 5 mod "$E/feeddir"; run "$(batch)" USAGE_FEED_DIR="$E/feeddir"
t_eq "feed: USAGE_FEED_DIR respected" "$OUT" ""
new_env; mk_feed 10 7000 20 200000 5 mod "$E/cfg/usage-feed"; run "$(batch)" CLAUDE_CONFIG_DIR="$E/cfg"
t_eq "feed: CLAUDE_CONFIG_DIR respected" "$OUT" ""
new_env; mk_feed 95 7000 20 200000 5; run "$(pre Bash)" ONLY_SESSIONS="$SID2"
t_eq "feed: ONLY_SESSIONS still applies" "$OUT" ""

CUR="input"
new_env; run 'not json'
t_eq "invalid JSON: exit 0" "$RC" "0"
t_has "invalid JSON: logged" "$(cat "$LOGF")" "not valid JSON"
run "$(base PreToolUse '../x' | jq -c '. + {tool_name: "Bash"}')"
t_eq "bad session id: exit 0" "$RC" "0"
t_has "bad session id: logged" "$(cat "$LOGF")" "invalid session_id"
run '5'
t_eq "JSON number: exit 0" "$RC" "0"
new_env; awk 'BEGIN { for (i = 0; i < 14000; i++) print "2026-01-01T00:00:00Z filler line " i " xxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxx" }' > "$LOGF"
run "$(pre Read)"
t_true "log trimmed under 1 MB" test "$(wc -c < "$LOGF" | tr -d ' ')" -lt 1048576

# ---------- copies of handoffs expire (B17) ----------
CUR="copy-ttl"
mk_written() { # session id, age s, handoff path
    local d="$AD/sessions/$1"
    mkdir -p "$d"
    printf '%s' "$(( $(now) - $2 ))" > "$d/written"
    printf '%s' "$3" > "$d/handoff"
    printf '%s' "t" > "$d/title"
    mkdir -p "$IDX"
    printf 'copy\n' > "$IDX/$(basename "$3" .md).prompt.txt"
}
new_env; OLDS=33333333-0000-4000-8000-000000000003
mk_written "$OLDS" $(( 8 * 86400 )) "$P/.claude/old-handoff-$OLDS.md"
mk_written "$SID2" 3600 "$P/.claude/new-handoff-$SID2.md"
printf 'orphan\n' > "$IDX/orphan.prompt.txt"; touch -t 202001010000 "$IDX/orphan.prompt.txt"
run "$(ups hi)"
t_false "ttl: old session state removed" test -e "$AD/sessions/$OLDS"
t_false "ttl: old prompt file removed" test -e "$IDX/old-handoff-$OLDS.prompt.txt"
t_true "ttl: recent session state kept" test -e "$AD/sessions/$SID2/written"
t_true "ttl: recent prompt file kept" test -e "$IDX/new-handoff-$SID2.prompt.txt"
t_false "ttl: old orphan prompt file removed" test -e "$IDX/orphan.prompt.txt"
t_no "ttl: index has no old entry" "$(cat "$IDX/INDEX.md" 2>/dev/null)" "old-handoff-$OLDS"
t_has "ttl: index keeps the recent entry" "$(cat "$IDX/INDEX.md" 2>/dev/null)" "new-handoff-$SID2"
t_true "ttl: stamp written" test -e "$ST/prune.stamp"
mk_written "$OLDS" $(( 8 * 86400 )) "$P/.claude/old-handoff-$OLDS.md"
run "$(ups hi)"
t_true "ttl: at most once a day" test -e "$AD/sessions/$OLDS/written"
new_env; mk_written "$SID2" $(( 3 * 86400 )) "$P/.claude/new-handoff-$SID2.md"
run "$(ups hi)" HANDOFF_COPY_TTL_DAYS=2
t_false "ttl: setting respected (2 days)" test -e "$AD/sessions/$SID2"

# =====================================================================
CUR="worktree"
# A Desktop worktree session (2026-11-23): the app refuses Write and Edit of
# <project>/.claude/ from <project>/.claude/worktrees/<name>, and the stop blocks Bash.
# The session writes a draft in the worktree's .claude/; PostToolUse copies it.
new_env; WTD="$P/.claude/worktrees/wt-a"; mkdir -p "$WTD/sub"
mk_usage 92 7000 10 200000 30
CWD="$WTD/sub"; run "$(batch)" CLAUDE_PROJECT_DIR="$P"
HF=$(sv handoff); D="$WTD/.claude/${HF##*/}"
t_eq "worktree: handoff path stays in the project" "$HF" "$P/.claude/Session-handoff-hooks-kurulumu-handoff-$SID.md"
t_has "worktree: stop names the draft" "$(ctx_of)" "Write the whole handoff to $D instead"
run "$(pre Bash)" CLAUDE_PROJECT_DIR="$P"
t_eq "worktree: Bash denied" "$(dec_of)" "deny"
run "$(pre Write "$D")" CLAUDE_PROJECT_DIR="$P"
t_eq "worktree: Write of the draft allowed" "$OUT" ""
t_true "worktree: draft folder made" test -d "$WTD/.claude"
run "$(pre Write "$WTD/.claude/other.md")" CLAUDE_PROJECT_DIR="$P"
t_eq "worktree: Write of another worktree file denied" "$(dec_of)" "deny"
printf '# Session handoff hooks kurulumu — limit devir notu\n\n## READ FIRST\n- x\n' > "$D"
run "$(post_write "$D")" CLAUDE_PROJECT_DIR="$P"
t_eq "worktree: draft copied to the handoff path" "$(sed -n 5p "$HF" 2>/dev/null)" "## READ FIRST"
t_false "worktree: draft removed" test -e "$D"
t_has "worktree: handoff stamped" "$(sed -n 2p "$HF")" "Son güncelleme: 20"
t_true "worktree: written marker" test -n "$(sv written)"
t_has "worktree: context names the copy" "$(ctx_of)" "The hook copied $D to $HF"
t_has "worktree: systemMessage" "$(sys_of)" "devir notu kaydedildi"
run "$(batch Write "$D")" CLAUDE_PROJECT_DIR="$P"
t_eq "worktree: batch that wrote the draft not stopped" "$OUT" ""
run "$(post_write "$WTD/.claude/other.md")" CLAUDE_PROJECT_DIR="$P"
t_eq "worktree: other file is not copied" "$OUT" ""
CWD=""; new_env; mk_usage 92 7000 10 200000 30; run "$(batch)"
t_no "not a worktree: no draft text" "$(ctx_of)" "runs in a worktree"

CUR="detail-note"
# Three files per handoff (2026-11-23): handoff, detail note, transcript dump.
ALL8="## Decisions and reasons, ## User requests in their words, ## Open tasks, ## Background jobs, ## Ruled out and why, ## Lessons learned, ## Memory changes, ## Environment"
HAVE_PY=0; command -v python3 >/dev/null 2>&1 && HAVE_PY=1
mk_detail() { # handoff path [heading number to leave out]; prints the detail note path
    local d="${1%.md}.detay.md" i
    printf '# test — detay notu\n' > "$d"
    for i in 1 2 3 4 5 6 7 8; do
        [ "$i" = "${2:-0}" ] && continue
        printf '\n%s\nYok.\n' "$(printf '%s' "$ALL8" | awk -F', ' -v n="$i" '{ print $n }')" >> "$d"
    done
    printf '%s' "$d"
}
dump_file() { printf '%s' "$H/.claude/handoff-dumps/$(basename "${1%.md}").transcript.md"; }
HDR='# Session handoff hooks kurulumu — limit devir notu\n\n## READ FIRST\n- x\n'

# detail_missing in this hook (the function text is cut out of the script).
dm() { bash -c "$(awk '/^DETAIL_HEADINGS=/ { f = 1 } f { print } f && /Environment.$/ { exit }' "$SCRIPT")
$(awk '$0 ~ "^detail_missing[(][)] [{]" { f = 1 } f { print } f && /^}/ { exit }' "$SCRIPT")
detail_missing \"\$1\"" _ "$1"; }
new_env
t_eq "detail_missing: no file lists all eight" "$(dm "$E/none.md")" "$ALL8"
mk_detail "$E/x.md" >/dev/null
t_eq "detail_missing: complete note" "$(dm "$E/x.detay.md")" ""
mk_detail "$E/x.md" 8 >/dev/null
t_eq "detail_missing: one heading left out" "$(dm "$E/x.detay.md")" "## Environment"

# The stop text asks for the detail note first.
new_env; mk_usage 92 7000 42 200000 30; run "$(batch)"
C=$(ctx_of); HF=$(sv handoff); DET="${HF%.md}.detay.md"
t_has "stop text: detail note first" "$C" "Write the detail note first, then the handoff."
t_has "stop text: detail note path" "$C" "Detail note: write ${DET} before the handoff"
t_has "stop text: first line of the note" "$C" "'# Session handoff hooks kurulumu — detay notu'"
t_has "stop text: required headings" "$C" "$ALL8"
t_has "stop text: user's requests in their words" "$C" "the user's requests and corrections quoted in their own words"
t_has "stop text: memory files in full" "$C" "the full text of every memory file this session wrote or changed"
t_has "stop text: no size limit" "$C" "no size limit"
t_has "stop text: the dump is a hook's job" "$C" "$(dump_file "$HF") is written by a hook"
t_has "stop text: allowed files" "$C" "writing the detail note and that handoff file"
t_has "stop text: handoff lines 2 and 3" "$C" "'Ek dosyalar: …'"
pd=${C%%Detail note: write*}; ph=${C%%Handoff: Line 1*}
t_true "stop text: the note comes before the handoff text" test "${#pd}" -lt "${#ph}"

# PreToolUse during a stop.
run "$(pre Write "$DET")"
t_eq "stop: Write of the detail note allowed" "$OUT" ""
run "$(pre Edit "$DET")"
t_eq "stop: Edit of the detail note allowed" "$OUT" ""
run "$(pre Write "$P/.claude/other.detay.md")"
t_eq "stop: another detail note denied" "$(dec_of)" "deny"

# A write of the handoff while D is missing.
printf "$HDR" > "$HF"; run "$(post_write "$HF")"
C=$(ctx_of)
t_has "handoff write: detail note named" "$C" "The detail note ${DET} does not exist: write it now"
t_has "handoff write: headings listed" "$C" "$ALL8"
t_has "handoff write: only the note is allowed" "$C" "Do not do any other work except the detail note"
t_has "handoff write: the block is still handed over" "$C" "$(printf 'Prompt:\n```text\nÖnceki oturum')"
t_has "handoff write: Son güncelleme on line 2" "$(sed -n 2p "$HF")" "Son güncelleme: 20"
t_eq "handoff write: Ek dosyalar on line 3" "$(sed -n 3p "$HF")" "Ek dosyalar: detay notu ${DET} · tam döküm $(dump_file "$HF")"
t_eq "handoff write: the body follows" "$(sed -n 5p "$HF")" "## READ FIRST"
run "$(post_write "$HF")"
t_eq "handoff write: still one Ek dosyalar line" "$(grep -c '^Ek dosyalar:' "$HF")" "1"
t_eq "handoff write: still one Son güncelleme line" "$(grep -c '^Son güncelleme:' "$HF")" "1"
t_has "handoff write: the long prompt names the dump" "$(cat "$IDX/$(basename "$HF" .md).prompt.txt")" "Tam transcript dökümü (bir hook yazdı, model yazmadı): $(dump_file "$HF")"
t_has "handoff write: no detail note yet in the long prompt" "$(cat "$IDX/$(basename "$HF" .md).prompt.txt")" "(Detay notu henüz yazılmadı.)"

# The batch after the handoff write is not stopped, and neither is the one that writes D.
run "$(batch Write "$HF")"
t_eq "batch of the handoff: not stopped" "$OUT" ""
run "$(batch Write "$DET")"
t_eq "batch of the detail note: not stopped" "$OUT" ""
run "$(batch Read /x)"
t_eq "the next batch is stopped" "$(printf '%s' "$OUT" | jq -r '.continue' 2>/dev/null)" "false"

# A write of an incomplete, then a complete detail note.
mk_detail "$HF" 4 >/dev/null
run "$(post_write "$DET")"
t_has "incomplete detail note: missing heading named" "$(ctx_of)" "It still misses these sections: ## Background jobs"
mk_detail "$HF" >/dev/null
run "$(post_write "$DET")"
C=$(ctx_of)
t_has "complete detail note: said so" "$C" "The detail note is saved and complete: ${DET}"
t_has "complete detail note: the block is handed over" "$C" "Show the user this warning line and prompt block"
t_has "complete detail note: systemMessage" "$(sys_of)" "Detay notu kaydedildi"
PT=$(cat "$IDX/$(basename "$HF" .md).prompt.txt")
t_has "long prompt: detail note begin" "$PT" "--- DETAY NOTU BAŞI (${DET}) ---"
t_has "long prompt: detail note body" "$PT" "## Lessons learned"
t_has "long prompt: detail note end" "$PT" "--- DETAY NOTU SONU ---"
t_has "long prompt: detail note comes after the handoff" "$PT" "--- DEVİR NOTU SONU ---"
pa=${PT%%--- DEVİR NOTU SONU ---*}; pb=${PT%%--- DETAY NOTU BAŞI*}
t_true "long prompt: handoff text first" test "${#pa}" -lt "${#pb}"
t_has "long prompt: intro names both notes" "$PT" "devir notunun ve detay notunun tamamı"
run "$(post_write "$HF")"
t_has "complete detail note: the handoff write is confirmed" "$(ctx_of)" "The handoff is saved: ${HF}."
t_no "complete detail note: no detail warning on the handoff write" "$(ctx_of)" "except the detail note"
t_has "complete detail note: INDEX line" "$(cat "$IDX/INDEX.md")" "devir notunu ve bağlı detay notunu tamamen oku. READ FIRST bölümünü özetle ve onayımı bekle."

# The long prompt cuts the detail note at 60000 bytes and the handoff at 12000.
head -c 61000 /dev/zero | tr '\0' 'z' >> "$DET"
printf 'tail-of-detail\n' >> "$DET"
run "$(post_write "$DET")"
PT=$(cat "$IDX/$(basename "$HF" .md).prompt.txt")
t_has "long prompt: long detail note cut" "$PT" "(Detay notu uzun: burada ilk 60000 bayt var. Tamamı dosyada.)"
t_no "long prompt: the tail of the detail note is cut" "$PT" "tail-of-detail"
head -c 13000 /dev/zero | tr '\0' 'q' > "$HF.body"; { printf "$HDR"; cat "$HF.body"; printf '\nhandoff-tail\n'; } > "$HF"; rm -f "$HF.body"
run "$(post_write "$HF")"
PT=$(cat "$IDX/$(basename "$HF" .md).prompt.txt")
t_has "long prompt: long handoff cut" "$PT" "(Devir notu uzun: burada ilk 12000 bayt var. Tamamı dosyada.)"
t_no "long prompt: the tail of the handoff is cut" "$PT" "handoff-tail"

# The dump after a write of the handoff.
if [ "$HAVE_PY" = "1" ]; then
    new_env; mk_usage 92 7000 42 200000 30; run "$(batch)"; HF=$(sv handoff)
    printf "$HDR" > "$HF"; run "$(post_write "$HF")"
    XF=$(dump_file "$HF")
    t_true "dump: created after a write of the handoff" test -s "$XF"
    t_has "dump: has the conversation section" "$(cat "$XF" 2>/dev/null)" "## Konuşma"
    t_has "dump: has the title of the session" "$(cat "$XF" 2>/dev/null)" "# Session handoff hooks kurulumu — tam transcript dökümü"
    t_true "dump: file mode 600" bash -c "ls -l '$XF' | cut -c1-10 | grep -q '^-rw-------\$'"
    t_true "dump: folder mode 700" bash -c "ls -ld '$H/.claude/handoff-dumps' | cut -c1-10 | grep -q '^drwx------\$'"
    rm -f "$XF"
    run "$(post_write "$HF")" HANDOFF_DUMP_SYNC=
    i=0; while [ ! -s "$XF" ] && [ "$i" -lt 50 ]; do sleep 0.1; i=$((i + 1)); done
    t_true "dump: the background run finishes" test -s "$XF"
    new_env; mk_usage 92 7000 42 200000 30; run "$(batch)"; HF=$(sv handoff)
    mkdir -p "$H/.claude"; printf 'x\n' > "$H/.claude/handoff-dumps"
    printf "$HDR" > "$HF"; run "$(post_write "$HF")"
    t_eq "dump: a failing dump exits 0" "$RC" "0"
    t_has "dump: a failing dump still hands over the block" "$(ctx_of)" "The handoff is saved"
    t_has "dump: a failing dump is logged" "$(cat "$LOGF")" "handoff dump failed"
fi

# No python3 or no script: logged once per session, the stop goes on.
new_env; mk_usage 92 7000 42 200000 30; run "$(batch)"; HF=$(sv handoff)
NOPY="$E/nopy"; mkdir -p "$NOPY"; cp "$SCRIPT" "$NOPY/usage-limit.sh"; chmod 755 "$NOPY/usage-limit.sh"
printf "$HDR" > "$HF"
OUT=$(printf '%s' "$(post_write "$HF")" | env -u CLAUDE_PROJECT_DIR -u CTX_PRESSURE_STATE_DIR -u CLAUDE_CONFIG_DIR -u USAGE_FEED_DIR -u CLAUDE_CODE_SESSION_NAME HOME="$H" USAGE_LIMIT_STATE_DIR="$ST" HANDOFF_DUMP_SYNC=1 \
    USAGE_LIMIT_INDEX_DIR="$IDX" USAGE_LIMIT_CONF="$CONF" CLAUDE_CODE_ACCOUNT_UUID="$ACCT" CLAUDE_CODE_ORGANIZATION_UUID="$ORG" "$NOPY/usage-limit.sh" 2>/dev/null); RC=$?
t_eq "no dump script: exit 0" "$RC" "0"
t_has "no dump script: the block is handed over" "$(ctx_of)" "The handoff is saved"
t_has "no dump script: logged" "$(cat "$LOGF")" "handoff dump skipped for $SID"
t_false "no dump script: no dump" test -e "$(dump_file "$HF")"

# The rename of a handoff takes its detail note along.
new_env; mk_usage 92 7000 42 200000 30
OLDH="$P/.claude/oldname-handoff-$SID.md"; printf '# old\n' > "$OLDH"; mk_detail "$OLDH" >/dev/null
run "$(batch)"; HF=$(sv handoff)
t_true "rename: the handoff moved to the session name" test -f "$HF"
t_true "rename: the detail note follows" test -f "${HF%.md}.detay.md"
t_false "rename: the old detail note is gone" test -e "${OLDH%.md}.detay.md"

# A Desktop worktree session: the detail note gets its own draft.
new_env; WTD="$P/.claude/worktrees/wt-b"; mkdir -p "$WTD/sub"
mk_usage 92 7000 10 200000 30
CWD="$WTD/sub"; run "$(batch)" CLAUDE_PROJECT_DIR="$P"
HF=$(sv handoff); DET="${HF%.md}.detay.md"; DD="$WTD/.claude/${DET##*/}"; HD="$WTD/.claude/${HF##*/}"
t_has "worktree: stop names the detail draft" "$(ctx_of)" "write it to ${DD}; a hook copies it to ${DET}"
run "$(pre Write "$DD")" CLAUDE_PROJECT_DIR="$P"
t_eq "worktree: Write of the detail draft allowed" "$OUT" ""
t_true "worktree: draft folder made" test -d "$WTD/.claude"
mkdir -p "$WTD/.claude"; mk_detail "$E/tmpd.md" >/dev/null; cp "$E/tmpd.detay.md" "$DD"
run "$(post_write "$DD")" CLAUDE_PROJECT_DIR="$P"
t_true "worktree: draft copied to the detail note" test -f "$DET"
t_eq "worktree: the copy is complete" "$(dm "$DET")" ""
t_false "worktree: detail draft removed" test -e "$DD"
t_has "worktree: the copy is named" "$(ctx_of)" "The hook copied $DD to $DET"
t_has "worktree: the handoff comes next" "$(ctx_of)" "Now write the handoff"

printf '%s: %s pass, %s fail\n' "$LABEL" "$PASS" "$FAIL"
if [ "$FAIL" -gt 0 ]; then printf '%s\n' "$FAILS" | head -n 60; exit 1; fi
exit 0
