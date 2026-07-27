#!/usr/bin/env bash
# Host-owned supervision-outage sentinel for one firstmate home.
#
# The watcher and away-mode daemon can both be reaped with their harness-hosted
# background task, so neither process can be the final detector of its own
# death. On macOS, `arm` registers this script as a home-scoped launchd agent.
# launchd invokes `scheduled-check` every FM_SENTINEL_INTERVAL_SECS (default 60), outside
# the harness process tree. A check uses the same in-flight count, watcher-lock
# identity, and beacon freshness predicates as the turn-end and continuity
# guards. It writes one durable outage marker and reuses config/wedge-alarm's
# active channels for a loud notification.
#
# This sentinel deliberately NEVER starts, stops, or signals a watcher or the
# away-mode daemon. A generic host process cannot safely recreate a harness
# completion notification or the daemon's supervisor-pane target. Automatic
# restart here could also race the existing singleton and away-mode ownership.
# The existing guarded recovery path remains human/agent-owned.
#
# Usage:
#   fm-supervision-sentinel.sh arm         Idempotently register unless deliberately disarmed.
#   fm-supervision-sentinel.sh enable      Explicitly re-enable and register this home's agent.
#   fm-supervision-sentinel.sh disarm      Explicitly uninstall and durably mark this home disarmed.
#   fm-supervision-sentinel.sh check       Run one in-process health check and alert.
#   fm-supervision-sentinel.sh note-outage Record an outage marker only; never notify.
#
# `scheduled-check` is the launchd-only entry point. It alone records host-service
# liveness and crosses the external-alert boundary; in-harness guard modes only
# leave a durable pending record and return their own loud banner immediately.
#
# `note-outage` is the only mode an in-harness turn-end or continuity hook may
# use. Those hooks must render their blocking banner immediately, so they record
# durable evidence with local writes alone and never cross the active-channel
# boundary. External alert delivery belongs to the scheduled host check.
#
# Environment:
#   FM_HOME                            Operational home (default: tracked root).
#   FM_ROOT_OVERRIDE                   Tracked code root override.
#   FM_STATE_OVERRIDE                  State directory override.
#   FM_CONFIG_OVERRIDE                 Alert configuration directory override.
#   FM_GUARD_GRACE                     Watcher-beacon grace seconds (default 300).
#   FM_SUPERVISION_SENTINEL_MODE=off   Disable automatic registration and checks.
#   FM_SENTINEL_INTERVAL_SECS          launchd check interval (default 60, minimum 15).
#   FM_SENTINEL_REALARM_SECS           first repeat delay (default 300, minimum 60).
#   FM_SENTINEL_MAX_REALARM_SECS       exponential-repeat cap (default 3600, minimum 300).
#   FM_SENTINEL_CLAIM_LEASE_SECS       failed/in-progress delivery retry lease (default 30).
#   FM_SENTINEL_PLATFORM               uname override for tests.
#   FM_SENTINEL_LAUNCHCTL              launchctl path override for tests.
#   FM_SENTINEL_DOMAIN                 launchd domain override for tests.
# End usage.
set -u

FM_SENTINEL_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$FM_SENTINEL_DIR/.." && pwd -P)}"
FM_SENTINEL_ROOT_CANON=$(cd "$FM_ROOT" 2>/dev/null && pwd -P) || exit 1
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_ROOT}}"
FM_SENTINEL_HOME_CANON=$(cd "$FM_HOME" 2>/dev/null && pwd -P) || exit 1
FM_SENTINEL_STATE="${FM_STATE_OVERRIDE:-$FM_HOME/state}"
FM_SENTINEL_WATCH="$FM_SENTINEL_DIR/fm-watch.sh"
FM_SENTINEL_ALERT_OWNER="$FM_SENTINEL_DIR/fm-supervise-daemon.sh"
FM_SENTINEL_GRACE=${FM_GUARD_GRACE:-300}
FM_SENTINEL_INTERVAL=${FM_SENTINEL_INTERVAL_SECS:-60}
FM_SENTINEL_REALARM=${FM_SENTINEL_REALARM_SECS:-300}
FM_SENTINEL_MAX_REALARM=${FM_SENTINEL_MAX_REALARM_SECS:-3600}
FM_SENTINEL_CLAIM_LEASE=${FM_SENTINEL_CLAIM_LEASE_SECS:-30}
FM_SENTINEL_JOB_PATH=/usr/local/bin:/opt/homebrew/bin:/usr/bin:/bin:/usr/sbin:/sbin

