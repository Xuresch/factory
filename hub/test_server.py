"""Black-box conformance tests for the factory hub (contract: hub/PROTOCOL.md).

  (cd hub && cargo build --release) && python3 -m unittest hub/test_server.py -v
  HUB_CMD=<any command that starts a hub> python3 -m unittest hub/test_server.py -v

Every test starts the hub as a subprocess (HUB_CMD, a shell command, default
hub/target/release/factory-hub) with a fresh database and talks to it over HTTP only. The server
is configured through FACTORY_HUB_PORT, _DB, _TOKENS, _BIND, _DASHBOARD and
_STATIC (a folder holding index.html and app.js).
"""

import calendar
import datetime
import gzip
import http.client
import json
import os
import re
import signal
import socket
import subprocess
import sys
import tempfile
import time
import unittest
import urllib.request
from pathlib import Path
from urllib.parse import unquote

TOKEN = "s3cret"
MAX_BODY = 64 * 1024 * 1024
HUB_CMD = os.environ.get("HUB_CMD") or str(Path(__file__).resolve().parent / "target" / "release" / "factory-hub")


def job(jid, stage="build", title=None, started="2026-11-17T10:00:00Z", cost=1.0, **extra):
    return {"id": jid, "title": title or f"job {jid}", "stage": stage, "started": started,
            "cost_usd": cost, "cost_by_agent": {"claude": cost}, **extra}


def entry(jid, stage="build", files=None, **kw):
    return {"id": jid, "job": job(jid, stage, **kw), "files": files or {"spec.md": f"# spec {jid}\n"}}


def push(machine, repos, **extra):
    return {"v": 1, "machine": machine, "sent_at": "2026-11-17T20:00:00Z", "full": False, "repos": repos, **extra}


def repo(name, jobs, ids=None, **extra):
    return {"repo": name, "url": f"https://github.com/{name}", "path": f"/x/{name}",
            "job_ids": ids if ids is not None else [j["id"] for j in jobs], "jobs": jobs, **extra}


