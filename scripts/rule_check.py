#!/usr/bin/env python3
"""Check answers against the answer format in AGENTS.md.

The checks are mechanical: the first line, the "Senden:" part, the number of
bullets, headings, the interim status block, and words and signs that the rules
forbid (long dash, semicolon in prose, "---", closing phrases). They do not judge
the content.

The sample tasks are in scripts/tests/rule_cases.json. Each case has a good
answer that must pass and bad answers that must fail.

Usage:
  rule_check.py --selftest           Check the good and bad answers of every case.
  rule_check.py --check KIND FILE    Check one answer. KIND: short, detailed,
                                     interim or tool-error. FILE "-" is stdin.
  rule_check.py --live [CASE ...]    Send the prompts to "claude -p" and check the
                                     real answers. This starts Claude sessions with
                                     your rules and uses your plan's usage. Codex is
                                     not called: paste its answers into --check.
Exit 0 when every check passes, 1 when one fails.
"""

import json
import os
import re
import subprocess
import sys
import tempfile

CASES_FILE = os.path.join(os.path.dirname(os.path.abspath(__file__)), "tests", "rule_cases.json")
RULE_LINE = "━" * 30
INTERIM_LINE = "⏳ Arka planda devam ediyor."
KINDS = ("short", "detailed", "interim", "tool-error")
MAX_BULLETS = 3
MAX_SHORT_LINES = 5   # Non-empty lines between the rule line and "Senden:".
CLOSERS = ("umarım yardımcı olur", "başka bir şey lazım olursa", "harika soru", "sormaktan çekinme",
           "açıklamamı istersen buradayım")
ERROR_WORDS = re.compile(r"\b(hata\w*|fail\w*|başarısız\w*|error\w*)", re.I)


def prose_lines(text):
    """Return (index, line) for the lines outside code blocks and inline code removed."""
    out = []
    in_fence = False
    for index, line in enumerate(text.split("\n")):
        if line.strip().startswith(("```", "~~~")):
            in_fence = not in_fence
            continue
        if not in_fence:
            out.append((index, re.sub(r"`[^`]*`", "", line)))
    return out


def common_problems(text):
    problems = []
    for index, line in prose_lines(text):
        if line.strip() == "---":
            problems.append("line %d: \"---\" (the desktop app draws it faint)" % (index + 1))
        if "—" in line or "–" in line:
            problems.append("line %d: long or middle dash" % (index + 1))
        if ";" in line:
            problems.append("line %d: semicolon in prose" % (index + 1))
        lowered = line.lower()
        for phrase in CLOSERS:
            if phrase in lowered:
                problems.append("line %d: closing phrase %r" % (index + 1, phrase))
    return problems


def senden_problems(lines):
    """The answer ends with the "Senden:" part: a line, maybe a numbered list, nothing else."""
    starts = [i for i, line in enumerate(lines) if line.startswith("Senden:")]
    if not starts:
        return ["no \"Senden:\" line"]
    rest = [line for line in lines[starts[-1] + 1:] if line.strip()]
    extra = [line for line in rest if not re.match(r"^\s*(\d+\.\s|\s{2,})", line)]
    if extra:
        return ["text after the \"Senden:\" part: %r" % extra[0][:60]]
    return []


def check(kind, text):
    """Return the problems of one answer. An empty list means it passes."""
    lines = text.rstrip("\n").split("\n")
    nonempty = [line for line in lines if line.strip()]
    problems = common_problems(text)
    if kind == "interim":
        if RULE_LINE in lines:
            problems.append("an interim status has no rule line")
        if nonempty[:3] != ["```", INTERIM_LINE, "```"]:
            problems.append("an interim status starts with a code block that holds only %r" % INTERIM_LINE)
        else:
            after = lines[lines.index("```", lines.index(INTERIM_LINE)) + 1:]
            if not after or after[0].strip():
                problems.append("no blank line after the code block")
            status = [line for line in after if line.strip() and not line.startswith("Senden:")]
            if len(status) != 1:
                problems.append("the status is %d lines, not one" % len(status))
        return problems
    if not nonempty or nonempty[0] != RULE_LINE:
        problems.append("the first line is not the rule line")
    problems += senden_problems(lines)
    body = []
    for line in nonempty[1:]:
        if line.startswith("Senden:"):
            break
        body.append(line)
    if body and body[0].startswith("#"):
        problems.append("the first line after the rule line is a heading, not the result")
    if kind in ("short", "tool-error"):
        bullets = [line for line in body if line.startswith("- ")]
        if len(bullets) > MAX_BULLETS:
            problems.append("%d bullets, at most %d" % (len(bullets), MAX_BULLETS))
        if len(body) > MAX_SHORT_LINES:
            problems.append("%d lines before \"Senden:\", at most %d" % (len(body), MAX_SHORT_LINES))
    if kind == "detailed" and not any(line.startswith("## ") for line in body):
        problems.append("a detailed answer has a \"## \" heading")
    if kind == "tool-error" and not ERROR_WORDS.search(" ".join(body[:2])):
        problems.append("the first lines do not name the error or the failed test")
    return problems


def load_cases():
    with open(CASES_FILE, encoding="utf-8") as handle:
        return json.load(handle)["cases"]


def selftest():
    failures = 0
    for case in load_cases():
        problems = check(case["kind"], case["good"])
        if problems:
            failures += 1
            print("FAIL %s: the good answer has problems: %s" % (case["name"], "; ".join(problems)))
        for number, bad in enumerate(case["bad"], 1):
            if not check(case["kind"], bad):
                failures += 1
                print("FAIL %s: bad answer %d passes" % (case["name"], number))
    total = sum(1 + len(case["bad"]) for case in load_cases())
    print("rule_check selftest: %d pass, %d fail" % (total - failures, failures))
    return 1 if failures else 0


def live(names):
    cases = [case for case in load_cases() if case["kind"] in ("short", "detailed", "tool-error")
             and (not names or case["name"] in names)]
    failures = 0
    for case in cases:
        if case["prompt"].startswith("("):
            print("skip %s: the prompt describes a situation, not a message" % case["name"])
            continue
        with tempfile.TemporaryDirectory() as work:
            done = subprocess.run(["claude", "-p", case["prompt"]], cwd=work, stdout=subprocess.PIPE,
                                  stderr=subprocess.PIPE, universal_newlines=True, timeout=300)
        if done.returncode != 0:
            failures += 1
            print("FAIL %s: claude -p exit code %d: %s" % (case["name"], done.returncode, done.stderr.strip()[:200]))
            continue
        problems = check(case["kind"], done.stdout)
        failures += bool(problems)
        print("%s %s%s" % ("FAIL" if problems else "ok  ", case["name"], ": " + "; ".join(problems) if problems else ""))
    return 1 if failures else 0


def main(argv):
    if argv[:1] == ["--selftest"] and len(argv) == 1:
        return selftest()
    if argv[:1] == ["--check"] and len(argv) == 3 and argv[1] in KINDS:
        text = sys.stdin.read() if argv[2] == "-" else open(argv[2], encoding="utf-8").read()
        problems = check(argv[1], text)
        for problem in problems:
            print(problem)
        print("ok" if not problems else "%d problems" % len(problems))
        return 1 if problems else 0
    if argv[:1] == ["--live"]:
        return live(argv[1:])
    print(__doc__.strip(), file=sys.stderr)
    return 2


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
