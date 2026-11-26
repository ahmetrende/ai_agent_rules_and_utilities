#!/usr/bin/env python3
"""Write a Markdown dump of a Claude Code session transcript.

The dump is the third file of a handoff (see docs/handoff_and_limit_hooks.md). A hook
runs this script, never the model. It holds the git state, the memory folder and the
main-thread conversation, so that a fresh session on another account, or Codex (which
loads no memory), can find any detail that the handoff and the detail note lack.

usage: handoff-dump.py --transcript T --out X --session SID [--project P] [--title TITLE]
                       [--config CFG] [--max-field 4000]

Python 3 standard library only. The transcript is read line by line (it can be tens of
MB). Malformed lines are skipped. The output is written to a temp file and moved with
os.replace, with mode 600. Exit 0 on success, 1 with a message on stderr on error.
"""

import argparse
import calendar
import datetime
import json
import os
import re
import subprocess
import sys
import time

TR_OFFSET = 3 * 3600  # Turkey keeps UTC+3 all year
SYSTEM_PREFIXES = ("<task-notification>", "<system-reminder>", "<agent-message")
GIT_TIMEOUT_S = 10
STATUS_MAX_LINES = 100


def parse_ts(value):
    """ISO timestamp ("2026-11-23T10:00:00.512Z") to epoch seconds, or None."""
    if not isinstance(value, str) or len(value) < 19:
        return None
    try:
        dt = datetime.datetime.strptime(value[:19], "%Y-%m-%dT%H:%M:%S")
    except ValueError:
        return None
    return calendar.timegm(dt.timetuple())


def hhmm(epoch):
    if epoch is None:
        return "--:--"
    return time.strftime("%H:%M", time.gmtime(epoch + TR_OFFSET))


def stamp(epoch):
    return time.strftime("%Y-%m-%d %H:%M", time.gmtime(epoch + TR_OFFSET)) + " TR"


def cut(text, limit):
    if limit <= 0 or len(text) <= limit:
        return text
    return "%s\n[... %d karakter daha var, kesildi. Tamamı transcript dosyasında.]" % (
        text[:limit], len(text) - limit)


def fenced(text, lang=""):
    """Text in a code fence that is longer than any backtick run inside the text."""
    longest = max([len(r) for r in re.findall(r"`+", text)] + [2])
    fence = "`" * (longest + 1)
    return "%s%s\n%s\n%s\n" % (fence, lang, text.rstrip("\n"), fence)


def slug(path):
    return re.sub(r"[^A-Za-z0-9]", "-", path)


def run_git(project, args):
    """Run git in the project. Returns (ok, text). Never raises."""
    env = dict(os.environ)
    env["GIT_OPTIONAL_LOCKS"] = "0"
    try:
        res = subprocess.run(["git", "-C", project] + args, stdout=subprocess.PIPE,
                             stderr=subprocess.PIPE, timeout=GIT_TIMEOUT_S, env=env)
    except (OSError, subprocess.SubprocessError) as exc:
        return False, str(exc)
    text = res.stdout.decode("utf-8", "replace").strip("\n")
    if res.returncode != 0:
        return False, (res.stderr.decode("utf-8", "replace").strip() or "git hata verdi")
    return True, text


def in_git_work_tree(project):
    if not project or not os.path.isdir(project):
        return False
    ok, text = run_git(project, ["rev-parse", "--is-inside-work-tree"])
    return ok and text.strip() == "true"


def main_repo_root(project):
    """Parent of the common git dir (the main checkout of a worktree), else the project."""
    ok, text = run_git(project, ["rev-parse", "--path-format=absolute", "--git-common-dir"])
    if ok and text.strip():
        common = text.strip().splitlines()[0]
        if not os.path.isabs(common):
            common = os.path.join(project, common)
        return os.path.dirname(os.path.normpath(common))
    return project


