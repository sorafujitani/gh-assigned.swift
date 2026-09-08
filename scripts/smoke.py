#!/usr/bin/env python3
"""Small, repeatable smoke checks for the local gh-assigned binaries.

The checks use only the Python standard library.  They never contact GitHub:
``gh`` and the browser opener are replaced in a temporary PATH.  PTY checks
are intentionally byte-oriented; this script does not claim a full virtual
screen assertion.
"""

from __future__ import annotations

import argparse
import json
import os
import pty
import select
import signal
import struct
import subprocess
import sys
import tempfile
import termios
import time
from collections.abc import Callable
from contextlib import suppress
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
DEFAULT_BINARIES = (ROOT / ".build/debug/gh-assigned", ROOT / ".build/release/gh-assigned")


class SmokeFailure(Exception):
    pass


class Case:
    def __init__(self, name: str) -> None:
        self.name = name
        self.notes: list[str] = []

    def note(self, text: str) -> None:
        self.notes.append(text)

    def check(self, condition: bool, message: str) -> None:
        if not condition:
            raise SmokeFailure(message)


class TempFixture:
    def __init__(self, root: Path) -> None:
        self.root = root
        self.home = root / "home"
        self.bin = root / "bin"
        self.cache = root / "xdg-cache"
        self.log = root / "gh.log"
        self.open_log = root / "open.log"
        self.home.mkdir()
        self.bin.mkdir()
        self._write_fake_gh()
        self._write_fake_open()

    def env(self, *, width: int | None = None, extra: dict[str, str] | None = None) -> dict[str, str]:
        env = os.environ.copy()
        env["HOME"] = str(self.home)
        env["XDG_CACHE_HOME"] = str(self.cache)
        env["PATH"] = f"{self.bin}:{env.get('PATH', '')}"
        env["SMOKE_GH_LOG"] = str(self.log)
        env["SMOKE_OPEN_LOG"] = str(self.open_log)
        if width is not None:
            env["SMOKE_TERM_WIDTH"] = str(width)
        if extra:
            env.update(extra)
        return env

    def _write_fake_gh(self) -> None:
        # The client makes one list and one checks query per list.  The query
        # text itself is enough to return a valid deterministic GraphQL shape.
        script = r'''#!/usr/bin/env python3
import json
import os
import pathlib
import signal
import sys
import time

log = pathlib.Path(os.environ["SMOKE_GH_LOG"])
args = sys.argv[1:]
query = next((a.split("=", 1)[1] for a in args if a.startswith("query=")), "")
with log.open("a", encoding="utf-8") as fp:
    fp.write(json.dumps({"args": args, "query": query}) + "\n")
    fp.flush()

is_browser = args[:2] == ["pr", "view"]
mode = os.environ.get("SMOKE_GH_MODE")
if mode == "stop" or (mode == "api-stop" and not is_browser) or (mode == "browser-stop" and is_browser):
    # Used by cancellation checks.  Ignore TERM so the parent must cancel the
    # subprocess rather than merely waiting for a cooperative child.
    signal.signal(signal.SIGTERM, signal.SIG_IGN)
    while True:
        time.sleep(1)

if os.environ.get("SMOKE_GH_DELAY"):
    time.sleep(float(os.environ["SMOKE_GH_DELAY"]))

is_checks = "statusCheckRollup" in query
filters = (("mine", "author:@me"), ("review", "review-requested:@me"), ("assigned", "assignee:@me"))
kind = next((name for name, marker in filters if marker in query), "mine")
repo = "smoke/example"
if is_checks:
    payload = {
        "data": {"search": {"nodes": [{
            "number": 101,
            "repository": {"nameWithOwner": repo},
            "commits": {"nodes": [{"commit": {"statusCheckRollup": {"state": "SUCCESS"}}}]},
        }]}}
    }
else:
    payload = {
        "data": {"search": {"nodes": [{
            "number": 101,
            "title": "Smoke \u65e5\u672c\u8a9e " + kind,
            "url": "https://example.invalid/smoke/101",
            "isDraft": False,
            "baseRefName": "main",
            "headRefName": "smoke/branch",
            "repository": {"nameWithOwner": repo},
            "author": {"login": "smoke-user"},
            "reviewDecision": "REVIEW_REQUIRED",
        }]}}
    }
print(json.dumps(payload), flush=True)
'''
        path = self.bin / "gh"
        path.write_text(script, encoding="utf-8")
        path.chmod(0o755)

    def _write_fake_open(self) -> None:
        script = r'''#!/usr/bin/env python3
import os
import pathlib
import signal
import time

pathlib.Path(os.environ["SMOKE_OPEN_LOG"]).open("a", encoding="utf-8").write("open\n")
if os.environ.get("SMOKE_OPEN_MODE") == "stop":
    signal.signal(signal.SIGTERM, signal.SIG_IGN)
    while True:
        time.sleep(1)
'''
        path = self.bin / "open"
        path.write_text(script, encoding="utf-8")
        path.chmod(0o755)


