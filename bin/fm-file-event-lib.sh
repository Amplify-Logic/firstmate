#!/usr/bin/env bash
# Shared glasses file-event wait for the watcher poll splice.
#
# This library owns FOUR contracts:
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
#      is unusable (no python, no existing paths, bad args). Contract 4 uses
#      a change to interrupt the terminal wait and expire state/.last-check
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
#   4. The WATCHER SPLICE (every fm_fork_* function below). This is the whole
#      body of hook W1: the fork's replacement for the watcher's terminal wait,
#      and the top-of-loop catch-up that runs beside it. Only bin/fm-watch.sh
#      calls these, and only through a guarded either/or at each call site, so
#      with this file absent the watcher runs its own event_wait_or_sleep and
#      skips the catch-up. They are spliced into the watcher's scope rather
#      than standing alone: they read POLL, STATE, FM_HOME, EVENT_CAP_FAIL_MAX
#      and the memoized _event_cap_* state, and they call recorded_windows,
#      window_backend, window_kind, handle_push_transition, triage_log and the
#      fm_backend_* accessors. Sourcing this file anywhere but the watcher gets
#      contracts 1 to 3 only.
#      Known drift point of the either/or design: fm_fork_event_wait_or_sleep
#      carries its own copy of upstream's push-window selection rules (the
#      secondmate exclusion and the first backend/session pinning) and of the
#      memoized capability probe, and for a home with glasses paths that copy,
#      not upstream's event_wait_or_sleep, decides which windows get the fast
#      path. A later upstream change to those rules, such as a new excluded
#      kind or multi-session support, does not reach those homes until the
#      copy here is updated to match.
#      The splice guards itself at load time: fm_fork_assert_watcher_hook_shape
#      walks the watcher beside this file once per source and, if any fm_fork_
#      call there has escaped its command -v guard or the terminal wait has
#      lost its else branch, prints the offending line and disables the
#      override without ever leaving the watcher's loop short of a wait: the
#      fork's terminal wait becomes a direct call to the watcher's own
#      event_wait_or_sleep, the catch-up becomes a no-op, and every other
#      fm_fork_ helper is unset because nothing reaches it any more.
#
# Usage (source):
#   . bin/fm-file-event-lib.sh
#   fm_glasses_watch_paths "$FM_HOME"
#   fm_file_event_wait <timeout_secs> <path> [<path> ...]
#   fm_file_event_newer_than <marker> <path> [<path> ...]
#
# Usage (watcher splice, guarded at each call site):
#   if command -v fm_fork_event_wait_or_sleep >/dev/null 2>&1; then
#     fm_fork_event_wait_or_sleep
#   else
#     event_wait_or_sleep
#   fi
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

# --- Watcher splice (hook W1) ------------------------------------------------
# Everything below is contract 4. It carries the fork's terminal-wait override
# so bin/fm-watch.sh keeps upstream's own event_wait_or_sleep untouched and
# reaches this code only through a guarded either/or. The override's trigger is
# narrower than "the fork is installed": it is this home having glasses watch
# paths, and with none the splice does exactly what the watcher would have done
# on its own.

# stat(1) is not portable between BSD and GNU, and an unknown format token is
# read as an unset variable under set -u, which would kill the watcher
# mid-cycle. Detect the platform once at source time.
if [ "$(uname)" = Darwin ]; then
  _FM_FILE_EVENT_STAT_STYLE=bsd
else
  _FM_FILE_EVENT_STAT_STYLE=gnu
fi

# fm_fork_file_event_sig: one-line signature of the current glasses watch paths
# so a post-wait stat catch-up can expire .last-check even if the event waiter
# was killed when a competing herdr wait returned first.
fm_fork_file_event_sig() {  # <path>...
  local p
  for p in "$@"; do
    if [ "$_FM_FILE_EVENT_STAT_STYLE" = bsd ]; then
      printf '%s:%s\n' "$p" "$(stat -f '%z:%Fm:%Fc' "$p" 2>/dev/null || printf missing)"
    else
      printf '%s:%s\n' "$p" "$(stat -c '%s:%y:%z' "$p" 2>/dev/null || printf missing)"
    fi
  done
}

# fm_fork_expire_check_sweep: make the next loop iteration run authenticated
# checks now instead of waiting out CHECK_INTERVAL. Used when a glasses path
# changed.
fm_fork_expire_check_sweep() {
  rm -f "$STATE/.last-check"
  triage_log "glasses file event; next cycle runs checks immediately"
}

