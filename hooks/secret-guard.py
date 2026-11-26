#!/usr/bin/env python3
"""PreToolUse guard: keep secret file contents and process environments out of agent transcripts.

Blocks Bash commands that name a secret path (unless the verb only touches metadata or uses the
file without printing it) or that dump an environment. Blocks Read/Grep/Glob on secret paths as a
second layer behind permissions.deny. Pattern list only: a script that opens a secret path itself
is not caught.

A block gives Claude one command for the user. The user runs it in a terminal outside Claude and
sees the secret there. The secret never reaches the transcript.

The built-in list holds only common secret paths. Secret paths of one machine (company services,
private tools) go in <this directory>/secret-guard.local.json, which is not in the repo. Format:
{"paths": [{"name": "etc-myapp", "regex": "/etc/myapp(/|\\b)"}]}. A broken file or entry is
skipped and logged as rule "local-config-error". The built-in rules still apply.
"secret-guard.py --check-local [FILE]" checks the local file and prints each problem. It writes
nothing. Exit 0 when the file is missing or valid, 1 when it has a problem. The installer runs it.

The log is <this directory>/state/secret-guard.log. It records the time, tool and rule name only,
never the command. secret-guard-codex.py loads this file and uses the same rules for Codex.
Source: the hooks/ folder of the ai_agent_rules repo. Install with install.sh.
"""
import json
import os
import re
import shlex
import sys
import time

HOME = os.path.expanduser("~")
HOOKS_DIR = os.path.dirname(os.path.abspath(__file__))
LOG = os.path.join(HOOKS_DIR, "state", "secret-guard.log")
LOCAL_FILE = os.path.join(HOOKS_DIR, "secret-guard.local.json")
RULE_NAME_RX = re.compile(r"^[a-z][a-z0-9-]*$")
# The Grep command for the user has this text in place of the search pattern. The pattern can be
# the sensitive value itself, so the deny reason does not repeat it.
SEARCH_PLACEHOLDER = "<search text>"


def log(tool, rule):
    try:
        os.makedirs(os.path.dirname(LOG), exist_ok=True)
        with open(LOG, "a") as f:
            f.write(f"{time.strftime('%Y-%m-%dT%H:%M:%S')}\t{tool}\t{rule}\n")
    except OSError:
        pass


# Common secret paths. Machine-specific paths go in the local file (see load_local_paths).
SECRET_PATHS = [
    ("pgpass", r"\.pgpass"),
    ("hcloud", r"/\.hcloud(/|\b)"),
    ("gh-config", r"/\.config/gh(/|\b)"),
    ("ssh", r"/\.ssh(/|\b)"),
    ("aws", r"/\.aws(/|\b)"),
    ("claude-json", r"/\.claude\.json\b"),
    ("agent-credentials", r"/\.claude/\.credentials\.json\b"),
    ("codex-auth", r"/\.codex/auth\.json\b"),
    ("dotenv", r"(^|[\s/'\"=:])\.env(\.(?!example|sample|template|dist)[\w-]+)?(?=$|[\s'\"`;|&)<>])"),
]


def parse_local_paths(path):
    """Return (rules, problems) for the local file. A missing file gives ([], []).

    rules holds the compiled (name, regex) pairs of the valid entries. problems holds one short
    text for the file when it cannot be read or parsed, else one text for each bad entry. A text
    names the entry by its number and name, never by its regex.
    """
    if not os.path.exists(path):
        return [], []
    try:
        with open(path, encoding="utf-8") as f:
            entries = json.load(f)["paths"]
        if not isinstance(entries, list):
            raise ValueError("paths is not a list")
    except OSError as e:
        return [], ["the file cannot be read ({})".format(e.strerror or type(e).__name__)]
    except (ValueError, KeyError, TypeError, RecursionError):
        return [], ['the file is not JSON of the form {"paths": [{"name": ..., "regex": ...}]}']
    rules, problems = [], []
    for number, entry in enumerate(entries, 1):
        label = "entry {}".format(number)
        try:
            name, regex = entry["name"], entry["regex"]
            if isinstance(name, str):
                label = "entry {} ({})".format(number, name[:40])
            if not isinstance(name, str) or not RULE_NAME_RX.match(name):
                raise ValueError("the name must match [a-z][a-z0-9-]*")
            if not isinstance(regex, str):
                raise ValueError("the regex is not a string")
            rules.append((name, re.compile(regex)))
        except re.error as e:
            problems.append("{}: the regex does not compile ({})".format(label, e.msg))
        except (OverflowError, RecursionError):
            # A loaded hook must not crash on import: with "onFailure": "block" a crash blocks every call.
            problems.append("{}: the regex does not compile (a repeat count is too large or it is nested too deep)".format(label))
        except ValueError as e:
            problems.append("{}: {}".format(label, e))
        except (KeyError, TypeError):
            problems.append('{}: not an object with "name" and "regex"'.format(label))
    return rules, problems