# shellcheck source=bin/fm-supervision-lib.sh
. "$FM_SENTINEL_DIR/fm-supervision-lib.sh"
# shellcheck source=bin/fm-primary-scope-lib.sh
. "$FM_SENTINEL_DIR/fm-primary-scope-lib.sh"
# shellcheck source=bin/fm-wake-lib.sh
. "$FM_SENTINEL_DIR/fm-wake-lib.sh"

FM_SENTINEL_STATE=$(cd "$FM_SENTINEL_STATE" 2>/dev/null && pwd -P) || exit 1
FM_SENTINEL_MARKER="$FM_SENTINEL_STATE/.supervision-outage-alarm"
FM_SENTINEL_ARM_LOCK="$FM_SENTINEL_STATE/.supervision-sentinel-arm.lock"
FM_SENTINEL_CHECK_LOCK="$FM_SENTINEL_STATE/.supervision-sentinel-check.lock"
FM_SENTINEL_PLIST="$FM_SENTINEL_STATE/.supervision-sentinel.plist"
FM_SENTINEL_LOADED_DIGEST="$FM_SENTINEL_STATE/.supervision-sentinel.loaded-digest"
FM_SENTINEL_LAST_CHECK="$FM_SENTINEL_STATE/.supervision-sentinel-last-check"
FM_SENTINEL_DISARMED="$FM_SENTINEL_STATE/.supervision-sentinel.disarmed"
FM_SENTINEL_CLAIM_TOKEN=
FM_SENTINEL_FORCE_ARM=0

fm_sentinel_usage() {
  awk '
    /^# Usage:/ { printing = 1 }
    /^# End usage\./ { exit }
    printing { sub(/^# ?/, ""); print }
  ' "$0"
}

fm_sentinel_mode_enabled() {
  case "${FM_SUPERVISION_SENTINEL_MODE:-auto}" in
    off|false|0|disabled) return 1 ;;
    *) return 0 ;;
  esac
}

fm_sentinel_positive_integer() { # <value> <fallback> [minimum]
  local value=$1 fallback=$2 minimum=${3:-1}
  case "$value" in
    ''|*[!0-9]*) printf '%s\n' "$fallback" ;;
    *)
      if [ "$value" -lt "$minimum" ]; then
        printf '%s\n' "$fallback"
      else
        printf '%s\n' "$value"
      fi
      ;;
  esac
}

fm_sentinel_normalize_tunables() {
  FM_SENTINEL_GRACE=$(fm_sentinel_positive_integer "$FM_SENTINEL_GRACE" 300 1)
  FM_SENTINEL_REALARM=$(fm_sentinel_positive_integer "$FM_SENTINEL_REALARM" 300 60)
  FM_SENTINEL_MAX_REALARM=$(fm_sentinel_positive_integer "$FM_SENTINEL_MAX_REALARM" 3600 300)
  [ "$FM_SENTINEL_MAX_REALARM" -ge "$FM_SENTINEL_REALARM" ] || FM_SENTINEL_MAX_REALARM=$FM_SENTINEL_REALARM
  FM_SENTINEL_CLAIM_LEASE=$(fm_sentinel_positive_integer "$FM_SENTINEL_CLAIM_LEASE" 30 1)
}

fm_sentinel_xml_escape() {
  printf '%s' "$1" | sed -e 's/&/\&amp;/g' -e 's/</\&lt;/g' -e 's/>/\&gt;/g' -e 's/"/\&quot;/g' -e "s/'/\&apos;/g"
}

fm_sentinel_label() {
  local hash
  [ -x /usr/bin/shasum ] || return 1
  hash=$(printf '%s\t%s' "$FM_SENTINEL_HOME_CANON" "$FM_SENTINEL_STATE" | /usr/bin/shasum -a 256 | /usr/bin/awk '{print $1}') || return 1
  [ -n "$hash" ] || return 1
  printf 'works.earendil.firstmate.supervision-sentinel-v1.%s\n' "$hash"
}

fm_sentinel_plist_digest() {
  [ -x /usr/bin/shasum ] || return 1
  /usr/bin/shasum -a 256 "$FM_SENTINEL_PLIST" | /usr/bin/awk '{print $1}'
}

fm_sentinel_check_recent() { # <max-age-seconds>
  [ "$(fm_path_age "$FM_SENTINEL_LAST_CHECK")" -le "$1" ]
}

fm_sentinel_wait_for_check() {
  local i=0
  while [ "$i" -lt 300 ]; do
    fm_sentinel_check_recent 10 && return 0
    sleep 0.05
    i=$((i + 1))
  done
  return 1
}

