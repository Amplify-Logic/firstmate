#!/usr/bin/env python3
"""Render a bounded screenshot of an isolated Herdr lab session's TUI.

Herdr draws pane borders, border titles, and the agent sidebar in its TUI
client, not in the server, so `herdr pane read` (terminal content) cannot
observe them. This engine attaches a throwaway read-only client to ONE named
lab session on a synthetic pty of an exact size, feeds the client's own output
through a terminal emulator, and prints the rendered screen.

It is a lab instrument, never a fleet operation:

- The session name must match the `fm-lab-` pattern and can never be `default`,
  checked here independently of the caller so this engine cannot be pointed at
  the captain's live session even when invoked directly.
- The Herdr argv is built literally from that one validated name. There is no
  pass-through of caller arguments, so no session or server lifecycle operation
  can be smuggled in.
- The caller's stdin is never wired to the pty, so no keystroke can reach the
  attached client. The client only ever draws.
- The run is bounded: a capped duration, after which the client is signalled
  and reaped.

`bin/fm-herdr-lab.sh view` is the supported entry point and owns the fleet-state
tripwire check that must pass before this engine runs.
"""

from __future__ import annotations

import argparse
import errno
import fcntl
import os
import pty
import re
import select
import signal
import struct
import sys
import termios
import time

SESSION_PATTERN = re.compile(r"^fm-lab-[A-Za-z0-9][A-Za-z0-9_-]*$")

COLS_MIN, COLS_MAX = 20, 400
ROWS_MIN, ROWS_MAX = 8, 200
SECONDS_MIN, SECONDS_MAX = 0.5, 30.0

# Read budget per poll, and how long to wait for the client to die politely.
READ_CHUNK = 65536
TERM_GRACE_SECONDS = 2.0


def fail(message: str) -> "None":
    sys.stderr.write("fm-herdr-lab-view: %s\n" % message)
    raise SystemExit(2)


def validate_session(name: str) -> str:
    """Refuse anything but a named lab session, independently of the caller."""
    if name == "default":
        fail("refusing session name 'default'")
    if not SESSION_PATTERN.match(name):
        fail("session name must start with 'fm-lab-': %s" % name)
    return name


def bounded(value: float, low: float, high: float, label: str) -> float:
    if not low <= value <= high:
        fail("%s must be between %s and %s: %s" % (label, low, high, value))
    return value


def set_winsize(fd: int, cols: int, rows: int) -> None:
    fcntl.ioctl(fd, termios.TIOCSWINSZ, struct.pack("HHHH", rows, cols, 0, 0))


def child_env(cols: int, rows: int) -> "dict[str, str]":
    """The attached client's environment, with every ambient Herdr var removed.

    This matters twice over. Herdr refuses to launch a nested client when it
    sees the outer client's HERDR_ENV, which is exactly the case when a lab runs
    from inside a Herdr pane. More importantly, HERDR_SOCKET_PATH points at the
    server that owns the CALLER's pane - the captain's live default server in
    normal use - so inheriting it would let an ambient value, rather than the
    validated lab name, decide which session gets attached. Stripping the whole
    prefix leaves the positional session name as the only selector.
    """
    env = {k: v for k, v in os.environ.items() if not k.startswith("HERDR_")}
    env["TERM"] = os.environ.get("TERM") or "xterm-256color"
    env["COLUMNS"] = str(cols)
    env["LINES"] = str(rows)
    return env


def capture(session: str, cols: int, rows: int, seconds: float) -> bytes:
    """Attach a bounded read-only client on a pty of exactly cols x rows."""
    # Built literally from the validated name: no caller argv reaches Herdr.
    argv = ["herdr", "session", "attach", session]

    env = child_env(cols, rows)

    pid, master = pty.fork()
    if pid == 0:  # child
        try:
            os.execvpe(argv[0], argv, env)
        except Exception:  # pragma: no cover - child cannot report usefully
            os._exit(127)

    set_winsize(master, cols, rows)
    chunks: "list[bytes]" = []
    deadline = time.monotonic() + seconds
    try:
        while True:
            remaining = deadline - time.monotonic()
            if remaining <= 0:
                break
            # A live TUI client goes quiet between repaints, so the read must be
            # bounded by the deadline rather than blocking on the next byte.
            try:
                ready, _, _ = select.select([master], [], [], min(remaining, 0.2))
            except (OSError, ValueError):
                break
            if not ready:
                continue
            try:
                data = os.read(master, READ_CHUNK)
            except OSError as exc:
                if exc.errno in (errno.EIO, errno.EBADF):
                    break  # client exited and closed the pty
                if exc.errno == errno.EAGAIN:
                    continue
                raise
            if not data:
                break
            chunks.append(data)
    finally:
        reap(pid)
        try:
            os.close(master)
        except OSError:
            pass
    return b"".join(chunks)


def reap(pid: int) -> None:
    """Signal the bounded client, then make sure it is actually gone."""
    for sig in (signal.SIGTERM, signal.SIGKILL):
        try:
            os.kill(pid, sig)
        except ProcessLookupError:
            return
        waited = 0.0
        while waited < TERM_GRACE_SECONDS:
            try:
                done, _ = os.waitpid(pid, os.WNOHANG)
            except ChildProcessError:
                return
            if done == pid:
                return
            time.sleep(0.05)
            waited += 0.05
    try:
        os.waitpid(pid, 0)
    except ChildProcessError:
        pass


def render(data: bytes, cols: int, rows: int) -> "list[str]":
    try:
        import pyte
    except ImportError:
        fail(
            "python3 module 'pyte' is required to render the lab screen; "
            "install it with 'python3 -m pip install pyte'"
        )
    screen = pyte.Screen(cols, rows)
    stream = pyte.ByteStream(screen)
    stream.feed(data)
    return list(screen.display)


def main(argv: "list[str] | None" = None) -> int:
    parser = argparse.ArgumentParser(add_help=True, description=__doc__)
    parser.add_argument("--session", required=True)
    parser.add_argument("--cols", type=int, default=182)
    parser.add_argument("--rows", type=int, default=64)
    parser.add_argument("--seconds", type=float, default=3.0)
    parser.add_argument("--format", choices=("text", "raw-bytes"), default="text")
    args = parser.parse_args(argv)

    session = validate_session(args.session)
    cols = int(bounded(args.cols, COLS_MIN, COLS_MAX, "--cols"))
    rows = int(bounded(args.rows, ROWS_MIN, ROWS_MAX, "--rows"))
    seconds = bounded(args.seconds, SECONDS_MIN, SECONDS_MAX, "--seconds")

    data = capture(session, cols, rows, seconds)
    if not data:
        sys.stderr.write(
            "fm-herdr-lab-view: the lab client produced no output; "
            "the session may not be running\n"
        )
        return 3

    if args.format == "raw-bytes":
        sys.stdout.buffer.write(data)
        return 0

    for index, line in enumerate(render(data, cols, rows)):
        sys.stdout.write("%02d|%s\n" % (index, line.rstrip()))
    return 0


if __name__ == "__main__":
    sys.exit(main())
