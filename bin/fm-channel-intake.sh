#!/usr/bin/env bash
# Continuous channel intake: a local, opt-in ledger and repeat-poll gate.
#
# Usage:
#   fm-channel-intake.sh tick
#   fm-channel-intake.sh claim [--source ID]
#   fm-channel-intake.sh observe --source ID --ref REF (--digest TEXT | --digest-file FILE)
#                                [--class CLASS] [--title TEXT] [--link URL]
#                                [--dedup-key KEY] [--thread PARENT] [--reply-marker VALUE]
#                                [--source-epoch EPOCH]
#   fm-channel-intake.sh complete --source ID --checkpoint VALUE
#   fm-channel-intake.sh fail --source ID --reason TEXT
#   fm-channel-intake.sh resolve --item KEY --reason TEXT [--waiting]
#   fm-channel-intake.sh items [--state open|waiting|archived]
#   fm-channel-intake.sh sources
#   fm-channel-intake.sh notify-due
#   fm-channel-intake.sh notify-sent --keys "KEY [KEY ...]"
#   fm-channel-intake.sh brief [--out FILE]
#   fm-channel-intake.sh todo [--out FILE]
#   fm-channel-intake.sh check
#   fm-channel-intake.sh arm-check
#   fm-channel-intake.sh disarm-check
#   fm-channel-intake.sh pending
#   fm-channel-intake.sh status
#   fm-channel-intake.sh interval
#   fm-channel-intake.sh --help
#
# WHAT THIS IS. A LOCAL GATE AND LEDGER ONLY. It never reads a source system,
# never opens a network connection, never spawns an agent, never sends a
# message, and never takes the per-home session lock or the watcher lock. It
# decides WHEN a source is worth reading, remembers WHAT has already been seen,
# and renders WHAT the captain still owes. An orchestrator does the actual
# connector read through its own authenticated path and reports back here.
#
# This is the repeat-poll sibling of bin/fm-morning-intake.sh. That gate is
# once per local day: after a day completes its `run` returns early, so a short
# scheduler interval only re-checks a satisfied day gate. This gate is per
# source and per interval instead, which is the whole reason it exists rather
# than being a shorter cadence on the morning gate. Everything else - the
# private mutex over its own record, the durable armed state, the single wake
# per armed cycle, the registered watcher check, and the rule that a watermark
# advances only behind captured output - is deliberately the same discipline.
#
# WHAT IT IS NOT. It writes nothing the Action Deck renders. An item classified
# `automation-candidate` is a PROPOSAL in the brief and nothing more: detecting
# that some device or account needs an action grants no permission to perform
# it, and this gate has no path that prepares, stages, or fires one. Executable
# deck cards stay with the action gateway and its per-action approval.
#
# DELIVERY. Two surfaces, both captain-private, neither of them sent from here:
#   `notify-due` renders ONE grouped, rate-limited, quiet-hours-aware private
#   direct-message payload and prints it. It does not send. The orchestrator
#   sends it on the configured recipient and then calls `notify-sent`, which is
#   what actually stamps the items. So an interrupted send re-renders rather
#   than being silently swallowed.
#   `brief` and `todo` render from the ledger every time, so a correction, a
#   resolution and a completed obligation reconcile across both by construction
#   instead of needing a second reconciliation pass.
#
# COVERAGE IS STATED, NEVER IMPLIED. The enrolled sources are exactly the rows
# of the private inventory file, each with its own coverage sentence and its own
# checkpoint. Enrolling some channels does not enrol a workspace. A source whose
# last read failed reports `unknown`, never "nothing new".
#
# TWO DISCLOSED DETECTION LIMITS, both bounded by design and neither hidden:
#   Edit horizon. An in-place edit keeps the original source id, so a forward
#   cursor never returns it again. Re-detection therefore depends on the
#   orchestrator re-reading a bounded recent window (revision_window_seconds)
#   and re-`observe`ing it; the digest comparison here then updates the same
#   item. AN EDIT OLDER THAN THAT WINDOW IS NOT DETECTED. Widening the window
#   costs a proportional re-read on every tick.
#   Thread replies. A cursor read of a channel returns messages whose own id is
#   newer than the cursor, so a reply added to a thread whose parent predates
#   the cursor can appear in no such read. `observe --thread` records a per
#   parent reply marker and `claim` prints the tracked parents back, so the
#   orchestrator can re-read only the threads whose marker advanced. That covers
#   parents still inside the tracked set and NOTHING OLDER. No completeness is
#   claimed. docs/channel-intake.md owns the full statement of both limits.
#
# NO POLL LOOP CAN RUN AWAY. interval_seconds has a hard floor, a failing
# source backs off geometrically to a bounded ceiling instead of retrying
# harder, and `tick` enqueues at most one wake per armed cycle. A throttle
# reported by a connector is a reason to call `fail` and back off, never a
# reason to measure the ceiling by hitting it.
#
# Opt-in is per home and per device: with no `enabled = true` line in private
# config/channel-intake this command is inert, so cloning the repo or seeding
# another home never enrols it.
#
# Configuration lives in private, gitignored config/channel-intake as
# `key = value` lines. Unknown keys are refused rather than ignored, so no
# secret or account path can be parked in this file. Source identities are not
# configuration: they live in the private inventory file below.
#   enabled                  true to arm this home (default false)
#   timezone                 IANA zone for the local day and quiet hours,
#                            refused unless it actually resolves here
#   interval_seconds         per-source poll cadence (default 900, floor 300)
#   sources_file             absolute path to the private inventory
#                            (default data/channel-intake/sources.tsv)
#   revision_window_seconds  bounded edit-detection lookback (default 86400)
#   stale_after_seconds      age at which a source reads stale (default 5400)
#   backoff_seconds          first backoff after a failed read (default 900)
#   backoff_max_seconds      backoff ceiling (default 21600)
#   quiet_start              HH:MM start of local quiet hours (default unset)
#   quiet_end                HH:MM end of local quiet hours (default unset)
#   notify_min_interval_seconds  minimum gap between payloads (default 1800)
#   notify_max_per_day       bounded payloads per local day (default 8)
#   notify_recipient         the private direct-message recipient
#   notify_recipient_verified  true only after the recipient was checked
#                            against the known captain account; notifications
#                            are refused until it is
#   report_dir               directory brief/todo output must be written into
#   label                    slug for the wake key and diagnostic line
#                            (default channel-intake)
set -eu

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$ROOT}}"
CONFIG="${FM_CONFIG_OVERRIDE:-$FM_HOME/config}"
DATA="${FM_DATA_OVERRIDE:-$FM_HOME/data}"
STATE_DIR="${FM_STATE_OVERRIDE:-$FM_HOME/state}"
CONFIG_FILE="$CONFIG/channel-intake"
INTAKE_DIR="$DATA/channel-intake"
SOURCE_DIR="$INTAKE_DIR/sources"
THREAD_DIR="$INTAKE_DIR/threads"
ITEM_DIR="$INTAKE_DIR/items"
ARCHIVE_DIR="$INTAKE_DIR/archive"
NOTIFY_FILE="$INTAKE_DIR/notify-state"
ARMED_FILE="$INTAKE_DIR/armed"
LATENCY_LOG="$INTAKE_DIR/latency.log"
LOG_FILE="$INTAKE_DIR/log"
STATE_LOCK="$INTAKE_DIR/state.lock"

# The floor is a quota guard, not a preference: below it a laptop awake all day
# multiplies every enrolled source by an unbounded call count.
MIN_INTERVAL=300
DEFAULT_INTERVAL=900
DEFAULT_REVISION_WINDOW=86400
DEFAULT_STALE_AFTER=5400
DEFAULT_BACKOFF=900
DEFAULT_BACKOFF_MAX=21600
DEFAULT_NOTIFY_MIN_INTERVAL=1800
DEFAULT_NOTIFY_MAX_PER_DAY=8
DEFAULT_LABEL=channel-intake

# Notifiable classes are the three the captain named. `outage` is the only one
# that survives quiet hours, which is what "preserve real severity" means here.
NOTIFY_CLASSES='urgent outage deadline'
QUIET_BYPASS_CLASSES='outage'
ALL_CLASSES='urgent outage deadline routine obligation automation-candidate'

CFG_ENABLED=false
CFG_TIMEZONE=
CFG_INTERVAL=$DEFAULT_INTERVAL
CFG_SOURCES_FILE=
CFG_REVISION_WINDOW=$DEFAULT_REVISION_WINDOW
CFG_STALE_AFTER=$DEFAULT_STALE_AFTER
CFG_BACKOFF=$DEFAULT_BACKOFF
CFG_BACKOFF_MAX=$DEFAULT_BACKOFF_MAX
CFG_QUIET_START=
CFG_QUIET_END=
CFG_NOTIFY_MIN_INTERVAL=$DEFAULT_NOTIFY_MIN_INTERVAL
CFG_NOTIFY_MAX_PER_DAY=$DEFAULT_NOTIFY_MAX_PER_DAY
CFG_NOTIFY_RECIPIENT=
CFG_NOTIFY_VERIFIED=false
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
  printf 'fm-channel-intake: %s\n' "$*" >&2
  exit 2
}

sanitize() {
  printf '%s' "${1:-}" | LC_ALL=C tr '\t\r\n' '   '
}

# --- configuration ----------------------------------------------------------

require_positive_int() {
  local key=$1 value=$2
  case "$value" in
    ''|*[!0-9]*|0) die "$key must be a positive integer: $value" ;;
  esac
}

