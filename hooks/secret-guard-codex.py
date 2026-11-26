#!/usr/bin/env python3
"""Codex PreToolUse adapter for secret-guard.py: the same rules in Codex sessions as in Claude Code.

Codex sends a Claude-style JSON payload on stdin. The shell command may be a string or an argv list
(["bash", "-lc", "..."]), and the tool name may be Bash, shell, local_shell or exec_command. A block is
returned two ways: a PreToolUse deny decision on stdout, and exit code 2 with the reason on stderr.
With SECRET_GUARD_DEBUG=1 the payload's key names (no values) are logged, to confirm the format.

The rules live in secret-guard.py in the same directory. install.sh copies both files. It does not
register this adapter in ~/.codex/hooks.json: register it by hand where Codex should use it.
"""
import importlib.util
import json
import os
import sys

HOOKS = os.path.dirname(os.path.abspath(__file__))
spec = importlib.util.spec_from_file_location("secret_guard", os.path.join(HOOKS, "secret-guard.py"))
sg = importlib.util.module_from_spec(spec)
spec.loader.exec_module(sg)


def command_of(inp):
    cmd = inp.get("command") or inp.get("cmd") or ""
    if isinstance(cmd, list):
        if len(cmd) >= 3 and str(cmd[1]) in ("-c", "-lc"):
            return str(cmd[-1])
        return " ".join(map(str, cmd))
    return str(cmd)


def main():
    data = json.load(sys.stdin)
    tool = str(data.get("tool_name", ""))
    inp = data.get("tool_input") or {}
    if isinstance(inp, str):
        try:
            inp = json.loads(inp)
        except ValueError:
            inp = {"command": inp}
    if os.environ.get("SECRET_GUARD_DEBUG"):
        os.makedirs(os.path.join(HOOKS, "state"), exist_ok=True)
        with open(os.path.join(HOOKS, "state", "secret-guard-codex-debug.log"), "a") as f:
            f.write(json.dumps({"keys": sorted(data), "tool_name": tool,
                                "input_keys": sorted(inp) if isinstance(inp, dict) else type(inp).__name__}) + "\n")
    cmd = command_of(inp) if isinstance(inp, dict) else ""
    cwd = str(data.get("cwd") or "") or None
    if cmd:
        rule = sg.check_bash(cmd)
        user_cmd = sg.safe_user_command("Bash", {"command": cmd}, cwd)
    else:
        path_inp = inp if isinstance(inp, dict) else {}
        rule = sg.check_path_tool("Read", path_inp)
        user_cmd = sg.safe_user_command("Read", path_inp, cwd)
    if not rule:
        return 0
    sg.log(f"codex:{tool}", rule)
    reason = sg.deny_reason(rule, user_cmd)
    print(json.dumps({"hookSpecificOutput": {"hookEventName": "PreToolUse", "permissionDecision": "deny",
                                             "permissionDecisionReason": reason}}))
    print(reason, file=sys.stderr)
    return 2


if __name__ == "__main__":
    sys.exit(main())