def load_local_paths(path):
    """Return the compiled (name, regex) pairs of the local file. A missing file gives [].

    A file that cannot be read or parsed, and each entry with a bad name or regex, is skipped.
    Each skip writes one log line with the rule "local-config-error".
    """
    rules, problems = parse_local_paths(path)
    for _ in problems:
        log("config", "local-config-error")
    return rules


# "--check-local" only reads the local file, so it must not write log lines while loading.
CHECK_LOCAL_ONLY = __name__ == "__main__" and sys.argv[1:2] == ["--check-local"]
SECRET_RX = [(n, re.compile(p)) for n, p in SECRET_PATHS] + ([] if CHECK_LOCAL_ONLY else load_local_paths(LOCAL_FILE))

# Verbs that touch only metadata, or use a secret without printing it.
SAFE_VERBS = {
    "ls", "stat", "chmod", "chown", "chgrp", "test", "[", "[[", "file", "du", "wc",
    "sha256sum", "sha1sum", "md5sum", "ssh", "scp", "sftp", "ssh-keygen", "ssh-add",
    "source", ".", "mkdir", "touch", "realpath", "readlink", "dirname", "basename",
}
# Wrapper -> its flags that take a separate value.
WRAPPERS = {
    "sudo": {"-u", "-g", "-C", "-D", "-h", "-p", "-r", "-t", "-U"}, "doas": {"-u", "-C"},
    "nice": {"-n"}, "ionice": {"-c", "-n", "-p"}, "nohup": set(), "time": set(), "command": set(),
    "builtin": set(), "exec": set(), "stdbuf": set(),
}
# ssh-family flags whose value is a local file the tool uses without printing.
SSH_FILE_FLAGS = {"-i", "-F", "-o"}
# Env assignments that point a tool at a secret file without printing it.
SAFE_PATH_VARS = {"PGPASSFILE", "AWS_CONFIG_FILE", "AWS_SHARED_CREDENTIALS_FILE", "GIT_SSH_COMMAND"}

SPLIT_RX = re.compile(r"\|\||&&|[;&|\n`]|\$\(|<\(|>\(|[(){}]")
ASSIGN_RX = re.compile(r"^([A-Za-z_][A-Za-z0-9_]*)=")
GLOB_CHARS_RX = re.compile(r"[*?\[{]")


def normalize(cmd):
    cmd = cmd.replace("${HOME}", HOME).replace("$HOME", HOME)
    return re.sub(r"(^|[\s'\"=:])~(?=/)", lambda m: m.group(1) + HOME, cmd)


def words(segment):
    try:
        return shlex.split(segment, posix=True)
    except ValueError:
        return segment.split()


def strip_prefix(ws, strip_env):
    """Drop wrappers and leading assignments; return (verb_index, safe_assignments).

    With strip_env, `env [opts] [NAME=val]... cmd` is a wrapper too. Without it, `env` stays the
    verb so a bare `env` can be seen as an environment dump.
    """
    i, dropped = 0, []
    while i < len(ws):
        w = ws[i]
        m = ASSIGN_RX.match(w)
        if m:
            if m.group(1) in SAFE_PATH_VARS:
                dropped.append(w)
            i += 1
        elif w in WRAPPERS:
            i += 1
            while i < len(ws) and ws[i].startswith("-"):
                i += 2 if ws[i] in WRAPPERS[w] else 1
        elif w == "env" and strip_env:
            i += 1
            while i < len(ws) and ws[i].startswith("-"):
                i += 2 if ws[i] in ("-u", "--unset", "-C", "--chdir") else 1
        elif w == "timeout":
            i += 1
            while i < len(ws) and (ws[i].startswith("-") or re.match(r"^\d", ws[i])):
                i += 1
        else:
            break
    return i, dropped


