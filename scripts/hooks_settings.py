#!/usr/bin/env python3
"""Merge the hook registrations of this repo into a Claude Code settings file.

Usage:
  hooks_settings.py --input FILE --output FILE --current-dir DIR
                    [--known-dir DIR ...] [--label NAME]
  hooks_settings.py --compare-plugins BEFORE AFTER

The script reads --input (a missing file counts as an empty settings file),
builds the merged settings and writes them to --output. It never changes
--input. install_hooks.sh compares the two files and replaces the live file.
--label is the file name to show in error messages (default: --input).

A hook command is "<dir>/hooks/<name>". --current-dir is the form to write,
for example "~/.claude". Each --known-dir is one more form that is also ours,
for example the old absolute form "/home/me/.claude". An entry is ours only
when its command is exactly one of these strings. An entry of another tool
with the same file name is never touched.

The shell runs the command. A path with a space or another special character
is written in single quotes. The "~/..." form is never quoted, because the
shell must expand the "~". For an absolute directory both the plain and the
quoted string are ours.

Rules:
  - Each script appears exactly one time in each of its events.
  - Each registration is a group of its own: type "command", timeout 5.
    secret-guard.py also has "onFailure": "block": when the guard cannot run,
    Claude Code blocks the tool call. Its timeout is 15: a slow process start
    (for example under endpoint security scanning) must not block calls.
  - A registration that is already correct is not touched.
  - All other hooks and all other keys stay as they are.

Output: one line for each registration, "<status> <event> <script>".
The status is "ok", "added" or "normalized". A line "extra <event> <script>"
reports one of our commands in an event that is not in the list below. The
script does not change such an entry. The last line is "result unchanged" or
"result changed". It compares the parsed settings, not the text, so a number
like 1.10 or 1e3 in another key never counts as a change.

Exit codes: 0 = merged, 2 = the input is not usable (nothing is written).

--compare-plugins compares two settings files as parsed JSON. It ignores
enabledPlugins."usage-feed@local-mods", enabledPlugins."oturum@local-mods" and
extraKnownMarketplaces."local-mods", the keys that the claude plugin commands own. A missing file counts as an
empty settings file. Exit codes: 0 = same, 1 = different, 2 = not usable.
"""

import argparse
import copy
import json
import re
import sys

TIMEOUT = 5

# (event, script, matcher). None = no matcher key.
# The SessionStart matcher leaves out "fork" on purpose.
REGISTRATIONS = [
    # Group A: session handoff.
    ("UserPromptSubmit", "context-pressure.sh", None),
    ("PostToolBatch", "context-pressure.sh", None),
    ("Stop", "context-pressure.sh", None),
    ("SessionEnd", "session-end-mark.sh", None),
    ("SessionStart", "handoff-load.sh", "startup|resume|clear|compact"),
    # Group B: usage limit.
    ("UserPromptSubmit", "usage-limit.sh", None),
    ("PreToolUse", "usage-limit.sh", None),
    ("PostToolUse", "usage-limit.sh", "Write|Edit|MultiEdit|mcp__ccd_session_mgmt__get_usage"),
    ("PostToolBatch", "usage-limit.sh", None),
    # Group C: secret guard.
    ("PreToolUse", "secret-guard.py", "Bash|Read|Grep|Glob|NotebookRead"),
]

# More handler keys for some scripts.
HANDLER_EXTRAS = {
    "secret-guard.py": {"timeout": 15, "onFailure": "block"},
}

SCRIPTS = sorted({script for _, script, _ in REGISTRATIONS})


class InputError(Exception):
    """The settings file does not have the expected structure."""


# Characters that the shell reads as plain text, without quotes.
SAFE_PATH = re.compile(r"^[A-Za-z0-9_@%+=:,./-]+$")

# The mods of local-mods. The claude plugin commands own their enabledPlugins keys.
PLUGIN_IDS = ("usage-feed@local-mods", "oturum@local-mods")
MARKETPLACE = "local-mods"


def is_tilde_form(directory):
    return directory == "~" or directory.startswith("~/")


def plain_path(directory, script):
    return "{}/hooks/{}".format(directory.rstrip("/"), script)


def shell_quote(text):
    return "'" + text.replace("'", "'\\''") + "'"


def command_for(directory, script):
    """Return the command string to write for this directory."""
    path = plain_path(directory, script)
    if is_tilde_form(directory) or SAFE_PATH.match(path):
        return path
    return shell_quote(path)


def our_commands(directories, script):
    """Return every command string that counts as ours for this script."""
    commands = set()
    for directory in directories:
        path = plain_path(directory, script)
        commands.add(path)
        if not is_tilde_form(directory):
            commands.add(shell_quote(path))
    return commands


def is_ours(handler, commands):
    return isinstance(handler, dict) and handler.get("command") in commands


def canonical_group(command, matcher, script):
    handler = {"type": "command", "command": command, "timeout": TIMEOUT}
    handler.update(HANDLER_EXTRAS.get(script, {}))
    if matcher is None:
        return {"hooks": [handler]}
    return {"matcher": matcher, "hooks": [handler]}


def handlers_of(group):
    """Return the handler list of a group, or None when the group is not usable."""
    if not isinstance(group, dict):
        return None
    handlers = group.get("hooks")
    if not isinstance(handlers, list):
        return None
    return handlers


