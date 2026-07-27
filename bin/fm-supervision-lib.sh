# shellcheck shell=bash
# Shared "supervision missing" predicate.
# Usage: . bin/fm-supervision-lib.sh
#
# True exactly when a firstmate home has in-flight work (a state/<id>.meta
# exists) but no watcher has a fresh liveness beacon (state/.last-watcher-beat,
# touched every poll cycle, within the grace window). bin/fm-guard.sh uses this
# grace-based warning predicate directly; bin/fm-turnend-guard.sh uses the status
# fields here for its banner but performs its end-of-turn block decision with the
# live watcher lock check in bin/fm-wake-lib.sh.

# Portable mtime; Linux stat lacks -f, macOS stat lacks -c.
fm_sup_stat_mtime() {
  if [ "$(uname)" = Darwin ]; then
    stat -f %m "$1" 2>/dev/null
  else
    stat -c %Y "$1" 2>/dev/null
  fi
}

# fm_supervision_status <state-dir> [grace-seconds]
# Populates, for the state dir at $1:
#   FM_SUP_IN_FLIGHT      count of state/*.meta (in-flight tasks)
#   FM_SUP_WATCHER_FRESH  true/false - a watcher beacon within the grace window
#   FM_SUP_BEACON_DESC    human-readable beacon age, for banners ("never" if absent)
#   FM_SUP_QUEUE_PENDING  true/false - state/.wake-queue has unread records
# grace-seconds defaults to $FM_GUARD_GRACE, then 300, matching fm-guard.sh.
# Always returns 0; callers read the vars, or use fm_supervision_unhealthy below.
fm_supervision_status() {
  local state=$1 grace=${2:-${FM_GUARD_GRACE:-300}} meta beat m age
  FM_SUP_IN_FLIGHT=0
  FM_SUP_WATCHER_FRESH=false
  FM_SUP_BEACON_DESC=never
  FM_SUP_QUEUE_PENDING=false

  for meta in "$state"/*.meta; do
    [ -e "$meta" ] || continue
    FM_SUP_IN_FLIGHT=$((FM_SUP_IN_FLIGHT + 1))
  done

  beat="$state/.last-watcher-beat"
  if [ -e "$beat" ]; then
    m=$(fm_sup_stat_mtime "$beat")
    if [ -n "$m" ]; then
      age=$(( $(date +%s) - m ))
      if [ "$age" -lt 0 ]; then
        FM_SUP_BEACON_DESC="$((-age))s in the future"
      else
        FM_SUP_BEACON_DESC="${age}s ago"
        [ "$age" -lt "$grace" ] && FM_SUP_WATCHER_FRESH=true
      fi
    else
      # shellcheck disable=SC2034 # Read by callers (fm-guard.sh) after sourcing.
      FM_SUP_BEACON_DESC=unknown
    fi
  fi

  # shellcheck disable=SC2034 # Read by callers (fm-guard.sh) after sourcing.
  [ -s "$state/.wake-queue" ] && FM_SUP_QUEUE_PENDING=true
  return 0
}

# fm_supervision_unhealthy <state-dir> [grace-seconds]
# Exit 0 (true) exactly in the dangerous state: in-flight work exists and no
# watcher has a fresh beacon. Exit 1 (false) otherwise, including zero in-flight.
fm_supervision_unhealthy() {
  fm_supervision_status "$@"
  [ "$FM_SUP_IN_FLIGHT" -gt 0 ] && [ "$FM_SUP_WATCHER_FRESH" = false ]
}

# Canonical basename of the durable host-sentinel registration-failure record.
# Every producer and consumer derives its path from this, so the filename is
# spelled exactly once in the tree.
FM_SUP_ARM_RECORD_NAME=.supervision-sentinel.arm-failure

# fm_supervision_arm_failure_status <state-dir>
# Reads the durable host-sentinel registration-failure record and populates:
#   FM_SUP_ARM_RECORD       resolved path of the record, set whether or not it exists
#   FM_SUP_ARM_FAILED       true/false - the record exists at all
#   FM_SUP_ARM_FAILURES     recorded consecutive failure count (0 when unreadable)
#   FM_SUP_ARM_RETRY_IN     seconds the retry cooldown still suppresses registration
#   FM_SUP_ARM_RETRY_STALE  true/false - the deadline is unusable, so it suppresses nothing
#
# One snapshot answers every question about the record, so a caller reads the file
# once per operation instead of re-deriving fields through separate wrappers.
#
# The cooldown counts only while retry_at is in the future AND no further away
# than the retry_after_secs recorded atomically beside it. A wall-clock rollback,
# or a state volume restored from a machine whose clock ran ahead, therefore reads
# as stale evidence that suppresses nothing rather than an enormous fake
# suppression window. Both bin/fm-supervision-sentinel.sh (which enforces the
# cooldown) and bin/fm-session-start.sh (which reports it) call this, so the
# displayed window and the enforced window cannot drift apart.
# Always returns 0; callers read the vars.
fm_supervision_arm_failure_status() {
  local state=$1 at after now remaining
  FM_SUP_ARM_RECORD="$state/$FM_SUP_ARM_RECORD_NAME"
  FM_SUP_ARM_FAILED=false
  FM_SUP_ARM_FAILURES=0
  FM_SUP_ARM_RETRY_IN=0
  FM_SUP_ARM_RETRY_STALE=false
  [ -f "$FM_SUP_ARM_RECORD" ] || return 0
  # shellcheck disable=SC2034 # Read by callers after sourcing.
  FM_SUP_ARM_FAILED=true

  FM_SUP_ARM_FAILURES=$(awk -F= '$1 == "failures" { print $2; exit }' "$FM_SUP_ARM_RECORD" 2>/dev/null || true)
  case "$FM_SUP_ARM_FAILURES" in ''|*[!0-9]*) FM_SUP_ARM_FAILURES=0 ;; esac

  at=$(awk -F= '$1 == "retry_at" { print $2; exit }' "$FM_SUP_ARM_RECORD" 2>/dev/null || true)
  after=$(awk -F= '$1 == "retry_after_secs" { print $2; exit }' "$FM_SUP_ARM_RECORD" 2>/dev/null || true)
  case "$at" in ''|*[!0-9]*) FM_SUP_ARM_RETRY_STALE=true; return 0 ;; esac
  case "$after" in ''|*[!0-9]*) FM_SUP_ARM_RETRY_STALE=true; return 0 ;; esac

  now=$(date +%s)
  [ "$now" -lt "$at" ] || return 0
  remaining=$((at - now))
  if [ "$remaining" -gt "$after" ]; then
    # shellcheck disable=SC2034 # Read by callers after sourcing.
    FM_SUP_ARM_RETRY_STALE=true
    return 0
  fi
  # shellcheck disable=SC2034 # Read by callers after sourcing.
  FM_SUP_ARM_RETRY_IN=$remaining
  return 0
}