def run_process(binary: Path, args: list[str], env: dict[str, str], timeout: float = 8.0) -> subprocess.CompletedProcess[bytes]:
    return subprocess.run(
        [str(binary), *args],
        cwd=ROOT,
        env=env,
        stdin=subprocess.DEVNULL,
        capture_output=True,
        timeout=timeout,
    )


def read_pty(master: int, duration: float = 0.25) -> bytes:
    data = bytearray()
    deadline = time.monotonic() + duration
    while time.monotonic() < deadline:
        ready, _, _ = select.select([master], [], [], min(0.05, max(0.0, deadline - time.monotonic())))
        if not ready:
            continue
        try:
            chunk = os.read(master, 65536)
        except OSError:
            break
        if not chunk:
            break
        data.extend(chunk)
    return bytes(data)


def set_winsize(fd: int, columns: int, rows: int = 24) -> None:
    winsize = struct.pack("HHHH", rows, columns, 0, 0)
    import fcntl

    fcntl.ioctl(fd, termios.TIOCSWINSZ, winsize)


def spawn_pty(binary: Path, env: dict[str, str], columns: int = 80) -> tuple[subprocess.Popen[bytes], int, list[int]]:
    master, slave = pty.openpty()
    set_winsize(master, columns)
    baseline = termios.tcgetattr(master)
    proc = subprocess.Popen(
        [str(binary)],
        cwd=ROOT,
        env=env,
        stdin=slave,
        stdout=slave,
        stderr=slave,
        preexec_fn=os.setsid,
    )
    os.close(slave)
    return proc, master, baseline


def terminate_process_group(proc: subprocess.Popen[bytes]) -> None:
    if proc.poll() is not None:
        return
    with suppress(OSError):
        os.killpg(os.getpgid(proc.pid), signal.SIGKILL)
    try:
        proc.wait(timeout=0.8)
    except subprocess.TimeoutExpired:
        with suppress(OSError):
            proc.kill()
        with suppress(subprocess.TimeoutExpired):
            proc.wait(timeout=0.8)


def wait_pty(proc: subprocess.Popen[bytes], master: int, timeout: float = 3.0) -> tuple[int, bytes, float]:
    output = bytearray()
    started = time.monotonic()
    deadline = started + timeout
    while proc.poll() is None and time.monotonic() < deadline:
        output.extend(read_pty(master, 0.08))
    if proc.poll() is None:
        output.extend(read_pty(master, 0.1))
        tail = bytes(output[-500:])
        terminate_process_group(proc)
        raise SmokeFailure(f"PTY process did not exit within {timeout:.1f}s; tail={tail!r}")
    output.extend(read_pty(master, 0.15))
    return proc.returncode, bytes(output), time.monotonic() - started


def close_pty(master: int) -> None:
    with suppress(OSError):
        os.close(master)


def json_and_cache(binary: Path, fixture: TempFixture, case: Case) -> None:
    sentinel = fixture.home / "do-not-overwrite.sentinel"
    sentinel.write_bytes(b"keep-me\n")
    result = run_process(binary, ["--json"], fixture.env(), timeout=8)
    case.check(result.returncode == 0, f"--json exit={result.returncode}: {result.stderr!r}")
    try:
        document = json.loads(result.stdout)
    except json.JSONDecodeError as exc:
        raise SmokeFailure(f"--json stdout is not JSON: {exc}: {result.stdout[:500]!r}") from exc
    case.check(isinstance(document, dict), "--json top level is not an object")
    lists = document.get("lists")
    case.check(isinstance(lists, list) and len(lists) == 3, f"expected three lists, got {document.keys()}")
    for index, rows in enumerate(lists):
        case.check(isinstance(rows, list) and len(rows) == 1, f"lists[{index}] is not a one-row list")
        row = rows[0]
        for field in ("repo", "number", "title", "url", "author", "is_draft", "base_ref", "head_ref", "checks", "review"):
            case.check(field in row, f"lists[{index}][0] missing schema field {field}")
    cache = fixture.cache / "gh-assigned/snapshot.json"
    case.check(cache.is_file(), f"XDG cache was not created: {cache}")
    case.check(sentinel.read_bytes() == b"keep-me\n", "unrelated existing sentinel was overwritten")
    log_lines = fixture.log.read_text(encoding="utf-8").splitlines()
    case.check(len(log_lines) == 6, f"expected six fake gh calls, got {len(log_lines)}")
    case.note("JSON: 3 lists/schema, isolated XDG cache, and unrelated sentinel verified")


