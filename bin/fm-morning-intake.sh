#!/usr/bin/env bash
# Once-per-local-day morning intake gate for a scheduled daily report.
#
# Usage:
#   fm-morning-intake.sh run [--force]
#   fm-morning-intake.sh claim
#   fm-morning-intake.sh complete --report FILE [--source-watermark VALUE]
#   fm-morning-intake.sh fail --reason TEXT
#   fm-morning-intake.sh rearm --reason TEXT
#   fm-morning-intake.sh check
#   fm-morning-intake.sh arm-check
#   fm-morning-intake.sh disarm-check
#   fm-morning-intake.sh pending
#   fm-morning-intake.sh acknowledge [REPORT]
#   fm-morning-intake.sh status
#   fm-morning-intake.sh reset
#   fm-morning-intake.sh --help
#
# This is a LOCAL GATE ONLY. It never reads a source system, never spawns an
# agent, never starts a session, and never takes the per-home session lock, so
# it cannot compete with a live fleet. `run` decides whether today's intake is
# owed and, when it is, records the durable armed state and appends one wake.
# The orchestrator does the actual ingestion and report writing, then calls
# `complete`; the intake is not finished until that call verifies a report.
#
# Two delivery paths reach the orchestrator, and neither one starts a session:
#
#   Live session - `arm-check` writes state/<label>.check.sh and binds it with
#   bin/fm-check-register.sh, so the running watcher executes it on its own slow
#   cadence and wakes the live primary through the established check path. The
#   shim runs `check`, which prints one line only while an intake is actually
#   owed and stays silent once that state has been surfaced.
#
#   No session running - nothing is delivered at the time the job fires. The
#   armed state and the pending marker are durable, and the next session's
#   bootstrap section surfaces them through `pending`. So on a closed or
#   logged-out laptop the intake is QUEUED UNTIL FIRSTMATE NEXT STARTS. It is
#   not running, and nothing about this makes it start on lid-open.
#
# `run` is the scheduled entry point (bin/fm-morning-intake-schedule.sh installs
# it on macOS launchd) and is also the manual command: run it by hand at any
# time, with --force to arm an intake outside the configured window.
#
# Opening is defined as the FIRST AVAILABLE MORNING, not a lid-open event: there
# is no hardware event here. A laptop asleep or offline past the threshold arms
# the intake on the first run after it wakes, which is the catch-up path.
#
# The completion watermark (data/morning-intake/last-complete) advances ONLY in
# `complete`, and only after the named report is verified as a non-empty regular
# file. `fail` records a visible failure and never advances it, so a corrected
# source message published after a same-day failure is still ingested by the
# next run while attempts remain.
#
# Opt-in is per home and per device: with no `enabled = true` line in private
# config/morning-intake this command is inert, so cloning the repo or seeding
# another home never enrolls it.
#
# Configuration lives in private, gitignored config/morning-intake as
# `key = value` lines. Unknown keys are refused rather than ignored, so no
# secret, channel id, or account path can be parked in this file; those belong
# in the orchestrator's own private records.
#   enabled            true to arm this home (default false)
#   timezone           IANA zone for the local day (default: host local time)
#   start_time         HH:MM start-of-morning threshold (default 06:00)
#   interval_seconds   scheduled poll cadence (default 900)
#   max_attempts       bounded retries per local day (default 3)
#   retry_after_seconds  re-arm a claim that never completed (default 1800)
#   report_dir         directory the day's report must be written into
#   label              slug used in the wake key and diagnostic line
#                      (default morning-intake)
set -eu

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$ROOT}}"
CONFIG="${FM_CONFIG_OVERRIDE:-$FM_HOME/config}"
DATA="${FM_DATA_OVERRIDE:-$FM_HOME/data}"
CONFIG_FILE="$CONFIG/morning-intake"
INTAKE_DIR="$DATA/morning-intake"
STATE_FILE="$INTAKE_DIR/state"
COMPLETE_FILE="$INTAKE_DIR/last-complete"
SOURCE_FILE="$INTAKE_DIR/source-watermark"
PENDING_FILE="$INTAKE_DIR/pending-report"
LOG_FILE="$INTAKE_DIR/log"