require_hhmm() {
  local key=$1 value=$2
  printf '%s\n' "$value" | grep -Eq '^([01][0-9]|2[0-3]):[0-5][0-9]$' \
    || die "$key must be HH:MM in 24-hour form: $value"
}

# Same contract as bin/fm-morning-intake.sh: date(1) treats a zone it cannot
# resolve as UTC and still exits 0, which would silently move both the local
# day and the quiet-hours window.
timezone_resolves() {
  local zone=$1 zonedir=${TZDIR:-/usr/share/zoneinfo} abbrev
  case "$zone" in
    UTC|Etc/UTC|GMT|Etc/GMT|Universal|Zulu) return 0 ;;
  esac
  if [ -d "$zonedir" ]; then
    [ -f "$zonedir/$zone" ]
    return
  fi
  abbrev=$(TZ="$zone" date +%Z 2>/dev/null) || return 1
  case "$abbrev" in
    ''|UTC|GMT|-00|+00) return 1 ;;
  esac
  return 0
}

load_config() {
  local line key value
  CFG_SOURCES_FILE="$INTAKE_DIR/sources.tsv"
  if [ -f "$CONFIG_FILE" ]; then
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
          [ -n "$value" ] || die 'timezone must name an IANA zone'
          case "$value" in
            *[!A-Za-z0-9/_+-]*) die 'timezone contains unsupported characters' ;;
          esac
          timezone_resolves "$value" \
            || die "timezone does not resolve on this host: $value"
          CFG_TIMEZONE=$value
          ;;
        interval_seconds)
          require_positive_int interval_seconds "$value"
          [ "$value" -ge "$MIN_INTERVAL" ] \
            || die "interval_seconds must be at least ${MIN_INTERVAL}s so an awake laptop cannot run an unbounded poll loop: $value"
          CFG_INTERVAL=$value
          ;;
        sources_file)
          case "$value" in
            /*) ;;
            *) die "sources_file must be an absolute path: $value" ;;
          esac
          CFG_SOURCES_FILE=$value
          ;;
        revision_window_seconds)
          require_positive_int revision_window_seconds "$value"; CFG_REVISION_WINDOW=$value ;;
        stale_after_seconds)
          require_positive_int stale_after_seconds "$value"; CFG_STALE_AFTER=$value ;;
        backoff_seconds) require_positive_int backoff_seconds "$value"; CFG_BACKOFF=$value ;;
        backoff_max_seconds)
          require_positive_int backoff_max_seconds "$value"; CFG_BACKOFF_MAX=$value ;;
        quiet_start) require_hhmm quiet_start "$value"; CFG_QUIET_START=$value ;;
        quiet_end) require_hhmm quiet_end "$value"; CFG_QUIET_END=$value ;;
        notify_min_interval_seconds)
          require_positive_int notify_min_interval_seconds "$value"
          CFG_NOTIFY_MIN_INTERVAL=$value ;;
        notify_max_per_day)
          require_positive_int notify_max_per_day "$value"; CFG_NOTIFY_MAX_PER_DAY=$value ;;
        notify_recipient)
          [ -n "$value" ] || die 'notify_recipient must not be empty'
          case "$value" in
            *[[:space:]]*) die "notify_recipient must be a single token: $value" ;;
          esac
          CFG_NOTIFY_RECIPIENT=$value
          ;;
        notify_recipient_verified)
          case "$value" in
            true|false) CFG_NOTIFY_VERIFIED=$value ;;
            *) die "notify_recipient_verified must be true or false: $value" ;;
          esac
          ;;
        report_dir)
          case "$value" in
            /*) ;;
            *) die "report_dir must be an absolute path: $value" ;;
          esac
          CFG_REPORT_DIR=${value%/}
          ;;
        label)
          # Matches bin/fm-pr-lib.sh fm_task_id_path_safe, which the check
          # registration owner enforces; a label accepted here but refused
          # there would arm a shim the watcher rejects on every sweep.
          case "$value" in
            ''|.*|*[!A-Za-z0-9._-]*) die "label must be a leading-dot-free slug of [A-Za-z0-9._-]: $value" ;;
          esac
          CFG_LABEL=$value
          ;;
        *) die "unknown config key: $key" ;;
      esac
    done <"$CONFIG_FILE"
  fi
  [ "$CFG_BACKOFF_MAX" -ge "$CFG_BACKOFF" ] \
    || die "backoff_max_seconds must not be below backoff_seconds"
  if [ -n "$CFG_QUIET_START" ] || [ -n "$CFG_QUIET_END" ]; then
    [ -n "$CFG_QUIET_START" ] && [ -n "$CFG_QUIET_END" ] \
      || die 'quiet_start and quiet_end must be set together'
  fi
}

enabled() {
  [ "$CFG_ENABLED" = true ]
}

require_enabled() {
  enabled || die "this home is not opted in; add 'enabled = true' to $CONFIG_FILE"
}

# --- clock ------------------------------------------------------------------

now_epoch() {
  local value=${FM_CHANNEL_INTAKE_NOW:-}
  if [ -n "$value" ]; then
    case "$value" in
      ''|*[!0-9]*) die "FM_CHANNEL_INTAKE_NOW must be an epoch second: $value" ;;
    esac
    printf '%s\n' "$value"
    return 0
  fi
  date +%s
}

local_fmt() {
  local epoch=$1 fmt=$2
  if [ -n "$CFG_TIMEZONE" ]; then
    TZ="$CFG_TIMEZONE" date -r "$epoch" "+$fmt" 2>/dev/null \
      || TZ="$CFG_TIMEZONE" date -d "@$epoch" "+$fmt" 2>/dev/null \
      || die 'cannot render local time; date(1) supports neither -r nor -d'
  else
    date -r "$epoch" "+$fmt" 2>/dev/null \
      || date -d "@$epoch" "+$fmt" 2>/dev/null \
      || die 'cannot render local time; date(1) supports neither -r nor -d'
  fi
}

local_date() {
  local_fmt "$1" '%Y-%m-%d'
}

# Quiet hours wrap midnight when the end is at or before the start, which is
# the normal overnight case and not an error.
in_quiet_hours() {
  local epoch=$1 hhmm
  [ -n "$CFG_QUIET_START" ] || return 1
  hhmm=$(local_fmt "$epoch" '%H:%M')
  if [ "$CFG_QUIET_START" \< "$CFG_QUIET_END" ]; then
    ! [ "$hhmm" \< "$CFG_QUIET_START" ] && [ "$hhmm" \< "$CFG_QUIET_END" ]
  else
    ! [ "$hhmm" \< "$CFG_QUIET_START" ] || [ "$hhmm" \< "$CFG_QUIET_END" ]
  fi
}

# --- durable record helpers -------------------------------------------------

write_atomic() {
  local dest=$1 value=$2 parent tmp
  parent=${dest%/*}
  mkdir -p "$parent"
  tmp=$(umask 077; mktemp "$parent/.channel-intake.XXXXXX") || return 1
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

# One record reader for every key=value record this gate keeps, so the source,
# item and notify records cannot drift into three parsers.
record_field() {
  local file=$1 key=$2
  [ -f "$file" ] && [ ! -L "$file" ] || return 0
  awk -F= -v k="$key" '
    index($0, k "=") == 1 { print substr($0, length(k) + 2) }
  ' "$file" | tail -n 1
}

digest_hex() {
  local input=$1 out
  if command -v shasum >/dev/null 2>&1; then
    out=$(printf '%s' "$input" | shasum -a 256 2>/dev/null) || return 1
  elif command -v sha256sum >/dev/null 2>&1; then
    out=$(printf '%s' "$input" | sha256sum 2>/dev/null) || return 1
  else
    die 'no sha256 tool available (shasum or sha256sum required)'
  fi
  printf '%s\n' "${out%% *}"
}

# Ids reach paths, so they are constrained the same way the check label is.
require_id() {
  local what=$1 value=$2
  case "$value" in
    ''|.*|*[!A-Za-z0-9._-]*)
      die "$what must be a leading-dot-free slug of [A-Za-z0-9._-]: $value" ;;
  esac
}

require_class() {
  local value=$1 known
  for known in $ALL_CLASSES; do
    [ "$value" != "$known" ] || return 0
  done
  die "unknown class: $value (known: $ALL_CLASSES)"
}

is_notify_class() {
  local value=$1 known
  for known in $NOTIFY_CLASSES; do
    [ "$value" != "$known" ] || return 0
  done
  return 1
}

is_quiet_bypass_class() {
  local value=$1 known
  for known in $QUIET_BYPASS_CLASSES; do
    [ "$value" != "$known" ] || return 0
  done
  return 1
}

WAKE_LIB_LOADED=false

load_wake_lib() {
  if [ "$WAKE_LIB_LOADED" != true ]; then
    # shellcheck source=bin/fm-wake-lib.sh disable=SC1091
    . "$SCRIPT_DIR/fm-wake-lib.sh"
    WAKE_LIB_LOADED=true
  fi
}

# The ledger is read-modify-written by the scheduled `tick`, by the watcher's
# `check`, and by a live orchestrator's `observe`/`complete`, all in separate
# processes. They serialize on a mutex private to this gate's own data
# directory: not the per-home session lock and not the watcher lock, so a live
# fleet is never competed with. The watcher's sweep gets the shorter bound so a
# wedged holder can never eat into FM_CHECK_TIMEOUT.
STATE_LOCK_WAIT=${FM_CHANNEL_INTAKE_LOCK_WAIT:-20}
case "$STATE_LOCK_WAIT" in
  ''|*[!0-9]*|0) die "FM_CHANNEL_INTAKE_LOCK_WAIT must be a positive integer: $STATE_LOCK_WAIT" ;;
esac
CHECK_LOCK_WAIT=$STATE_LOCK_WAIT
[ "$CHECK_LOCK_WAIT" -le 5 ] || CHECK_LOCK_WAIT=5
STATE_LOCK_HELD=false

lock_state() {
  local timeout=$1
  [ "$STATE_LOCK_HELD" != true ] || return 0
  load_wake_lib
  mkdir -p "$INTAKE_DIR"
  fm_lock_acquire_wait "$STATE_LOCK" "$timeout" || return 1
  STATE_LOCK_HELD=true
  trap 'unlock_state' EXIT
}

unlock_state() {
  [ "$STATE_LOCK_HELD" = true ] || return 0
  STATE_LOCK_HELD=false
  fm_lock_release "$STATE_LOCK"
}

require_state_lock() {
  lock_state "$STATE_LOCK_WAIT" \
    || die "another channel-intake command still holds $STATE_LOCK"
}

log_event() {
  mkdir -p "$INTAKE_DIR"
  umask 077
  printf '%s\t%s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$(sanitize "$*")" >>"$LOG_FILE"
}

# --- the private source inventory -------------------------------------------

# Tab-separated, hand-maintained, gitignored, and the ONLY place a channel id,
# mailbox or board id lives. Tracked code reads it; tracked code never contains
# it. Columns: id, kind, coverage sentence. A row is one enrolled source, so
# the file is also the explicit coverage statement.
INVENTORY_IDS=
INVENTORY_LOADED=false

load_inventory() {
  local line id kind coverage
  [ "$INVENTORY_LOADED" != true ] || return 0
  INVENTORY_LOADED=true
  INVENTORY_IDS=
  [ -n "$CFG_SOURCES_FILE" ] || return 0
  [ -f "$CFG_SOURCES_FILE" ] && [ ! -L "$CFG_SOURCES_FILE" ] || return 0
  while IFS= read -r line || [ -n "$line" ]; do
    case "$line" in ''|'#'*) continue ;; esac
    case "$line" in *[![:space:]]*) ;; *) continue ;; esac
    id=$(printf '%s' "$line" | cut -f1)
    kind=$(printf '%s' "$line" | cut -f2)
    coverage=$(printf '%s' "$line" | cut -f3-)
    [ -n "$kind" ] && [ -n "$coverage" ] \
      || die "inventory row must be id<TAB>kind<TAB>coverage: $CFG_SOURCES_FILE"
    require_id 'source id' "$id"
    require_id 'source kind' "$kind"
    INVENTORY_IDS="$INVENTORY_IDS$id
"
  done <"$CFG_SOURCES_FILE"
}

inventory_field() {
  local id=$1 column=$2
  awk -F'\t' -v want="$id" -v col="$column" '
    /^#/ { next }
    $1 == want { print $col; exit }
  ' "$CFG_SOURCES_FILE" 2>/dev/null
}

source_known() {
  local id=$1 known
  load_inventory
  for known in $INVENTORY_IDS; do
    [ "$known" != "$id" ] || return 0
  done
  return 1
}

source_record() {
  printf '%s/%s/state\n' "$SOURCE_DIR" "$1"
}

# `unknown` is the honest reading for a source that has never completed a read
# or whose last read failed. It is never rendered as "nothing new".
source_status() {
  local id=$1 epoch=$2 rec last_ok failures
  rec=$(source_record "$id")
  last_ok=$(record_field "$rec" last_ok)
  failures=$(record_field "$rec" failures)
  case "$failures" in ''|*[!0-9]*) failures=0 ;; esac
  if [ "$failures" -gt 0 ]; then
    printf 'unknown\n'
    return 0
  fi
  case "$last_ok" in
    ''|*[!0-9]*) printf 'unknown\n'; return 0 ;;
  esac
  if [ $((epoch - last_ok)) -gt "$CFG_STALE_AFTER" ]; then
    printf 'stale\n'
  else
    printf 'fresh\n'
  fi
}

source_due() {
  local id=$1 epoch=$2 rec last_attempt backoff_until last_ok
  rec=$(source_record "$id")
  backoff_until=$(record_field "$rec" backoff_until)
  case "$backoff_until" in ''|*[!0-9]*) backoff_until=0 ;; esac
  [ "$epoch" -ge "$backoff_until" ] || return 1
  last_ok=$(record_field "$rec" last_ok)
  last_attempt=$(record_field "$rec" last_attempt)
  case "$last_ok" in ''|*[!0-9]*) last_ok=0 ;; esac
  case "$last_attempt" in ''|*[!0-9]*) last_attempt=0 ;; esac
  [ "$last_attempt" -ge "$last_ok" ] || last_attempt=$last_ok
  [ $((epoch - last_attempt)) -ge "$CFG_INTERVAL" ]
}

save_source() {
  local id=$1 checkpoint=$2 last_ok=$3 last_attempt=$4 failures=$5 backoff_until=$6 error=$7
  local body
  body=$(printf 'id=%s\ncheckpoint=%s\nlast_ok=%s\nlast_attempt=%s\nfailures=%s\nbackoff_until=%s\nerror=%s' \
    "$id" "$(sanitize "$checkpoint")" "$last_ok" "$last_attempt" "$failures" \
    "$backoff_until" "$(sanitize "$error")")
  mkdir -p "$SOURCE_DIR/$id"
  write_atomic "$(source_record "$id")" "$body" || die "cannot write the source record for $id"
}

# --- items ------------------------------------------------------------------

item_path() {
  printf '%s/%s\n' "$ITEM_DIR" "$1"
}

archive_path() {
  printf '%s/%s\n' "$ARCHIVE_DIR" "$1"
}

item_key() {
  local dedup=$1 source=$2 ref=$3
  if [ -n "$dedup" ]; then
    digest_hex "dedup:$dedup"
  else
    digest_hex "src:$source:$ref"
  fi
}

save_item() {
  local path=$1
  shift
  write_atomic "$path" "$*" || die "cannot write the item record: $path"
}

item_body() {
  printf 'key=%s\nsource=%s\nkind=%s\nref=%s\nlink=%s\nclass=%s\ntitle=%s\ndigest=%s\nstate=%s\ncreated=%s\nupdated=%s\nsource_epoch=%s\nnotified=%s\nnotified_digest=%s\nrevisions=%s\nprovenance=%s\nresolution=%s\nresolved_at=%s' \
    "$1" "$2" "$3" "$4" "$(sanitize "$5")" "$6" "$(sanitize "$7")" "$8" "$9" \
    "${10}" "${11}" "${12}" "${13}" "${14}" "${15}" "$(sanitize "${16}")" \
    "$(sanitize "${17}")" "${18}"
}

# --- wake delivery ----------------------------------------------------------

enqueue_wake() {
  local payload=$1
  load_wake_lib
  fm_wake_append check "$CFG_LABEL" "$payload"
}

# --- live-session delivery: the registered watcher check ---------------------

check_path() {
  printf '%s/%s.check.sh\n' "$STATE_DIR" "$CFG_LABEL"
}

CHECK_LIB_LOADED=false

load_check_lib() {
  if [ "$CHECK_LIB_LOADED" != true ]; then
    # shellcheck source=bin/fm-pr-lib.sh disable=SC1091
    . "$SCRIPT_DIR/fm-pr-lib.sh"
    # shellcheck source=bin/fm-check-lib.sh disable=SC1091
    . "$SCRIPT_DIR/fm-check-lib.sh"
    CHECK_LIB_LOADED=true
  fi
}

check_armed_state() {
  local check
  check=$(check_path)
  if [ ! -e "$check" ] && [ ! -L "$check" ]; then
    printf 'absent\n'
    return 0
  fi
  load_check_lib
  if fm_custom_check_registered "$STATE_DIR" "$CFG_LABEL" 2>/dev/null; then
    printf 'armed\n'
  else
    printf 'unregistered\n'
  fi
}

render_check_shim() {
  cat <<SHIM
#!/usr/bin/env bash
# Generated by bin/fm-channel-intake.sh arm-check. Do not edit; re-arm instead.
set -eu
FM_HOME='$FM_HOME' FM_ROOT_OVERRIDE='$ROOT' exec '$SCRIPT_DIR/fm-channel-intake.sh' check
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
  tmp=$(mktemp "$STATE_DIR/.channel-intake-check.XXXXXX") || die 'cannot stage the check shim'
  render_check_shim >"$tmp" || { rm -f "$tmp"; die 'cannot write the check shim'; }
  chmod 0700 "$tmp" || { rm -f "$tmp"; die 'cannot set check shim mode'; }
  mv -f "$tmp" "$check" || { rm -f "$tmp"; die "cannot install the check shim: $check"; }
  # Arming is all-or-nothing for the same reason the morning gate's is: an
  # unregistered shim left in state/ is worse than no shim, because the watcher
  # rejects it and wakes the primary about it on every sweep.
  if ! "$SCRIPT_DIR/fm-check-register.sh" "$CFG_LABEL"; then
    rm -f -- "$check" 2>/dev/null || true
    rm -f -- "$STATE_DIR/$CFG_LABEL.check-trust" 2>/dev/null || true
    [ ! -e "$check" ] \
      || die "check registration failed and the shim could not be removed: $check"
    die "check registration failed for $CFG_LABEL"
  fi
}

disarm_check() {
  local check
  [ "$#" -eq 0 ] || die 'disarm-check takes no arguments'
  check=$(check_path)
  rm -f "$check" "$STATE_DIR/$CFG_LABEL.check-trust"
  printf 'disarmed: %s\n' "$check"
}

# --- tick -------------------------------------------------------------------

due_source_ids() {
  local epoch=$1 id
  load_inventory
  for id in $INVENTORY_IDS; do
    if source_due "$id" "$epoch"; then
      printf '%s\n' "$id"
    fi
  done
  return 0
}

# The most recent read attempt across every enrolled source. It only ever moves
# forward, because `claim`, `complete` and `fail` all stamp the current epoch,
# so it is the monotonic term a suppression signature needs to tell a genuinely
# recurring condition apart from one already surfaced.
last_attempt_watermark() {
  local id watermark=0 value
  load_inventory
  for id in $INVENTORY_IDS; do
    value=$(record_field "$(source_record "$id")" last_attempt)
    case "$value" in ''|*[!0-9]*) continue ;; esac
    [ "$value" -le "$watermark" ] || watermark=$value
  done
  printf '%s\n' "$watermark"
}

# The scheduled entry point. It decides only WHETHER a read is worth doing and
# records that decision; it reads nothing itself. One wake per armed cycle: the
# armed marker is cleared by `complete`/`fail` on the last due source, so a
# repeat tick over an already-armed cycle stays silent.
tick() {
  local epoch due count armed payload
  [ "$#" -eq 0 ] || die 'tick takes no arguments'
  enabled || return 0
  epoch=$(now_epoch)
  require_state_lock
  due=$(due_source_ids "$epoch")
  count=$(printf '%s' "$due" | grep -c '[^[:space:]]' || true)
  if [ "$count" -eq 0 ]; then
    return 0
  fi
  armed=$(read_line_file "$ARMED_FILE")
  case "$armed" in
    ''|*[!0-9]*) armed=0 ;;
  esac
  # One wake per armed cycle. `claim`, `complete` and `fail` all clear the
  # marker, so a worked cycle re-arms normally. An armed cycle nobody ever took
  # re-arms once its wake is older than the staleness bound, which keeps a lost
  # wake recoverable without turning the marker into a per-tick reminder.
  if [ "$armed" -gt 0 ] && [ $((epoch - armed)) -lt "$CFG_STALE_AFTER" ]; then
    return 0
  fi
  write_atomic "$ARMED_FILE" "$epoch" || die 'cannot record the armed cycle'
  payload="$CFG_LABEL has $count source(s) due; take them with '$0 claim'"
  log_event "armed: $count source(s) due"
  enqueue_wake "$payload" || die 'could not append the wake record'
  printf 'CHANNEL_INTAKE: %s source(s) due for %s\n' "$count" "$CFG_LABEL"
}

# --- claim / complete / fail ------------------------------------------------

claim() {
  local want='' epoch id due any=false parent marker rec
  while [ "$#" -gt 0 ]; do
    case "$1" in
      --source) [ "$#" -ge 2 ] || die '--source requires a value'; want=$2; shift 2 ;;
      *) die "unknown claim argument: $1" ;;
    esac
  done
  require_enabled
  epoch=$(now_epoch)
  require_state_lock
  load_inventory
  if [ -n "$want" ]; then
    require_id 'source id' "$want"
    source_known "$want" || die "source is not in the inventory: $want"
    due=$want
  else
    due=$(due_source_ids "$epoch")
  fi
  printf 'now: %s\n' "$epoch"
  printf 'revision_window_seconds: %s\n' "$CFG_REVISION_WINDOW"
  printf 'revision_window_from: %s\n' "$((epoch - CFG_REVISION_WINDOW))"
  for id in $due; do
    any=true
    printf 'source: %s\tkind: %s\tcheckpoint: %s\tcoverage: %s\n' \
      "$id" "$(inventory_field "$id" 2)" \
      "$(record_field "$(source_record "$id")" checkpoint)" \
      "$(inventory_field "$id" 3)"
    # Tracked thread parents, so the orchestrator can re-read only the threads
    # whose reply marker advanced instead of re-reading every thread.
    if [ -d "$THREAD_DIR/$id" ]; then
      for parent in "$THREAD_DIR/$id"/*; do
        [ -f "$parent" ] || continue
        marker=$(read_line_file "$parent")
        printf 'thread: %s\t%s\t%s\n' "$id" "${parent##*/}" "$marker"
      done
    fi
    # An attempt is recorded before the read, so a read that never reports back
    # still spends its slot and cannot be retried in a tight loop.
    rec=$(source_record "$id")
    save_source "$id" "$(record_field "$rec" checkpoint)" \
      "$(record_field "$rec" last_ok)" "$epoch" \
      "$(record_field "$rec" failures)" "$(record_field "$rec" backoff_until)" \
      "$(record_field "$rec" error)"
  done
  rm -f "$ARMED_FILE"
  [ "$any" = true ] || printf 'source: <none due>\n'
}