fm_sentinel_domain() {
  printf '%s\n' "${FM_SENTINEL_DOMAIN:-gui/$(id -u)}"
}

fm_sentinel_launchctl() {
  printf '%s\n' "${FM_SENTINEL_LAUNCHCTL:-/bin/launchctl}"
}

fm_sentinel_plist_env() { # <key> <value>
  printf '      <key>%s</key>\n      <string>%s</string>\n' \
    "$(fm_sentinel_xml_escape "$1")" "$(fm_sentinel_xml_escape "$2")"
}

fm_sentinel_write_plist() { # <label> <interval>
  local label=$1 interval=$2 pending
  pending=$(mktemp "$FM_SENTINEL_STATE/.supervision-sentinel.plist.XXXXXX") || return 1
  {
    printf '%s\n' '<?xml version="1.0" encoding="UTF-8"?>'
    printf '%s\n' '<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">'
    printf '%s\n' '<plist version="1.0">' '<dict>'
    printf '  <key>Label</key>\n  <string>%s</string>\n' "$(fm_sentinel_xml_escape "$label")"
    printf '%s\n' '  <key>ProgramArguments</key>' '  <array>'
    printf '    <string>%s</string>\n' "$(fm_sentinel_xml_escape "$FM_SENTINEL_DIR/fm-supervision-sentinel.sh")"
    printf '%s\n' '    <string>scheduled-check</string>' '  </array>'
    printf '%s\n' '  <key>EnvironmentVariables</key>' '  <dict>'
    fm_sentinel_plist_env FM_HOME "$FM_SENTINEL_HOME_CANON"
    fm_sentinel_plist_env FM_ROOT_OVERRIDE "$FM_SENTINEL_ROOT_CANON"
    fm_sentinel_plist_env FM_GUARD_GRACE "$FM_SENTINEL_GRACE"
    fm_sentinel_plist_env FM_SENTINEL_INTERVAL_SECS "$interval"
    fm_sentinel_plist_env FM_SENTINEL_REALARM_SECS "$FM_SENTINEL_REALARM"
    fm_sentinel_plist_env FM_SENTINEL_MAX_REALARM_SECS "$FM_SENTINEL_MAX_REALARM"
    fm_sentinel_plist_env FM_SENTINEL_CLAIM_LEASE_SECS "$FM_SENTINEL_CLAIM_LEASE"
    fm_sentinel_plist_env PATH "$FM_SENTINEL_JOB_PATH"
    if [ -n "${FM_STATE_OVERRIDE:-}" ]; then
      fm_sentinel_plist_env FM_STATE_OVERRIDE "$FM_SENTINEL_STATE"
    fi
    if [ -n "${FM_CONFIG_OVERRIDE:-}" ]; then
      fm_sentinel_plist_env FM_CONFIG_OVERRIDE "$FM_CONFIG_OVERRIDE"
    fi
    printf '%s\n' '  </dict>'
    printf '%s\n' '  <key>RunAtLoad</key>' '  <true/>'
    printf '  <key>StartInterval</key>\n  <integer>%s</integer>\n' "$interval"
    printf '%s\n' '  <key>ProcessType</key>' '  <string>Background</string>'
    printf '%s\n' '</dict>' '</plist>'
  } > "$pending" || { rm -f "$pending"; return 1; }
  chmod 600 "$pending" || { rm -f "$pending"; return 1; }
  mv -f "$pending" "$FM_SENTINEL_PLIST"
}

