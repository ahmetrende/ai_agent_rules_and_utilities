import json
import os
import subprocess
import sys
import tempfile
import time
import unittest
from unittest import mock

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)
import sessions  # noqa: E402

SCRIPT = os.path.join(HERE, "sessions.py")
# 2023-11-14 22:13:20 UTC is 2023-11-15 01:13 in Turkey.
OLD_EPOCH = 1700000000


def write(path, text, mtime=None):
    os.makedirs(os.path.dirname(path), exist_ok=True)
    with open(path, "w", encoding="utf-8") as handle:
        handle.write(text)
    if mtime is not None:
        os.utime(path, (mtime, mtime))


def transcript(*records):
    return "\n".join(json.dumps(r) for r in records) + "\n"


class Base(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self.tmp.cleanup)
        self.root = os.path.realpath(self.tmp.name)
        self.cfg = os.path.join(self.root, "cfg")
        self.work = os.path.join(self.root, "work")
        os.makedirs(self.cfg)
        os.makedirs(self.work)
        patcher = mock.patch.dict(
            os.environ,
            {"CLAUDE_CONFIG_DIR": self.cfg, "AI_AGENT_RULES_DIR": os.path.join(self.root, "repo")},
        )
        patcher.start()
        self.addCleanup(patcher.stop)

    def session_file(self, sid, *records, mtime=None, project="-p"):
        path = os.path.join(self.cfg, "projects", project, sid + ".jsonl")
        write(path, transcript(*records), mtime)
        return path


class ScanTests(Base):
    def test_titles_cwd_and_branch_use_the_newest_value(self):
        self.session_file(
            "s1",
            {"type": "ai-title", "aiTitle": "Old ai title"},
            {"type": "user", "cwd": "/a/old", "gitBranch": "old"},
            {"type": "custom-title", "customTitle": "Mine \"quoted\""},
            {"type": "ai-title", "aiTitle": "New ai title"},
            {"type": "user", "cwd": "/a/new proj", "gitBranch": "main"},
        )
        data = sessions.collect_local(3)
        self.assertEqual(len(data["sessions"]), 1)
        item = data["sessions"][0]
        self.assertEqual(item["sessionId"], "s1")
        self.assertEqual(item["title"], 'Mine "quoted"')
        self.assertEqual(item["cwd"], "/a/new proj")
        self.assertEqual(item["project"], "new proj")
        self.assertEqual(item["gitBranch"], "main")
        self.assertGreater(item["sizeBytes"], 0)
        self.assertIsNone(item["handoff"])

    def test_ai_title_is_used_without_custom_title(self):
        self.session_file("s1", {"aiTitle": "First"}, {"aiTitle": "Second"}, {"cwd": "/x"})
        self.assertEqual(sessions.collect_local(3)["sessions"][0]["title"], "Second")

    def test_subagent_files_old_files_and_bad_lines(self):
        self.session_file("top", {"cwd": "/x"})
        sub = os.path.join(self.cfg, "projects", "-p", "top", "subagents", "agent-1.jsonl")
        write(sub, transcript({"cwd": "/sub"}))
        self.session_file("old", {"cwd": "/x"}, mtime=time.time() - 10 * 86400)
        path = os.path.join(self.cfg, "projects", "-p", "bad.jsonl")
        write(path, 'not json "cwd":"/bad\n{"cwd":"/good","aiTitle":"T"}\n\x00\xff garbage\n')
        data = sessions.collect_local(3)
        ids = sorted(item["sessionId"] for item in data["sessions"])
        self.assertEqual(ids, ["bad", "top"])
        bad = [item for item in data["sessions"] if item["sessionId"] == "bad"][0]
        self.assertEqual(bad["cwd"], "/good")

    def test_days_widens_the_window_and_sorts_newest_first(self):
        self.session_file("older", {"cwd": "/x"}, mtime=time.time() - 5 * 86400)
        self.session_file("newer", {"cwd": "/x"})
        self.assertEqual([s["sessionId"] for s in sessions.collect_local(3)["sessions"]], ["newer"])
        self.assertEqual(
            [s["sessionId"] for s in sessions.collect_local(7)["sessions"]], ["newer", "older"]
        )