complete_source() {
  local id='' checkpoint='' epoch
  while [ "$#" -gt 0 ]; do
    case "$1" in
      --source) [ "$#" -ge 2 ] || die '--source requires a value'; id=$2; shift 2 ;;
      --checkpoint) [ "$#" -ge 2 ] || die '--checkpoint requires a value'; checkpoint=$2; shift 2 ;;
      *) die "unknown complete argument: $1" ;;
    esac
  done
  require_enabled
  [ -n "$id" ] || die '--source is required'
  require_id 'source id' "$id"
  [ -n "$checkpoint" ] || die '--checkpoint is required'
  source_known "$id" || die "source is not in the inventory: $id"
  epoch=$(now_epoch)
  require_state_lock
  # The checkpoint advances ONLY here, and only on a read the orchestrator has
  # already captured. An interrupted read leaves the old checkpoint, so the
  # next tick re-reads that window instead of skipping it.
  save_source "$id" "$checkpoint" "$epoch" "$epoch" 0 0 ''
  clear_armed_if_settled
  log_event "source $id complete at checkpoint $checkpoint"
  printf 'CHANNEL_INTAKE: %s read complete, checkpoint %s\n' "$id" "$checkpoint"
}

fail_source() {
  local id='' reason='' epoch rec failures backoff
  while [ "$#" -gt 0 ]; do
    case "$1" in
      --source) [ "$#" -ge 2 ] || die '--source requires a value'; id=$2; shift 2 ;;
      --reason) [ "$#" -ge 2 ] || die '--reason requires a value'; reason=$2; shift 2 ;;
      *) die "unknown fail argument: $1" ;;
    esac
  done
  require_enabled
  [ -n "$id" ] || die '--source is required'
  require_id 'source id' "$id"
  [ -n "$reason" ] || die '--reason is required'
  source_known "$id" || die "source is not in the inventory: $id"
  epoch=$(now_epoch)
  require_state_lock
  rec=$(source_record "$id")
  failures=$(record_field "$rec" failures)
  case "$failures" in ''|*[!0-9]*) failures=0 ;; esac
  failures=$((failures + 1))
  # Geometric backoff to a bounded ceiling. A throttle is a reason to read less
  # often, never to retry harder, and the ceiling means a permanently broken
  # source settles into a cheap heartbeat instead of a loop.
  backoff=$CFG_BACKOFF
  local n=1
  while [ "$n" -lt "$failures" ] && [ "$backoff" -lt "$CFG_BACKOFF_MAX" ]; do
    backoff=$((backoff * 2))
    n=$((n + 1))
  done
  [ "$backoff" -le "$CFG_BACKOFF_MAX" ] || backoff=$CFG_BACKOFF_MAX
  # last_ok is deliberately NOT advanced: the checkpoint and the freshness
  # reading both stay where the last captured read left them.
  save_source "$id" "$(record_field "$rec" checkpoint)" \
    "$(record_field "$rec" last_ok)" "$epoch" "$failures" "$((epoch + backoff))" "$reason"
  clear_armed_if_settled
  log_event "source $id failed ($failures): $reason"
  printf 'CHANNEL_INTAKE: %s read failed (%s consecutive), backing off %ss - %s\n' \
    "$id" "$failures" "$backoff" "$reason"
}