# fm_fork_glasses_file_event_catch_up: close the durable gap a live event waiter
# cannot observe. On watcher start and at the top of every later loop (including
# after a clean wait timeout), compare the current default watch paths with the
# last completed authenticated-check sweep. A newer path expires that marker so
# the check block in this same loop runs immediately. A missing marker is
# already due and needs no mutation. The in-wait signature comparison below
# separately covers a write that races this catch-up with waiter setup.
fm_fork_glasses_file_event_catch_up() {
  local path
  local paths=()
  while IFS= read -r path; do
    [ -n "$path" ] || continue
    paths+=("$path")
  done < <(fm_glasses_watch_paths "$FM_HOME")
  [ "${#paths[@]}" -gt 0 ] || return 1
  fm_file_event_newer_than "$STATE/.last-check" "${paths[@]}" || return 1
  fm_fork_expire_check_sweep
}

# fm_fork_file_event_wait_or_sleep: replace sleep POLL with a bounded file wait
# when glasses paths exist. A change expires the slow-check timer; an unusable
# waiter falls back to sleep POLL.
fm_fork_file_event_wait_or_sleep() {  # <path>...
  local before after rc
  [ "$#" -gt 0 ] || { sleep "$POLL"; return; }
  before=$(fm_fork_file_event_sig "$@")
  fm_file_event_wait "$POLL" "$@"
  rc=$?
  after=$(fm_fork_file_event_sig "$@")
  if [ "$rc" -eq 0 ] || [ "$before" != "$after" ]; then
    fm_fork_expire_check_sweep
    return
  fi
  if [ "$rc" -eq 2 ]; then
    sleep "$POLL"
  fi
}

# fm_fork_kill_pid_tree: stop a raced waiter and its descendants so a herdr
# socket reader cannot outlive the cycle that lost the race.
fm_fork_kill_pid_tree() {  # <pid>
  local pid=$1 child
  [ -n "$pid" ] || return 0
  while IFS= read -r child; do
    [ -n "$child" ] || continue
    fm_fork_kill_pid_tree "$child"
  done < <(pgrep -P "$pid" 2>/dev/null || true)
  kill "$pid" 2>/dev/null || true
}

# fm_fork_apply_push_wait_result: the herdr-only half of the terminal wait,
# shared with the file-event race so a herdr timeout or failure still follows
# upstream's own fail-closed disable rule.
fm_fork_apply_push_wait_result() {  # <backend> <session> <record> <rc>
  local backend=$1 session=$2 record=$3 rc=$4
  case "$rc" in
    0)
      _event_cap_fails=0
      handle_push_transition "$backend" "$session" "$record"
      ;;
    2)
      # Event path unusable this cycle (connect/subscribe failure). Sleep the
      # budget and count toward the runtime-disable threshold; past it, drop to
      # pure polling for the rest of this watcher process.
      _event_cap_fails=$((_event_cap_fails + 1))
      [ "$_event_cap_fails" -ge "$EVENT_CAP_FAIL_MAX" ] && _event_cap_ok=0
      sleep "$POLL"
      ;;
    *)
      # 1: a clean full-budget wait with no actionable edge - the reader already
      # blocked ~POLL, so just continue; the next cycle re-scans.
      _event_cap_fails=0
      ;;
  esac
}

