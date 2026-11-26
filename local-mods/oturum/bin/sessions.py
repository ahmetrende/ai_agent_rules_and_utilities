#!/usr/bin/env python3
"""List Claude sessions and the metadata of their last handoff notes.

Python 3 standard library only. Read-only: nothing is written or changed.

Usage:
  sessions.py --json [--days N]        This machine as JSON (default 3 days).
  sessions.py --text [--days N]        This machine as Markdown tables.
  sessions.py --all [--json] [--days N]
  sessions.py --all --text [--days N]  This machine and each machine in
                                       <repo>/local/machines.md (SSH).

--all runs "sessions.py --json" on the other machines over SSH, in parallel.
It uses BatchMode, so a machine that needs a password shows up as an error.
Exit code is 0 even when one machine fails. The failure is in the output.
"""

import argparse
import concurrent.futures
import datetime
import glob
import json
import os
import re
import shlex
import socket
import subprocess
import sys
import time

SCRIPT = os.path.abspath(__file__)
# Turkey time is UTC+3 all year.
TR_OFFSET = 10800
DEFAULT_DAYS = 3
READ_FIRST_JSON = 200
SSH_TIMEOUT = 120
MACHINE_PATTERN = re.compile(r"^- (.+): `ssh ([^`]+)`, repo yolu `([^`]+)`")

CUSTOM_TITLE = re.compile(rb'"customTitle"\s*:\s*"((?:[^"\\]|\\.)*)"')
AI_TITLE = re.compile(rb'"aiTitle"\s*:\s*"((?:[^"\\]|\\.)*)"')
CWD = re.compile(rb'"cwd"\s*:\s*"((?:[^"\\]|\\.)*)"')
BRANCH = re.compile(rb'"gitBranch"\s*:\s*"((?:[^"\\]|\\.)*)"')
# The organization (Claude account) the session was started with.
ORG = re.compile(rb'"credential_org"\s*,\s*"organizationUuid"\s*:\s*"([A-Za-z0-9-]{8,64})"')
# Subagent and teammate sessions: "agent-a9" and the like. They are not shown.
AGENT_TITLE = re.compile(r"^agent-[0-9a-f]+$")
ACCOUNT_LINE = re.compile(r"^- ([A-Za-z0-9-]{8,64}):\s*(.+?)\s*$")
# At most this many sessions in the text for the slash command. The pane shows all.
MAX_TEXT = 15
# A session that went on this long after its handoff was written gets a warning.
STALE_AFTER = 600


# ---------------------------------------------------------------- paths


def config_dir():
    value = os.environ.get("CLAUDE_CONFIG_DIR")
    if value:
        return os.path.expanduser(value)
    return os.path.join(os.path.expanduser("~"), ".claude")


def repo_dir(cfg):
    """Repo folder: env, then the @.../AGENTS.md line in CLAUDE.md, then the script's place."""
    value = os.environ.get("AI_AGENT_RULES_DIR")
    if value:
        return os.path.expanduser(value)
    try:
        with open(os.path.join(cfg, "CLAUDE.md"), encoding="utf-8", errors="replace") as handle:
            for line in handle:
                match = re.match(r"^\s*@(.+)/AGENTS\.md\s*$", line)
                if match:
                    return os.path.expanduser(match.group(1).strip())
    except OSError:
        pass
    guess = SCRIPT
    for _ in range(4):
        guess = os.path.dirname(guess)
    if os.path.isfile(os.path.join(guess, "AGENTS.md")):
        return guess
    return None


def short_host():
    return socket.gethostname().split(".")[0] or "unknown"


# ---------------------------------------------------------------- transcripts


def decode(raw):
    """Decode the inside of a JSON string literal. Return None on failure."""
    try:
        return json.loads('"' + raw.decode("utf-8", "replace") + '"')
    except ValueError:
        return None


def scan_transcript(path):
    """Return (customTitle, aiTitle, cwd, gitBranch, organization id), each the newest value or None."""
    custom = ai = cwd = branch = org = None
    try:
        with open(path, "rb") as handle:
            for line in handle:
                if b'"customTitle"' in line:
                    match = CUSTOM_TITLE.search(line)
                    if match:
                        custom = decode(match.group(1)) or custom
                if b'"aiTitle"' in line:
                    match = AI_TITLE.search(line)
                    if match:
                        ai = decode(match.group(1)) or ai
                if b'"cwd"' in line:
                    match = CWD.search(line)
                    if match:
                        cwd = decode(match.group(1)) or cwd
                if b'"gitBranch"' in line:
                    match = BRANCH.search(line)
                    if match:
                        branch = decode(match.group(1)) or branch
                if b'credential_org' in line:
                    match = ORG.search(line)
                    if match:
                        org = decode(match.group(1)) or org
    except OSError:
        return None, None, None, None, None
    return custom, ai, cwd, branch, org


