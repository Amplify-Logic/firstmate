#!/usr/bin/env bash
# tests/fm-file-eventwait.test.sh - unit tests for the glasses file-event
# nudger (bin/fm-file-event-lib.sh and bin/fm-file-eventwait.py) and the
# watcher splice (hook W1) that expires the slow-check timer, plus the
# degraded path the watcher must take when the library is not installed.
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
fm_fork_glasses_file_event_catch_up || fail "a write while the watcher was dead must be caught on arm"
[ ! -e "$STATE_DIR/.last-check" ] || fail "dead-watcher catch-up must expire .last-check"
pass "catch-up: event during a dead watcher is detected on arm"

reset_state
mkdir -p "$HOME_DIR/data/glasses-voice-runtime"
: > "$HOME_DIR/data/glasses-voice-runtime/mailbox.db"
: > "$STATE_DIR/.last-check"
set_mtime 202608280900.00 "$HOME_DIR/data/glasses-voice-runtime"
set_mtime 202608280900.00 "$HOME_DIR/data/glasses-voice-runtime/mailbox.db"
set_mtime 202608280901.00 "$STATE_DIR/.last-check"
if fm_fork_glasses_file_event_catch_up; then
  fail "unchanged paths must not catch up before the arm gap"
fi
set_mtime 202608280902.00 "$HOME_DIR/data/glasses-voice-runtime/mailbox.db"
fm_fork_glasses_file_event_catch_up || fail "a write during the arm gap must be caught before waiting"
[ ! -e "$STATE_DIR/.last-check" ] || fail "arm-gap catch-up must expire .last-check"
pass "catch-up: event during the arm gap is detected"

reset_state
mkdir -p "$HOME_DIR/data/glasses-voice-runtime"
: > "$HOME_DIR/data/glasses-voice-runtime/mailbox.db"
: > "$STATE_DIR/.last-check"
set_mtime 202608280900.00 "$HOME_DIR/data/glasses-voice-runtime"
set_mtime 202608280900.00 "$HOME_DIR/data/glasses-voice-runtime/mailbox.db"
set_mtime 202608280901.00 "$STATE_DIR/.last-check"
if fm_fork_glasses_file_event_catch_up; then
  fail "a completed sweep newer than every watched path must not double-fire"
fi
[ -e "$STATE_DIR/.last-check" ] || fail "no-change catch-up must preserve .last-check"
pass "catch-up: unchanged paths do not spuriously double-fire"

reset_state
mkdir -p "$HOME_DIR/data/glasses-voice-runtime"
: > "$HOME_DIR/data/glasses-voice-runtime/mailbox.db"
command sleep 1.1
: > "$STATE_DIR/.last-check"
pending="$STATE_DIR/.last-check.pending.test"
command sleep 1.1
check_sweep_begin "$pending" || fail "check sweep must capture its start boundary"
[ -e "$pending" ] || fail "check sweep must preserve a private pending marker"
if fm_fork_glasses_file_event_catch_up; then
  fail "pre-loop catch-up must see no event before the race fixture write"
fi
command sleep 1.1
touch "$HOME_DIR/data/glasses-voice-runtime/mailbox.db"
check_sweep_complete "$pending" || fail "completed check sweep must publish its start boundary"
[ ! -e "$pending" ] || fail "completed check sweep must consume its pending marker"
fm_fork_glasses_file_event_catch_up || fail "a write after pre-loop catch-up must remain newer than the published boundary"
[ ! -e "$STATE_DIR/.last-check" ] || fail "check-sweep race catch-up must expire .last-check"
pass "catch-up: event after pre-loop catch-up is preserved"

# Neutralize POLL sleeps for the watcher-splice cases below. Real delays in
# the python helper tests above use `command sleep` so they stay timed.
sleep() { printf 'SLEEP\n' >> "$SLEEP_LOG"; }

# --- the splice: glasses paths replace sleep on tmux-only homes --------------