# Registration body. Runs only while this home's arm lock is held, so it may
# return early anywhere: fm_sentinel_arm owns the single matching release.
fm_sentinel_arm_registration() { # <launchctl> <domain> <label> <service> <interval>
  local launchctl=$1 domain=$2 label=$3 service=$4 interval=$5 digest loaded_digest i pending rc=0
  if ! fm_sentinel_write_plist "$label" "$interval"; then
    printf 'supervision sentinel: could not write %s\n' "$FM_SENTINEL_PLIST" >&2
    return 1
  fi
  digest=$(fm_sentinel_plist_digest) || return 1
  loaded_digest=$(cat "$FM_SENTINEL_LOADED_DIGEST" 2>/dev/null || true)
  if "$launchctl" print "$service" >/dev/null 2>&1; then
    "$launchctl" enable "$service" >/dev/null 2>&1 || true
    if [ "$loaded_digest" = "$digest" ]; then
      fm_sentinel_check_recent $((interval * 2 + 15)) && return 0
      "$launchctl" kickstart "$service" >/dev/null 2>&1 || true
      fm_sentinel_wait_for_check && return 0
      printf 'supervision sentinel: loaded home service did not complete a check\n' >&2
      return 1
    fi
    # The tracked script path or launch settings changed. Reload only this exact
    # home service; never sweep launchd labels or supervision processes.
    "$launchctl" bootout "$service" >/dev/null 2>&1 || true
    i=0
    while [ "$i" -lt 40 ] && "$launchctl" print "$service" >/dev/null 2>&1; do
      sleep 0.05
      i=$((i + 1))
    done
    if "$launchctl" print "$service" >/dev/null 2>&1; then
      printf 'supervision sentinel: prior home service did not retire for a manifest reload\n' >&2
      return 1
    fi
  fi
  rm -f "$FM_SENTINEL_LAST_CHECK" 2>/dev/null || true
  "$launchctl" bootstrap "$domain" "$FM_SENTINEL_PLIST" >/dev/null 2>&1 || rc=$?
  if [ "$rc" -ne 0 ] && ! "$launchctl" print "$service" >/dev/null 2>&1; then
    printf 'supervision sentinel: launchd registration failed for this home (exit %s)\n' "$rc" >&2
    return 1
  fi
  "$launchctl" enable "$service" >/dev/null 2>&1 || true
  if ! "$launchctl" print "$service" >/dev/null 2>&1; then
    printf 'supervision sentinel: launchd did not retain this home service\n' >&2
    return 1
  fi
  if ! fm_sentinel_wait_for_check; then
    printf 'supervision sentinel: launchd retained the home service but no check completed\n' >&2
    return 1
  fi
  pending="$FM_SENTINEL_LOADED_DIGEST.pending.$$"
  if ! printf '%s\n' "$digest" > "$pending" || ! mv -f "$pending" "$FM_SENTINEL_LOADED_DIGEST"; then
    rm -f "$pending"
    printf 'supervision sentinel: could not record the loaded manifest identity\n' >&2
    return 1
  fi
  return 0
}

fm_sentinel_arm() {
  local platform launchctl label domain service interval i rc
  fm_sentinel_mode_enabled || return 0
  platform=${FM_SENTINEL_PLATFORM:-$(uname)}
  if [ "$platform" != Darwin ]; then
    printf 'supervision sentinel: no verified host scheduler for %s; watcher outage fallback is unavailable\n' "$platform" >&2
    return 1
  fi
  fm_primary_scope_matches "$FM_ROOT" "$FM_SENTINEL_STATE" || return 0
  if [ -f "$FM_SENTINEL_DISARMED" ] && [ "$FM_SENTINEL_FORCE_ARM" -ne 1 ]; then
    printf 'supervision sentinel: deliberately disarmed for this home; run %s enable to restore host monitoring\n' "$0" >&2
    return 0
  fi
  fm_sentinel_normalize_tunables
  interval=$(fm_sentinel_positive_integer "$FM_SENTINEL_INTERVAL" 60 15)
  launchctl=$(fm_sentinel_launchctl)
  [ -x "$launchctl" ] || { printf 'supervision sentinel: launchctl is unavailable\n' >&2; return 1; }
  label=$(fm_sentinel_label) || { printf 'supervision sentinel: SHA-256 service identity is unavailable\n' >&2; return 1; }
  domain=$(fm_sentinel_domain)
  service="$domain/$label"

  if ! fm_lock_try_acquire "$FM_SENTINEL_ARM_LOCK"; then
    # Another home-scoped arm is already converging on the same launchd label.
    # Wait briefly for its publication instead of reporting a false failure.
    i=0
    while [ "$i" -lt 40 ]; do
      if "$launchctl" print "$service" >/dev/null 2>&1 && fm_sentinel_check_recent $((interval * 2 + 15)); then
        return 0
      fi
      sleep 0.05
      i=$((i + 1))
    done
    return 1
  fi
  fm_sentinel_arm_registration "$launchctl" "$domain" "$label" "$service" "$interval"
  rc=$?
  fm_lock_release "$FM_SENTINEL_ARM_LOCK" 2>/dev/null || true
  return "$rc"
}

fm_sentinel_write_disarmed() { # <service>
  local service=$1 pending
  pending=$(mktemp "$FM_SENTINEL_STATE/.supervision-sentinel.disarmed.XXXXXX") || return 1
  {
    printf 'state=disarmed\n'
    printf 'disarmed_at=%s\n' "$(date +%s)"
    printf 'home=%s\n' "$FM_SENTINEL_HOME_CANON"
    printf 'service=%s\n' "$service"
    printf 'reenable=%s enable\n' "$FM_SENTINEL_DIR/fm-supervision-sentinel.sh"
  } > "$pending" || { rm -f "$pending"; return 1; }
  chmod 600 "$pending" || { rm -f "$pending"; return 1; }
  mv -f "$pending" "$FM_SENTINEL_DISARMED"
}