def env_dump(ws, i):
    if i >= len(ws):
        return None
    verb, rest = os.path.basename(ws[i]), ws[i + 1:]
    if verb == "printenv":
        return "printenv"
    if verb == "env":
        j = 0
        while j < len(rest):
            if rest[j] in ("-u", "--unset", "-C", "--chdir", "-S", "--split-string"):
                j += 2
            elif rest[j].startswith("-") or ASSIGN_RX.match(rest[j]):
                j += 1
            else:
                return None
        return "bare-env"
    if verb in ("export", "declare", "typeset") and all(a.startswith("-") for a in rest) and (not rest or any("p" in a or "x" in a for a in rest)):
        return "export-dump"
    if verb == "set" and not rest:
        return "set-dump"
    if verb == "ps" and rest and re.fullmatch(r"[a-zA-Z]+", rest[0]) and "e" in rest[0]:
        return "ps-environ"
    if verb == "systemctl" and "show" in rest and any("Environment" in a for a in rest):
        return "systemctl-environment"
    if verb in ("docker", "kubectl", "podman") and "exec" in rest and rest and rest[-1] in ("env", "printenv"):
        return "container-env"
    return None


def bash_hit(cmd, cwd=None):
    """Return (rule, kept words, verb index, cwd, all words) of the first blocked segment, or None.

    The verb index points into all words. Kept words leave out the words that only point a tool
    at a file (KEY=path assignments, ssh -i/-F/-o values). Both word lists are empty for
    proc-environ. cwd follows plain `cd DIR` segments before the blocked one. It becomes None
    (unknown) after any other directory change, or when the command has a subshell.
    """
    text = normalize(cmd)
    if "/proc/" in text and "environ" in text:
        return "proc-environ", [], 0, cwd, []
    cwd = cwd or None
    subshell = "(" in text or "`" in text
    for seg in SPLIT_RX.split(text):
        if not seg.strip():
            continue
        ws = words(seg)
        i0 = strip_prefix(ws, strip_env=False)[0]
        hit = env_dump(ws, i0)
        if hit:
            return hit, ws, i0, cwd, ws
        i, safe_assign = strip_prefix(ws, strip_env=True)
        verb = os.path.basename(ws[i]) if i < len(ws) else ""
        kept = [w for w in ws if w not in safe_assign]
        if verb in ("ssh", "scp", "sftp"):
            # A key or config path is used, not printed. A remote command naming a secret path is not safe.
            kept = [w for j, w in enumerate(kept) if not (j and kept[j - 1] in SSH_FILE_FLAGS)
                    and not re.match(r"^-[iFo].", w)]
        names = [n for n, rx in SECRET_RX if rx.search(" ".join(kept))]
        blocked = bool(names)
        if verb in SAFE_VERBS and verb not in ("ssh", "scp", "sftp"):
            blocked = False
        if verb == "find" and not any(w in ("-exec", "-execdir", "-ok", "-okdir") for w in ws):
            blocked = False
        if blocked:
            return names[0], kept, i, cwd, ws
        if verb in ("cd", "pushd", "popd"):
            cwd = next_cwd(ws[i + 1:], cwd) if verb == "cd" and not subshell else None
    return None


def next_cwd(args, cwd):
    """The directory after `cd ARGS`, or None when it is not known."""
    if not args or args == ["~"]:
        return HOME
    if len(args) != 1 or args[0].startswith("-"):
        return None
    if os.path.isabs(args[0]):
        return args[0]
    return os.path.join(cwd, args[0]) if cwd else None


def check_bash(cmd):
    hit = bash_hit(cmd)
    return hit[0] if hit else None


def check_path_tool(tool, inp):
    # Grep's `pattern` is the content regex, not a path, so it is not checked.
    keys = ("path", "glob") if tool == "Grep" else ("file_path", "path", "pattern", "notebook_path")
    text = normalize(" ".join(str(inp.get(k, "")) for k in keys))
    for n, rx in SECRET_RX:
        if rx.search(text):
            return n
    if "/proc/" in text and "environ" in text:
        return "proc-environ"
    return None


