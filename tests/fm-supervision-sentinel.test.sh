#!/usr/bin/env bash
# Behavior tests for the launchd-backed supervision-outage sentinel.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

SENTINEL="$ROOT/bin/fm-supervision-sentinel.sh"
TMP_ROOT=$(fm_test_tmproot fm-supervision-sentinel)

# Exact-service teardown for the opt-in real-launchd smoke below. Registered here
# rather than inside that test so a `fail` anywhere still retires the one service
# it may have bootstrapped, and never touches any other launchd label.
FM_SENTINEL_SMOKE_SERVICE=

fm_sentinel_bootout_smoke_service() {
  local service=$1 i=0
  /bin/launchctl bootout "$service" >/dev/null 2>&1 || true
  while [ "$i" -lt 100 ] && /bin/launchctl print "$service" >/dev/null 2>&1; do
    sleep 0.05
    i=$((i + 1))
  done
  ! /bin/launchctl print "$service" >/dev/null 2>&1
}

fm_sentinel_suite_teardown() {
  local rc=$?
  if [ -n "$FM_SENTINEL_SMOKE_SERVICE" ]; then
    if fm_sentinel_bootout_smoke_service "$FM_SENTINEL_SMOKE_SERVICE"; then
      FM_SENTINEL_SMOKE_SERVICE=
    else
      printf 'not ok - real-launchd smoke left %s loaded; remove it with: launchctl bootout %s\n' \
        "$FM_SENTINEL_SMOKE_SERVICE" "$FM_SENTINEL_SMOKE_SERVICE" >&2
      rc=1
    fi
  fi
  fm_test_cleanup
  exit "$rc"
}
trap fm_sentinel_suite_teardown EXIT

make_primary() {
  local dir=$1
  mkdir -p "$dir/bin" "$dir/state" "$dir/config"
  git init -q "$dir"
  git -C "$dir" commit -q --allow-empty -m init
  : > "$dir/AGENTS.md"
}

make_recorder() {
  local path=$1 log=$2
  cat > "$path" <<SH
#!/usr/bin/env bash
printf '%s\\t%s\\n' "\$1" "\$2" >> "$log"
SH
  chmod +x "$path"
}

run_check() {
  local home=$1 recorder=$2
  FM_SUPERVISION_SENTINEL_MODE=auto \
    FM_ROOT_OVERRIDE="$home" \
    FM_HOME="$home" \
    FM_STATE_OVERRIDE="$home/state" \
    FM_WEDGE_ALARM_CHANNEL=osascript \
    FM_WEDGE_ALARM_EXEC="$recorder" \
    "$SENTINEL" scheduled-check
}

run_mode() { # <home> <recorder> <mode>
  local home=$1 recorder=$2 mode=$3
  FM_SUPERVISION_SENTINEL_MODE=auto \
    FM_ROOT_OVERRIDE="$home" \
    FM_HOME="$home" \
    FM_STATE_OVERRIDE="$home/state" \
    FM_WEDGE_ALARM_CHANNEL=osascript \
    FM_WEDGE_ALARM_EXEC="$recorder" \
    "$SENTINEL" "$mode"
}

install_stale_watcher_fixture() { # <home> <holder-pid> <watcher-path>
  local home=$1 holder=$2 watcher=$3 identity
  identity=$(FM_STATE_OVERRIDE="$home/state" bash -c '. "$1"; fm_pid_identity "$2"' _ "$ROOT/bin/fm-wake-lib.sh" "$holder") || return 1
  mkdir -p "$home/state/.watch.lock"
  printf '%s\n' "$holder" > "$home/state/.watch.lock/pid"
  printf '%s\n' "$home" > "$home/state/.watch.lock/fm-home"
  printf '%s\n' "$watcher" > "$home/state/.watch.lock/watcher-path"
  printf '%s\n' "$identity" > "$home/state/.watch.lock/pid-identity"
}