# ---------------------------------------------------------------- handoffs


_DIR_CACHE = {}


def is_dir(path):
    """os.path.isdir with a cache. A missing folder makes every path under it missing
    without another file system call. On macOS each check of a /home/... path costs
    about 20 ms (automount), and the Mac keeps the transcripts of SSH sessions whose
    folders are on another machine: without the cache /oturum spent ~9 s on such checks."""
    path = os.path.normpath(path)
    if path in _DIR_CACHE:
        return _DIR_CACHE[path]
    parent = os.path.dirname(path)
    if parent != path and not is_dir(parent):
        _DIR_CACHE[path] = False
        return False
    result = os.path.isdir(path)
    _DIR_CACHE[path] = result
    return result


def handoff_dirs(cwd):
    dirs = [os.path.join(cwd, ".claude")]
    marker = "/.claude/worktrees/"
    index = cwd.find(marker)
    if index >= 0:
        dirs.append(cwd[:index] + "/.claude")
    return dirs


def read_head(path, limit=65536):
    with open(path, encoding="utf-8", errors="replace") as handle:
        return handle.read(limit)


def parse_handoff(text):
    """Return (title, readFirst). Either can be None."""
    lines = text.splitlines()
    title = None
    for line in lines:
        if line.strip():
            title = line.strip()
            if title.startswith("# "):
                title = title[2:].strip()
            break
    read_first = None
    for index, line in enumerate(lines):
        if re.match(r"^##\s+READ FIRST\b", line.strip(), re.IGNORECASE):
            for follow in lines[index + 1:]:
                if follow.strip():
                    read_first = follow.strip()[:READ_FIRST_JSON]
                    break
            break
    return title, read_first


def find_handoff(cfg, cwd, session_id):
    if not cwd:
        return None
    found = []
    safe = glob.escape(session_id)
    for folder in handoff_dirs(cwd):
        if not is_dir(folder):
            continue
        patterns = [
            os.path.join(glob.escape(folder), "*-handoff-%s.md" % safe),
            os.path.join(glob.escape(folder), "handoff-%s.md" % safe),
        ]
        for pattern in patterns:
            for path in glob.glob(pattern):
                try:
                    found.append((os.stat(path).st_mtime, path))
                except OSError:
                    continue
    if not found:
        return None
    found.sort(reverse=True)
    written, path = found[0]
    title = read_first = None
    try:
        title, read_first = parse_handoff(read_head(path))
    except OSError:
        pass
    detail = path[:-3] + ".detay.md"
    dump = os.path.join(
        cfg, "handoff-dumps", os.path.basename(path)[:-3] + ".transcript.md"
    )
    return {
        "path": path,
        "prompt": handoff_prompt(path),
        "writtenAt": int(written),
        "title": title,
        "readFirst": read_first,
        "detail": {"path": detail, "exists": os.path.isfile(detail)},
        "dump": {"path": dump, "exists": os.path.isfile(dump)},
    }


def session_folder(cwd):
    """The folder to open a new session in: the main repo for a worktree session."""
    if not cwd:
        return None
    marker = "/.claude/worktrees/"
    index = cwd.find(marker)
    return cwd[:index] if index > 0 else cwd


def handoff_prompt(path):
    """The prompt the user gives another session to go on with this handoff."""
    return (
        "Önceki oturumun işine devam ediyorum. %s devir notunu ve bağlı detay notunu "
        "tamamen oku. READ FIRST bölümünü özetle ve onayımı bekle." % path
    )


# ---------------------------------------------------------------- collect


def collect_local(days):
    cfg = config_dir()
    cutoff = time.time() - days * 86400
    sessions = []
    for path in glob.glob(os.path.join(glob.escape(cfg), "projects", "*", "*.jsonl")):
        try:
            info = os.stat(path)
            if info.st_mtime < cutoff:
                continue
            session_id = os.path.basename(path)[: -len(".jsonl")]
            custom, ai, cwd, branch, org = scan_transcript(path)
            if AGENT_TITLE.match(custom or ai or ""):
                continue
            handoff = None
            try:
                handoff = find_handoff(cfg, cwd, session_id)
            except Exception:
                handoff = None
            sessions.append(
                {
                    "sessionId": session_id,
                    "title": custom or ai,
                    "cwd": cwd,
                    "folder": session_folder(cwd),
                    "project": os.path.basename((cwd or "").rstrip("/")) or None,
                    "gitBranch": branch,
                    "orgId": org,
                    "lastActivity": int(info.st_mtime),
                    "sizeBytes": info.st_size,
                    "handoff": handoff,
                    # False for a remote session whose transcript the app keeps here too.
                    "cwdExists": bool(cwd) and is_dir(cwd),
                }
            )
        except Exception:
            continue
    sessions.sort(key=lambda item: item["lastActivity"], reverse=True)
    return {"host": short_host(), "generated": int(time.time()), "sessions": sessions}