# Uninstall body. Runs only while this home's arm lock is held, so it may return
# early anywhere: fm_sentinel_disarm owns the single matching release.
fm_sentinel_disarm_service() { # <launchctl> <service>
  local launchctl=$1 service=$2 i
  if "$launchctl" print "$service" >/dev/null 2>&1; then
    if ! "$launchctl" bootout "$service" >/dev/null 2>&1; then
      printf 'supervision sentinel: exact home service could not be uninstalled\n' >&2
      return 1
    fi
    i=0
    while [ "$i" -lt 100 ] && "$launchctl" print "$service" >/dev/null 2>&1; do
      sleep 0.05
      i=$((i + 1))
    done
    if "$launchctl" print "$service" >/dev/null 2>&1; then
      printf 'supervision sentinel: exact home service remained loaded after disarm\n' >&2
      return 1
    fi
  fi
  # The durable record must land before the generated artifacts are removed, so
  # a partial disarm can never look like an ordinary unregistered home.
  if ! fm_sentinel_write_disarmed "$service"; then
    printf 'supervision sentinel: service is absent but the durable disarm record could not be written\n' >&2
    return 1
  fi
  rm -f "$FM_SENTINEL_PLIST" "$FM_SENTINEL_LOADED_DIGEST" "$FM_SENTINEL_LAST_CHECK" "$FM_SENTINEL_MARKER" 2>/dev/null || true
  return 0
}

fm_sentinel_disarm() {
  local platform launchctl label domain service rc
  fm_primary_scope_matches "$FM_ROOT" "$FM_SENTINEL_STATE" || {
    printf 'supervision sentinel: disarm is valid only in this home primary scope\n' >&2
    return 1
  }
  platform=${FM_SENTINEL_PLATFORM:-$(uname)}
  if [ "$platform" != Darwin ]; then
    printf 'supervision sentinel: no verified host service to disarm on %s\n' "$platform" >&2
    return 1
  fi
  launchctl=$(fm_sentinel_launchctl)
  [ -x "$launchctl" ] || { printf 'supervision sentinel: launchctl is unavailable\n' >&2; return 1; }
  label=$(fm_sentinel_label) || { printf 'supervision sentinel: SHA-256 service identity is unavailable\n' >&2; return 1; }
  domain=$(fm_sentinel_domain)
  service="$domain/$label"
  if ! fm_lock_try_acquire "$FM_SENTINEL_ARM_LOCK"; then
    printf 'supervision sentinel: this home is already changing its host-service registration\n' >&2
    return 1
  fi
  fm_sentinel_disarm_service "$launchctl" "$service"
  rc=$?
  fm_lock_release "$FM_SENTINEL_ARM_LOCK" 2>/dev/null || true
  [ "$rc" -eq 0 ] || return "$rc"
  printf 'supervision sentinel: disarmed for this home; session start will keep reporting this state\n'
}

fm_sentinel_enable() {
  fm_primary_scope_matches "$FM_ROOT" "$FM_SENTINEL_STATE" || {
    printf 'supervision sentinel: enable is valid only in this home primary scope\n' >&2
    return 1
  }
  # The explicit command is the deliberate override for both the durable
  # record and a process-local MODE=off setting.
  FM_SUPERVISION_SENTINEL_MODE=auto
  FM_SENTINEL_FORCE_ARM=1
  if ! fm_sentinel_arm; then
    printf 'supervision sentinel: re-enable failed; durable disarm record preserved\n' >&2
    return 1
  fi
  rm -f "$FM_SENTINEL_DISARMED" || {
    printf 'supervision sentinel: host service is live but the stale disarm record could not be cleared\n' >&2
    return 1
  }
  printf 'supervision sentinel: enabled for this home\n'
}

fm_sentinel_episode_key() {
  local beat m pid
  beat="$FM_SENTINEL_STATE/.last-watcher-beat"
  m=$(fm_sup_stat_mtime "$beat" 2>/dev/null || printf 'absent')
  pid=$(cat "$FM_SENTINEL_STATE/.watch.lock/pid" 2>/dev/null || printf 'none')
  printf 'beat:%s|lock:%s\n' "$m" "$pid"
}

fm_sentinel_marker_field() { # <field>
  [ -f "$FM_SENTINEL_MARKER" ] || return 1
  /usr/bin/awk -F= -v want="$1" '$1 == want { sub(/^[^=]*=/, ""); print; exit }' "$FM_SENTINEL_MARKER"
}