def git_section(project):
    if not in_git_work_tree(project):
        return ""
    out = ["## Git durumu", ""]
    ok, text = run_git(project, ["rev-parse", "--abbrev-ref", "HEAD"])
    out.append("Dal: %s" % (text if ok else "(alınamadı: %s)" % text))
    ok, text = run_git(project, ["rev-parse", "--short", "HEAD"])
    out.append("HEAD: %s" % (text if ok else "(alınamadı: %s)" % text))
    out.append("")
    # --porcelain: paths relative to the repo root, also when the project is a subfolder.
    out.append("### git status --porcelain")
    ok, text = run_git(project, ["status", "--porcelain"])
    if not ok:
        out.append("(alınamadı: %s)" % text)
    else:
        rows = text.splitlines()
        body = "\n".join(rows[:STATUS_MAX_LINES]) if rows else "(temiz)"
        if len(rows) > STATUS_MAX_LINES:
            body += "\n[... %d satır daha var]" % (len(rows) - STATUS_MAX_LINES)
        out.append(fenced(body).rstrip("\n"))
    out.append("")
    out.append("### git log --oneline -15")
    ok, text = run_git(project, ["log", "--oneline", "-15"])
    if not ok:
        out.append("(alınamadı: %s)" % text)
    else:
        out.append(fenced(text if text else "(commit yok)").rstrip("\n"))
    out.append("")
    return "\n".join(out) + "\n"


def read_text(path):
    with open(path, "r", encoding="utf-8", errors="replace") as handle:
        return handle.read()


def find_memory_dir(cfg, project, transcript):
    """The memory folder: the main repo root's first, then the project's, then the
    transcript's. The project path is tried as given, absolute and physical, because
    Claude Code names the folder after the path as it knows it."""
    candidates = []
    if project:
        absolute = os.path.abspath(project)
        for path in (main_repo_root(absolute), project, absolute, os.path.realpath(absolute)):
            cand = os.path.join(cfg, "projects", slug(path), "memory")
            if cand not in candidates:
                candidates.append(cand)
    candidates.append(os.path.join(os.path.dirname(os.path.abspath(transcript)), "memory"))
    for cand in candidates:
        if os.path.isdir(cand):
            return cand
    return ""


def memory_section(cfg, project, transcript, first_ts):
    mdir = find_memory_dir(cfg, project, transcript)
    out = ["## Memory", ""]
    if not mdir:
        out.append("Memory klasörü bulunamadı.")
        out.append("")
        return "\n".join(out) + "\n"
    out.append("Memory klasörü: %s" % mdir)
    out.append("")
    try:
        names = sorted(n for n in os.listdir(mdir) if n.endswith(".md"))
    except OSError as exc:
        out.append("(klasör okunamadı: %s)" % exc)
        out.append("")
        return "\n".join(out) + "\n"
    if "MEMORY.md" in names:
        out.append("### MEMORY.md")
        try:
            out.append(fenced(read_text(os.path.join(mdir, "MEMORY.md"))).rstrip("\n"))
        except OSError as exc:
            out.append("(okunamadı: %s)" % exc)
        out.append("")
    others = [n for n in names if n != "MEMORY.md"]
    changed = []
    plain = []
    for name in others:
        try:
            mtime = os.stat(os.path.join(mdir, name)).st_mtime
        except OSError:
            plain.append(name)
            continue
        if first_ts is not None and mtime >= first_ts:
            changed.append(name)
        else:
            plain.append(name)
    out.append("### Bu oturumda değişen memory dosyaları")
    if not changed:
        out.append("Yok.")
    for name in changed:
        out.append("")
        out.append("#### %s" % name)
        try:
            out.append(fenced(read_text(os.path.join(mdir, name))).rstrip("\n"))
        except OSError as exc:
            out.append("(okunamadı: %s)" % exc)
    out.append("")
    out.append("### Diğer memory dosyaları (yalnız adlar)")
    if not plain:
        out.append("Yok.")
    for name in plain:
        out.append("- %s" % name)
    out.append("")
    return "\n".join(out) + "\n"