class HubCase(unittest.TestCase):
    """Starts the hub as a subprocess per test, with a fresh database."""

    tokens = TOKEN

    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        tmp = Path(self.tmp.name)
        (tmp / "dashboard.html").write_text("<title>dash</title>")
        (tmp / "static").mkdir()
        (tmp / "static" / "index.html").write_text("<h1>overview</h1>")
        (tmp / "static" / "app.js").write_text("1")
        with socket.socket() as s:
            s.bind(("127.0.0.1", 0))
            self.port = s.getsockname()[1]
        env = {**os.environ, "FACTORY_HUB_PORT": str(self.port), "FACTORY_HUB_DB": str(tmp / "hub.db"),
               "FACTORY_HUB_TOKENS": self.tokens, "FACTORY_HUB_BIND": "127.0.0.1",
               "FACTORY_HUB_DASHBOARD": str(tmp / "dashboard.html"), "FACTORY_HUB_STATIC": str(tmp / "static")}
        self.proc = subprocess.Popen(HUB_CMD, shell=True, env=env, start_new_session=True,
                                     stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
        self.addCleanup(self.stop)
        deadline = time.time() + 15
        while True:
            try:
                with urllib.request.urlopen(f"http://127.0.0.1:{self.port}/healthz", timeout=1):
                    break
            except OSError:
                if time.time() > deadline or self.proc.poll() is not None:
                    self.fail("hub did not start")
                time.sleep(0.05)

    def stop(self):
        try:
            os.killpg(self.proc.pid, signal.SIGKILL)
        except ProcessLookupError:
            pass
        self.proc.wait()
        self.tmp.cleanup()

    def request(self, method, path, body=None, headers=None):
        conn = http.client.HTTPConnection("127.0.0.1", self.port, timeout=10)
        conn.request(method, path, body=body, headers=headers or {})
        res = conn.getresponse()
        data = res.read()
        conn.close()
        return res.status, res, data

    def get(self, path):
        status, res, data = self.request("GET", path)
        return status, data.decode(), res

    def get_json(self, path):
        status, text, _ = self.get(path)
        self.assertEqual(status, 200, path)
        return json.loads(text)

    def ingest(self, payload, token=TOKEN, gz=False):
        headers = {"Content-Type": "application/json"}
        if token is not None:
            headers["Authorization"] = f"Bearer {token}"
        body = json.dumps(payload).encode()
        if gz:
            body = gzip.compress(body)
            headers["Content-Encoding"] = "gzip"
        status, _, data = self.request("POST", "/api/ingest", body, headers)
        return status, json.loads(data or b"{}")

    def ok(self, payload, **kw):
        status, data = self.ingest(payload, **kw)
        self.assertEqual(status, 200, data)
        return data

    @staticmethod
    def links(listing):
        return [unquote(h) for h in re.findall(r'<a href="([^"]*)"', listing)]


class TestNoTokens(HubCase):
    tokens = ""

    def test_ingest_refused(self):
        self.assertEqual(self.ingest(push("m1", []))[0], 403)
        self.assertEqual(self.ingest(push("m1", []), token=None)[0], 403)


class TestIngest(HubCase):
    def test_auth(self):
        payload = push("m1", [repo("o/r", [entry("001")])])
        self.assertEqual(self.ingest(payload, token=None)[0], 401)
        self.assertEqual(self.ingest(payload, token="wrong")[0], 401)
        self.assertEqual(self.ingest(payload)[0], 200)


    def test_bad_body(self):
        status, _, _ = self.request("POST", "/api/ingest", b"not json",
                                    {"Authorization": f"Bearer {TOKEN}", "Content-Length": "8"})
        self.assertEqual(status, 400)
        self.assertEqual(self.ingest({"v": 1, "repos": []})[0], 400)
        bad = push("m1", [repo("o/r", [entry("001", files={"../x.md": "y"})])])
        self.assertEqual(self.ingest(bad)[0], 400)

    def test_too_large(self):
        status, _, _ = self.request("POST", "/api/ingest", None, {
            "Authorization": f"Bearer {TOKEN}", "Content-Length": str(MAX_BODY + 1)})
        self.assertEqual(status, 413)

    def test_gzip_body(self):
        self.assertTrue(self.ok(push("m1", [repo("o/r", [entry("001")])]), gz=True)["ok"])
        self.assertEqual(len(self.get_json("/api/overview")["repos"]), 1)

    def test_need_full_on_fresh_db(self):
        payload = push("m1", [repo("o/r", [entry("001")])])
        self.assertFalse(self.ok({**push("m0", [repo("o/r", [entry("001")])]), "full": True})["need_full"])
        self.assertTrue(self.ok(payload)["need_full"])
        self.assertFalse(self.ok(payload)["need_full"])
        # A repo the hub has not seen in a non-full push asks for a full one too.
        self.assertTrue(self.ok(push("m1", [repo("o/new", [entry("001")])]))["need_full"])
        self.assertFalse(self.ok({**push("m1", [repo("o/new2", [entry("001")])]), "full": True})["need_full"])

    def test_full_ingest_overview(self):
        jobs = [entry("001", "merged", ended="2026-11-17T11:00:00Z", cost=2.0),
                entry("002", "build", cost=1.5),
                entry("003", "needs-human", cost=0.5),
                entry("004", "rejected", ended="2026-11-16T11:00:00Z", cost=0.25)]
        payload = push("m1", [repo("Xuresch/app", jobs, config={"prices_usd_per_mtok": {}})],
                       subscriptions=[{"name": "Claude Max", "agent": "claude", "usd_per_month": 100}])
        self.ok({**payload, "full": True})
        ov = self.get_json("/api/overview")
        self.assertEqual(ov["machines"][0]["machine"], "m1")
        self.assertEqual(ov["machines"][0]["repos"], 1)
        r = ov["repos"][0]
        self.assertEqual(r["repo"], "Xuresch/app")
        self.assertEqual(r["counts"], {"running": 1, "needs_you": 1, "merged": 1, "rejected": 1, "total": 4})
        self.assertEqual(r["cost_usd"], 4.25)
        self.assertEqual(r["href"], "/r/Xuresch/app/dashboard.html")
        self.assertEqual(len(r["daily"]), 14)
        self.assertEqual([j["id"] for j in ov["live"]], ["002"])
        self.assertEqual(ov["live"][0]["href"], "/r/Xuresch/app/dashboard.html#job=002")
        self.assertEqual([j["id"] for j in ov["needs_you"]], ["003"])
        self.assertEqual([j["id"] for j in ov["recent"]], ["001", "004"])
        self.assertEqual({e["job"] for e in ov["events"]}, {"001", "002", "003", "004"})
        self.assertEqual(ov["month"]["subscriptions_usd"], 100)

    def test_overview_agent_split(self):
        now = datetime.datetime.now(datetime.timezone.utc)
        today, month = now.strftime("%Y-%m-%d"), now.strftime("%Y-%m")
        prev_first = (now.replace(day=1) - datetime.timedelta(days=1))
        prev = prev_first.strftime("%Y-%m")

        def j(jid, cost, by, started):
            data = {"id": jid, "title": jid, "stage": "merged", "started": started, "cost_usd": cost}
            if by is not None:
                data["cost_by_agent"] = by
            return {"id": jid, "job": data, "files": {"spec.md": "x"}}

        t = f"{today}T00:30:00Z"
        a = [j("001", 3.0, {"claude": 2.0, "codex": 1.0}, t), j("002", 1.0, None, t),
             j("003", 4.0, {"claude": 4.0}, f"{prev}-15T10:00:00Z")]
        b = [j("001", 0.6, {"claude": 0.1, "codex": 0.5}, t), j("002", 0.2, {"claude": 0.1}, t)]

        def outside(this, last):
            return {"status": "ready", "months": {month: this, prev: last}, "by_cwd": [], "unpriced": {}}
        self.ok(push("m1", [repo("o/a", a), repo("o/b", b)],
                     outside=outside({"claude": 5.0, "codex": 1.0}, {"claude": 2.0, "codex": 0.5})))
        self.ok(push("m2", [], outside=outside({"claude": 7.0, "codex": 1.0}, {"claude": 1.0, "codex": 0.5})))
        ov = self.get_json("/api/overview")
        ra, rb = ov["repos"]
        self.assertEqual(ra["cost_by_agent"], {"claude": 6.0, "codex": 1.0, "other": 1.0})
        self.assertEqual(ra["cost_month_by_agent"], {"claude": 2.0, "codex": 1.0, "other": 1.0})
        self.assertEqual(rb["cost_by_agent"], {"claude": 0.2, "codex": 0.5, "other": 0.1})
        self.assertEqual(rb["cost_month_by_agent"], rb["cost_by_agent"])
        self.assertEqual(ra["cost_usd"], 8.0)
        self.assertEqual(ra["cost_month"], 4.0)
        day_a = ra["daily"][-1]
        self.assertEqual((day_a["day"], day_a["jobs"], day_a["cost_usd"]), (today, 2, 4.0))
        self.assertEqual(day_a["by_agent"], {"claude": 2.0, "codex": 1.0, "other": 1.0})
        self.assertEqual(ra["daily"][0]["by_agent"], {"claude": 0.0, "codex": 0.0, "other": 0.0})
        self.assertEqual(len(ov["daily"]), 14)
        top = ov["daily"][-1]
        self.assertEqual((top["day"], top["jobs"], top["cost_usd"]), (today, 4, 4.8))
        self.assertEqual(top["by_agent"], {"claude": 2.2, "codex": 1.5, "other": 1.1})
        m = ov["month"]
        self.assertEqual(m["factory"], {"claude": 2.2, "codex": 1.5, "other": 1.1})
        self.assertEqual(m["outside"], {"claude": 12.0, "codex": 2.0})
        self.assertEqual(m["by_agent"], {"claude": 14.2, "codex": 3.5})
        self.assertEqual(m["api_equivalent_usd"], 18.8)
        self.assertEqual(m["prev"], {"month": prev, "api_equivalent_usd": 8.0,
                                     "factory": {"claude": 4.0, "codex": 0.0, "other": 0.0},
                                     "outside": {"claude": 3.0, "codex": 1.0}})
        self.assertEqual(m["days_elapsed"], now.day)
        self.assertEqual(m["days_in_month"], calendar.monthrange(now.year, now.month)[1])

    def test_delta_ingest_files_removed_and_job_ids(self):
        files = {"spec.md": "a", "round-1/review-code.md": "b", "round-2/review-ux.md": "c"}
        self.ok(push("m1", [repo("o/r", [entry("001", files=files), entry("002")])]))
        delta = {"id": "001", "job": job("001", "gate"), "files": {"spec.md": "a2"},
                 "files_removed": ["round-2/review-ux.md"]}
        self.ok(push("m1", [{"repo": "o/r", "job_ids": ["001"], "jobs": [delta]}]))
        self.assertEqual(self.get("/r/o/r/jobs/001/spec.md")[1], "a2")
        self.assertEqual(self.get("/r/o/r/jobs/001/round-1/review-code.md")[0], 200)
        self.assertEqual(self.get("/r/o/r/jobs/001/round-2/review-ux.md")[0], 404)
        self.assertEqual(self.get("/r/o/r/jobs/002/job.json")[0], 404)  # not in job_ids: deleted
        self.assertEqual(self.links(self.get("/r/o/r/jobs/")[1]), ["001/"])

    def test_removed_job_keeps_its_cost_and_comes_back(self):
        self.ok(push("m1", [repo("o/r", [entry("001", cost=2.0), entry("002", "merged", cost=3.0)])]))
        self.ok(push("m1", [{"repo": "o/r", "job_ids": ["001"], "jobs": []}]))
        r = self.get_json("/api/overview")["repos"][0]
        self.assertEqual(r["counts"]["total"], 1)  # gone from the board
        self.assertEqual(r["cost_usd"], 5.0)  # still in the history
        self.ok(push("m1", [{"repo": "o/r", "job_ids": ["001", "002"], "jobs": []}]))
        self.assertEqual(self.get("/r/o/r/jobs/002/job.json")[0], 200)
        self.assertEqual(self.get_json("/api/overview")["repos"][0]["counts"]["total"], 2)

    def test_round_verdicts_come_from_the_files(self):
        files = {"spec.md": "s", "round-1/checks.md": "GATE: PASS\n", "round-1/review-code.md": "VERDICT: CHANGES\n"}
        self.ok(push("m1", [repo("o/r", [entry("001", "review", files=files, round=1)])]))
        self.assertEqual(self.get("/r/o/r/jobs/001/round-1/checks.md")[1], "GATE: PASS\n")

    def test_full_replaces_file_set_and_drops_repos(self):
        self.ok(push("m1", [repo("o/a", [entry("001", files={"spec.md": "x", "build.md": "y"})]),
                            repo("o/b", [entry("001")])]))
        again = {**push("m1", [repo("o/a", [entry("001", files={"spec.md": "x"})])]), "full": True}
        self.ok(again)
        self.assertEqual(self.get("/r/o/a/jobs/001/build.md")[0], 404)
        self.assertEqual(self.get("/r/o/b/jobs/")[0], 404)
        self.assertEqual([r["repo"] for r in self.get_json("/api/overview")["repos"]], ["o/a"])

    def test_stage_change_event_and_sse(self):
        self.ok(push("m1", [repo("o/r", [entry("001", "build", title="Add thing")])]))
        events = self.get_json("/api/overview")["events"]
        self.assertEqual((events[0]["from"], events[0]["to"]), (None, "build"))

        sock = socket.create_connection(("127.0.0.1", self.port), timeout=5)
        sock.sendall(b"GET /api/stream HTTP/1.1\r\nHost: x\r\n\r\n")
        reader = sock.makefile("rb")
        line = b""
        while b"retry: 3000" not in line:  # sent once the client is subscribed
            line = reader.readline()
        self.ok(push("m1", [repo("o/r", [entry("001", "gate", title="Add thing")])]))
        seen = {}
        while "job" not in seen or "seen" not in seen:
            kind = reader.readline().decode().strip()
            if kind.startswith("event: "):
                seen[kind[7:]] = json.loads(reader.readline().decode()[6:])
        sock.close()
        self.assertEqual(seen["job"], {"at": seen["job"]["at"], "machine": "m1", "repo": "o/r", "job": "001",
                                       "title": "Add thing", "from": "build", "to": "gate"})
        self.assertEqual(seen["seen"]["machine"], "m1")
        self.assertEqual(self.get_json("/api/overview")["events"][0]["to"], "gate")

    def test_unchanged_stage_makes_no_event(self):
        payload = push("m1", [repo("o/r", [entry("001", "build")])])
        self.ok(payload)
        self.ok(payload)
        self.assertEqual(len(self.get_json("/api/overview")["events"]), 1)

    def test_dead_sse_client_does_not_block_ingest(self):
        sock = socket.create_connection(("127.0.0.1", self.port), timeout=5)
        sock.sendall(b"GET /api/stream HTTP/1.1\r\nHost: x\r\n\r\n")
        sock.makefile("rb").readline()
        sock.close()
        for n in range(300):  # more than a stuck client could buffer
            self.ok(push("m1", [repo("o/r", [entry("001", "build" if n % 2 else "gate")])]))


class TestTree(HubCase):
    def setUp(self):
        super().setUp()
        files = {"spec.md": "# spec\n", "round-1/review-code.md": "VERDICT: PASS\n", "round-1/diff.md": "d"}
        self.ok(push("m1", [repo("o/r", [entry("001", "merged", files=files, cost=2.0,
                                                issue_url=".scratch/x/03.md")],
                                 config={"prices_usd_per_mtok": {"m": {}}},
                                 tickets={".scratch/x/03.md": "Status: ready\n"})]))

    def test_dashboard_hub_and_static(self):
        self.assertEqual(self.get("/r/o/r/dashboard.html")[1], "<title>dash</title>")
        self.assertEqual(self.get_json("/r/o/r/hub"), {"repo": "o/r", "overview": "/"})
        self.assertEqual(self.get("/")[1], "<h1>overview</h1>")
        self.assertEqual(self.get("/static/app.js")[0], 200)
        self.assertEqual(self.get("/static/nope.js")[0], 404)
        self.assertEqual(self.get("/healthz")[1].strip(), "ok")
        self.assertEqual(self.get("/r/o/zzz/dashboard.html")[0], 404)

    def test_no_store_everywhere(self):
        for path in ("/api/overview", "/r/o/r/jobs/", "/r/o/r/jobs/001/job.json", "/healthz", "/"):
            self.assertEqual(self.get(path)[2].headers["Cache-Control"], "no-store", path)

    def test_listings_and_files(self):
        status, text, res = self.get("/r/o/r/jobs/")
        self.assertEqual((status, res.headers["Content-Type"]), (200, "text/html; charset=utf-8"))
        self.assertEqual(self.links(text), ["001/"])
        self.assertEqual(self.links(self.get("/r/o/r/jobs/001/")[1]), ["job.json", "round-1/", "spec.md"])
        self.assertEqual(self.links(self.get("/r/o/r/jobs/001/round-1/")[1]), ["diff.md", "review-code.md"])
        self.assertEqual(self.get_json("/r/o/r/jobs/001/job.json")["id"], "001")
        status, text, res = self.get("/r/o/r/jobs/001/round-1/review-code.md")
        self.assertEqual(text, "VERDICT: PASS\n")
        self.assertEqual(res.headers["Content-Type"], "text/markdown; charset=utf-8")
        self.assertEqual(self.get_json("/r/o/r/config.json")["prices_usd_per_mtok"], {"m": {}})
        self.assertEqual(self.get("/r/o/r/.scratch/x/03.md")[1], "Status: ready\n")
        self.assertEqual(self.get("/r/o/r/jobs/nope/")[0], 404)
        self.assertEqual(self.get("/r/o/r/jobs/001/nope/")[0], 404)

    def test_directory_redirects_like_http_server(self):
        status, _, res = self.get("/r/o/r/jobs")
        self.assertEqual((status, res.headers["Location"]), (301, "/r/o/r/jobs/"))

    def test_path_traversal(self):
        for path in ("/r/o/r/jobs/../config.json", "/r/o/r/jobs/001/..%2f..%2fconfig.json",
                     "/r/o/r/jobs/%2e%2e/001/job.json", "/static/../server.py", "/static/%2e%2e%2fserver.py",
                     "/all/jobs/../config.json"):
            self.assertEqual(self.get(path)[0], 404, path)

    def test_config_404_without_report(self):
        self.ok(push("m1", [repo("o/other", [entry("001")])]))
        self.assertEqual(self.get("/r/o/other/config.json")[0], 404)

    def test_subscriptions_shape(self):
        data = self.get_json("/r/o/r/_subscriptions.json")
        self.assertEqual(data["config"], "factory hub")
        self.assertEqual(data["projects"], [{"name": "o/r", "missing": False, "jobs": [
            {"id": "001", "stage": "merged", "started": "2026-11-17T10:00:00Z", "ended": None,
             "cost_usd": 2.0, "cost_by_agent": {"claude": 2.0}}]}])
        self.assertEqual(data["outside"], {"status": "scanning"})

    def test_subscriptions_aggregate_two_machines(self):
        def outside(claude, cwd):
            return {"status": "ready", "months": {"2026-11": {"claude": claude, "codex": 1.0}},
                    "by_cwd": [{"cwd": cwd, "claude": claude, "codex": 1.0, "sessions": 2}],
                    "unpriced": {"2026-11": {"gpt-x": 100}}, "factory_sessions": 3}
        sub = {"name": "Claude Max", "agent": "claude", "usd_per_month": 100}
        self.ok(push("m1", [], subscriptions=[sub], outside=outside(5.0, "/a")))
        self.ok(push("m2", [repo("o/r2", [entry("009")])],
                     subscriptions=[sub, {"name": "Codex", "agent": "codex", "usd_per_month": 20}],
                     outside=outside(7.0, "/b")))
        data = self.get_json("/_subscriptions.json") if False else self.get_json("/r/o/r/_subscriptions.json")
        self.assertEqual([s["name"] for s in data["subscriptions"]], ["Claude Max", "Codex"])
        self.assertEqual({p["name"] for p in data["projects"]}, {"o/r", "o/r2"})
        out = data["outside"]
        self.assertEqual(out["status"], "ready")
        self.assertEqual(out["months"], {"2026-11": {"claude": 12.0, "codex": 2.0}})
        self.assertEqual([c["cwd"] for c in out["by_cwd"]], ["m2:/b", "m1:/a"])
        self.assertEqual(out["unpriced"], {"2026-11": {"gpt-x": 200}})
        self.assertEqual(out["factory_sessions"], 6)
        month = self.get_json("/api/overview")["month"]
        self.assertEqual(month["subscriptions_usd"], 120)

    def test_machine_prefixing(self):
        self.ok(push("m2", [repo("o/r", [entry("001", files={"spec.md": "from m2"}), entry("005")])]))
        self.assertEqual(self.links(self.get("/r/o/r/jobs/")[1]), ["m1~001/", "m2~001/", "m2~005/"])
        data = self.get_json("/r/o/r/jobs/m2~001/job.json")
        self.assertEqual(data["id"], "m2~001")
        self.assertEqual(self.get("/r/o/r/jobs/m2~001/spec.md")[1], "from m2")
        self.assertEqual(self.get("/r/o/r/jobs/m1~001/spec.md")[1], "# spec\n")
        self.assertEqual(self.get("/r/o/r/jobs/001/spec.md")[0], 404)
        ov = self.get_json("/api/overview")
        self.assertEqual(ov["repos"][0]["machines"], ["m1", "m2"])
        self.assertEqual(ov["repos"][0]["counts"]["total"], 3)
        self.assertIn("m2~005", [j["id"] for j in ov["live"]])

    def test_all_tree(self):
        self.ok(push("m1", [repo("o/other", [entry("001", files={"spec.md": "other"})])]))
        self.assertEqual(self.links(self.get("/all/jobs/")[1]), ["other~001/", "r~001/"])
        self.assertEqual(self.get_json("/all/jobs/r~001/job.json")["id"], "r~001")
        self.assertEqual(self.get("/all/jobs/other~001/spec.md")[1], "other")
        self.assertEqual(self.get_json("/all/hub")["overview"], "/")
        self.assertEqual(self.get("/all/dashboard.html")[0], 200)
        self.assertEqual(self.get("/all/.scratch/x/03.md")[0], 404)
        self.assertIn("prices_usd_per_mtok", self.get_json("/all/config.json"))
        self.assertEqual(len(self.get_json("/all/_subscriptions.json")["projects"]), 2)

    def test_all_tree_clash_uses_machine(self):
        self.ok(push("m2", [repo("o/r", [entry("001")])]))
        self.ok(push("m1", [repo("p/r", [entry("001")])]))
        names = self.links(self.get("/all/jobs/")[1])
        self.assertEqual(len(names), len(set(names)))
        self.assertEqual(len(names), 3)
        # o/r on m1 and p/r on m1 still clash after adding the machine: the owner is added too
        self.assertEqual(sorted(names), ["o~r~m1~001/", "p~r~m1~001/", "r~m2~001/"])
        self.assertEqual(self.get("/all/jobs/r~m2~001/job.json")[0], 200)


if __name__ == "__main__":
    unittest.main()

class TestReadApi(HubCase):
    def test_summaries_details_and_overview(self):
        e = entry("001", round=1, issue="12", round_limit=6,
                  files={"spec.md": "spec", "round-1/checks.md": "GATE: PASS\n",
                         "round-1/review-code.md": "VERDICT: CHANGES\n"},
                  agents={"builder": {"agent": "claude"}, "reviewers": {"code": {"agent": "codex"}}},
                  reviews={"code": "PASS"}, intake={"surfaces": ["ui"], "split": True},
                  history=[{"stage": "spec", "at": "2026-11-17T10:00:00Z"},
                           {"stage": "build", "round": 1, "at": "2026-11-17T10:10:00Z"}],
                  slices=[{"n": 1, "title": "one", "state": "done"}],
                  cost_breakdown=[{"role": "builder-s1", "agent": "claude", "model": "opus", "cost_usd": 1, "input_tokens": 10}],
                  diff_sizes={"1": {"files": 3, "insertions": 40, "deletions": 2}},
                  answers={"1": {"code F1": {"status": "fixed", "text": "done"}}},
                  builder_log=[{"round": 1, "builder": {"agent": "codex"}, "why": "changes"}],
                  accepted=[{"by": "person", "after": "spec"}],
                  follow_ups=[{"issue": "42", "title": "later"}], fork_point="abc", review_head="def")
        self.ok(push("neo", [repo("o/r", [e])]))
        result = self.get_json("/api/repos/o/r/jobs")
        self.assertEqual(result["machines"], ["neo"])
        j = result["jobs"][0]
        self.assertEqual((j["id"], j["key"], j["repo"]), ("001", "001", "o/r"))
        self.assertEqual(j["rounds"][0]["gate"], "PASS")
        self.assertEqual(j["rounds"][0]["reviews"], {"code": "CHANGES"})
        self.assertEqual(j["slices"][0]["title"], "one")
        self.assertEqual(j["history"][1]["from"], "spec")
        self.assertEqual(j["intake"]["surfaces"], ["ui"])
        self.assertEqual(j["tokens"]["input"], 10)
        self.assertEqual(j["cost_breakdown"][0]["role_base"], "builder")
        self.assertEqual(j["cost_breakdown"][0]["input_tokens"], 10)
        self.assertEqual(self.get_json("/api/overview")["live"][0]["job"], j)
        detail = self.get_json("/api/repos/o/r/jobs/001")
        self.assertEqual(detail["cost_breakdown"][0]["role_base"], "builder")
        self.assertEqual(detail["reviewers"][0]["lens"], "code")
        self.assertEqual(detail["round_reviews"][0]["verdict"], "CHANGES")
        self.assertEqual(detail["findings"][0]["answer"], "done")
        self.assertEqual(detail["builder_changes"][0]["reason"], "changes")
        self.assertEqual(detail["approvals"][0]["by"], "person")
        self.assertEqual(detail["follow_ups"][0]["issue"], "42")
        self.assertIn("round-1/checks.md", detail["files"])
        self.assertEqual((detail["fork_point"], detail["review_head"]), ("abc", "def"))
        self.assertEqual(self.get_json("/api/all/jobs")["jobs"][0]["id"], "r~001")
        self.assertTrue(self.get_json("/api/all/jobs")["jobs"][0]["href"].endswith("#job=001"))
        self.assertEqual(self.get_json("/api/all/jobs/r~001")["key"], "001")
        for path in ("/api/repos/no/repo/jobs", "/api/repos/o/r/jobs/missing", "/api/all/jobs/missing"):
            self.assertEqual(self.get(path)[0], 404)
        self.assertEqual(self.get("/api/all/jobs")[2].getheader("Cache-Control"), "no-store")

    def test_costs_removal_and_machine_ids(self):
        def cost_entry(key, day, amount, agent, model):
            return entry(key, started=day + "T10:00:00Z", cost=amount,
                         cost_breakdown=[{"role": "builder-s1", "agent": agent, "model": model,
                                          "cost_usd": amount, "input_tokens": 5}])
        self.ok(push("neo", [repo("o/r", [cost_entry("001", "2026-11-01", 2, "claude", "opus")])]))
        self.ok(push("trinity", [repo("o/r", [cost_entry("001", "2026-11-02", 3, "codex", "gpt")])]))
        ids = {j["id"] for j in self.get_json("/api/repos/o/r/jobs")["jobs"]}
        self.assertEqual(ids, {"neo~001", "trinity~001"})
        self.assertEqual(self.get_json("/api/repos/o/r/jobs/neo~001")["machine"], "neo")
        self.assertEqual(self.get_json("/api/all/jobs/r~neo~001")["machine"], "neo")
        for group, keys in [("day", {"2026-11-01", "2026-11-02"}), ("month", {"2026-11"}),
                            ("repo", {"o/r"}), ("agent", {"claude", "codex"}),
                            ("model", {"opus", "gpt"}), ("role", {"builder"})]:
            rows = self.get_json("/api/costs?group=" + group)["rows"]
            self.assertEqual({r["key"] for r in rows}, keys)
            self.assertAlmostEqual(sum(r["cost_usd"] for r in rows), 5)
        rows = self.get_json("/api/costs?group=day&repo=o%2Fr&since=2026-11-02&until=2026-11-02")["rows"]
        self.assertEqual([(r["key"], r["cost_usd"]) for r in rows], [("2026-11-02", 3)])
        self.ok(push("neo", [repo("o/r", [], ids=[])]))
        removed = self.get_json("/api/repos/o/r/jobs?removed=1")["jobs"]
        self.assertEqual(sum(j["removed"] for j in removed), 1)
        self.assertEqual(len(self.get_json("/api/repos/o/r/jobs")["jobs"]), 1)
        self.assertEqual(next(j["id"] for j in removed if not j["removed"]), "001")
        self.assertEqual(sum(r["cost_usd"] for r in self.get_json("/api/costs?group=repo")["rows"]), 5)