reset_state
fm_write_meta "$STATE_DIR/tk4.meta" "window=fmses:fm-tk4" "kind=ship"
touch "$STATE_DIR/.last-check"
# shellcheck disable=SC2329
fm_glasses_watch_paths() { printf '%s\n' "$TMP/watch.txt"; }
# shellcheck disable=SC2329
fm_file_event_wait() { printf 'FILEWAIT %s\n' "$*" >> "$TMP/filewait"; return 0; }
# shellcheck disable=SC2329
fm_backend_wait_transition() { printf 'CALLED\n' > "$TMP/wtcalled"; return 1; }
fm_fork_event_wait_or_sleep
[ ! -e "$TMP/wtcalled" ] || fail "tmux-only home must not invoke the herdr wait"
grep -q 'FILEWAIT' "$TMP/filewait" || fail "tmux-only home with glasses paths must file-wait"
[ ! -e "$STATE_DIR/.last-check" ] || fail "a file event must expire .last-check"
grep -q 'SLEEP' "$SLEEP_LOG" && fail "a successful file wait must not fall back to sleep"
pass "fm_fork_event_wait_or_sleep: tmux-only home with glasses paths file-waits and expires .last-check"

reset_state
fm_write_meta "$STATE_DIR/tk4.meta" "window=fmses:fm-tk4" "kind=ship"
touch "$STATE_DIR/.last-check"
# shellcheck disable=SC2329
fm_glasses_watch_paths() { printf '%s\n' "$TMP/watch.txt"; }
# shellcheck disable=SC2329
fm_file_event_wait() { return 1; }
fm_fork_event_wait_or_sleep
[ -e "$STATE_DIR/.last-check" ] || fail "a clean file-wait timeout must leave .last-check alone"
grep -q 'SLEEP' "$SLEEP_LOG" && fail "a clean file-wait timeout has already waited; do not sleep again"
pass "fm_fork_event_wait_or_sleep: file-wait timeout does not expire checks or extra-sleep"

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
  # Invoked indirectly by fm_fork_event_wait_or_sleep.
  # shellcheck disable=SC2329
  fm_fork_file_event_sig() { printf '%s\n' stable; }
  fm_fork_event_wait_or_sleep
)
[ -e "$STATE_DIR/.last-check" ] || fail "a signature-blind timeout fixture expired .last-check before durable catch-up"
fm_fork_glasses_file_event_catch_up || fail "a write hidden behind a wait timeout must catch up on the next loop"
[ ! -e "$STATE_DIR/.last-check" ] || fail "wait-timeout catch-up must expire .last-check"
pass "catch-up: wait-timeout recheck detects a missed event"

reset_state
fm_write_meta "$STATE_DIR/tk4.meta" "window=fmses:fm-tk4" "kind=ship"
# shellcheck disable=SC2329
fm_glasses_watch_paths() { printf '%s\n' "$TMP/watch.txt"; }
# shellcheck disable=SC2329
fm_file_event_wait() { return 2; }
fm_fork_event_wait_or_sleep
grep -q 'SLEEP' "$SLEEP_LOG" || fail "an unusable file wait must fall back to sleep POLL"
pass "fm_fork_event_wait_or_sleep: unusable file wait falls back to sleep POLL"

# --- the splice: herdr race, a file win does not count as a herdr failure ----

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
fm_fork_event_wait_or_sleep
[ ! -e "$STATE_DIR/.last-check" ] || fail "file-win race must expire .last-check"
[ ! -s "$WAKE_LOG" ] || fail "file-win race must not escalate a killed herdr wait as blocked"
[ "$_event_cap_fails" = 0 ] || fail "file-win must not increment herdr fail count, got $_event_cap_fails"
pass "fm_fork_event_wait_or_sleep: file event wins the herdr race, expires checks, and is not a herdr failure"

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
fm_fork_event_wait_or_sleep
[ -e "$STATE_DIR/.wake-queue" ] || fail "herdr blocked must still escalate when file wait times out"
grep -q 'herdr: agent blocked' "$STATE_DIR/.wake-queue" \
  || fail "herdr win must keep the blocked stale payload"
pass "fm_fork_event_wait_or_sleep: herdr blocked still escalates when glasses paths are watched"

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
fm_fork_event_wait_or_sleep
[ ! -e "$STATE_DIR/.last-check" ] || fail "a file event after herdr failure must expire .last-check"
[ "$_event_cap_fails" = 1 ] || fail "herdr failure before file event must increment fail count"
grep -q 'SLEEP' "$SLEEP_LOG" && fail "herdr failure must not blind-sleep while the file waiter remains usable"
pass "fm_fork_event_wait_or_sleep: fractional poll survives herdr failure and file event still interrupts"