def non_tty(binary: Path, fixture: TempFixture, case: Case) -> None:
    fixture.log.unlink(missing_ok=True)
    result = run_process(binary, [], fixture.env(), timeout=3)
    text = (result.stdout + result.stderr).decode(errors="replace")
    case.check(result.returncode != 0, "non-TTY interactive invocation unexpectedly succeeded")
    case.check("terminal" in text.lower() and "json" in text.lower(), f"non-TTY error lacks guidance: {text!r}")
    case.check(not fixture.log.exists(), "non-TTY validation launched fake gh")
    case.note(f"non-TTY error verified (exit {result.returncode})")


def pty_cancel(binary: Path, fixture: TempFixture, key: bytes, label: str, case: Case) -> None:
    proc, master, baseline = spawn_pty(binary, fixture.env(extra={"SMOKE_GH_DELAY": "5"}))
    try:
        read_pty(master, 0.35)
        os.write(master, key)
        returncode, output, elapsed = wait_pty(proc, master, timeout=2.5)
        after = termios.tcgetattr(master)
        case.check(returncode == 130, f"{label}: exit={returncode}, output={output[-500:]!r}")
        case.check(baseline == after, f"{label}: PTY termios was not restored")
        case.check(elapsed < 2.3, f"{label}: cancellation took {elapsed:.2f}s")
        case.note(f"{label}: exit 130, termios restored, {elapsed:.2f}s")
    finally:
        close_pty(master)
        terminate_process_group(proc)


def pty_query_and_layout(binary: Path, fixture: TempFixture, case: Case) -> None:
    # Query editing is always active.  Send abc in one write to catch dropped
    # bytes at the raw-input boundary, then append a long query at width 20.
    proc, master, baseline = spawn_pty(binary, fixture.env(extra={"SMOKE_GH_DELAY": "0.15"}), columns=20)
    output = bytearray()
    try:
        output.extend(read_pty(master, 0.2))
        os.write(master, b"abc")
        output.extend(read_pty(master, 0.7))
        os.write(master, b"-long-query-" * 12)
        # Resize while the app is alive; a tick redraw should observe it.
        set_winsize(master, 20, 24)
        proc.send_signal(signal.SIGWINCH)
        output.extend(read_pty(master, 0.25))
        os.write(master, b"\x1b")
        returncode, tail, elapsed = wait_pty(proc, master, timeout=2.5)
        output.extend(tail)
        after = termios.tcgetattr(master)
        data = bytes(output)
        case.check(returncode == 130, f"query cancel exit={returncode}, tail={data[-500:]!r}")
        case.check(baseline == after, "query: PTY termios was not restored")
        case.check(b"abc" in data, f"query bytes do not contain abc: tail={data[-1000:]!r}")
        case.check(len(data) > 0, "query produced no terminal bytes")
        case.note(f"PTY query abc retained in output; width=20/resize exercised; {elapsed:.2f}s")
        case.note("screen retention is byte-checked only; no virtual-screen dependency")
    finally:
        close_pty(master)
        terminate_process_group(proc)


def cancellation_of_external(binary: Path, fixture: TempFixture, case: Case) -> None:
    proc, master, _ = spawn_pty(
        binary,
        fixture.env(extra={"SMOKE_GH_MODE": "browser-stop", "SMOKE_GH_DELAY": "0.05"}),
        columns=80,
    )
    try:
        read_pty(master, 0.35)
        # Wait for the deterministic API fixture, select the first row, and
        # start the fake browser command.  The browser then deliberately hangs.
        os.write(master, b"O")
        deadline = time.monotonic() + 1.5
        while time.monotonic() < deadline:
            read_pty(master, 0.08)
            if fixture.log.exists() and '"pr", "view"' in fixture.log.read_text(encoding="utf-8"):
                break
        case.check(fixture.log.exists() and '"pr", "view"' in fixture.log.read_text(encoding="utf-8"), "fake browser was not started")
        proc.send_signal(signal.SIGTERM)
        returncode, output, elapsed = wait_pty(proc, master, timeout=2.5)
        case.check(returncode == 130, f"external cancellation exit={returncode}: {output[-500:]!r}")
        case.check(elapsed < 2.3, f"external cancellation took {elapsed:.2f}s")
        case.note(f"SIGTERM during fake external work: exit 130 in {elapsed:.2f}s")
    finally:
        close_pty(master)
        terminate_process_group(proc)


