"""Generate the round gate's evidence report from the branch and its check run."""

import json
import re
import shutil
import stat
import subprocess
from pathlib import Path
from time import monotonic


SOURCE_SUFFIXES = set(".bash .c .cc .cjs .clj .cpp .cs .css .dart .ex .exs .go .h .hpp .html "
                      ".java .js .jsx .kt .lua .m .mjs .php .py .rb .rs .scala .sh .sql .svelte "
                      ".swift .ts .tsx .vue .zig .zsh".split())
TEST_DIRS = {"test", "tests", "__tests__", "spec", "specs", "e2e"}
TEST_PREFIX = re.compile(r"^(?:test|spec)[_.-]")
TEST_SUFFIX = re.compile(r"(?:[_.-](?:test|spec|testcase|integration|e2e|node))+$")
HUNK = re.compile(r"^@@ -\d+(?:,\d+)? \+(\d+)(?:,(\d+))? @@", re.M)
CRITERION = re.compile(r"^\s*(?:\d+[.)]|[-*])\s+(?:\[[ xX]\]\s+)?(.+)$")
TEST_REF = re.compile(r"\bTest:\s*(?:`([^`\n]+::[^`\n]+)`|([^`\n]+?::[^`\n]+)(?=$|\s+Test:))")
CHANGE_ENTRY = re.compile(r"^\s*(?:[-*+]\s+|\d+[.)]\s+)?(?:\*\*)?(?:`([^`]+)`|([^\s:*]+))")
SYMBOL = re.compile(r"^- `([^`]+)` \([^\n]+?\).* — :(\d+)[ \t]*$", re.M)
CALLER_LIMIT = 5
COMMAND_TIMEOUT = 15
CODEGRAPH_BUDGET = 120
INPUT_ERRORS = (OSError, ValueError, subprocess.SubprocessError)


class GraphBudgetExhausted(Exception):
    pass


def command(worktree, *args, timeout=COMMAND_TIMEOUT):
    return subprocess.run(args, cwd=worktree, check=True, capture_output=True,
                          text=True, errors="replace", timeout=timeout).stdout


def graph_command(worktree, deadline, *args):
    remaining = deadline - monotonic()
    if remaining <= 0:
        raise GraphBudgetExhausted
    try:
        return command(worktree, "codegraph", *args, timeout=min(COMMAND_TIMEOUT, remaining))
    except subprocess.TimeoutExpired:
        if remaining <= COMMAND_TIMEOUT or monotonic() >= deadline:
            raise GraphBudgetExhausted from None
        raise


def changed_paths(worktree, revision):
    fields = iter(command(worktree, "git", "diff", "--name-status", "-z", "--find-renames",
                          revision, "--").rstrip("\0").split("\0"))
    paths = {}
    for status in fields:
        if status:
            path = next(fields)
            paths[next(fields) if status.startswith(("R", "C")) else path] = (status, path)
    return dict(sorted(paths.items()))


def diff_ranges(worktree, revision, path, original):
    patch = command(worktree, "git", "--literal-pathspecs", "diff", "--no-color", "--no-ext-diff", "--no-textconv",
                    "--find-renames", "--unified=0", revision, "--", *dict.fromkeys((original, path)))
    return [(int(start), int(start) + int(count or 1) - 1) for start, count in HUNK.findall(patch)]


def read_input(path, label, inputs):
    try:
        return path.read_text(encoding="utf-8")
    except FileNotFoundError:
        inputs.append(f"{label}: missing.")
    except INPUT_ERRORS:
        inputs.append(f"{label}: could not read.")
    return None


def repository_path(value):
    return value.removeprefix("./")


def is_branch_directory(worktree, path):
    try:
        return command(worktree, "git", "cat-file", "-t", f"HEAD:{path}").strip() == "tree"
    except INPUT_ERRORS:
        return False