class HandoffTests(Base):
    def handoff_text(self):
        return "# Devir: kart akışı\n\nYazıldı.\n\n## READ FIRST\n\n\nİlk okunacak satır.\nİkinci satır.\n"

    def test_handoff_in_cwd_with_detail_and_dump(self):
        cwd = os.path.join(self.work, "proj")
        path = os.path.join(cwd, ".claude", "2026-11-23-handoff-s1.md")
        write(path, self.handoff_text(), OLD_EPOCH)
        write(path[:-3] + ".detay.md", "detay")
        write(os.path.join(self.cfg, "handoff-dumps", "2026-11-23-handoff-s1.transcript.md"), "x")
        self.session_file("s1", {"cwd": cwd})
        handoff = sessions.collect_local(3)["sessions"][0]["handoff"]
        self.assertEqual(handoff["path"], path)
        self.assertEqual(handoff["writtenAt"], OLD_EPOCH)
        self.assertEqual(handoff["title"], "Devir: kart akışı")
        self.assertEqual(handoff["readFirst"], "İlk okunacak satır.")
        self.assertTrue(handoff["detail"]["exists"])
        self.assertTrue(handoff["detail"]["path"].endswith("-handoff-s1.detay.md"))
        self.assertTrue(handoff["dump"]["exists"])

    def test_missing_detail_and_dump_and_plain_name(self):
        cwd = os.path.join(self.work, "proj")
        write(os.path.join(cwd, ".claude", "handoff-s2.md"), "# T\n\n## READ FIRST\nOnly line\n")
        self.session_file("s2", {"cwd": cwd})
        handoff = sessions.collect_local(3)["sessions"][0]["handoff"]
        self.assertFalse(handoff["detail"]["exists"])
        self.assertFalse(handoff["dump"]["exists"])
        self.assertEqual(handoff["readFirst"], "Only line")

    def test_read_first_is_cut_at_200(self):
        cwd = os.path.join(self.work, "proj")
        write(os.path.join(cwd, ".claude", "a-handoff-s3.md"), "# T\n## READ FIRST\n" + "x" * 500 + "\n")
        self.session_file("s3", {"cwd": cwd})
        handoff = sessions.collect_local(3)["sessions"][0]["handoff"]
        self.assertEqual(len(handoff["readFirst"]), 200)

    def test_newest_handoff_wins(self):
        cwd = os.path.join(self.work, "proj")
        write(os.path.join(cwd, ".claude", "a-handoff-s4.md"), "# Old\n", OLD_EPOCH)
        write(os.path.join(cwd, ".claude", "b-handoff-s4.md"), "# New\n", OLD_EPOCH + 100)
        self.session_file("s4", {"cwd": cwd})
        handoff = sessions.collect_local(3)["sessions"][0]["handoff"]
        self.assertEqual(handoff["title"], "New")

    def test_worktree_cwd_also_looks_in_the_base_repo(self):
        base = os.path.join(self.work, "repo")
        cwd = os.path.join(base, ".claude", "worktrees", "feature-x")
        os.makedirs(cwd)
        write(os.path.join(base, ".claude", "z-handoff-s5.md"), "# Base\n## READ FIRST\nfrom base\n")
        self.session_file("s5", {"cwd": cwd})
        handoff = sessions.collect_local(3)["sessions"][0]["handoff"]
        self.assertEqual(handoff["readFirst"], "from base")
        self.assertEqual(sessions.handoff_dirs(cwd)[1], os.path.join(base, ".claude"))

    def test_other_session_handoff_is_not_matched(self):
        cwd = os.path.join(self.work, "proj")
        write(os.path.join(cwd, ".claude", "a-handoff-other.md"), "# Other\n")
        write(os.path.join(cwd, ".claude", "a-handoff-s6.detay.md"), "# Detail only\n")
        self.session_file("s6", {"cwd": cwd})
        self.assertIsNone(sessions.collect_local(3)["sessions"][0]["handoff"])


