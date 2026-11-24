"""Best-effort CodeGraph indexing and cleanup for factory checkouts."""

import contextlib
import fcntl
import os
import signal
import subprocess
import tempfile
import time
from pathlib import Path

INDEX = ".codegraph"
DATABASE = "codegraph.db"
INIT_TIMEOUT = 180
SYNC_TIMEOUT = 60


def log_failure(log, where, message):
    with contextlib.suppress(OSError):
        with log.open("a") as out:
            out.write(f"{where}: {message}\n")


def invoke(cmd, where, timeout):
    result = subprocess.run(cmd, cwd=where, stdin=subprocess.DEVNULL, stdout=subprocess.PIPE,
                            stderr=subprocess.STDOUT, text=True, errors="replace", timeout=timeout)
    if result.returncode:
        raise OSError(f"{' '.join(cmd)} exit {result.returncode}\n{result.stdout.rstrip()}")
    return result.stdout.strip()


def exclude_index(where):
    # v1.2 ignores the database but leaves its generated .gitignore visible.
    # Git's common exclude file applies to linked worktrees as well.
    common = invoke(["git", "rev-parse", "--git-common-dir"], where, SYNC_TIMEOUT)
    exclude = where / common / "info" / "exclude"
    rule = b"/.codegraph/"
    exclude.parent.mkdir(parents=True, exist_ok=True)
    with exclude.open("a+b") as file:
        fcntl.flock(file, fcntl.LOCK_EX | fcntl.LOCK_NB)
        file.seek(0)
        current = file.read()
        if rule not in current.splitlines():
            file.write((b"\n" if current and not current.endswith(b"\n") else b"") + rule + b"\n")


@contextlib.contextmanager
def index_lock(directory):
    directory.mkdir(exist_ok=True)
    # Different jobs may start intake at the same time or copy the main DB
    # while another job is updating it.
    with (directory / "factory.lock").open("a") as lock:
        deadline = time.monotonic() + SYNC_TIMEOUT
        while True:
            try:
                fcntl.flock(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
                break
            except BlockingIOError:
                if time.monotonic() >= deadline:
                    raise TimeoutError(f"waiting for {directory} to unlock")
                time.sleep(0.1)
        yield


def seed_index(cli, source, directory):
    """Publish complete copies only, and leave any existing worktree index to sync."""
    source_index = source / INDEX
    with index_lock(source_index):
        if not (source_index / DATABASE).is_file():
            invoke([cli, "init"], source, INIT_TIMEOUT)
        files = [source_index / DATABASE]
        if (source_index / ".gitignore").is_file() and not (directory / ".gitignore").exists():
            files.append(source_index / ".gitignore")
        with tempfile.TemporaryDirectory(dir=directory) as tmp:
            invoke(["cp", "--reflink=auto", *map(str, files), tmp], source, SYNC_TIMEOUT)
            for path in files:
                (Path(tmp) / path.name).replace(directory / path.name)


def refresh(cli, where, log, seed_from=None):
    """Initialize or sync this checkout. A fresh worktree can reuse the main DB."""
    directory = where / INDEX
    try:
        exclude_index(where)
    except (OSError, subprocess.TimeoutExpired) as error:
        log_failure(log, where, error)
    try:
        with index_lock(directory):
            db = directory / DATABASE
            if seed_from and not db.is_file():
                try:
                    seed_index(cli, seed_from, directory)
                except (OSError, subprocess.TimeoutExpired) as error:
                    log_failure(log, where, f"seed from {seed_from}: {error}")
            if db.is_file():
                invoke([cli, "sync", "-q"], where, SYNC_TIMEOUT)
            else:
                invoke([cli, "init"], where, INIT_TIMEOUT)
    except (OSError, subprocess.TimeoutExpired) as error:
        log_failure(log, where, error)


def serves_checkout(proc, where):
    args = os.fsdecode((proc / "cmdline").read_bytes()).split("\0")
    # The npm and bundled distributions run codegraph.js via node. A shell
    # executable may also have its interpreter in the first argv slot.
    executable = Path(args[0]).name
    if executable in {"node", "nodejs", "bash", "sh"}:
        args = args[1:]
        while args and args[0].startswith("-"):
            args = args[1:]
    if len(args) < 2 or Path(args[0]).name not in {"codegraph", "codegraph.js"} or args[1] != "serve":
        return False
    for option, value in zip(args[2:], args[3:]):
        flag, equal, path = option.partition("=")
        if flag in {"--path", "-p"} and (path if equal else value):
            project = Path(path if equal else value)
            if not project.is_absolute():
                project = (proc / "cwd").readlink() / project
            return project.resolve().is_relative_to(where)
    return False


def running_since(proc):
    try:
        fields = (proc / "stat").read_text().rsplit(")", 1)[1].split()
        return fields[19] if fields[0] != "Z" else None
    except (OSError, IndexError):
        return None


def signal_server(proc, started, where, sig, log):
    try:
        if serves_checkout(proc, where) and running_since(proc) == started:
            os.kill(int(proc.name), sig)
            return True
    except (FileNotFoundError, ProcessLookupError):
        pass
    except PermissionError:
        # /proc may hide other users' command lines.
        pass
    except (OSError, RuntimeError, ValueError) as error:
        log_failure(log, where, error)
    return False


def stop_servers(where, log):
    """Stop Linux CodeGraph servers with an explicit path inside this checkout."""
    if not Path("/proc/self/cmdline").is_file():
        return
    try:
        procs = list(Path("/proc").iterdir())
    except OSError as error:
        log_failure(log, where, error)
        return
    pending = {}
    for proc in procs:
        if proc.name.isdecimal() and (started := running_since(proc)):
            if signal_server(proc, started, where, signal.SIGTERM, log):
                pending[proc] = started
    deadline = time.monotonic() + 2
    while pending and time.monotonic() < deadline:
        pending = {proc: started for proc, started in pending.items() if running_since(proc) == started}
        if pending:
            time.sleep(0.05)
    for proc, started in pending.items():
        signal_server(proc, started, where, signal.SIGKILL, log)
