#!/usr/bin/env bash
# Behavior tests for the opt-in morning intake gate and its schedule.
#
# Contracts under test:
#   - A home with no `enabled = true` line is completely inert, so cloning the
#     repo or seeding another home never enrolls a device.
#   - The intake arms once per configured local day, at or after the threshold;
#     repeat scheduled polls neither re-arm nor enqueue a second wake.
#   - A morning missed while asleep or offline is caught up by the first run
#     after the threshold, on the real local date, with no simulated sleep.
#   - The wake actually drives an intake to a completed, acknowledged report:
#     arm -> registered watcher check -> claim -> report -> complete -> pending
#     -> acknowledge, through the same commands a live orchestrator runs.
#   - A failed or partial intake cannot advance the completion watermark, and a
#     corrected source message after a same-day failure is still ingested.
#   - Retries are bounded and the exhausted state stays visible.
#   - No existing fleet is overridden: no session lock is taken, no watcher is
#     started, and a foreign home's records are untouched.
#   - Local configuration stays private: unknown keys are refused rather than
#     parked, and status prints only declared knobs.
#   - Install and uninstall work against a temporary home and a fake launchd
#     transport, and refuse a home that never opted in.
# shellcheck disable=SC2016
set -u

# shellcheck source=tests/lib.sh disable=SC1091
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

INTAKE="$ROOT/bin/fm-morning-intake.sh"
SCHEDULE="$ROOT/bin/fm-morning-intake-schedule.sh"
TMP_ROOT=$(fm_test_tmproot fm-morning-intake-tests)

# 2026-09-10 in Europe/Amsterdam (CEST, UTC+2).
T_0530=1789011000   # 05:30 local - before the 06:00 threshold
T_0700=1789016400   # 07:00 local
T_0715=1789017300
T_1100=1789031400   # 11:00 local - a laptop that woke late
T_NEXT_0700=1789102800  # 2026-09-11 07:00 local

new_home() {
  local h=$1
  mkdir -p "$h/config" "$h/state" "$h/reports"
  cat >"$h/config/morning-intake" <<EOF
enabled = true
timezone = Europe/Amsterdam
start_time = 06:00
report_dir = $h/reports
max_attempts = 2
retry_after_seconds = 1800
EOF
}

# Every invocation pins the clock instead of sleeping or suspending anything.
at() {
  local h=$1 now=$2
  shift 2
  FM_HOME="$h" FM_ROOT_OVERRIDE="$ROOT" FM_MORNING_INTAKE_NOW="$now" "$INTAKE" "$@"
}

queue_lines() {
  grep -c '[^[:space:]]' "$1/state/.wake-queue" 2>/dev/null || printf '0\n'
}

test_inert_without_opt_in() {
  local h out code
  h="$TMP_ROOT/no-optin"
  mkdir -p "$h/config" "$h/state"

  # No config file at all: the scheduled entry point must do nothing.
  out=$(at "$h" "$T_0700" run) && code=0 || code=$?
  expect_code 0 "$code" 'run on a home with no config'
  [ -z "$out" ] || fail "un-enrolled home produced output: $out"
  assert_absent "$h/data/morning-intake/state" 'un-enrolled home wrote durable state'
  assert_absent "$h/state/.wake-queue" 'un-enrolled home enqueued a wake'

  # Present but disabled is equally inert, and pending stays silent too.
  printf 'enabled = false\n' >"$h/config/morning-intake"
  out=$(at "$h" "$T_0700" run)
  [ -z "$out" ] || fail "disabled home produced output: $out"
  out=$(at "$h" "$T_0700" pending)
  [ -z "$out" ] || fail "disabled home surfaced a bootstrap line: $out"

  pass 'a home without an explicit opt-in is completely inert, so no clone or device self-enrolls'
}

test_daily_gate_and_no_duplicate_wake() {
  local h out code
  h="$TMP_ROOT/gate"
  new_home "$h"

  out=$(at "$h" "$T_0530" run)
  [ -z "$out" ] || fail "armed before the configured threshold: $out"
  [ "$(queue_lines "$h")" = 0 ] || fail 'a pre-threshold poll enqueued a wake'

  out=$(at "$h" "$T_0700" run)
  assert_contains "$out" 'MORNING_INTAKE: morning-intake due for 2026-09-10' \
    'the first poll past the threshold did not arm the local day'
  [ "$(queue_lines "$h")" = 1 ] || fail 'arming did not enqueue exactly one wake'

  # The scheduled job keeps firing every interval all morning. That must not
  # re-arm the day or enqueue a second wake.
  out=$(at "$h" "$T_0715" run)
  [ -z "$out" ] || fail "a repeat poll re-armed an already-armed day: $out"
  out=$(at "$h" "$T_1100" run)
  [ -z "$out" ] || fail "a later repeat poll re-armed an already-armed day: $out"
  [ "$(queue_lines "$h")" = 1 ] || fail 'repeat polls enqueued duplicate wakes'

  out=$(at "$h" "$T_0700" run --force)
  assert_contains "$out" 'manual --force arm' 'the retained manual command did not force an arm'

  pass 'the intake arms once per local day past the threshold, and repeat wakes never duplicate it'
}

