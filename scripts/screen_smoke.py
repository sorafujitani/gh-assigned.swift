#!/usr/bin/env python3
"""Virtual-screen regression test for the inline renderer.

The test installs its only third-party dependency (``pyte==0.8.2``) into a
throwaway virtualenv when needed.  It never contacts GitHub: a deterministic
``gh`` fixture is placed first in PATH and the application runs in a PTY.
"""

from __future__ import annotations

import argparse
import codecs
import importlib
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
PYTE_REQUIREMENT = "pyte==0.8.2"
COLUMNS = 20
INITIAL_ROWS = 12
RESIZED_ROWS = 8
SENTINEL = "SHELL-SENTINEL"


class ScreenSmokeFailure(Exception):
    pass


def ensure_pyte() -> int | None:
    try:
        importlib.import_module("pyte")
    except ImportError:
        pass
    else:
        return None

    with tempfile.TemporaryDirectory(prefix="gh-assigned-pyte-") as directory:
        venv = Path(directory) / "venv"
        subprocess.run([sys.executable, "-m", "venv", str(venv)], check=True)
        python = venv / "bin" / "python"
        if not python.is_file():
            python = venv / "Scripts" / "python.exe"
        subprocess.run(
            [str(python), "-m", "pip", "install", "--disable-pip-version-check", "--no-input", PYTE_REQUIREMENT],
            check=True,
        )
        environment = os.environ.copy()
        environment["SCREEN_SMOKE_IN_VENV"] = "1"
        return subprocess.run([str(python), __file__, *sys.argv[1:]], env=environment).returncode


def set_winsize(fd: int, columns: int, rows: int) -> None:
    import fcntl

    fcntl.ioctl(fd, termios.TIOCSWINSZ, struct.pack("HHHH", rows, columns, 0, 0))


def write_fake_gh(directory: Path) -> Path:
    path = directory / "gh"
    path.write_text(
        r'''#!/usr/bin/env python3
import json
import os
import sys
import time

query = next((arg.split("=", 1)[1] for arg in sys.argv[1:] if arg.startswith("query=")), "")
time.sleep(float(os.environ.get("SCREEN_SMOKE_GH_DELAY", "0.35")))
repo = "smoke/example"
if "statusCheckRollup" in query:
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
            "title": "ROW-GROW",
            "url": "https://example.invalid/smoke/101",
            "isDraft": False,
            "baseRefName": "main",
            "headRefName": "smoke/branch",
            "repository": {"nameWithOwner": repo},
            "author": {"login": "smoke-user"},
            "reviewDecision": "APPROVED",
        }]}}
    }
print(json.dumps(payload), flush=True)
''',
        encoding="utf-8",
    )
    path.chmod(0o755)
    return path


class VirtualScreen:
    def __init__(self, columns: int, rows: int) -> None:
        pyte = importlib.import_module("pyte")
        self.screen = pyte.Screen(columns, rows)
        self.stream = pyte.Stream(self.screen)
        self.decoder = codecs.getincrementaldecoder("utf-8")("replace")

    def feed(self, data: bytes) -> None:
        text = self.decoder.decode(data)
        if text:
            self.stream.feed(text)

    def resize(self, columns: int, rows: int) -> None:
        self.screen.resize(lines=rows, columns=columns)

    @property
    def lines(self) -> list[str]:
        return list(self.screen.display)

    @property
    def cursor(self) -> tuple[int, int]:
        return self.screen.cursor.y, self.screen.cursor.x

    def put_sentinel_at_bottom(self, rows: int) -> None:
        self.stream.feed(f"\x1b[{rows};1H{SENTINEL}\x1b[{rows};1H")

    def has(self, text: str) -> bool:
        return any(text in line for line in self.lines)

    def require(self, condition: bool, message: str) -> None:
        if not condition:
            raise ScreenSmokeFailure(message + "\n" + "\n".join(self.lines))


def spawn(binary: Path, root: Path) -> tuple[subprocess.Popen[bytes], int]:
    home = root / "home"
    bin_directory = root / "bin"
    home.mkdir()
    bin_directory.mkdir()
    write_fake_gh(bin_directory)

    environment = os.environ.copy()
    environment.update(
        {
            "HOME": str(home),
            "XDG_CACHE_HOME": str(home / ".cache"),
            "PATH": f"{bin_directory}:{environment.get('PATH', '')}",
            "SCREEN_SMOKE_GH_DELAY": "0.35",
        }
    )
    master, slave = pty.openpty()
    set_winsize(master, COLUMNS, INITIAL_ROWS)
    process = subprocess.Popen(
        [str(binary)],
        cwd=ROOT,
        env=environment,
        stdin=slave,
        stdout=slave,
        stderr=slave,
        preexec_fn=os.setsid,
    )
    os.close(slave)
    return process, master