test_stale_beacon_alert_is_loud_deduplicated_backed_off_and_rearmed() {
  local home="$TMP_ROOT/check" recorder="$TMP_ROOT/record-alert" log="$TMP_ROOT/alerts.log" holder i text marker delivered next
  make_primary "$home"
  make_recorder "$recorder" "$log"
  for i in 1 2 3 4 5 6; do
    printf 'project=test\n' > "$home/state/task-$i.meta"
  done
  sleep 60 &
  holder=$!
  install_stale_watcher_fixture "$home" "$holder" "$ROOT/bin/fm-watch.sh" || {
    kill "$holder" 2>/dev/null || true
    wait "$holder" 2>/dev/null || true
    fail "could not identify the stale-beacon watcher fixture"
  }
  touch -t 202001010000 "$home/state/.last-watcher-beat"
  marker="$home/state/.supervision-outage-alarm"

  run_check "$home" "$recorder"
  [ -s "$marker" ] || fail "stale watcher check did not write its durable outage marker"
  [ "$(wc -l < "$log" | tr -d '[:space:]')" -eq 1 ] || fail "first outage check did not emit exactly one active alert"
  text=$(cat "$log")
  assert_contains "$text" $'osascript\tSUPERVISION DOWN: 6 task(s) in flight' "active alert did not lead with an unambiguous outage and task count"
  assert_contains "$text" "last watcher beat:" "active alert omitted the outage age evidence"
  assert_contains "$text" "grace 300s" "active alert omitted the configured grace"
  assert_contains "$text" "No automatic restart was attempted" "active alert did not state the conservative recovery result"
  assert_contains "$(cat "$marker")" 'delivery_count=1' "initial alert did not record the first successful delivery"
  delivered=$(awk -F= '$1 == "delivered_at" { print $2 }' "$marker")
  next=$(awk -F= '$1 == "next_alert_at" { print $2 }' "$marker")
  [ "$((next - delivered))" -eq 300 ] || fail "first repeat delay was not five minutes"

  run_check "$home" "$recorder"
  [ "$(wc -l < "$log" | tr -d '[:space:]')" -eq 1 ] || fail "one continuous outage emitted a duplicate alert inside its backoff window"

  awk -F= '$1 == "next_alert_at" { print "next_alert_at=0"; next } { print }' "$marker" > "$marker.next"
  mv "$marker.next" "$marker"
  run_check "$home" "$recorder"
  [ "$(wc -l < "$log" | tr -d '[:space:]')" -eq 2 ] || fail "due continuous-outage reminder was not delivered"
  assert_contains "$(cat "$marker")" 'delivery_count=2' "repeat alert did not advance its delivery count"
  delivered=$(awk -F= '$1 == "delivered_at" { print $2 }' "$marker")
  next=$(awk -F= '$1 == "next_alert_at" { print $2 }' "$marker")
  [ "$((next - delivered))" -eq 600 ] || fail "second repeat did not exponentially back off to ten minutes"

  # Flapping outage: the watcher was re-armed and reaped again between two host
  # checks, so the beacon evidence moved. That is a new episode and must alert
  # now instead of inheriting the backed-off schedule of the previous one.
  touch -t 202001020000 "$home/state/.last-watcher-beat"
  run_check "$home" "$recorder"
  [ "$(wc -l < "$log" | tr -d '[:space:]')" -eq 3 ] || fail "a re-reaped watcher stayed silent under the previous episode's backoff"
  assert_contains "$(cat "$marker")" 'delivery_count=1' "changed outage evidence did not restart the repeat schedule"
  delivered=$(awk -F= '$1 == "delivered_at" { print $2 }' "$marker")
  next=$(awk -F= '$1 == "next_alert_at" { print $2 }' "$marker")
  [ "$((next - delivered))" -eq 300 ] || fail "new outage episode did not reset the backoff to five minutes"

  rm -f "$home/state/task-"*.meta
  run_check "$home" "$recorder"
  [ ! -e "$marker" ] || fail "healthy/idle transition did not clear the outage episode marker"
  printf 'project=test\n' > "$home/state/task-new.meta"
  run_check "$home" "$recorder"
  kill "$holder" 2>/dev/null || true
  wait "$holder" 2>/dev/null || true
  [ "$(wc -l < "$log" | tr -d '[:space:]')" -eq 4 ] || fail "a later outage episode did not re-arm the active alert"
  pass "supervision sentinel: stale beacon alert deduplicates, backs off, resets on a new episode, and re-arms"
}

test_guard_note_outage_records_evidence_without_notifying() {
  local home="$TMP_ROOT/note" recorder="$TMP_ROOT/record-note" log="$TMP_ROOT/note-alerts.log" marker
  make_primary "$home"
  make_recorder "$recorder" "$log"
  printf 'project=test\n' > "$home/state/task.meta"
  touch -t 202001010000 "$home/state/.last-watcher-beat"
  marker="$home/state/.supervision-outage-alarm"

  FM_SUPERVISION_SENTINEL_MODE=auto \
    FM_ROOT_OVERRIDE="$home" FM_HOME="$home" FM_STATE_OVERRIDE="$home/state" \
    FM_WEDGE_ALARM_CHANNEL=osascript FM_WEDGE_ALARM_EXEC="$recorder" \
    "$SENTINEL" note-outage || fail "marker-only outage note failed"
  [ ! -e "$log" ] || fail "in-harness note-outage crossed the active-channel boundary: $(cat "$log")"
  [ -s "$marker" ] || fail "note-outage did not record the durable outage evidence"
  assert_contains "$(cat "$marker")" 'SUPERVISION DOWN: 1 task(s) in flight' "note-outage marker omitted the outage summary"
  assert_contains "$(cat "$marker")" 'delivery=pending' "note-outage claimed a delivery it never attempted"
  assert_contains "$(cat "$marker")" 'attempt_at=0' "note-outage left a delivery lease the host check must wait out"
  [ ! -e "$home/state/.supervision-sentinel-last-check" ] || fail "note-outage forged the launchd liveness proof"

  run_check "$home" "$recorder"
  [ "$(wc -l < "$log" | tr -d '[:space:]')" -eq 1 ] || fail "the scheduled check did not immediately deliver a noted outage"
  assert_contains "$(cat "$marker")" 'delivery=sent' "delivered alert did not commit its delivery state"

  # A noted outage must never clobber an already-delivered episode's backoff.
  FM_SUPERVISION_SENTINEL_MODE=auto \
    FM_ROOT_OVERRIDE="$home" FM_HOME="$home" FM_STATE_OVERRIDE="$home/state" \
    FM_WEDGE_ALARM_CHANNEL=osascript FM_WEDGE_ALARM_EXEC="$recorder" \
    "$SENTINEL" note-outage || fail "repeat outage note failed"
  assert_contains "$(cat "$marker")" 'delivery=sent' "a later note-outage reset a committed delivery record"
  [ "$(wc -l < "$log" | tr -d '[:space:]')" -eq 1 ] || fail "note-outage notified after the episode was already delivered"

  assert_not_contains "$(cat "$ROOT/bin/fm-turnend-guard.sh" "$ROOT/bin/fm-continuity-pretool-check.sh")" \
    'SENTINEL" check' "an in-harness guard still waits on the active-alert boundary"
  pass "supervision sentinel: in-harness guards record outage evidence without any notifier work"
}

