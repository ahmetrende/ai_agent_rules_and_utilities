#!/usr/bin/env python3
"""Merge the subagent settings of this repo into a Claude Code settings file.

Usage:
  subagents_settings.py --input FILE --output FILE [--label NAME]

The script reads --input (a missing file counts as an empty settings file),
builds the merged settings and writes them to --output. It never changes
--input. install_subagents.sh compares the two files and replaces the live
file. --label is the file name to show in error messages (default: --input).

Rules:
  - permissions.deny gets "Agent(model:*opus*)" and "Agent(model:*fable*)".
    A string that is missing is added at the end of the list. A string that
    is there already is not touched, also when it is there two times. No
    other entry is removed, changed or moved.
  - env.CLAUDE_CODE_MAX_CONCURRENT_SUBAGENTS gets "2" when the key is missing.
    A key that exists keeps its value, also when the value is not "2".
  - All other keys stay as they are.

Output: one line for each item.
  "deny ok <string>" or "deny added <string>"
  "env ok", "env added" or "env differs <value as JSON>"
The last line is "result unchanged" or "result changed". It compares the
parsed settings, not the text, so a number like 1.10 or 1e3 in another key
never counts as a change.

Exit codes: 0 = merged, 2 = the input is not usable (nothing is written).
"""

import argparse
import copy
import json
import sys

DENY_RULES = ["Agent(model:*opus*)", "Agent(model:*fable*)"]
ENV_KEY = "CLAUDE_CODE_MAX_CONCURRENT_SUBAGENTS"
ENV_VALUE = "2"


class InputError(Exception):
    """The settings file does not have the expected structure."""


def merge(settings):
    """Merge the deny rules and the env key into settings. Returns the report lines."""
    if not isinstance(settings, dict):
        raise InputError("the top level is not a JSON object")
    report = []

    # A key with the value null counts as missing, like "// {}" in jq.
    permissions = settings.get("permissions")
    if permissions is None:
        permissions = {}
    if not isinstance(permissions, dict):
        raise InputError('"permissions" is not a JSON object')
    deny = permissions.get("deny")
    if deny is None:
        deny = []
    if not isinstance(deny, list):
        raise InputError('"permissions.deny" is not a JSON array')
    added = False
    for rule in DENY_RULES:
        if rule in deny:
            report.append("deny ok {}".format(rule))
        else:
            deny = deny + [rule]
            added = True
            report.append("deny added {}".format(rule))
    if added:
        permissions["deny"] = deny
        settings["permissions"] = permissions

    env = settings.get("env")
    if env is None:
        env = {}
    if not isinstance(env, dict):
        raise InputError('"env" is not a JSON object')
    if ENV_KEY not in env:
        env[ENV_KEY] = ENV_VALUE
        settings["env"] = env
        report.append("env added")
    elif env[ENV_KEY] == ENV_VALUE:
        report.append("env ok")
    else:
        report.append("env differs {}".format(json.dumps(env[ENV_KEY], ensure_ascii=False)))
    return report


def without_ours(settings):
    """Return a copy without our deny rules, our env key and the containers they leave empty."""
    result = copy.deepcopy(settings)
    permissions = result.get("permissions")
    if isinstance(permissions, dict):
        deny = permissions.get("deny")
        if isinstance(deny, list):
            permissions["deny"] = [rule for rule in deny if rule not in DENY_RULES]
        if not permissions.get("deny"):
            permissions.pop("deny", None)
    if not result.get("permissions"):
        result.pop("permissions", None)
    env = result.get("env")
    if isinstance(env, dict) and env.get(ENV_KEY) == ENV_VALUE:
        del env[ENV_KEY]
    if not result.get("env"):
        result.pop("env", None)
    return result


def main():
    parser = argparse.ArgumentParser(description="Merge the subagent settings into a settings file.")
    parser.add_argument("--input", required=True)
    parser.add_argument("--output", required=True)
    parser.add_argument("--label")
    args = parser.parse_args()
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
            print("subagents_settings.py: {} is not valid JSON: {}".format(label, error), file=sys.stderr)
            return 2

    original = copy.deepcopy(settings)
    try:
        report = merge(settings)
    except InputError as error:
        print("subagents_settings.py: {}: {}".format(label, error), file=sys.stderr)
        return 2

    # The merge may add our entries only. Compare the parsed objects without them.
    if without_ours(original) != without_ours(settings):
        print("subagents_settings.py: {}: the merge changed other keys".format(label), file=sys.stderr)
        return 2
    report.append("result unchanged" if settings == original else "result changed")

    # Same format as scripts/hooks_settings.py, so the scripts agree on the bytes.
    with open(args.output, "w", encoding="utf-8") as handle:
        handle.write(json.dumps(settings, indent=2, ensure_ascii=False) + "\n")
    for line in report:
        print(line)
    return 0


if __name__ == "__main__":
    sys.exit(main())
