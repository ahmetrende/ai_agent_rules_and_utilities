#!/usr/bin/env python3
"""Build a term-language profile from your own Claude Code messages.

For each concept pair in terms/pairs.tsv, the script counts how often you
wrote the Turkish form and how often you wrote the English form. It writes
the terms that you use mostly in one language to generated/term_profile.md.
AGENTS.md imports that file, so Claude reads it in every session.

The script keeps a cache of your cleaned messages in
~/.cache/ai_agent_rules/messages.json. Claude Code deletes old transcripts.
The cache keeps their messages, so the counts do not drop.
The cache also keeps the term counts of these messages. A run counts only the
messages that are new since the last run. When terms/pairs.tsv changes, the
next run counts all messages again.
A run that finds no messages does not replace a profile that was built from
messages. Such a run usually has another HOME, CLAUDE_CONFIG_DIR or
XDG_CACHE_HOME, for example a test in a temporary home.

--export writes your term preferences to a file: the terms of
local/override.md (or the template terms/override.md when that is missing) and,
with --with-counts, the term counts. The file does not
contain the text of your messages. --import shows what such a file changes on
this machine. --import with --apply makes the changes: it adds the override
terms to local/override.md (created from the template when missing) and keeps the counts in imported_counts.json in the
cache folder. A new --import replaces the counts of an earlier one.
The cache folder has mode 700 and its files have mode 600. Each run sets these
modes again. A cache file that is not valid JSON or has the wrong structure is
moved to messages.json.broken-<time>, and the cache is built again from the
transcripts.

Usage:
  term_profile.py                    Update the cache and write the profile.
  term_profile.py --max-age-days 7   Do nothing if the profile is less than 7 days old.
  term_profile.py --quiet            Print nothing. The SessionStart hook uses this.
  term_profile.py --report           Print the counts for every pair.
  term_profile.py --evaluate         Test how well old messages predict new messages.
                                     Uses the same rule and override filter as the profile.
  term_profile.py --check            Show the state of the cache and the last run.
                                     Changes nothing. Exit 1 when there is a problem.
  term_profile.py --export FILE [--with-counts]
                                     Write the override terms (and the term counts) to FILE.
  term_profile.py --import FILE [--apply]
                                     Show what FILE changes. --apply makes the changes.
"""

import argparse
import fcntl
import glob
import hashlib
import json
import os
import re
import stat
import sys
import time
import traceback
from datetime import datetime, timezone

REPO_DIR = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
PAIRS_FILE = os.path.join(REPO_DIR, "terms", "pairs.tsv")
OVERRIDE_TEMPLATE = os.path.join(REPO_DIR, "terms", "override.md")   # tracked, empty template
OVERRIDE_FILE = os.path.join(REPO_DIR, "local", "override.md")       # the user's file, not in git
PROFILE_FILE = os.path.join(REPO_DIR, "generated", "term_profile.md")

# An empty variable counts as unset, so the paths never become relative.
CLAUDE_DIR = os.environ.get("CLAUDE_CONFIG_DIR") or os.path.expanduser("~/.claude")
TRANSCRIPT_GLOB = os.path.join(CLAUDE_DIR, "projects", "*", "*.jsonl")
CACHE_DIR = os.path.join(os.environ.get("XDG_CACHE_HOME") or os.path.expanduser("~/.cache"), "ai_agent_rules")
CACHE_FILE = os.path.join(CACHE_DIR, "messages.json")
LOCK_FILE = os.path.join(CACHE_DIR, "term_profile.lock")
LOG_FILE = os.path.join(CACHE_DIR, "term_profile.log")
IMPORTED_FILE = os.path.join(CACHE_DIR, "imported_counts.json")
BROKEN_PREFIX = CACHE_FILE + ".broken-"

# The cache holds the text of your messages: only you may read it.
TR_OFFSET = 3 * 3600  # Turkey keeps UTC+3 all year.
DIR_MODE = 0o700
FILE_MODE = 0o600

# Change this number when the cleaning rules change. The cache is then built again.
CLEAN_VERSION = 1
# Change this number when the counting rules change. The next run counts all messages again.
COUNT_VERSION = 1

MIN_COUNT = 10          # A pair needs this many uses in total to go into the profile.
MIN_SHARE = 0.6         # One form needs this share of the uses to go into the profile.
MAX_MESSAGE_CHARS = 1500  # Longer messages are usually pasted text, not your own writing.
MIN_TEST_COUNT = 5      # --evaluate: a pair needs this many uses in the test messages.

EXPORT_FORMAT = "ai_agent_rules term preferences"
EXPORT_VERSION = 1

TAG_BLOCK = re.compile(r"<([a-zA-Z][\w-]*)\b[^>]*>.*?</\1>", re.S)
CODE_FENCE = re.compile(r"```.*?```", re.S)
INLINE_CODE = re.compile(r"`[^`\n]*`")
CODE_LINE = re.compile(
    r"^\s*(select|insert|update|delete|create|alter|drop|grant|with|from|where|set|exec|declare"
    r"|\$|#|//|--|\{|\}|import|def |function |if |for )|[;{}=]\s*$",
    re.I,
)
TURKISH_HINT = re.compile(r"[çğışöü]|\b(bir|bu|ve|için|ne|mi|mı|var|yok|de|da)\b")
SUMMARY_PREFIX = "this session is being continued"
OVERRIDE_LINE = re.compile(r"^\s*(Türkçe|İngilizce) yaz:\s*(.*)$")


def make_cache_dir():
    """Create the cache folder with mode 700."""
    os.makedirs(CACHE_DIR, mode=DIR_MODE, exist_ok=True)