test_missed_morning_catches_up() {
  local h out
  h="$TMP_ROOT/catchup"
  new_home "$h"

  # The machine was asleep or offline through 06:00 and the job never ran. The
  # first run after it wakes must arm the SAME local day, not wait for tomorrow.
  out=$(at "$h" "$T_1100" run)
  assert_contains "$out" 'due for 2026-09-10' 'a morning missed while asleep was not caught up'
  assert_contains "$out" 'first arm of the local day' 'the catch-up arm was misreported'

  pass 'a morning missed while the laptop was asleep or offline is caught up on the first later run'
}

# The end-to-end path: the wake leads to a real report that is completed and
# acknowledged, driven through the same commands an orchestrator would run.
test_wake_drives_intake_to_acknowledged_report() {
  local h out report armed
  h="$TMP_ROOT/e2e"
  new_home "$h"
  report="$h/reports/2026-09-10.md"

  at "$h" "$T_0700" run >/dev/null

  # The live-session delivery path is a registered watcher check, so the running
  # watcher can execute it and wake the primary.
  at "$h" "$T_0700" arm-check >/dev/null
  assert_present "$h/state/morning-intake.check.sh" 'arm-check did not write the watcher shim'
  assert_present "$h/state/morning-intake.check-trust" 'arm-check did not bind the shim bytes'
  [ "$(stat -f '%Lp' "$h/state/morning-intake.check.sh" 2>/dev/null \
    || stat -c '%a' "$h/state/morning-intake.check.sh")" = 700 ] \
    || fail 'the watcher shim is not a private mode-0700 file'
  armed=$(at "$h" "$T_0700" status | awk '$1 == "check_armed:" { print $2 }')
  [ "$armed" = armed ] || fail "check state after arming is '$armed', not armed"

  # Executing the shim the way the watcher does: one line means wake.
  out=$(FM_HOME="$h" FM_ROOT_OVERRIDE="$ROOT" FM_MORNING_INTAKE_NOW="$T_0715" \
    "$h/state/morning-intake.check.sh")
  assert_contains "$out" 'morning-intake due for 2026-09-10' \
    'the registered check did not signal the live primary'
  [ "$(printf '%s\n' "$out" | grep -c '[^[:space:]]')" = 1 ] \
    || fail 'the watcher check printed more than the single wake line'

  # Still owed, but already surfaced: silence, so one owed intake wakes once.
  out=$(FM_HOME="$h" FM_ROOT_OVERRIDE="$ROOT" FM_MORNING_INTAKE_NOW="$T_0715" \
    "$h/state/morning-intake.check.sh")
  [ -z "$out" ] || fail "the check re-woke the primary for an already-surfaced intake: $out"

  out=$(at "$h" "$T_0715" claim)
  assert_contains "$out" 'local_date: 2026-09-10' 'claim did not name the day to ingest'
  assert_contains "$out" 'attempt: 1 of 2' 'claim did not report the bounded attempt'

  printf '# intake 2026-09-10\nfindings\n' >"$report"
  out=$(at "$h" "$T_0715" complete --report "$report" --source-watermark 1789023821.730139)
  assert_contains "$out" 'complete for 2026-09-10' 'complete did not confirm the finished intake'
  [ "$(cat "$h/data/morning-intake/last-complete")" = 2026-09-10 ] \
    || fail 'a verified report did not advance the completion watermark'
  [ "$(cat "$h/data/morning-intake/source-watermark")" = 1789023821.730139 ] \
    || fail 'complete did not record the source watermark'

  out=$(at "$h" "$T_0715" pending)
  [ "$out" = "MORNING_INTAKE: new morning-intake report at $report" ] \
    || fail "the bootstrap surface did not offer the finished report: $out"

  at "$h" "$T_0715" acknowledge "$report"
  out=$(at "$h" "$T_0715" pending)
  [ -z "$out" ] || fail "an acknowledged report still surfaced: $out"
  assert_present "$report" 'acknowledgement deleted the durable report'

  # A completed day is closed to the scheduler until the next local day.
  out=$(at "$h" "$T_1100" run)
  [ -z "$out" ] || fail "a completed day re-armed on a later poll: $out"
  out=$(at "$h" "$T_NEXT_0700" run)
  assert_contains "$out" 'due for 2026-09-11' 'the next local day did not arm'

  pass 'a wake drives the intake through claim, report, completion and acknowledgement'
}