# A path or host that a remote shell reads as one plain word.
REMOTE_WORD_RX = re.compile(r"^[A-Za-z0-9_@%+=:,./~-]+$")
HOST_RX = re.compile(r"^[A-Za-z0-9][A-Za-z0-9_.@-]*$")
# Verbs whose secret path is usually a directory: the user gets `ls -la` for them.
DIR_VERBS = {"cd", "pushd", "find", "ls", "du", "tree"}


def quote_path(path):
    """Quote a local path for the shell. A leading "~/" stays outside the quotes, so the shell expands it."""
    if path == "~":
        return path
    if path.startswith("~/"):
        rest = path[2:]
        return "~/" + shlex.quote(rest) if rest else "~/"
    return shlex.quote(path)


def home_form(path):
    """Write a path below HOME as "~/...". The user's shell expands it again."""
    if path == HOME:
        return "~"
    if path.startswith(HOME + "/"):
        return "~" + path[len(HOME):]
    return path


def local_path(path, cwd):
    """Return the path in "~/" or absolute form, or None when it is relative and cwd is not known."""
    if path in ("~",) or path.startswith("~/"):
        return path
    if os.path.isabs(path):
        return home_form(path)
    if not cwd:
        return None
    return home_form(cwd if path in ("", ".") else os.path.join(cwd, path))


def glob_base(pattern, path):
    """Return the directory part of a Glob call that has no wildcard. It can be relative."""
    match = GLOB_CHARS_RX.search(pattern)
    static = pattern[:match.start()] if match else pattern
    static = os.path.dirname(static) if match or not static.endswith("/") else static.rstrip("/")
    if os.path.isabs(static) or static == "~" or static.startswith("~/"):
        return static or "/"
    if not static:
        return path
    return os.path.join(path, static) if path else static


def secret_word(ws, rule):
    """Return the first word that names the secret path of the rule, without a prefix like KEY= or @.

    An option word with an attached value (-Ffile) is skipped: its path cannot be cut out safely.
    """
    rx = dict(SECRET_RX).get(rule)
    if rx is None:
        return None
    for w in ws:
        cand = w
        if ASSIGN_RX.match(cand) or (cand.startswith("-") and "=" in cand):
            cand = cand.split("=", 1)[1]
        elif cand.startswith("-"):
            continue
        # A word from a broken quote can keep a quote character at either end.
        cand = cand.lstrip("@<>").strip("\"'")
        if cand and rx.search(cand):
            return trim_trailing(cand, rx)
    return None


# Punctuation that prose or a list leaves after a path: "~/.ssh," or "~/.ssh/config."
TRAILING_PUNCT = ",;:!?)]}>"


def trim_trailing(path, rx):
    """Remove trailing punctuation from a path. A "." stays when it ends "." or ".." after a slash.

    The original path comes back when the trimmed one no longer matches the rule.
    """
    out = path
    while out:
        if out[-1] in TRAILING_PUNCT:
            out = out[:-1]
        elif out[-1] == "." and len(out) > 1 and out[-2] not in "./":
            out = out[:-1]
        else:
            break
    return out if out and rx.search(out) else path


def remote_read_command(host, path, sudo, opts=()):
    """`ssh [opts] host [sudo] cat -- path`, or "" when the host or path is not one plain word.

    ssh joins its arguments and the remote shell parses them again. So the remote path must
    be a plain word: no space, redirect, quote or other shell character.
    """
    path = home_form(path)
    if not HOST_RX.match(host) or not REMOTE_WORD_RX.match(path):
        return ""
    # Quoted, so the local shell keeps "~" and the remote shell expands it to the remote home.
    return " ".join(["ssh"] + list(opts) + [host] + (["sudo"] if sudo else []) + ["cat", "--", shlex.quote(path)])