def pump(process: subprocess.Popen[bytes], master: int, screen: VirtualScreen, output: bytearray, duration: float) -> None:
    deadline = time.monotonic() + duration
    while time.monotonic() < deadline:
        timeout = min(0.05, max(0.0, deadline - time.monotonic()))
        ready, _, _ = select.select([master], [], [], timeout)
        if not ready:
            continue
        try:
            chunk = os.read(master, 65536)
        except OSError:
            return
        if not chunk:
            return
        output.extend(chunk)
        screen.feed(chunk)


def wait_for(
    process: subprocess.Popen[bytes],
    master: int,
    screen: VirtualScreen,
    output: bytearray,
    predicate: Callable[[], bool],
    label: str,
    timeout: float = 2.5,
) -> None:
    deadline = time.monotonic() + timeout
    while time.monotonic() < deadline:
        if predicate():
            return
        pump(process, master, screen, output, 0.06)
    if not predicate():
        raise ScreenSmokeFailure(f"{label} がタイムアウトしました\n" + "\n".join(screen.lines))


def stop_process(process: subprocess.Popen[bytes]) -> None:
    if process.poll() is not None:
        return
    with suppress(OSError):
        os.killpg(os.getpgid(process.pid), signal.SIGKILL)
    with suppress(subprocess.TimeoutExpired):
        process.wait(timeout=1.0)


def run_sentinel_lifecycle(binary: Path) -> None:
    with tempfile.TemporaryDirectory(prefix="gh-assigned-screen-") as directory:
        process, master = spawn(binary, Path(directory))
        screen = VirtualScreen(COLUMNS, INITIAL_ROWS)
        screen.put_sentinel_at_bottom(INITIAL_ROWS)
        output = bytearray()
        try:
            wait_for(process, master, screen, output, lambda: screen.has("fuzzy"), "初回描画")
            screen.require(screen.has(SENTINEL), "初回描画でシェル行のsentinelが失われました")
            screen.require(screen.cursor[1] <= COLUMNS - 1, "初回描画の入力カーソルが幅外です")
            screen.require(screen.has("0/0"), "初回描画がデータ取得前にgrowしています")

            wait_for(process, master, screen, output, lambda: screen.has("1/1"), "行数grow")
            screen.require(screen.has(SENTINEL), "growでシェル行のsentinelが失われました")

            os.write(master, b"?")
            wait_for(process, master, screen, output, lambda: screen.has("keys"), "help描画")
            screen.require(screen.has(SENTINEL), "helpでシェル行のsentinelが失われました")
            screen.require(screen.cursor[1] <= COLUMNS - 1, "help描画のカーソルが幅外です")

            os.write(master, b"\x1b")
            pump(process, master, screen, output, 0.35)
            screen.require(not screen.has("keys"), "helpを閉じた後に行が残っています")
            screen.require(screen.has(SENTINEL), "help closeでシェル行のsentinelが失われました")

            os.write(master, b"012345678901234567890123456789")
            pump(process, master, screen, output, 0.45)
            screen.require(screen.cursor[1] <= COLUMNS - 1, "長いqueryで入力カーソルが最終列を越えました")
            screen.require(screen.has("56789"), "長いqueryの末尾が入力行に描画されていません")
            screen.require(screen.has(SENTINEL), "long queryでシェル行のsentinelが失われました")

            os.write(master, b"\x1b")
            deadline = time.monotonic() + 2.5
            while process.poll() is None and time.monotonic() < deadline:
                pump(process, master, screen, output, 0.08)
            if process.poll() is None:
                raise ScreenSmokeFailure("finishがタイムアウトしました")
            pump(process, master, screen, output, 0.15)
            screen.require(process.returncode == 130, f"finishの終了コードが{process.returncode}です")
            screen.require(screen.has(SENTINEL), "finishでシェル行のsentinelが失われました")
            screen.require("keys" not in "\n".join(screen.lines), "finish後にhelp行が残っています")
            screen.require(screen.cursor[0] == 0, f"finish後のカーソル行がsentinel行(0)ではありません: {screen.cursor}")
            screen.require(screen.cursor[1] <= COLUMNS - 1, "finish後のカーソルが幅外です")

            for forbidden in (b"\x1b[2J", b"\x1b[3J", b"\x1b[?1049h", b"\x1b[?1049l"):
                screen.require(forbidden not in output, f"禁止された全画面操作を出力しました: {forbidden!r}")
        finally:
            with suppress(OSError):
                os.close(master)
            stop_process(process)