class MachinesTests(Base):
    def test_parse_machines(self):
        text = (
            "Intro line.\n\n"
            "- ubuntu: `ssh user@10.0.0.1`, repo yolu `~/Developer/ai_agent_rules`\n"
            "- Mac Mini: `ssh -p 2222 user@host`, repo yolu `/srv/my repo`\n"
            "- broken line without the format\n"
        )
        machines, notes = sessions.parse_machines(text)
        self.assertEqual(
            machines,
            [
                ("ubuntu", "user@10.0.0.1", "~/Developer/ai_agent_rules"),
                ("Mac Mini", "-p 2222 user@host", "/srv/my repo"),
            ],
        )
        self.assertEqual(len(notes), 1)
        self.assertIn("broken line", notes[0])

    def test_remote_cd_path(self):
        self.assertEqual(sessions.remote_cd_path("~/x y"), "\"$HOME\"/'x y'")
        self.assertEqual(sessions.remote_cd_path("~"), '"$HOME"')
        self.assertEqual(sessions.remote_cd_path("/srv/my repo"), "'/srv/my repo'")

    def test_fetch_remote_builds_the_ssh_command(self):
        payload = json.dumps({"host": "box", "generated": 1, "sessions": [{"sessionId": "a"}]})
        done = subprocess.CompletedProcess([], 0, stdout="banner\n" + payload + "\n", stderr="")
        with mock.patch.object(sessions.subprocess, "run", return_value=done) as run:
            result = sessions.fetch_remote(("box", "-p 22 u@h", "~/repo"), 5)
        argv = run.call_args[0][0]
        self.assertEqual(argv[:6], ["ssh", "-n", "-o", "BatchMode=yes", "-o", "ConnectTimeout=10"])
        self.assertEqual(argv[6:9], ["-p", "22", "u@h"])
        self.assertIn('cd "$HOME"/repo && python3 local-mods/oturum/bin/sessions.py --json --days 5', argv[-1])
        self.assertTrue(result["ok"])
        self.assertEqual(result["sessions"], [{"sessionId": "a"}])

    def test_fetch_remote_failure_keeps_first_stderr_line(self):
        done = subprocess.CompletedProcess([], 255, stdout="", stderr="\nPermission denied (publickey).\nmore\n")
        with mock.patch.object(sessions.subprocess, "run", return_value=done):
            result = sessions.fetch_remote(("box", "u@h", "~/repo"), 3)
        self.assertFalse(result["ok"])
        self.assertEqual(result["error"], "Permission denied (publickey).")
        self.assertEqual(result["sessions"], [])

    def test_fetch_remote_bad_output(self):
        done = subprocess.CompletedProcess([], 0, stdout="hello\n", stderr="")
        with mock.patch.object(sessions.subprocess, "run", return_value=done):
            result = sessions.fetch_remote(("box", "u@h", "~/repo"), 3)
        self.assertFalse(result["ok"])
        self.assertTrue(result["error"])

    def test_collect_all_without_machines_file_is_a_note(self):
        os.makedirs(os.path.join(self.root, "repo"))
        data = sessions.collect_all(3)
        self.assertEqual(len(data["machines"]), 1)
        self.assertTrue(data["machines"][0]["ok"])
        self.assertEqual(len(data["notes"]), 1)

    def test_collect_all_reads_machines_file_and_survives_a_failure(self):
        write(
            os.path.join(self.root, "repo", "local", "machines.md"),
            "- one: `ssh a@b`, repo yolu `~/r`\n- two: `ssh c@d`, repo yolu `~/r`\n",
        )
        good = json.dumps({"host": "two", "generated": 1, "sessions": []})

        def fake_run(argv, **kwargs):
            if "a@b" in argv:
                return subprocess.CompletedProcess(argv, 255, stdout="", stderr="no route\n")
            return subprocess.CompletedProcess(argv, 0, stdout=good + "\n", stderr="")

        with mock.patch.object(sessions.subprocess, "run", side_effect=fake_run):
            data = sessions.collect_all(3)
        names = [m["name"] for m in data["machines"]]
        self.assertEqual(names[1:], ["one", "two"])
        self.assertFalse(data["machines"][1]["ok"])
        self.assertEqual(data["machines"][1]["error"], "no route")
        self.assertTrue(data["machines"][2]["ok"])
        self.assertEqual(data["notes"], [])