test_failure_cannot_advance_watermark_and_correction_still_lands() {
  local h out code report
  h="$TMP_ROOT/failure"
  new_home "$h"
  report="$h/reports/2026-09-10.md"

  at "$h" "$T_0700" run >/dev/null
  at "$h" "$T_0700" claim >/dev/null

  # A partial intake that names a report it never wrote must be refused.
  out=$(at "$h" "$T_0700" complete --report "$h/reports/missing.md" 2>&1) && code=0 || code=$?
  expect_code 2 "$code" 'complete accepted a report that does not exist'
  assert_contains "$out" 'report is not a regular file' 'the refusal did not name the missing report'
  assert_absent "$h/data/morning-intake/last-complete" \
    'a refused completion advanced the watermark'

  # An empty report is equally not a completed intake.
  : >"$report"
  out=$(at "$h" "$T_0700" complete --report "$report" 2>&1) && code=0 || code=$?
  expect_code 2 "$code" 'complete accepted an empty report'
  assert_absent "$h/data/morning-intake/last-complete" \
    'an empty report advanced the watermark'

  # A report written outside the configured directory is refused too.
  printf 'body\n' >"$TMP_ROOT/outside.md"
  out=$(at "$h" "$T_0700" complete --report "$TMP_ROOT/outside.md" 2>&1) && code=0 || code=$?
  expect_code 2 "$code" 'complete accepted a report outside report_dir'
  assert_absent "$h/data/morning-intake/last-complete" \
    'an out-of-tree report advanced the watermark'

  # An explicit failure is visible and still does not close the day.
  out=$(at "$h" "$T_0700" fail --reason 'source read timed out')
  assert_contains "$out" 'failed for 2026-09-10' 'the failure was not reported'
  assert_contains "$out" 'source read timed out' 'the failure reason was dropped'
  assert_absent "$h/data/morning-intake/last-complete" 'a failure advanced the watermark'
  out=$(at "$h" "$T_0715" pending)
  assert_contains "$out" 'failed for 2026-09-10' 'the failure state is not visible at session start'

  # The source then publishes a correction on the SAME date. Having already seen
  # a failure notice for today must not discard it: the next run re-arms.
  out=$(at "$h" "$T_1100" run)
  assert_contains "$out" 'due for 2026-09-10' \
    'a same-date failure notice suppressed the corrected intake'
  assert_contains "$out" 'source read timed out' 'the retry did not carry the prior failure reason'
  at "$h" "$T_1100" claim >/dev/null
  printf '# corrected intake\ncorrected findings\n' >"$report"
  out=$(at "$h" "$T_1100" complete --report "$report")
  assert_contains "$out" 'complete for 2026-09-10' 'the corrected intake could not complete'
  [ "$(cat "$h/data/morning-intake/last-complete")" = 2026-09-10 ] \
    || fail 'the corrected intake did not advance the watermark'

  pass 'failed and partial intakes never advance the watermark, and a same-date correction still lands'
}

test_retries_are_bounded_and_exhaustion_is_visible() {
  local h out
  h="$TMP_ROOT/bounded"
  new_home "$h"   # max_attempts = 2

  at "$h" "$T_0700" run >/dev/null
  at "$h" "$T_0700" claim >/dev/null
  at "$h" "$T_0700" fail --reason 'attempt one failed' >/dev/null
  at "$h" "$T_0715" run >/dev/null
  at "$h" "$T_0715" claim >/dev/null
  at "$h" "$T_0715" fail --reason 'attempt two failed' >/dev/null

  # The budget is spent: the scheduler must stop re-arming and say so, rather
  # than looping every interval or falling quiet as if the day had succeeded.
  out=$(at "$h" "$T_1100" run)
  assert_contains "$out" 'failed for 2026-09-10 after 2 attempts' \
    'the exhausted retry budget was not reported'
  assert_absent "$h/data/morning-intake/last-complete" \
    'exhausting the retries advanced the watermark'
  [ "$(queue_lines "$h")" = 2 ] || fail 'the exhausted state kept enqueueing wakes'

  # A new local day starts a fresh budget: yesterday never blocks today.
  out=$(at "$h" "$T_NEXT_0700" run)
  assert_contains "$out" 'due for 2026-09-11' "yesterday's exhausted budget blocked the next day"

  pass 'retries are bounded per local day, exhaustion stays visible, and the next day starts fresh'
}