def iter_records(path):
    """Yield every JSON object of the transcript. Malformed lines are skipped."""
    with open(path, "r", encoding="utf-8", errors="replace") as handle:
        for line in handle:
            line = line.strip()
            if not line:
                continue
            try:
                rec = json.loads(line)
            except ValueError:
                continue
            if isinstance(rec, dict):
                yield rec


def first_timestamp(path):
    for rec in iter_records(path):
        ts = parse_ts(rec.get("timestamp"))
        if ts is not None:
            return ts
    return None


def blocks_of(content):
    if isinstance(content, str):
        return [{"type": "text", "text": content}]
    blocks = []
    if isinstance(content, list):
        for item in content:
            if isinstance(item, dict):
                blocks.append(item)
            elif isinstance(item, str):
                blocks.append({"type": "text", "text": item})
    return blocks


def result_text(content):
    if isinstance(content, str):
        return content
    parts = []
    if isinstance(content, list):
        for item in content:
            if isinstance(item, str):
                parts.append(item)
            elif isinstance(item, dict) and item.get("type") == "text":
                parts.append(str(item.get("text") or ""))
            elif isinstance(item, dict) and item.get("type") == "image":
                parts.append("[görsel]")
            else:
                parts.append(json.dumps(item, ensure_ascii=False))
    elif content is not None:
        parts.append(json.dumps(content, ensure_ascii=False))
    return "\n".join(parts)


class Writer(object):
    def __init__(self, handle, max_field):
        self.handle = handle
        self.max_field = max_field

    def line(self, text=""):
        self.handle.write(text + "\n")

    def heading(self, text):
        self.line()
        self.line("### " + text)
        self.line()

    def text_block(self, text, lang=""):
        self.handle.write(fenced(text, lang))


def write_record(rec, w):
    if rec.get("isSidechain") is True:
        return
    rtype = rec.get("type")
    when = hhmm(parse_ts(rec.get("timestamp")))
    maxf = w.max_field

    if rtype == "user":
        message = rec.get("message")
        content = message.get("content") if isinstance(message, dict) else None
        blocks = blocks_of(content)
        if rec.get("isCompactSummary") is True:
            text = "\n".join(str(b.get("text") or "") for b in blocks if b.get("type") == "text")
            w.heading("Compact özeti · %s TR" % when)
            w.text_block(cut(text, maxf))
            return
        results = [b for b in blocks if b.get("type") == "tool_result"]
        texts = [str(b.get("text") or "") for b in blocks if b.get("type") == "text"]
        images = len([b for b in blocks if b.get("type") == "image"])
        for res in results:
            label = "← Sonuç (hata)" if res.get("is_error") is True else "← Sonuç"
            w.line()
            w.line(label)
            w.line()
            w.text_block(cut(result_text(res.get("content")), maxf))
        text = "\n".join(texts)
        if text.strip():
            system = rec.get("isMeta") is True or bool(results) \
                or text.lstrip().startswith(SYSTEM_PREFIXES)
            if system:
                w.heading("Sistem/agent bildirimi · %s TR" % when)
                w.text_block(cut(text, maxf))
            else:
                w.heading("Kullanıcı · %s TR" % when)
                w.text_block(text)
        if images:
            w.line()
            w.line("[%d görsel eklendi]" % images)
        return

    if rtype == "assistant":
        message = rec.get("message")
        content = message.get("content") if isinstance(message, dict) else None
        for block in blocks_of(content):
            btype = block.get("type")
            if btype == "text":
                text = str(block.get("text") or "")
                if text.strip():
                    w.heading("Asistan · %s TR" % when)
                    w.text_block(text)
            elif btype == "thinking":
                text = str(block.get("thinking") or "")
                if text.strip():
                    w.line()
                    w.line("→ Düşünce · %s TR" % when)
                    w.line()
                    w.text_block(cut(text, maxf))
            elif btype == "tool_use":
                w.line()
                w.line("→ Araç: %s" % (block.get("name") or "?"))
                w.line()
                try:
                    body = json.dumps(block.get("input"), ensure_ascii=False, indent=2)
                except (TypeError, ValueError):
                    body = str(block.get("input"))
                w.text_block(cut(body, maxf), "json")
        return

    if rtype == "system" and rec.get("subtype") == "compact_boundary":
        text = str(rec.get("content") or "Compact sınırı")
        meta = rec.get("compactMetadata")
        if meta is not None:
            text += "\n" + json.dumps(meta, ensure_ascii=False)
        w.heading("Compact sınırı · %s TR" % when)
        w.text_block(cut(text, maxf))
        return

    if rtype == "attachment":
        att = rec.get("attachment")
        if not isinstance(att, dict):
            return
        atype = att.get("type")
        if atype == "queued_command":
            prompt = att.get("prompt")
            text = result_text(prompt) if not isinstance(prompt, str) else prompt
            w.heading("Kuyruktaki komut · %s TR" % when)
            w.text_block(cut(text, maxf))
        elif atype == "hook_system_message":
            w.heading("Hook mesajı · %s TR" % when)
            w.text_block(cut(result_text(att.get("content")), maxf))