def open_private(path, flags):
    """Open a file in the cache folder. A new file gets mode 600."""
    return os.fdopen(os.open(path, flags, FILE_MODE), "a" if flags & os.O_APPEND else "w", encoding="utf-8")


def log(message):
    """Append one line to the log file. Never raise."""
    try:
        make_cache_dir()
        with open_private(LOG_FILE, os.O_WRONLY | os.O_CREAT | os.O_APPEND) as handle:
            handle.write("%s %s\n" % (datetime.now().isoformat(timespec="seconds"), message))
    except OSError:
        pass


def secure_cache_dir():
    """Set mode 700 on the cache folder and mode 600 on its files. Older versions used the umask."""
    if not os.path.isdir(CACHE_DIR):
        return
    try:
        if stat.S_IMODE(os.stat(CACHE_DIR).st_mode) != DIR_MODE:
            os.chmod(CACHE_DIR, DIR_MODE)
        for name in os.listdir(CACHE_DIR):
            path = os.path.join(CACHE_DIR, name)
            info = os.lstat(path)
            if stat.S_ISREG(info.st_mode) and stat.S_IMODE(info.st_mode) != FILE_MODE:
                os.chmod(path, FILE_MODE)
    except OSError as error:
        log("could not set the cache modes: %s" % error)


def write_atomic(path, text, private=False):
    """Write text to a temporary file, then rename it over path.

    private: the file is in the cache folder and gets mode 600.
    """
    os.makedirs(os.path.dirname(path), exist_ok=True)
    temp_path = path + ".tmp"
    if private:
        with open_private(temp_path, os.O_WRONLY | os.O_CREAT | os.O_TRUNC) as handle:
            os.fchmod(handle.fileno(), FILE_MODE)
            handle.write(text)
    else:
        with open(temp_path, "w", encoding="utf-8") as handle:
            handle.write(text)
    os.replace(temp_path, path)


# --- Messages -----------------------------------------------------------------


def clean_text(text):
    """Return the lower-case prose of a message, or None if it is not Turkish prose."""
    text = TAG_BLOCK.sub(" ", text)
    text = CODE_FENCE.sub(" ", text)
    text = INLINE_CODE.sub(" ", text)
    text = "\n".join(line for line in text.splitlines() if not CODE_LINE.search(line)).strip()
    if len(text) < 3 or len(text) > MAX_MESSAGE_CHARS:
        return None
    text = text.replace("İ", "i").lower()
    if text.startswith(SUMMARY_PREFIX) or not TURKISH_HINT.search(text):
        return None
    return text


def user_texts(record):
    """Return the text parts that the user typed in one transcript record."""
    if record.get("type") != "user":
        return []
    if record.get("isMeta") or record.get("isSidechain") or record.get("isCompactSummary"):
        return []
    content = (record.get("message") or {}).get("content")
    if isinstance(content, str):
        return [content]
    if isinstance(content, list):
        return [part.get("text", "") for part in content if isinstance(part, dict) and part.get("type") == "text"]
    return []


def read_transcript(path):
    """Yield (timestamp, cleaned text) for each user message in one transcript."""
    with open(path, encoding="utf-8", errors="ignore") as handle:
        for line in handle:
            try:
                record = json.loads(line)
            except ValueError:
                continue
            if not isinstance(record, dict):
                continue
            for text in user_texts(record):
                cleaned = clean_text(text) if text else None
                if cleaned:
                    yield record.get("timestamp", ""), cleaned


def cache_problem(cache):
    """Return why a parsed cache cannot be used, or None when its structure is valid."""
    if not isinstance(cache, dict):
        return "the top level is %s, not an object" % type(cache).__name__
    if not isinstance(cache.get("files"), dict):
        return '"files" is not an object'
    if not isinstance(cache.get("messages"), dict):
        return '"messages" is not an object'
    for signature in cache["files"].values():
        if not (isinstance(signature, list) and len(signature) == 2):
            return 'an entry of "files" is not a list of two numbers'
    for value in cache["messages"].values():
        if not (isinstance(value, list) and len(value) == 2 and all(isinstance(part, str) for part in value)):
            return 'an entry of "messages" is not a list of two texts'
    return None


def read_cache_file():
    """Return (cache, problem). A missing file gives (None, None)."""
    try:
        with open(CACHE_FILE, encoding="utf-8") as handle:
            cache = json.load(handle)
    except FileNotFoundError:
        return None, None
    except OSError as error:
        return None, "cannot be read (%s)" % (error.strerror or type(error).__name__)
    except ValueError as error:
        return None, "not valid JSON (%s)" % error
    except RecursionError:
        return None, "not valid JSON (nested too deep)"
    return cache, cache_problem(cache)


def set_aside_broken_cache(problem):
    """Move a broken cache file to messages.json.broken-<time>, so the next write does not lose it."""
    target = BROKEN_PREFIX + datetime.now().strftime("%Y%m%dT%H%M%S")
    try:
        os.replace(CACHE_FILE, target)
    except OSError as error:
        raise RuntimeError("the cache %s is broken (%s) and could not be moved: %s" % (CACHE_FILE, problem, error))
    log("cache was broken (%s): moved to %s. The cache is built again from the transcripts." % (problem, target))


def load_cache():
    cache, problem = read_cache_file()
    if problem:
        set_aside_broken_cache(problem)
    elif cache is not None and cache.get("clean_version") == CLEAN_VERSION:
        return cache
    return {"clean_version": CLEAN_VERSION, "files": {}, "messages": {}}