# fm_fork_race_push_and_file_wait: run the herdr transition wait and the glasses
# file wait together. The first completion unblocks this cycle. A file change
# (or a post-wait signature change) expires .last-check. A herdr result is
# applied only when the file waiter did not win, so an interrupted herdr reader
# is not treated as a connect failure.
# Reads FM_FORK_EVENT_WAIT_WINDOWS and FM_FORK_FILE_EVENT_PATHS because bash
# functions cannot see the caller's local arrays.
# Winner is a regular noclobber file, not a fifo: a fifo read is interrupted
# by SIGCHLD when the other waiter exits, which dropped blocked escalations.
fm_fork_race_push_and_file_wait() {  # <backend> <session>
  local backend=$1 session=$2
  local race_dir winner_file recfile herdr_rc_file file_rc_file winner fpid hpid
  local file_rc=1 before after rec rc="" spins=0 poll_whole max_spins
  local -a race_windows=("${FM_FORK_EVENT_WAIT_WINDOWS[@]}")
  local -a race_paths=("${FM_FORK_FILE_EVENT_PATHS[@]}")
  [ "${#race_windows[@]}" -gt 0 ] || return
  [ "${#race_paths[@]}" -gt 0 ] || return

  before=$(fm_fork_file_event_sig "${race_paths[@]}")
  race_dir=$(mktemp -d "${TMPDIR:-/tmp}/fm-file-eventwait.XXXXXX") || {
    fm_fork_file_event_wait_or_sleep "${race_paths[@]}"
    return
  }
  winner_file="$race_dir/winner"
  recfile="$race_dir/rec"
  herdr_rc_file="$race_dir/herdr_rc"
  file_rc_file="$race_dir/file_rc"

  (
    fm_file_event_wait "$POLL" "${race_paths[@]}"
    rc=$?
    printf '%s\n' "$rc" > "$file_rc_file"
    if [ "$rc" -eq 0 ]; then
      set -C
      { printf 'file\n' > "$winner_file"; } 2>/dev/null || true
    fi
  ) &
  fpid=$!
  (
    rec=$(FM_BACKEND_EVENTS_CAPABILITY_CONFIRMED=1 fm_backend_wait_transition \
      "$backend" "$session" "$POLL" "$STATE" "${race_windows[@]}")
    rc=$?
    printf '%s' "$rec" > "$recfile"
    printf '%s\n' "$rc" > "$herdr_rc_file"
    set -C
    { printf 'herdr:%s\n' "$rc" > "$winner_file"; } 2>/dev/null || true
  ) &
  hpid=$!

  poll_whole=${POLL%%.*}
  [[ "$poll_whole" =~ ^[0-9]+$ ]] || poll_whole=0
  max_spins=$(((poll_whole + 3) * 20))
  while [ ! -s "$winner_file" ]; do
    if ! kill -0 "$fpid" 2>/dev/null && ! kill -0 "$hpid" 2>/dev/null; then
      break
    fi
    command sleep 0.05
    spins=$((spins + 1))
    [ "$spins" -ge "$max_spins" ] && break
  done
  winner=$(cat "$winner_file" 2>/dev/null || true)
  if [ "$winner" = herdr:2 ]; then
    wait "$fpid" 2>/dev/null || true
  else
    fm_fork_kill_pid_tree "$fpid"
  fi
  fm_fork_kill_pid_tree "$hpid"
  wait "$fpid" 2>/dev/null || true
  wait "$hpid" 2>/dev/null || true
  [ -f "$file_rc_file" ] && file_rc=$(cat "$file_rc_file")
  winner=$(cat "$winner_file" 2>/dev/null || true)
  rec=$(cat "$recfile" 2>/dev/null || true)
  if [ -z "$winner" ] && [ -f "$herdr_rc_file" ]; then
    winner="herdr:$(cat "$herdr_rc_file")"
  fi
  rm -rf "$race_dir"

  after=$(fm_fork_file_event_sig "${race_paths[@]}")
  if [ "$winner" = file ] || [ "$file_rc" -eq 0 ] || [ "$before" != "$after" ]; then
    fm_fork_expire_check_sweep
  fi
  if [ "$winner" = file ]; then
    return
  fi
  case "$winner" in
    herdr:0|herdr:1)
      rc=${winner#herdr:}
      fm_fork_apply_push_wait_result "$backend" "$session" "$rec" "$rc"
      ;;
    herdr:2)
      _event_cap_fails=$((_event_cap_fails + 1))
      [ "$_event_cap_fails" -ge "$EVENT_CAP_FAIL_MAX" ] && _event_cap_ok=0
      [ "$file_rc" -eq 2 ] && sleep "$POLL"
      ;;
  esac
}

# fm_fork_event_wait_or_sleep: the fork's replacement for the watcher's terminal
# wait. Its trigger is one input upstream has no answer for: a home whose
# glasses watch paths exist. Those paths are collected before anything else,
# and a home without them is handed straight to the watcher's own
# event_wait_or_sleep, so upstream's behaviour for that home is upstream's code
# running rather than a copy of it. For a home with glasses paths the blind
# sleep becomes a bounded file wait, and a push-capable home races the file
# wait against the native transition wait so whichever arrives first unblocks
# the cycle. That race is why the additive form of this hook would be a no-op:
# chaining this wait with upstream's would serialise a shortened wait behind a
# full poll sleep and the mailbox change would stop interrupting anything. The
# poll loop in the watcher still runs every cycle, so this only ever SHORTENS
# latency and can never drop an escalation.
fm_fork_event_wait_or_sleep() {
  local w b session first_backend="" first_session="" p
  local windows=()
  local paths=()
  while IFS= read -r p; do
    [ -n "$p" ] || continue
    paths+=("$p")
  done < <(fm_glasses_watch_paths "$FM_HOME")
  if [ "${#paths[@]}" -eq 0 ]; then
    event_wait_or_sleep
    return
  fi

  while IFS= read -r w; do
    b=$(window_backend "$w")
    fm_backend_has_push "$b" || continue
    # Secondmate endpoints are supervised via status writes, not pane/agent
    # state (an idle or blocked secondmate agent pane is healthy by design), so
    # they are excluded from the fast escalation exactly as the stale loop skips
    # them.
    [ "$(window_kind "$w")" = secondmate ] && continue
    session=${w%%:*}
    if [ -z "$first_backend" ]; then first_backend=$b; first_session=$session; fi
    # One socket connection covers one backend+session; a home normally has a
    # single herdr session. A window in a different backend/session stays on the
    # poll path this cycle.
    if [ "$b" != "$first_backend" ] || [ "$session" != "$first_session" ]; then
      continue
    fi
    windows+=("$w")
  done < <(recorded_windows)

  if [ "${#windows[@]}" -eq 0 ]; then
    fm_fork_file_event_wait_or_sleep "${paths[@]}"
    return
  fi

  # Memoized capability probe (fm_backend_events_capable runs a heavy schema
  # read); re-probed only when the backend/session key changes.
  if [ "$_event_cap_key" != "$first_backend:$first_session" ]; then
    _event_cap_key="$first_backend:$first_session"
    if fm_backend_events_capable "$first_backend" "$first_session"; then
      _event_cap_ok=1
    else
      _event_cap_ok=0
    fi
    _event_cap_fails=0
  fi
  if [ "$_event_cap_ok" != 1 ]; then
    fm_fork_file_event_wait_or_sleep "${paths[@]}"
    return
  fi

  FM_FORK_EVENT_WAIT_WINDOWS=("${windows[@]}")
  FM_FORK_FILE_EVENT_PATHS=("${paths[@]}")
  fm_fork_race_push_and_file_wait "$first_backend" "$first_session"
}