def api_cancellation(binary: Path, fixture: TempFixture, case: Case) -> None:
    proc, master, baseline = spawn_pty(binary, fixture.env(extra={"SMOKE_GH_MODE": "api-stop"}))
    try:
        read_pty(master, 0.35)
        os.write(master, b"\x03")
        returncode, output, elapsed = wait_pty(proc, master, timeout=2.5)
        after = termios.tcgetattr(master)
        case.check(returncode == 130, f"stopped API: exit={returncode}, output={output[-500:]!r}")
        case.check(baseline == after, "stopped API: PTY termios was not restored")
        case.check(elapsed < 2.3, f"stopped API cancellation took {elapsed:.2f}s")
        case.note(f"stopped fake gh API cancelled in {elapsed:.2f}s")
    finally:
        close_pty(master)
        terminate_process_group(proc)


def run_one(binary: Path) -> tuple[list[str], list[str]]:
    passed: list[str] = []
    failed: list[str] = []
    checks: list[tuple[str, Callable[[Case], None]]] = []
    with tempfile.TemporaryDirectory(prefix="gh-assigned-smoke-") as temp:
        root = Path(temp)
        fixture = TempFixture(root)
        checks = [
            ("json/cache", lambda case: json_and_cache(binary, fixture, case)),
            ("non-tty", lambda case: non_tty(binary, fixture, case)),
            ("pty-query/layout", lambda case: pty_query_and_layout(binary, fixture, case)),
            ("esc-cancel", lambda case: pty_cancel(binary, fixture, b"\x1b", "ESC", case)),
            ("control-c", lambda case: pty_cancel(binary, fixture, b"\x03", "control-C", case)),
            ("sigterm", lambda case: pty_cancel(binary, fixture, b"", "SIGTERM", case)),
            ("api-cancel", lambda case: api_cancellation(binary, fixture, case)),
            ("external-cancel", lambda case: cancellation_of_external(binary, fixture, case)),
        ]
        for name, check in checks:
            case = Case(name)
            try:
                if name == "sigterm":
                    proc, master, baseline = spawn_pty(binary, fixture.env(extra={"SMOKE_GH_DELAY": "5"}))
                    try:
                        read_pty(master, 0.3)
                        started = time.monotonic()
                        proc.send_signal(signal.SIGTERM)
                        returncode, output, _ = wait_pty(proc, master, timeout=2.5)
                        elapsed = time.monotonic() - started
                        after = termios.tcgetattr(master)
                        case.check(returncode == 130, f"SIGTERM: exit={returncode}, output={output[-500:]!r}")
                        case.check(baseline == after, "SIGTERM: PTY termios was not restored")
                        case.check(elapsed < 2.3, f"SIGTERM: cancellation took {elapsed:.2f}s")
                        case.note(f"SIGTERM: exit 130, termios restored, {elapsed:.2f}s")
                    finally:
                        close_pty(master)
                        terminate_process_group(proc)
                else:
                    check(case)
                passed.append(f"{binary.name} {name}: PASS" + (f" ({'; '.join(case.notes)})" if case.notes else ""))
            except (SmokeFailure, OSError, subprocess.SubprocessError, termios.error) as exc:
                failed.append(f"{binary.name} {name}: FAIL: {exc}")
    return passed, failed


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("binaries", nargs="*", type=Path, help="debug/release binaries (default: both)")
    args = parser.parse_args()
    binaries = args.binaries or list(DEFAULT_BINARIES)
    def is_executable(path: Path) -> bool:
        try:
            return path.is_file() and os.access(path, os.X_OK)
        except OSError:
            return False

    missing = [path for path in binaries if not is_executable(path)]
    if missing:
        print("未検証: executable missing: " + ", ".join(map(str, missing)), file=sys.stderr)
        return 2
    all_passed: list[str] = []
    all_failed: list[str] = []
    for binary in binaries:
        passed, failed = run_one(binary)
        all_passed.extend(passed)
        all_failed.extend(failed)
    print("検証済み:")
    for line in all_passed:
        print(f"  {line}")
    if all_failed:
        print("失敗/未検証:")
        for line in all_failed:
            print(f"  {line}")
        return 1
    print("未検証: full virtual-screen semantics and real GitHub/browser integration")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