test_in_harness_modes_are_marker_only_and_honor_a_durable_disarm() {
  local home="$TMP_ROOT/marker-only" recorder="$TMP_ROOT/record-marker-only" log="$TMP_ROOT/marker-only.log" marker mode
  make_primary "$home"
  make_recorder "$recorder" "$log"
  printf 'project=test\n' > "$home/state/task.meta"
  touch -t 202001010000 "$home/state/.last-watcher-beat"
  marker="$home/state/.supervision-outage-alarm"

  # `scheduled-check` is the only mode that may cross the external boundary, so
  # neither in-harness mode alerts even though both see the same outage.
  for mode in check note-outage; do
    rm -f "$marker"
    run_mode "$home" "$recorder" "$mode" || fail "$mode failed on an unhealthy home"
    [ ! -e "$log" ] || fail "$mode crossed the active-channel boundary: $(cat "$log")"
    [ -s "$marker" ] || fail "$mode did not record the durable outage evidence"
    assert_contains "$(cat "$marker")" 'delivery=pending' "$mode claimed a delivery it never attempted"
    assert_contains "$(cat "$marker")" 'attempt_at=0' "$mode left a delivery lease the host check must wait out"
    [ ! -e "$home/state/.supervision-sentinel-last-check" ] || fail "$mode forged the launchd liveness proof"
  done

  # A deliberately disarmed home stays silent on every channel and stops
  # accumulating evidence until an explicit verified enable.
  rm -f "$marker"
  printf 'state=disarmed\n' > "$home/state/.supervision-sentinel.disarmed"
  for mode in check note-outage scheduled-check; do
    run_mode "$home" "$recorder" "$mode" || fail "$mode failed on a disarmed home"
    [ ! -e "$log" ] || fail "$mode alerted on a deliberately disarmed home: $(cat "$log")"
    [ ! -e "$marker" ] || fail "$mode wrote outage evidence on a deliberately disarmed home"
  done
  [ ! -e "$home/state/.supervision-sentinel-last-check" ] \
    || fail "a disarmed home still published host-service liveness"
  rm -f "$home/state/.supervision-sentinel.disarmed"
  pass "supervision sentinel: check and note-outage stay marker-only and every mode honors a durable disarm"
}

test_marker_only_evidence_refreshes_a_new_episode_but_never_a_claim() {
  local home="$TMP_ROOT/refresh" recorder="$TMP_ROOT/record-refresh" log="$TMP_ROOT/refresh.log" marker first second
  make_primary "$home"
  make_recorder "$recorder" "$log"
  printf 'project=test\n' > "$home/state/task.meta"
  touch -t 202001010000 "$home/state/.last-watcher-beat"
  marker="$home/state/.supervision-outage-alarm"

  run_mode "$home" "$recorder" note-outage || fail "first outage note failed"
  first=$(awk -F= '$1 == "episode" { print $2 }' "$marker")
  assert_contains "$(cat "$marker")" 'SUPERVISION DOWN: 1 task(s) in flight' "first note omitted its summary"

  # A changed task count with the same episode refreshes the human-facing text.
  printf 'project=test\n' > "$home/state/task-2.meta"
  run_mode "$home" "$recorder" note-outage || fail "second outage note failed"
  assert_contains "$(cat "$marker")" 'SUPERVISION DOWN: 2 task(s) in flight' "a changed in-flight count left stale evidence"

  # A changed beacon episode re-keys the frozen record instead of preserving the
  # first outage ever observed on a home with no working host check.
  touch -t 202001020000 "$home/state/.last-watcher-beat"
  run_mode "$home" "$recorder" note-outage || fail "third outage note failed"
  second=$(awk -F= '$1 == "episode" { print $2 }' "$marker")
  [ -n "$first" ] && [ "$first" != "$second" ] || fail "changed outage evidence did not re-key the durable record"
  assert_contains "$(cat "$marker")" 'delivery=pending' "a marker-only refresh must never claim delivery"

  # An in-flight scheduled claim owns the record: a concurrent guard note must
  # not steal its token, count, or lease even when the episode moved.
  NOW=$(date +%s) awk -F= '$1 == "claim" { print "claim=host-token"; next }
           $1 == "attempt_at" { printf "attempt_at=%s\n", ENVIRON["NOW"]; next }
           $1 == "delivery_count" { print "delivery_count=3"; next } { print }' "$marker" > "$marker.claimed"
  mv "$marker.claimed" "$marker"
  touch -t 202001030000 "$home/state/.last-watcher-beat"
  run_mode "$home" "$recorder" note-outage || fail "note-outage failed against an in-flight claim"
  assert_contains "$(cat "$marker")" 'claim=host-token' "a marker-only note stole an in-flight delivery claim"
  assert_contains "$(cat "$marker")" 'delivery_count=3' "a marker-only note rewound an in-flight claim's repeat schedule"
  [ ! -e "$log" ] || fail "marker-only refresh reached an external channel: $(cat "$log")"
  pass "supervision sentinel: marker-only evidence refreshes a moved episode without touching a live claim"
}

