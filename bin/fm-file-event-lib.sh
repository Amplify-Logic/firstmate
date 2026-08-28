#!/usr/bin/env bash
# Shared glasses file-event wait for the watcher poll splice.
#
# This library owns THREE contracts:
#
#   1. The DEFAULT WATCH PATHS for instant glasses wakes. Given an operational
#      home, print the existing mailbox DB files (and their parent directory,
#      so a later WAL/SHM create is visible) plus the bridge photo inbox
#      directory, one path per line:
#          $home/data/glasses-voice-runtime/mailbox.db
#          $home/data/glasses-voice-runtime/mailbox.db-wal
#          $home/data/glasses-voice-runtime/mailbox.db-shm
#          $home/data/glasses-voice-runtime
#          $home/data/bridge-inbox
#      Missing paths are omitted. An empty listing means this home has no
#      glasses surfaces yet and the watcher must keep today's sleep.
#
#   2. The BOUNDED FILE WAIT (fm_file_event_wait). Blocks up to <timeout_secs>
#      for a change on the given existing paths via bin/fm-file-eventwait.py.
#      Prints the first changed path and returns 0 on a change; returns 1 on a
#      clean timeout (the caller has already waited); returns 2 when the wait
#      is unusable (no python, no existing paths, bad args). The watcher uses
#      a change to interrupt event_wait_or_sleep and expire state/.last-check
#      so the next cycle's authenticated check sweep, including a home-local
#      glasses pending/inbox check, runs immediately instead of waiting out
#      FM_CHECK_INTERVAL. The poll loop remains the fail-closed backstop.
#
#   3. The DURABLE CATCH-UP COMPARISON (fm_file_event_newer_than). Returns 0
#      when any existing watched path has an mtime newer than the persisted
#      last-check marker. This closes the watcher-process boundary that a live
#      event waiter cannot observe. A missing marker returns 1 because the
#      caller's ordinary check cadence is already due immediately.
#
# Usage (source):
#   . bin/fm-file-event-lib.sh
#   fm_glasses_watch_paths "$FM_HOME"
#   fm_file_event_wait <timeout_secs> <path> [<path> ...]
#   fm_file_event_newer_than <marker> <path> [<path> ...]
set -u

_FM_FILE_EVENT_LIB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_FILE_EVENTWAIT=${FM_FILE_EVENTWAIT:-$_FM_FILE_EVENT_LIB_DIR/fm-file-eventwait.py}

# fm_glasses_watch_paths: print existing default glasses watch paths for <home>.
fm_glasses_watch_paths() {  # <home>
  local home=$1 runtime inbox
  [ -n "$home" ] || return 0
  runtime="$home/data/glasses-voice-runtime"
  inbox="$home/data/bridge-inbox"
  if [ -e "$runtime/mailbox.db" ]; then
    printf '%s\n' "$runtime/mailbox.db"
    [ -e "$runtime/mailbox.db-wal" ] && printf '%s\n' "$runtime/mailbox.db-wal"
    [ -e "$runtime/mailbox.db-shm" ] && printf '%s\n' "$runtime/mailbox.db-shm"
    [ -d "$runtime" ] && printf '%s\n' "$runtime"
  fi
  [ -d "$inbox" ] && printf '%s\n' "$inbox"
}

# fm_file_event_wait: bounded wait for a change on <path...>.
# 0 = changed (stdout is the path), 1 = clean timeout, 2 = unusable.
fm_file_event_wait() {  # <timeout_secs> <path> [<path> ...]
  local timeout=$1
  shift
  [ -n "$timeout" ] || return 2
  [ "$#" -gt 0 ] || return 2
  command -v python3 >/dev/null 2>&1 || return 2
  [ -f "$FM_FILE_EVENTWAIT" ] || return 2
  python3 "$FM_FILE_EVENTWAIT" "$timeout" "$@"
}

# fm_file_event_newer_than: 0 iff an existing <path> is newer than <marker>.
fm_file_event_newer_than() {  # <marker> <path> [<path> ...]
  local marker=$1 path
  shift
  [ -e "$marker" ] || return 1
  for path in "$@"; do
    [ -e "$path" ] || continue
    [ "$path" -nt "$marker" ] && return 0
  done
  return 1
}