fm_sentinel_write_alarm_record() { # <delivery> <claim> <attempt> <episode> <summary> [delivered] [count] [next]
  local delivery=$1 claim=$2 attempt=$3 episode=$4 summary=$5 delivered=${6:-} count=${7:-0} next=${8:-} pending
  pending=$(mktemp "$FM_SENTINEL_STATE/.supervision-outage-alarm.XXXXXX") || return 1
  {
    printf 'state=outage\n'
    printf 'delivery=%s\n' "$delivery"
    printf 'claim=%s\n' "$claim"
    printf 'attempt_at=%s\n' "$attempt"
    [ -z "$delivered" ] || printf 'delivered_at=%s\n' "$delivered"
    printf 'delivery_count=%s\n' "$count"
    [ -z "$next" ] || printf 'next_alert_at=%s\n' "$next"
    printf 'episode=%s\n' "$episode"
    printf '%s\n' "$summary"
  } > "$pending" || { rm -f "$pending"; return 1; }
  mv -f "$pending" "$FM_SENTINEL_MARKER" || { rm -f "$pending"; return 1; }
}

fm_sentinel_backoff_delay() { # <delivery-count>
  local count=$1 delay=$FM_SENTINEL_REALARM i=1
  while [ "$i" -lt "$count" ] && [ "$delay" -lt "$FM_SENTINEL_MAX_REALARM" ]; do
    if [ "$delay" -gt $((FM_SENTINEL_MAX_REALARM / 2)) ]; then
      delay=$FM_SENTINEL_MAX_REALARM
    else
      delay=$((delay * 2))
    fi
    i=$((i + 1))
  done
  [ "$delay" -le "$FM_SENTINEL_MAX_REALARM" ] || delay=$FM_SENTINEL_MAX_REALARM
  printf '%s\n' "$delay"
}

fm_sentinel_clear_alarm() { # [claim-token]
  local token=${1:-} current
  fm_lock_try_acquire "$FM_SENTINEL_CHECK_LOCK" || return 0
  if [ -n "$token" ]; then
    current=$(fm_sentinel_marker_field claim 2>/dev/null || true)
    if [ "$current" != "$token" ]; then
      fm_lock_release "$FM_SENTINEL_CHECK_LOCK" 2>/dev/null || true
      return 0
    fi
  fi
  rm -f "$FM_SENTINEL_MARKER" 2>/dev/null || true
  fm_lock_release "$FM_SENTINEL_CHECK_LOCK" 2>/dev/null || true
}

fm_sentinel_claim_alarm() { # <episode-key> <summary>
  local key=$1 summary=$2 now delivery delivered_at next_alert_at attempt_at deliveries elapsed token episode new_episode=0
  FM_SENTINEL_CLAIM_TOKEN=
  now=$(date +%s)
  # A wedged claim lock must not silence the alarm. Return the storage-failure
  # class so the caller still attempts the active channel without dedup state.
  fm_lock_try_acquire "$FM_SENTINEL_CHECK_LOCK" || return 2
  delivery=$(fm_sentinel_marker_field delivery 2>/dev/null || true)
  delivered_at=$(fm_sentinel_marker_field delivered_at 2>/dev/null || true)
  next_alert_at=$(fm_sentinel_marker_field next_alert_at 2>/dev/null || true)
  attempt_at=$(fm_sentinel_marker_field attempt_at 2>/dev/null || true)
  episode=$(fm_sentinel_marker_field episode 2>/dev/null || true)
  deliveries=$(fm_sentinel_marker_field delivery_count 2>/dev/null || printf '0')
  case "$deliveries" in ''|*[!0-9]*) deliveries=0 ;; esac
  # A changed episode key means the watcher lock pid or beacon evidence moved:
  # the watcher recovered and was reaped again between two scheduled checks. That
  # flapping outage is genuinely new, so it restarts the repeat schedule instead
  # of inheriting a backoff that can already be an hour long. Only an unchanged,
  # continuous outage keeps backing off.
  if [ -n "$episode" ] && [ "$episode" != "$key" ]; then
    new_episode=1
    deliveries=0
  fi
  if [ "$delivery" = sent ] && [ "$new_episode" -eq 0 ]; then
    case "$next_alert_at" in
      ''|*[!0-9]*)
        case "$delivered_at" in
          ''|*[!0-9]*) ;;
          *) next_alert_at=$((delivered_at + FM_SENTINEL_REALARM)) ;;
        esac
        ;;
    esac
    case "$next_alert_at" in
      ''|*[!0-9]*) ;;
      *)
        elapsed=$((next_alert_at - now))
        if [ "$elapsed" -gt 0 ] && [ "$elapsed" -le "$FM_SENTINEL_MAX_REALARM" ]; then
          fm_lock_release "$FM_SENTINEL_CHECK_LOCK" 2>/dev/null || true
          return 1
        fi
        ;;
    esac
  elif [ "$delivery" = pending ]; then
    # The short claim lease still applies to a new episode: it only defers by
    # FM_SENTINEL_CLAIM_LEASE_SECS, and honoring it keeps a delivery that is
    # still in flight from being duplicated by a concurrent check.
    case "$attempt_at" in
      ''|*[!0-9]*) ;;
      *)
        elapsed=$((now - attempt_at))
        if [ "$elapsed" -ge 0 ] && [ "$elapsed" -lt "$FM_SENTINEL_CLAIM_LEASE" ]; then
          fm_lock_release "$FM_SENTINEL_CHECK_LOCK" 2>/dev/null || true
          return 1
        fi
        ;;
    esac
  fi
  token="${BASHPID:-$$}-$now-${RANDOM:-0}"
  if ! fm_sentinel_write_alarm_record pending "$token" "$now" "$key" "$summary" '' "$deliveries"; then
    fm_lock_release "$FM_SENTINEL_CHECK_LOCK" 2>/dev/null || true
    return 2
  fi
  FM_SENTINEL_CLAIM_TOKEN=$token
  fm_lock_release "$FM_SENTINEL_CHECK_LOCK" 2>/dev/null || true
  return 0
}