# A reported read settles the cycle, whether it succeeded or failed. Leaving
# the marker in place would suppress the next genuine wake.
clear_armed_if_settled() {
  rm -f "$ARMED_FILE"
}

# --- observe ----------------------------------------------------------------

# The one entry point for "the orchestrator saw this". Idempotent by content:
# the same content reported twice is `unchanged` and produces no second item and
# no second notification, which is what makes an unchanged poll silent.
observe() {
  local id='' ref='' digest_in='' digest_file='' class=routine title='' link=''
  local dedup='' thread='' marker='' source_epoch='' epoch key path digest
  local existing_digest existing_state created revisions provenance notified
  local notified_digest kind outcome prov_tag
  while [ "$#" -gt 0 ]; do
    case "$1" in
      --source) [ "$#" -ge 2 ] || die '--source requires a value'; id=$2; shift 2 ;;
      --ref) [ "$#" -ge 2 ] || die '--ref requires a value'; ref=$2; shift 2 ;;
      --digest) [ "$#" -ge 2 ] || die '--digest requires a value'; digest_in=$2; shift 2 ;;
      --digest-file) [ "$#" -ge 2 ] || die '--digest-file requires a value'; digest_file=$2; shift 2 ;;
      --class) [ "$#" -ge 2 ] || die '--class requires a value'; class=$2; shift 2 ;;
      --title) [ "$#" -ge 2 ] || die '--title requires a value'; title=$2; shift 2 ;;
      --link) [ "$#" -ge 2 ] || die '--link requires a value'; link=$2; shift 2 ;;
      --dedup-key) [ "$#" -ge 2 ] || die '--dedup-key requires a value'; dedup=$2; shift 2 ;;
      --thread) [ "$#" -ge 2 ] || die '--thread requires a value'; thread=$2; shift 2 ;;
      --reply-marker) [ "$#" -ge 2 ] || die '--reply-marker requires a value'; marker=$2; shift 2 ;;
      --source-epoch) [ "$#" -ge 2 ] || die '--source-epoch requires a value'; source_epoch=$2; shift 2 ;;
      *) die "unknown observe argument: $1" ;;
    esac
  done
  require_enabled
  [ -n "$id" ] || die '--source is required'
  require_id 'source id' "$id"
  [ -n "$ref" ] || die '--ref is required'
  # A ref is hashed into the item key and never becomes a path, so it only has
  # to be a single-line token; a Gmail message id is not a filename slug.
  case "$ref" in
    *[[:space:]]*) die "--ref must be a single whitespace-free token: $ref" ;;
  esac
  source_known "$id" || die "source is not in the inventory: $id"
  require_class "$class"
  if [ -n "$digest_file" ]; then
    [ -z "$digest_in" ] || die 'pass --digest or --digest-file, not both'
    [ -f "$digest_file" ] && [ ! -L "$digest_file" ] \
      || die "--digest-file is not a regular file: $digest_file"
    # Content never lands in the ledger, only its hash: customer text and
    # private message bodies stay in the source system.
    digest_in=$(digest_hex "$(cat "$digest_file")")
  fi
  [ -n "$digest_in" ] || die '--digest or --digest-file is required'
  case "$source_epoch" in
    '') ;;
    *[!0-9]*) die "--source-epoch must be an epoch second: $source_epoch" ;;
  esac
  epoch=$(now_epoch)
  require_state_lock
  digest=$(digest_hex "$digest_in")
  key=$(item_key "$dedup" "$id" "$ref")
  kind=$(inventory_field "$id" 2)
  prov_tag="$id:$ref"

  if [ -n "$thread" ]; then
    require_id 'thread parent' "$thread"
    mkdir -p "$THREAD_DIR/$id"
    write_atomic "$THREAD_DIR/$id/$thread" "${marker:-$ref}" \
      || die 'cannot record the thread reply marker'
  fi

  # A resolved ask is never reopened from here. A reaction or an unchanged
  # re-read is silent, and even a genuine later edit only annotates the archive
  # so the brief can mention it; reopening is a captain decision, not a poll's.
  if [ -f "$(archive_path "$key")" ]; then
    path=$(archive_path "$key")
    existing_digest=$(record_field "$path" digest)
    if [ "$existing_digest" = "$digest" ]; then
      printf 'archived-unchanged %s\n' "$key"
    else
      printf 'archived-changed %s\n' "$key"
      log_event "archived item $key changed after resolution"
    fi
    return 0
  fi

  path=$(item_path "$key")
  if [ -f "$path" ]; then
    existing_digest=$(record_field "$path" digest)
    existing_state=$(record_field "$path" state)
    created=$(record_field "$path" created)
    revisions=$(record_field "$path" revisions)
    provenance=$(record_field "$path" provenance)
    notified=$(record_field "$path" notified)
    notified_digest=$(record_field "$path" notified_digest)
    case "$revisions" in ''|*[!0-9]*) revisions=0 ;; esac
    # Whole-token membership: provenance is space-separated `id:ref`, and an
    # unanchored match would drop a new tag whose ref is a prefix of a
    # recorded one on the same source.
    case " $provenance " in
      *" $prov_tag "*) ;;
      # A cross-source duplicate keeps every source's provenance and stays ONE
      # item: it never becomes a second task.
      *) provenance="$provenance $prov_tag"; outcome=merged ;;
    esac
    if [ "$existing_digest" = "$digest" ]; then
      # Unchanged content. Provenance may still have grown, so the record is
      # rewritten, but nothing about the item's attention state moves.
      save_item "$path" "$(item_body "$key" "$id" "$kind" "$ref" \
        "$(record_field "$path" link)" "$(record_field "$path" class)" \
        "$(record_field "$path" title)" "$digest" "$existing_state" "$created" \
        "$(record_field "$path" updated)" "$(record_field "$path" source_epoch)" \
        "$notified" "$notified_digest" "$revisions" "$provenance" \
        "$(record_field "$path" resolution)" "$(record_field "$path" resolved_at)")"
      printf '%s %s\n' "${outcome:-unchanged}" "$key"
      return 0
    fi
    # A correction updates the SAME item rather than creating a second one.
    revisions=$((revisions + 1))
    save_item "$path" "$(item_body "$key" "$id" "$kind" "$ref" \
      "${link:-$(record_field "$path" link)}" "$class" \
      "${title:-$(record_field "$path" title)}" "$digest" "$existing_state" \
      "$created" "$epoch" "${source_epoch:-$(record_field "$path" source_epoch)}" \
      "$notified" "$notified_digest" "$revisions" "$provenance" \
      "$(record_field "$path" resolution)" "$(record_field "$path" resolved_at)")"
    log_event "item $key updated (revision $revisions)"
    printf 'updated %s\n' "$key"
    return 0
  fi

  save_item "$path" "$(item_body "$key" "$id" "$kind" "$ref" "$link" "$class" \
    "$title" "$digest" open "$epoch" "$epoch" "$source_epoch" '' '' 0 "$prov_tag" '' '')"
  if [ -n "$source_epoch" ] && [ "$epoch" -ge "$source_epoch" ]; then
    # Measured detection latency, sampled from real runs rather than projected
    # from the poll interval, which is a target and not an upper bound.
    mkdir -p "$INTAKE_DIR"
    umask 077
    printf '%s\t%s\t%s\n' "$epoch" "$id" "$((epoch - source_epoch))" >>"$LATENCY_LOG"
  fi
  log_event "item $key opened from $prov_tag as $class"
  printf 'new %s\n' "$key"
}

