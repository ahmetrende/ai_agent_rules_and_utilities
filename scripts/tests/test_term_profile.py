#!/usr/bin/env python3
"""Tests for scripts/term_profile.py.

Each test copies the script to a temporary repo with a small terms/pairs.tsv.
HOME, CLAUDE_CONFIG_DIR and XDG_CACHE_HOME point into the temporary folder,
so the tests never read or write your real cache or transcripts.

Run: python3 -m unittest discover -s scripts/tests -p 'test_*.py'
"""

import json
import os
import shutil
import stat
import subprocess
import sys
import tempfile
import unittest

SCRIPT = os.path.join(os.path.dirname(os.path.dirname(os.path.abspath(__file__))), "term_profile.py")

PAIRS = "dosya\tfile\nklasör\tfolder|directory\nsil\tdelete\nkod\tcode\n"
OVERRIDE = "# Terim override'ları\n\nTürkçe yaz:\n\nİngilizce yaz:\n"


class TermProfileTest(unittest.TestCase):
    def setUp(self):
        self.root = tempfile.mkdtemp(prefix="tp-test-")
        self.repo = os.path.join(self.root, "repo")
        os.makedirs(os.path.join(self.repo, "scripts"))
        os.makedirs(os.path.join(self.repo, "terms"))
        shutil.copy(SCRIPT, os.path.join(self.repo, "scripts", "term_profile.py"))
        self.write(os.path.join(self.repo, "terms", "pairs.tsv"), PAIRS)
        self.write(os.path.join(self.repo, "terms", "override.md"), OVERRIDE)
        self.claude = os.path.join(self.root, "claude")
        self.projects = os.path.join(self.claude, "projects", "p")
        os.makedirs(self.projects)
        self.cache_home = os.path.join(self.root, "cache")
        self.cache_dir = os.path.join(self.cache_home, "ai_agent_rules")
        self.cache_file = os.path.join(self.cache_dir, "messages.json")
        self.profile = os.path.join(self.repo, "generated", "term_profile.md")
        self.transcripts = 0

    def tearDown(self):
        shutil.rmtree(self.root, ignore_errors=True)

    # --- helpers

    @staticmethod
    def write(path, text):
        os.makedirs(os.path.dirname(path), exist_ok=True)
        with open(path, "w", encoding="utf-8") as handle:
            handle.write(text)

    @staticmethod
    def read(path):
        with open(path, encoding="utf-8") as handle:
            return handle.read()

    def add_transcript(self, texts, day="2026-11-01"):
        """Write one transcript with one user message for each text."""
        self.transcripts += 1
        lines = []
        for index, text in enumerate(texts):
            lines.append(json.dumps({
                "type": "user",
                "timestamp": "%sT10:%02d:00.000Z" % (day, index % 60),
                "message": {"role": "user", "content": text},
            }, ensure_ascii=False))
        self.write(os.path.join(self.projects, "s%d.jsonl" % self.transcripts), "\n".join(lines) + "\n")

    def run_script(self, *args):
        env = dict(os.environ, HOME=self.root, CLAUDE_CONFIG_DIR=self.claude, XDG_CACHE_HOME=self.cache_home)
        return subprocess.run([sys.executable, os.path.join(self.repo, "scripts", "term_profile.py")] + list(args),
                              env=env, stdout=subprocess.PIPE, stderr=subprocess.PIPE, universal_newlines=True)

    def cache(self):
        with open(self.cache_file, encoding="utf-8") as handle:
            return json.load(handle)

    def profile_lines(self):
        lines = self.read(self.profile).splitlines()
        return [line for line in lines if line.startswith(("Türkçe yaz:", "İngilizce yaz:"))]

    def turkish_messages(self, count, start=0):
        # Each message: dosya once, file once in every third, folder twice, sil once.
        texts = []
        for number in range(start, start + count):
            extra = " bir file daha" if number % 3 == 0 else ""
            texts.append("bu dosya %d için folder ve folder lazım, sonra sil%s" % (number, extra))
        return texts

    # --- B13: incremental counts

    def test_incremental_counts_equal_full_count(self):
        self.add_transcript(self.turkish_messages(12))
        result = self.run_script()
        self.assertEqual(result.returncode, 0, result.stderr)
        self.add_transcript(self.turkish_messages(9, start=100), day="2026-11-02")
        self.assertEqual(self.run_script().returncode, 0)
        incremental = self.cache()["counts"]
        incremental_profile = self.profile_lines()
        # Remove the counts: the next run counts all messages again.
        data = self.cache()
        del data["counts"]
        self.write(self.cache_file, json.dumps(data, ensure_ascii=False))
        self.assertEqual(self.run_script().returncode, 0)
        full = self.cache()["counts"]
        self.assertEqual(incremental["pairs"], full["pairs"])
        self.assertEqual(incremental["message_count"], 21)
        self.assertEqual(full["message_count"], 21)
        self.assertEqual(incremental_profile, self.profile_lines())
        # dosya: 21 Turkish uses, file: 4 + 3 English uses.
        self.assertEqual(full["pairs"][0][:2], [21, 7])
        # folder|directory: two English forms, so the form counts are kept.
        self.assertEqual(full["pairs"][1], [0, 42, [], [42, 0]])

    def test_unchanged_run_does_not_write_the_cache(self):
        self.add_transcript(self.turkish_messages(12))
        self.run_script()
        before = os.stat(self.cache_file).st_mtime_ns
        content = self.read(self.cache_file)
        result = self.run_script()
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(os.stat(self.cache_file).st_mtime_ns, before)
        self.assertEqual(self.read(self.cache_file), content)

    def test_changed_pairs_file_counts_again(self):
        self.add_transcript(self.turkish_messages(12))
        self.run_script()
        old_key = self.cache()["counts"]["key"]
        self.write(os.path.join(self.repo, "terms", "pairs.tsv"), PAIRS + "lazım\tneeded\n")
        result = self.run_script()
        self.assertEqual(result.returncode, 0, result.stderr)
        counts = self.cache()["counts"]
        self.assertNotEqual(counts["key"], old_key)
        self.assertEqual(len(counts["pairs"]), 5)
        self.assertEqual(counts["pairs"][4][:2], [12, 0])

    def test_stale_counts_from_an_older_version_are_built_again(self):
        self.add_transcript(self.turkish_messages(12))
        self.run_script()
        data = self.cache()
        # An older script version added a message without updating the counts.
        data["messages"]["x" * 40] = ["2026-11-03T00:00:00Z", "bu dosya ve dosya"]
        self.write(self.cache_file, json.dumps(data, ensure_ascii=False))
        result = self.run_script("--check")
        self.assertIn("term counts: the counts are for 12 messages, not 13", result.stdout)
        self.assertEqual(result.returncode, 0, result.stdout)
        self.run_script()
        counts = self.cache()["counts"]
        self.assertEqual(counts["message_count"], 13)
        self.assertEqual(counts["pairs"][0][0], 14)
        self.assertIn("ok        term counts: up to date for 13 messages", self.run_script("--check").stdout)

    def test_broken_counts_are_built_again(self):
        self.add_transcript(self.turkish_messages(12))
        self.run_script()
        data = self.cache()
        data["counts"]["pairs"][0] = ["a", 1, [], []]
        self.write(self.cache_file, json.dumps(data, ensure_ascii=False))
        result = self.run_script()
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(self.cache()["counts"]["pairs"][0][:2], [12, 4])

    # --- B18: --evaluate uses the profile rule

    def test_evaluate_uses_the_profile_rule_and_override(self):
        # Train: the first 70% of messages (by time). dosya 14 times, kod 3 times.
        train = ["bu dosya %d için kod yaz" % n if n < 3 else "bu dosya %d tamam" % n for n in range(14)]
        test = ["bu dosya %d yeni, file da var" % n for n in range(6)]
        self.add_transcript(train, day="2026-11-01")
        self.add_transcript(test, day="2026-11-05")
        self.write(os.path.join(self.repo, "local", "override.md"), "Türkçe yaz:\n\nİngilizce yaz: folder\n")
        result = self.run_script("--evaluate")
        self.assertEqual(result.returncode, 0, result.stderr)
        out = result.stdout
        self.assertIn("Pairs: 4. Tested: 1.", out)
        self.assertIn("Not tested: 1 in the override file, 1 not decided by the rule", out)
        self.assertIn("kod/code (3)", out)
        # dosya: profile says Turkish. Test: 6 Turkish, 6 English uses: half, so it agrees.
        self.assertIn("Agreement by pair: 1/1 (100%)", out)
        self.assertIn("Agreement by use: 50%", out)

    # --- O04: export and import

    def test_export_without_counts_has_no_counts(self):
        self.add_transcript(self.turkish_messages(12))
        self.write(os.path.join(self.repo, "local", "override.md"), "Türkçe yaz: dosya\n\nİngilizce yaz: code\n")
        target = os.path.join(self.root, "prefs.json")
        result = self.run_script("--export", target)
        self.assertEqual(result.returncode, 0, result.stderr)
        data = json.loads(self.read(target))
        self.assertEqual(data["format"], "ai_agent_rules term preferences")
        self.assertEqual(data["version"], 1)
        self.assertEqual(data["override"], {"turkish": ["dosya"], "english": ["code"]})
        self.assertNotIn("counts", data)
        self.assertEqual(stat.S_IMODE(os.stat(target).st_mode), 0o600)

    def test_export_with_counts_has_no_message_text(self):
        self.add_transcript(["bu dosya gizlisözcük için lazım"] + self.turkish_messages(11))
        target = os.path.join(self.root, "prefs.json")
        result = self.run_script("--export", target, "--with-counts")
        self.assertEqual(result.returncode, 0, result.stderr)
        text = self.read(target)
        self.assertNotIn("gizlisözcük", text)
        data = json.loads(text)
        self.assertEqual(data["counts"]["message_count"], 12)
        self.assertEqual(data["counts"]["pairs"]["dosya\tfile"][:2], [12, 4])

    def test_import_preview_changes_nothing_and_apply_merges(self):
        # Machine A: messages and override.
        self.add_transcript(self.turkish_messages(12))
        self.write(os.path.join(self.repo, "local", "override.md"), "Türkçe yaz: kod, sil\n\nİngilizce yaz: folder\n")
        export = os.path.join(self.root, "prefs.json")
        self.assertEqual(self.run_script("--export", export, "--with-counts").returncode, 0)
        # Machine B: no messages, its own override with a conflict.
        shutil.rmtree(self.cache_dir)
        shutil.rmtree(os.path.join(self.claude, "projects"))
        os.makedirs(self.projects)
        override_b = "# B\n\nTürkçe yaz: folder\n\nİngilizce yaz: delete\n"
        override_path = os.path.join(self.repo, "local", "override.md")
        self.write(override_path, override_b)
        preview = self.run_script("--import", export)
        self.assertEqual(preview.returncode, 0, preview.stderr)
        self.assertIn("add to Türkçe yaz: kod", preview.stdout)
        self.assertIn("conflict: sil is Türkçe in the file and İngilizce here. It stays İngilizce.", preview.stdout)
        self.assertIn("conflict: folder is İngilizce in the file and Türkçe here. It stays Türkçe.", preview.stdout)
        self.assertIn("new in Türkçe yaz: dosya", preview.stdout)
        self.assertIn("Nothing was changed.", preview.stdout)
        self.assertEqual(self.read(override_path), override_b)
        self.assertFalse(os.path.exists(os.path.join(self.cache_dir, "imported_counts.json")))
        applied = self.run_script("--import", export, "--apply")
        self.assertEqual(applied.returncode, 0, applied.stderr)
        self.assertEqual(self.read(override_path), "# B\n\nTürkçe yaz: folder, kod\n\nİngilizce yaz: delete\n")
        imported = os.path.join(self.cache_dir, "imported_counts.json")
        self.assertEqual(stat.S_IMODE(os.stat(imported).st_mode), 0o600)
        profile = self.read(self.profile)
        self.assertIn("Kaynak: 12 mesaj (0 bu makineden, 12 aktarılan)", profile)
        self.assertIn("Türkçe yaz: dosya", profile)
        # A normal run keeps the imported counts in the profile.
        result = self.run_script()
        self.assertIn("Messages: 0 and 12 imported.", result.stdout)
        self.assertIn("Türkçe yaz: dosya", self.read(self.profile))
        self.assertIn("ok        imported_counts.json: 12 messages", self.run_script("--check").stdout)

    def test_local_override_is_preferred_over_the_template(self):
        self.add_transcript(self.turkish_messages(12))
        self.write(os.path.join(self.repo, "terms", "override.md"), "Türkçe yaz: kod\n\nİngilizce yaz:\n")
        self.write(os.path.join(self.repo, "local", "override.md"), "Türkçe yaz: sil\n\nİngilizce yaz:\n")
        target = os.path.join(self.root, "prefs.json")
        self.assertEqual(self.run_script("--export", target).returncode, 0)
        self.assertEqual(json.loads(self.read(target))["override"], {"turkish": ["sil"], "english": []})

    def test_template_is_used_when_local_override_is_missing(self):
        self.add_transcript(self.turkish_messages(12))
        self.write(os.path.join(self.repo, "terms", "override.md"), "Türkçe yaz: kod\n\nİngilizce yaz:\n")
        self.assertFalse(os.path.exists(os.path.join(self.repo, "local", "override.md")))
        target = os.path.join(self.root, "prefs.json")
        self.assertEqual(self.run_script("--export", target).returncode, 0)
        self.assertEqual(json.loads(self.read(target))["override"], {"turkish": ["kod"], "english": []})
        self.assertFalse(os.path.exists(os.path.join(self.repo, "local", "override.md")))

    def test_import_apply_creates_local_override_from_the_template(self):
        template = os.path.join(self.repo, "terms", "override.md")
        local = os.path.join(self.repo, "local", "override.md")
        export = os.path.join(self.root, "prefs.json")
        self.write(export, json.dumps({"format": "ai_agent_rules term preferences", "version": 1,
                                       "override": {"turkish": ["kod"], "english": []}}))
        self.assertFalse(os.path.exists(local))
        result = self.run_script("--import", export, "--apply")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn("local/override.md is not in git", result.stdout)
        self.assertEqual(self.read(local), "# Terim override'ları\n\nTürkçe yaz: kod\n\nİngilizce yaz:\n")
        self.assertEqual(self.read(template), OVERRIDE)

    def test_import_rejects_a_wrong_file(self):
        bad = os.path.join(self.root, "bad.json")
        self.write(bad, json.dumps({"format": "something else", "version": 1}))
        override_path = os.path.join(self.repo, "terms", "override.md")
        result = self.run_script("--import", bad, "--apply")
        self.assertEqual(result.returncode, 1)
        self.assertIn("is not a term preferences export", result.stderr)
        self.assertEqual(self.read(override_path), OVERRIDE)
        self.write(bad, json.dumps({"format": "ai_agent_rules term preferences", "version": 2,
                                    "override": {"turkish": [], "english": []}}))
        result = self.run_script("--import", bad)
        self.assertEqual(result.returncode, 1)
        self.assertIn("has version 2", result.stderr)

    def test_broken_imported_file_is_a_check_warning(self):
        os.makedirs(self.cache_dir, mode=0o700)
        self.write(os.path.join(self.cache_dir, "imported_counts.json"), "{not json")
        result = self.run_script("--check")
        self.assertEqual(result.returncode, 1)
        self.assertIn("WARNING   imported_counts.json", result.stdout)

    def test_options_that_do_not_go_together(self):
        self.assertEqual(self.run_script("--with-counts").returncode, 2)
        self.assertEqual(self.run_script("--apply").returncode, 2)
        self.assertEqual(self.run_script("--export", "a.json", "--evaluate").returncode, 2)


if __name__ == "__main__":
    unittest.main()