# --- the splice: no glasses paths delegates to upstream's wait ---------------
# Every case above sets glasses paths. With the library present and no paths,
# the fork must hand the cycle to event_wait_or_sleep itself, so the assertions
# here are upstream's own effects for each window shape.

reset_state
fm_write_meta "$STATE_DIR/tk4.meta" "window=fmses:fm-tk4" "kind=ship"
touch "$STATE_DIR/.last-check"
# shellcheck disable=SC2329
fm_glasses_watch_paths() { :; }
# shellcheck disable=SC2329
fm_file_event_wait() { printf 'FILEWAIT %s\n' "$*" >> "$TMP/filewait"; return 0; }
# shellcheck disable=SC2329
fm_backend_wait_transition() { printf 'CALLED\n' > "$TMP/wtcalled"; return 1; }
fm_fork_event_wait_or_sleep
[ "$(grep -c 'SLEEP' "$SLEEP_LOG")" = 1 ] \
  || fail "a tmux-only home without glasses paths must take upstream's single poll sleep"
[ ! -e "$TMP/wtcalled" ] || fail "a tmux-only home must not invoke the herdr wait"
[ ! -e "$TMP/filewait" ] || fail "a home without glasses paths must not attempt a file wait"
[ -e "$STATE_DIR/.last-check" ] || fail "upstream's poll sleep must leave .last-check alone"
pass "fm_fork_event_wait_or_sleep: no glasses paths on a tmux-only home runs upstream's poll sleep"

reset_state
fm_write_meta "$STATE_DIR/tk5.meta" "window=default:wG:pQ" "backend=herdr" "kind=ship"
touch "$STATE_DIR/.last-check"
# shellcheck disable=SC2329
fm_backend_events_capable() { return 0; }
# shellcheck disable=SC2329
fm_glasses_watch_paths() { :; }
# shellcheck disable=SC2329
fm_file_event_wait() { printf 'FILEWAIT %s\n' "$*" >> "$TMP/filewait"; return 0; }
# shellcheck disable=SC2329
fm_backend_wait_transition() {
  printf 'CALLED %s\n' "$*" > "$TMP/wtcalled"
  fm_transition_record wG:pQ "wG" "" blocked claude
  return 0
}
fm_fork_event_wait_or_sleep
grep -q '^CALLED herdr default ' "$TMP/wtcalled" \
  || fail "a herdr home without glasses paths must run upstream's native transition wait"
[ -e "$STATE_DIR/.wake-queue" ] || fail "upstream's herdr wait must still escalate blocked"
grep -q 'herdr: agent blocked' "$STATE_DIR/.wake-queue" \
  || fail "upstream's herdr wait must keep the blocked stale payload"
[ "$_event_cap_fails" = 0 ] || fail "upstream's rc 0 arm resets the fail count, got $_event_cap_fails"
grep -q 'SLEEP' "$SLEEP_LOG" && fail "upstream's herdr win must not sleep"
[ ! -e "$TMP/filewait" ] || fail "a home without glasses paths must not attempt a file wait"
[ -e "$STATE_DIR/.last-check" ] || fail "upstream's herdr wait must leave .last-check alone"
pass "fm_fork_event_wait_or_sleep: no glasses paths on a herdr home runs upstream's native wait"

# --- hook W1 degrades to upstream when the library is absent -----------------
# The splice above is a declared override: it replaces the watcher's terminal
# wait instead of running beside it. The promise that makes that legitimate is
# that a home without bin/fm-file-event-lib.sh behaves exactly as upstream's
# watcher does. Roots are built by symlink so the real checkout is never
# mutated, and the counterfactual at the end proves these assertions can fail.