# --- resolution -------------------------------------------------------------

# An obligation is discharged by content, not by the fact that somebody replied.
# `--waiting` is the honest middle state for "handed to someone else": it leaves
# the item on the ledger under waiting-on-others rather than clearing it.
resolve_item() {
  local key='' reason='' waiting=false epoch path dest
  while [ "$#" -gt 0 ]; do
    case "$1" in
      --item) [ "$#" -ge 2 ] || die '--item requires a value'; key=$2; shift 2 ;;
      --reason) [ "$#" -ge 2 ] || die '--reason requires a value'; reason=$2; shift 2 ;;
      --waiting) waiting=true; shift ;;
      *) die "unknown resolve argument: $1" ;;
    esac
  done
  require_enabled
  [ -n "$key" ] || die '--item is required'
  require_id 'item key' "$key"
  [ -n "$reason" ] || die '--reason is required'
  epoch=$(now_epoch)
  require_state_lock
  path=$(item_path "$key")
  [ -f "$path" ] || die "no open item with that key: $key"
  if [ "$waiting" = true ]; then
    save_item "$path" "$(item_body "$key" "$(record_field "$path" source)" \
      "$(record_field "$path" kind)" "$(record_field "$path" ref)" \
      "$(record_field "$path" link)" "$(record_field "$path" class)" \
      "$(record_field "$path" title)" "$(record_field "$path" digest)" waiting \
      "$(record_field "$path" created)" "$epoch" \
      "$(record_field "$path" source_epoch)" "$(record_field "$path" notified)" \
      "$(record_field "$path" notified_digest)" "$(record_field "$path" revisions)" \
      "$(record_field "$path" provenance)" "$reason" '')"
    log_event "item $key moved to waiting-on-others: $reason"
    printf 'waiting %s\n' "$key"
    return 0
  fi
  # Archived, not deleted: the item leaves the active list and its evidence -
  # source, ref, link, provenance, revision count - is preserved verbatim.
  mkdir -p "$ARCHIVE_DIR"
  dest=$(archive_path "$key")
  save_item "$dest" "$(item_body "$key" "$(record_field "$path" source)" \
    "$(record_field "$path" kind)" "$(record_field "$path" ref)" \
    "$(record_field "$path" link)" "$(record_field "$path" class)" \
    "$(record_field "$path" title)" "$(record_field "$path" digest)" archived \
    "$(record_field "$path" created)" "$epoch" \
    "$(record_field "$path" source_epoch)" "$(record_field "$path" notified)" \
    "$(record_field "$path" notified_digest)" "$(record_field "$path" revisions)" \
    "$(record_field "$path" provenance)" "$reason" "$epoch")"
  rm -f "$path"
  log_event "item $key archived: $reason"
  printf 'archived %s\n' "$key"
}

# --- listing ----------------------------------------------------------------

