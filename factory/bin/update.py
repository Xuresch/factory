#!/usr/bin/env python3
"""Update this installation from the factory template, keeping what's yours.

Usage:
  update [<source>] [--dry-run] [--force]

<source> is a git URL or a local checkout of the template (default: config.json
`template`, else https://github.com/Xuresch/factory). Append `@<ref>` for a
branch or tag.

What it does:
- factory/bin/*, dashboard.html, its JavaScript modules and package.json, factory/tests/*, the factory skill and
  every brief without project blocks: replaced by the template's version.
- factory/agents/*.md: the template's version, with this installation's
  `<!-- project: ... -->` ... `<!-- /project -->` blocks put back into the
  template's slots of the same kind (matched by the text after `project:`).
  A block with no matching slot is kept at the end of the file, and said so.
- factory/config.json: keys the template added are added, also inside nested
  objects (`labels.factory` into your `labels`); your values stay. Each update
  records the fetched template's version.
- Never touched: factory/checks.sh, factory/env.sh, factory/jobs/, and
  anything outside factory/ and .claude/skills/factory/.

It prints what changed and leaves committing to you. It refuses while a
merge, rebase or cherry-pick is in progress, or while the files it replaces
have uncommitted changes (`--force` skips the second check).

Changes made to factory/bin, the skill or the tests in this installation are
overwritten: port them to the template first.
"""

import json
import os
import re
import shutil
import subprocess
import sys
import tempfile
from datetime import date
from pathlib import Path

UPDATE = Path(__file__).resolve()
REPO = UPDATE.parents[2]
FACTORY = REPO / "factory"
CONFIG = json.loads((FACTORY / "config.json").read_text())
DEFAULT = CONFIG.get("template", "https://github.com/Xuresch/factory")
BLOCK_RE = re.compile(r"<!-- project: (.*?) -->\n(.*?)<!-- /project -->\n?", re.S)
NEVER = {"checks.sh", "env.sh", "cargo-env.sh"}


def die(msg):
    print(f"update: {msg}", file=sys.stderr)
    sys.exit(1)


def fetch(source, into):
    src, _, ref = source.partition("@")
    if Path(src).expanduser().is_dir():
        path = Path(src).expanduser().resolve()
        if ref:
            subprocess.run(["git", "-C", str(path), "worktree", "add", "--detach", str(into), ref],
                           check=True, capture_output=True)
            return into
        return path
    cmd = ["git", "clone", "--quiet", "--depth", "1"] + (["--branch", ref] if ref else []) + [src, str(into)]
    res = subprocess.run(cmd, capture_output=True, text=True)
    if res.returncode != 0:
        die(f"can't fetch {source}: {res.stderr.strip()}")
    return into


def template_version(tpl, source):
    git = ["git", "-C", str(tpl)]
    prefix = subprocess.run([*git, "rev-parse", "--show-prefix"], capture_output=True, text=True)
    # A plain directory inside another checkout has no template history of its own.
    if prefix.returncode == 0 and not prefix.stdout.strip():
        head = subprocess.run([*git, "log", "-1", "--format=%H%n%cI", "HEAD"],
                              capture_output=True, text=True)
        if head.returncode == 0:
            sha, committed = head.stdout.splitlines()
            return {"commit": sha, "date": committed, "source": source}
    return {"commit": None, "date": date.today().isoformat(), "source": source}


def run_template_update(tpl, update, argv):
    # Load the fetched code with the installation's script path, which older
    # updaters also use to find their destination. Keep the checkout alive
    # until the child exits so the parent can clean up the temporary directory.
    loader = """
import sys
from pathlib import Path

update = Path(sys.argv[1])
sys.argv = sys.argv[2:]
__file__ = sys.argv[0]
sys.path[0] = str(update.parent)
exec(compile(update.read_bytes(), str(update), "exec"))
"""
    env = {**os.environ, "FACTORY_UPDATE_TEMPLATE": str(tpl)}
    return subprocess.run([sys.executable, "-B", "-c", loader, str(update), str(UPDATE), *argv],
                          env=env).returncode


def merge_brief(mine, theirs):
    """The template's text with my project blocks in its slots of the same kind."""
    blocks = {kind: body for kind, body in BLOCK_RE.findall(mine)}
    used, notes = set(), []

    def fill(m):
        kind = m.group(1)
        if kind in blocks:
            used.add(kind)
            return f"<!-- project: {kind} -->\n{blocks[kind]}<!-- /project -->\n"
        return m.group(0)

    out = BLOCK_RE.sub(fill, theirs)
    for kind, body in blocks.items():
        if kind not in used:
            out = out.rstrip("\n") + f"\n\n<!-- project: {kind} -->\n{body}<!-- /project -->\n"
            notes.append(f"kept '{kind}' at the end: the template has no slot for it any more")
    return out, notes


def merge_config(mine, theirs, path=""):
    """Add the keys the template has and this repo's config.json doesn't. An agent
    entry ({"agent", "model", "effort"}) the repo set is kept whole: the template's
    effort belongs to the template's model, not to the one the repo chose."""
    added = []
    for key, value in theirs.items():
        if key not in mine:
            mine[key] = value
            added.append(path + key)
        elif isinstance(value, dict) and isinstance(mine[key], dict) and "agent" not in mine[key]:
            added += merge_config(mine[key], value, path + key + ".")
    return added


def differing(mine, theirs, path=""):
    """Values you have that differ from the template's: kept, but worth a look
    (a changed default reaches you only if you take it)."""
    out = []
    for key, value in theirs.items():
        if key in mine and isinstance(value, dict) and isinstance(mine[key], dict):
            out += differing(mine[key], value, path + key + ".")
        elif key in mine and mine[key] != value and key not in {"base_branch", "concurrency", "tracker"}:
            out.append(f"{path}{key}: yours {json.dumps(mine[key])}, template {json.dumps(value)}")
    return out