# ---------------------------------------------------------------- machines


def parse_machines(text):
    """Return (machines, notes). A machine is (name, ssh_args, repo_path)."""
    machines = []
    notes = []
    for line in text.splitlines():
        match = MACHINE_PATTERN.match(line)
        if match:
            machines.append((match.group(1), match.group(2), match.group(3)))
        elif line.startswith("- "):
            notes.append("local/machines.md: bu satır makine satırı değil: " + line)
    return machines, notes


def remote_cd_path(path):
    if path == "~":
        return '"$HOME"'
    if path.startswith("~/"):
        return '"$HOME"/' + shlex.quote(path[2:])
    return shlex.quote(path)


def fetch_remote(machine, days):
    name, ssh_args, repo_path = machine
    result = {"name": name, "host": None, "ok": False, "error": None, "sessions": []}
    command = "cd %s && python3 local-mods/oturum/bin/sessions.py --json --days %d" % (
        remote_cd_path(repo_path),
        days,
    )
    argv = ["ssh", "-n", "-o", "BatchMode=yes", "-o", "ConnectTimeout=10"]
    argv += shlex.split(ssh_args)
    argv.append(command)
    try:
        done = subprocess.run(
            argv,
            stdin=subprocess.DEVNULL,
            capture_output=True,
            text=True,
            errors="replace",
            timeout=SSH_TIMEOUT,
        )
    except subprocess.TimeoutExpired:
        result["error"] = "ssh timeout (%d s)" % SSH_TIMEOUT
        return result
    except Exception as error:
        result["error"] = str(error).splitlines()[0] if str(error) else type(error).__name__
        return result
    if done.returncode != 0:
        lines = [line for line in done.stderr.splitlines() if line.strip()]
        result["error"] = lines[0].strip() if lines else "exit code %d" % done.returncode
        return result
    data = None
    for line in reversed(done.stdout.splitlines()):
        if line.startswith("{"):
            try:
                data = json.loads(line)
            except ValueError:
                data = None
            break
    if not isinstance(data, dict) or not isinstance(data.get("sessions"), list):
        result["error"] = "çıktı JSON değil"
        return result
    result["ok"] = True
    result["host"] = data.get("host")
    result["sessions"] = data["sessions"]
    return result


def local_name(host):
    """The name of this machine in the output: "Mac (bu makine)" on macOS."""
    return "%s (bu makine)" % ("Mac" if sys.platform == "darwin" else host)


def load_accounts(repo):
    """Read <repo>/local/accounts.md: lines "- <organization id>: <name>"."""
    names = {}
    if not repo:
        return names
    try:
        with open(os.path.join(repo, "local", "accounts.md"), encoding="utf-8", errors="replace") as handle:
            for line in handle:
                match = ACCOUNT_LINE.match(line.strip())
                if match:
                    names[match.group(1)] = match.group(2)
    except OSError:
        pass
    return names


def add_accounts(machines, names):
    """Give each session the account name of its organization id, or None."""
    for machine in machines:
        for item in machine.get("sessions") or []:
            item["account"] = names.get(item.get("orgId") or "")


def collect_all(days):
    local = collect_local(days)
    machines_out = [
        {
            "name": local_name(local["host"]),
            "host": local["host"],
            "ok": True,
            "error": None,
            "sessions": local["sessions"],
        }
    ]
    notes = []
    repo = repo_dir(config_dir())
    machines_file = os.path.join(repo, "local", "machines.md") if repo else None
    machines = []
    if machines_file and os.path.isfile(machines_file):
        try:
            with open(machines_file, encoding="utf-8", errors="replace") as handle:
                machines, notes = parse_machines(handle.read())
        except OSError as error:
            notes.append("local/machines.md okunamadı: %s" % error)
    else:
        notes.append(
            "local/machines.md yok, yalnız bu makine gösteriliyor. Örnek: local.example/machines.md"
        )
    if machines:
        with concurrent.futures.ThreadPoolExecutor(max_workers=min(8, len(machines))) as pool:
            machines_out.extend(pool.map(lambda item: fetch_remote(item, days), machines))
    drop_copies(machines_out)
    return {"generated": local["generated"], "machines": machines_out, "notes": notes}


