"""Session usage accounting: Claude Code transcripts and Codex rollouts, read and priced once.

bin/job, bin/dashboard and bin/report import this module. It takes explicit
session directories and the price table (config.json `prices_usd_per_mtok`),
so tests can point it at JSONL fixtures.

Reading a session gives a record of token counts, never dollars:

  claude: {factory, job_folder, role, cwd,
           msgs: {message id: [month, model, input, output, write_5m, write_1h, read]}}
  codex:  {factory, job_folder, role, cwd, sid, tokens,
           usage: {month: {model: {token field: n}}}}

A session is a factory session when one of its first lines names a
`Job folder: .../factory/jobs/<job>/`; `job_folder` is that path and `role` comes
from the worker's brief filename. `month` is the local YYYY-MM of the usage,
None when the line had no timestamp.

Claude usage is kept per message id, so a message copied into a resumed
transcript counts once. Codex token_count events carry running totals: each
event adds its growth since the one before, under the model of the turn it
falls in, so a session that changes models charges each increment at the rate
of the model in use. A repeated total adds nothing, and of two copies of one
session (two homes, a resumed file) only the one with the largest final total
counts.

usage_rows() turns records into usage rows, price() prices one row. Two
rollups sit on top: job_usage() for one job's cost (bin/job sync) and
scan_outside() for the sessions of no job (outside usage, the dashboard and
report), which caches each file's records so a price change needs no rescan.
"""

import json
import os
import re
from datetime import datetime
from pathlib import Path

FACTORY = Path(__file__).resolve().parents[1]
JOB_FOLDER = re.compile(r'Job folder: ([^\n]*?/factory/jobs/[^/\s"\\]+/)')
# Older briefs can mark a factory session without naming a slash-terminated job folder.
FACTORY_BRIEF = re.compile(r"Job folder: \S*/factory/jobs/")
ROLE = re.compile(r"factory/(?:agents/|jobs/(?:[^/\n]+/)+(?:[^/\n]*?-)?brief-)([\w-]+)\.md")
CLAUDE_HEAD, CODEX_HEAD = 40, 60  # a brief is in a session's first lines
CODEX_KEYS = ("input_tokens", "cached_input_tokens", "cache_write_input_tokens", "output_tokens", "total_tokens")
CACHE_VERSION = 3  # bump when a file's cached record changes shape; that drops the cache


# ---- where sessions live ---------------------------------------------------

def factory_config():
    return json.loads((FACTORY / "config.json").read_text())


def claude_projects_root():
    return Path(os.environ.get("CLAUDE_CONFIG_DIR") or Path.home() / ".claude") / "projects"


def claude_project_dirs():
    """Every Claude Code project directory on this machine."""
    return sorted(p for p in claude_projects_root().glob("*") if p.is_dir())


def codex_homes(extra=()):
    """Where Codex writes sessions: $CODEX_HOME or ~/.codex, every account Orca
    launches Codex workers with (~/.config/orca/codex-accounts/<id>/home), and
    config.json `codex_homes` (extra)."""
    homes = [Path(os.environ.get("CODEX_HOME") or Path.home() / ".codex")]
    homes += sorted((Path.home() / ".config" / "orca" / "codex-accounts").glob("*/home"))
    homes += [Path(p).expanduser() for p in extra]
    return list(dict.fromkeys(homes))


def codex_session_dirs(extra=()):
    return [home / "sessions" for home in codex_homes(extra)]


def cache_path():
    return Path(os.environ.get("XDG_CACHE_HOME") or Path.home() / ".cache") / "factory" / "usage.json"


def claude_transcripts(project_dirs):
    """Transcripts in Claude project directories, subagent transcripts included.
    A missing directory has none."""
    paths = []
    for d in project_dirs:
        d = Path(d)
        paths += sorted(d.glob("*.jsonl")) + sorted(d.glob("*/subagents/*.jsonl"))
    return list(dict.fromkeys(paths))


def codex_rollouts(session_dirs, since=None):
    """Rollout files, sessions/YYYY/MM/DD/rollout-*.jsonl, from day `since` (YYYY-MM-DD) on."""
    paths = []
    for d in session_dirs:
        for path in sorted(Path(d).glob("*/*/*/rollout-*.jsonl")):
            if since is None or "-".join(path.parts[-4:-1]) >= since:
                paths.append(path)
    return list(dict.fromkeys(paths))


# ---- reading one session ---------------------------------------------------

