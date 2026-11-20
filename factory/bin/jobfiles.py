"""How the factory reads a job folder: factory/jobs/<job-id>/.

The one reader of job.json's encoding and of the Markdown the agents and the
gate write there. `job`, `gate`, `route` and `report` read through it;
`job` stays the only writer (its `save` replaces job.json whole, so a reader
here never needs the job lock).

A Verdict is what a round artifact declares in its first line, and only there:

  review-<lens>.md   VERDICT: PASS | CHANGES
  checks.md          GATE: PASS | FAIL      (merge-checks.md too)

Whitespace after the colon is allowed. A missing artifact is `pending`; one
whose first line is empty, unreadable or anything else is `invalid`, even when
a later line declares a Verdict. The hub (hub/src/project.rs `verdict`) and the
standalone dashboard (dashboard.html `verdictOf`) apply the same rule;
factory/tests/fixtures/verdicts/ holds the cases all three are tested against.
Whether a declared Verdict lets the job move on (the Progression check) is the
lifecycle's judgment, not this module's.
"""

import hashlib
import json
import re
from pathlib import Path

PENDING, INVALID = "pending", "invalid"

# artifact kind -> (prefix, the Verdicts it may declare)
DECLARATIONS = {
    "review": ("VERDICT", ("PASS", "CHANGES")),
    "checks": ("GATE", ("PASS", "FAIL")),
}
# Unicode White_Space, matching Rust trim and JavaScript \p{White_Space}.
VERDICT_SPACE = (
    "\t\n\v\f\r \x85\xa0\u1680\u2000\u2001\u2002\u2003\u2004\u2005"
    "\u2006\u2007\u2008\u2009\u200a\u2028\u2029\u202f\u205f\u3000"
)


# ---- job.json ----------------------------------------------------------------


def job_path(jobs, job_id):
    return Path(jobs) / job_id / "job.json"


def read_job(path):
    """job.json decoded. OSError when it can't be read, ValueError when it isn't a
    JSON object. Safe without the job lock: `job save` replaces the file whole."""
    doc = json.loads(Path(path).read_text(encoding="utf-8"))
    if not isinstance(doc, dict):
        raise ValueError(f"{path}: not a JSON object")
    return doc


def load_job(jobs, job_id):
    """The job document of <jobs>/<job_id>, as `read_job` reads it."""
    return read_job(job_path(jobs, job_id))


def job_snapshot(path):
    """(document, sha1 of its raw bytes), or (None, None) when job.json is missing,
    unreadable, half-written or not an object: a reporter keeps what it had."""
    got = snapshot(path)
    if not got:
        return None, None
    try:
        doc = json.loads(got[0])
    except ValueError:
        return None, None
    return (doc, got[1]) if isinstance(doc, dict) else (None, None)


# ---- Markdown ----------------------------------------------------------------


def snapshot(path, *, unreadable=None):
    """(text, sha1 of the raw bytes) of a file, None when missing, the supplied
    fallback on other read errors. Bytes that aren't UTF-8 become U+FFFD."""
    try:
        raw = Path(path).read_bytes()
    except FileNotFoundError:
        return None
    except OSError:
        return unreadable
    return raw.decode("utf-8", errors="replace"), hashlib.sha1(raw).hexdigest()


def first_line(path):
    """A file's first line, stripped; None when there is no file."""
    path = Path(path)
    return path.read_text(encoding="utf-8").split("\n", 1)[0].strip() if path.exists() else None


def header(path):
    """KEY: value lines at the top of an agent's file, up to the first blank line.
    Metadata only (a checks.md's COMMIT, CHECKS_SH; intake's RISK): a Verdict
    comes from `verdict`."""
    return _parse_header(Path(path).read_text(encoding="utf-8"))


def _parse_header(text):
    fields = {}
    for line in text.splitlines():
        if not line.strip():
            break
        key, _, value = line.partition(":")
        fields[key.strip().upper()] = value.strip()
    return fields


def section(path, heading):
    """Body of a `## heading` section, or None."""
    text = Path(path).read_text(encoding="utf-8")
    m = re.search(rf"^## {re.escape(heading)}\n(.*?)(?=^## |\Z)", text, re.M | re.S)
    return m.group(1).strip() if m else None


# ---- Verdicts ----------------------------------------------------------------


def kind_of(path):
    """`review` or `checks` for a round artifact's file name, else None."""
    name = Path(path).name
    if name in ("checks.md", "merge-checks.md"):
        return "checks"
    if name.startswith("review-") and name.endswith(".md"):
        return "review"
    return None


def declared(kind, line):
    """The Verdict a first line declares for an artifact of `kind`: one of its
    values, `pending` for no artifact (None), else `invalid`."""
    if line is None:
        return PENDING
    prefix, values = DECLARATIONS[kind]
    key, colon, value = line.strip(VERDICT_SPACE).partition(":")
    value = value.lstrip(VERDICT_SPACE)
    return value if key == prefix and colon and value in values else INVALID


def _decode_verdict(kind, raw):
    try:
        line = raw.partition(b"\n")[0].decode("utf-8")
    except UnicodeDecodeError:
        return INVALID
    return declared(kind, line)


def verdict(kind, path):
    """The Verdict the artifact at `path` declares (see `declared`). Only the
    first line is read: an unreadable one (not UTF-8, no permission) is invalid."""
    path = Path(path)
    try:
        with path.open("rb") as f:
            raw = f.readline()
    except FileNotFoundError:
        return PENDING
    except OSError:
        return INVALID
    return _decode_verdict(kind, raw)


def checks(path):
    """Read the Verdict, COMMIT and CHECKS_SH from the same checks.md contents.
    Metadata comes from the header block and is None when unavailable."""
    v, h = INVALID, {}
    try:
        raw = Path(path).read_bytes()
        v = _decode_verdict("checks", raw)
        h = _parse_header(raw.decode("utf-8"))
    except FileNotFoundError:
        v = PENDING
    except (OSError, UnicodeDecodeError):
        pass
    return {"verdict": v, "commit": h.get("COMMIT"), "checks_sh": h.get("CHECKS_SH")}