class RepoDirTests(Base):
    def test_env_wins(self):
        self.assertEqual(sessions.repo_dir(self.cfg), os.path.join(self.root, "repo"))

    def test_claude_md_import_line(self):
        del os.environ["AI_AGENT_RULES_DIR"]
        write(
            os.path.join(self.cfg, "CLAUDE.md"),
            "@~/Developer/ai_agent_rules/skills/x/SKILL.md\n@~/Developer/ai_agent_rules/AGENTS.md\n",
        )
        self.assertEqual(
            sessions.repo_dir(self.cfg), os.path.expanduser("~/Developer/ai_agent_rules")
        )

    def test_none_when_nothing_matches_and_script_is_elsewhere(self):
        del os.environ["AI_AGENT_RULES_DIR"]
        with mock.patch.object(sessions, "SCRIPT", os.path.join(self.root, "a", "b", "c", "d.py")):
            self.assertIsNone(sessions.repo_dir(self.cfg))

    def test_script_place_fallback(self):
        del os.environ["AI_AGENT_RULES_DIR"]
        repo = os.path.join(self.root, "r")
        write(os.path.join(repo, "AGENTS.md"), "x")
        script = os.path.join(repo, "local-mods", "oturum", "bin", "sessions.py")
        with mock.patch.object(sessions, "SCRIPT", script):
            self.assertEqual(sessions.repo_dir(self.cfg), repo)


class TextTests(Base):
    def session(self, sid="abcdef123456", title="Kart akışı", written=OLD_EPOCH + 60, last=OLD_EPOCH + 60,
                detail=True, account="Acme2", path="/w/proj/.claude/Kart-handoff-abcdef123456.md"):
        item = {
            "sessionId": sid,
            "title": title,
            "cwd": "/w/proj",
            "folder": "/w/proj",
            "project": "proj",
            "lastActivity": last,
            "account": account,
            "handoff": None if path is None else {
                "path": path,
                "prompt": sessions.handoff_prompt(path),
                "writtenAt": written,
                "detail": {"exists": detail},
                "dump": {"exists": False},
            },
        }
        return item

    def machine(self, *items, name="Mac (bu makine)"):
        return {"name": name, "ok": True, "error": None, "sessions": list(items)}

    def test_tr_time(self):
        self.assertEqual(sessions.tr_time(OLD_EPOCH), "11-15 01:13")

    def test_block_has_name_machine_account_time_path_and_prompt(self):
        text = sessions.render_text([self.machine(self.session())], [], 3, OLD_EPOCH)
        self.assertTrue(text.startswith("Oturumlar · 2023-11-15 01:13 TR · son 3 gün · devir notu olan 1 oturum · saatler TR"))
        self.assertNotIn("###", text)
        self.assertIn("**1. Kart akışı** · Mac (bu makine) · Acme2 · 2023-11-15 01:14", text)
        self.assertNotIn("devir notu 2023", text)
        self.assertNotIn("```text\n/w/proj/.claude/Kart-handoff-abcdef123456.md\n```", text)
        self.assertIn("Önceki oturumun işine devam ediyorum. /w/proj/.claude/Kart-handoff-abcdef123456.md devir notunu ve bağlı detay notunu tamamen oku.", text)
        self.assertIn("Klasör: `/w/proj`", text)
        self.assertNotIn("━", text)
        self.assertNotIn("⚠", text)

    def test_warnings(self):
        item = self.session(last=OLD_EPOCH + 60 + 2 * 3600 + 600, detail=False, account=None)
        text = sessions.render_text([self.machine(item)], [], 3, OLD_EPOCH)
        self.assertIn("⚠ nottan sonra 2 sa 10 dk daha çalıştı", text)
        self.assertIn("⚠ detay notu yok", text)
        self.assertIn("· hesap bilinmiyor ·", text)

    def test_duration(self):
        self.assertEqual(sessions.duration(40 * 60), "40 dk")
        self.assertEqual(sessions.duration(2 * 3600), "2 sa")
        self.assertEqual(sessions.duration(26 * 3600), "1 gün 2 sa")

    def test_fence_is_longer_than_backticks_inside(self):
        self.assertTrue(sessions.fence("a ```b``` c").startswith("````text"))

    def test_sessions_without_handoff_are_counted_not_shown(self):
        machines = [self.machine(self.session(), self.session(sid="x1", title="Bos", path=None))]
        text = sessions.render_text(machines, [], 3, OLD_EPOCH)
        self.assertNotIn("Bos", text)
        self.assertIn("Devir notu olmayan 1 oturum gösterilmedi.", text)

    def test_newest_handoff_first_across_machines_and_at_most_15(self):
        mac = self.machine(*[self.session(sid="m%02d" % i, title="M%02d" % i, written=OLD_EPOCH + i,
                                          path="/m/.claude/M-handoff-m%02d.md" % i) for i in range(10)])
        box = self.machine(*[self.session(sid="b%02d" % i, title="B%02d" % i, written=OLD_EPOCH + 100 + i,
                                          path="/b/.claude/B-handoff-b%02d.md" % i) for i in range(10)], name="box2")
        text = sessions.render_text([mac, box], [], 3, OLD_EPOCH)
        titles = [line.split("**")[1].split(". ", 1)[1] for line in text.splitlines() if line.startswith("**")]
        numbers = [line.split("**")[1].split(". ", 1)[0] for line in text.splitlines() if line.startswith("**")]
        self.assertEqual(numbers[:3], ["1", "2", "3"])
        self.assertEqual(len(titles), 15)
        self.assertEqual(titles[0], "B09")
        self.assertIn("5 oturum daha var. Tamamı yan panelde.", text)

    def test_error_machine_empty_list_and_notes(self):
        machines = [{"name": "bad", "ok": False, "error": "no route", "sessions": []}]
        text = sessions.render_text(machines, ["bir not"], 3, OLD_EPOCH)
        self.assertIn("Hata: bad: no route", text)
        self.assertIn("Son 3 günde devir notu olan oturum yok.", text)
        self.assertIn("Not: bir not", text)