def merge_one(groups, commands, wanted):
    """Make one registration correct in the group list of one event.

    Returns (new group list, status).
    """
    count = 0
    exact = 0
    for group in groups:
        handlers = handlers_of(group)
        if handlers is None:
            continue
        ours = [h for h in handlers if is_ours(h, commands)]
        count += len(ours)
        if group == wanted:
            exact += 1

    if count == 0:
        return groups + [wanted], "added"
    if count == 1 and exact == 1:
        return groups, "ok"

    # Wrong form, wrong matcher, a shared group, or a duplicate.
    # Put one correct group at the place of the first copy. Remove the other copies.
    result = []
    placed = False
    for group in groups:
        handlers = handlers_of(group)
        if handlers is None or not any(is_ours(h, commands) for h in handlers):
            result.append(group)
            continue
        others = [h for h in handlers if not is_ours(h, commands)]
        if others:
            # Handlers of other tools keep their group and its matcher.
            kept = dict(group)
            kept["hooks"] = others
            result.append(kept)
        if not placed:
            result.append(wanted)
            placed = True
    return result, "normalized"


def merge(settings, current_dir, known_dirs):
    """Merge all registrations into settings. Returns the report lines."""
    if not isinstance(settings, dict):
        raise InputError("the top level is not a JSON object")
    hooks = settings.get("hooks")
    if hooks is None:
        hooks = {}
    if not isinstance(hooks, dict):
        raise InputError('"hooks" is not a JSON object')

    all_dirs = [current_dir] + [d for d in known_dirs if d != current_dir]
    report = []
    for event, script, matcher in REGISTRATIONS:
        groups = hooks.get(event)
        if groups is None:
            groups = []
        if not isinstance(groups, list):
            raise InputError('"hooks.{}" is not a JSON array'.format(event))
        commands = our_commands(all_dirs, script)
        wanted = canonical_group(command_for(current_dir, script), matcher, script)
        new_groups, status = merge_one(groups, commands, wanted)
        if status != "ok":
            hooks[event] = new_groups
        report.append("{} {} {}".format(status, event, script))

    if hooks:
        settings["hooks"] = hooks

    # Report our commands in events that are not in the list. Do not change them.
    expected = {(event, script) for event, script, _ in REGISTRATIONS}
    for event, groups in hooks.items():
        if not isinstance(groups, list):
            continue
        for script in SCRIPTS:
            if (event, script) in expected:
                continue
            commands = our_commands(all_dirs, script)
            for group in groups:
                handlers = handlers_of(group) or []
                if any(is_ours(h, commands) for h in handlers):
                    report.append("extra {} {}".format(event, script))
                    break
    return report


def load_or_empty(path):
    """Return the parsed file. A missing file gives an empty object."""
    try:
        with open(path, encoding="utf-8") as handle:
            return json.load(handle)
    except FileNotFoundError:
        return {}


def without_plugin_keys(settings):
    """Return a copy without the keys that the claude plugin commands own."""
    result = copy.deepcopy(settings)
    owned = [("enabledPlugins", plugin_id) for plugin_id in PLUGIN_IDS]
    owned.append(("extraKnownMarketplaces", MARKETPLACE))
    for key, name in owned:
        section = result.get(key)
        if isinstance(section, dict):
            section.pop(name, None)
            if not section:
                del result[key]
    return result


def compare_plugins(before_path, after_path):
    try:
        before = load_or_empty(before_path)
        after = load_or_empty(after_path)
    except ValueError as error:
        print("hooks_settings.py: not valid JSON: {}".format(error), file=sys.stderr)
        return 2
    if not isinstance(before, dict) or not isinstance(after, dict):
        print("hooks_settings.py: the top level is not a JSON object", file=sys.stderr)
        return 2
    return 0 if without_plugin_keys(before) == without_plugin_keys(after) else 1


def main():
    parser = argparse.ArgumentParser(description="Merge hook registrations into a settings file.")
    parser.add_argument("--input")
    parser.add_argument("--output")
    parser.add_argument("--current-dir")
    parser.add_argument("--known-dir", action="append", default=[])
    parser.add_argument("--label")
    parser.add_argument("--compare-plugins", nargs=2, metavar=("BEFORE", "AFTER"))
    args = parser.parse_args()
    if args.compare_plugins:
        return compare_plugins(args.compare_plugins[0], args.compare_plugins[1])
    if not args.input or not args.output or not args.current_dir:
        parser.error("--input, --output and --current-dir are required")
    label = args.label or args.input

    try:
        with open(args.input, encoding="utf-8") as handle:
            text = handle.read()
    except FileNotFoundError:
        settings = {}
    else:
        try:
            settings = json.loads(text)
        except ValueError as error:
            print("hooks_settings.py: {} is not valid JSON: {}".format(label, error), file=sys.stderr)
            return 2

    original = copy.deepcopy(settings)
    try:
        report = merge(settings, args.current_dir, args.known_dir)
    except InputError as error:
        print("hooks_settings.py: {}: {}".format(label, error), file=sys.stderr)
        return 2

    # The merge may change "hooks" only. Compare the parsed objects.
    rest_before = {key: value for key, value in original.items() if key != "hooks"}
    rest_after = {key: value for key, value in settings.items() if key != "hooks"}
    if rest_before != rest_after:
        print("hooks_settings.py: {}: the merge changed keys outside \"hooks\"".format(label), file=sys.stderr)
        return 2
    report.append("result unchanged" if settings == original else "result changed")

    # Same format as scripts/install_hook.py, so the two scripts agree on the bytes.
    with open(args.output, "w", encoding="utf-8") as handle:
        handle.write(json.dumps(settings, indent=2, ensure_ascii=False) + "\n")
    for line in report:
        print(line)
    return 0


if __name__ == "__main__":
    sys.exit(main())
