#!/usr/bin/env python3
"""The deterministic gate: does the job's branch pass the repo's checks?

Usage:
  gate <job-id>            write round-N/checks.md; exit 0 on PASS, 1 on FAIL (job in stage gate)
  gate <job-id> --merge    same, as round-N/merge-checks.md (job merge runs it)
  gate --hook              builder SubagentStop hook: run the checks once, exit 2 on failure

The gate runs the main checkout's factory/checks.sh inside the job's worktree,
so a branch can't change the checks it is judged by. It also fails when the
branch modifies or deletes a file matching config.json `protected_paths`
(fnmatch patterns, where `*` also matches `/`). Adding new files is fine.

The round gate also checks the commit format, for jobs whose job.json says
`commit_format: conventional` (every job created since the rule came in): each
non-merge commit since the base, and the PR title on GitHub, must be a
Conventional Commits line (config.json `commit_types`), at most 72 characters,
with no trailing period. checks.md says how to reword them.

Gates and the builder's self-check use the repository's heavy command pool.
A gate that waits names the holder once. checks.md records the wait separately
from checks.sh's own time.

checks.log and checks.md have ANSI color codes removed. checks.md lists the
lines that look like failures under `## Failures`, with the first one's
context, above the log's tail.

The merge gate reuses the round gate's PASS instead of running checks.sh again
when nothing it would judge changed: the merge commit is the commit checks.md
passed (the base sync brought nothing), checks.sh is byte for byte the one that
ran, and checks.sh doesn't read FACTORY_GATE (a repo that runs less in a round
always gets the full merge run).
"""

import hashlib
import fnmatch
import json
import os
import re
import subprocess
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
import heavy  # noqa: E402
import jobfiles  # noqa: E402  (factory/bin/jobfiles.py: how a job folder reads)

REPO = Path(__file__).resolve().parents[2]
FACTORY = REPO / "factory"
CONFIG = json.loads((FACTORY / "config.json").read_text())
CHECKS = FACTORY / "checks.sh"
TAIL = 80
PASS_TAIL = 20


def die(msg):
    print(f"gate: {msg}", file=sys.stderr)
    sys.exit(2)


def git(worktree, *args):
    res = subprocess.run(["git", *args], cwd=worktree, capture_output=True, text=True)
    if res.returncode != 0:
        die(f"`git {' '.join(args)}` failed: {res.stderr.strip()}")
    return res.stdout


def protected_changes(worktree, base_ref):
    """Existing files under protected_paths that the branch modified or deleted."""
    diff = git(worktree, "diff", "--name-status", f"{base_ref}...HEAD")
    hits = []
    for line in diff.splitlines():
        status, *paths = line.split("\t")
        if status.startswith("A"):
            continue
        old = paths[0]  # for renames and copies, the original path
        if any(fnmatch.fnmatch(old, pattern) for pattern in CONFIG["protected_paths"]):
            hits.append(f"{status[0]} {old}")
    return hits


TRAILER_RE = r"^(co-authored-by:|.*generated with \[?claude code)"


def strip_trailers(worktree, base_ref, branch, push):
    """Remove Co-Authored-By and "Generated with" lines from the branch's own
    commits (nobody co-authors a factory job). Rewrites only when one exists;
    the trees stay the same. Returns how many commits had one."""
    import re
    log = git(worktree, "log", "--format=%H%x00%B%x01", f"{base_ref}..HEAD")
    dirty = [c for c in log.split("\x01") if c.strip()
             and re.search(TRAILER_RE, c.split("\x00", 1)[-1], re.I | re.M)]
    if not dirty or subprocess.run(["git", "status", "--porcelain"], cwd=worktree,
                                   capture_output=True, text=True).stdout.strip():
        return 0
    script = ("sed -E '/^[Cc][Oo]-[Aa][Uu][Tt][Hh][Oo][Rr][Ee][Dd]-[Bb][Yy]:/d; "
              "/[Gg]enerated with \\[?Claude Code/d' | git stripspace")
    env = dict(os.environ, FILTER_BRANCH_SQUELCH_WARNING="1")
    res = subprocess.run(["git", "filter-branch", "-f", "--msg-filter", script, "--", f"{base_ref}..{branch}"],
                         cwd=worktree, capture_output=True, text=True, env=env)
    if res.returncode != 0:
        print(f"gate: couldn't strip commit trailers: {res.stderr.strip()[:500]}", file=sys.stderr)
        return 0
    subprocess.run(["git", "update-ref", "-d", f"refs/original/refs/heads/{branch}"], cwd=worktree,
                   capture_output=True)
    if push:
        subprocess.run(["git", "push", "--force-with-lease", "origin", branch], cwd=worktree, capture_output=True)
    return len(dirty)