for_each_item() {
  local dir=$1 f
  [ -d "$dir" ] || return 0
  for f in "$dir"/*; do
    [ -f "$f" ] || continue
    printf '%s\n' "$f"
  done
}

count_items_in_state() {
  local dir=$1 want=$2 f n=0
  for f in $(for_each_item "$dir"); do
    [ "$(record_field "$f" state)" = "$want" ] || continue
    n=$((n + 1))
  done
  printf '%s\n' "$n"
}

items_cmd() {
  local want='' f state
  while [ "$#" -gt 0 ]; do
    case "$1" in
      --state) [ "$#" -ge 2 ] || die '--state requires a value'; want=$2; shift 2 ;;
      *) die "unknown items argument: $1" ;;
    esac
  done
  case "$want" in
    ''|open|waiting|archived) ;;
    *) die "unknown state: $want" ;;
  esac
  {
    for_each_item "$ITEM_DIR"
    case "$want" in
      open|waiting) ;;
      *) for_each_item "$ARCHIVE_DIR" ;;
    esac
  } | while IFS= read -r f; do
    state=$(record_field "$f" state)
    [ -z "$want" ] || [ "$want" = "$state" ] || continue
    printf '%s\t%s\t%s\t%s\t%s\n' "$(record_field "$f" key)" "$state" \
      "$(record_field "$f" class)" "$(record_field "$f" source)" \
      "$(record_field "$f" title)"
  done
}

sources_cmd() {
  local epoch id rec
  [ "$#" -eq 0 ] || die 'sources takes no arguments'
  epoch=$(now_epoch)
  load_inventory
  if [ -z "$INVENTORY_IDS" ]; then
    printf 'sources: <none enrolled>\tinventory: %s\n' "$CFG_SOURCES_FILE"
    return 0
  fi
  for id in $INVENTORY_IDS; do
    rec=$(source_record "$id")
    printf '%s\t%s\t%s\tcheckpoint=%s\tlast_ok=%s\tfailures=%s\t%s\n' \
      "$id" "$(inventory_field "$id" 2)" "$(source_status "$id" "$epoch")" \
      "$(record_field "$rec" checkpoint)" "$(record_field "$rec" last_ok)" \
      "$(record_field "$rec" failures)" "$(inventory_field "$id" 3)"
  done
}

# --- notification -------------------------------------------------------------

notify_field() {
  record_field "$NOTIFY_FILE" "$1"
}

# Payloads already sent today, reset by the local day rather than a rolling
# window so the daily cap means what the captain would read it to mean.
notify_today_count() {
  local epoch=$1 day sent
  day=$(local_date "$epoch")
  sent=$(notify_field count)
  case "$sent" in ''|*[!0-9]*) sent=0 ;; esac
  [ "$(notify_field day)" = "$day" ] || sent=0
  printf '%s\n' "$sent"
}

save_notify() {
  local last=$1 day=$2 count=$3
  write_atomic "$NOTIFY_FILE" "$(printf 'last=%s\nday=%s\ncount=%s' "$last" "$day" "$count")" \
    || die 'cannot write the notification record'
}

# An item is notifiable when it is open, in a notifiable class, and either has
# never been notified or its content changed since the notification that went
# out. That last clause is what makes an edit re-notify exactly once and an
# unchanged poll never re-notify at all.
notifiable_items() {
  local quiet=$1 f class notified notified_digest digest
  for f in $(for_each_item "$ITEM_DIR"); do
    [ "$(record_field "$f" state)" = open ] || continue
    class=$(record_field "$f" class)
    is_notify_class "$class" || continue
    if [ "$quiet" = true ]; then
      is_quiet_bypass_class "$class" || continue
    fi
    notified=$(record_field "$f" notified)
    notified_digest=$(record_field "$f" notified_digest)
    digest=$(record_field "$f" digest)
    if [ -n "$notified" ] && [ "$notified_digest" = "$digest" ]; then
      continue
    fi
    printf '%s\n' "$f"
  done
}

# The ONE decision for "can a payload go out right now, and if not, why not".
# It prints `<state> <count>` and nothing else: `notify-due` renders from it,
# and `pending`, `check` and `status` report it. Scraping the rendered payload
# instead collapsed every refusal and every suppression into the same silence
# as "nothing to send", which is precisely what a blocked alert must not do.
#   none          nothing is notifiable right now
#   unconfigured  no recipient is configured
#   unverified    the recipient was never checked against the captain account
#   capped        the bounded payloads for this local day are spent
#   spaced        the minimum gap since the last payload has not elapsed
#   ready         a payload can be rendered and sent
notify_state() {
  local epoch=$1 day quiet=false files count last lastday sent f bypass=false
  enabled || { printf 'none 0\n'; return 0; }
  day=$(local_date "$epoch")
  ! in_quiet_hours "$epoch" || quiet=true
  files=$(notifiable_items "$quiet")
  count=$(printf '%s' "$files" | grep -c '[^[:space:]]' || true)
  if [ "$count" -eq 0 ]; then
    printf 'none 0\n'
    return 0
  fi
  # The recipient is checked against the known captain account BEFORE any
  # payload can be rendered for it. Standing scope covers private alerts to the
  # captain and nobody else, so an unverified recipient is a refusal.
  if [ -z "$CFG_NOTIFY_RECIPIENT" ]; then
    printf 'unconfigured %s\n' "$count"
    return 0
  fi
  if [ "$CFG_NOTIFY_VERIFIED" != true ]; then
    printf 'unverified %s\n' "$count"
    return 0
  fi
  for f in $files; do
    if is_quiet_bypass_class "$(record_field "$f" class)"; then
      bypass=true
    fi
  done
  last=$(notify_field last)
  lastday=$(notify_field day)
  sent=$(notify_field count)
  case "$last" in ''|*[!0-9]*) last=0 ;; esac
  case "$sent" in ''|*[!0-9]*) sent=0 ;; esac
  [ "$lastday" = "$day" ] || sent=0
  if [ "$sent" -ge "$CFG_NOTIFY_MAX_PER_DAY" ]; then
    printf 'capped %s\n' "$count"
    return 0
  fi
  if [ "$bypass" != true ] && [ $((epoch - last)) -lt "$CFG_NOTIFY_MIN_INTERVAL" ]; then
    printf 'spaced %s\n' "$count"
    return 0
  fi
  printf 'ready %s\n' "$count"
}

notify_state_count() {
  local count=${1##* }
  case "$count" in ''|*[!0-9]*) count=0 ;; esac
  printf '%s\n' "$count"
}

# How a state that is neither `ready` nor empty reads on a captain-facing
# surface, so a cap or a refusal is visible instead of looking like quiet.
notify_state_phrase() {
  case "$1" in
    unconfigured) printf 'blocked, notify_recipient is not configured\n' ;;
    unverified) printf 'blocked, notify_recipient_verified is not true\n' ;;
    capped) printf 'held, the daily notification cap is spent\n' ;;
    spaced) printf 'held, the minimum gap since the last payload has not elapsed\n' ;;
    *) printf 'ready to send\n' ;;
  esac
}

# Renders. Does NOT send: sending is the orchestrator's authenticated path, and
# the items are only stamped once it confirms with `notify-sent`, so an
# interrupted send re-renders instead of vanishing.
notify_due() {
  local epoch quiet=false files count state f
  [ "$#" -eq 0 ] || die 'notify-due takes no arguments'
  enabled || return 0
  epoch=$(now_epoch)
  state=$(notify_state "$epoch")
  case "${state%% *}" in
    none) return 0 ;;
    unconfigured) die "notify_recipient is not configured in $CONFIG_FILE" ;;
    unverified)
      die "notify_recipient_verified is not true in $CONFIG_FILE; verify the recipient against the known captain account before enabling notifications" ;;
    # Nothing is lost: the items stay notifiable and `pending`/`status` report
    # the suppression, so a cap is visible rather than silent.
    capped|spaced) return 0 ;;
  esac
  ! in_quiet_hours "$epoch" || quiet=true
  files=$(notifiable_items "$quiet")
  count=$(notify_state_count "$state")
  printf 'recipient: %s\n' "$CFG_NOTIFY_RECIPIENT"
  printf 'items: %s\n' "$count"
  printf 'keys: %s\n' "$(for f in $files; do printf '%s ' "$(record_field "$f" key)"; done)"
  printf -- '---\n'
  printf 'Intake needs you (%s):\n' "$count"
  for f in $files; do
    printf -- '- [%s] %s%s\n' "$(record_field "$f" class)" \
      "$(record_field "$f" title)" \
      "$([ -z "$(record_field "$f" link)" ] || printf ' %s' "$(record_field "$f" link)")"
  done
  printf 'Full brief: %s brief\n' "$0"
}

notify_sent() {
  local keys='' epoch day key path sent lastday
  while [ "$#" -gt 0 ]; do
    case "$1" in
      --keys) [ "$#" -ge 2 ] || die '--keys requires a value'; keys=$2; shift 2 ;;
      *) die "unknown notify-sent argument: $1" ;;
    esac
  done
  require_enabled
  [ -n "$keys" ] || die '--keys is required'
  epoch=$(now_epoch)
  day=$(local_date "$epoch")
  require_state_lock
  for key in $keys; do
    require_id 'item key' "$key"
    path=$(item_path "$key")
    [ -f "$path" ] || die "no open item with that key: $key"
    save_item "$path" "$(item_body "$key" "$(record_field "$path" source)" \
      "$(record_field "$path" kind)" "$(record_field "$path" ref)" \
      "$(record_field "$path" link)" "$(record_field "$path" class)" \
      "$(record_field "$path" title)" "$(record_field "$path" digest)" \
      "$(record_field "$path" state)" "$(record_field "$path" created)" \
      "$(record_field "$path" updated)" "$(record_field "$path" source_epoch)" \
      "$epoch" "$(record_field "$path" digest)" "$(record_field "$path" revisions)" \
      "$(record_field "$path" provenance)" "$(record_field "$path" resolution)" \
      "$(record_field "$path" resolved_at)")"
  done
  lastday=$(notify_field day)
  sent=$(notify_field count)
  case "$sent" in ''|*[!0-9]*) sent=0 ;; esac
  [ "$lastday" = "$day" ] || sent=0
  save_notify "$epoch" "$day" "$((sent + 1))"
  log_event "notification delivered for: $keys"
  printf 'CHANNEL_INTAKE: notification recorded for %s item(s)\n' \
    "$(printf '%s' "$keys" | wc -w | tr -d ' ')"
}

# --- rendered surfaces --------------------------------------------------------

resolve_out() {
  local out=$1
  [ -n "$out" ] || return 0
  case "$out" in
    /*) ;;
    *) die "--out must be an absolute path: $out" ;;
  esac
  if [ -n "$CFG_REPORT_DIR" ]; then
    case "$out" in
      "$CFG_REPORT_DIR"/*) ;;
      *) die "--out is outside the configured report_dir: $out" ;;
    esac
  fi
}

section_items() {
  local want_state=$1 epoch=$2 f class state found=false
  shift 2
  for f in $(for_each_item "$ITEM_DIR"); do
    state=$(record_field "$f" state)
    class=$(record_field "$f" class)
    [ "$state" = "$want_state" ] || continue
    if [ "$#" -gt 0 ]; then
      case " $* " in
        *" $class "*) ;;
        *) continue ;;
      esac
    fi
    found=true
    printf -- '- [%s] %s%s (%s, first seen %s)\n' "$class" \
      "$(record_field "$f" title)" \
      "$([ -z "$(record_field "$f" link)" ] || printf ' %s' "$(record_field "$f" link)")" \
      "$(record_field "$f" source)" \
      "$(local_date "$(record_field "$f" created)")"
  done
  [ "$found" = true ] || printf -- '- nothing\n'
}

render_brief() {
  local epoch=$1 id f
  printf '# Channel intake brief - %s\n\n' "$(local_fmt "$epoch" '%Y-%m-%d %H:%M %Z')"
  printf '## Coverage\n\n'
  printf 'Enrolled sources only. Enrolling these does not enrol every channel, mailbox or board in the workspace.\n'
  printf 'A source reading `unknown` did not complete its last read; that is not the same as nothing new.\n\n'
  load_inventory
  if [ -z "$INVENTORY_IDS" ]; then
    printf -- '- no sources enrolled\n'
  else
    for id in $INVENTORY_IDS; do
      printf -- '- `%s` (%s): %s - last read %s, %s\n' "$id" \
        "$(inventory_field "$id" 2)" "$(source_status "$id" "$epoch")" \
        "$(freshness_phrase "$id" "$epoch")" "$(inventory_field "$id" 3)"
    done
  fi
  printf '\n## What changed\n\n'
  changed_section "$epoch"
  printf '\n## What needs you\n\n'
  section_items open "$epoch" urgent outage deadline obligation
  printf '\n## Waiting on others\n\n'
  section_items waiting "$epoch"
  printf '\n## Next dated actions\n\n'
  section_items open "$epoch" deadline
  printf '\n## Automation candidates\n\n'
  printf 'Proposals only. Nothing here is prepared, staged or executable, and detecting one grants no permission to act.\n\n'
  section_items open "$epoch" automation-candidate
  printf '\n## Detection limits\n\n'
  printf -- '- An in-place edit older than the %ss revision window is not detected.\n' "$CFG_REVISION_WINDOW"
  printf -- '- A reply on a thread whose parent is not in the tracked set can appear in no cursor read.\n'
  printf -- '- The %ss poll interval is a target detection latency, not a guaranteed upper bound: sleep, offline stretches, backoff and queue delay all add to it.\n' "$CFG_INTERVAL"
  printf -- '- Measured detection latency so far: %s\n' "$(latency_summary)"
}

freshness_phrase() {
  local id=$1 epoch=$2 last_ok
  last_ok=$(record_field "$(source_record "$id")" last_ok)
  case "$last_ok" in
    ''|*[!0-9]*) printf 'never\n' ;;
    *) printf '%ss ago\n' "$((epoch - last_ok))" ;;
  esac
}

# What changed is the day's readable accumulation: routine traffic that needs
# no action, every correction to an item already on the ledger, and anything
# closed recently. It is bounded by BRIEF_WINDOW so it stays a brief rather
# than growing into the whole history.
BRIEF_WINDOW=86400

changed_section() {
  local epoch=$1 f found=false revisions resolved_at created updated
  for f in $(for_each_item "$ITEM_DIR"); do
    revisions=$(record_field "$f" revisions)
    case "$revisions" in ''|*[!0-9]*) revisions=0 ;; esac
    if [ "$revisions" -gt 0 ]; then
      # Bounded like every other row here: a correction is news on the day it
      # lands, not a permanent fixture of every later brief.
      updated=$(record_field "$f" updated)
      case "$updated" in ''|*[!0-9]*) continue ;; esac
      [ $((epoch - updated)) -le "$BRIEF_WINDOW" ] || continue
      found=true
      printf -- '- %s was corrected %s time(s) (%s)\n' "$(record_field "$f" title)" \
        "$revisions" "$(record_field "$f" source)"
      continue
    fi
    # Routine traffic is never a ping; this is where it accumulates.
    [ "$(record_field "$f" class)" = routine ] || continue
    created=$(record_field "$f" created)
    case "$created" in ''|*[!0-9]*) continue ;; esac
    [ $((epoch - created)) -le "$BRIEF_WINDOW" ] || continue
    found=true
    printf -- '- %s (%s)\n' "$(record_field "$f" title)" "$(record_field "$f" source)"
  done
  for f in $(for_each_item "$ARCHIVE_DIR"); do
    resolved_at=$(record_field "$f" resolved_at)
    case "$resolved_at" in ''|*[!0-9]*) continue ;; esac
    [ $((epoch - resolved_at)) -le "$BRIEF_WINDOW" ] || continue
    found=true
    printf -- '- %s was closed: %s\n' "$(record_field "$f" title)" \
      "$(record_field "$f" resolution)"
  done
  [ "$found" = true ] || printf -- '- nothing\n'
}

latency_summary() {
  [ -f "$LATENCY_LOG" ] || { printf 'no samples yet\n'; return 0; }
  awk -F'\t' '
    { n++; s += $3; if ($3 > max) max = $3 }
    END {
      if (n == 0) { print "no samples yet"; exit }
      printf "%d sample(s), mean %ds, max %ds\n", n, s / n, max
    }
  ' "$LATENCY_LOG"
}

brief_cmd() {
  local out='' epoch body
  while [ "$#" -gt 0 ]; do
    case "$1" in
      --out) [ "$#" -ge 2 ] || die '--out requires a value'; out=$2; shift 2 ;;
      *) die "unknown brief argument: $1" ;;
    esac
  done
  require_enabled
  resolve_out "$out"
  epoch=$(now_epoch)
  body=$(render_brief "$epoch")
  if [ -n "$out" ]; then
    # Overwriting the same path is deliberate: a background run updates the
    # existing page instead of leaving a trail of dated files to reopen.
    write_atomic "$out" "$body" || die "cannot write the brief: $out"
    printf 'CHANNEL_INTAKE: brief written to %s\n' "$out"
  else
    printf '%s\n' "$body"
  fi
}

# The daily to-do list is rendered from the same ledger as the brief, so a
# correction, a resolution and a completed obligation reconcile across both by
# construction rather than needing a second pass over two stores.
render_todo() {
  local epoch=$1 f found=false
  printf '# Daily to-do - %s\n\n' "$(local_date "$epoch")"
  printf 'Human obligations only. Executable automations live in the Action Deck behind their own approval.\n\n'
  for f in $(for_each_item "$ITEM_DIR"); do
    [ "$(record_field "$f" state)" = open ] || continue
    case "$(record_field "$f" class)" in
      automation-candidate|routine) continue ;;
    esac
    found=true
    printf -- '- [ ] %s%s (%s)\n' "$(record_field "$f" title)" \
      "$([ -z "$(record_field "$f" link)" ] || printf ' %s' "$(record_field "$f" link)")" \
      "$(record_field "$f" source)"
  done
  [ "$found" = true ] || printf -- '- [ ] nothing outstanding\n'
  printf '\n## Waiting on others\n\n'
  section_items waiting "$epoch"
}

todo_cmd() {
  local out='' epoch body
  while [ "$#" -gt 0 ]; do
    case "$1" in
      --out) [ "$#" -ge 2 ] || die '--out requires a value'; out=$2; shift 2 ;;
      *) die "unknown todo argument: $1" ;;
    esac
  done
  require_enabled
  resolve_out "$out"
  epoch=$(now_epoch)
  body=$(render_todo "$epoch")
  if [ -n "$out" ]; then
    write_atomic "$out" "$body" || die "cannot write the to-do list: $out"
    printf 'CHANNEL_INTAKE: to-do list written to %s\n' "$out"
  else
    printf '%s\n' "$body"
  fi
}

# --- watcher check and session-start surface ----------------------------------

# The watcher contract: one line when firstmate should wake, nothing otherwise,
# finishing well inside FM_CHECK_TIMEOUT. Suppression is by signature, so an
# unchanged state wakes the primary once rather than on every poll.
#
# Due sources and notifiable items are two independent conditions and each
# carries its own signature and its own marker. One combined snapshot would
# couple them: a claim that empties the due set while an alert is still held
# reads as a brand-new combined state, so the primary would be woken again
# about the alert it has already been told about, twice per poll interval, for
# as long as the alert stays held - and `capped`, `spaced` and an unverified
# recipient are all standing conditions rather than edge cases.
#
# Each signature carries the term that actually moves under it - the
# last-attempt watermark for due sources, the state token and count for
# notifications - and a condition that is currently absent clears its own
# marker. That is what the morning gate gets from folding its monotonic
# `updated` stamp in: without it a recurring identical state is suppressed
# forever and the live wake path fires once in the life of the home.
CHECK_DUE_FILE_NAME=check-surfaced-due
CHECK_NOTIFY_FILE_NAME=check-surfaced-notify

check_signal() {
  local epoch due count notify notify_token line='' progress wake=false
  local due_file notify_file due_signature='' notify_signature=''
  [ "$#" -eq 0 ] || die 'check takes no arguments'
  enabled || return 0
  epoch=$(now_epoch)
  lock_state "$CHECK_LOCK_WAIT" || return 0
  due_file="$INTAKE_DIR/$CHECK_DUE_FILE_NAME"
  notify_file="$INTAKE_DIR/$CHECK_NOTIFY_FILE_NAME"
  due=$(due_source_ids "$epoch")
  count=$(printf '%s' "$due" | grep -c '[^[:space:]]' || true)
  notify=$(notify_state "$epoch")
  notify_token=${notify%% *}
  notify=$(notify_state_count "$notify")

  if [ "$count" -gt 0 ]; then
    progress=$(last_attempt_watermark)
    due_signature="$count:$progress"
    [ "$(read_line_file "$due_file")" = "$due_signature" ] || wake=true
    line="$CFG_LABEL: $count source(s) due to read"
  fi
  if [ "$notify" -gt 0 ]; then
    notify_signature="$notify_token:$notify"
    [ "$(read_line_file "$notify_file")" = "$notify_signature" ] || wake=true
    line="${line:-$CFG_LABEL:}${line:+,} $notify item(s) $(notify_state_phrase "$notify_token")"
  fi

  # An absent condition clears its own marker whether or not this sweep wakes,
  # because that is what re-arms its next genuine wake.
  [ -n "$due_signature" ] || rm -f "$due_file"
  [ -n "$notify_signature" ] || rm -f "$notify_file"
  if [ "$wake" != true ]; then
    unlock_state
    return 0
  fi
  if [ -n "$due_signature" ]; then
    write_atomic "$due_file" "$due_signature" || { unlock_state; return 0; }
  fi
  if [ -n "$notify_signature" ]; then
    write_atomic "$notify_file" "$notify_signature" || { unlock_state; return 0; }
  fi
  unlock_state
  printf '%s\n' "$line"
}

# Read-only. Prints at most one diagnostic-convention line per condition, and
# nothing at all on a home that is not opted in or has nothing owed.
pending() {
  local epoch count notify notify_token armed unknown
  [ "$#" -eq 0 ] || die 'pending takes no arguments'
  enabled || return 0
  epoch=$(now_epoch)
  count=$(due_source_ids "$epoch" | grep -c '[^[:space:]]' || true)
  [ "$count" -eq 0 ] \
    || printf 'CHANNEL_INTAKE: %s source(s) due for %s - take them with %s claim\n' \
      "$count" "$CFG_LABEL" "$0"
  # A refused or suppressed alert reads as itself here. Reporting only the
  # sendable count would make "the recipient was never verified" and "the day's
  # cap is spent" indistinguishable from a quiet home.
  notify=$(notify_state "$epoch")
  notify_token=${notify%% *}
  notify=$(notify_state_count "$notify")
  [ "$notify" -eq 0 ] \
    || printf 'CHANNEL_INTAKE: %s item(s) %s for %s\n' \
      "$notify" "$(notify_state_phrase "$notify_token")" "$CFG_LABEL"
  unknown=$(unknown_sources "$epoch")
  [ -z "$unknown" ] \
    || printf 'CHANNEL_INTAKE: source(s) reading unknown for %s: %s\n' "$CFG_LABEL" "$unknown"
  # Nothing re-creates the live-session shim once it is gone, so report the
  # loss where an operator already looks and name the one command that repairs
  # it. Read-only on purpose: session start must not pay a mutation on every
  # home just to keep a per-device opt-in.
  [ "$count" -gt 0 ] || [ "$notify" -gt 0 ] || return 0
  armed=$(check_armed_state)
  [ "$armed" != armed ] || return 0
  printf 'CHANNEL_INTAKE: %s live check is %s - re-arm it with %s arm-check\n' \
    "$CFG_LABEL" "$armed" "$0"
}

unknown_sources() {
  local epoch=$1 id out=
  load_inventory
  for id in $INVENTORY_IDS; do
    [ "$(source_status "$id" "$epoch")" = unknown ] || continue
    out="$out${out:+ }$id"
  done
  printf '%s\n' "$out"
}

status_cmd() {
  local epoch
  [ "$#" -eq 0 ] || die 'status takes no arguments'
  epoch=$(now_epoch)
  printf 'config: %s\n' "$CONFIG_FILE"
  printf 'enabled: %s\n' "$CFG_ENABLED"
  printf 'timezone: %s\n' "${CFG_TIMEZONE:-<host local time>}"
  printf 'interval_seconds: %s\n' "$CFG_INTERVAL"
  printf 'interval_floor_seconds: %s\n' "$MIN_INTERVAL"
  printf 'revision_window_seconds: %s\n' "$CFG_REVISION_WINDOW"
  printf 'stale_after_seconds: %s\n' "$CFG_STALE_AFTER"
  printf 'backoff_seconds: %s\n' "$CFG_BACKOFF"
  printf 'backoff_max_seconds: %s\n' "$CFG_BACKOFF_MAX"
  printf 'quiet_hours: %s\n' \
    "$([ -z "$CFG_QUIET_START" ] && printf '<unset>' || printf '%s-%s' "$CFG_QUIET_START" "$CFG_QUIET_END")"
  printf 'in_quiet_hours: %s\n' "$(in_quiet_hours "$epoch" && printf true || printf false)"
  printf 'notify_min_interval_seconds: %s\n' "$CFG_NOTIFY_MIN_INTERVAL"
  printf 'notify_max_per_day: %s\n' "$CFG_NOTIFY_MAX_PER_DAY"
  printf 'notify_recipient_set: %s\n' \
    "$([ -n "$CFG_NOTIFY_RECIPIENT" ] && printf true || printf false)"
  printf 'notify_recipient_verified: %s\n' "$CFG_NOTIFY_VERIFIED"
  printf 'sources_file: %s\n' "$CFG_SOURCES_FILE"
  printf 'report_dir: %s\n' "${CFG_REPORT_DIR:-<unset>}"
  printf 'label: %s\n' "$CFG_LABEL"
  printf 'local_date_now: %s\n' "$(local_date "$epoch")"
  printf 'sources_enrolled: %s\n' "$(load_inventory; printf '%s' "$INVENTORY_IDS" | grep -c '[^[:space:]]' || true)"
  printf 'sources_due: %s\n' "$(due_source_ids "$epoch" | grep -c '[^[:space:]]' || true)"
  printf 'sources_unknown: %s\n' "$(unknown_sources "$epoch")"
  # Open and waiting both live in the active directory, so counting the
  # directory would report work handed to someone else as still owed.
  printf 'items_open: %s\n' "$(count_items_in_state "$ITEM_DIR" open)"
  printf 'items_waiting: %s\n' "$(count_items_in_state "$ITEM_DIR" waiting)"
  printf 'items_archived: %s\n' "$(for_each_item "$ARCHIVE_DIR" | wc -l | tr -d ' ')"
  printf 'notifications_today: %s\n' "$(notify_today_count "$epoch")"
  printf 'notifications_state: %s\n' "$(notify_state "$epoch")"
  printf 'measured_latency: %s\n' "$(latency_summary)"
  printf 'check_armed: %s\n' "$(check_armed_state)"
}

print_interval() {
  [ "$#" -eq 0 ] || die 'interval takes no arguments'
  printf '%s\n' "$CFG_INTERVAL"
}

load_config

case "${1:-}" in
  tick) shift; tick "$@" ;;
  claim) shift; claim "$@" ;;
  observe) shift; observe "$@" ;;
  complete) shift; complete_source "$@" ;;
  fail) shift; fail_source "$@" ;;
  resolve) shift; resolve_item "$@" ;;
  items) shift; items_cmd "$@" ;;
  sources) shift; sources_cmd "$@" ;;
  notify-due) shift; notify_due "$@" ;;
  notify-sent) shift; notify_sent "$@" ;;
  brief) shift; brief_cmd "$@" ;;
  todo) shift; todo_cmd "$@" ;;
  check) shift; check_signal "$@" ;;
  arm-check) shift; arm_check "$@" ;;
  disarm-check) shift; disarm_check "$@" ;;
  pending) shift; pending "$@" ;;
  status) shift; status_cmd "$@" ;;
  interval) shift; print_interval "$@" ;;
  -h|--help) usage ;;
  '') usage; exit 2 ;;
  *) die "unknown command: $1" ;;
esac