# fm_fork_assert_watcher_hook_shape: the parse-time check for hook W1, in the
# style of fork_registry_assert_no_shadow. Given the watcher's path it proves,
# skipping comment lines, that every fm_fork_ call sits inside a matching
# `if command -v <same function> >/dev/null 2>&1; then` guard and that the
# terminal-wait either/or keeps an explicit else branch calling the watcher's
# own event_wait_or_sleep. Quiet on success; on failure it names the offending
# line on stderr and returns 1. An absent or unreadable watcher is not an
# error: there is nothing to assert, so it returns 0 without output.
# Constraint on the guarded blocks: the walk treats a bare fi as the end of the
# current guard and a bare else as its else branch, so a future nested if
# inside either guarded block would end the guard early and be read as an
# unguarded call; keep those blocks free of nested if/fi.
fm_fork_assert_watcher_hook_shape() {  # <watcher-path>
  local watcher=${1:-} offending
  [ -n "$watcher" ] && [ -r "$watcher" ] || return 0
  offending=$(awk '
    { line = $0 }
    line ~ /^[[:space:]]*#/ { next }
    match(line, /if command -v fm_fork_[A-Za-z0-9_]+ >\/dev\/null 2>&1; then$/) {
      guard = line
      sub(/^.*command -v /, "", guard)
      sub(/ .*$/, "", guard)
      guard_line = FNR
      seen_else = 0
      seen_upstream = 0
      next
    }
    line ~ /^[[:space:]]*else$/ && guard != "" { seen_else = 1; next }
    line ~ /^[[:space:]]*event_wait_or_sleep$/ && seen_else { seen_upstream = 1; next }
    line ~ /^[[:space:]]*fi$/ {
      if (guard == "fm_fork_event_wait_or_sleep" && !(seen_else && seen_upstream)) {
        print FILENAME ":" guard_line ": terminal wait lost its else branch calling event_wait_or_sleep"
      }
      guard = ""
      next
    }
    line ~ /fm_fork_[A-Za-z0-9_]+/ {
      call = line
      sub(/^.*(fm_fork_)/, "fm_fork_", call)
      sub(/[^A-Za-z0-9_].*$/, "", call)
      if (call != guard) { print FILENAME ":" FNR ": unguarded fork call: " line }
    }
  ' "$watcher")
  [ -z "$offending" ] || {
    printf 'fm-file-event-lib: hook W1 shape is unsafe, override disabled: %s\n' "$offending" >&2
    return 1
  }
  return 0
}

# Fail closed in the direction that keeps supervision alive: an unsafe hook
# shape disables the fork override, never the watcher. A refused shape may be
# a bare fm_fork_event_wait_or_sleep call or an if/then with no else, and for
# those unsetting the entry point would leave the main loop with no wait at
# all, so the two entry points become shims instead: the terminal wait runs
# the watcher's own event_wait_or_sleep and nothing else, and the catch-up
# returns inert, as it already does for a home with no watch paths. Every
# other helper is unset because nothing reaches it once the entry points are
# shims. This runs once per source of this file, which for the watcher is
# once per start, and it never exits or returns non-zero out of the sourced
# file.
if ! fm_fork_assert_watcher_hook_shape "$_FM_FILE_EVENT_LIB_DIR/fm-watch.sh"; then
  fm_fork_event_wait_or_sleep() { event_wait_or_sleep; }
  fm_fork_glasses_file_event_catch_up() { return 1; }
  unset -f fm_fork_file_event_wait_or_sleep fm_fork_race_push_and_file_wait \
    fm_fork_apply_push_wait_result fm_fork_expire_check_sweep \
    fm_fork_file_event_sig fm_fork_kill_pid_tree
fi