def month(ts):
    """Local YYYY-MM of an ISO timestamp, as the dashboard buckets job starts; None without one."""
    if not ts:
        return None
    try:
        return datetime.fromisoformat(ts.replace("Z", "+00:00")).astimezone().strftime("%Y-%m")
    except (AttributeError, ValueError):
        return None


def claude_user_text(entry):
    msg = entry.get("message")
    if entry.get("type") != "user" or not isinstance(msg, dict):
        return ""
    content = msg.get("content")
    if isinstance(content, str):
        return content
    return " ".join(b.get("text", "") for b in content or [] if isinstance(b, dict))


def role_of(text):
    """The role named in a rendered brief or its legacy source path."""
    m = ROLE.search(text)
    return m.group(1) if m else "unknown"


def read_claude(path, only=None):
    """The record of one Claude Code transcript (see the module docstring).

    only="outside" stops at a job brief, only="factory" stops when the first
    lines hold none: either way the record comes back without usage."""
    out = {"factory": False, "job_folder": None, "role": None, "cwd": None, "msgs": {}}
    with open(path, errors="replace") as f:
        for i, line in enumerate(f):
            if only == "factory" and not out["factory"] and i > CLAUDE_HEAD:
                break
            try:
                entry = json.loads(line)
            except ValueError:
                continue
            if not isinstance(entry, dict):
                continue
            out["cwd"] = out["cwd"] or entry.get("cwd")
            if i <= CLAUDE_HEAD and not out["factory"]:
                text = claude_user_text(entry)
                m = JOB_FOLDER.search(text)
                if m:
                    out.update(factory=True, job_folder=m.group(1), role=role_of(text))
                    if only == "outside":
                        return {**out, "msgs": {}}
                    continue
                if only == "outside" and FACTORY_BRIEF.search(text):
                    return {**out, "factory": True, "msgs": {}}
                if only == "factory":
                    continue
            msg = entry.get("message")
            if entry.get("type") != "assistant" or not isinstance(msg, dict) or not isinstance(msg.get("usage"), dict):
                continue
            u = msg["usage"]
            write_1h = (u.get("cache_creation") or {}).get("ephemeral_1h_input_tokens", 0) or 0
            row = [u.get("input_tokens", 0) or 0, u.get("output_tokens", 0) or 0,
                   (u.get("cache_creation_input_tokens", 0) or 0) - write_1h, write_1h,
                   u.get("cache_read_input_tokens", 0) or 0]
            if any(row):
                usage_month = month(entry.get("timestamp"))
                if usage_month is None and only == "outside":
                    continue
                out["msgs"][msg.get("id") or f"{path}:{i}"] = [usage_month, str(msg.get("model"))] + row
    if only == "factory" and not out["factory"]:
        out["msgs"] = {}
    return out


def read_codex(path, only=None):
    """The record of one Codex rollout (see the module docstring); `only` as in read_claude."""
    out = {"factory": False, "job_folder": None, "role": None, "cwd": None, "sid": Path(path).stem,
           "tokens": 0, "usage": {}}
    model, last = None, {}
    with open(path, errors="replace") as f:
        for i, line in enumerate(f):
            if i <= CODEX_HEAD and not out["factory"]:
                m = JOB_FOLDER.search(line)
                if m:
                    out.update(factory=True, job_folder=m.group(1), role=role_of(line))
                    if only == "outside":
                        return {**out, "usage": {}}
                elif only == "outside" and FACTORY_BRIEF.search(line):
                    return {**out, "factory": True, "usage": {}}
            elif only == "factory" and not out["factory"]:
                return {**out, "usage": {}}
            if '"session_meta"' not in line[:80] and '"turn_context"' not in line[:80] and '"token_count"' not in line:
                continue
            try:
                entry = json.loads(line)
            except ValueError:
                continue
            if not isinstance(entry, dict):
                continue
            p = entry.get("payload") or {}
            if not isinstance(p, dict):
                continue
            if entry.get("type") == "session_meta":
                out["sid"] = p.get("session_id") or p.get("id") or out["sid"]
                out["cwd"] = out["cwd"] or p.get("cwd")
            elif entry.get("type") == "turn_context":
                model = p.get("model") or model
            elif p.get("type") == "token_count" and isinstance(p.get("info"), dict) \
                    and isinstance(p["info"].get("total_token_usage"), dict):
                total = p["info"]["total_token_usage"]
                if not total:
                    continue
                grown = {k: (total.get(k, 0) or 0) - (last.get(k, 0) or 0) for k in CODEX_KEYS}
                last = total
                out["tokens"] = total.get("total_tokens", 0) or 0
                if grown["total_tokens"] <= 0:
                    continue
                row = out["usage"].setdefault(month(entry.get("timestamp")), {}).setdefault(str(model), {})
                for k, n in grown.items():
                    row[k] = row.get(k, 0) + n
    if only == "factory" and not out["factory"]:
        out["usage"] = {}
    return out