def update_cache(pairs):
    """Read new or changed transcripts into the cache. Keep messages of deleted transcripts.

    The cache also keeps the term counts of all its messages ("counts"). Messages
    are only added, never removed, so the counts of the new messages are added
    to the old counts. The counts are built again from all messages when
    terms/pairs.tsv or the counting rules changed, or when they do not cover
    exactly the messages that were in the cache before this run (for example,
    an older version of this script added messages).
    """
    cache = load_cache()
    changed = False
    new_texts = []
    for path in glob.glob(TRANSCRIPT_GLOB):
        try:
            stat = os.stat(path)
        except OSError:
            continue
        signature = [int(stat.st_mtime), stat.st_size]
        if cache["files"].get(path) == signature:
            continue
        for timestamp, text in read_transcript(path):
            key = hashlib.sha1(text.encode("utf-8")).hexdigest()
            known = cache["messages"].get(key)
            if known is None:
                new_texts.append(text)
                cache["messages"][key] = [timestamp, text]
            elif timestamp and timestamp < known[0]:
                cache["messages"][key] = [timestamp, text]
        cache["files"][path] = signature
        changed = True
    key = pairs_key()
    counts = cache.get("counts")
    if counts_problem(counts, key, len(pairs), len(cache["messages"]) - len(new_texts)) is None:
        if new_texts:
            add_counts(counts["pairs"], count_texts(pairs, new_texts))
            counts["message_count"] = len(cache["messages"])
    else:
        texts = [text for _, text in cache["messages"].values()]
        cache["counts"] = {"key": key, "message_count": len(texts), "pairs": count_texts(pairs, texts)}
        if texts:
            changed = True
    if changed:
        write_atomic(CACHE_FILE, json.dumps(cache, ensure_ascii=False), private=True)
    return cache


# --- Pairs and counting ---------------------------------------------------------


def split_top_level(field):
    """Split a regex field on "|" characters that are not inside (...) or [...]."""
    parts, depth, in_class, current = [], 0, False, ""
    for char in field:
        if char == "[":
            in_class = True
        elif char == "]":
            in_class = False
        elif char == "(" and not in_class:
            depth += 1
        elif char == ")" and not in_class:
            depth -= 1
        if char == "|" and depth == 0 and not in_class:
            parts.append(current)
            current = ""
        else:
            current += char
    parts.append(current)
    return [part.strip() for part in parts if part.strip()]


def display_form(alternative):
    """Turn one regex alternative into the word that a reader sees."""
    text = re.sub(r"\(\?[:!=<][^)]*\)", "", alternative)
    text = re.sub(r"\[(.)[^\]]*\]", r"\1", text)
    text = text.replace("\\s?", " ").replace("\\s", " ")
    return re.sub(r"\s+", " ", text).strip()


def turkish_pattern(alternatives):
    # A Turkish form matches as a stem, because Turkish adds suffixes without an apostrophe.
    return re.compile(r"(?<![\w])(?:%s)\w*" % "|".join(alternatives))


def english_pattern(alternatives):
    # An English form matches as a whole word, with an optional plural or apostrophe suffix.
    return re.compile(r"(?<![\w])(?:%s)(?:['’]\w+|s|es)?(?![\w])" % "|".join(alternatives))


def load_pairs():
    pairs = []
    with open(PAIRS_FILE, encoding="utf-8") as handle:
        for number, line in enumerate(handle, 1):
            line = line.rstrip("\n")
            if not line.strip() or line.lstrip().startswith("#"):
                continue
            fields = line.split("\t")
            if len(fields) != 2:
                raise ValueError("%s:%d: expected 2 fields separated by one TAB" % (PAIRS_FILE, number))
            turkish = split_top_level(fields[0])
            english = split_top_level(fields[1])
            pairs.append({
                # The two fields as they are in the file. Exported counts use it to find the pair.
                "line": fields[0].strip() + "\t" + fields[1].strip(),
                "turkish": turkish,
                "english": english,
                "turkish_pattern": turkish_pattern(turkish),
                "english_pattern": english_pattern(english),
                # One pattern for each form, to find the form that the user writes most.
                "turkish_forms": [turkish_pattern([alt]) for alt in turkish] if len(turkish) > 1 else [],
                "english_forms": [english_pattern([alt]) for alt in english] if len(english) > 1 else [],
            })
    return pairs


def pairs_key():
    """Return a key that changes when terms/pairs.tsv or the counting rules change."""
    with open(PAIRS_FILE, "rb") as handle:
        digest = hashlib.sha1(handle.read()).hexdigest()
    return "%s clean%d count%d" % (digest, CLEAN_VERSION, COUNT_VERSION)


def count_texts(pairs, texts):
    """Count the uses of each pair in the texts.

    Return one entry for each pair: [Turkish uses, English uses,
    uses of each Turkish form, uses of each English form]. The form lists are
    empty when the pair has only one form on that side.
    """
    corpus = "\n".join(texts)
    counts = []
    for pair in pairs:
        counts.append([
            len(pair["turkish_pattern"].findall(corpus)),
            len(pair["english_pattern"].findall(corpus)),
            [len(pattern.findall(corpus)) for pattern in pair["turkish_forms"]],
            [len(pattern.findall(corpus)) for pattern in pair["english_forms"]],
        ])
    return counts


def add_counts(total, extra):
    """Add the counts in extra to the counts in total. Both have the same pairs."""
    for entry, more in zip(total, extra):
        entry[0] += more[0]
        entry[1] += more[1]
        entry[2] = [a + b for a, b in zip(entry[2], more[2])]
        entry[3] = [a + b for a, b in zip(entry[3], more[3])]


