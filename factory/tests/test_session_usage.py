"""Direct tests of factory/bin/session_usage.py over JSONL fixtures in a temp dir.

Run: python3 -m unittest factory/tests/test_session_usage.py (run.sh runs it too).
HOME, CLAUDE_CONFIG_DIR, CODEX_HOME and XDG_CACHE_HOME point into the temp dir,
so nothing reads or writes this machine's sessions or cache.
"""

import importlib.machinery
import importlib.util
import json
import os
import sys
import tempfile
import unittest
from pathlib import Path
from unittest import mock

BIN = Path(__file__).resolve().parents[1] / "bin"
sys.dont_write_bytecode = True
sys.path.insert(0, str(BIN))
import session_usage as su  # noqa: E402

CLAUDE_PRICE = {"input": 4.0, "output": 20.0, "cache_write_5m": 5.0, "cache_write_1h": 8.0, "cache_read": 0.2}
PRICES = {"claude-a": CLAUDE_PRICE,
          "gpt-one": {"input": 1.0, "cached_input": 0.1, "cache_write": 1.25, "output": 5.0},
          "gpt-two": {"input": 2.0, "cached_input": 0.1, "cache_write": 2.5, "output": 10.0}}
JOB = "/r/factory/jobs/001-a/"
BRIEF = f"Job folder: {JOB}\nYour brief is /r/factory/agents/builder.md"


def lines(path, *entries, raw=()):
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text("".join(json.dumps(e) + "\n" for e in entries) + "".join(r + "\n" for r in raw))
    return path


def user(text, cwd=None):
    return {"type": "user", "cwd": cwd, "message": {"role": "user", "content": text}}


def assistant(mid, model="claude-a", ts="2026-11-14T12:00:00Z", **usage):
    return {"type": "assistant", "timestamp": ts, "message": {"id": mid, "model": model, "usage": usage}}


def meta(sid, cwd="/w/api"):
    return {"timestamp": "2026-11-14T12:00:00Z", "type": "session_meta", "payload": {"id": sid, "cwd": cwd}}


def turn(model):
    return {"timestamp": "2026-11-14T12:00:00Z", "type": "turn_context", "payload": {"model": model}}


def count(ts, inp, out=0, cached=0):
    return {"timestamp": ts, "type": "event_msg", "payload": {"type": "token_count", "info": {"total_token_usage": {
        "input_tokens": inp, "cached_input_tokens": cached, "output_tokens": out, "total_tokens": inp + out}}}}


def task(text):
    return {"timestamp": "2026-11-14T12:00:00Z", "type": "event_msg", "payload": {"type": "user_message", "message": text}}


def switching_rollout(path, brief=None):
    """1M input tokens on gpt-one, the same total again, then 1M more on gpt-two."""
    return lines(path, meta("c1"), *([task(brief)] if brief else []), turn("gpt-one"),
                 count("2026-11-14T12:00:00Z", 1_000_000), count("2026-11-14T12:00:01Z", 1_000_000),
                 turn("gpt-two"), count("2026-11-14T12:00:02Z", 2_000_000))


class Base(unittest.TestCase):
    def setUp(self):
        tmp = tempfile.TemporaryDirectory()
        self.addCleanup(tmp.cleanup)
        self.root = Path(tmp.name)
        env = {"HOME": str(self.root / "home"), "CLAUDE_CONFIG_DIR": str(self.root / "home/.claude"),
               "CODEX_HOME": str(self.root / "home/.codex"), "XDG_CACHE_HOME": str(self.root / "home/.cache")}
        patcher = mock.patch.dict(os.environ, env)
        patcher.start()
        self.addCleanup(patcher.stop)
        self.projects = self.root / "home/.claude/projects"
        self.sessions = self.root / "home/.codex/sessions"


