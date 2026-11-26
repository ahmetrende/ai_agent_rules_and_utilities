#!/usr/bin/env python3
"""Add the term-profile SessionStart hook to a Claude Code settings file.

Usage:
  install_hook.py SETTINGS_FILE COMMAND
  install_hook.py --check SETTINGS_FILE COMMAND

The script removes an older copy of the same hook first, for example after
you move the repo. A copy that is already current keeps its place in the
list, so a second run changes nothing. It keeps all other hooks. It writes the file only when
the content changes, and it prints "changed" or "unchanged".

--check changes nothing. It prints one word and exits:
  ok        exit 0. The install would not change the hooks.
  missing   exit 1. The file has no copy of this hook.
  outdated  exit 1. The file has an older copy, or a copy that the install moves.
An unreadable or invalid settings file gives exit 2 and a message on stderr.
"""

import copy
import json
import os
import shutil
import sys

# Every copy of this hook runs term_profile.py with this flag.
MARKER = "term_profile.py' --max-age-days"


def wanted_group(command):
    # No matcher: the hook runs on every session start. async: the session does not wait.
    return {"hooks": [{"type": "command", "command": command, "async": True}]}


def add_hook(settings, command):
    """Put the current hook into settings. Return True if a copy was there before."""
    wanted = wanted_group(command)
    groups = settings.setdefault("hooks", {}).setdefault("SessionStart", [])
    kept_groups = []
    found = False
    had_copy = False
    for group in groups:
        # The current hook keeps its place, so a second run changes nothing.
        if not found and group == wanted:
            kept_groups.append(group)
            found = True
            had_copy = True
            continue
        handlers = group.get("hooks", [])
        other_handlers = [h for h in handlers if MARKER not in h.get("command", "")]
        if len(other_handlers) != len(handlers):
            had_copy = True
        if handlers and not other_handlers:
            continue  # The group held only an older copy of this hook.
        group["hooks"] = other_handlers
        kept_groups.append(group)

    if not found:
        kept_groups.append(wanted)
    settings["hooks"]["SessionStart"] = kept_groups
    return had_copy


def read_settings(path):
    """Return (file text or None, parsed settings). Raise ValueError if not usable."""
    try:
        with open(path, encoding="utf-8") as handle:
            original = handle.read()
    except FileNotFoundError:
        return None, {}
    try:
        settings = json.loads(original)
    except json.JSONDecodeError as error:
        raise ValueError(f"{path} is not valid JSON: {error}") from error
    if not isinstance(settings, dict):
        raise ValueError(f"{path} does not hold a JSON object.")
    return original, settings


def main():
    args = sys.argv[1:]
    check = bool(args) and args[0] == "--check"
    if check:
        args = args[1:]
    if len(args) != 2:
        print(__doc__.strip(), file=sys.stderr)
        return 2
    path, command = args

    try:
        original, settings = read_settings(path)
    except (OSError, ValueError) as error:
        print(f"install_hook.py: {error}", file=sys.stderr)
        return 2

    if check:
        before = copy.deepcopy(settings)
        had_copy = add_hook(settings, command)
        if settings == before:
            print("ok")
            return 0
        print("outdated" if had_copy else "missing")
        return 1

    add_hook(settings, command)
    text = json.dumps(settings, indent=2, ensure_ascii=False) + "\n"
    if text == original:
        print("unchanged")
        return 0
    # Write through a symlink to its target, so the link stays a link.
    path = os.path.realpath(path)
    os.makedirs(os.path.dirname(path), exist_ok=True)
    temp_path = path + ".tmp"
    with open(temp_path, "w", encoding="utf-8") as handle:
        handle.write(text)
    if original is not None:
        shutil.copymode(path, temp_path)
    os.replace(temp_path, path)
    print("changed")
    return 0


if __name__ == "__main__":
    sys.exit(main())