test_symlinked_home_is_not_reported_as_an_outage() {
  local real="$TMP_ROOT/symlink-real" link="$TMP_ROOT/symlink-home" rootlink="$TMP_ROOT/symlink-root"
  local recorder="$TMP_ROOT/record-symlink" log="$TMP_ROOT/symlink.log" holder
  make_primary "$real"
  make_recorder "$recorder" "$log"
  ln -s "$real" "$link"
  ln -s "$ROOT" "$rootlink"
  printf 'project=test\n' > "$real/state/task.meta"
  sleep 60 &
  holder=$!
  # bin/fm-watch.sh resolves its home and its own path with `pwd`, so it records
  # whatever symlinked spelling it was started through, while the host sentinel
  # resolves both physically with `pwd -P`. The identity check compares the same
  # physical target, so a healthy watcher is never alarmed over the spelling.
  install_stale_watcher_fixture "$real" "$holder" "$rootlink/bin/fm-watch.sh" || {
    kill "$holder" 2>/dev/null || true
    wait "$holder" 2>/dev/null || true
    fail "could not identify the symlinked-home watcher fixture"
  }
  printf '%s\n' "$link" > "$real/state/.watch.lock/fm-home"
  touch "$real/state/.last-watcher-beat"

  FM_SUPERVISION_SENTINEL_MODE=auto \
    FM_ROOT_OVERRIDE="$real" FM_HOME="$real" FM_STATE_OVERRIDE="$real/state" \
    FM_WEDGE_ALARM_CHANNEL=osascript FM_WEDGE_ALARM_EXEC="$recorder" \
    "$SENTINEL" check
  [ ! -e "$log" ] || fail "a healthy watcher reached through a symlinked home was alarmed as down: $(cat "$log")"
  [ ! -e "$real/state/.supervision-outage-alarm" ] || fail "symlinked-home spelling produced a false outage marker"

  # A genuinely different home must still fail the identity check, with the same
  # live pid, watcher path, and fresh beacon.
  mkdir -p "$TMP_ROOT/symlink-other"
  printf '%s\n' "$TMP_ROOT/symlink-other" > "$real/state/.watch.lock/fm-home"
  FM_SUPERVISION_SENTINEL_MODE=auto \
    FM_ROOT_OVERRIDE="$real" FM_HOME="$real" FM_STATE_OVERRIDE="$real/state" \
    FM_WEDGE_ALARM_CHANNEL=osascript FM_WEDGE_ALARM_EXEC="$recorder" \
    "$SENTINEL" check
  kill "$holder" 2>/dev/null || true
  wait "$holder" 2>/dev/null || true
  [ -s "$real/state/.supervision-outage-alarm" ] || fail "a foreign home in the watcher lock was accepted as this home"
  pass "supervision sentinel: watcher identity matches through symlinks but not across homes"
}

test_failed_alert_stays_pending_and_retries() {
  local home="$TMP_ROOT/retry" failing="$TMP_ROOT/record-failure" recorder="$TMP_ROOT/record-retry" log="$TMP_ROOT/retry.log"
  make_primary "$home"
  printf 'project=test\n' > "$home/state/task.meta"
  touch -t 202001010000 "$home/state/.last-watcher-beat"
  cat > "$failing" <<SH
#!/usr/bin/env bash
printf 'failed\\n' >> "$log"
exit 1
SH
  chmod +x "$failing"
  make_recorder "$recorder" "$log"

  if FM_SENTINEL_CLAIM_LEASE_SECS=1 run_check "$home" "$failing"; then
    fail "failed active-alert channel was reported as delivered"
  fi
  assert_contains "$(cat "$home/state/.supervision-outage-alarm")" 'delivery=pending' "failed notification was incorrectly marked delivered"
  sleep 1
  FM_SENTINEL_CLAIM_LEASE_SECS=1 run_check "$home" "$recorder" || fail "pending notification was not retried successfully"
  assert_contains "$(cat "$home/state/.supervision-outage-alarm")" 'delivery=sent' "successful retry did not commit delivery state"
  assert_contains "$(cat "$log")" $'osascript\tSUPERVISION DOWN:' "successful retry did not reach the recorder"
  pass "supervision sentinel: failed alert remains pending and retries on the next check"
}

make_fake_launchctl() {
  local path=$1 log=$2 loaded=$3 checked=$4
  cat > "$path" <<SH
#!/usr/bin/env bash
printf '%s' "\$1" >> "$log"
shift
for arg in "\$@"; do printf ' <%s>' "\$arg" >> "$log"; done
printf '\\n' >> "$log"
case "\$(tail -n 1 "$log")" in
  print*) [ -e "$loaded" ] ;;
  bootstrap*) : > "$loaded"; date +%s > "$checked" ;;
  bootout*) rm -f "$loaded" ;;
  kickstart*) date +%s > "$checked" ;;
  enable*) exit 0 ;;
  *) exit 2 ;;
esac
SH
  chmod +x "$path"
}