class JobUsage(Base):
    def test_codex_model_change_charges_each_increment_at_its_model(self):
        switching_rollout(self.sessions / "2026/11/14/rollout-c1.jsonl", BRIEF)
        # A shorter copy of the same session in another home adds nothing.
        other = self.root / "other/sessions"
        lines(other / "2026/11/14/rollout-c1.jsonl", meta("c1"), task(BRIEF), turn("gpt-one"),
              count("2026-11-14T12:00:00Z", 1_000_000))
        totals, rows = su.job_usage(JOB, [], [self.sessions, other], PRICES, since="2026-11-01")
        self.assertEqual(totals, {"claude": 0.0, "codex": 3.0})
        self.assertEqual(sorted((k, r["sessions"], r["input_tokens"], round(r["cost_usd"], 4)) for k, r in rows.items()), [
            (("builder", "codex", "gpt-one"), 1, 1_000_000, 1.0),
            (("builder", "codex", "gpt-two"), 1, 1_000_000, 2.0)])

    def test_rollouts_before_the_job_started_are_not_read(self):
        switching_rollout(self.sessions / "2026/10/31/rollout-c1.jsonl", BRIEF)
        self.assertEqual(su.job_usage(JOB, [], [self.sessions], PRICES, since="2026-11-01")[0]["codex"], 0.0)

    def test_claude_repeated_ids_and_cache_buckets(self):
        proj = self.projects / "-r"
        usage = dict(input_tokens=1000, output_tokens=2000, cache_creation_input_tokens=3000,
                     cache_creation={"ephemeral_1h_input_tokens": 1000}, cache_read_input_tokens=10000)
        lines(proj / "s1.jsonl", user(BRIEF, cwd="/r"), assistant("m1", **usage), assistant("m1", **usage),
              assistant("m2", ts=None, input_tokens=1_000_000),  # undated usage still counts for a job
              assistant("m3", model="claude-x", input_tokens=500),
              raw=["{not json", "[1, 2]"])
        lines(proj / "s1/subagents/agent-1.jsonl", user(BRIEF.replace("builder", "reviewer-code")),
              assistant("m4", output_tokens=1_000_000))
        lines(proj / "s2.jsonl", user("not a job"), assistant("m5", input_tokens=1_000_000))
        warned = []
        totals, rows = su.job_usage(JOB, [proj, self.root / "missing"], [self.root / "nope"], PRICES,
                                    on_unpriced=warned.append)
        # m1 once: 1000*4 + 2000*20 + 2000*5 + 1000*8 + 10000*0.2 = 64000 per 1e6; m2: $4; m4: $20.
        builder = rows[("builder", "claude", "claude-a")]
        self.assertEqual((builder["sessions"], builder["input_tokens"], builder["cached_tokens"], builder["output_tokens"]),
                         (1, 1000 + 3000 + 1_000_000, 10000, 2000))
        self.assertAlmostEqual(builder["cost_usd"], 0.064 + 4.0)
        self.assertEqual(rows[("reviewer-code", "claude", "claude-a")]["cost_usd"], 20.0)
        self.assertEqual(totals, {"claude": 24.06, "codex": 0.0})
        self.assertEqual(warned, ["claude-x"])
        self.assertNotIn(("builder", "claude", "claude-x"), rows)

    def test_usage_rows_from_a_fixture(self):
        path = lines(self.projects / "-x/s.jsonl", user("hi", cwd="/w"),
                     assistant("m1", input_tokens=10, cache_read_input_tokens=5), raw=["garbage"])
        rows = list(su.usage_rows({str(path): {**su.read_claude(path), "kind": "claude"}}))
        self.assertEqual([(r["agent"], r["model"], r["month"], r["cwd"], r["tokens"]) for r in rows], [
            ("claude", "claude-a", "2026-11", "/w",
             {"input": 10, "cache_write_5m": 0, "cache_write_1h": 0, "cache_read": 5, "output": 0})])
        self.assertAlmostEqual(su.price(rows[0], PRICES), (10 * 4 + 5 * 0.2) / 1e6)
        self.assertIsNone(su.price({**rows[0], "model": "claude-x"}, PRICES))