fm_sentinel_mark_delivered() { # <claim-token> <episode> <summary>
  local token=$1 key=$2 summary=$3 current now deliveries delay next
  now=$(date +%s)
  fm_lock_try_acquire "$FM_SENTINEL_CHECK_LOCK" || return 1
  current=$(fm_sentinel_marker_field claim 2>/dev/null || true)
  if [ "$current" != "$token" ]; then
    fm_lock_release "$FM_SENTINEL_CHECK_LOCK" 2>/dev/null || true
    return 1
  fi
  deliveries=$(fm_sentinel_marker_field delivery_count 2>/dev/null || printf '0')
  case "$deliveries" in ''|*[!0-9]*) deliveries=0 ;; esac
  deliveries=$((deliveries + 1))
  delay=$(fm_sentinel_backoff_delay "$deliveries")
  next=$((now + delay))
  fm_sentinel_write_alarm_record sent "$token" "$now" "$key" "$summary" "$now" "$deliveries" "$next"
  current=$?
  fm_lock_release "$FM_SENTINEL_CHECK_LOCK" 2>/dev/null || true
  return "$current"
}

fm_sentinel_record_check() {
  local pending="$FM_SENTINEL_LAST_CHECK.pending.$$"
  if ! printf '%s\n' "$(date +%s)" > "$pending" || ! mv -f "$pending" "$FM_SENTINEL_LAST_CHECK"; then
    rm -f "$pending"
    return 1
  fi
}

fm_sentinel_summary() {
  printf 'SUPERVISION DOWN: %s task(s) in flight; last watcher beat: %s (grace %ss). No automatic restart was attempted; see %s\n' \
    "$FM_SUP_IN_FLIGHT" "$FM_SUP_BEACON_DESC" "$FM_SENTINEL_GRACE" "$FM_SENTINEL_MARKER"
}

# Marker-only mode for the in-harness turn-end and continuity guards.
#
# Those hooks must render their blocking banner immediately: a Stop hook that
# outruns its harness timeout loses the block itself, which is the very backstop
# this sentinel exists to strengthen. So a guard records durable evidence with
# local writes alone and never forks the alert owner, never backgrounds notifier
# work, and never writes the launchd-liveness proof. The scheduled host check
# remains the sole owner of external alert delivery.
fm_sentinel_note_outage() {
  local key summary
  fm_sentinel_mode_enabled || return 0
  fm_primary_scope_matches "$FM_ROOT" "$FM_SENTINEL_STATE" || return 0
  [ -f "$FM_SENTINEL_DISARMED" ] && return 0
  fm_sentinel_normalize_tunables
  fm_supervision_status "$FM_SENTINEL_STATE" "$FM_SENTINEL_GRACE"
  [ "$FM_SUP_IN_FLIGHT" -gt 0 ] || return 0
  fm_watcher_healthy "$FM_SENTINEL_STATE" "$FM_SENTINEL_WATCH" "$FM_SENTINEL_GRACE" "$FM_HOME" && return 0
  fm_lock_try_acquire "$FM_SENTINEL_CHECK_LOCK" || return 0
  if [ ! -e "$FM_SENTINEL_MARKER" ]; then
    key=$(fm_sentinel_episode_key)
    summary=$(fm_sentinel_summary)
    # An unclaimed record with attempt_at=0 leaves no delivery lease to wait out,
    # so the next scheduled host check claims and alerts on this episode at once.
    fm_sentinel_write_alarm_record pending '' 0 "$key" "$summary" '' 0 || true
  fi
  fm_lock_release "$FM_SENTINEL_CHECK_LOCK" 2>/dev/null || true
  return 0
}

