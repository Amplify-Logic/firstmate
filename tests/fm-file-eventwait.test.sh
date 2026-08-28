#!/usr/bin/env bash
# tests/fm-file-eventwait.test.sh - unit tests for the glasses file-event
# nudger (bin/fm-file-event-lib.sh and bin/fm-file-eventwait.py) and the
# watcher's event_wait_or_sleep splice that expires the slow-check timer.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

TMP=$(fm_test_tmproot fm-file-eventwait)
STATE_DIR="$TMP/state"
HOME_DIR="$TMP/home"
mkdir -p "$STATE_DIR" "$HOME_DIR"

export FM_STATE_OVERRIDE="$STATE_DIR"
export FM_ROOT_OVERRIDE="$ROOT"
export FM_HOME="$HOME_DIR"
# shellcheck source=/dev/null
. "$ROOT/bin/fm-watch.sh"
# shellcheck source=bin/fm-file-event-lib.sh
. "$ROOT/bin/fm-file-event-lib.sh"

WAKE_LOG="$TMP/wakes"
SLEEP_LOG="$TMP/sleeps"
wake() { printf '%s\n' "$1" >> "$WAKE_LOG"; return 0; }

reset_state() {
  rm -f "$STATE_DIR"/*.meta "$STATE_DIR"/*.status "$STATE_DIR"/.wake-queue \
    "$STATE_DIR"/.wake-queue.seq "$STATE_DIR"/.watch-triage.log \
    "$STATE_DIR"/.last-check "$STATE_DIR"/.last-check.pending.* \
    "$STATE_DIR"/.herdr-escalated-* \
    "$TMP"/wtcalled "$TMP"/filewait 2>/dev/null || true
  rm -rf "$HOME_DIR/data"
  : > "$WAKE_LOG"
  : > "$SLEEP_LOG"
  _event_cap_key=""
  _event_cap_ok=0
  _event_cap_fails=0
}

set_mtime() {  # <YYYYMMDDhhmm.ss> <path>
  touch -t "$1" "$2"
}

WAIT_PY="$ROOT/bin/fm-file-eventwait.py"
[ -f "$WAIT_PY" ] || fail "bin/fm-file-eventwait.py is missing"

# --- default path list -------------------------------------------------------
# Later tests override fm_glasses_watch_paths for the watcher splice; the
# calls below still hit the sourced owner. SC2218 is the later mock.

reset_state
# shellcheck disable=SC2218
listed=$(fm_glasses_watch_paths "$HOME_DIR")
[ -z "$listed" ] || fail "an empty home must list no glasses watch paths, got '$listed'"
pass "fm_glasses_watch_paths: empty home lists nothing"

reset_state
mkdir -p "$HOME_DIR/data/glasses-voice-runtime"
# shellcheck disable=SC2218
listed=$(fm_glasses_watch_paths "$HOME_DIR")
[ -z "$listed" ] || fail "a runtime dir without mailbox.db must not be watched, got '$listed'"
pass "fm_glasses_watch_paths: runtime without mailbox.db is omitted"

reset_state
mkdir -p "$HOME_DIR/data/glasses-voice-runtime"
: > "$HOME_DIR/data/glasses-voice-runtime/mailbox.db"
: > "$HOME_DIR/data/glasses-voice-runtime/mailbox.db-wal"
# shellcheck disable=SC2218
listed=$(fm_glasses_watch_paths "$HOME_DIR")
printf '%s\n' "$listed" | grep -Fxq "$HOME_DIR/data/glasses-voice-runtime/mailbox.db" \
  || fail "mailbox.db must be listed: $listed"
printf '%s\n' "$listed" | grep -Fxq "$HOME_DIR/data/glasses-voice-runtime/mailbox.db-wal" \
  || fail "mailbox.db-wal must be listed: $listed"
printf '%s\n' "$listed" | grep -Fxq "$HOME_DIR/data/glasses-voice-runtime" \
  || fail "runtime dir must be listed once mailbox.db exists: $listed"
printf '%s\n' "$listed" | grep -q bridge-inbox \
  && fail "absent inbox must be omitted: $listed"
pass "fm_glasses_watch_paths: mailbox.db plus WAL and parent dir, no missing inbox"

reset_state
mkdir -p "$HOME_DIR/data/bridge-inbox"
# shellcheck disable=SC2218
listed=$(fm_glasses_watch_paths "$HOME_DIR")
[ "$listed" = "$HOME_DIR/data/bridge-inbox" ] \
  || fail "inbox-only home must list only the inbox, got '$listed'"
pass "fm_glasses_watch_paths: inbox-only home lists the inbox"

# --- python helper -----------------------------------------------------------

command -v python3 >/dev/null 2>&1 || fail "python3 is required for fm-file-eventwait.py"

python3 "$WAIT_PY" >"$TMP/help.out" 2>&1
[ $? -eq 2 ] || fail "missing args must exit 2"
python3 "$WAIT_PY" 0 "$TMP/nope" >/dev/null 2>&1
[ $? -eq 2 ] || fail "timeout <= 0 must exit 2"
python3 "$WAIT_PY" 0.2 "$TMP/does-not-exist" >/dev/null 2>&1
[ $? -eq 2 ] || fail "no existing paths must exit 2"
pass "fm-file-eventwait.py: bad args and missing paths exit 2"

idle_file="$TMP/idle.txt"
: > "$idle_file"
python3 "$WAIT_PY" 0.4 "$idle_file" >/dev/null
[ $? -eq 1 ] || fail "unchanged file must time out with exit 1"
pass "fm-file-eventwait.py: unchanged path times out (exit 1)"

watch_file="$TMP/watch.txt"
: > "$watch_file"
python3 "$WAIT_PY" 2 "$watch_file" > "$TMP/changed.out" &
wpid=$!
command sleep 0.25
printf 'nudge\n' >> "$watch_file"
wait "$wpid"
wrc=$?
[ "$wrc" -eq 0 ] || fail "a write during the wait must exit 0, got $wrc"
grep -Fq "$watch_file" "$TMP/changed.out" \
  || fail "changed path must be printed, got '$(cat "$TMP/changed.out")'"
pass "fm-file-eventwait.py: file write exits 0 and prints the path"

watch_dir="$TMP/inbox"
mkdir -p "$watch_dir"
python3 "$WAIT_PY" 2 "$watch_dir" > "$TMP/dir.out" &
wpid=$!
command sleep 0.25
: > "$watch_dir/20260823T000000Z-aa.json"
wait "$wpid"
wrc=$?
[ "$wrc" -eq 0 ] || fail "a new inbox file must exit 0, got $wrc"
pass "fm-file-eventwait.py: directory create exits 0"

# --- durable catch-up across watcher cycles ---------------------------------

reset_state
mkdir -p "$HOME_DIR/data/glasses-voice-runtime"
: > "$HOME_DIR/data/glasses-voice-runtime/mailbox.db"
: > "$STATE_DIR/.last-check"
set_mtime 202608280900.00 "$STATE_DIR/.last-check"
set_mtime 202608280900.00 "$HOME_DIR/data/glasses-voice-runtime"
set_mtime 202608280901.00 "$HOME_DIR/data/glasses-voice-runtime/mailbox.db"
glasses_file_event_catch_up || fail "a write while the watcher was dead must be caught on arm"
[ ! -e "$STATE_DIR/.last-check" ] || fail "dead-watcher catch-up must expire .last-check"
pass "catch-up: event during a dead watcher is detected on arm"

reset_state
mkdir -p "$HOME_DIR/data/glasses-voice-runtime"
: > "$HOME_DIR/data/glasses-voice-runtime/mailbox.db"
: > "$STATE_DIR/.last-check"
set_mtime 202608280900.00 "$HOME_DIR/data/glasses-voice-runtime"
set_mtime 202608280900.00 "$HOME_DIR/data/glasses-voice-runtime/mailbox.db"
set_mtime 202608280901.00 "$STATE_DIR/.last-check"
if glasses_file_event_catch_up; then
  fail "unchanged paths must not catch up before the arm gap"
fi
set_mtime 202608280902.00 "$HOME_DIR/data/glasses-voice-runtime/mailbox.db"
glasses_file_event_catch_up || fail "a write during the arm gap must be caught before waiting"
[ ! -e "$STATE_DIR/.last-check" ] || fail "arm-gap catch-up must expire .last-check"
pass "catch-up: event during the arm gap is detected"

reset_state
mkdir -p "$HOME_DIR/data/glasses-voice-runtime"
: > "$HOME_DIR/data/glasses-voice-runtime/mailbox.db"
: > "$STATE_DIR/.last-check"
set_mtime 202608280900.00 "$HOME_DIR/data/glasses-voice-runtime"
set_mtime 202608280900.00 "$HOME_DIR/data/glasses-voice-runtime/mailbox.db"
set_mtime 202608280901.00 "$STATE_DIR/.last-check"
if glasses_file_event_catch_up; then
  fail "a completed sweep newer than every watched path must not double-fire"
fi
[ -e "$STATE_DIR/.last-check" ] || fail "no-change catch-up must preserve .last-check"
pass "catch-up: unchanged paths do not spuriously double-fire"

reset_state
mkdir -p "$HOME_DIR/data/glasses-voice-runtime"
: > "$HOME_DIR/data/glasses-voice-runtime/mailbox.db"
pending="$STATE_DIR/.last-check.pending.test"
check_sweep_begin "$pending" || fail "check sweep must capture its start boundary"
[ -e "$pending" ] || fail "check sweep must preserve a private pending marker"
[ ! -e "$STATE_DIR/.last-check" ] || fail "check sweep must not publish its boundary before completion"
set_mtime 202608280901.00 "$pending"
set_mtime 202608280902.00 "$HOME_DIR/data/glasses-voice-runtime/mailbox.db"
check_sweep_complete "$pending" || fail "completed check sweep must publish its start boundary"
[ ! -e "$pending" ] || fail "completed check sweep must consume its pending marker"
glasses_file_event_catch_up || fail "a write during a check sweep must remain newer than its published boundary"
[ ! -e "$STATE_DIR/.last-check" ] || fail "check-sweep race catch-up must expire .last-check"
pass "catch-up: event during authenticated check sweep is preserved"

# Neutralize POLL sleeps for the watcher-splice cases below. Real delays in
# the python helper tests above use `command sleep` so they stay timed.
sleep() { printf 'SLEEP\n' >> "$SLEEP_LOG"; }

# --- event_wait_or_sleep: glasses paths replace sleep on tmux-only homes ------

reset_state
fm_write_meta "$STATE_DIR/tk4.meta" "window=fmses:fm-tk4" "kind=ship"
touch "$STATE_DIR/.last-check"
# shellcheck disable=SC2329
fm_glasses_watch_paths() { printf '%s\n' "$TMP/watch.txt"; }
# shellcheck disable=SC2329
fm_file_event_wait() { printf 'FILEWAIT %s\n' "$*" >> "$TMP/filewait"; return 0; }
# shellcheck disable=SC2329
fm_backend_wait_transition() { printf 'CALLED\n' > "$TMP/wtcalled"; return 1; }
event_wait_or_sleep
[ ! -e "$TMP/wtcalled" ] || fail "tmux-only home must not invoke the herdr wait"
grep -q 'FILEWAIT' "$TMP/filewait" || fail "tmux-only home with glasses paths must file-wait"
[ ! -e "$STATE_DIR/.last-check" ] || fail "a file event must expire .last-check"
grep -q 'SLEEP' "$SLEEP_LOG" && fail "a successful file wait must not fall back to sleep"
pass "event_wait_or_sleep: tmux-only home with glasses paths file-waits and expires .last-check"

reset_state
fm_write_meta "$STATE_DIR/tk4.meta" "window=fmses:fm-tk4" "kind=ship"
touch "$STATE_DIR/.last-check"
# shellcheck disable=SC2329
fm_glasses_watch_paths() { printf '%s\n' "$TMP/watch.txt"; }
# shellcheck disable=SC2329
fm_file_event_wait() { return 1; }
event_wait_or_sleep
[ -e "$STATE_DIR/.last-check" ] || fail "a clean file-wait timeout must leave .last-check alone"
grep -q 'SLEEP' "$SLEEP_LOG" && fail "a clean file-wait timeout has already waited; do not sleep again"
pass "event_wait_or_sleep: file-wait timeout does not expire checks or extra-sleep"

reset_state
fm_write_meta "$STATE_DIR/tk4.meta" "window=fmses:fm-tk4" "kind=ship"
: > "$TMP/watch.txt"
: > "$STATE_DIR/.last-check"
set_mtime 202608280900.00 "$TMP/watch.txt"
set_mtime 202608280901.00 "$STATE_DIR/.last-check"
# shellcheck disable=SC2329
fm_glasses_watch_paths() { printf '%s\n' "$TMP/watch.txt"; }
# Model a clean native timeout after a write landed too close to waiter setup
# for that waiter to report it. The next loop's durable catch-up must see it.
# shellcheck disable=SC2329
fm_file_event_wait() {
  set_mtime 202608280902.00 "$TMP/watch.txt"
  return 1
}
# Force the in-memory signature guard to model a waiter that snapshots after
# the write and therefore sees no before/after delta. The persisted mtime
# boundary must still recover it when the timeout hands control back.
(
  file_event_sig() { printf '%s\n' stable; }
  event_wait_or_sleep
)
[ -e "$STATE_DIR/.last-check" ] || fail "a signature-blind timeout fixture expired .last-check before durable catch-up"
glasses_file_event_catch_up || fail "a write hidden behind a wait timeout must catch up on the next loop"
[ ! -e "$STATE_DIR/.last-check" ] || fail "wait-timeout catch-up must expire .last-check"
pass "catch-up: wait-timeout recheck detects a missed event"

reset_state
fm_write_meta "$STATE_DIR/tk4.meta" "window=fmses:fm-tk4" "kind=ship"
# shellcheck disable=SC2329
fm_glasses_watch_paths() { printf '%s\n' "$TMP/watch.txt"; }
# shellcheck disable=SC2329
fm_file_event_wait() { return 2; }
event_wait_or_sleep
grep -q 'SLEEP' "$SLEEP_LOG" || fail "an unusable file wait must fall back to sleep POLL"
pass "event_wait_or_sleep: unusable file wait falls back to sleep POLL"

# --- event_wait_or_sleep: herdr race, file win does not count as herdr fail --

reset_state
fm_write_meta "$STATE_DIR/tk5.meta" "window=default:wG:pQ" "backend=herdr" "kind=ship"
touch "$STATE_DIR/.last-check"
# shellcheck disable=SC2329
fm_backend_events_capable() { return 0; }
# shellcheck disable=SC2329
fm_glasses_watch_paths() { printf '%s\n' "$TMP/watch.txt"; }
# shellcheck disable=SC2329
fm_file_event_wait() { return 0; }
# shellcheck disable=SC2329
fm_backend_wait_transition() {
  command sleep 10
  return 2
}
event_wait_or_sleep
[ ! -e "$STATE_DIR/.last-check" ] || fail "file-win race must expire .last-check"
[ ! -s "$WAKE_LOG" ] || fail "file-win race must not escalate a killed herdr wait as blocked"
[ "$_event_cap_fails" = 0 ] || fail "file-win must not increment herdr fail count, got $_event_cap_fails"
pass "event_wait_or_sleep: file event wins the herdr race, expires checks, and is not a herdr failure"

reset_state
fm_write_meta "$STATE_DIR/tk5.meta" "window=default:wG:pQ" "backend=herdr" "kind=ship"
# shellcheck disable=SC2329
fm_backend_events_capable() { return 0; }
# shellcheck disable=SC2329
fm_glasses_watch_paths() { printf '%s\n' "$TMP/watch.txt"; }
# shellcheck disable=SC2329
fm_file_event_wait() { return 1; }
# shellcheck disable=SC2329
fm_backend_wait_transition() {
  fm_transition_record wG:pQ "wG" "" blocked claude
  return 0
}
event_wait_or_sleep
[ -e "$STATE_DIR/.wake-queue" ] || fail "herdr blocked must still escalate when file wait times out"
grep -q 'herdr: agent blocked' "$STATE_DIR/.wake-queue" \
  || fail "herdr win must keep the blocked stale payload"
pass "event_wait_or_sleep: herdr blocked still escalates when glasses paths are watched"

reset_state
fm_write_meta "$STATE_DIR/tk5.meta" "window=default:wG:pQ" "backend=herdr" "kind=ship"
touch "$STATE_DIR/.last-check"
POLL=0.2
# shellcheck disable=SC2329
fm_backend_events_capable() { return 0; }
# shellcheck disable=SC2329
fm_glasses_watch_paths() { printf '%s\n' "$TMP/watch.txt"; }
# shellcheck disable=SC2329
fm_file_event_wait() {
  [ "$1" = "$POLL" ] || fail "file waiter must receive fractional POLL, got $1"
  command sleep 0.1
  return 0
}
# shellcheck disable=SC2329
fm_backend_wait_transition() { return 2; }
event_wait_or_sleep
[ ! -e "$STATE_DIR/.last-check" ] || fail "a file event after herdr failure must expire .last-check"
[ "$_event_cap_fails" = 1 ] || fail "herdr failure before file event must increment fail count"
grep -q 'SLEEP' "$SLEEP_LOG" && fail "herdr failure must not blind-sleep while the file waiter remains usable"
pass "event_wait_or_sleep: fractional poll survives herdr failure and file event still interrupts"

echo "# fm-file-eventwait.test.sh: all assertions passed"