class AccountTests(Base):
    def test_org_id_is_read_and_agent_sessions_are_hidden(self):
        self.session_file("s1", {"cwd": "/w/p", "aiTitle": "Gerçek"},
                          {"type": "attachment", "attachment": {"type": "credential_org", "organizationUuid": "aaaaaaaa-1111"}},
                          {"type": "attachment", "attachment": {"type": "credential_org", "organizationUuid": "bbbbbbbb-2222"}})
        self.session_file("s2", {"cwd": "/w/p", "customTitle": "agent-a9"})
        data = sessions.collect_local(3)
        self.assertEqual([x["sessionId"] for x in data["sessions"]], ["s1"])
        self.assertEqual(data["sessions"][0]["orgId"], "bbbbbbbb-2222")

    def test_accounts_file(self):
        repo = os.path.join(self.root, "repo")
        write(os.path.join(repo, "local", "accounts.md"),
              "Başlık\n\n- aaaaaaaa-1111: Acme2\n- bozuk satır\n- bbbbbbbb-2222:  acme \n")
        names = sessions.load_accounts(repo)
        self.assertEqual(names, {"aaaaaaaa-1111": "Acme2", "bbbbbbbb-2222": "acme"})
        machines = [{"sessions": [{"orgId": "aaaaaaaa-1111"}, {"orgId": None}]}]
        sessions.add_accounts(machines, names)
        self.assertEqual([x["account"] for x in machines[0]["sessions"]], ["Acme2", None])
        self.assertEqual(sessions.load_accounts(os.path.join(self.root, "none")), {})

    def test_session_folder(self):
        self.assertEqual(sessions.session_folder("/r/x/.claude/worktrees/wt-1"), "/r/x")
        self.assertEqual(sessions.session_folder("/r/x"), "/r/x")
        self.assertIsNone(sessions.session_folder(None))

    def test_local_name(self):
        self.assertTrue(sessions.local_name("host").endswith("(bu makine)"))