COMMIT_TYPES = ["feat", "fix", "docs", "style", "refactor", "perf", "test", "build", "ci", "chore", "revert"]
MAX_SUBJECT = 72


def subject_problem(subject):
    """Why a commit subject or PR title isn't a Conventional Commits line, or None."""
    types = CONFIG.get("commit_types") or COMMIT_TYPES
    if not re.match(rf"^({'|'.join(map(re.escape, types))})(\([^)]+\))?!?: \S.*", subject):
        return f"isn't `<type>(<scope>): <summary>` with a type from {', '.join(types)}"
    if len(subject) > MAX_SUBJECT:
        return f"is {len(subject)} characters, over {MAX_SUBJECT}"
    if subject.endswith("."):
        return "ends with a period"
    return None


def pr_title(job):
    """The job's PR title on GitHub, or None (no PR yet, or gh failed)."""
    if job.get("tracker") != "github" or not job.get("pr"):
        return None
    res = subprocess.run(["gh", "pr", "view", str(job["pr"]), "--json", "title"], cwd=REPO,
                         capture_output=True, text=True)
    try:
        return json.loads(res.stdout).get("title") if res.returncode == 0 else None
    except ValueError:
        return None


def commit_format(job, worktree, base_ref):
    """checks.md's `## Commit format` body for the job's own commits and PR
    title, or "" when they all pass. Only jobs created under the rule
    (job.json `commit_format: conventional`) are checked."""
    if job.get("commit_format") != "conventional":
        return ""
    log = git(worktree, "log", "--no-merges", "--format=%H%x00%s", f"{base_ref}..HEAD")
    bad = [(sha, subj, why) for sha, subj in (l.split("\x00", 1) for l in log.splitlines() if l)
           for why in [subject_problem(subj)] if why]
    title = pr_title(job)
    title_why = subject_problem(title) if title is not None else None
    if not bad and not title_why:
        return ""
    branch, out = job["branch"], []
    if bad:
        cases = "\n".join(f'    {sha}) echo "<new subject>"; sed 1d ;;' for sha, _, _ in bad)
        out += ["Commit subjects on the job branch must be `<type>(<scope>): <summary>`, imperative, "
                f"at most {MAX_SUBJECT} characters, no trailing period:", ""]
        out += [f"- `{sha[:7]}` `{subj}`: {why}" for sha, subj, why in bad]
        out += ["", f"Reword them, only on {branch} and only these commits: put each new subject in "
                "the commands below" + (", which force-push the job branch" if job.get("tracker") == "github" else "")
                + ". Change nothing else.", "",
                "```", f"cd {worktree} && FILTER_BRANCH_SQUELCH_WARNING=1 git filter-branch -f --msg-filter '",
                '  case "$GIT_COMMIT" in', cases, "    *) cat ;;", "  esac' -- " + f"{base_ref}..{branch}",
                f"cd {worktree} && git update-ref -d refs/original/refs/heads/{branch}"]
        if job.get("tracker") == "github":
            out += [f"cd {worktree} && git push --force-with-lease origin {branch}"]
        out += ["```", ""]
    if title_why:
        out += [f"The PR title `{title}` {title_why}. Fix it:", "",
                "```", f'gh pr edit {job["pr"]} --title "<type>(<scope>): <summary>"', "```", ""]
    return "\n".join(out)


def run_checks(job, base_ref=None, mode="full"):
    """Run checks.sh in a shared slot with its round, merge or full settings."""
    env = dict(os.environ, FACTORY_GATE=mode)
    wait_fd = env.pop("FACTORY_GATE_WAIT_FD", None)
    if base_ref:
        env["FACTORY_BASE_REF"] = base_ref
    role = "builder" if mode == "full" else "gate"
    result = heavy.run(REPO, CONFIG, ["bash", str(CHECKS)], cwd=job["worktree"],
                       env=env, job=job["id"], role=role, prefix="gate", capture=True)
    if mode == "merge" and wait_fd is not None:
        with os.fdopen(int(wait_fd), "w") as wait:
            wait.write(str(result.waited))
    else:
        heavy.record_wait(REPO, job["id"], role, result.waited)
    return result


ANSI_RE = re.compile(r"\x1b\[[0-?]*[ -/]*[@-~]|\x1b\][^\x07\x1b]*(?:\x07|\x1b\\)|\x1b[@-Z\\-_]")