def is_count_entry(entry):
    """Return True if entry has the structure that count_texts() gives for one pair."""
    return (isinstance(entry, list) and len(entry) == 4
            and all(isinstance(value, int) and value >= 0 for value in entry[:2])
            and all(isinstance(forms, list) and all(isinstance(value, int) and value >= 0 for value in forms)
                    for forms in entry[2:]))


def counts_problem(counts, key, pair_count, message_count):
    """Return why the stored counts cannot be used, or None when they can."""
    if not isinstance(counts, dict):
        return "no counts"
    if counts.get("key") != key:
        return "the counts are for another terms/pairs.tsv or another script version"
    if counts.get("message_count") != message_count:
        return "the counts are for %r messages, not %d" % (counts.get("message_count"), message_count)
    entries = counts.get("pairs")
    if not (isinstance(entries, list) and len(entries) == pair_count and all(is_count_entry(e) for e in entries)):
        return "the counts have the wrong structure"
    return None


def pick_form(alternatives, form_counts):
    """Return the display form of the alternative that the user writes most.

    On a tie, the alternative that comes first in terms/pairs.tsv wins.
    """
    if len(alternatives) == 1 or len(form_counts) != len(alternatives):
        return display_form(alternatives[0])
    best = max((count, -index, alt) for index, (alt, count) in enumerate(zip(alternatives, form_counts)))
    return display_form(best[2])


def results_from_counts(pairs, counts):
    """Turn the counts of count_texts() into one result for each pair."""
    results = []
    for pair, (turkish_count, english_count, turkish_forms, english_forms) in zip(pairs, counts):
        results.append({
            "line": pair["line"],
            "turkish_count": turkish_count,
            "english_count": english_count,
            "turkish_word": pick_form(pair["turkish"], turkish_forms),
            "english_word": pick_form(pair["english"], english_forms),
            "all_words": {display_form(alt) for alt in pair["turkish"] + pair["english"]},
        })
    return results


def decide(result):
    """Return "tr", "en", or None when the data is too small or too mixed."""
    total = result["turkish_count"] + result["english_count"]
    if total < MIN_COUNT:
        return None
    if result["turkish_count"] >= MIN_SHARE * total:
        return "tr"
    if result["english_count"] >= MIN_SHARE * total:
        return "en"
    return None


# --- Override and profile -------------------------------------------------------


def override_read_path():
    """Return local/override.md when it exists, else the template terms/override.md."""
    return OVERRIDE_FILE if os.path.isfile(OVERRIDE_FILE) else OVERRIDE_TEMPLATE


def ensure_local_override():
    """Create local/override.md from the template when it is missing."""
    if os.path.isfile(OVERRIDE_FILE):
        return
    try:
        with open(OVERRIDE_TEMPLATE, encoding="utf-8") as handle:
            text = handle.read()
    except OSError:
        text = "# Terim override'ları\n\nTürkçe yaz:\n\nİngilizce yaz:\n"
    os.makedirs(os.path.dirname(OVERRIDE_FILE), exist_ok=True)
    write_atomic(OVERRIDE_FILE, text)


def load_override_words():
    words = set()
    try:
        with open(override_read_path(), encoding="utf-8") as handle:
            for line in handle:
                match = OVERRIDE_LINE.match(line)
                if match:
                    words.update(word.strip().lower() for word in match.group(2).split(",") if word.strip())
    except OSError:
        pass
    return words


PROFILE_COUNT = re.compile(r"Kaynak: ([0-9.]+) mesaj")


def profile_message_count():
    """Return the message count that the current profile names, or 0."""
    try:
        with open(PROFILE_FILE, encoding="utf-8") as handle:
            match = PROFILE_COUNT.search(handle.read())
    except OSError:
        return 0
    return int(match.group(1).replace(".", "")) if match else 0


def turkish_number(value):
    return "{:,}".format(value).replace(",", ".")


def profile_terms(results, override_words):
    """Return (Turkish words, English words) that the profile lists, most used first."""
    turkish, english = [], []
    for result in sorted(results, key=lambda r: -(r["turkish_count"] + r["english_count"])):
        if result["all_words"] & override_words:
            continue
        decision = decide(result)
        if decision == "tr" and result["turkish_word"] not in turkish:
            turkish.append(result["turkish_word"])
        elif decision == "en" and result["english_word"] not in english:
            english.append(result["english_word"])
    return turkish, english


def write_profile(results, message_count, override_words, imported_count=0):
    turkish, english = profile_terms(results, override_words)
    source = turkish_number(message_count + imported_count) + " mesaj"
    if imported_count:
        source += " (%s bu makineden, %s aktarılan)" % (turkish_number(message_count), turkish_number(imported_count))
    lines = [
        "<!-- Generated by scripts/term_profile.py. Do not edit this file. Run the script to update it. -->",
        "# Terim profili",
        "",
        "- Bu liste benim mesajlarımdan otomatik üretilir. Kaynak: %s. Tarih: %s."
        % (source, datetime.now().strftime("%Y-%m-%d")),
        "- Bir terim, benim en az %%%d oranında kullandığım dilde yer alır." % int(MIN_SHARE * 100),
        "- Override dosyasındaki terimler bu listede yer almaz.",
        "",
        "Türkçe yaz: " + ", ".join(turkish),
        "",
        "İngilizce yaz: " + ", ".join(english),
        "",
    ]
    write_atomic(PROFILE_FILE, "\n".join(lines))
    return len(turkish), len(english)


