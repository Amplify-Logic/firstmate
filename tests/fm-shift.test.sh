#!/usr/bin/env bash
# tests/fm-shift.test.sh - the shift command (bin/fm-shift.sh) that arms the
# captain's glasses voice loop before a delivery shift, stands it down after,
# and speaks up when the loop dies while he is out.
#
# Everything the real command touches - power state, launchd, Tailscale Serve,
# the mailbox health endpoint, the announce path, and the away-mode owners - is
# faked on PATH or through the script's own owner overrides. No test reads real
# power state, mutates real launchd or Tailscale, touches the live mailbox, or
# speaks a real line into the glasses.
#
# The behaviors under test are the ones a half-armed shift would cost the
# captain three streets from home: refusal by name instead of partial arming,
# an honest status, and an outage that speaks once per episode rather than once
# per watcher sweep.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

SHIFT="$ROOT/bin/fm-shift.sh"

# ---------------------------------------------------------------------------
# Fixture: a hermetic home plus a fakebin shadowing every system command the
# command shells out to.
# ---------------------------------------------------------------------------
make_shift_home() {
  local tmp home fakebin
  tmp=$(fm_test_tmproot fm-shift)
  home="$tmp/home"
  mkdir -p "$home/state" "$home/config" "$home/data"
  fakebin=$(fm_fakebin "$tmp")

  cat > "$fakebin/pmset" <<'SH'
#!/usr/bin/env bash
case "$*" in
  "-g ps") printf "Now drawing from '%s'\n" "${FAKE_POWER_SOURCE:-AC Power}" ;;
  "-g") printf ' sleep %s\n' "${FAKE_SLEEP_LINE:-1 (sleep prevented by caffeinate)}" ;;
esac
SH

  # `launchctl print` reports running unless the label is named in
  # FAKE_LAUNCHD_DOWN; kickstart records the exact label it was asked to restart
  # and can flip the mailbox healthy again through FAKE_HEALTH_FILE.
  cat > "$fakebin/launchctl" <<'SH'
#!/usr/bin/env bash
case "$1" in
  print)
    label=${2##*/}
    case " ${FAKE_LAUNCHD_DOWN:-} " in *" $label "*) exit 1 ;; esac
    printf '\tstate = running\n\tpid = 4242\n'
    ;;
  kickstart)
    printf '%s\n' "$*" >> "${FAKE_LAUNCHCTL_LOG:-/dev/null}"
    [ -z "${FAKE_HEALTH_FILE:-}" ] || printf '%s' "${FAKE_KICKSTART_HEALS_TO:-200}" > "$FAKE_HEALTH_FILE"
    ;;
esac
exit 0
SH

  cat > "$fakebin/tailscale" <<'SH'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "${FAKE_TAILSCALE_LOG:-/dev/null}"
if [ "$1" = serve ] && [ "$2" = status ]; then
  [ "${FAKE_SERVE_ARMED:-1}" = 1 ] || exit 0
  printf 'https://host.ts.net:8443 (tailnet only)\n'
  printf '|-- / proxy http://127.0.0.1:8765\n'
fi
exit 0
SH

  cat > "$fakebin/curl" <<'SH'
#!/usr/bin/env bash
if [ -n "${FAKE_HEALTH_FILE:-}" ] && [ -f "$FAKE_HEALTH_FILE" ]; then
  cat "$FAKE_HEALTH_FILE"
else
  printf '%s' "${FAKE_HEALTH_CODE:-200}"
fi
SH

  # bin/fm-lock.sh asks ps whether the recorded holder is a harness process.
  cat > "$fakebin/ps" <<'SH'
#!/usr/bin/env bash
printf '%s\n' "${FAKE_PS_COMM:-claude}"
SH

  # The dry run during preflight and the real spoken line fail independently, so
  # a test can prove the arm-time confirmation is a separate guarantee.
  cat > "$home/announce" <<'SH'
#!/usr/bin/env bash
if [ "${1:-}" = --dry-run ]; then
  exit "${FAKE_ANNOUNCE_DRYRUN_EXIT:-0}"
fi
printf '%s\n' "$*" >> "${ANNOUNCE_LOG:-/dev/null}"
exit "${FAKE_ANNOUNCE_EXIT:-0}"
SH

  cat > "$home/afk-launch" <<'SH'
#!/usr/bin/env bash
[ "${FAKE_AFK_LAUNCH_EXIT:-0}" = 0 ] || exit "$FAKE_AFK_LAUNCH_EXIT"
: > "$FM_STATE_OVERRIDE/.afk"
SH

  # FAKE_AFK_RETURN_KEEPS_AFK=1 models the return owner failing to stop the
  # daemon: .afk stays and the owner exits 3, exactly as fm-afk-return.sh does.
  cat > "$home/afk-return" <<'SH'