# build_degraded_root <dest> [<replacement-watcher>]
# Mirrors the checkout with bin/fm-file-event-lib.sh removed. A replacement
# watcher is copied in as a real file so the counterfactual can edit it.
build_degraded_root() {
  local dest=$1 watcher=${2:-} entry
  rm -rf "$dest"
  mkdir -p "$dest/bin"
  for entry in "$ROOT"/*; do
    [ "$(basename "$entry")" = bin ] || ln -s "$entry" "$dest/$(basename "$entry")"
  done
  for entry in "$ROOT"/bin/*; do
    case "$(basename "$entry")" in
      fm-file-event-lib.sh) ;;
      fm-watch.sh)
        if [ -n "$watcher" ]; then
          cp "$watcher" "$dest/bin/fm-watch.sh"
          chmod +x "$dest/bin/fm-watch.sh"
        else
          ln -s "$entry" "$dest/bin/fm-watch.sh"
        fi
        ;;
      *) ln -s "$entry" "$dest/bin/$(basename "$entry")" ;;
    esac
  done
  [ ! -e "$dest/bin/fm-file-event-lib.sh" ] \
    || fail "degraded root must not contain bin/fm-file-event-lib.sh"
  [ -e "$dest/bin/fm-watch.sh" ] || fail "degraded root must still contain the watcher"
}

cat > "$TMP/degraded-driver.sh" <<'DRIVER'
set -u
# shellcheck source=/dev/null
. "$FM_ROOT_OVERRIDE/bin/fm-watch.sh" || { echo "SOURCE-RETURNED-NONZERO"; exit 3; }
command -v fm_fork_event_wait_or_sleep >/dev/null 2>&1 && echo "FORK-WAIT-DEFINED"
command -v fm_fork_glasses_file_event_catch_up >/dev/null 2>&1 && echo "FORK-CATCHUP-DEFINED"
command -v fm_glasses_watch_paths >/dev/null 2>&1 && echo "LIB-LOADED"
sleep() { echo "SLEPT $1"; }
printf 'window=fmses:fm-deg\nkind=ship\n' > "$FM_STATE_OVERRIDE/deg.meta"
if command -v fm_fork_glasses_file_event_catch_up >/dev/null 2>&1; then
  fm_fork_glasses_file_event_catch_up || true
fi
if command -v fm_fork_event_wait_or_sleep >/dev/null 2>&1; then
  fm_fork_event_wait_or_sleep
else
  event_wait_or_sleep
fi
echo "SURVIVED"
DRIVER

# run_degraded_root <root> <tag>; leaves stdout/stderr in $TMP/<tag>.{out,err}
# and the observed exit status in deg_rc. A home with glasses paths is used
# throughout, because that is the only input the override claims.
run_degraded_root() {
  local root=$1 tag=$2 state="$TMP/$2-state" home="$TMP/$2-home"
  rm -rf "$state" "$home"
  mkdir -p "$state" "$home/data/glasses-voice-runtime"
  : > "$home/data/glasses-voice-runtime/mailbox.db"
  touch "$state/.last-check"
  FM_ROOT_OVERRIDE="$root" FM_STATE_OVERRIDE="$state" FM_HOME="$home" FM_POLL=1 \
    bash "$TMP/degraded-driver.sh" > "$TMP/$tag.out" 2> "$TMP/$tag.err"
  deg_rc=$?
  deg_state=$state
}

build_degraded_root "$TMP/degraded-root"
run_degraded_root "$TMP/degraded-root" degraded

[ "$deg_rc" -eq 0 ] \
  || fail "the watcher must load and wait at exit 0 with the fork library absent, got $deg_rc: $(cat "$TMP/degraded.err")"
[ ! -s "$TMP/degraded.err" ] \
  || fail "an absent fork library must be silent, not an error every cycle: $(cat "$TMP/degraded.err")"
for marker in FORK-WAIT-DEFINED FORK-CATCHUP-DEFINED LIB-LOADED SOURCE-RETURNED-NONZERO; do
  grep -Fq "$marker" "$TMP/degraded.out" \
    && fail "degraded run reported $marker: $(cat "$TMP/degraded.out")"
done
grep -Fqx SURVIVED "$TMP/degraded.out" \
  || fail "the degraded terminal wait did not complete: $(cat "$TMP/degraded.out")"
grep -Fq 'SLEPT 1' "$TMP/degraded.out" \
  || fail "with glasses paths present but no library the watcher must blind-sleep POLL: $(cat "$TMP/degraded.out")"
[ -e "$deg_state/.last-check" ] \
  || fail "an absent library must never expire the slow-check timer"
pass "hook W1: an absent fork library leaves the watcher silently on upstream's blind poll sleep"

# The counterfactual. Everything above would also hold for a watcher whose
# source line is not guarded at all, because this file runs without set -e and
# a failed source only prints. That is exactly the degrade test that cannot
# fail, so the guard is deleted here and the same assertions are required to
# catch it. Without this, the block above is decoration.
# The pattern is the watcher's literal source line, so $SCRIPT_DIR must stay
# unexpanded here too.
# shellcheck disable=SC2016
sed 's#^\[ ! -r "\$SCRIPT_DIR/fm-file-event-lib.sh" \] || ##' \
  "$ROOT/bin/fm-watch.sh" > "$TMP/unguarded-watch.sh"
# shellcheck disable=SC2016
grep -q '^\. "\$SCRIPT_DIR/fm-file-event-lib.sh"$' "$TMP/unguarded-watch.sh" \
  || fail "the counterfactual must produce an unguarded source line"
bash -n "$TMP/unguarded-watch.sh" \
  || fail "the counterfactual edit left a syntactically broken watcher"

build_degraded_root "$TMP/unguarded-root" "$TMP/unguarded-watch.sh"
run_degraded_root "$TMP/unguarded-root" unguarded

grep -Fq 'fm-file-event-lib.sh' "$TMP/unguarded.err" \
  || fail "deleting the guard must be caught: the unguarded watcher reported nothing"
[ -s "$TMP/unguarded.err" ] \
  || fail "the degraded assertions above cannot fail, so they prove nothing"
pass "hook W1: the degrade assertions fail when the source guard is deleted"

# --- the real call sites, executed --------------------------------------------
# The driver above re-implements W1 parts two and three, so deleting either
# call-site guard in bin/fm-watch.sh would change nothing there. Both call sites
# sit inside the watcher's main loop, and the watcher returns early when sourced,
# so the only way to reach them is to EXECUTE the watcher as a script from a
# degraded root, the way tests/fm-watch-triage.test.sh runs it: fake bin on
# PATH, private state and home, a tight poll and a quiet cadence, bounded wait,
# then reap. The untouched watcher must run with clean stderr; a copy with a
# call-site guard removed must report that function's own command not found.

# shellcheck source=tests/wake-helpers.sh
. "$(dirname "${BASH_SOURCE[0]}")/wake-helpers.sh"

# wait_file_nonempty <file> [<ticks>]: 0 once <file> has content, 1 on timeout.
wait_file_nonempty() {
  local file=$1 limit=${2:-30} i=0
  while [ "$i" -lt "$limit" ]; do
    [ -s "$file" ] && return 0
    command sleep 0.1
    i=$((i + 1))
  done
  return 1
}

# run_degraded_watcher <tag> [<replacement-watcher>]: execute the watcher from a
# degraded root for a bounded window; stderr lands in $TMP/<tag>-exec.err.
run_degraded_watcher() {
  local tag=$1 watcher=${2:-} dir fakebin root pid
  dir="$TMP/$tag-exec"
  rm -rf "$dir"
  mkdir -p "$dir/state" "$dir/home/data/glasses-voice-runtime"
  fakebin="$dir/fakebin"
  fm_install_fake_caffeinate "$fakebin"
  make_fake_crew_state "$fakebin" >/dev/null
  root="$dir/root"
  build_degraded_root "$root" "$watcher"
  : > "$dir/home/data/glasses-voice-runtime/mailbox.db"
  touch "$dir/state/.last-check"
  PATH="$fakebin:$PATH" FM_STATE_OVERRIDE="$dir/state" FM_HOME="$dir/home" \
    FM_CREW_STATE_BIN="$fakebin/fm-crew-state.sh" FM_POLL=1 FM_SIGNAL_GRACE=1 \
    FM_CHECK_INTERVAL=999999 FM_HEARTBEAT=999999 \
    "$root/bin/fm-watch.sh" > "$TMP/$tag-exec.out" 2> "$TMP/$tag-exec.err" &
  pid=$!
  # Two full poll cycles is enough for both call sites to have run; a copy with
  # a broken guard reports sooner and is reaped as soon as it does.
  wait_file_nonempty "$TMP/$tag-exec.err" 40 || true
  kill "$pid" 2>/dev/null || true
  wait "$pid" 2>/dev/null || true
}

run_degraded_watcher intact
[ ! -s "$TMP/intact-exec.err" ] \
  || fail "the executed degraded watcher must keep clean stderr through its real call sites: $(cat "$TMP/intact-exec.err")"
[ ! -s "$TMP/intact-exec.out" ] \
  || fail "the executed degraded watcher printed a wake reason: $(cat "$TMP/intact-exec.out")"
pass "hook W1: the executed watcher runs both real call sites silently with the library absent"

# Part two: strip the catch-up guard so the bare call remains.
sed '/^  if command -v fm_fork_glasses_file_event_catch_up >\/dev\/null 2>&1; then$/,/^  fi$/{
  /^  if command -v fm_fork_glasses_file_event_catch_up/d
  /^  fi$/d
}' "$ROOT/bin/fm-watch.sh" > "$TMP/nocatchguard-watch.sh"
grep -q '^    fm_fork_glasses_file_event_catch_up || true$' "$TMP/nocatchguard-watch.sh" \
  || fail "the catch-up counterfactual must keep the bare call"
grep -q 'if command -v fm_fork_glasses_file_event_catch_up' "$TMP/nocatchguard-watch.sh" \
  && fail "the catch-up counterfactual must remove the guard"
bash -n "$TMP/nocatchguard-watch.sh" \
  || fail "the catch-up counterfactual edit left a syntactically broken watcher"
run_degraded_watcher nocatchguard "$TMP/nocatchguard-watch.sh"
grep -q 'fm_fork_glasses_file_event_catch_up: command not found' "$TMP/nocatchguard-exec.err" \
  || fail "deleting the catch-up guard must surface its own command not found: $(head -3 "$TMP/nocatchguard-exec.err")"
pass "hook W1: the executed watcher fails by name when the catch-up call-site guard is deleted"

# Part three: strip the terminal-wait either/or so the bare call remains.
sed '/^  if command -v fm_fork_event_wait_or_sleep >\/dev\/null 2>&1; then$/,/^  fi$/{
  /^  if command -v fm_fork_event_wait_or_sleep/d
  /^  else$/d
  /^    event_wait_or_sleep$/d
  /^  fi$/d
}' "$ROOT/bin/fm-watch.sh" > "$TMP/nowaitguard-watch.sh"
grep -q '^    fm_fork_event_wait_or_sleep$' "$TMP/nowaitguard-watch.sh" \
  || fail "the terminal-wait counterfactual must keep the bare call"
grep -q 'if command -v fm_fork_event_wait_or_sleep' "$TMP/nowaitguard-watch.sh" \
  && fail "the terminal-wait counterfactual must remove the either/or"
bash -n "$TMP/nowaitguard-watch.sh" \
  || fail "the terminal-wait counterfactual edit left a syntactically broken watcher"
run_degraded_watcher nowaitguard "$TMP/nowaitguard-watch.sh"
grep -q 'fm_fork_event_wait_or_sleep: command not found' "$TMP/nowaitguard-exec.err" \
  || fail "deleting the terminal-wait either/or must surface its own command not found: $(head -3 "$TMP/nowaitguard-exec.err")"
grep -q 'fm_fork_glasses_file_event_catch_up: command not found' "$TMP/nowaitguard-exec.err" \
  && fail "the terminal-wait counterfactual must not be satisfied by the catch-up guard's failure"
pass "hook W1: the executed watcher fails by name when the terminal-wait either/or is deleted"

# --- hook W1 stays visible in the watcher's own control flow -----------------
# Clause (b) of the standing hook rule: reading bin/fm-watch.sh alone must show
# that a branch can be taken over. There is no executable boundary that can
# prove a source property, so this is asserted against the file.

WATCHER_SRC="$ROOT/bin/fm-watch.sh"
# The pattern is the watcher's own literal source line, so its $SCRIPT_DIR must
# stay unexpanded.
# shellcheck disable=SC2016
grep -q '^\[ ! -r "\$SCRIPT_DIR/fm-file-event-lib.sh" \] || \. "\$SCRIPT_DIR/fm-file-event-lib.sh"$' \
  "$WATCHER_SRC" || fail "the fork library must be sourced through a readability guard"

# fm_fork_assert_watcher_hook_shape in bin/fm-file-event-lib.sh is the single
# owner of the hook-shape rule; the test asserts it by running that function
# against the real watcher here and against guard-removed copies below.
assert_err=$(fm_fork_assert_watcher_hook_shape "$WATCHER_SRC" 2>&1)
assert_rc=$?
[ "$assert_rc" -eq 0 ] \
  || fail "the hook-shape assertion must pass the real watcher, got $assert_rc: $assert_err"
[ -z "$assert_err" ] || fail "the hook-shape assertion must be quiet on success: $assert_err"

grep -q 'if command -v fm_fork_event_wait_or_sleep >/dev/null 2>&1; then' "$WATCHER_SRC" \
  || fail "the terminal wait must announce its either/or at the call site"
grep -A 3 'if command -v fm_fork_event_wait_or_sleep >/dev/null 2>&1; then' "$WATCHER_SRC" \
  | grep -q '^  else$' \
  || fail "the terminal-wait either/or must keep an explicit else branch"
grep -A 4 'if command -v fm_fork_event_wait_or_sleep >/dev/null 2>&1; then' "$WATCHER_SRC" \
  | grep -q '^    event_wait_or_sleep$' \
  || fail "the else branch must call the watcher's own event_wait_or_sleep"
pass "hook W1: the override is guarded and visible at every call site in the watcher"

# --- the parse-time check the library runs on itself --------------------------
# fm_fork_assert_watcher_hook_shape also runs when the library loads, once per
# watcher start. Having passed the real watcher above, it must refuse a
# guard-removed copy at its own exit code naming the line, skip an absent path,
# and when sourced beside an unsafe watcher it must disable the override rather
# than the watcher.

assert_err=$(fm_fork_assert_watcher_hook_shape "$TMP/does-not-exist.sh" 2>&1)
assert_rc=$?
[ "$assert_rc" -eq 0 ] && [ -z "$assert_err" ] \
  || fail "an absent watcher path must be skipped silently, got $assert_rc: $assert_err"

assert_err=$(fm_fork_assert_watcher_hook_shape "$TMP/nocatchguard-watch.sh" 2>&1)
assert_rc=$?
[ "$assert_rc" -eq 1 ] \
  || fail "the hook-shape assertion must refuse an unguarded catch-up call at exit 1, got $assert_rc"
grep -q 'nocatchguard-watch.sh:[0-9]*: unguarded fork call: .*fm_fork_glasses_file_event_catch_up' <<<"$assert_err" \
  || fail "the refusal must name the offending line: $assert_err"

assert_err=$(fm_fork_assert_watcher_hook_shape "$TMP/nowaitguard-watch.sh" 2>&1)
assert_rc=$?
[ "$assert_rc" -eq 1 ] \
  || fail "the hook-shape assertion must refuse an unguarded terminal wait at exit 1, got $assert_rc"
grep -q 'nowaitguard-watch.sh:[0-9]*: unguarded fork call: .*fm_fork_event_wait_or_sleep' <<<"$assert_err" \
  || fail "the refusal must name the unguarded terminal-wait line: $assert_err"

# A guard that keeps its if line but drops the else branch is the other shape
# the assertion must catch.
sed '/^  if command -v fm_fork_event_wait_or_sleep >\/dev\/null 2>&1; then$/,/^  fi$/{
  /^  else$/d
  /^    event_wait_or_sleep$/d
}' "$ROOT/bin/fm-watch.sh" > "$TMP/noelse-watch.sh"
grep -q '^    event_wait_or_sleep$' "$TMP/noelse-watch.sh" \
  && fail "the no-else counterfactual must remove the upstream call from the either/or"
bash -n "$TMP/noelse-watch.sh" || fail "the no-else counterfactual edit left a syntactically broken watcher"
assert_err=$(fm_fork_assert_watcher_hook_shape "$TMP/noelse-watch.sh" 2>&1)
assert_rc=$?
[ "$assert_rc" -eq 1 ] \
  || fail "the hook-shape assertion must refuse a terminal wait without an else branch at exit 1, got $assert_rc"
grep -q 'noelse-watch.sh:[0-9]*: terminal wait lost its else branch' <<<"$assert_err" \
  || fail "the refusal must name the either/or that lost its else branch: $assert_err"
pass "hook W1: the load-time hook-shape assertion refuses each broken shape by line"

# Fail closed toward supervision: source the library from a root whose watcher
# has lost a guard, and require the override to be disabled while the source
# itself still returns 0 and the first three contracts stay usable. Nothing may
# be left uncallable: the terminal-wait entry point must still exist and run
# the watcher's own wait, and the catch-up must still exist and be inert,
# because for a bare or else-less terminal wait the shim is the loop's only
# wait.
UNSAFE_ROOT="$TMP/unsafe-root"
rm -rf "$UNSAFE_ROOT" "$TMP/unsafe-state"
mkdir -p "$UNSAFE_ROOT/bin" "$TMP/unsafe-state"
ln -s "$ROOT/bin/fm-file-event-lib.sh" "$UNSAFE_ROOT/bin/fm-file-event-lib.sh"
ln -s "$ROOT/bin/fm-file-eventwait.py" "$UNSAFE_ROOT/bin/fm-file-eventwait.py"
cp "$TMP/nowaitguard-watch.sh" "$UNSAFE_ROOT/bin/fm-watch.sh"
unsafe_out=$(bash -c '
  set -u
  # shellcheck disable=SC1090,SC1091
  . "$1/bin/fm-file-event-lib.sh"
  echo "SOURCE-RC=$?"
  command -v fm_fork_event_wait_or_sleep >/dev/null 2>&1 && echo "FORK-WAIT-CALLABLE"
  command -v fm_fork_glasses_file_event_catch_up >/dev/null 2>&1 && echo "FORK-CATCHUP-CALLABLE"
  for helper in fm_fork_file_event_wait_or_sleep fm_fork_race_push_and_file_wait \
      fm_fork_apply_push_wait_result fm_fork_expire_check_sweep \
      fm_fork_file_event_sig fm_fork_kill_pid_tree; do
    command -v "$helper" >/dev/null 2>&1 && echo "HELPER-DEFINED $helper"
  done
  command -v fm_glasses_watch_paths >/dev/null 2>&1 && echo "LIB-LOADED"
  event_wait_or_sleep() { echo "UPSTREAM-WAIT-RAN"; }
  STATE="$2"
  touch "$STATE/.last-check"
  fm_fork_event_wait_or_sleep
  echo "FORK-WAIT-RC=$?"
  fm_fork_glasses_file_event_catch_up
  echo "FORK-CATCHUP-RC=$?"
  [ -e "$STATE/.last-check" ] && echo "LAST-CHECK-KEPT"
  echo "SURVIVED"
' _ "$UNSAFE_ROOT" "$TMP/unsafe-state" 2> "$TMP/unsafe-source.err")
grep -Fqx 'SOURCE-RC=0' <<<"$unsafe_out" \
  || fail "sourcing beside an unsafe watcher must not return non-zero: $unsafe_out"
grep -Fqx SURVIVED <<<"$unsafe_out" \
  || fail "sourcing beside an unsafe watcher must not abort the caller: $unsafe_out"
grep -Fqx LIB-LOADED <<<"$unsafe_out" \
  || fail "contracts 1 to 3 must stay usable beside an unsafe watcher: $unsafe_out"
for marker in FORK-WAIT-CALLABLE FORK-CATCHUP-CALLABLE FORK-WAIT-RC=0 FORK-CATCHUP-RC=1 LAST-CHECK-KEPT; do
  grep -Fqx "$marker" <<<"$unsafe_out" \
    || fail "a refused shape must leave both entry points callable and inert, missing $marker: $unsafe_out"
done
[ "$(grep -Fcx UPSTREAM-WAIT-RAN <<<"$unsafe_out")" -eq 1 ] \
  || fail "the refused terminal wait must run the watcher's own wait exactly once: $unsafe_out"
grep -Fq 'HELPER-DEFINED' <<<"$unsafe_out" \
  && fail "a refused shape must unset every other fork helper: $unsafe_out"
grep -q 'hook W1 shape is unsafe, override disabled: .*fm-watch.sh:[0-9]*: unguarded fork call' "$TMP/unsafe-source.err" \
  || fail "the disabled override must say why on stderr: $(cat "$TMP/unsafe-source.err")"
safe_out=$(bash -c '
  set -u
  # shellcheck disable=SC1090,SC1091
  . "$1/bin/fm-file-event-lib.sh"
  command -v fm_fork_event_wait_or_sleep >/dev/null 2>&1 && echo "FORK-WAIT-DEFINED"
' _ "$ROOT" 2>&1)
grep -Fqx FORK-WAIT-DEFINED <<<"$safe_out" \
  || fail "beside the real watcher the override must stay installed: $safe_out"
pass "hook W1: an unsafe hook shape shims the fork override at load time and the watcher always keeps a wait"
echo "# fm-file-eventwait.test.sh: all assertions passed"