def strip_ansi(text):
    """The log without color and cursor codes; a carriage-return redraw keeps its last state."""
    text = ANSI_RE.sub("", text).replace("\r\n", "\n")
    return "\n".join(line.rsplit("\r", 1)[-1] for line in text.split("\n"))


# Lines test runners and compilers print for a failure: pytest, unittest, jest,
# vitest, go test, cargo, tsc, mocha, the factory's own tests.
FAILURE_RE = re.compile(
    r"\bFAILED\b|^\s*!! |\bFAIL\b|✗|✘|×|\bError:|\berror TS\d+|\berror(\[E\d+\])?:|panicked"
    r"|^\s*--- FAIL|AssertionError|^\s*not ok \d+")
MAX_FAILURES = 40
BLOCK_AFTER = 15


def failures(log):
    """(distinct failure lines, at most MAX_FAILURES; the first one with
    BLOCK_AFTER lines of context after it)."""
    lines = log.splitlines()
    hits = [i for i, line in enumerate(lines) if FAILURE_RE.search(line)]
    seen, distinct = set(), []
    for i in hits:
        key = lines[i].strip()
        if key not in seen:
            seen.add(key)
            distinct.append(key)
    block = lines[hits[0]:hits[0] + 1 + BLOCK_AFTER] if hits else []
    return distinct[:MAX_FAILURES], len(distinct), block


def failures_section(log):
    """checks.md's `## Failures` for a failed run."""
    distinct, total, block = failures(log)
    if not distinct:
        return "## Failures\nNo line looks like a failure summary; see the tail below.\n\n"
    more = f"\n- ... and {total - len(distinct)} more in the log" if total > len(distinct) else ""
    return ("## Failures\n" + "\n".join(f"- `{d}`" if "`" not in d else f"- {d}" for d in distinct) + more
            + "\n\nThe first failure:\n\n```\n" + "\n".join(block) + "\n```\n\n")


WAIT_NOTE_MINUTES = 5