def drop_copies(machines_out):
    """Keep one row per session: the machine whose disk holds the session's folder.

    The Desktop app keeps the transcript of an SSH session on this machine too, so the
    same session id can come from two machines. A row whose cwd does not exist on its
    machine goes when another machine has the same session with an existing cwd.
    """
    owned = set()
    for machine in machines_out:
        for item in machine.get("sessions") or []:
            if item.get("cwdExists"):
                owned.add(item.get("sessionId"))
    for machine in machines_out:
        rows = machine.get("sessions") or []
        machine["sessions"] = [
            item
            for item in rows
            if item.get("cwdExists", True) or item.get("sessionId") not in owned
        ]


# ---------------------------------------------------------------- usage


def int_or_none(value):
    return value if isinstance(value, int) and not isinstance(value, bool) else None


def usage_summary(config, names):
    """The last usage reading of each account on this machine, newest first.

    The usage-feed mod writes <config>/usage-feed/feed-<org id>_<account id>.json.
    A file that cannot be read is skipped.
    """
    out = []
    for path in glob.glob(os.path.join(config, "usage-feed", "feed-*.json")):
        org = os.path.basename(path)[len("feed-"):-len(".json")].split("_", 1)[0]
        try:
            with open(path, encoding="utf-8") as handle:
                reading = json.load(handle)
        except (OSError, ValueError):
            continue
        if not isinstance(reading, dict):
            continue
        five = reading.get("five") if isinstance(reading.get("five"), dict) else {}
        week = reading.get("week") if isinstance(reading.get("week"), dict) else {}
        out.append({
            "orgId": org,
            "account": names.get(org),
            "fivePct": int_or_none(five.get("pct")),
            "fiveReset": int_or_none(five.get("reset")),
            "weekPct": int_or_none(week.get("pct")),
            "weekReset": int_or_none(week.get("reset")),
            "measuredAt": int_or_none(reading.get("mts")) or int_or_none(reading.get("ts")),
        })
    out.sort(key=lambda item: item["measuredAt"] or 0, reverse=True)
    return out


def usage_line(item, now):
    """One line for one account. A window whose reset time has passed shows "sıfırlandı"."""
    def window(label, pct, reset, fmt):
        if pct is None:
            return "%s -" % label
        if reset and reset <= now:
            return "%s sıfırlandı" % label
        return "%s %d%%%s" % (label, pct, " (%s)" % fmt(reset) if reset else "")
    parts = [
        item.get("account") or "hesap bilinmiyor",
        window("5-hour limit", item.get("fivePct"), item.get("fiveReset"), lambda e: tr_datetime(e)[11:]),
        window("Weekly", item.get("weekPct"), item.get("weekReset"), tr_datetime),
    ]
    if item.get("measuredAt"):
        parts.append("ölçüm %s" % tr_datetime(item["measuredAt"]))
    return " · ".join(parts)


# ---------------------------------------------------------------- text


def tr_datetime(epoch):
    """Turkey time as "YYYY-MM-DD HH:MM"."""
    moment = datetime.datetime.fromtimestamp(int(epoch) + TR_OFFSET, datetime.timezone.utc)
    return moment.strftime("%Y-%m-%d %H:%M")


def tr_time(epoch):
    moment = datetime.datetime.fromtimestamp(int(epoch) + TR_OFFSET, datetime.timezone.utc)
    return moment.strftime("%m-%d %H:%M")