DEFAULT_START_TIME=06:00
DEFAULT_INTERVAL=900
DEFAULT_MAX_ATTEMPTS=3
DEFAULT_RETRY_AFTER=1800
DEFAULT_LABEL=morning-intake

CFG_ENABLED=false
CFG_TIMEZONE=
CFG_START_TIME=$DEFAULT_START_TIME
CFG_INTERVAL=$DEFAULT_INTERVAL
CFG_MAX_ATTEMPTS=$DEFAULT_MAX_ATTEMPTS
CFG_RETRY_AFTER=$DEFAULT_RETRY_AFTER
CFG_REPORT_DIR=
CFG_LABEL=$DEFAULT_LABEL

usage() {
  awk '
    NR == 1 { next }
    /^#/ { sub(/^# ?/, ""); print; next }
    { exit }
  ' "$0" >&2
}

die() {
  printf 'fm-morning-intake: %s\n' "$*" >&2
  exit 2
}

# --- configuration ----------------------------------------------------------

require_positive_int() {
  local key=$1 value=$2
  case "$value" in
    ''|*[!0-9]*|0) die "$key must be a positive integer: $value" ;;
  esac
}

load_config() {
  local line key value
  [ -f "$CONFIG_FILE" ] || return 0
  [ ! -L "$CONFIG_FILE" ] || die "config must be a regular file: $CONFIG_FILE"
  while IFS= read -r line || [ -n "$line" ]; do
    line=$(printf '%s\n' "$line" | sed -E 's/^[[:space:]]+//; s/[[:space:]]+$//')
    case "$line" in ''|'#'*) continue ;; esac
    case "$line" in
      *=*) ;;
      *) die "config line is not key = value: $line" ;;
    esac
    key=$(printf '%s\n' "${line%%=*}" | tr -d '[:space:]')
    value=$(printf '%s\n' "${line#*=}" | sed -E 's/^[[:space:]]+//; s/[[:space:]]+$//')
    case "$key" in
      enabled)
        case "$value" in
          true|false) CFG_ENABLED=$value ;;
          *) die "enabled must be true or false: $value" ;;
        esac
        ;;
      timezone)
        case "$value" in
          *[!A-Za-z0-9/_+-]*) die "timezone contains unsupported characters" ;;
        esac
        CFG_TIMEZONE=$value
        ;;
      start_time)
        printf '%s\n' "$value" | grep -Eq '^([01][0-9]|2[0-3]):[0-5][0-9]$' \
          || die "start_time must be HH:MM in 24-hour form: $value"
        CFG_START_TIME=$value
        ;;
      interval_seconds) require_positive_int interval_seconds "$value"; CFG_INTERVAL=$value ;;
      max_attempts) require_positive_int max_attempts "$value"; CFG_MAX_ATTEMPTS=$value ;;
      retry_after_seconds) require_positive_int retry_after_seconds "$value"; CFG_RETRY_AFTER=$value ;;
      report_dir)
        case "$value" in
          /*) ;;
          *) die "report_dir must be an absolute path: $value" ;;
        esac
        CFG_REPORT_DIR=${value%/}
        ;;
      label)
        case "$value" in
          ''|*[!A-Za-z0-9._-]*) die "label must be a slug of [A-Za-z0-9._-]: $value" ;;
        esac
        CFG_LABEL=$value
        ;;
      *) die "unknown config key: $key" ;;
    esac
  done <"$CONFIG_FILE"
}

enabled() {
  [ "$CFG_ENABLED" = true ]
}

require_enabled() {
  enabled || die "this home is not opted in; add 'enabled = true' to $CONFIG_FILE"
}

# --- clock ------------------------------------------------------------------

now_epoch() {
  local value=${FM_MORNING_INTAKE_NOW:-}
  if [ -n "$value" ]; then
    case "$value" in
      ''|*[!0-9]*) die "FM_MORNING_INTAKE_NOW must be an epoch second: $value" ;;
    esac
    printf '%s\n' "$value"
    return 0
  fi
  date +%s
}

# Render one strftime format for an epoch in the configured zone.
# TZ is scoped to the date call so nothing else in this process is retimed.
local_fmt() {
  local epoch=$1 fmt=$2
  if [ -n "$CFG_TIMEZONE" ]; then
    TZ="$CFG_TIMEZONE" date -r "$epoch" "+$fmt" 2>/dev/null \
      || TZ="$CFG_TIMEZONE" date -d "@$epoch" "+$fmt" 2>/dev/null \
      || die "cannot render local time; date(1) supports neither -r nor -d"
  else
    date -r "$epoch" "+$fmt" 2>/dev/null \
      || date -d "@$epoch" "+$fmt" 2>/dev/null \
      || die "cannot render local time; date(1) supports neither -r nor -d"
  fi
}

local_date() {
  local_fmt "$1" '%Y-%m-%d'
}

# True when the epoch is at or past today's configured start-of-morning.
past_threshold() {
  local epoch=$1 hhmm
  hhmm=$(local_fmt "$epoch" '%H:%M')
  [ "$hhmm" \> "$CFG_START_TIME" ] || [ "$hhmm" = "$CFG_START_TIME" ]
}

# --- durable state ----------------------------------------------------------

write_atomic() {
  local dest=$1 value=$2 parent tmp
  parent=${dest%/*}
  mkdir -p "$parent"
  tmp=$(umask 077; mktemp "$parent/.morning-intake.XXXXXX") || return 1
  printf '%s\n' "$value" >"$tmp" || { rm -f "$tmp"; return 1; }
  chmod 600 "$tmp"
  mv -f "$tmp" "$dest"
}

read_line_file() {
  local file=$1 value=
  [ -f "$file" ] && [ ! -L "$file" ] || return 0
  IFS= read -r value <"$file" 2>/dev/null || true
  printf '%s\n' "$value"
}

ST_DATE=
ST_PHASE=idle
ST_ATTEMPTS=0
ST_UPDATED=0
ST_REPORT=
ST_ERROR=
ST_REARMS=0
ST_SURFACED=

load_state() {
  local line key value
  ST_DATE=; ST_PHASE=idle; ST_ATTEMPTS=0; ST_UPDATED=0
  ST_REPORT=; ST_ERROR=; ST_REARMS=0; ST_SURFACED=
  [ -f "$STATE_FILE" ] && [ ! -L "$STATE_FILE" ] || return 0
  while IFS= read -r line || [ -n "$line" ]; do
    key=${line%%=*}
    value=${line#*=}
    case "$key" in
      date) ST_DATE=$value ;;
      phase) ST_PHASE=$value ;;
      attempts) ST_ATTEMPTS=$value ;;
      updated) ST_UPDATED=$value ;;
      report) ST_REPORT=$value ;;
      error) ST_ERROR=$value ;;
      rearms) ST_REARMS=$value ;;
      surfaced) ST_SURFACED=$value ;;
    esac
  done <"$STATE_FILE"
  case "$ST_ATTEMPTS" in ''|*[!0-9]*) ST_ATTEMPTS=0 ;; esac
  case "$ST_UPDATED" in ''|*[!0-9]*) ST_UPDATED=0 ;; esac
  case "$ST_REARMS" in ''|*[!0-9]*) ST_REARMS=0 ;; esac
}

save_state() {
  local body parent tmp
  body=$(printf 'date=%s\nphase=%s\nattempts=%s\nupdated=%s\nrearms=%s\nsurfaced=%s\nreport=%s\nerror=%s' \
    "$ST_DATE" "$ST_PHASE" "$ST_ATTEMPTS" "$ST_UPDATED" "$ST_REARMS" \
    "$(sanitize "$ST_SURFACED")" "$(sanitize "$ST_REPORT")" "$(sanitize "$ST_ERROR")")
  parent=$INTAKE_DIR
  mkdir -p "$parent"
  tmp=$(umask 077; mktemp "$parent/.morning-intake.XXXXXX") || die 'cannot write state'
  printf '%s\n' "$body" >"$tmp" || { rm -f "$tmp"; die 'cannot write state'; }
  chmod 600 "$tmp"
  mv -f "$tmp" "$STATE_FILE"
}

sanitize() {
  printf '%s' "${1:-}" | LC_ALL=C tr '\t\r\n' '   '
}

log_event() {
  mkdir -p "$INTAKE_DIR"
  umask 077
  printf '%s\t%s\t%s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$ST_PHASE" "$(sanitize "$*")" \
    >>"$LOG_FILE"
}

last_complete_date() {
  read_line_file "$COMPLETE_FILE"
}

# --- wake delivery ----------------------------------------------------------

# One durable `check` wake, appended through the shared queue owner. This is the
# only fleet-visible side effect, and appending is not locking: no session lock
# is taken, no watcher is started, and no other home's state is touched.
enqueue_wake() {
  local day=$1 payload
  payload="$CFG_LABEL due for $day; run '$0 claim' to take it"
  # shellcheck source=bin/fm-wake-lib.sh disable=SC1091
  . "$SCRIPT_DIR/fm-wake-lib.sh"
  fm_wake_append check "$CFG_LABEL" "$payload"
}

# --- live-session delivery: the registered watcher check ---------------------

STATE_DIR="${FM_STATE_OVERRIDE:-$FM_HOME/state}"

check_path() {
  printf '%s/%s.check.sh\n' "$STATE_DIR" "$CFG_LABEL"
}

check_armed_state() {
  local check trust
  check=$(check_path)
  trust="$STATE_DIR/$CFG_LABEL.check-trust"
  if [ -f "$check" ] && [ -f "$trust" ]; then
    printf 'armed\n'
  elif [ -f "$check" ]; then
    printf 'unregistered\n'
  else
    printf 'absent\n'
  fi
}

# The shim is deliberately tiny and byte-stable: it names this script and the
# home it belongs to and nothing else, so registering it once stays valid.
render_check_shim() {
  cat <<SHIM
#!/usr/bin/env bash
# Generated by bin/fm-morning-intake.sh arm-check. Do not edit; re-arm instead.
set -eu
FM_HOME='$FM_HOME' FM_ROOT_OVERRIDE='$ROOT' exec '$SCRIPT_DIR/fm-morning-intake.sh' check
SHIM
}

arm_check() {
  local check tmp
  [ "$#" -eq 0 ] || die 'arm-check takes no arguments'
  require_enabled
  [ -d "$STATE_DIR" ] && [ ! -L "$STATE_DIR" ] || mkdir -p "$STATE_DIR"
  check=$(check_path)
  [ ! -L "$check" ] || die "check path is a symlink: $check"
  umask 077
  tmp=$(mktemp "$STATE_DIR/.morning-intake-check.XXXXXX") || die 'cannot stage the check shim'
  render_check_shim >"$tmp" || { rm -f "$tmp"; die 'cannot write the check shim'; }
  chmod 0700 "$tmp" || { rm -f "$tmp"; die 'cannot set check shim mode'; }
  mv -f "$tmp" "$check"
  # The watcher refuses to execute an unregistered custom check, so binding the
  # bytes through the registration owner is what makes this path live.
  "$SCRIPT_DIR/fm-check-register.sh" "$CFG_LABEL" \
    || die "check registration failed for $CFG_LABEL"
}

disarm_check() {
  local check
  [ "$#" -eq 0 ] || die 'disarm-check takes no arguments'
  check=$(check_path)
  rm -f "$check" "$STATE_DIR/$CFG_LABEL.check-trust"
  printf 'disarmed: %s\n' "$check"
}

# The watcher contract: print exactly one line when firstmate should wake, print
# nothing otherwise, and finish well inside FM_CHECK_TIMEOUT. Suppression is by
# state signature, so a still-owed intake wakes the primary once rather than on
# every poll; any real state change re-arms the signal.
check_signal() {
  local epoch day signature line=
  [ "$#" -eq 0 ] || die 'check takes no arguments'
  enabled || return 0
  epoch=$(now_epoch)
  day=$(local_date "$epoch")
  load_state
  [ "$ST_DATE" = "$day" ] || return 0
  case "$ST_PHASE" in
    due)
      line="$CFG_LABEL due for $day; take it with '$SCRIPT_DIR/fm-morning-intake.sh claim'"
      ;;
    claimed)
      [ $((epoch - ST_UPDATED)) -ge "$CFG_RETRY_AFTER" ] || return 0
      line="$CFG_LABEL claim for $day stalled after $((epoch - ST_UPDATED))s"
      ;;
    failed)
      line="$CFG_LABEL failed for $day (attempt $ST_ATTEMPTS of $CFG_MAX_ATTEMPTS): ${ST_ERROR:-unspecified failure}"
      ;;
    *) return 0 ;;
  esac
  signature="$ST_PHASE:$ST_ATTEMPTS:$ST_REARMS:$ST_UPDATED"
  [ "$ST_SURFACED" != "$signature" ] || return 0
  ST_SURFACED=$signature
  save_state
  printf '%s\n' "$line"
}

# --- commands ---------------------------------------------------------------

run_intake() {
  local force=false epoch day complete age reason
  while [ "$#" -gt 0 ]; do
    case "$1" in
      --force) force=true; shift ;;
      *) die "unknown run argument: $1" ;;
    esac
  done

  if ! enabled; then
    # Inert by design on a home that never opted in.
    return 0
  fi
  epoch=$(now_epoch)
  day=$(local_date "$epoch")
  load_state
  complete=$(last_complete_date)

  if [ "$ST_DATE" != "$day" ]; then
    # A new local day resets attempts; yesterday's failure never blocks today.
    ST_DATE=$day; ST_PHASE=idle; ST_ATTEMPTS=0; ST_REARMS=0; ST_REPORT=; ST_ERROR=; ST_SURFACED=
  fi

  if [ "$force" != true ]; then
    if [ "$complete" = "$day" ]; then
      return 0
    fi
    past_threshold "$epoch" || return 0
    case "$ST_PHASE" in
      due)
        # Already armed for today: never enqueue a second wake for one day.
        return 0
        ;;
      claimed)
        age=$((epoch - ST_UPDATED))
        [ "$age" -ge "$CFG_RETRY_AFTER" ] || return 0
        reason="claim did not complete within ${CFG_RETRY_AFTER}s"
        ;;
      failed)
        reason="retrying after: ${ST_ERROR:-unspecified failure}"
        ;;
      *) reason='first arm of the local day' ;;
    esac
    if [ "$ST_ATTEMPTS" -ge "$CFG_MAX_ATTEMPTS" ]; then
      # Visible, terminal-for-today failure state. No silent success, no loop.
      printf 'MORNING_INTAKE: %s failed for %s after %s attempts - %s\n' \
        "$CFG_LABEL" "$day" "$ST_ATTEMPTS" "${ST_ERROR:-no report completed}"
      return 0
    fi
  else
    reason='manual --force arm'
  fi

  ST_PHASE=due
  ST_UPDATED=$epoch
  ST_SURFACED=
  save_state
  log_event "armed: $reason"
  enqueue_wake "$day" || die 'could not append the wake record'
  printf 'MORNING_INTAKE: %s due for %s (%s)\n' "$CFG_LABEL" "$day" "$reason"
}

claim_intake() {
  local epoch day
  [ "$#" -eq 0 ] || die 'claim takes no arguments'
  require_enabled
  epoch=$(now_epoch)
  day=$(local_date "$epoch")
  load_state
  [ "$ST_DATE" = "$day" ] || die "no intake is armed for $day; run '$0 run --force' first"
  case "$ST_PHASE" in
    due|failed) ;;
    claimed)
      [ $((epoch - ST_UPDATED)) -ge "$CFG_RETRY_AFTER" ] \
        || die "an intake claim for $day is still active"
      ;;
    *) die "no intake is armed for $day (phase: $ST_PHASE)" ;;
  esac
  [ "$ST_ATTEMPTS" -lt "$CFG_MAX_ATTEMPTS" ] \
    || die "attempt budget exhausted for $day ($ST_ATTEMPTS/$CFG_MAX_ATTEMPTS)"
  ST_ATTEMPTS=$((ST_ATTEMPTS + 1))
  ST_PHASE=claimed
  ST_UPDATED=$epoch
  ST_ERROR=
  ST_SURFACED=
  save_state
  log_event "claimed attempt $ST_ATTEMPTS"
  printf 'local_date: %s\n' "$day"
  printf 'attempt: %s of %s\n' "$ST_ATTEMPTS" "$CFG_MAX_ATTEMPTS"
  printf 'source_watermark: %s\n' "$(read_line_file "$SOURCE_FILE")"
  [ -z "$CFG_REPORT_DIR" ] || printf 'report_dir: %s\n' "$CFG_REPORT_DIR"
}

complete_intake() {
  local report='' watermark='' epoch day
  while [ "$#" -gt 0 ]; do
    case "$1" in
      --report) [ "$#" -ge 2 ] || die '--report requires a value'; report=$2; shift 2 ;;
      --source-watermark) [ "$#" -ge 2 ] || die '--source-watermark requires a value'; watermark=$2; shift 2 ;;
      *) die "unknown complete argument: $1" ;;
    esac
  done
  require_enabled
  [ -n "$report" ] || die '--report is required'
  case "$report" in
    /*) ;;
    *) die "--report must be an absolute path: $report" ;;
  esac
  # The watermark advances only behind a report that actually exists. A partial
  # or aborted intake therefore cannot mark the day done.
  [ -f "$report" ] && [ ! -L "$report" ] || die "report is not a regular file: $report"
  [ -s "$report" ] || die "report is empty: $report"
  if [ -n "$CFG_REPORT_DIR" ]; then
    case "$report" in
      "$CFG_REPORT_DIR"/*) ;;
      *) die "report is outside the configured report_dir: $report" ;;
    esac
  fi
  epoch=$(now_epoch)
  day=$(local_date "$epoch")
  load_state
  [ "$ST_DATE" = "$day" ] || die "no intake is armed for $day"
  [ "$ST_PHASE" = claimed ] || die "complete requires a claimed intake (phase: $ST_PHASE)"

  ST_PHASE=complete
  ST_UPDATED=$epoch
  ST_REPORT=$report
  ST_ERROR=
  save_state
  write_atomic "$PENDING_FILE" "$report" || die 'cannot record the pending report'
  [ -z "$watermark" ] || write_atomic "$SOURCE_FILE" "$watermark" \
    || die 'cannot record the source watermark'
  # Last, and only now: the day is done.
  write_atomic "$COMPLETE_FILE" "$day" || die 'cannot advance the completion watermark'
  log_event "completed with report $report"
  printf 'MORNING_INTAKE: %s complete for %s - report %s\n' "$CFG_LABEL" "$day" "$report"
}

fail_intake() {
  local reason='' epoch day
  while [ "$#" -gt 0 ]; do
    case "$1" in
      --reason) [ "$#" -ge 2 ] || die '--reason requires a value'; reason=$2; shift 2 ;;
      *) die "unknown fail argument: $1" ;;
    esac
  done
  require_enabled
  [ -n "$reason" ] || die '--reason is required'
  epoch=$(now_epoch)
  day=$(local_date "$epoch")
  load_state
  [ "$ST_DATE" = "$day" ] || die "no intake is armed for $day"
  ST_PHASE=failed
  ST_UPDATED=$epoch
  ST_ERROR=$reason
  ST_SURFACED=
  save_state
  log_event "failed: $reason"
  printf 'MORNING_INTAKE: %s failed for %s (attempt %s of %s) - %s\n' \
    "$CFG_LABEL" "$day" "$ST_ATTEMPTS" "$CFG_MAX_ATTEMPTS" "$reason"
}

# Re-arm an already-completed day. This exists for exactly one case: the source
# published a revision after the day's report completed, so the day's content is
# stale even though its watermark is set. Bounded by max_attempts so a revision
# storm cannot loop.
rearm_intake() {
  local reason='' epoch day
  while [ "$#" -gt 0 ]; do
    case "$1" in
      --reason) [ "$#" -ge 2 ] || die '--reason requires a value'; reason=$2; shift 2 ;;
      *) die "unknown rearm argument: $1" ;;
    esac
  done
  require_enabled
  [ -n "$reason" ] || die '--reason is required'
  epoch=$(now_epoch)
  day=$(local_date "$epoch")
  load_state
  [ "$ST_ATTEMPTS" -lt "$CFG_MAX_ATTEMPTS" ] \
    || die "attempt budget exhausted for $day ($ST_ATTEMPTS/$CFG_MAX_ATTEMPTS)"
  ST_DATE=$day
  ST_PHASE=due
  ST_UPDATED=$epoch
  ST_REARMS=$((ST_REARMS + 1))
  ST_ERROR=
  ST_SURFACED=
  save_state
  log_event "rearmed: $reason"
  enqueue_wake "$day" || die 'could not append the wake record'
  printf 'MORNING_INTAKE: %s re-armed for %s - %s\n' "$CFG_LABEL" "$day" "$reason"
}

safe_pending_report() {
  local report
  report=$(read_line_file "$PENDING_FILE")
  [ -n "$report" ] || return 1
  case "$report" in
    /*) ;;
    *) return 1 ;;
  esac
  if [ -n "$CFG_REPORT_DIR" ]; then
    case "$report" in
      "$CFG_REPORT_DIR"/*) ;;
      *) return 1 ;;
    esac
  fi
  [ -f "$report" ] && [ ! -L "$report" ] || return 1
  printf '%s\n' "$report"
}

# Read-only. Prints at most one diagnostic-convention line per condition, and
# nothing at all on a home that is not opted in or has nothing owed.
pending() {
  local report day epoch
  [ "$#" -eq 0 ] || die 'pending takes no arguments'
  enabled || return 0
  load_state
  epoch=$(now_epoch)
  day=$(local_date "$epoch")
  report=$(safe_pending_report 2>/dev/null || true)
  if [ -n "$report" ]; then
    printf 'MORNING_INTAKE: new %s report at %s\n' "$CFG_LABEL" "$report"
  fi
  [ "$ST_DATE" = "$day" ] || return 0
  case "$ST_PHASE" in
    due)
      printf 'MORNING_INTAKE: %s due for %s - claim it with %s claim\n' \
        "$CFG_LABEL" "$day" "$0"
      ;;
    claimed)
      [ $((epoch - ST_UPDATED)) -lt "$CFG_RETRY_AFTER" ] || \
        printf 'MORNING_INTAKE: %s claim for %s stalled after %ss - rerun %s run\n' \
          "$CFG_LABEL" "$day" "$((epoch - ST_UPDATED))" "$0"
      ;;
    failed)
      printf 'MORNING_INTAKE: %s failed for %s (attempt %s of %s) - %s\n' \
        "$CFG_LABEL" "$day" "$ST_ATTEMPTS" "$CFG_MAX_ATTEMPTS" "${ST_ERROR:-unspecified failure}"
      ;;
  esac
}

acknowledge() {
  local expected=${1:-} current
  current=$(safe_pending_report 2>/dev/null || true)
  [ -n "$current" ] || return 0
  if [ -n "$expected" ] && [ "$expected" != "$current" ]; then
    die "pending report changed (current: $current)"
  fi
  rm -f "$PENDING_FILE"
}

# Prints only the declared operating knobs and durable state. No config value
# outside the known-key set can exist, so there is nothing else to withhold.
status_intake() {
  local epoch
  [ "$#" -eq 0 ] || die 'status takes no arguments'
  load_state
  epoch=$(now_epoch)
  printf 'config: %s\n' "$CONFIG_FILE"
  printf 'enabled: %s\n' "$CFG_ENABLED"
  printf 'timezone: %s\n' "${CFG_TIMEZONE:-<host local time>}"
  printf 'start_time: %s\n' "$CFG_START_TIME"
  printf 'interval_seconds: %s\n' "$CFG_INTERVAL"
  printf 'max_attempts: %s\n' "$CFG_MAX_ATTEMPTS"
  printf 'retry_after_seconds: %s\n' "$CFG_RETRY_AFTER"
  printf 'report_dir: %s\n' "${CFG_REPORT_DIR:-<unset>}"
  printf 'label: %s\n' "$CFG_LABEL"
  printf 'local_date_now: %s\n' "$(local_date "$epoch")"
  printf 'last_complete: %s\n' "$(last_complete_date)"
  printf 'source_watermark: %s\n' "$(read_line_file "$SOURCE_FILE")"
  printf 'state_date: %s\n' "$ST_DATE"
  printf 'state_phase: %s\n' "$ST_PHASE"
  printf 'state_attempts: %s\n' "$ST_ATTEMPTS"
  printf 'state_rearms: %s\n' "$ST_REARMS"
  printf 'state_surfaced: %s\n' "$ST_SURFACED"
  printf 'check_armed: %s\n' "$(check_armed_state)"
  printf 'state_report: %s\n' "$ST_REPORT"
  printf 'state_error: %s\n' "$ST_ERROR"
}

reset_intake() {
  [ "$#" -eq 0 ] || die 'reset takes no arguments'
  require_enabled
  load_state
  ST_PHASE=idle
  ST_ATTEMPTS=0
  ST_REARMS=0
  ST_ERROR=
  ST_UPDATED=$(now_epoch)
  save_state
  log_event 'reset attempt budget'
  printf 'reset: %s attempt budget cleared for %s\n' "$CFG_LABEL" "${ST_DATE:-<no armed day>}"
}

# The interval is read by the schedule owner, which must not duplicate parsing.
print_interval() {
  [ "$#" -eq 0 ] || die 'interval takes no arguments'
  printf '%s\n' "$CFG_INTERVAL"
}

load_config

case "${1:-}" in
  run) shift; run_intake "$@" ;;
  claim) shift; claim_intake "$@" ;;
  complete) shift; complete_intake "$@" ;;
  fail) shift; fail_intake "$@" ;;
  rearm) shift; rearm_intake "$@" ;;
  check) shift; check_signal "$@" ;;
  arm-check) shift; arm_check "$@" ;;
  disarm-check) shift; disarm_check "$@" ;;
  pending) shift; pending "$@" ;;
  acknowledge) shift; [ "$#" -le 1 ] || die 'acknowledge accepts at most one report path'; acknowledge "${1:-}" ;;
  status) shift; status_intake "$@" ;;
  reset) shift; reset_intake "$@" ;;
  interval) shift; print_interval "$@" ;;
  -h|--help) usage ;;
  '') usage; exit 2 ;;
  *) die "unknown command: $1" ;;
esac