def refresh_codex_rules():
    """Write the Codex rules file again, because it holds the profile text. Never raise."""
    try:
        sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
        import codex_rules
        codex_rules.refresh()
    except Exception as error:
        log("codex rules not refreshed: %s" % error)


# --- Report and evaluation ------------------------------------------------------


def print_report(results):
    print("%-28s %-28s %6s %6s %6s  %s" % ("turkish", "english", "tr", "en", "tr%", "profile"))
    for result in sorted(results, key=lambda r: -(r["turkish_count"] + r["english_count"])):
        total = result["turkish_count"] + result["english_count"]
        share = "%5.0f%%" % (100.0 * result["turkish_count"] / total) if total else "     -"
        decision = {"tr": "Türkçe", "en": "İngilizce", None: "-"}[decide(result)]
        print("%-28s %-28s %6d %6d %6s  %s" % (
            result["turkish_word"], result["english_word"],
            result["turkish_count"], result["english_count"], share, decision))


def evaluate(pairs, messages, override_words):
    """Build a profile from the first 70% of messages. Test it on the last 30%.

    The profile part uses the same rule as the real profile: decide() and the
    override filter. A pair that the rule does not decide is not tested, and
    the output says how many pairs each reason skipped.
    """
    ordered = [text for _, text in sorted(messages)]
    split = int(len(ordered) * 0.7)
    train = results_from_counts(pairs, count_texts(pairs, ordered[:split]))
    test = results_from_counts(pairs, count_texts(pairs, ordered[split:]))
    tested = agree = weighted_agree = weighted_total = 0
    skipped_override, skipped_rule, skipped_test = 0, [], 0
    for train_result, test_result in zip(train, test):
        if train_result["all_words"] & override_words:
            skipped_override += 1
            continue
        decision = decide(train_result)
        if decision is None:
            total = train_result["turkish_count"] + train_result["english_count"]
            if total:
                skipped_rule.append((total, train_result["turkish_word"], train_result["english_word"]))
            continue
        test_tr, test_en = test_result["turkish_count"], test_result["english_count"]
        if test_tr + test_en < MIN_TEST_COUNT:
            skipped_test += 1
            continue
        chosen = test_tr if decision == "tr" else test_en
        tested += 1
        agree += 2 * chosen >= test_tr + test_en
        weighted_total += test_tr + test_en
        weighted_agree += chosen
    print("Messages: %d (train %d, test %d)" % (len(ordered), split, len(ordered) - split))
    print("Rule: at least %d uses in the train messages and a %d%% share for one form (the profile rule)."
          % (MIN_COUNT, int(MIN_SHARE * 100)))
    print("Pairs: %d. Tested: %d." % (len(pairs), tested))
    print("Not tested: %d in the override file, %d not decided by the rule, %d with fewer than %d uses in the test messages."
          % (skipped_override, len(skipped_rule), skipped_test, MIN_TEST_COUNT))
    if skipped_rule:
        top = sorted(skipped_rule, reverse=True)[:10]
        print("Most used pairs that the rule did not decide: " + ", ".join(
            "%s/%s (%d)" % (turkish, english, total) for total, turkish, english in top))
    if not tested:
        print("Not enough data to evaluate.")
        return
    print("Agreement by pair: %d/%d (%.0f%%). A pair agrees when the profile form has at least half of its test uses."
          % (agree, tested, 100.0 * agree / tested))
    print("Agreement by use: %.0f%%" % (100.0 * weighted_agree / weighted_total))


# --- Export and import ----------------------------------------------------------

LANGUAGES = (("turkish", "Türkçe"), ("english", "İngilizce"))


def read_override():
    """Return {"turkish": [...], "english": [...]}: the words of local/override.md (or the template) as they are written."""
    words = {"turkish": [], "english": []}
    try:
        with open(override_read_path(), encoding="utf-8") as handle:
            for line in handle:
                match = OVERRIDE_LINE.match(line)
                if match:
                    side = "turkish" if match.group(1) == "Türkçe" else "english"
                    words[side].extend(word.strip() for word in match.group(2).split(",") if word.strip())
    except OSError:
        pass
    return words


def add_override_words(additions):
    """Add words to the "Türkçe yaz:" and "İngilizce yaz:" lines of local/override.md.

    The file is created from the template terms/override.md when it is missing.
    Every other line stays as it is. A missing line is added at the end of the file.
    """
    ensure_local_override()
    try:
        with open(OVERRIDE_FILE, encoding="utf-8") as handle:
            lines = handle.read().splitlines()
    except FileNotFoundError:
        lines = ["# Terim override'ları", ""]
    for side, label in LANGUAGES:
        if not additions.get(side):
            continue
        for index, line in enumerate(lines):
            match = OVERRIDE_LINE.match(line)
            if match and match.group(1) == label:
                words = [word.strip() for word in match.group(2).split(",") if word.strip()]
                lines[index] = "%s yaz: %s" % (label, ", ".join(words + additions[side]))
                break
        else:
            lines += ["", "%s yaz: %s" % (label, ", ".join(additions[side]))]
    write_atomic(OVERRIDE_FILE, "\n".join(lines) + "\n")


def counts_by_line(pairs, counts):
    return {pair["line"]: entry for pair, entry in zip(pairs, counts)}


def imported_problem(data):
    """Return why imported counts cannot be used, or None when their structure is valid."""
    if not isinstance(data, dict):
        return "the top level is not an object"
    if not isinstance(data.get("message_count"), int) or data["message_count"] < 0:
        return '"message_count" is not a number'
    if not isinstance(data.get("pairs"), dict):
        return '"pairs" is not an object'
    for line, entry in data["pairs"].items():
        if not (isinstance(line, str) and is_count_entry(entry)):
            return 'an entry of "pairs" has the wrong structure'
    return None