def run_resize(binary: Path) -> None:
    with tempfile.TemporaryDirectory(prefix="gh-assigned-screen-resize-") as directory:
        process, master = spawn(binary, Path(directory))
        screen = VirtualScreen(COLUMNS, INITIAL_ROWS)
        screen.put_sentinel_at_bottom(INITIAL_ROWS)
        output = bytearray()
        try:
            wait_for(process, master, screen, output, lambda: screen.has("fuzzy"), "resize前の初回描画")
            wait_for(process, master, screen, output, lambda: screen.has("1/1"), "resize前の行数grow")
            os.write(master, b"?")
            wait_for(process, master, screen, output, lambda: screen.has("keys"), "resize前のhelp描画")
            screen.require(screen.has(SENTINEL), "resize前にシェル行のsentinelが失われました")

            set_winsize(master, COLUMNS, RESIZED_ROWS)
            screen.resize(COLUMNS, RESIZED_ROWS)
            screen.require(len(screen.lines) == RESIZED_ROWS, "8行resize直後の仮想画面サイズが不正です")
            screen.require(not screen.has(SENTINEL), "pyte.Screen.resize直後にcropでsentinelが失われませんでした")

            process.send_signal(signal.SIGWINCH)
            pump(process, master, screen, output, 0.55)
            screen.require(screen.has("keys"), "8行resize後にhelpが安全に再描画されていません")
            screen.require(screen.cursor[0] == 0, f"resize後のUIが画面先頭に再anchorされていません: {screen.cursor}")
            screen.require(screen.lines[0].startswith("all·fuzzy >"), "resize後にcrop前の古いUI行が残っています")

            os.write(master, b"\x1b")
            pump(process, master, screen, output, 0.35)
            screen.require(not screen.has("keys"), "resize後にhelpを閉じても行が残っています")
            screen.require(screen.lines[0].startswith("all·fuzzy >"), "resize後のhelp closeでUIのanchorが壊れています")
            screen.require(all(not line.strip() for line in screen.lines[3:]), "resize前のhelp行がclose後に残っています")

            os.write(master, b"\x1b")
            deadline = time.monotonic() + 2.5
            while process.poll() is None and time.monotonic() < deadline:
                pump(process, master, screen, output, 0.08)
            if process.poll() is None:
                raise ScreenSmokeFailure("resize後のfinishがタイムアウトしました")
            pump(process, master, screen, output, 0.15)
            screen.require(process.returncode == 130, f"resize後finishの終了コードが{process.returncode}です")
            screen.require(all(not line.strip() for line in screen.lines), "resize後finishでUI行が残っています")
            screen.require(screen.cursor[0] == 0, f"resize後finishのカーソル行が安全な位置ではありません: {screen.cursor}")
            screen.require(screen.cursor[1] <= COLUMNS - 1, "resize後finishのカーソルが幅外です")

            for forbidden in (b"\x1b[2J", b"\x1b[3J", b"\x1b[?1049h", b"\x1b[?1049l"):
                screen.require(forbidden not in output, f"禁止された全画面操作を出力しました: {forbidden!r}")
        finally:
            with suppress(OSError):
                os.close(master)
            stop_process(process)


def run(binary: Path) -> None:
    run_sentinel_lifecycle(binary)
    run_resize(binary)


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("binary", nargs="?", type=Path)
    args = parser.parse_args()
    if args.binary is None:
        debug = ROOT / ".build/debug/gh-assigned"
        release = ROOT / ".build/release/gh-assigned"
        binary = debug if debug.is_file() else release
    else:
        binary = args.binary
    try:
        executable = binary.is_file() and os.access(binary, os.X_OK)
    except OSError:
        executable = False
    if not executable:
        print(f"未検証: executable がありません: {binary}", file=sys.stderr)
        return 2

    venv_result = ensure_pyte()
    if venv_result is not None:
        return venv_result
    try:
        run(binary)
    except (OSError, ScreenSmokeFailure, subprocess.SubprocessError) as error:
        print(f"失敗: {error}", file=sys.stderr)
        return 1
    print(f"検証済み: {binary.name} の仮想画面描画")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