test_live_identity_matched_watcher_stays_silent() {
  local home="$TMP_ROOT/healthy" recorder="$TMP_ROOT/record-healthy" log="$TMP_ROOT/healthy-alerts.log" holder identity
  make_primary "$home"
  make_recorder "$recorder" "$log"
  printf 'project=test\n' > "$home/state/task.meta"
  sleep 60 &
  holder=$!
  identity=$(FM_STATE_OVERRIDE="$home/state" bash -c '. "$1"; fm_pid_identity "$2"' _ "$ROOT/bin/fm-wake-lib.sh" "$holder") || {
    kill "$holder" 2>/dev/null || true
    wait "$holder" 2>/dev/null || true
    fail "could not identify the healthy watcher fixture"
  }
  mkdir -p "$home/state/.watch.lock"
  printf '%s\n' "$holder" > "$home/state/.watch.lock/pid"
  printf '%s\n' "$home" > "$home/state/.watch.lock/fm-home"
  printf '%s\n' "$ROOT/bin/fm-watch.sh" > "$home/state/.watch.lock/watcher-path"
  printf '%s\n' "$identity" > "$home/state/.watch.lock/pid-identity"
  touch "$home/state/.last-watcher-beat"

  run_check "$home" "$recorder"
  kill "$holder" 2>/dev/null || true
  wait "$holder" 2>/dev/null || true
  [ ! -e "$log" ] || fail "healthy watcher emitted an active alert: $(cat "$log")"
  [ ! -e "$home/state/.supervision-outage-alarm" ] || fail "healthy watcher wrote an outage marker"
  pass "supervision sentinel: live identity-matched watcher with a fresh beacon stays silent"
}

test_arm_registers_one_home_scoped_read_only_launchd_job() {
  local home="$TMP_ROOT/arm" fake="$TMP_ROOT/fake-launchctl" log="$TMP_ROOT/launchctl.log" loaded="$TMP_ROOT/loaded" checked plist calls
  make_primary "$home"
  checked="$home/state/.supervision-sentinel-last-check"
  make_fake_launchctl "$fake" "$log" "$loaded" "$checked"

  FM_SUPERVISION_SENTINEL_MODE=auto \
    FM_SENTINEL_PLATFORM=Darwin \
    FM_SENTINEL_LAUNCHCTL="$fake" \
    FM_ROOT_OVERRIDE="$home" \
    FM_HOME="$home" \
    FM_STATE_OVERRIDE="$home/state" \
    "$SENTINEL" arm || fail "first sentinel arm did not register its fake launchd service"
  plist="$home/state/.supervision-sentinel.plist"
  [ -s "$plist" ] || fail "sentinel arm did not write its launchd plist"
  assert_contains "$(cat "$plist")" "$SENTINEL" "launchd plist did not pin the tracked sentinel path"
  assert_contains "$(cat "$plist")" '<string>scheduled-check</string>' "launchd plist does not run the host-liveness check mode"
  assert_not_contains "$(cat "$plist")" '<string>check</string>' "launchd plist used the in-harness check entry point"
  assert_contains "$(cat "$plist")" '<integer>60</integer>' "launchd plist lost the bounded one-minute check cadence"
  assert_contains "$(cat "$plist")" '/usr/local/bin:/opt/homebrew/bin:/usr/bin:/bin:/usr/sbin:/sbin' "launchd plist did not pin its minimal host PATH"
  assert_not_contains "$(cat "$plist")" '.pi/agent/bin' "launchd plist persisted a harness-controlled PATH"
  if command -v plutil >/dev/null 2>&1; then
    plutil -lint "$plist" >/dev/null || fail "generated launchd plist is invalid"
  fi
  assert_not_contains "$(cat "$plist")" 'fm-watch-arm.sh' "host fallback must not auto-start a watcher"
  assert_not_contains "$(cat "$plist")" 'fm-supervise-daemon.sh' "host fallback must not auto-start an away-mode daemon"
  assert_not_contains "$(cat "$plist")" '--restart' "host fallback must not restart any supervision process"

  FM_SUPERVISION_SENTINEL_MODE=auto \
    FM_SENTINEL_PLATFORM=Darwin \
    FM_SENTINEL_LAUNCHCTL="$fake" \
    FM_ROOT_OVERRIDE="$home" \
    FM_HOME="$home" \
    FM_STATE_OVERRIDE="$home/state" \
    "$SENTINEL" arm || fail "second sentinel arm was not idempotent"
  calls=$(grep -c '^bootstrap ' "$log" || true)
  [ "$calls" -eq 1 ] || fail "idempotent arm bootstrapped $calls services instead of one: $(cat "$log")"

  touch -t 202001010000 "$checked"
  FM_SUPERVISION_SENTINEL_MODE=auto \
    FM_SENTINEL_PLATFORM=Darwin \
    FM_SENTINEL_LAUNCHCTL="$fake" \
    FM_ROOT_OVERRIDE="$home" \
    FM_HOME="$home" \
    FM_STATE_OVERRIDE="$home/state" \
    "$SENTINEL" arm || fail "loaded sentinel with a stale check heartbeat was not verified"
  [ "$(grep -c '^kickstart ' "$log" || true)" -eq 1 ] || fail "stale host checker was not kickstarted by exact service id: $(cat "$log")"

  FM_SUPERVISION_SENTINEL_MODE=auto \
    FM_SENTINEL_PLATFORM=Darwin \
    FM_SENTINEL_LAUNCHCTL="$fake" \
    FM_SENTINEL_INTERVAL_SECS=90 \
    FM_ROOT_OVERRIDE="$home" \
    FM_HOME="$home" \
    FM_STATE_OVERRIDE="$home/state" \
    "$SENTINEL" arm || fail "changed sentinel manifest was not reloaded"
  [ "$(grep -c '^bootout ' "$log" || true)" -eq 1 ] || fail "manifest change did not retire the exact old service once: $(cat "$log")"
  [ "$(grep -c '^bootstrap ' "$log" || true)" -eq 2 ] || fail "manifest change did not bootstrap one replacement service: $(cat "$log")"
  assert_contains "$(cat "$plist")" '<integer>90</integer>' "reloaded manifest did not retain the changed interval"
  pass "supervision sentinel: launchd registration is one-per-home, reconciles its manifest, and never auto-recovers"
}