def claims(worktree, build, log, paths, inputs):
    lines, contradictions = [], 0
    if build is None:
        return lines, contradictions
    sections = re.split(r"^(#{1,6}) +([^\n]+)\n", build, flags=re.M)
    criteria, changes = [], []
    criteria_level = None
    for marks, heading, body in zip(sections[1::3], sections[2::3], sections[3::3]):
        title, level = heading.strip().lower(), len(marks)
        if criteria_level is not None and level <= criteria_level:
            criteria_level = None
        if title == "changes":
            changes.append(body)
        if title == "acceptance criteria" and criteria_level is None:
            criteria_level = level
        if criteria_level is None:
            continue
        block = []
        for line in body.splitlines():
            match = CRITERION.match(line)
            if match:
                block.append(match[1])
            elif block and line.strip():
                block[-1] += " " + line.strip()
        criteria.extend(block)
    if not criteria:
        inputs.append("build.md: no criteria found.")
    blobs = {}
    for index, criterion in enumerate(criteria, 1):
        refs = TEST_REF.findall(criterion)
        if not refs:
            lines.append(f"- Criterion {index} has no `Test:` reference ({criterion}).")
        for quoted, plain in refs:
            file, name = map(str.strip, (quoted or plain).split("::", 1))
            file = repository_path(file)
            if not file or not name:
                lines.append(f"- Criterion {index} has an incomplete `Test:` reference.")
                continue
            if file not in blobs:
                try:
                    blobs[file] = command(worktree, "git", "cat-file", "blob", f"HEAD:{file}")
                except subprocess.CalledProcessError:
                    blobs[file] = None
                except INPUT_ERRORS:
                    inputs.append(f"Git: could not read `{file}` at HEAD.")
                    continue
            content = blobs[file]
            outcomes = ["file exists on branch" if content is not None else "file missing on branch"]
            if content is not None:
                outcomes.append("name found in file" if name in content else "name missing from file")
            outcomes.append("file changed" if paths is not None and file in paths else
                            "file unchanged" if paths is not None else "diff unavailable")
            outcomes.append("gate log unavailable" if log is None else
                            "seen in the gate log" if name in log or file in log else "not seen in the gate log")
            contradicts = content is None or name not in content
            contradictions += contradicts
            label = " **Contradiction.**" if contradicts else ""
            lines.append(f"- Criterion {index}, `{file}::{name}`.{label} " + ", ".join(outcomes) + ".")

    if not changes:
        inputs.append("build.md: no Changes section found.")
    elif paths is not None:
        named = set()
        for line in "\n".join(changes).splitlines():
            if entry := CHANGE_ENTRY.match(line):
                named.add(repository_path(entry[1] or entry[2]).rstrip(","))
        covered = set()
        rename_sources = {original for status, original in paths.values() if status.startswith("R")}
        for file in sorted(named):
            if file in paths:
                covered.add(file)
                if paths[file][0] != "D":
                    continue
            directory = file.endswith("/") or is_branch_directory(worktree, file)
            if directory:
                prefix = file.rstrip("/") + "/"
                descendants = {path for path in paths if path.startswith(prefix)}
                covered.update(descendants)
                if descendants or any(path.startswith(prefix) for path in rename_sources):
                    continue
            if file not in paths and (directory or "/" in file or Path(file).suffix or file.isupper()):
                lines.append(f"- **Contradiction.** `## Changes` names `{file}`, which the diff does not touch.")
                contradictions += 1
        for file in sorted(paths.keys() - covered):
            lines.append(f"- The diff changes `{file}` without an entry in `## Changes` (not a contradiction).")
    return lines, contradictions


def test_key(path):
    return TEST_SUFFIX.sub("", TEST_PREFIX.sub("", Path(path).stem))


def is_test(path):
    return bool(TEST_DIRS.intersection(Path(path).parts[:-1])) or test_key(path) != Path(path).stem