def load_imported():
    """Return (imported counts, problem). A missing file gives (None, None)."""
    try:
        with open(IMPORTED_FILE, encoding="utf-8") as handle:
            data = json.load(handle)
    except FileNotFoundError:
        return None, None
    except (OSError, ValueError, RecursionError) as error:
        return None, "cannot be read as JSON (%s)" % type(error).__name__
    problem = imported_problem(data)
    return (None, problem) if problem else (data, None)


def effective_counts(pairs, own, imported):
    """Return the own counts plus the imported counts of the same pairs."""
    total = [[entry[0], entry[1], list(entry[2]), list(entry[3])] for entry in own]
    if not imported:
        return total
    for pair, entry in zip(pairs, total):
        more = imported["pairs"].get(pair["line"])
        if more is None:
            continue
        entry[0] += more[0]
        entry[1] += more[1]
        # The form counts are added only when the pair has the same forms in both files.
        if len(more[2]) == len(entry[2]):
            entry[2] = [a + b for a, b in zip(entry[2], more[2])]
        if len(more[3]) == len(entry[3]):
            entry[3] = [a + b for a, b in zip(entry[3], more[3])]
    return total


def export_preferences(path, with_counts, pairs, counts, message_count):
    """Write the override terms and, with with_counts, the term counts to path. Return 0."""
    data = {
        "format": EXPORT_FORMAT,
        "version": EXPORT_VERSION,
        "exported": datetime.now().strftime("%Y-%m-%d"),
        "override": read_override(),
    }
    if with_counts:
        data["counts"] = {"message_count": message_count, "pairs": counts_by_line(pairs, counts)}
    write_atomic(os.path.abspath(path), json.dumps(data, ensure_ascii=False, indent=1) + "\n", private=True)
    print("Exported: %s" % path)
    override = data["override"]
    print("Override terms: %d Türkçe, %d İngilizce." % (len(override["turkish"]), len(override["english"])))
    if with_counts:
        print("Term counts: %d pairs from %d messages. The file has no message text." % (len(pairs), message_count))
    else:
        print("Term counts: not exported. Add --with-counts to export them.")
    return 0


def read_export(path):
    """Return the data of an export file. Raise ValueError with the reason when it is not valid."""
    try:
        with open(path, encoding="utf-8") as handle:
            data = json.load(handle)
    except OSError as error:
        raise ValueError("cannot read %s: %s" % (path, error.strerror or type(error).__name__))
    except (ValueError, RecursionError) as error:
        raise ValueError("%s is not valid JSON: %s" % (path, error))
    if not isinstance(data, dict) or data.get("format") != EXPORT_FORMAT:
        raise ValueError('%s is not a term preferences export (no "format": "%s")' % (path, EXPORT_FORMAT))
    if data.get("version") != EXPORT_VERSION:
        raise ValueError("%s has version %r. This script reads version %d." % (path, data.get("version"), EXPORT_VERSION))
    override = data.get("override")
    if not (isinstance(override, dict) and all(
            isinstance(override.get(side), list) and all(isinstance(word, str) and word.strip() for word in override[side])
            for side, _ in LANGUAGES)):
        raise ValueError('%s: "override" must have "turkish" and "english" lists of words' % path)
    if "counts" in data:
        problem = imported_problem(data["counts"])
        if problem:
            raise ValueError('%s: "counts": %s' % (path, problem))
    return data


def plan_override(file_override, local_override, pairs):
    """Return (additions, conflicts) for merging the override words of a file into the local ones.

    A word is a conflict when the local file lists the same concept for the
    other language: the same word, or another form of its pair in
    terms/pairs.tsv (for example "sil" and "delete"). The local choice stays.
    """
    local = {side: {word.lower() for word in local_override[side]} for side, _ in LANGUAGES}
    concept = {}
    for pair in pairs:
        words = {display_form(alt).lower() for alt in pair["turkish"] + pair["english"]}
        for word in words:
            concept.setdefault(word, set()).update(words)
    additions = {"turkish": [], "english": []}
    conflicts = []
    for side, label in LANGUAGES:
        other = "english" if side == "turkish" else "turkish"
        for word in file_override[side]:
            word = word.strip()
            key = word.lower()
            if key in local[side] or key in {w.lower() for w in additions[side]}:
                continue
            if (concept.get(key, set()) | {key}) & local[other]:
                conflicts.append((word, label, dict(LANGUAGES)[other]))
                continue
            additions[side].append(word)
    return additions, conflicts


def print_word_changes(title, words):
    if words:
        shown = words[:20]
        more = " and %d more" % (len(words) - 20) if len(words) > 20 else ""
        print("  %s: %s%s" % (title, ", ".join(shown), more))