run_arm() { # <home> <launchctl> [extra env assignments...]
  local home=$1 fake=$2
  shift 2
  env "$@" \
    FM_SUPERVISION_SENTINEL_MODE=auto \
    FM_SENTINEL_PLATFORM=Darwin \
    FM_SENTINEL_LAUNCHCTL="$fake" \
    FM_ROOT_OVERRIDE="$home" \
    FM_HOME="$home" \
    FM_STATE_OVERRIDE="$home/state" \
    "$SENTINEL" arm
}

test_unconverged_arm_backs_off_instead_of_churning_launchd() {
  local home="$TMP_ROOT/churn" fake="$TMP_ROOT/churn-launchctl" log="$TMP_ROOT/churn-launchctl.log"
  local loaded="$TMP_ROOT/churn-loaded" healthy="$TMP_ROOT/churn-healthy" checked failure err boots
  make_primary "$home"
  checked="$home/state/.supervision-sentinel-last-check"
  failure="$home/state/.supervision-sentinel.arm-failure"
  err="$TMP_ROOT/churn.err"
  # launchd retains the service, but until the healthy flag exists no scheduled
  # check ever lands. That is exactly what a job which cannot resolve its own home
  # under the pinned minimal PATH looks like from the arm side.
  cat > "$fake" <<SH
#!/usr/bin/env bash
printf '%s' "\$1" >> "$log"
shift
for arg in "\$@"; do printf ' <%s>' "\$arg" >> "$log"; done
printf '\\n' >> "$log"
case "\$(tail -n 1 "$log")" in
  print*) [ -e "$loaded" ] || exit 1 ;;
  bootstrap*) : > "$loaded"; [ -e "$healthy" ] && date +%s > "$checked" ;;
  bootout*) rm -f "$loaded" ;;
  kickstart*) [ -e "$healthy" ] && date +%s > "$checked" ;;
esac
exit 0
SH
  chmod +x "$fake"

  if run_arm "$home" "$fake" FM_SENTINEL_CHECK_WAIT_SECS=1 2>"$err"; then
    fail "arm reported success without a single completed scheduled check"
  fi
  assert_contains "$(cat "$err")" 'no check completed' "failed registration did not say why it failed"
  [ -s "$failure" ] || fail "a failed registration left no durable per-home failure record"
  assert_contains "$(cat "$failure")" 'failures=1' "first registration failure was not counted"
  boots=$(grep -c '^bootstrap ' "$log" || true)
  [ "$boots" -eq 1 ] || fail "first arm bootstrapped $boots services instead of one: $(cat "$log")"

  if run_arm "$home" "$fake" FM_SENTINEL_CHECK_WAIT_SECS=1 2>"$err"; then
    fail "arm inside its failure cooldown must not claim host monitoring is healthy"
  fi
  assert_contains "$(cat "$err")" 'host outage monitoring is NOT active' "cooldown warning implied monitoring was live"
  assert_contains "$(cat "$err")" 'fm-supervision-sentinel.sh enable' "cooldown warning omitted the deliberate recovery action"
  [ "$(grep -c '^bootstrap ' "$log" || true)" -eq 1 ] || fail "cooldown still re-bootstrapped the service: $(cat "$log")"
  [ "$(grep -c '^bootout ' "$log" || true)" -eq 0 ] || fail "cooldown still booted out the service: $(cat "$log")"
  [ "$(grep -c '^kickstart ' "$log" || true)" -eq 0 ] || fail "cooldown still kickstarted the service: $(cat "$log")"
  assert_contains "$(cat "$failure")" 'failures=1' "a cooldown skip must not count as another failure"

  # The explicit enable is the documented recovery action, so it always gets one
  # real attempt rather than inheriting the cooldown of the failure it repairs.
  : > "$healthy"
  FM_SUPERVISION_SENTINEL_MODE=auto FM_SENTINEL_PLATFORM=Darwin FM_SENTINEL_LAUNCHCTL="$fake" \
    FM_SENTINEL_CHECK_WAIT_SECS=1 \
    FM_ROOT_OVERRIDE="$home" FM_HOME="$home" FM_STATE_OVERRIDE="$home/state" \
    "$SENTINEL" enable >/dev/null 2>"$err" || fail "explicit enable did not override the failure cooldown: $(cat "$err")"
  [ ! -e "$failure" ] || fail "a verified registration left its failure record behind"
  [ -s "$checked" ] || fail "verified registration did not record a completed scheduled check"

  boots=$(grep -c '^bootstrap ' "$log" || true)
  run_arm "$home" "$fake" FM_SENTINEL_CHECK_WAIT_SECS=1 2>"$err" \
    || fail "converged arm did not report success: $(cat "$err")"
  [ "$(grep -c '^bootstrap ' "$log" || true)" -eq "$boots" ] \
    || fail "a converged arm re-registered the service: $(cat "$log")"
  [ ! -e "$failure" ] || fail "a converged arm recorded a failure"
  pass "supervision sentinel: an unconverged launchd registration backs off per home instead of churning"
}