def graph(worktree, path, ranges, inputs, deadline):
    """Read CodeGraph's symbol map and its JSON lists, without parsing source code."""
    affected, symbols = [], []
    try:
        output = json.loads(graph_command(worktree, deadline, "affected", "--json", "--", path))
        tests = output.get("affectedTests") if isinstance(output, dict) else None
        if not isinstance(tests, list) or not all(isinstance(test, str) for test in tests):
            raise ValueError("expected affectedTests")
        affected = sorted(set(tests))
    except INPUT_ERRORS:
        inputs.append(f"CodeGraph: affected tests unavailable for `{path}`.")

    try:
        output = graph_command(worktree, deadline, "node", "--symbols-only", "--file", path)
    except INPUT_ERRORS:
        inputs.append(f"CodeGraph: symbol map unavailable for `{path}`.")
        return affected, symbols
    if f"**{path}**" not in output:
        inputs.append(f"CodeGraph: no indexed symbol map for `{path}`.")
        return affected, symbols
    rows = sorted((int(start), name) for name, start in SYMBOL.findall(output))
    starts = sorted({start for start, _ in rows})
    boundaries = dict(zip(starts, starts[1:]))
    more = re.search(r"^- … \+(\d+) more$", output, re.M)
    if more:
        inputs.append(f"CodeGraph: `{path}` symbol map omits {more[1]} symbols.")
    for start, symbol in rows:
        # node prints start lines only. Attribute each hunk to the nearest preceding
        # declaration in the returned map. With a truncated map, stop at its last start.
        end = boundaries.get(start, start + 1 if more else float("inf"))
        if not any(lo < end and max(lo, hi) >= start for lo, hi in ranges):
            continue
        try:
            result = json.loads(graph_command(worktree, deadline, "callers", "--json", "--limit",
                                              "2147483647", "--", symbol))
            callers = sorted({f"{row['name']} ({row['filePath']}:{row['startLine']})" for row in result["callers"]})
            listing = ", ".join(f"`{caller}`" for caller in callers[:CALLER_LIMIT]) or "none returned"
            if len(callers) > CALLER_LIMIT:
                listing += f", and {len(callers) - CALLER_LIMIT} more"
        except (*INPUT_ERRORS, KeyError, TypeError):
            listing = "unavailable from CodeGraph"
        symbols.append(f"  - `{symbol}` at line {start}. Callers: {listing}.")
    return affected, symbols


def coverage_snapshot(worktree, config):
    """Remember the configured file before checks so a prior run cannot supply coverage."""
    if not config:
        return None, None, "LCOV: report.coverage_lcov is unset."
    try:
        root = Path(worktree).resolve()
        path = (root / config).resolve()
        if Path(config).is_absolute() or not path.is_relative_to(root) or path == root:
            raise ValueError("expected a path in the worktree")
        try:
            info = path.stat()
        except FileNotFoundError:
            return path, None, None
        if not stat.S_ISREG(info.st_mode):
            raise ValueError("expected a regular file")
        return path, (info.st_dev, info.st_ino, info.st_size, info.st_mtime_ns, info.st_ctime_ns), None
    except (*INPUT_ERRORS, RuntimeError, TypeError):
        return None, None, "LCOV: report.coverage_lcov must name an accessible file inside the worktree."


def coverage_records(worktree, before, after, inputs):
    path, stamp, message = after
    message = message or before[2]
    if message:
        inputs.append(message)
    elif stamp is None:
        inputs.append("LCOV: configured file is missing.")
    elif stamp == before[1] and path == before[0]:
        inputs.append("LCOV: configured file was not updated by this gate run.")
    else:
        records, hits = {}, None
        root = Path(worktree).resolve()
        try:
            for line in path.read_text(encoding="utf-8").splitlines():
                if line.startswith("SF:"):
                    file = Path(line[3:])
                    if file.is_relative_to(root):
                        file = file.relative_to(root)
                    hits = records.setdefault(file.as_posix(), set())
                elif line.startswith("DA:") and hits is not None:
                    number, count, *_ = line[3:].split(",")
                    if int(count) > 0:
                        hits.add(int(number))
                elif line == "end_of_record":
                    hits = None
            if not records:
                raise ValueError("expected source records")
            return records
        except INPUT_ERRORS:
            inputs.append("LCOV: could not read source line records.")
    return None


def line_ranges(lines):
    spans = []
    for line in sorted(lines):
        if spans and spans[-1][1] == line - 1:
            spans[-1][1] = line
        else:
            spans.append([line, line])
    return ", ".join(str(lo) if lo == hi else f"{lo}-{hi}" for lo, hi in spans) or "none"