class OutsideUsage(Base):
    def fixture(self):
        cl = self.projects / "-x"
        use = {"input_tokens": 1_000_000}
        lines(cl / "s1.jsonl", user("hi", cwd="/w/app"), assistant("m1", **use))
        lines(cl / "s2.jsonl", user("hi", cwd="/w/app"), assistant("m1", **use))  # a resumed copy
        lines(cl / "s3.jsonl", user(BRIEF), assistant("m2", **use))  # a factory session
        lines(cl / "s1/subagents/agent-1.jsonl", assistant("m3", model="claude-x", input_tokens=500))
        # Codex: gpt-one in November, gpt-two in December; a factory rollout; a shorter copy.
        lines(self.sessions / "2026/11/30/rollout-c1.jsonl", meta("c1"), turn("gpt-one"),
              count("2026-11-14T12:00:00Z", 1_000_000), count("2026-11-14T12:00:01Z", 1_000_000),
              turn("gpt-two"), count("2026-12-14T12:00:00Z", 2_000_000))
        switching_rollout(self.sessions / "2026/11/30/rollout-f1.jsonl", BRIEF)
        acct = self.root / "home/.config/orca/codex-accounts/a/home/sessions"
        lines(acct / "2026/11/30/rollout-c1.jsonl", meta("c1"), turn("gpt-one"), count("2026-11-14T12:00:00Z", 1_000_000))

    def scan(self, prices=PRICES):
        return su.outside_usage(su.claude_project_dirs(), su.codex_session_dirs(), prices, su.cache_path())

    def test_summary(self):
        self.fixture()
        r = self.scan()
        self.assertEqual({m: {a: round(v, 2) for a, v in x.items()} for m, x in r["months"].items()},
                         {"2026-11": {"claude": 4.0, "codex": 1.0}, "2026-12": {"claude": 0.0, "codex": 2.0}})
        self.assertEqual(r["factory_sessions"], 2)
        self.assertEqual(r["unpriced"], {"2026-11": {"claude-x": 500}})
        self.assertEqual([(c["cwd"], c["sessions"]) for c in r["by_cwd"]], [("/w/app", 1), ("/w/api", 1)])
        self.assertEqual(r["status"], "ready")

    def test_dashboard_and_report_agree(self):
        self.fixture()
        mods = {}
        for name in ("dashboard", "report"):
            loader = importlib.machinery.SourceFileLoader(f"t_{name}", str(BIN / name))
            mods[name] = importlib.util.module_from_spec(importlib.util.spec_from_loader(f"t_{name}", loader))
            loader.exec_module(mods[name])
        cfg = {**su.factory_config(), "prices_usd_per_mtok": PRICES}  # the repo's config, fixture prices
        with mock.patch.object(mods["dashboard"], "config", return_value=cfg), \
                mock.patch.object(su, "factory_config", return_value=cfg):
            first = mods["dashboard"].Outside().scan()
            self.assertEqual(mods["report"].scan_outside(), first)
        self.assertEqual(first, self.scan())
        self.assertEqual(first["factory_sessions"], 2)

    def test_cache_reuse_deletion_upgrade_and_repricing(self):
        self.fixture()
        first = self.scan()
        with mock.patch.object(su, "read_claude", side_effect=AssertionError("reread")), \
                mock.patch.object(su, "read_codex", side_effect=AssertionError("reread")):
            self.assertEqual(self.scan(), first)  # unchanged files come from the cache
        for p in (self.projects / "-x").glob("s[12].jsonl"):
            p.unlink()
        self.assertEqual(self.scan(), first)  # deleted transcripts keep counting
        doubled = {m: {k: v * 2 for k, v in p.items()} for m, p in PRICES.items()}
        again = self.scan(doubled)  # a new price table reprices cached tokens
        self.assertEqual({m: {a: round(v, 2) for a, v in x.items()} for m, x in again["months"].items()},
                         {"2026-11": {"claude": 8.0, "codex": 2.0}, "2026-12": {"claude": 0.0, "codex": 4.0}})

    def test_cache_written_before_this_module_still_counts(self):
        cache = su.cache_path()
        cache.parent.mkdir(parents=True)
        cache.write_text(json.dumps({"version": 2, "files": {
            "/gone/a.jsonl": {"stamp": [1, 1], "kind": "claude", "factory": False, "cwd": "/w/old",
                              "msgs": {"old1": ["2026-09", "claude-a", 1_000_000, 0, 0, 0, 0]}},
            "/gone/rollout-o.jsonl": {"stamp": [1, 1], "kind": "codex", "factory": False, "cwd": "/w/old",
                                      "sid": "o", "tokens": 1_000_000,
                                      "usage": {"2026-09": {"gpt-two": {"input_tokens": 1_000_000, "total_tokens": 1_000_000}}}},
            "/gone/f.jsonl": {"stamp": [1, 1], "kind": "claude", "factory": True, "cwd": None, "msgs": {}}}}))
        r = self.scan()
        self.assertEqual(r["months"], {"2026-09": {"claude": 4.0, "codex": 2.0}})
        self.assertEqual(r["factory_sessions"], 1)

    def test_undated_usage_stays_out_of_months_and_cache(self):
        lines(self.projects / "-x/s.jsonl", user("hi"), assistant("m1", ts=None, input_tokens=5))
        lines(self.sessions / "2026/11/30/rollout-u.jsonl", meta("u"), turn("gpt-one"),
              {"type": "event_msg", "payload": count("x", 7)["payload"]})
        self.assertEqual(self.scan()["months"], {})
        json.loads(su.cache_path().read_text())  # still valid JSON: no None keys

    def test_missing_directories(self):
        r = su.outside_usage([self.root / "none"], [self.root / "none"], PRICES, self.root / "c.json")
        self.assertEqual((r["months"], r["by_cwd"], r["factory_sessions"]), ({}, [], 0))


if __name__ == "__main__":
    unittest.main()