def ssh_read_command(ws, i, rule):
    """For `ssh [opts] host remote-command`: a command that prints the remote secret file.

    Only -p, -l and -i are kept. Other options can run a local command (-F, -o ProxyCommand)
    or route through another host (-J).
    """
    keep_flags = {"-p", "-l", "-i"}
    value_flags = set("-" + c for c in "BbcDEeFIiJLlmOoPpQRSWw")
    opts, j = [], i + 1
    while j < len(ws) and ws[j].startswith("-"):
        if ws[j] == "--":
            j += 1
            break
        if len(ws[j]) > 2 and ws[j] not in value_flags and "-" + ws[j][-1] in value_flags:
            # A bundle like -tp ends with a value flag: its value is the next word. Not parsed.
            return ""
        if ws[j] in value_flags and j + 1 < len(ws):
            if ws[j] in keep_flags:
                value = home_form(ws[j + 1])
                if not REMOTE_WORD_RX.match(value):
                    return ""
                opts += [ws[j], quote_path(value)]
            j += 2
        else:
            j += 1
    if j >= len(ws):
        return ""
    host = ws[j]
    # The remote shell splits the remote command again, so split it here too.
    remote = [t for w in ws[j + 1:] for t in words(w)]
    path = secret_word(remote, rule)
    if not path:
        return ""
    return remote_read_command(host, path, "sudo" in remote, opts)


def container_env_command(ws, i):
    """For `docker|podman|kubectl [compose] exec ... env`: the same exec with env as the only command."""
    verb = os.path.basename(ws[i])
    try:
        k = ws.index("exec", i + 1)
    except ValueError:
        return ""
    middle = ws[i + 1:k]
    if middle not in ([], ["compose"]):
        return ""
    value_flags = {"-u", "-w", "-e", "-n", "-c", "--user", "--workdir", "--env", "--namespace", "--container"}
    keep = {"-n", "-c", "--namespace", "--container"} if verb == "kubectl" else set()
    rest = ws[k + 1:]
    opts, j = [], 0
    while j < len(rest) and rest[j].startswith("-"):
        if rest[j] in value_flags and j + 1 < len(rest):
            if rest[j] in keep:
                opts += [rest[j], shlex.quote(rest[j + 1])]
            j += 2
        else:
            j += 1
    if j >= len(rest) or rest[j] == "--":
        return ""
    sep = ["--"] if verb == "kubectl" else []
    return " ".join([verb] + middle + ["exec"] + opts + [shlex.quote(rest[j])] + sep + ["env"])


def bash_user_command(cmd, cwd=None):
    """Return a read-only command that shows the user the secret of a blocked Bash call.

    The command is built from the secret path or the rule, never copied from the blocked
    command: a blocked command can come from a prompt injection and must not reach the user.
    Returns "" when no safe command can be built. Nothing here touches the file system.
    """
    hit = bash_hit(cmd, cwd)
    if not hit:
        return ""
    rule, kept, i, cwd, ws = hit
    if rule == "proc-environ":
        m = re.search(r"/proc/[0-9a-z]+/environ\b", normalize(cmd))
        return "tr '\\0' '\\n' < " + m.group(0) if m else ""
    if rule in ("bare-env", "export-dump", "set-dump"):
        return "printenv"
    if rule == "printenv":
        names = [w for w in ws[i + 1:] if re.fullmatch(r"[A-Za-z_][A-Za-z0-9_]*", w)]
        return " ".join(["printenv"] + names[:1])
    if rule == "ps-environ":
        return "ps eww"
    if rule == "systemctl-environment":
        units = [w for w in ws[ws.index("show") + 1:] if not w.startswith("-") and "Environment" not in w]
        user = ["--user"] if "--user" in ws else []
        return " ".join(["systemctl"] + user + ["show", shlex.quote(units[0]), "-p", "Environment"]) if units else ""
    if rule == "container-env":
        return container_env_command(ws, i)
    verb = os.path.basename(ws[i]) if i < len(ws) else ""
    sudo = "sudo" in ws[:i]
    if verb == "ssh":
        return ssh_read_command(ws, i, rule)
    rx = dict(SECRET_RX).get(rule)
    for w in kept:
        # scp/rsync form host:/path names a remote file.
        m = re.match(r"^([^:/\s]+):(/(?!/).*)$", w)
        if rx and m and rx.search(m.group(2)):
            return remote_read_command(m.group(1), m.group(2), False)
    path = secret_word(kept, rule)
    path = local_path(path, cwd) if path else None
    if not path:
        return ""
    as_dir = verb in DIR_VERBS or path.endswith("/")
    return "{}{} {}".format("sudo " if sudo else "", "ls -la --" if as_dir else "cat --", quote_path(path))


