#!/usr/bin/env bash
# Behavior tests for the launchd-backed supervision-outage sentinel.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

SENTINEL="$ROOT/bin/fm-supervision-sentinel.sh"
TMP_ROOT=$(fm_test_tmproot fm-supervision-sentinel)

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

test_stale_beacon_alert_is_loud_deduplicated_backed_off_and_rearmed
test_guard_note_outage_records_evidence_without_notifying
test_symlinked_home_is_not_reported_as_an_outage
test_live_identity_matched_watcher_stays_silent
test_failed_alert_stays_pending_and_retries
test_arm_registers_one_home_scoped_read_only_launchd_job
test_explicit_disarm_is_durable_home_scoped_and_reversible
test_watch_arm_validates_arguments_before_sentinel_registration
test_real_channel_uses_unambiguous_notification_title_without_posting