def build(args):
    if not os.path.isfile(args.transcript):
        raise RuntimeError("transcript not found: %s" % args.transcript)
    cfg = args.config or os.environ.get("CLAUDE_CONFIG_DIR") or os.path.expanduser("~/.claude")
    # The project as given: shown as is and tried as is for the memory folder.
    project_given = args.project or ""
    project = os.path.abspath(project_given) if project_given else ""
    first_ts = first_timestamp(args.transcript)

    out_dir = os.path.dirname(os.path.abspath(args.out))
    if not os.path.isdir(out_dir):
        os.makedirs(out_dir, 0o700)
        os.chmod(out_dir, 0o700)
    tmp = "%s.tmp.%d" % (args.out, os.getpid())
    fd = os.open(tmp, os.O_WRONLY | os.O_CREAT | os.O_EXCL, 0o600)
    try:
        with os.fdopen(fd, "w", encoding="utf-8", errors="replace") as handle:
            w = Writer(handle, args.max_field)
            w.line("# %s — tam transcript dökümü" % (args.title or args.session))
            w.line()
            w.line("- Üretim zamanı: %s" % stamp(int(time.time())))
            w.line("- Oturum: %s" % args.session)
            w.line("- Transcript: %s" % args.transcript)
            w.line("- Proje: %s" % (project_given or "(verilmedi)"))
            w.line("- Not: Araç girdileri ve çıktıları, sistem bildirimleri ve düşünce blokları "
                   "%d karakterden uzunsa kesilir. Tam metin transcript dosyasındadır." % args.max_field)
            w.line()
            if project:
                git = git_section(project)
                if git:
                    handle.write(git + "\n")
            handle.write(memory_section(cfg, project_given, args.transcript, first_ts) + "\n")
            w.line("## Konuşma")
            for rec in iter_records(args.transcript):
                write_record(rec, w)
        os.replace(tmp, args.out)
    except BaseException:
        try:
            os.unlink(tmp)
        except OSError:
            pass
        raise


def main(argv):
    parser = argparse.ArgumentParser(description="Dump a Claude Code transcript as Markdown.")
    parser.add_argument("--transcript", required=True)
    parser.add_argument("--out", required=True)
    parser.add_argument("--session", required=True)
    parser.add_argument("--project", default="")
    parser.add_argument("--title", default="")
    parser.add_argument("--config", default="")
    parser.add_argument("--max-field", type=int, default=4000)
    try:
        args = parser.parse_args(argv)
    except SystemExit as exc:
        return 0 if exc.code in (0, None) else 1
    try:
        build(args)
    except Exception as exc:  # any failure is reported, never raised to the hook
        sys.stderr.write("handoff-dump: %s\n" % exc)
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