#!/usr/bin/env bash
if [ "${FAKE_AFK_RETURN_KEEPS_AFK:-0}" = 1 ]; then
  printf 'away-mode shutdown failed; lifecycle state preserved for retry\n' >&2
  exit 3
fi
rm -f "$FM_STATE_OVERRIDE/.afk"
printf 'away mode stopped\n'
exit "${FAKE_AFK_RETURN_EXIT:-0}"
SH

  chmod +x "$fakebin"/* "$home/announce" "$home/afk-launch" "$home/afk-return"
  printf '%s\n' "$tmp"
}

# A live process the session-lock reader accepts as this home's holder, paired
# with the fake ps above. Registered for the suite's own reaping.
hold_session_lock() {  # <home>
  local home=$1 pid
  # Detached stdio: a background sleeper inheriting the suite's stdout would
  # hold a caller's pipe open long after the test finished.
  sleep 120 >/dev/null 2>&1 &
  pid=$!
  fm_test_track_pid "$pid"
  printf '%s\n' "$pid" > "$home/state/.lock"
  : > "$home/state/.last-watcher-beat"
}

# Run fm-shift.sh against the fixture with a hermetic environment.
run_shift() {  # <tmp> <args...>
  local tmp=$1
  shift
  env -i \
    PATH="$tmp/fakebin:/usr/bin:/bin:/usr/sbin:/sbin" \
    HOME="${HOME:-/tmp}" TMPDIR="${TMPDIR:-/tmp}" \
    FM_HOME="$tmp/home" \
    FM_STATE_OVERRIDE="$tmp/home/state" \
    FM_CONFIG_OVERRIDE="$tmp/home/config" \
    FM_SUPERVISION_MODEL=autoarm \
    FM_SHIFT_ANNOUNCE="$tmp/home/announce" \
    FM_SHIFT_AFK_LAUNCH="$tmp/home/afk-launch" \
    FM_SHIFT_AFK_RETURN="$tmp/home/afk-return" \
    FM_SHIFT_HEALTH_WAIT="${FM_SHIFT_HEALTH_WAIT:-2}" \
    ANNOUNCE_LOG="$tmp/announce.log" \
    FAKE_POWER_SOURCE="${FAKE_POWER_SOURCE:-AC Power}" \
    FAKE_SLEEP_LINE="${FAKE_SLEEP_LINE:-1 (sleep prevented by caffeinate)}" \
    FAKE_LAUNCHD_DOWN="${FAKE_LAUNCHD_DOWN:-}" \
    FAKE_LAUNCHCTL_LOG="$tmp/launchctl.log" \
    FAKE_TAILSCALE_LOG="$tmp/tailscale.log" \
    FAKE_SERVE_ARMED="${FAKE_SERVE_ARMED:-1}" \
    FAKE_HEALTH_CODE="${FAKE_HEALTH_CODE:-200}" \
    FAKE_HEALTH_FILE="${FAKE_HEALTH_FILE:-}" \
    FAKE_KICKSTART_HEALS_TO="${FAKE_KICKSTART_HEALS_TO:-200}" \
    FAKE_AFK_LAUNCH_EXIT="${FAKE_AFK_LAUNCH_EXIT:-0}" \
    FAKE_AFK_RETURN_EXIT="${FAKE_AFK_RETURN_EXIT:-0}" \
    FAKE_AFK_RETURN_KEEPS_AFK="${FAKE_AFK_RETURN_KEEPS_AFK:-0}" \
    FAKE_ANNOUNCE_EXIT="${FAKE_ANNOUNCE_EXIT:-0}" \
    FAKE_ANNOUNCE_DRYRUN_EXIT="${FAKE_ANNOUNCE_DRYRUN_EXIT:-0}" \
    bash "$SHIFT" "$@"
}

# Run the registered self-check exactly as the watcher runs it: a bare bash on
# the snapshot, with no firstmate environment of its own.
run_registered_check() {  # <tmp>
  local tmp=$1
  env -i \
    PATH="$tmp/fakebin:/usr/bin:/bin:/usr/sbin:/sbin" \
    HOME="${HOME:-/tmp}" \
    ANNOUNCE_LOG="$tmp/announce.log" \
    FAKE_HEALTH_CODE="${FAKE_HEALTH_CODE:-200}" \
    FAKE_HEALTH_FILE="${FAKE_HEALTH_FILE:-}" \
    bash "$tmp/home/state/fm-shift.check.sh"
}

arm_shift() {  # <tmp>
  hold_session_lock "$1/home"
  run_shift "$1" start
}

# ---------------------------------------------------------------------------
# start refuses, by name, before arming anything.
# ---------------------------------------------------------------------------
test_start_refuses_on_battery() {
  local tmp out rc=0
  tmp=$(make_shift_home)
  hold_session_lock "$tmp/home"
  out=$(FAKE_POWER_SOURCE='Battery Power' run_shift "$tmp" start 2>&1) || rc=$?
  expect_code 1 "$rc" 'battery refusal exit'
  assert_contains "$out" 'the Mac is running on battery' 'battery refusal names the cause'
  assert_contains "$out" 'plug the Mac into mains' 'battery refusal names the fix'
  assert_contains "$out" 'leave the lid open' 'battery refusal says the lid must stay open'
  assert_absent "$tmp/home/state/.shift" 'a refused start armed nothing'
  assert_absent "$tmp/home/state/fm-shift.check.sh" 'a refused start registered no self-check'
  assert_absent "$tmp/home/state/.afk" 'a refused start did not start away mode'
  pass 'start: refuses on battery, names the cause and the fix, arms nothing'
}

test_start_refuses_when_the_mailbox_will_not_come_up() {
  local tmp out rc=0
  tmp=$(make_shift_home)
  hold_session_lock "$tmp/home"
  out=$(FAKE_HEALTH_CODE=000 FAKE_KICKSTART_HEALS_TO=000 run_shift "$tmp" start 2>&1) || rc=$?
  expect_code 1 "$rc" 'mailbox refusal exit'
  assert_contains "$out" '/health answered' 'mailbox refusal names the failing health check'
  assert_contains "$out" 'kickstart' 'mailbox refusal names the launchd fix'
  assert_absent "$tmp/home/state/.shift" 'a refused start armed nothing'
  assert_absent "$tmp/home/state/.afk" 'a refused start did not start away mode'
  pass 'start: refuses when the mailbox will not come up, arms nothing'
}

test_start_refuses_when_supervision_is_not_live() {
  local tmp out rc=0
  tmp=$(make_shift_home)
  # No session lock and no watcher beacon: nobody is awake to hear a question.
  out=$(run_shift "$tmp" start 2>&1) || rc=$?
  expect_code 1 "$rc" 'supervision refusal exit'
  assert_contains "$out" 'supervision: DOWN' 'supervision refusal names the component'
  assert_contains "$out" 'nobody is awake to hear' 'supervision refusal says why it matters'
  assert_absent "$tmp/home/state/.shift" 'a refused start armed nothing'
  pass 'start: refuses when supervision is not live, arms nothing'
}

test_start_reports_every_failed_precondition_at_once() {
  local tmp out rc=0
  tmp=$(make_shift_home)
  out=$(FAKE_POWER_SOURCE='Battery Power' FAKE_SERVE_ARMED=0 run_shift "$tmp" start 2>&1) || rc=$?
  expect_code 1 "$rc" 'multi-failure refusal exit'
  assert_contains "$out" 'the Mac is running on battery' 'refusal lists the power failure'
  assert_contains "$out" 'supervision: DOWN' 'refusal lists the supervision failure'
  pass 'start: one refusal lists every precondition that failed, not just the first'
}

# ---------------------------------------------------------------------------
# The second-copy guard: a sick mailbox is restarted through launchd only.
# ---------------------------------------------------------------------------
test_mailbox_recovery_goes_through_launchd_and_never_a_second_copy() {
  local tmp out
  tmp=$(make_shift_home)
  hold_session_lock "$tmp/home"
  printf '000' > "$tmp/health"
  out=$(FAKE_HEALTH_FILE="$tmp/health" FAKE_KICKSTART_HEALS_TO=200 run_shift "$tmp" start 2>&1)
  assert_contains "$out" 'Shift loop armed.' 'a kickstarted mailbox lets the shift arm'
  assert_grep 'kickstart -k' "$tmp/launchctl.log" 'the mailbox was restarted through launchd'
  assert_grep 'com.firstmate.glasses-voice-mailbox' "$tmp/launchctl.log" 'launchd restarted the mailbox label'
  # The only mailbox process this command may ever start is launchd's own.
  assert_no_grep 'glasses-voice-mailbox --' "$tmp/launchctl.log" 'no second mailbox copy was started'
  pass 'start: a sick mailbox is restarted through launchd, never as a second copy'
}

test_missing_serve_mapping_is_rearmed_and_verified() {
  local tmp out
  tmp=$(make_shift_home)
  hold_session_lock "$tmp/home"
  out=$(FAKE_SERVE_ARMED=0 run_shift "$tmp" start 2>&1) || true
  assert_grep 'serve --bg --https=8443 http://127.0.0.1:8765' "$tmp/tailscale.log" \
    'the phone route was re-armed with the runbook command'
  assert_contains "$out" 'phone route: DOWN' 'a route that stays missing is still reported down'
  pass 'start: a missing phone route is re-armed and then verified, not assumed'
}

# ---------------------------------------------------------------------------
# A clean arm, and arming twice.
# ---------------------------------------------------------------------------
test_start_arms_and_speaks_one_confirmation() {
  local tmp out
  tmp=$(make_shift_home)
  out=$(arm_shift "$tmp" 2>&1)
  assert_contains "$out" 'Shift loop armed.' 'start prints its summary'
  assert_present "$tmp/home/state/.shift" 'the armed shift is recorded'
  assert_present "$tmp/home/state/fm-shift.check.sh" 'the self-check was written'
  assert_present "$tmp/home/state/fm-shift.check-trust" 'the self-check was registered'
  assert_present "$tmp/home/state/.afk" 'away mode was started'
  assert_grep 'Shift loop armed. Ask me anything while you ride.' "$tmp/announce.log" \
    'the confirmation was spoken into the glasses'
  # The spoken register: seconds, no URLs, no paths, no ids.
  assert_no_grep 'http' "$tmp/announce.log" 'nothing spoken carries a URL'
  assert_no_grep '/home/state' "$tmp/announce.log" 'nothing spoken carries a path'
  pass 'start: arms every part and speaks one short confirmation'
}

test_start_uses_the_away_mode_launch_owner_not_a_native_background_path() {
  local tmp
  tmp=$(make_shift_home)
  arm_shift "$tmp" >/dev/null 2>&1
  # The launch owner is the only thing that creates .afk in this fixture, so its
  # presence proves the memory-safe launch path was used rather than a
  # hand-rolled background daemon.
  assert_present "$tmp/home/state/.afk" 'away mode came from bin/fm-afk-launch.sh start'
  pass 'start: away mode goes through its launch owner, never a native background path'
}

test_start_is_safe_to_run_twice() {
  local tmp out lines
  tmp=$(make_shift_home)
  arm_shift "$tmp" >/dev/null 2>&1
  out=$(run_shift "$tmp" start 2>&1)
  assert_contains "$out" 'Shift loop armed.' 'the second start still reports armed'
  assert_present "$tmp/home/state/fm-shift.check-trust" 'the self-check is still registered'
  lines=$(grep -c 'fm-shift.sh alarm' "$tmp/home/config/wedge-alarm")
  [ "$lines" = 1 ] || fail "arming twice duplicated the alarm route ($lines copies)"
  lines=$(grep -c ' armed ' "$tmp/home/state/.shift-log")
  [ "$lines" = 1 ] || fail "arming twice recorded the shift twice ($lines times)"
  pass 'start: safe to run twice - it re-verifies and re-converges, duplicating nothing'
}

test_start_refuses_when_away_mode_will_not_start() {
  local tmp out rc=0
  tmp=$(make_shift_home)
  hold_session_lock "$tmp/home"
  out=$(FAKE_AFK_LAUNCH_EXIT=1 run_shift "$tmp" start 2>&1) || rc=$?
  expect_code 1 "$rc" 'away-mode failure refusal exit'
  assert_contains "$out" 'away mode' 'the refusal names away mode'
  assert_absent "$tmp/home/state/.shift" 'no shift was recorded when away mode failed'
  pass 'start: refuses when away mode will not start'
}

test_start_reports_loudly_when_the_confirmation_cannot_be_spoken() {
  local tmp err rc=0
  tmp=$(make_shift_home)
  hold_session_lock "$tmp/home"
  # The dry run during preflight passes, the real line fails: the captain must
  # never leave believing he heard a confirmation he did not.
  err=$(FAKE_ANNOUNCE_EXIT=0 run_shift "$tmp" start 2>&1 >/dev/null) || true
  [ -z "$err" ] || fail "a healthy arm should print nothing on stderr: $err"
  rm -f "$tmp/home/state/.shift" "$tmp/home/state/fm-shift.check.sh" "$tmp/home/state/fm-shift.check-trust"
  err=$(FAKE_ANNOUNCE_EXIT=3 run_shift "$tmp" start 2>&1 >/dev/null) || rc=$?
  expect_code 1 "$rc" 'unspoken confirmation exit'
  assert_contains "$err" 'do not leave until you have heard one' 'an unspoken confirmation is loud'
  pass 'start: an unspoken confirmation is reported loudly rather than passed off as armed'
}

# ---------------------------------------------------------------------------
# The self-check: one line per outage episode, not one per watcher sweep.
# ---------------------------------------------------------------------------
test_self_check_is_silent_while_the_loop_is_healthy() {
  local tmp out before after
  tmp=$(make_shift_home)
  arm_shift "$tmp" >/dev/null 2>&1
  before=$(wc -l < "$tmp/announce.log")
  out=$(FAKE_HEALTH_CODE=200 run_registered_check "$tmp")
  after=$(wc -l < "$tmp/announce.log")
  [ -z "$out" ] || fail "a healthy sweep printed '$out' and would have woken firstmate"
  [ "$before" = "$after" ] || fail 'a healthy sweep spoke into the glasses'
  pass 'self-check: prints nothing and speaks nothing while the loop is healthy'
}

test_self_check_speaks_once_per_episode_not_once_per_sweep() {
  local tmp i out downs spoken
  tmp=$(make_shift_home)
  arm_shift "$tmp" >/dev/null 2>&1
  : > "$tmp/announce.log"

  # Four watcher sweeps into one continuing outage.
  out=$(FAKE_HEALTH_CODE=000 run_registered_check "$tmp")
  assert_contains "$out" 'voice loop is down' 'the first sweep of an outage wakes firstmate'
  for i in 2 3 4; do
    out=$(FAKE_HEALTH_CODE=000 run_registered_check "$tmp")
    [ -z "$out" ] || fail "sweep $i re-reported the same continuing outage: $out"
  done
  downs=$(grep -c ' down ' "$tmp/home/state/.shift-log")
  [ "$downs" = 1 ] || fail "one continuing outage recorded $downs log lines, not 1"

  # The loop comes back: exactly one spoken line, and it is the recovery.
  out=$(FAKE_HEALTH_CODE=200 run_registered_check "$tmp")
  assert_contains "$out" 'recovered' 'recovery wakes firstmate'
  spoken=$(wc -l < "$tmp/announce.log" | tr -d ' ')
  [ "$spoken" = 1 ] || fail "one outage episode spoke $spoken lines into the glasses, not 1"
  assert_grep 'is back up now' "$tmp/announce.log" 'the spoken line is the recovery'
  assert_no_grep 'http' "$tmp/announce.log" 'the spoken recovery carries no URL'

  # A second episode is a new episode and speaks again.
  out=$(FAKE_HEALTH_CODE=000 run_registered_check "$tmp")
  assert_contains "$out" 'voice loop is down' 'a later outage is a new episode'
  out=$(FAKE_HEALTH_CODE=200 run_registered_check "$tmp")
  spoken=$(wc -l < "$tmp/announce.log" | tr -d ' ')
  [ "$spoken" = 2 ] || fail "a second episode should speak once more, got $spoken lines total"
  pass 'self-check: one spoken line per outage episode, never one per sweep'
}

test_self_check_is_inert_once_the_shift_is_over() {
  local tmp out
  tmp=$(make_shift_home)
  arm_shift "$tmp" >/dev/null 2>&1
  # Keep the check file but drop the armed record, the state a crash could leave.
  rm -f "$tmp/home/state/.shift"
  : > "$tmp/announce.log"
  out=$(FAKE_HEALTH_CODE=000 run_registered_check "$tmp")
  [ -z "$out" ] || fail "a check left behind after the shift still reported: $out"
  [ ! -s "$tmp/announce.log" ] || fail 'a check left behind after the shift still spoke'
  pass 'self-check: inert once no shift is armed, so it can never speak out of turn'
}

# Portable mode-and-links read; Linux stat lacks -f, macOS stat lacks -c.
stat_mode_links() {  # <path>
  if [ "$(uname)" = Darwin ]; then
    stat -f '%Lp %l' "$1"
  else
    stat -c '%a %h' "$1"
  fi
}

test_self_check_is_a_plain_registered_check_file() {
  local tmp mode links
  tmp=$(make_shift_home)
  arm_shift "$tmp" >/dev/null 2>&1
  [ ! -L "$tmp/home/state/fm-shift.check.sh" ] || fail 'the registered check is a symlink'
  read -r mode links <<< "$(stat_mode_links "$tmp/home/state/fm-shift.check.sh")"
  [ "$mode" = '700' ] || fail "the registered check is mode $mode, not 700"
  [ "$links" = 1 ] || fail "the registered check has $links links, not 1"
  pass 'self-check: an ordinary single-link mode-0700 file, as the check contract requires'
}

# ---------------------------------------------------------------------------
# The supervision alarm route into the glasses.
# ---------------------------------------------------------------------------
test_supervision_alarm_speaks_without_relaying_internal_detail() {
  local tmp
  tmp=$(make_shift_home)
  arm_shift "$tmp" >/dev/null 2>&1
  : > "$tmp/announce.log"
  run_shift "$tmp" alarm 'SUPERVISION OUTAGE: SUPERVISION DOWN: down for 12m 3s; 2 task(s) in flight: fm-a, fm-b.'
  assert_grep 'stopped watching' "$tmp/announce.log" 'a watcher outage is spoken'
  assert_no_grep 'fm-a' "$tmp/announce.log" 'no task id is ever spoken'
  assert_no_grep '12m' "$tmp/announce.log" 'no raw internal summary is relayed'
  pass 'alarm: a supervision outage is spoken as one plain line, with no ids relayed'
}

test_supervision_alarm_is_silent_when_no_shift_is_armed() {
  local tmp
  tmp=$(make_shift_home)
  run_shift "$tmp" alarm 'SUPERVISION DOWN: down for 1m.'
  [ ! -s "$tmp/announce.log" ] || fail 'the alarm spoke with no shift armed'
  pass 'alarm: silent when no shift is armed'
}

test_alarm_route_preserves_a_captain_written_channel() {
  local tmp
  tmp=$(make_shift_home)
  printf 'osascript\n' > "$tmp/home/config/wedge-alarm"
  arm_shift "$tmp" >/dev/null 2>&1
  assert_grep 'osascript' "$tmp/home/config/wedge-alarm" 'the captain channel survived arming'
  run_shift "$tmp" stop >/dev/null 2>&1
  assert_grep 'osascript' "$tmp/home/config/wedge-alarm" 'the captain channel survived stand-down'
  assert_no_grep 'fm-shift.sh alarm' "$tmp/home/config/wedge-alarm" 'the shift route was removed'
  pass 'alarm route: the shift adds and removes only its own directive'
}

test_alarm_route_survives_a_captain_channel_with_no_trailing_newline() {
  local tmp
  tmp=$(make_shift_home)
  printf 'osascript' > "$tmp/home/config/wedge-alarm"
  arm_shift "$tmp" >/dev/null 2>&1
  grep -qx 'osascript' "$tmp/home/config/wedge-alarm" || fail 'the captain channel is no longer its own intact line'
  grep -q '^# >>> fm-shift.sh' "$tmp/home/config/wedge-alarm" || fail 'the begin sentinel does not start its own line'
  run_shift "$tmp" stop >/dev/null 2>&1
  grep -qx 'osascript' "$tmp/home/config/wedge-alarm" || fail 'the captain channel did not survive stand-down intact'
  assert_no_grep 'fm-shift' "$tmp/home/config/wedge-alarm" 'the whole shift block was removed'
  pass 'alarm route: a captain channel without a trailing newline is never glued to the sentinel'
}

# ---------------------------------------------------------------------------
# The shift log is not a crew task: no state/*.status name, no protocol verbs.
# ---------------------------------------------------------------------------
test_shift_log_is_plain_and_never_a_task_status_file() {
  local tmp
  tmp=$(make_shift_home)
  arm_shift "$tmp" >/dev/null 2>&1
  FAKE_HEALTH_CODE=000 run_registered_check "$tmp" >/dev/null
  FAKE_HEALTH_CODE=200 run_registered_check "$tmp" >/dev/null
  run_shift "$tmp" stop >/dev/null 2>&1
  assert_absent "$tmp/home/state/fm-shift.status" 'no state/*.status file was written for the shift'
  local event
  for event in armed down up stood-down; do
    grep -qE "^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9:]{8}Z $event " "$tmp/home/state/.shift-log" \
      || fail "the $event edge is not one timestamped log line"
  done
  ! grep -qE '^(working|blocked|done):' "$tmp/home/state/.shift-log" || fail 'a crewmate protocol verb appears in the shift log'
  pass 'shift log: plain timestamped events in state/.shift-log, never a crew task status'
}

# ---------------------------------------------------------------------------
# stop.
# ---------------------------------------------------------------------------
test_stop_is_safe_when_nothing_is_armed() {
  local tmp out rc=0
  tmp=$(make_shift_home)
  out=$(run_shift "$tmp" stop 2>&1) || rc=$?
  expect_code 0 "$rc" 'stop with nothing armed exits 0'
  assert_contains "$out" 'No shift is armed' 'stop says plainly that nothing was armed'
  assert_absent "$tmp/home/state/.afk" 'stop did not start anything'
  pass 'stop: safe to run when no shift is armed'
}

test_stop_leaves_the_standing_services_alone() {
  local tmp out
  tmp=$(make_shift_home)
  arm_shift "$tmp" >/dev/null 2>&1
  : > "$tmp/launchctl.log"
  : > "$tmp/tailscale.log"
  out=$(run_shift "$tmp" stop 2>&1)
  assert_contains "$out" 'Shift stood down.' 'stop reports the stand-down'
  assert_absent "$tmp/home/state/.shift" 'the armed record is gone'
  assert_absent "$tmp/home/state/fm-shift.check.sh" 'the self-check registration is gone'
  assert_absent "$tmp/home/state/fm-shift.check-trust" 'the self-check trust binding is gone'
  assert_absent "$tmp/home/state/.afk" 'away mode was stood down'
  [ ! -s "$tmp/launchctl.log" ] || fail 'stop touched a standing LaunchAgent'
  [ ! -s "$tmp/tailscale.log" ] || fail 'stop touched the standing Tailscale mapping'
  pass 'stop: stands down shift state only, never the standing desk services'
}

test_stop_reports_what_happened_during_the_shift() {
  local tmp out
  tmp=$(make_shift_home)
  arm_shift "$tmp" >/dev/null 2>&1
  FAKE_HEALTH_CODE=000 run_registered_check "$tmp" >/dev/null
  FAKE_HEALTH_CODE=200 run_registered_check "$tmp" >/dev/null
  out=$(run_shift "$tmp" stop 2>&1)
  assert_contains "$out" 'ran: ' 'the report says how long the shift ran'
  assert_contains "$out" 'interruptions: 1' 'the report counts the outage the captain lived through'
  assert_contains "$out" 'came back' 'the report says the loop recovered'
  pass 'stop: reports the shift in one short block, including its interruptions'
}

test_stop_clears_an_outage_still_open_at_the_end() {
  local tmp
  tmp=$(make_shift_home)
  arm_shift "$tmp" >/dev/null 2>&1
  FAKE_HEALTH_CODE=000 run_registered_check "$tmp" >/dev/null
  assert_present "$tmp/home/state/.shift-mailbox-outage" 'the outage episode was open'
  run_shift "$tmp" stop >/dev/null 2>&1
  assert_absent "$tmp/home/state/.shift-mailbox-outage" 'stop cleared the open outage episode'
  pass 'stop: clears an outage episode left open at the end of the shift'
}

test_stop_says_plainly_when_away_mode_is_still_running() {
  local tmp out rc=0
  tmp=$(make_shift_home)
  arm_shift "$tmp" >/dev/null 2>&1
  out=$(FAKE_AFK_RETURN_KEEPS_AFK=1 run_shift "$tmp" stop 2>&1) || rc=$?
  expect_code 1 "$rc" 'stop exits non-zero when away mode did not stop'
  assert_present "$tmp/home/state/.afk" 'away mode is genuinely still on'
  assert_contains "$out" 'away mode: STILL RUNNING' 'stop does not claim away mode stopped'
  assert_contains "$out" 'afk-launch stop' 'stop names the launch owner stop command'
  assert_not_contains "$out" 'away mode: stopped' 'no line claims away mode stopped'

  # The benign case stays distinct: the daemon stopped but catch-up is open.
  tmp=$(make_shift_home)
  arm_shift "$tmp" >/dev/null 2>&1
  rc=0
  out=$(FAKE_AFK_RETURN_EXIT=3 run_shift "$tmp" stop 2>&1) || rc=$?
  expect_code 0 "$rc" 'open catch-up is not a failed stand-down'
  assert_contains "$out" 'catch-up to clear' 'open catch-up is reported as such'
  pass 'stop: says away mode is still running when its return owner could not stop it'
}

test_stop_removes_a_stale_task_status_file_from_an_earlier_shift() {
  local tmp
  tmp=$(make_shift_home)
  printf 'working: 2026-01-01T00:00:00Z shift armed\n' > "$tmp/home/state/fm-shift.status"
  run_shift "$tmp" stop >/dev/null 2>&1
  assert_absent "$tmp/home/state/fm-shift.status" 'a stale fm-shift.status was cleared'
  pass 'stop: clears a stale state/fm-shift.status left by an earlier shift'
}

test_stop_clears_arming_that_outlived_its_shift_record() {
  local tmp
  tmp=$(make_shift_home)
  arm_shift "$tmp" >/dev/null 2>&1
  rm -f "$tmp/home/state/.shift"
  run_shift "$tmp" stop >/dev/null 2>&1
  assert_absent "$tmp/home/state/fm-shift.check.sh" 'a stray self-check was cleared'
  if [ -f "$tmp/home/config/wedge-alarm" ]; then
    assert_no_grep 'fm-shift.sh alarm' "$tmp/home/config/wedge-alarm" 'a stray alarm route was cleared'
  fi
  pass 'stop: clears shift arming that outlived its record, so nothing speaks out of turn'
}

# ---------------------------------------------------------------------------
# status.
# ---------------------------------------------------------------------------
test_status_is_honest_when_a_component_is_down() {
  local tmp out rc=0
  tmp=$(make_shift_home)
  arm_shift "$tmp" >/dev/null 2>&1
  out=$(run_shift "$tmp" status 2>&1)
  expect_code 0 "$?" 'status on a healthy armed shift exits 0'
  assert_contains "$out" 'shift: armed' 'status says the shift is armed'
  assert_not_contains "$out" 'DOWN' 'a healthy armed shift reports nothing down'

  rc=0
  out=$(FAKE_HEALTH_CODE=503 run_shift "$tmp" status 2>&1) || rc=$?
  expect_code 1 "$rc" 'status exits non-zero when an armed component is down'
  assert_contains "$out" 'mailbox: DOWN' 'status names the component that is down'
  assert_contains "$out" 'fix:' 'status says what to do about it'
  pass 'status: one line per component, honest and non-zero when an armed one is down'
}

test_status_reports_a_self_check_the_watcher_would_reject() {
  local tmp out rc=0
  tmp=$(make_shift_home)
  arm_shift "$tmp" >/dev/null 2>&1
  printf '# drifted after registration\n' >> "$tmp/home/state/fm-shift.check.sh"
  out=$(run_shift "$tmp" status 2>&1) || rc=$?
  expect_code 1 "$rc" 'a drifted self-check makes status exit non-zero'
  assert_contains "$out" 'outage self-check: DOWN' 'status says the self-check is down'
  assert_contains "$out" 'watcher rejects it' 'status says why the watcher would not run it'
  assert_not_contains "$out" 'watching the mailbox' 'status no longer claims the check is watching'

  # start rewrites and re-registers it, which restores an honest ok.
  run_shift "$tmp" start >/dev/null 2>&1
  rc=0
  out=$(run_shift "$tmp" status 2>&1) || rc=$?
  expect_code 0 "$rc" 're-arming restores a valid registration'
  assert_contains "$out" 'outage self-check: ok' 'status reports the re-registered check as ok'
  pass 'status: a self-check whose bytes drifted after registration is reported down, not watching'
}

test_status_with_no_shift_armed_still_reports_every_component() {
  local tmp out rc=0
  tmp=$(make_shift_home)
  out=$(FAKE_HEALTH_CODE=503 run_shift "$tmp" status 2>&1) || rc=$?
  expect_code 0 "$rc" 'status exits 0 when nothing is armed'
  assert_contains "$out" 'shift: not armed' 'status says no shift is armed'
  assert_contains "$out" 'mailbox: DOWN' 'status still reports the standing components honestly'
  pass 'status: with nothing armed it reports every component but claims no failure'
}

test_usage_is_printed_for_an_unknown_command() {
  local tmp out rc=0
  tmp=$(make_shift_home)
  out=$(run_shift "$tmp" wobble 2>&1) || rc=$?
  expect_code 2 "$rc" 'an unknown command exits 2'
  assert_contains "$out" 'fm-shift.sh start' 'the usage names the real commands'
  pass 'usage: an unknown command prints usage and exits 2'
}

test_start_refuses_on_battery
test_start_refuses_when_the_mailbox_will_not_come_up
test_start_refuses_when_supervision_is_not_live
test_start_reports_every_failed_precondition_at_once
test_mailbox_recovery_goes_through_launchd_and_never_a_second_copy
test_missing_serve_mapping_is_rearmed_and_verified
test_start_arms_and_speaks_one_confirmation
test_start_uses_the_away_mode_launch_owner_not_a_native_background_path
test_start_is_safe_to_run_twice
test_start_refuses_when_away_mode_will_not_start
test_start_reports_loudly_when_the_confirmation_cannot_be_spoken
test_self_check_is_silent_while_the_loop_is_healthy
test_self_check_speaks_once_per_episode_not_once_per_sweep
test_self_check_is_inert_once_the_shift_is_over
test_self_check_is_a_plain_registered_check_file
test_supervision_alarm_speaks_without_relaying_internal_detail
test_supervision_alarm_is_silent_when_no_shift_is_armed
test_alarm_route_preserves_a_captain_written_channel
test_alarm_route_survives_a_captain_channel_with_no_trailing_newline
test_shift_log_is_plain_and_never_a_task_status_file
test_stop_is_safe_when_nothing_is_armed
test_stop_leaves_the_standing_services_alone
test_stop_reports_what_happened_during_the_shift
test_stop_clears_an_outage_still_open_at_the_end
test_stop_says_plainly_when_away_mode_is_still_running
test_stop_removes_a_stale_task_status_file_from_an_earlier_shift
test_stop_clears_arming_that_outlived_its_shift_record
test_status_is_honest_when_a_component_is_down
test_status_reports_a_self_check_the_watcher_would_reject
test_status_with_no_shift_armed_still_reports_every_component
test_usage_is_printed_for_an_unknown_command