def duration(seconds):
    """A duration in Turkish: "40 dk", "2 sa 10 dk", "3 gün 4 sa"."""
    minutes = int(seconds // 60)
    if minutes < 60:
        return "%d dk" % minutes
    hours, minutes = divmod(minutes, 60)
    if hours < 24:
        return "%d sa %d dk" % (hours, minutes) if minutes else "%d sa" % hours
    days, hours = divmod(hours, 24)
    return "%d gün %d sa" % (days, hours) if hours else "%d gün" % days


def warnings_of(session):
    """Warnings for one session with a handoff: an old handoff, a missing detail note."""
    handoff = session.get("handoff") or {}
    out = []
    gap = session.get("lastActivity", 0) - handoff.get("writtenAt", 0)
    if handoff.get("writtenAt") and gap > STALE_AFTER:
        out.append("⚠ nottan sonra %s daha çalıştı" % duration(gap))
    if not (handoff.get("detail") or {}).get("exists"):
        out.append("⚠ detay notu yok")
    return out


def fence(text):
    """A text code block whose fence is longer than any backtick run in the text."""
    longest = max([len(run) for run in re.findall(r"`+", text)] or [0])
    mark = "`" * max(3, longest + 1)
    return "%stext\n%s\n%s" % (mark, text, mark)


def handoff_rows(machines):
    """(machine name, session) for every session with a handoff, newest handoff first,
    the number of sessions without one, and the machine errors."""
    rows, without, errors = [], 0, []
    for machine in machines:
        if not machine.get("ok"):
            errors.append("%s: %s" % (machine.get("name"), machine.get("error") or "bilinmiyor"))
            continue
        for session in machine.get("sessions") or []:
            if (session.get("handoff") or {}).get("path"):
                rows.append((machine.get("name"), session))
            else:
                without += 1
    rows.sort(key=lambda row: row[1]["handoff"].get("writtenAt", 0), reverse=True)
    return rows, without, errors


def render_text(machines, notes, days, generated=None, usage=None):
    """Markdown for the slash command: the usage of each account, then one block per session with a handoff."""
    rows, without, errors = handoff_rows(machines)
    out = [
        "Oturumlar · %s TR · son %d gün · devir notu olan %d oturum · saatler TR"
        % (tr_datetime(generated or time.time()), days, len(rows)),
        "",
    ]
    if usage:
        now = time.time()
        out.append("Kullanım (son ölçüm, hesap başına):")
        out.extend("- " + usage_line(item, now) for item in usage)
        out.append("")
    for number, (name, session) in enumerate(rows[:MAX_TEXT], 1):
        handoff = session["handoff"]
        title = session.get("title") or str(session.get("sessionId", ""))[:8]
        # A blank line between sessions, no separator line (easier on the eyes).
        if number > 1:
            out.append("")
        out.append(
            "**%d. %s** · %s · %s · %s"
            % (number, title, name, session.get("account") or "hesap bilinmiyor", tr_datetime(handoff["writtenAt"]))
        )
        if session.get("folder"):
            out.append("Klasör: `%s`" % session["folder"])
        out.extend(warnings_of(session))
        # The prompt holds the handoff path: no separate path block.
        out.append(fence(handoff.get("prompt") or handoff_prompt(handoff["path"])))
    if rows:
        out.append("")
    else:
        out.append("Son %d günde devir notu olan oturum yok." % days)
    if len(rows) > MAX_TEXT:
        out.append("%d oturum daha var. Tamamı yan panelde." % (len(rows) - MAX_TEXT))
    if without:
        out.append("Devir notu olmayan %d oturum gösterilmedi." % without)
    for error in errors:
        out.append("Hata: %s" % error)
    for note in notes:
        out.append("Not: %s" % note)
    return "\n".join(out).rstrip() + "\n"


# ---------------------------------------------------------------- main


def main(argv=None):
    parser = argparse.ArgumentParser(description="List Claude sessions and handoff metadata.")
    parser.add_argument("--json", action="store_true", help="print JSON (default)")
    parser.add_argument("--text", action="store_true", help="print Markdown tables")
    parser.add_argument("--all", action="store_true", help="include the machines in local/machines.md")
    parser.add_argument("--days", type=int, default=DEFAULT_DAYS)
    args = parser.parse_args(argv)
    days = max(1, args.days)

    if args.all:
        data = collect_all(days)
    else:
        local = collect_local(days)
        if not args.text:
            print(json.dumps(local, ensure_ascii=False))
            return 0
        data = {
            "generated": local["generated"],
            "machines": [
                {
                    "name": local_name(local["host"]),
                    "host": local["host"],
                    "ok": True,
                    "error": None,
                    "sessions": local["sessions"],
                }
            ],
            "notes": [],
        }
    names = load_accounts(repo_dir(config_dir()))
    add_accounts(data["machines"], names)
    data["usage"] = usage_summary(config_dir(), names)
    text = render_text(data["machines"], data["notes"], days, data.get("generated"), data["usage"])
    if args.text:
        sys.stdout.write(text)
    else:
        # The mod shows this text for the slash command and draws the pane from the rest.
        data["text"] = text
        print(json.dumps(data, ensure_ascii=False))
    return 0


if __name__ == "__main__":
    try:
        sys.exit(main())
    except SystemExit:
        raise
    except Exception as error:  # last resort: still exit 0 with valid JSON
        print(json.dumps({"host": short_host(), "generated": 0, "sessions": [], "error": str(error)}))
        sys.exit(0)
