#!/usr/bin/env python3
"""Bounded wait for a filesystem change on named paths.

This is the wire-transport half of the watcher's glasses file-event nudger
(bin/fm-file-event-lib.sh, consumed by bin/fm-watch.sh event_wait_or_sleep).
It does not know supervision policy: it watches the given paths and prints the
first changed path to stdout, flushing so the bash caller can interrupt its
poll sleep sub-second.

Usage: fm-file-eventwait.py <timeout_seconds> <path> [<path> ...]

Exit status:
  0  a watched path changed
  1  a clean full-budget wait with no change
  2  bad arguments, no existing paths, or the wait primitive failed to start
"""
from __future__ import annotations

import errno
import fcntl
import os
import select
import sys
import time

POLL_SLICE = 0.05


def _existing(paths):
    out = []
    seen = set()
    for path in paths:
        if path in seen:
            continue
        seen.add(path)
        if os.path.exists(path):
            out.append(path)
    return out


def _stat_key(path):
    try:
        st = os.stat(path)
    except OSError:
        return None
    return (st.st_mtime_ns, st.st_size, st.st_nlink, st.st_ino)


def _snapshot(paths):
    return {path: _stat_key(path) for path in paths}


def _first_changed(before, after):
    for path, key in after.items():
        if before.get(path) != key:
            return path
    for path in before:
        if path not in after:
            return path
    return None


def _wait_stat(paths, timeout):
    before = _snapshot(paths)
    deadline = time.monotonic() + timeout
    while True:
        remaining = deadline - time.monotonic()
        if remaining <= 0:
            return None
        time.sleep(min(POLL_SLICE, remaining))
        changed = _first_changed(before, _snapshot(paths))
        if changed is not None:
            return changed


def _wait_kqueue(paths, timeout):
    if not hasattr(select, "kqueue"):
        raise OSError(errno.ENOTSUP, "kqueue unavailable")
    kq = select.kqueue()
    fds = []
    fd_to_path = {}
    try:
        notes = (
            select.KQ_NOTE_WRITE
            | select.KQ_NOTE_EXTEND
            | select.KQ_NOTE_ATTRIB
            | select.KQ_NOTE_DELETE
            | select.KQ_NOTE_RENAME
            | select.KQ_NOTE_LINK
        )
        flags = select.KQ_EV_ADD | select.KQ_EV_ENABLE | select.KQ_EV_CLEAR
        for path in paths:
            fd = os.open(path, os.O_RDONLY)
            fds.append(fd)
            fd_to_path[fd] = path
            kev = select.kevent(
                fd,
                filter=select.KQ_FILTER_VNODE,
                flags=flags,
                fflags=notes,
            )
            kq.control([kev], 0)
        deadline = time.monotonic() + timeout
        before = _snapshot(paths)
        while True:
            remaining = deadline - time.monotonic()
            if remaining <= 0:
                return None
            events = kq.control(None, 1, remaining)
            if not events:
                return None
            changed = _first_changed(before, _snapshot(paths))
            if changed is not None:
                return changed
            ident = getattr(events[0], "ident", None)
            if ident in fd_to_path:
                return fd_to_path[ident]
    finally:
        for fd in fds:
            try:
                os.close(fd)
            except OSError:
                pass
        kq.close()


def _wait_inotify(paths, timeout):
    if sys.platform != "linux":
        raise OSError(errno.ENOTSUP, "inotify unavailable")
    import ctypes
    import ctypes.util

    libc_name = ctypes.util.find_library("c")
    if not libc_name:
        raise OSError(errno.ENOTSUP, "libc unavailable")
    libc = ctypes.CDLL(libc_name, use_errno=True)
    libc.inotify_init.restype = ctypes.c_int
    libc.inotify_add_watch.argtypes = [ctypes.c_int, ctypes.c_char_p, ctypes.c_uint32]
    libc.inotify_add_watch.restype = ctypes.c_int

    in_modify = 0x00000002
    in_attrib = 0x00000004
    in_close_write = 0x00000008
    in_moved_to = 0x00000080
    in_create = 0x00000100
    in_delete = 0x00000200
    in_delete_self = 0x00000400
    in_move_self = 0x00000800
    mask = (
        in_modify
        | in_attrib
        | in_close_write
        | in_moved_to
        | in_create
        | in_delete
        | in_delete_self
        | in_move_self
    )

    fd = libc.inotify_init()
    if fd < 0:
        err = ctypes.get_errno()
        raise OSError(err, os.strerror(err))
    wds = {}
    try:
        flags = fcntl.fcntl(fd, fcntl.F_GETFD)
        fcntl.fcntl(fd, fcntl.F_SETFD, flags | fcntl.FD_CLOEXEC)
        for path in paths:
            wd = libc.inotify_add_watch(fd, path.encode("utf-8"), mask)
            if wd < 0:
                err = ctypes.get_errno()
                raise OSError(err, os.strerror(err))
            wds[wd] = path
        deadline = time.monotonic() + timeout
        before = _snapshot(paths)
        while True:
            remaining = deadline - time.monotonic()
            if remaining <= 0:
                return None
            ready, _, _ = select.select([fd], [], [], remaining)
            if not ready:
                return None
            os.read(fd, 4096)
            changed = _first_changed(before, _snapshot(paths))
            if changed is not None:
                return changed
            if wds:
                return next(iter(wds.values()))
    finally:
        os.close(fd)


def wait_for_change(paths, timeout):
    last_error = None
    for waiter in (_wait_kqueue, _wait_inotify, _wait_stat):
        try:
            return waiter(paths, timeout)
        except OSError as exc:
            last_error = exc
            continue
    if last_error is not None:
        raise last_error
    return None


def main(argv):
    if len(argv) < 3:
        return 2
    try:
        timeout = float(argv[1])
    except ValueError:
        return 2
    if timeout <= 0:
        return 2
    paths = _existing(argv[2:])
    if not paths:
        return 2
    try:
        changed = wait_for_change(paths, timeout)
    except OSError:
        return 2
    if changed is None:
        return 1
    sys.stdout.write(changed + "\n")
    sys.stdout.flush()
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
