#!/usr/bin/env python3
"""Usage: factory/bin/heavy <cmd...>

Run a command in a shared heavy slot for this repository and machine.
"""

import fcntl
import json
import os
import shlex
import signal
import socket
import subprocess
import sys
import time
from contextlib import contextmanager, suppress
from dataclasses import dataclass
from pathlib import Path

SLOT_ENV = "FACTORY_HEAVY_SLOT"
POLL_SECONDS = 0.1
STOP_GRACE_SECONDS = 2


def main_checkout(cwd):
    result = subprocess.run(["git", "rev-parse", "--path-format=absolute", "--git-common-dir"],
                            cwd=cwd, capture_output=True, text=True, check=True)
    common = Path(result.stdout.strip())
    root = common.parent
    if common.name == ".git" and (root / "factory" / "config.json").is_file():
        return root
    # Repositories with a separate Git directory need the first worktree's path.
    trees = subprocess.check_output(["git", "worktree", "list", "--porcelain", "-z"], cwd=cwd)
    return Path(os.fsdecode(trees.split(b"\0", 1)[0].removeprefix(b"worktree ")))


def pool_dir(repo):
    return repo / "factory" / "jobs" / "_heavy" / socket.gethostname()


def holder(path):
    try:
        value = json.loads(path.read_text())
    except (OSError, ValueError):
        return {}
    return value if isinstance(value, dict) else {}


def active_holders(repo):
    for path in sorted(pool_dir(repo).glob("slot-*.lock")):
        # Check the lock, rather than the recorded PID: flock releases it
        # when the holder dies, and the PID alone may have been reused.
        try:
            with path.open("r+b") as lock:
                try:
                    fcntl.flock(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
                except BlockingIOError:
                    info = holder(path)
                    if info:
                        yield info
        except FileNotFoundError:
            continue


def describe(info):
    if not info:
        return "another heavy command"
    place = " ".join(filter(None, (info.get("job"), info.get("role")))) or info["cwd"]
    return f"{place}: {info['command']}"


def gate_holder(info):
    if info.get("role") == "gate" and info.get("job"):
        return f"{info['job']}'s gate"
    return describe(info)


@dataclass
class Result:
    returncode: int
    stdout: str | None = None
    seconds: float = 0
    waited: float = 0
    blocked_by: dict | None = None


class Stopped(Exception):
    pass


@contextmanager
def slot(repo, config, info, stopped, *, prefix, env):
    limit = int(config.get("heavy_parallel", config.get("gate_parallel", 1)) or 0)
    if SLOT_ENV in env or limit <= 0:
        yield env, 0, None
        return

    directory = pool_dir(repo)
    directory.mkdir(parents=True, exist_ok=True)
    paths = [directory / f"slot-{n}.lock" for n in range(1, limit + 1)]
    started, blocker = time.monotonic(), None
    while not stopped():
        for path in paths:
            with path.open("a+") as lock:
                try:
                    fcntl.flock(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
                except BlockingIOError:
                    continue
                lock.seek(0)
                lock.truncate()
                json.dump(dict(info, pid=os.getpid(), since=time.time()), lock)
                lock.flush()
                waited = time.monotonic() - started if blocker is not None else 0
                yield dict(env, **{SLOT_ENV: str(path)}), waited, blocker
                return
        if blocker is None:
            blocker = holder(paths[0])
            since = time.strftime("%H:%M", time.localtime(blocker["since"])) if blocker.get("since") else "?"
            who = gate_holder(blocker) if prefix == "gate" else describe(blocker)
            print(f"{prefix}: waiting for {who} (since {since})", file=sys.stderr, flush=True)
        time.sleep(POLL_SECONDS)
    raise Stopped


def communicate(child, stopped):
    while not stopped():
        try:
            return child.communicate(timeout=POLL_SECONDS)[0]
        except subprocess.TimeoutExpired:
            continue
    with suppress(ProcessLookupError):
        os.killpg(child.pid, stopped())
    try:
        return child.communicate(timeout=STOP_GRACE_SECONDS)[0]
    except subprocess.TimeoutExpired:
        with suppress(ProcessLookupError):
            os.killpg(child.pid, signal.SIGKILL)
        return child.communicate()[0]
    finally:
        # If the group leader exited first, also stop its remaining descendants.
        with suppress(ProcessLookupError):
            os.killpg(child.pid, signal.SIGKILL)


def run(repo, config, cmd, *, cwd=None, env=None, job=None, role=None, prefix="heavy", capture=False):
    cwd = str(cwd or Path.cwd())
    env = os.environ.copy() if env is None else env
    info = {"job": job, "role": role, "command": shlex.join(cmd).replace("\n", r"\n"), "cwd": cwd}
    interrupted = None

    def on_signal(signum, _frame):
        nonlocal interrupted
        interrupted = interrupted or signum

    def stopped():
        return interrupted

    previous = {sig: signal.signal(sig, on_signal) for sig in (signal.SIGINT, signal.SIGTERM)}
    try:
        with slot(repo, config, info, stopped, prefix=prefix, env=env) as (child_env, waited, blocker):
            if interrupted:
                return Result(128 + interrupted, waited=waited, blocked_by=blocker)
            started = time.monotonic()
            output = {"stdout": subprocess.PIPE, "stderr": subprocess.STDOUT, "text": True} if capture else {}
            with subprocess.Popen(cmd, cwd=cwd, env=child_env, start_new_session=True, **output) as child:
                stdout = communicate(child, stopped)
            code = 128 + interrupted if interrupted else child.returncode
            return Result(code if code >= 0 else 128 - code, stdout, time.monotonic() - started, waited, blocker)
    except Stopped:
        return Result(128 + interrupted)
    finally:
        for sig, handler in previous.items():
            signal.signal(sig, handler)


def record_wait(repo, job, role, waited):
    if job and role and waited > 0:
        # Record after releasing the heavy slot, so the job lock and pool
        # never depend on one another in opposite order.
        try:
            subprocess.run([str(repo / "factory" / "bin" / "job"), "_heavy-wait", job, role, str(waited)],
                           cwd=repo, stdin=subprocess.DEVNULL, stdout=subprocess.DEVNULL)
        except OSError as exc:
            print(f"heavy: could not record wait: {exc}", file=sys.stderr)


def main(argv):
    if not argv or argv == ["--help"]:
        print(__doc__.strip(), file=sys.stdout if argv else sys.stderr)
        return 0 if argv else 2
    try:
        if SLOT_ENV in os.environ:
            os.execvp(argv[0], argv)
        repo = main_checkout(Path.cwd())
        config = json.loads((repo / "factory" / "config.json").read_text())
        job, role = os.environ.get("FACTORY_JOB"), os.environ.get("FACTORY_ROLE")
        result = run(repo, config, argv, job=job, role=role)
    except subprocess.CalledProcessError as exc:
        print(f"heavy: cannot find the factory's Git checkout: {exc.stderr}", file=sys.stderr)
        return 2
    except (OSError, ValueError) as exc:
        print(f"heavy: {exc}", file=sys.stderr)
        return 127 if isinstance(exc, FileNotFoundError) else 126 if isinstance(exc, PermissionError) else 2
    record_wait(repo, job, role, result.waited)
    return result.returncode


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