def import_preferences(path, apply, pairs, own_counts, message_count, imported):
    """Show what an export file changes. With apply, make the changes. Return the exit code."""
    try:
        data = read_export(path)
    except ValueError as error:
        print("Import failed: %s" % error, file=sys.stderr)
        return 1
    local_override = read_override()
    additions, conflicts = plan_override(data["override"], local_override, pairs)
    new_imported = data.get("counts", imported)
    known_lines = {pair["line"] for pair in pairs}
    print("Import: %s (exported %s)" % (path, data.get("exported", "?")))
    print("local/override.md:")
    if not (additions["turkish"] or additions["english"] or conflicts):
        print("  no change")
    print_word_changes("add to Türkçe yaz", additions["turkish"])
    print_word_changes("add to İngilizce yaz", additions["english"])
    for word, file_side, local_side in conflicts:
        print("  conflict: %s is %s in the file and %s here. It stays %s." % (word, file_side, local_side, local_side))
    if "counts" in data:
        matched = len(known_lines & set(data["counts"]["pairs"]))
        unknown = len(data["counts"]["pairs"]) - matched
        print("Term counts: %d messages. %d pairs match terms/pairs.tsv, %d do not and are skipped."
              % (data["counts"]["message_count"], matched, unknown))
        if imported:
            print("  They replace the counts of the earlier import (%d messages)." % imported["message_count"])
    else:
        print("Term counts: none in the file. The counts of an earlier import stay.")
    old_override = {word.lower() for side, _ in LANGUAGES for word in local_override[side]}
    new_override = old_override | {word.lower() for side, _ in LANGUAGES for word in additions[side]}
    old_terms = profile_terms(results_from_counts(pairs, effective_counts(pairs, own_counts, imported)), old_override)
    new_terms = profile_terms(results_from_counts(pairs, effective_counts(pairs, own_counts, new_imported)), new_override)
    print("generated/term_profile.md:")
    changes = False
    for index, (_, label) in enumerate(LANGUAGES):
        added = [word for word in new_terms[index] if word not in old_terms[index]]
        removed = [word for word in old_terms[index] if word not in new_terms[index]]
        print_word_changes("new in %s yaz" % label, added)
        print_word_changes("no longer in %s yaz" % label, removed)
        changes = changes or bool(added or removed)
    if not changes:
        print("  no change")
    if not apply:
        print("Nothing was changed. Run the same command with --apply to make these changes.")
        return 0
    if additions["turkish"] or additions["english"]:
        add_override_words(additions)
    if "counts" in data:
        stored = dict(data["counts"], exported=data.get("exported", ""))
        write_atomic(IMPORTED_FILE, json.dumps(stored, ensure_ascii=False), private=True)
    results = results_from_counts(pairs, effective_counts(pairs, own_counts, new_imported))
    imported_count = new_imported["message_count"] if new_imported else 0
    write_profile(results, message_count, load_override_words(), imported_count)
    refresh_codex_rules()
    log("import applied from %s: %d override words, counts %s"
        % (path, len(additions["turkish"]) + len(additions["english"]), "replaced" if "counts" in data else "kept"))
    print("Applied.")
    if additions["turkish"] or additions["english"]:
        print("local/override.md is not in git. Use --export and --import to move it to another machine.")
    return 0


# --- Main -----------------------------------------------------------------------


def profile_is_fresh(max_age_days):
    """Return True if the profile is newer than max_age_days and newer than its inputs."""
    try:
        profile_time = os.path.getmtime(PROFILE_FILE)
    except OSError:
        return False
    if time.time() - profile_time > max_age_days * 86400:
        return False
    for path in (PAIRS_FILE, override_read_path(), IMPORTED_FILE):
        if os.path.exists(path) and os.path.getmtime(path) > profile_time:
            return False
    return True


def last_run_error():
    """Return the log line of the last run when that run failed, else None."""
    try:
        with open(LOG_FILE, encoding="utf-8", errors="replace") as handle:
            lines = handle.read().splitlines()
    except OSError:
        return None
    for line in reversed(lines):
        parts = line.split(" ", 2)
        if len(parts) < 2:
            continue
        if parts[1] == "error:":
            return line
        if parts[1] == "profile":
            return None
    return None


def check():
    """Print the state of the cache and of the last run. Change nothing. Return 1 on a problem."""
    problems = 0
    print("Term profile cache: %s" % CACHE_DIR)
    if not os.path.isdir(CACHE_DIR):
        print("  missing   the cache folder. The next run builds it.")
    elif not os.access(CACHE_DIR, os.R_OK | os.X_OK):
        print("  WARNING   the cache folder cannot be read. Check its owner and mode.")
        problems += 1
    else:
        mode = stat.S_IMODE(os.stat(CACHE_DIR).st_mode)
        if mode != DIR_MODE:
            print("  WARNING   folder mode %o (want 700). The next run sets it." % mode)
            problems += 1
        for name in sorted(os.listdir(CACHE_DIR)):
            info = os.lstat(os.path.join(CACHE_DIR, name))
            if stat.S_ISREG(info.st_mode) and stat.S_IMODE(info.st_mode) != FILE_MODE:
                print("  WARNING   %s: mode %o (want 600). The next run sets it." % (name, stat.S_IMODE(info.st_mode)))
                problems += 1
        cache, problem = read_cache_file()
        if problem:
            print("  WARNING   messages.json: %s. The next run moves it aside and builds it again." % problem)
            problems += 1
        elif cache is None:
            print("  missing   messages.json. The next run builds it.")
        elif cache.get("clean_version") != CLEAN_VERSION:
            print("  NOTE      messages.json has clean version %r, not %d. The next run builds it again."
                  % (cache.get("clean_version"), CLEAN_VERSION))
        else:
            print("  ok        messages.json: %d messages from %d transcripts" % (len(cache["messages"]), len(cache["files"])))
            try:
                pairs = load_pairs()
                problem = counts_problem(cache.get("counts"), pairs_key(), len(pairs), len(cache["messages"]))
            except (OSError, ValueError, re.error) as error:
                problem = "terms/pairs.tsv cannot be read (%s)" % error
            if problem:
                print("  NOTE      term counts: %s. The next run counts all messages again." % problem)
            else:
                print("  ok        term counts: up to date for %d messages" % len(cache["messages"]))
        imported, problem = load_imported()
        if problem:
            print("  WARNING   imported_counts.json: %s. Runs ignore it. Run --import again or delete it." % problem)
            problems += 1
        elif imported:
            print("  ok        imported_counts.json: %d messages from an export of %s"
                  % (imported["message_count"], imported.get("exported") or "an unknown date"))
        for name in sorted(os.listdir(CACHE_DIR)):
            if os.path.join(CACHE_DIR, name).startswith(BROKEN_PREFIX):
                print("  NOTE      %s: a broken cache that a run set aside. Its messages are not counted." % name)
                print("            Delete it when you do not need it.")
    error = last_run_error()
    if error:
        # The log line is "<time> error: <traceback with " | " for each line break>".
        # Its last part names the exception.
        last = [part for part in error.split(" | ") if part.strip()][-1].strip()
        print("  WARNING   the last run failed at %s: %s" % (error.split(" ", 1)[0], last[:200]))
        print("            Details: %s" % LOG_FILE)
        problems += 1
    try:
        # Turkey time (UTC+3 all year), whatever the time zone of this machine.
        written = datetime.fromtimestamp(os.path.getmtime(PROFILE_FILE) + TR_OFFSET, timezone.utc).strftime("%Y-%m-%d %H:%M")
        print("  ok        %s written %s TR" % (os.path.relpath(PROFILE_FILE, REPO_DIR), written))
    except OSError:
        print("  missing   %s. Run scripts/term_profile.py." % os.path.relpath(PROFILE_FILE, REPO_DIR))
        problems += 1
    return 1 if problems else 0