test_no_existing_fleet_is_overridden() {
  local h other out
  h="$TMP_ROOT/isolation"
  other="$TMP_ROOT/other-home"
  new_home "$h"
  mkdir -p "$other/state" "$other/data"
  printf 'held by another session\n' >"$other/state/.session.lock"
  printf 'other-home records\n' >"$other/data/backlog.md"
  printf 'other queue row\n' >"$other/state/.wake-queue"

  at "$h" "$T_0700" run >/dev/null
  at "$h" "$T_0700" arm-check >/dev/null

  # The gate touches nothing outside its own home.
  [ "$(cat "$other/state/.session.lock")" = 'held by another session' ] \
    || fail "the intake disturbed another home's session lock"
  [ "$(cat "$other/data/backlog.md")" = 'other-home records' ] \
    || fail "the intake wrote into another home's records"
  [ "$(cat "$other/state/.wake-queue")" = 'other queue row' ] \
    || fail "the intake appended to another home's wake queue"

  # It takes no lock of its own either, so it cannot compete with a live
  # session that holds this home's lock.
  assert_absent "$h/state/.session.lock" 'the intake created a session lock'
  assert_absent "$h/state/.watch.lock" 'the intake created a watcher lock'
  for out in "$h/state"/*lock*; do
    [ ! -e "$out" ] || fail "the intake created a lock file in state: $out"
  done

  # A live session already holding this home's lock is not displaced.
  printf 'live session\n' >"$h/state/.session.lock"
  out=$(at "$h" "$T_0715" run)
  [ "$(cat "$h/state/.session.lock")" = 'live session' ] \
    || fail "the intake overwrote this home's live session lock"

  # And it never starts an agent or a watcher itself.
  assert_no_grep 'fm-spawn' "$INTAKE" 'the intake gate spawns an agent'
  assert_no_grep 'fm-watch' "$INTAKE" 'the intake gate starts a watcher'
  assert_no_grep 'fm-lock' "$INTAKE" 'the intake gate takes a lock'

  pass 'the intake never takes a lock, starts an agent, or touches another home'
}

test_local_configuration_stays_private() {
  local h out code
  h="$TMP_ROOT/privacy"
  new_home "$h"

  # An unknown key is refused, not silently ignored, so no channel id, token, or
  # account path can be parked in this file and later echoed.
  printf 'enabled = true\nslack_token = shhh-not-a-real-secret\n' >"$h/config/morning-intake"
  out=$(at "$h" "$T_0700" run 2>&1) && code=0 || code=$?
  expect_code 2 "$code" 'an unknown config key was accepted'
  assert_contains "$out" 'unknown config key: slack_token' 'the refusal did not name the rejected key'
  assert_not_contains "$out" 'shhh-not-a-real-secret' 'the refusal echoed the rejected value'

  # status prints only declared knobs and durable state.
  new_home "$h"
  out=$(at "$h" "$T_0700" status)
  assert_contains "$out" 'enabled: true' 'status omitted the opt-in state'
  assert_contains "$out" 'timezone: Europe/Amsterdam' 'status omitted the configured zone'
  assert_contains "$out" 'local_date_now: 2026-09-10' 'status omitted the resolved local day'
  assert_not_contains "$out" 'shhh-not-a-real-secret' 'status leaked a rejected value'

  # The private surfaces this feature writes are ignored by git.
  git -C "$ROOT" check-ignore -q "$ROOT/config/morning-intake" \
    || fail 'config/morning-intake is not gitignored'
  git -C "$ROOT" check-ignore -q "$ROOT/data/morning-intake/state" \
    || fail 'data/morning-intake state is not gitignored'
  git -C "$ROOT" check-ignore -q "$ROOT/state/morning-intake.check.sh" \
    || fail 'the generated watcher shim is not gitignored'

  pass 'unknown config keys are refused, status prints only declared knobs, and every private path is ignored'
}

test_install_and_uninstall_on_a_temp_home() {
  local h out code fakebin agents
  h="$TMP_ROOT/install"
  new_home "$h"
  agents="$TMP_ROOT/LaunchAgents"
  mkdir -p "$agents"

  # A fake launchd transport so the suite never loads a real agent.
  fakebin="$TMP_ROOT/fakebin"
  mkdir -p "$fakebin"
  cat >"$fakebin/launchctl" <<'FAKE'
#!/usr/bin/env bash
printf '%s\n' "$*" >>"$FAKE_LAUNCHCTL_LOG"
FAKE
  chmod +x "$fakebin/launchctl"

  schedule() {
    FM_HOME="$h" FM_ROOT_OVERRIDE="$ROOT" \
    FM_MORNING_INTAKE_LAUNCH_AGENTS_DIR="$agents" \
    FM_MORNING_INTAKE_LAUNCHCTL="$fakebin/launchctl" \
    FAKE_LAUNCHCTL_LOG="$TMP_ROOT/launchctl.log" \
      "$SCHEDULE" "$@"
  }

  out=$(schedule render)
  assert_contains "$out" '<key>StartInterval</key>' 'the rendered schedule omitted StartInterval'
  assert_contains "$out" '<integer>900</integer>' 'the default cadence is not the 900s poll'
  assert_contains "$out" '<key>RunAtLoad</key>' 'the schedule does not run at load, so login never catches up'
  assert_contains "$out" '<string>run</string>' 'the schedule does not call the intake gate'
  assert_contains "$out" 'dev.firstmate.morning-intake.' 'the label is not the per-home intake label'

  # The cadence comes from private config through the gate owner, not a second parser.
  printf 'enabled = true\ntimezone = Europe/Amsterdam\nreport_dir = %s\ninterval_seconds = 300\n' \
    "$h/reports" >"$h/config/morning-intake"
  out=$(schedule render)
  assert_contains "$out" '<integer>300</integer>' 'private cadence configuration was ignored'
  new_home "$h"

  if [ "$(uname)" != Darwin ]; then
    pass 'the schedule renders an inspectable per-home launchd definition (install skipped: not macOS)'
    return 0
  fi

  : >"$TMP_ROOT/launchctl.log"
  # Arm a real day first, so remove can be checked against durable history that
  # actually exists rather than an empty home.
  at "$h" "$T_0700" run >/dev/null
  out=$(schedule install)
  assert_contains "$out" "installed: $agents/" 'install did not report the written definition'
  assert_present "$agents"/dev.firstmate.morning-intake.*.plist 'install wrote no plist'
  assert_grep 'bootstrap gui/' "$TMP_ROOT/launchctl.log" 'install did not load the agent'
  assert_present "$h/state/morning-intake.check.sh" 'install did not arm the live-session check'

  out=$(schedule status)
  assert_contains "$out" 'installed definition' 'status did not show the installed definition'
  assert_contains "$out" 'check_armed: armed' 'status did not report the armed live check'

  out=$(schedule remove)
  assert_contains "$out" 'removed: ' 'remove did not report the deleted definition'
  assert_absent "$agents"/dev.firstmate.morning-intake.*.plist 'remove left the plist behind'
  assert_absent "$h/state/morning-intake.check.sh" 'remove left the watcher check armed'
  assert_grep 'bootout gui/' "$TMP_ROOT/launchctl.log" 'remove did not unload the agent'
  # Uninstalling the schedule is not the same as discarding intake history.
  assert_present "$h/data/morning-intake/state" 'remove discarded the durable intake record'

  # And a home that never opted in cannot be enrolled by install.
  printf 'enabled = false\n' >"$h/config/morning-intake"
  out=$(schedule install 2>&1) && code=0 || code=$?
  expect_code 2 "$code" 'install enrolled a home that never opted in'
  assert_contains "$out" 'not opted in' 'the install refusal did not name the missing opt-in'

  pass 'install, status and remove work against a temporary home and refuse a home without an opt-in'
}

test_bootstrap_surfaces_the_intake() {
  # Session start composes bootstrap verbatim, so pin the actual owner
  # invocation rather than adding another report channel to session start.
  assert_grep '"$SCRIPT_DIR/fm-morning-intake.sh" pending' "$ROOT/bin/fm-bootstrap.sh" \
    'bootstrap no longer surfaces the morning intake'
  assert_grep 'MORNING_INTAKE' "$ROOT/bin/fm-bootstrap.sh" \
    'bootstrap does not document the MORNING_INTAKE diagnostic line'

  pass 'the session-start bootstrap section surfaces an owed, failed, or finished intake'
}

test_inert_without_opt_in
test_daily_gate_and_no_duplicate_wake
test_missed_morning_catches_up
test_wake_drives_intake_to_acknowledged_report
test_failure_cannot_advance_watermark_and_correction_still_lands
test_retries_are_bounded_and_exhaustion_is_visible
test_no_existing_fleet_is_overridden
test_local_configuration_stays_private
test_install_and_uninstall_on_a_temp_home
test_bootstrap_surfaces_the_intake