def user_command(tool, inp, cwd=None):
    """Return one read-only shell command that shows the user what the blocked call would show."""
    if tool == "Bash":
        return bash_user_command(str(inp.get("command", "")), cwd)
    if tool in ("Read", "NotebookRead"):
        raw = str(inp.get("file_path") or inp.get("notebook_path") or inp.get("path") or "")
        path = local_path(raw, cwd) if raw else None
        return "cat -- " + quote_path(path) if path else ""
    if tool == "Grep":
        path = local_path(str(inp.get("path") or ""), cwd)
        if not path:
            return ""
        cmd = "grep -rn"
        if inp.get("glob"):
            cmd += " --include=" + shlex.quote(str(inp["glob"]))
        return "{} -e {} -- {}".format(cmd, shlex.quote(SEARCH_PLACEHOLDER), quote_path(path))
    if tool == "Glob":
        path = local_path(glob_base(str(inp.get("pattern", "")), str(inp.get("path") or "")), cwd)
        return "ls -la -- " + quote_path(path) if path else ""
    return ""


def safe_user_command(tool, inp, cwd=None):
    """user_command that never raises. A failure gives no command; the block stays."""
    try:
        return user_command(tool, inp, cwd)
    except Exception:
        return ""


def deny_reason(rule, command):
    reason = ("secret-guard: blocked ({}). The output would put secret file contents or a process "
              "environment into the transcript. Do not look for another way to read it. When metadata, a "
              "masked value or a fingerprint is enough, use a command that prints only that.").format(rule)
    if command:
        reason += ("\nIf the user needs to see it, give them this command in a fenced bash code block. "
                   "Tell them to run it in a terminal outside Claude: not with \"!\" in Claude and not in "
                   "a terminal that Claude can read. Do not run it yourself.")
        if shlex.quote(SEARCH_PLACEHOLDER) in command:
            reason += (" The command has {} in place of the search pattern. Do not fill it in. Tell the user "
                       "to type their search text there.").format(shlex.quote(SEARCH_PLACEHOLDER))
        reason += "\n" + command
    else:
        reason += ("\nIf the user needs to see it, tell them which file or variable it is. They can look "
                   "at it in a terminal outside Claude.")
    return reason


def check_local(argv):
    """--check-local [FILE]: print the state of the local file. Exit 0 when it is missing or valid."""
    if len(argv) > 1:
        print("usage: secret-guard.py --check-local [FILE]", file=sys.stderr)
        return 2
    path = argv[0] if argv else LOCAL_FILE
    if not os.path.exists(path):
        print("missing: {} (optional; only the built-in rules apply)".format(path))
        return 0
    rules, problems = parse_local_paths(path)
    if not problems:
        print("ok: {} ({} local rules)".format(path, len(rules)))
        return 0
    print("PROBLEM: {} ({} local rules apply, {} problems)".format(path, len(rules), len(problems)))
    for problem in problems:
        print("  " + problem)
    print("  The hook skips what is broken and logs it as local-config-error. Fix the file.")
    return 1


def main():
    if sys.argv[1:2] == ["--check-local"]:
        return check_local(sys.argv[2:])
    data = json.load(sys.stdin)
    tool, inp = data.get("tool_name", ""), data.get("tool_input") or {}
    if tool == "Bash":
        rule = check_bash(inp.get("command", ""))
    elif tool in ("Read", "Grep", "Glob", "NotebookRead"):
        rule = check_path_tool(tool, inp)
    else:
        rule = None
    if not rule:
        return
    log(tool, rule)
    command = safe_user_command(tool, inp, str(data.get("cwd") or "") or None)
    print(json.dumps({"hookSpecificOutput": {"hookEventName": "PreToolUse",
                                             "permissionDecision": "deny",
                                             "permissionDecisionReason": deny_reason(rule, command)}}))


if __name__ == "__main__":
    sys.exit(main())