def run(args):
    secure_cache_dir()
    if args.max_age_days is not None and profile_is_fresh(args.max_age_days):
        return 0
    make_cache_dir()
    with open_private(LOCK_FILE, os.O_WRONLY | os.O_CREAT) as lock:
        try:
            fcntl.flock(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
        except OSError:
            if args.export or args.import_file:
                print("Another run of term_profile.py is working. Try again in a minute.", file=sys.stderr)
                return 1
            # Another run holds the lock. That run writes the profile.
            return 0
        pairs = load_pairs()
        cache = update_cache(pairs)
        messages = list(cache["messages"].values())
        override_words = load_override_words()
        if args.evaluate:
            evaluate(pairs, messages, override_words)
            return 0
        imported, problem = load_imported()
        if problem:
            log("imported_counts.json ignored: %s" % problem)
        own_counts = cache["counts"]["pairs"]
        if args.import_file:
            return import_preferences(args.import_file, args.apply, pairs, own_counts, len(messages), imported)
        counts = effective_counts(pairs, own_counts, imported)
        imported_count = imported["message_count"] if imported else 0
        if args.export:
            return export_preferences(args.export, args.with_counts, pairs, counts, len(messages) + imported_count)
        results = results_from_counts(pairs, counts)
        if args.report:
            print_report(results)
        kept = profile_message_count()
        if not messages and not imported_count and kept:
            note = ("profile kept: this run found 0 messages, the profile was built from %d. "
                    "Check HOME, CLAUDE_CONFIG_DIR and XDG_CACHE_HOME." % kept)
            log(note)
            if not args.quiet:
                print("Profile: %s (not changed)" % PROFILE_FILE)
                print(note[0].upper() + note[1:])
            return 0
        turkish, english = write_profile(results, len(messages), override_words, imported_count)
        refresh_codex_rules()
    imported_note = " and %d imported" % imported_count if imported_count else ""
    log("profile written: %d messages%s, %d Turkish, %d English" % (len(messages), imported_note, turkish, english))
    if not args.quiet:
        print("Profile: %s" % PROFILE_FILE)
        print("Messages: %d%s. Turkish terms: %d. English terms: %d." % (len(messages), imported_note, turkish, english))
    return 0


def main():
    parser = argparse.ArgumentParser(description="Build a term-language profile from your Claude Code messages.")
    parser.add_argument("--max-age-days", type=float, help="do nothing if the profile is newer than this")
    parser.add_argument("--quiet", action="store_true", help="print nothing (for the SessionStart hook)")
    parser.add_argument("--report", action="store_true", help="print the counts for every pair")
    parser.add_argument("--evaluate", action="store_true", help="test old messages against new messages")
    parser.add_argument("--check", action="store_true", help="show the state of the cache and the last run; change nothing")
    parser.add_argument("--export", metavar="FILE", help="write the override terms to FILE")
    parser.add_argument("--with-counts", action="store_true", help="with --export: write the term counts too")
    parser.add_argument("--import", dest="import_file", metavar="FILE", help="show what an export file changes")
    parser.add_argument("--apply", action="store_true", help="with --import: make the changes")
    args = parser.parse_args()
    modes = [name for name, value in (("--check", args.check), ("--evaluate", args.evaluate),
                                      ("--export", args.export), ("--import", args.import_file)) if value]
    if len(modes) > 1:
        parser.error("use only one of %s" % ", ".join(modes))
    if args.with_counts and not args.export:
        parser.error("--with-counts needs --export")
    if args.apply and not args.import_file:
        parser.error("--apply needs --import")
    if args.check:
        return check()
    try:
        return run(args)
    except Exception:
        log("error: " + traceback.format_exc().replace("\n", " | "))
        if args.quiet:
            # A failure must not show text in the session. The log file keeps the details.
            return 0
        raise


if __name__ == "__main__":
    sys.exit(main())