def write(worktree, base_ref, round_dir, verdict, lcov_before, lcov_after):
    inputs = []
    revision = f"{base_ref}...HEAD"
    try:
        paths = changed_paths(worktree, revision)
    except INPUT_ERRORS:
        inputs.append("Git: branch diff unavailable.")
        paths = None
    build = read_input(round_dir.parent / "build.md", "build.md", inputs)
    log = read_input(round_dir / "checks.log", "checks.log", inputs)
    claims_lines, contradictions = claims(worktree, build, log, paths, inputs)
    coverage = coverage_records(worktree, lcov_before, lcov_after, inputs)
    indexed = (Path(worktree) / ".codegraph").is_dir()
    if not indexed:
        inputs.append("CodeGraph: no worktree index (.codegraph/ missing).")
    elif not shutil.which("codegraph"):
        inputs.append("CodeGraph: CLI unavailable.")
        indexed = False
    else:
        inputs.append("CodeGraph: each changed line is listed under the nearest declaration above it in the index's symbol map.")

    deadline = monotonic() + CODEGRAPH_BUDGET if indexed else None
    sources, tests, covered = [], [], []
    source_count, untested = 0, 0
    changed_tests = [file for file, (status, _) in (paths or {}).items()
                     if not status.startswith("D") and Path(file).suffix in SOURCE_SUFFIXES and is_test(file)]
    for file, (status, original) in (paths or {}).items():
        source = Path(file).suffix in SOURCE_SUFFIXES and not is_test(file)
        if not source and coverage is None:
            continue
        use_graph = indexed and source and status != "D"
        within_budget = use_graph and monotonic() < deadline
        ranges = []
        if coverage is not None or within_budget:
            try:
                ranges = diff_ranges(worktree, revision, file, original)
            except INPUT_ERRORS:
                inputs.append(f"Git: changed line ranges unavailable for `{file}`.")
                ranges = None
        if source:
            source_count += 1
            nearby = [test for test in changed_tests if test_key(test) == Path(file).stem]
            affected, symbols = [], []
            if within_budget:
                try:
                    affected, symbols = graph(worktree, file, ranges or [], inputs, deadline)
                except GraphBudgetExhausted:
                    deadline = monotonic()
                    within_budget = False
            if use_graph and not within_budget:
                inputs.append(f"CodeGraph: skipped (time budget) for `{file}`.")
            sources.append(f"- `{file}`" + (" (deleted)" if status == "D" else ""))
            sources.extend(symbols)
            links = []
            if affected:
                links.append("CodeGraph affected tests: " + ", ".join(f"`{test}`" for test in affected))
            if nearby:
                links.append("changed tests with a matching filename stem: " + ", ".join(f"`{test}`" for test in nearby))
            if not links:
                untested += 1
                links.append("untested: no CodeGraph affected test and no changed test with a matching filename stem")
            tests.append(f"- `{file}`: " + "; ".join(links) + ".")
        if coverage is not None:
            added = {line for lo, hi in ranges or [] for line in range(lo, hi + 1)}
            if ranges is None:
                detail = "changed lines unavailable"
            elif not added:
                detail = "no changed lines in HEAD"
            elif file not in coverage:
                detail = "no LCOV source record"
            else:
                hits = added & coverage[file]
                detail = (f"{len(hits)}/{len(added)} changed lines covered ({len(hits) / len(added):.1%}). "
                          f"Changed lines without a recorded hit: {line_ranges(added - hits)}")
            covered.append(f"- `{file}`: {detail}.")

    summary = [f"- Round gate: {verdict}.", f"- {contradictions} build claim contradictions.",
               f"- {source_count} changed source files identified, {untested} with no test link found.",
               f"- Changed-line coverage: {'LCOV records available' if coverage is not None else 'unavailable'}."]
    parts = [("Summary", summary), ("Claims", claims_lines or ["No claims to list."]),
             ("Changed code", sources or ["No changed source files listed."]),
             ("Tests for the change", tests or ["No changed source files to link to tests."]),
             ("Coverage", covered or ["No changed-line coverage to list."]),
             ("Inputs", [f"- {item}" for item in inputs] or ["All inputs available."])]
    report = f"REPORT: {contradictions} contradictions, {untested} untested\n\n"
    report += "\n\n".join(f"## {title}\n\n" + "\n".join(body) for title, body in parts) + "\n"
    (round_dir / "report.md").write_text(report, encoding="utf-8")