fm_sentinel_check() { # [record-host-liveness: 0|1]
  local record_host=${1:-0} claim_rc key summary
  fm_sentinel_mode_enabled || return 0
  fm_primary_scope_matches "$FM_ROOT" "$FM_SENTINEL_STATE" || return 0
  if [ "$record_host" -eq 1 ]; then
    [ -f "$FM_SENTINEL_DISARMED" ] && return 0
    # Publish liveness only for launchd's private entry point and only when the
    # one-shot check exits. Guard-owned checks cannot forge host-service health.
    trap 'fm_sentinel_record_check || true' EXIT
  fi
  fm_sentinel_normalize_tunables
  fm_supervision_status "$FM_SENTINEL_STATE" "$FM_SENTINEL_GRACE"
  if [ "$FM_SUP_IN_FLIGHT" -eq 0 ]; then
    fm_sentinel_clear_alarm
    return 0
  fi
  if fm_watcher_healthy "$FM_SENTINEL_STATE" "$FM_SENTINEL_WATCH" "$FM_SENTINEL_GRACE" "$FM_HOME"; then
    fm_sentinel_clear_alarm
    return 0
  fi

  summary=$(fm_sentinel_summary)
  key=$(fm_sentinel_episode_key)
  fm_sentinel_claim_alarm "$key" "$summary"
  claim_rc=$?
  [ "$claim_rc" -eq 1 ] && return 0

  # A competing recovery may have landed after the claim. Revalidate before
  # crossing the active-alert boundary, and clear only this claim if healthy.
  fm_supervision_status "$FM_SENTINEL_STATE" "$FM_SENTINEL_GRACE"
  if [ "$FM_SUP_IN_FLIGHT" -eq 0 ] || fm_watcher_healthy "$FM_SENTINEL_STATE" "$FM_SENTINEL_WATCH" "$FM_SENTINEL_GRACE" "$FM_HOME"; then
    [ -z "$FM_SENTINEL_CLAIM_TOKEN" ] || fm_sentinel_clear_alarm "$FM_SENTINEL_CLAIM_TOKEN"
    return 0
  fi

  if [ ! -x "$FM_SENTINEL_ALERT_OWNER" ]; then
    return 1
  fi
  if FM_WEDGE_ALARM_TITLE='firstmate: SUPERVISION DOWN' \
    FM_WEDGE_ALARM_LOG_FILE="$FM_SENTINEL_STATE/.supervision-sentinel.log" \
    "$FM_SENTINEL_ALERT_OWNER" --active-alert "$summary" "$FM_SENTINEL_MARKER"; then
    [ -z "$FM_SENTINEL_CLAIM_TOKEN" ] || fm_sentinel_mark_delivered "$FM_SENTINEL_CLAIM_TOKEN" "$key" "$summary" || true
    return 0
  fi
  # Leave delivery=pending so the next scheduled check retries after the short
  # claim lease instead of suppressing a notification that never landed.
  return 1
}

case "${1:-}" in
  arm) [ "$#" -eq 1 ] || { fm_sentinel_usage >&2; exit 2; }; fm_sentinel_arm ;;
  enable) [ "$#" -eq 1 ] || { fm_sentinel_usage >&2; exit 2; }; fm_sentinel_enable ;;
  disarm) [ "$#" -eq 1 ] || { fm_sentinel_usage >&2; exit 2; }; fm_sentinel_disarm ;;
  check) [ "$#" -eq 1 ] || { fm_sentinel_usage >&2; exit 2; }; fm_sentinel_check 0 ;;
  note-outage) [ "$#" -eq 1 ] || { fm_sentinel_usage >&2; exit 2; }; fm_sentinel_note_outage ;;
  scheduled-check) [ "$#" -eq 1 ] || { fm_sentinel_usage >&2; exit 2; }; fm_sentinel_check 1 ;;
  -h|--help) fm_sentinel_usage ;;
  *) fm_sentinel_usage >&2; exit 2 ;;
esac