# ---- usage rows and prices -------------------------------------------------

def usage_rows(records):
    """Usage rows from {path: record with "kind"}: one per Claude message of a
    transcript, one per month and model of a Codex session's longest copy.

    A row is {agent, model, month, path, session, cwd, role, message, tokens};
    tokens are the buckets price() charges: claude input, cache_write_5m,
    cache_write_1h, cache_read, output; codex input (fresh), cache_write,
    cache_read, output."""
    best = {}
    for path, r in sorted(records.items()):
        if r["kind"] == "claude":
            for mid, (m, model, inp, outp, w5m, w1h, read) in r["msgs"].items():
                yield {"agent": "claude", "model": model, "month": m, "path": path, "session": path,
                       "cwd": r.get("cwd"), "role": r.get("role"), "message": mid,
                       "tokens": {"input": inp, "cache_write_5m": w5m, "cache_write_1h": w1h,
                                  "cache_read": read, "output": outp}}
        else:
            b = best.get(r["sid"])
            if not b or r["tokens"] > b[1]["tokens"]:
                best[r["sid"]] = (path, r)
    for path, r in best.values():
        for m, models in r["usage"].items():
            for model, u in models.items():
                cached = u.get("cached_input_tokens", 0)
                written = u.get("cache_write_input_tokens", 0)
                yield {"agent": "codex", "model": model, "month": m, "path": path, "session": r["sid"],
                       "cwd": r.get("cwd"), "role": r.get("role"), "message": None,
                       "tokens": {"input": u.get("input_tokens", 0) - cached - written, "cache_write": written,
                                  "cache_read": cached, "output": u.get("output_tokens", 0)}}


def price(row, prices):
    """API-equivalent dollars of one usage row; None when its model has no price."""
    p = prices.get(row["model"])
    if not p:
        return None
    t = row["tokens"]
    if row["agent"] == "claude":
        return (t["input"] * p["input"] + t["output"] * p["output"] + t["cache_write_5m"] * p["cache_write_5m"]
                + t["cache_write_1h"] * p["cache_write_1h"] + t["cache_read"] * p["cache_read"]) / 1e6
    return (t["input"] * p["input"] + t["cache_read"] * p["cached_input"]
            + t["cache_write"] * p.get("cache_write", p["input"]) + t["output"] * p["output"]) / 1e6


# ---- one job ---------------------------------------------------------------

def job_usage(job_folder, claude_dirs, codex_dirs, prices, since=None, on_unpriced=None):
    """One job's cost: ({"claude": usd, "codex": usd}, {(role, agent, model): row}).

    Counts the sessions whose brief names `job_folder` (".../factory/jobs/<job>/").
    A row is {role, agent, model, sessions, input_tokens, cached_tokens,
    output_tokens, cost_usd}; input_tokens includes cache writes, cached_tokens
    are cache reads. A session counts once in each row it adds to. A model
    without a price calls on_unpriced(model) and adds nothing. Undated usage
    counts. Totals are rounded to cents, rows are not."""
    records = {}
    for kind, paths, read in (("claude", claude_transcripts(claude_dirs), read_claude),
                              ("codex", codex_rollouts(codex_dirs, since), read_codex)):
        for path in paths:
            try:
                r = read(path, only="factory")
            except OSError:
                continue
            if r["job_folder"] == job_folder:
                records[str(path)] = {**r, "kind": kind}
    totals, rows, sessions = {"claude": 0.0, "codex": 0.0}, {}, {}
    for u in usage_rows(records):
        t = u["tokens"]
        if not any(t.values()):
            continue
        usd = price(u, prices)
        if usd is None:
            if on_unpriced:
                on_unpriced(u["model"])
            continue
        key = (u["role"] or "unknown", u["agent"], u["model"])
        row = rows.setdefault(key, {
            "role": key[0], "agent": key[1], "model": key[2], "sessions": 0,
            "input_tokens": 0, "cached_tokens": 0, "output_tokens": 0, "cost_usd": 0.0})
        row["input_tokens"] += t["input"] + t.get("cache_write", 0) + t.get("cache_write_5m", 0) + t.get("cache_write_1h", 0)
        row["cached_tokens"] += t["cache_read"]
        row["output_tokens"] += t["output"]
        row["cost_usd"] += usd
        totals[u["agent"]] += usd
        sessions.setdefault(key, set()).add(u["session"])
    for key, s in sessions.items():
        rows[key]["sessions"] = len(s)
    return {agent: round(usd, 2) for agent, usd in totals.items()}, rows