class UsageTests(Base):
    def test_usage_summary_reads_each_account_newest_first(self):
        feed = os.path.join(self.cfg, "usage-feed")
        write(os.path.join(feed, "feed-aaaaaaaa-1111_u1.json"),
              json.dumps({"ts": 100, "five": {"pct": 15, "reset": 5000}, "week": {"pct": 90, "reset": 9000}}))
        write(os.path.join(feed, "feed-bbbbbbbb-2222_u2.json"),
              json.dumps({"ts": 150, "mts": 200, "five": {"pct": 29}, "week": "bad"}))
        write(os.path.join(feed, "feed-cccccccc-3333_u3.json"), "{not json")
        usage = sessions.usage_summary(self.cfg, {"aaaaaaaa-1111": "Acme2"})
        self.assertEqual([u["orgId"] for u in usage], ["bbbbbbbb-2222", "aaaaaaaa-1111"])
        self.assertEqual(usage[0], {"orgId": "bbbbbbbb-2222", "account": None, "fivePct": 29, "fiveReset": None,
                                    "weekPct": None, "weekReset": None, "measuredAt": 200})
        self.assertEqual(usage[1]["account"], "Acme2")
        self.assertEqual(sessions.usage_summary(os.path.join(self.root, "none"), {}), [])

    def test_usage_line_and_text(self):
        item = {"account": "Acme2", "fivePct": 15, "fiveReset": 1795446000, "weekPct": 90,
                "weekReset": 1795525200, "measuredAt": 1795436480}
        line = sessions.usage_line(item, now=1795440000)
        self.assertEqual(line, "Acme2 · 5-hour limit 15% (18:00) · Weekly 90% (2026-11-24 16:00)"
                               " · ölçüm 2026-11-23 15:21")
        self.assertIn("5-hour limit sıfırlandı", sessions.usage_line(item, now=1795450000))
        self.assertIn("hesap bilinmiyor · 5-hour limit - · Weekly -",
                      sessions.usage_line({"fivePct": None, "weekPct": None}, now=0))
        text = sessions.render_text([], [], 3, generated=1795440000, usage=[item])
        self.assertIn("Kullanım (son ölçüm, hesap başına):\n- Acme2 · 5-hour limit", text)
        self.assertNotIn("Kullanım", sessions.render_text([], [], 3, generated=1795440000))


class CliTests(Base):
    def run_cli(self, *args):
        return subprocess.run(
            [sys.executable, SCRIPT, *args], capture_output=True, text=True, env=os.environ.copy()
        )

    def test_json_mode(self):
        self.session_file("s1", {"cwd": "/w/p", "aiTitle": "Hello"})
        done = self.run_cli("--json")
        self.assertEqual(done.returncode, 0)
        data = json.loads(done.stdout)
        self.assertEqual(set(data), {"host", "generated", "sessions"})
        self.assertEqual(data["sessions"][0]["title"], "Hello")

    def test_text_mode(self):
        self.session_file("s1", {"cwd": "/w/p", "aiTitle": "Hello"})
        done = self.run_cli("--text")
        self.assertEqual(done.returncode, 0)
        self.assertTrue(done.stdout.startswith("Oturumlar · "))
        self.assertIn("Devir notu olmayan 1 oturum gösterilmedi.", done.stdout)

    def test_all_json_with_missing_machines_file(self):
        os.makedirs(os.path.join(self.root, "repo"))
        done = self.run_cli("--all", "--json", "--days", "1")
        self.assertEqual(done.returncode, 0)
        data = json.loads(done.stdout)
        self.assertEqual(len(data["machines"]), 1)
        self.assertEqual(len(data["notes"]), 1)
        self.assertTrue(data["machines"][0]["name"].endswith("(bu makine)"))
        self.assertTrue(data["text"].startswith("Oturumlar · "))

    def test_empty_config_dir_still_prints_json(self):
        done = self.run_cli("--json")
        self.assertEqual(done.returncode, 0)
        self.assertEqual(json.loads(done.stdout)["sessions"], [])



class DropCopiesTest(unittest.TestCase):
    def test_copy_without_folder_goes_when_another_machine_owns_it(self):
        machines = [
            {"name": "mac", "sessions": [
                {"sessionId": "a", "cwdExists": False},
                {"sessionId": "b", "cwdExists": False},
                {"sessionId": "c", "cwdExists": True},
            ]},
            {"name": "ubuntu", "sessions": [{"sessionId": "a", "cwdExists": True}]},
        ]
        sessions.drop_copies(machines)
        self.assertEqual([x["sessionId"] for x in machines[0]["sessions"]], ["b", "c"])
        self.assertEqual([x["sessionId"] for x in machines[1]["sessions"]], ["a"])

if __name__ == "__main__":
    unittest.main()