def waited_minutes(job):
    """Minutes between the job entering `gate` and this run, from its history."""
    from datetime import datetime, timezone
    entered = [h["at"] for h in job.get("history") or [] if h.get("stage") == "gate"]
    if not entered:
        return None
    at = datetime.fromisoformat(entered[-1].replace("Z", "+00:00"))
    return int((datetime.now(timezone.utc) - at).total_seconds() // 60)


def checks_hash():
    """sha1 of checks.sh as it is now: checks.md records which script judged."""
    return hashlib.sha1(CHECKS.read_bytes()).hexdigest()


def reusable(checks_md, commit):
    """True when the round's checks.md declares PASS for this very commit with this very
    checks.sh, and checks.sh runs the same at merge as in a round (it never reads FACTORY_GATE)."""
    got = jobfiles.checks(checks_md)
    if got["verdict"] != "PASS":
        return False
    code = [l for l in CHECKS.read_text().splitlines() if not l.lstrip().startswith("#")]
    return (got["commit"] == commit and got["checks_sh"] == checks_hash()
            and not any("FACTORY_GATE" in l for l in code))


def gate(job_id, merge):
    job = jobfiles.load_job(FACTORY / "jobs", job_id)
    worktree = job["worktree"]
    if job["round"] < 1:
        die(f"{job_id} hasn't started a build round")
    # A round gate outside `gate` writes a checks.md nothing reads, or overwrites the one
    # a review already judged. `job merge` runs the merge gate itself, in `merging`.
    if not merge and job["stage"] != "gate":
        die(f"{job_id} is in {job['stage']}, not gate: the round gate runs after "
            f"`factory/bin/job advance {job_id} gate`; `job next {job_id}` says what to do now")
    round_dir = FACTORY / "jobs" / job_id / f"round-{job['round']}"
    # Local trackers have no remote: the job records which base ref it forked from.
    base_ref = job.get("base_ref", f"origin/{CONFIG['base_branch']}")
    stripped = strip_trailers(worktree, base_ref, job["branch"], bool(job.get("pr")))
    commit = git(worktree, "rev-parse", "HEAD").strip()
    protected = protected_changes(worktree, base_ref)
    commits = "" if merge else commit_format(job, worktree, base_ref)
    if merge and reusable(round_dir / "checks.md", commit):
        (round_dir / "merge-checks.md").write_text(
            f"GATE: PASS\nCOMMIT: {commit}\n\n## Summary\n"
            f"- Reused round {job['round']}'s gate (checks.md): the merge commit {commit[:7]} is the commit it "
            "passed, the base sync brought nothing new, and checks.sh is unchanged and runs the same in a "
            "round as at merge\n"
            f"- Protected paths: {'changed: ' + ', '.join(protected) if protected else 'none changed'}\n\n"
            "## Protected paths\n" + ("\n".join(f"- {p}" for p in protected) if protected else "None changed.") + "\n")
        if not protected:
            print(f"GATE: PASS ({job_id} round {job['round']}, reused checks.md: same commit {commit[:7]})")
            sys.exit(0)
    waited = waited_minutes(job) if not merge else None
    result = run_checks(job, base_ref, "merge" if merge else "round")
    code, log, seconds = result.returncode, strip_ansi(result.stdout or ""), int(result.seconds)
    other, queued = result.blocked_by, int(result.waited)
    verdict = "PASS" if code == 0 and not protected and not commits else "FAIL"
    name = "merge-checks" if merge else "checks"
    (round_dir / f"{name}.log").write_text(log)
    lines = TAIL if verdict == "FAIL" else PASS_TAIL
    tail = "\n".join(log.rstrip().splitlines()[-lines:])
    summary = [
        f"checks.sh {'passed' if code == 0 else f'failed with exit {code}'} in {seconds}s",
        f"Protected paths: {'changed: ' + ', '.join(protected) if protected else 'none changed'}",
        f"Commit {commit[:7]}" + (", synced with the latest main before merging" if merge else ""),
    ]
    if commits:
        summary.append("Commit format: a commit subject or the PR title isn't Conventional Commits "
                       "(see `## Commit format`)")
    if stripped:
        summary.append(f"Removed Co-Authored-By / Generated-with lines from {stripped} commit"
                       + ("" if stripped == 1 else "s") + " (nobody co-authors a factory job)")
    if other is not None:
        holder = (f"another gate ({other['job']})" if other.get("role") == "gate" and other.get("job")
                  else f"a heavy command ({heavy.describe(other)})")
        summary.append(f"Waited {queued}s for {holder} before checks.sh ran; not counted in its {seconds}s")
    if waited is not None and waited >= WAIT_NOTE_MINUTES:
        summary.append(f"The gate ran {waited} min after the job entered `gate`: that time went to "
                       f"waiting for the orchestrator, not to checks.sh ({seconds}s)")
    (round_dir / f"{name}.md").write_text(
        f"GATE: {verdict}\nCOMMIT: {commit}\nCHECKS_SH: {checks_hash()}\n\n"
        "## Summary\n" + "\n".join(f"- {s}" for s in summary) + "\n\n"
        "## Protected paths\n"
        + ("\n".join(f"- {p}" for p in protected) if protected else "None changed.") + "\n\n"
        + (f"## Commit format\n{commits}\n" if commits else "")
        + (failures_section(log) if code != 0 else "")
        + f"## checks.sh\nExit {code} in {seconds}s. Last {lines} lines of {name}.log:\n\n```\n{tail}\n```\n"
    )
    print(f"GATE: {verdict} ({job_id} round {job['round']}, checks.sh exit {code} in {seconds}s"
          + (f", after waiting {queued}s for {heavy.gate_holder(other)}" if other is not None else "")
          + (f", protected paths changed: {', '.join(protected)}" if protected else "")
          + (", commit format" if commits else "") + ")")
    sys.exit(0 if verdict == "PASS" else 1)


def hook():
    event = json.load(sys.stdin)
    if event.get("stop_hook_active"):
        sys.exit(0)  # one nudge per stop; the gate decides
    with open(Path(event["agent_transcript_path"]).expanduser()) as f:
        content = json.loads(f.readline())["message"]["content"]
    prompt = content if isinstance(content, str) else " ".join(b.get("text", "") for b in content)
    job_id = prompt.split("Job: ", 1)[1].split(".", 1)[0]
    job = jobfiles.load_job(FACTORY / "jobs", job_id)
    result = run_checks(job)
    code, log = result.returncode, strip_ansi(result.stdout or "")
    if code != 0:
        tail = "\n".join(log.rstrip().splitlines()[-40:])
        print(f"factory/checks.sh fails in your worktree (exit {code}). The gate will reject this "
              f"build. Fix it, or write STATUS: BLOCKED in build.md if you can't.\n\n{tail}",
              file=sys.stderr)
        sys.exit(2)


def main(argv):
    if argv == ["--hook"]:
        hook()
    elif len(argv) == 1 and not argv[0].startswith("-"):
        gate(argv[0], merge=False)
    elif len(argv) == 2 and argv[1] == "--merge":
        gate(argv[0], merge=True)
    else:
        die(__doc__.strip())


if __name__ == "__main__":
    main(sys.argv[1:])