# ---- outside usage ---------------------------------------------------------

def outside_summary(records, prices):
    """{status, months: {month: {claude, codex}}, by_cwd: [...], unpriced: {month: {model: tokens}}, factory_sessions}.

    Factory sessions are counted, not priced: their job already is. Usage
    without a month is left out; a Claude message counts once across transcripts."""
    months, cwds, unpriced, seen = {}, {}, {}, set()
    factory_sessions = sum(1 for r in records.values() if r["factory"])
    for u in usage_rows({p: r for p, r in records.items() if not r["factory"]}):
        if u["month"] is None:
            continue
        if u["agent"] == "claude":
            if u["message"] in seen:
                continue
            seen.add(u["message"])
        usd = price(u, prices)
        if usd is None:
            row = unpriced.setdefault(u["month"], {})
            row[u["model"]] = row.get(u["model"], 0) + sum(u["tokens"].values())
            continue
        months.setdefault(u["month"], {"claude": 0.0, "codex": 0.0})[u["agent"]] += usd
        cwd = u["cwd"] or "?"
        c = cwds.setdefault(cwd, {"cwd": cwd, "claude": 0.0, "codex": 0.0, "sessions": set()})
        c[u["agent"]] += usd
        c["sessions"].add(u["path"])
    by_cwd = [{**c, "sessions": len(c["sessions"])} for c in cwds.values()]
    by_cwd.sort(key=lambda c: -(c["claude"] + c["codex"]))
    return {"status": "ready", "months": months, "by_cwd": by_cwd, "unpriced": unpriced,
            "factory_sessions": factory_sessions}


def dated(record):
    """The record as the cache keeps it: only usage with a month (JSON keys can't be None)."""
    if "msgs" in record:
        return {**record, "msgs": {k: v for k, v in record["msgs"].items() if v[0] is not None}}
    return {**record, "usage": {m: v for m, v in record["usage"].items() if m is not None}}


def outside_usage(claude_dirs, codex_dirs, prices, cache):
    """outside_summary() of every session in these directories, read through `cache`.

    A file whose size and mtime match its cache entry isn't read again. The
    cache only grows: a session Claude Code or Codex has since deleted keeps
    its entry, so its months stay counted. Entries hold tokens, priced here."""
    cache = Path(cache)
    try:
        data = json.loads(cache.read_text())
        files = data["files"] if data.get("version") == CACHE_VERSION else {}
    except (OSError, ValueError, KeyError, AttributeError):
        files = {}
    changed = False
    for kind, paths, read in (("claude", claude_transcripts(claude_dirs), read_claude),
                              ("codex", codex_rollouts(codex_dirs), read_codex)):
        for path in paths:
            try:
                st = path.stat()
            except OSError:
                continue
            stamp = [st.st_size, st.st_mtime_ns]
            old = files.get(str(path))
            if old and old.get("stamp") == stamp:
                continue
            try:
                record = read(path, only="outside")
            except OSError:
                continue
            files[str(path)] = {"stamp": stamp, "kind": kind, **dated(record)}
            changed = True
    if changed:
        cache.parent.mkdir(parents=True, exist_ok=True)
        tmp = cache.with_suffix(".tmp")
        tmp.write_text(json.dumps({"version": CACHE_VERSION, "files": files}))
        tmp.replace(cache)
    return outside_summary(files, prices)


def scan_outside(cfg=None, cache=None):
    """Outside usage on this machine: every Claude project, every Codex home,
    config.json's prices and `codex_homes`, cached in ~/.cache/factory/usage.json."""
    cfg = cfg if cfg is not None else factory_config()
    return outside_usage(claude_project_dirs(), codex_session_dirs(cfg.get("codex_homes", [])),
                         cfg["prices_usd_per_mtok"], cache or cache_path())