def busy():
    """Why updating now could clobber someone's work, or None."""
    git_dir = Path(subprocess.run(["git", "-C", str(REPO), "rev-parse", "--git-dir"],
                                  capture_output=True, text=True).stdout.strip() or ".git")
    git_dir = git_dir if git_dir.is_absolute() else REPO / git_dir
    for marker, what in [("MERGE_HEAD", "a merge"), ("CHERRY_PICK_HEAD", "a cherry-pick"),
                         ("REVERT_HEAD", "a revert"), ("rebase-merge", "a rebase"), ("rebase-apply", "a rebase")]:
        if (git_dir / marker).exists():
            return f"{what} is in progress in {REPO}; finish or abort it first"
    return None


def dirty():
    """Uncommitted changes in the files update replaces."""
    paths = ["factory/bin", "factory/tests", "factory/agents", "factory/config.json",
             "factory/dashboard.html", "factory/job-summary.js", "factory/cost-aggregation.js",
             "factory/package.json", ".claude/skills/factory"]
    out = subprocess.run(["git", "-C", str(REPO), "status", "--porcelain", "--", *paths],
                         capture_output=True, text=True).stdout
    return [l[3:] for l in out.splitlines() if "__pycache__" not in l]


def main(argv):
    dry = "--dry-run" in argv
    force = "--force" in argv
    args = [a for a in argv if a not in {"--dry-run", "--force"}]
    if not dry:
        if why := busy():
            die(why)
        if (changed := dirty()) and not force:
            die("uncommitted changes in files this would replace: " + ", ".join(changed)
                + "\ncommit or stash them first (or pass --force)")
    source = args[0] if args else DEFAULT
    fetched = os.environ.pop("FACTORY_UPDATE_TEMPLATE", None)
    with tempfile.TemporaryDirectory() as tmp:
        tpl = Path(fetched) if fetched else fetch(source, Path(tmp) / "template")
        tf = tpl / "factory"
        if not (tf / "bin" / "job").exists():
            die(f"{source} doesn't look like the factory template (no factory/bin/job)")
        version = template_version(tpl, source)
        config_path = FACTORY / "config.json"
        update = tf / "bin" / "update.py"
        if not update.is_file():
            update = update.with_suffix("")  # template from before the move
        if not fetched and update.is_file() and update.read_bytes() != UPDATE.read_bytes():
            status = run_template_update(tpl, update, argv)
            if status == 0 and not dry:
                # Older template updaters don't record the version themselves.
                config = json.loads(config_path.read_text())
                if config.get("template_version") != version:
                    config["template_version"] = version
                    config_path.write_text(json.dumps(config, indent=2) + "\n")
            return status
        changes, notes = [], []

        def put(dst, data):
            data = data.encode() if isinstance(data, str) else data  # test fixtures may not be UTF-8
            old = dst.read_bytes() if dst.exists() else None
            if old != data:
                changes.append(f"{'updated' if old is not None else 'added'} {dst.relative_to(REPO)}")
                if not dry:
                    dst.parent.mkdir(parents=True, exist_ok=True)
                    dst.write_bytes(data)

        for rel in ["bin", "tests"]:
            files = sorted((tf / rel).rglob("*"))
            if rel == "bin":
                files.sort(key=lambda f: f.suffix != ".py")  # Install implementations before launchers.
            for f in files:
                if f.is_file() and "__pycache__" not in f.parts:
                    dst = FACTORY / f.relative_to(tf)
                    put(dst, f.read_bytes())
                    if not dry and f.stat().st_mode & 0o111:
                        dst.chmod(dst.stat().st_mode | 0o755)
        for name in ["dashboard.html", "job-summary.js", "cost-aggregation.js", "package.json"]:
            if (tf / name).exists():
                put(FACTORY / name, (tf / name).read_text())
        if not (FACTORY / "env.sh").exists() and (tf / "env.sh").exists():  # older installs had none
            put(FACTORY / "env.sh", (tf / "env.sh").read_text())
        skill = tpl / ".claude" / "skills" / "factory" / "SKILL.md"
        if skill.exists():
            put(REPO / ".claude" / "skills" / "factory" / "SKILL.md", skill.read_text())
        for f in sorted((tf / "agents").glob("*.md")):
            dst = FACTORY / "agents" / f.name
            text = f.read_text()
            if dst.exists():
                text, n = merge_brief(dst.read_text(), text)
                notes += [f"{dst.name}: {x}" for x in n]
            put(dst, text)
        mine = json.loads(config_path.read_text())
        theirs = json.loads((tf / "config.json").read_text())
        theirs.pop("template_version", None)
        notes += [f"config {d}" for d in differing(mine, theirs)]
        added = merge_config(mine, theirs)
        if added:
            changes.append(f"config.json: added {', '.join(added)}")
        version_changed = mine.get("template_version") != version
        if version_changed:
            mine["template_version"] = version
            changes.append("config.json: updated template_version")
        if (added or version_changed) and not dry:
            config_path.write_text(json.dumps(mine, indent=2) + "\n")
        if (tf / "checks.sh").exists() and (FACTORY / "checks.sh").exists():
            notes.append("checks.sh and env.sh are yours and were left alone")
    print(("would change (dry run):" if dry else "changed:") if changes else "already up to date")
    for c in changes:
        print(f"  {c}")
    for n in notes:
        print(f"  note: {n}")
    if changes and not dry:
        print("Review with `git diff`, run factory/tests/run.sh, and commit.")


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