test_explicit_disarm_is_durable_home_scoped_and_reversible() {
  local home="$TMP_ROOT/disarm" fake="$TMP_ROOT/disarm-launchctl" log="$TMP_ROOT/disarm-launchctl.log" loaded="$TMP_ROOT/disarm-loaded" checked before after out
  make_primary "$home"
  home=$(cd "$home" && pwd -P)
  checked="$home/state/.supervision-sentinel-last-check"
  make_fake_launchctl "$fake" "$log" "$loaded" "$checked"

  FM_SUPERVISION_SENTINEL_MODE=auto FM_SENTINEL_PLATFORM=Darwin FM_SENTINEL_LAUNCHCTL="$fake" \
    FM_ROOT_OVERRIDE="$home" FM_HOME="$home" FM_STATE_OVERRIDE="$home/state" \
    "$SENTINEL" arm || fail "disarm fixture could not register its home service"
  out=$(FM_SENTINEL_PLATFORM=Darwin FM_SENTINEL_LAUNCHCTL="$fake" \
    FM_ROOT_OVERRIDE="$home" FM_HOME="$home" FM_STATE_OVERRIDE="$home/state" \
    "$SENTINEL" disarm) || fail "explicit disarm failed"
  assert_contains "$out" 'disarmed for this home' "disarm did not report its durable result"
  [ ! -e "$loaded" ] || fail "disarm left the exact home service loaded"
  [ -s "$home/state/.supervision-sentinel.disarmed" ] || fail "disarm did not leave a durable visible record"
  assert_contains "$(cat "$home/state/.supervision-sentinel.disarmed")" "home=$home" "disarm record lost its canonical home identity"
  [ ! -e "$home/state/.supervision-sentinel.plist" ] || fail "disarm left its generated manifest installed"

  before=$(grep -c '^bootstrap ' "$log" || true)
  FM_SUPERVISION_SENTINEL_MODE=auto FM_SENTINEL_PLATFORM=Darwin FM_SENTINEL_LAUNCHCTL="$fake" \
    FM_ROOT_OVERRIDE="$home" FM_HOME="$home" FM_STATE_OVERRIDE="$home/state" \
    "$SENTINEL" arm >/dev/null 2>&1 || fail "automatic arm should honor an explicit disarm without failing watcher entry"
  after=$(grep -c '^bootstrap ' "$log" || true)
  [ "$after" -eq "$before" ] || fail "ordinary arm silently overrode the durable disarm"
  [ -s "$home/state/.supervision-sentinel.disarmed" ] || fail "ordinary arm cleared the durable disarm record"

  FM_SUPERVISION_SENTINEL_MODE=off FM_SENTINEL_PLATFORM=Darwin FM_SENTINEL_LAUNCHCTL="$fake" \
    FM_ROOT_OVERRIDE="$home" FM_HOME="$home" FM_STATE_OVERRIDE="$home/state" \
    "$SENTINEL" enable >/dev/null || fail "explicit enable did not restore the home service"
  [ -e "$loaded" ] || fail "explicit enable did not load the exact home service"
  [ ! -e "$home/state/.supervision-sentinel.disarmed" ] || fail "explicit enable left the disarm record after verified registration"

  assert_not_contains "$(cat "$ROOT/bin/fm-teardown.sh" "$ROOT/bin/fm-session-start.sh" "$ROOT/bin/fm-watch-arm.sh")" \
    'fm-supervision-sentinel.sh disarm' "ordinary lifecycle code invokes the explicit-only disarm path"
  pass "supervision sentinel: explicit disarm is durable, home-scoped, visible, and explicitly reversible"
}

test_watch_arm_validates_arguments_before_sentinel_registration() {
  local case_line arm_line
  case_line=$(grep -nF "case \"\${1:-}\" in" "$ROOT/bin/fm-watch-arm.sh" | tail -1 | cut -d: -f1)
  arm_line=$(grep -nF "\"\$SENTINEL\" arm" "$ROOT/bin/fm-watch-arm.sh" | head -1 | cut -d: -f1)
  [ -n "$case_line" ] && [ -n "$arm_line" ] && [ "$case_line" -lt "$arm_line" ] \
    || fail "watcher arm still registers the host service before rejecting bad argv"
  pass "supervision sentinel: watcher arm validates argv before host registration"
}

test_real_channel_uses_unambiguous_notification_title_without_posting() {
  local home="$TMP_ROOT/title" fakebin log i
  make_primary "$home"
  printf 'project=test\n' > "$home/state/task.meta"
  touch -t 202001010000 "$home/state/.last-watcher-beat"
  fakebin=$(fm_fakebin "$TMP_ROOT/title-tools")
  log="$TMP_ROOT/osascript-argv.log"
  cat > "$fakebin/osascript" <<SH
#!/usr/bin/env bash
printf '<%s>\\n' "\$@" >> "$log"
SH
  chmod +x "$fakebin/osascript"

  PATH="$fakebin:$PATH" \
    FM_SUPERVISION_SENTINEL_MODE=auto \
    FM_ROOT_OVERRIDE="$home" \
    FM_HOME="$home" \
    FM_STATE_OVERRIDE="$home/state" \
    FM_WEDGE_ALARM_CHANNEL=osascript \
    FM_WEDGE_ALARM_TIMEOUT_SECS=2 \
    env -u FM_WEDGE_ALARM_EXEC "$SENTINEL" scheduled-check
  [ -s "$log" ] || fail "fake osascript did not receive the active alert"
  assert_contains "$(cat "$log")" 'firstmate: SUPERVISION DOWN' "Notification Center title did not identify the supervision outage"
  assert_contains "$(cat "$log")" 'SUPERVISION DOWN: 1 task(s) in flight' "Notification Center body omitted the outage summary"
  pass "supervision sentinel: OS alert title and body are unambiguous (fake notifier only)"
}

# Opt-in end-to-end proof over the REAL launchd transport, which every other case
# in this file fakes. It is deliberately not part of the default suite: it mutates
# the caller's own `gui/<uid>` launchd domain, so it must be an explicit, attended
# choice on a macOS login session rather than something CI or a parallel shard
# does implicitly. It still never posts a real desktop notification - the
# launchd-spawned check resolves the scratch home's own config/wedge-alarm, whose
# only channel writes a file.
test_real_launchd_scheduled_check_delivers_end_to_end() {
  local home alert_log label domain service plist uid i
  if [ "${FM_SENTINEL_REAL_LAUNCHD_SMOKE:-0}" != 1 ]; then
    pass "supervision sentinel: real-launchd smoke skipped (FM_SENTINEL_REAL_LAUNCHD_SMOKE=1 on an attended macOS login session runs it)"
    return 0
  fi
  [ "$(uname)" = Darwin ] || fail "the real-launchd smoke was requested on $(uname); it is macOS-only"
  [ -x /bin/launchctl ] || fail "the real-launchd smoke was requested without /bin/launchctl"

  home="$TMP_ROOT/real-launchd"
  make_primary "$home"
  home=$(cd "$home" && pwd -P)
  alert_log="$home/real-launchd-alert.log"
  cat > "$home/config/wedge-alarm" <<EOF
command:printf '%s\n' "\$1" >> $alert_log
EOF
  printf 'project=test\n' > "$home/state/task.meta"
  touch -t 202001010000 "$home/state/.last-watcher-beat"

  # Derive the exact service identity before registering anything, so teardown can
  # target this one label even if arm fails partway through.
  uid=$(id -u)
  domain="gui/$uid"
  label="works.earendil.firstmate.supervision-sentinel-v1.$(printf '%s\t%s' "$home" "$home/state" | /usr/bin/shasum -a 256 | /usr/bin/awk '{print $1}')"
  service="$domain/$label"
  FM_SENTINEL_SMOKE_SERVICE="$service"

  FM_SUPERVISION_SENTINEL_MODE=auto FM_ROOT_OVERRIDE="$home" FM_HOME="$home" \
    FM_SENTINEL_CHECK_WAIT_SECS=30 \
    "$SENTINEL" arm || fail "real launchd did not retain and verify this home service"
  plist="$home/state/.supervision-sentinel.plist"
  assert_grep "<string>$label</string>" "$plist" "generated manifest label does not match the derived service identity"
  /bin/launchctl print "$service" >/dev/null 2>&1 || fail "real launchd is not holding the exact home service"
  [ -s "$home/state/.supervision-sentinel-last-check" ] \
    || fail "a launchd-spawned scheduled-check never recorded host liveness"

  i=0
  while [ "$i" -lt 300 ] && [ ! -s "$alert_log" ]; do
    sleep 0.2
    i=$((i + 1))
  done
  [ -s "$alert_log" ] || fail "the launchd-spawned check never reached its configured active channel"
  assert_grep 'SUPERVISION DOWN: 1 task(s) in flight' "$alert_log" "launchd-delivered alert omitted the outage summary"
  assert_grep 'delivery=sent' "$home/state/.supervision-outage-alarm" "launchd-delivered alert did not commit its delivery state"

  fm_sentinel_bootout_smoke_service "$service" || fail "exact home service could not be retired after the smoke"
  FM_SENTINEL_SMOKE_SERVICE=
  pass "supervision sentinel: real launchd bootstrap -> scheduled-check -> configured channel delivers end to end"
}

test_stale_beacon_alert_is_loud_deduplicated_backed_off_and_rearmed
test_guard_note_outage_records_evidence_without_notifying
test_in_harness_modes_are_marker_only_and_honor_a_durable_disarm
test_marker_only_evidence_refreshes_a_new_episode_but_never_a_claim
test_symlinked_home_is_not_reported_as_an_outage
test_live_identity_matched_watcher_stays_silent
test_failed_alert_stays_pending_and_retries
test_arm_registers_one_home_scoped_read_only_launchd_job
test_unconverged_arm_backs_off_instead_of_churning_launchd
test_explicit_disarm_is_durable_home_scoped_and_reversible
test_watch_arm_validates_arguments_before_sentinel_registration
test_real_channel_uses_unambiguous_notification_title_without_posting
test_real_launchd_scheduled_check_delivers_end_to_end
