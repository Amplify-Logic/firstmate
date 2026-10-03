#!/usr/bin/env bash
# fm-routine-report-check.sh - notice new scheduled cloud routine reports and
# read them, without ever writing to the repository they live in.
#
# Usage:
#   fm-routine-report-check.sh [check]   print one line when a new report landed; silent otherwise
#   fm-routine-report-check.sh show      print every report on the routine-reports branch
#   fm-routine-report-check.sh arm       write and register state/routine-reports.check.sh
#   fm-routine-report-check.sh disarm    remove the check shim, its trust binding, and the record
#   fm-routine-report-check.sh --help
#
# Scheduled Claude cloud routines publish capped digests, one file per routine,
# on the routine-reports branch of this firstmate repository's own origin
# (docs/cloud-routines.md). `check` asks the remote for that branch's head with
# one `git ls-remote` and prints one generic line when the head moved since the
# last report, so the watcher turns it into a `check:` wake and firstmate
# reviews and imports the report from the laptop. The line names no report
# content: what a routine wrote is read only on purpose, through `show`.
#
# `show` reads the branch into a throwaway bare repository in a temporary
# directory and prints each report file, so it never fetches into, checks out
# in, or otherwise changes this checkout. Neither action can push.
#
# `check` probes at most once per FM_ROUTINE_REPORT_INTERVAL seconds (default
# 3600, valid 60..86400; 0 disables the gate) and each git call is bounded by
# FM_ROUTINE_REPORT_PROBE_SECS (default 20, valid 1..25, so a probe always
# fits inside the watcher's default per-check bound). A failed or timed-out
# probe stays silent and is retried at the next interval. A branch that does not
# exist yet is silent. The first head ever seen is reported, because it is a
# report nobody has read yet.
#
# The record state/.routine-reports holds the schema line, the last reported
# head, and the epoch of the last probe. `disarm` removes it with the shim.
#
# FM_ROUTINE_REPORTS_URL overrides the remote; by default it is the origin URL
# of the repository this script lives in.
set -u
export LC_ALL=C
export GIT_TERMINAL_PROMPT=0

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_ROOT}}"
STATE="${FM_STATE_OVERRIDE:-$FM_HOME/state}"
CHECK_ID=routine-reports
CHECK_SHIM="$STATE/$CHECK_ID.check.sh"
CHECK_TRUST="$STATE/$CHECK_ID.check-trust"
RECORD="$STATE/.routine-reports"
RECORD_SCHEMA=fm-routine-reports-v1
BRANCH=routine-reports
REGISTER_BIN="$SCRIPT_DIR/fm-check-register.sh"

# shellcheck source=bin/fm-timeout-lib.sh
. "$SCRIPT_DIR/fm-timeout-lib.sh"
# shellcheck source=bin/fm-pr-lib.sh
. "$SCRIPT_DIR/fm-pr-lib.sh"
# shellcheck source=bin/fm-check-lib.sh
. "$SCRIPT_DIR/fm-check-lib.sh"

usage() {
  cat <<'EOF'
Usage:
  fm-routine-report-check.sh [check]   print one line when a new routine report landed (silent otherwise)
  fm-routine-report-check.sh show      print every report on the routine-reports branch
  fm-routine-report-check.sh arm       write and register state/routine-reports.check.sh
  fm-routine-report-check.sh disarm    remove the check shim, its trust binding, and the record
  fm-routine-report-check.sh --help    print this help

See docs/cloud-routines.md for the routines that write these reports.
EOF
}

die() {
  printf 'fm-routine-report-check: %s\n' "$1" >&2
  exit "${2:-1}"
}

bounded_setting() {  # <name> <value> <min> <max> [allow-zero]
  local name=$1 value=$2 min=$3 max=$4 zero=${5:-}
  case "$value" in ''|*[!0-9]*) die "$name must be a whole number from $min to $max" 2 ;; esac
  [ -n "$zero" ] && [ "$value" -eq 0 ] && return 0
  if [ "$value" -lt "$min" ] || [ "$value" -gt "$max" ]; then
    die "$name must be a whole number from $min to $max${zero:+, or 0}" 2
  fi
}

INTERVAL=${FM_ROUTINE_REPORT_INTERVAL:-3600}
PROBE_SECS=${FM_ROUTINE_REPORT_PROBE_SECS:-20}
bounded_setting FM_ROUTINE_REPORT_INTERVAL "$INTERVAL" 60 86400 zero
bounded_setting FM_ROUTINE_REPORT_PROBE_SECS "$PROBE_SECS" 1 25

remote_url() {
  if [ -n "${FM_ROUTINE_REPORTS_URL:-}" ]; then
    printf '%s\n' "$FM_ROUTINE_REPORTS_URL"
  else
    git -C "$FM_ROOT" remote get-url origin 2>/dev/null
  fi
}

RECORD_HEAD=
RECORD_PROBED=0

record_read() {
  local schema head probed
  RECORD_HEAD=
  RECORD_PROBED=0
  [ -f "$RECORD" ] && [ ! -L "$RECORD" ] || return 0
  { IFS= read -r schema; IFS= read -r head; IFS= read -r probed; } < "$RECORD" || true
  [ "$schema" = "$RECORD_SCHEMA" ] || return 0
  [[ "${head:-}" =~ ^([0-9a-f]{40}|[0-9a-f]{64})?$ ]] && RECORD_HEAD=${head:-}
  case "${probed:-}" in ''|*[!0-9]*) ;; *) RECORD_PROBED=$probed ;; esac
}

record_write() {  # <head> <probed-epoch>
  local tmp
  [ -d "$STATE" ] && [ ! -L "$STATE" ] || return 1
  [ ! -L "$RECORD" ] || return 1
  tmp=$(umask 077; mktemp "$STATE/.fm-routine-reports.XXXXXX" 2>/dev/null) || return 1
  if ! printf '%s\n%s\n%s\n' "$RECORD_SCHEMA" "$1" "$2" > "$tmp" || ! mv -f -- "$tmp" "$RECORD"; then
    rm -f -- "$tmp"
    return 1
  fi
}

action_check() {
  local now url out rc head
  now=$(date +%s)
  record_read
  if [ "$INTERVAL" -ne 0 ] && [ $(( now - RECORD_PROBED )) -lt "$INTERVAL" ] && [ "$RECORD_PROBED" -le "$now" ]; then
    return 0
  fi
  url=$(remote_url) && [ -n "$url" ] || return 0
  out=$(fm_run_timed "$PROBE_SECS" git ls-remote --exit-code "$url" "refs/heads/$BRANCH" 2>/dev/null)
  rc=$?
  case "$rc" in
    0) head=${out%%[[:space:]]*} ;;
    2) record_write "$RECORD_HEAD" "$now" || true; return 0 ;;
    *) return 0 ;;
  esac
  [[ "$head" =~ ^([0-9a-f]{40}|[0-9a-f]{64})$ ]] || return 0
  if [ "$head" = "$RECORD_HEAD" ]; then
    record_write "$RECORD_HEAD" "$now" || true
    return 0
  fi
  # Report only once the record holds the new head, so a home that cannot
  # write its record stays silent instead of repeating the line every poll.
  record_write "$head" "$now" || return 0
  printf 'routine report ready: a scheduled cloud routine published a new report; review it with bin/fm-routine-report-check.sh show\n'
}

action_show() {
  local url tmp name
  url=$(remote_url) && [ -n "$url" ] || die "no remote to read reports from"
  tmp=$(mktemp -d "${TMPDIR:-/tmp}/fm-routine-reports.XXXXXX") || die "could not make a temporary directory"
  # shellcheck disable=SC2064  # Expand now: the path is fixed for this call.
  trap "rm -rf -- '$tmp'" EXIT
  git init --quiet --bare "$tmp/r" || die "could not make a temporary repository"
  if ! fm_run_timed 60 git -C "$tmp/r" fetch --quiet --no-tags --depth=1 "$url" "refs/heads/$BRANCH:refs/heads/$BRANCH" >/dev/null 2>&1; then
    die "could not read the $BRANCH branch of $url"
  fi
  printf 'Routine reports on %s at %s\n' "$BRANCH" "$(git -C "$tmp/r" rev-parse --short "refs/heads/$BRANCH")"
  git -C "$tmp/r" ls-tree --name-only "refs/heads/$BRANCH" | while IFS= read -r name; do
    case "$name" in *.md) ;; *) continue ;; esac
    [ "$name" = README.md ] && continue
    printf '\n===== %s =====\n' "$name"
    git -C "$tmp/r" cat-file -p "refs/heads/$BRANCH:$name"
  done
}

# The home is embedded already resolved, because the watcher runs the shim from
# its own working directory.
shim_content() {
  printf '%s\n' \
    '#!/usr/bin/env bash' \
    '# Auto-generated by fm-routine-report-check.sh - cloud routine report poll shim.' \
    '# The watcher validates these bytes, then dispatches the trusted check script.' \
    "export FM_HOME=$(printf '%q' "$1")" \
    "exec $(printf '%q' "$SCRIPT_DIR/fm-routine-report-check.sh") check"
}

# An unregistered shim is not inert: the watcher rejects it on every cycle and
# wakes firstmate about an unauthenticated state check. So a failed arm never
# leaves a shim without a matching trust binding.
action_arm() {
  local home device tmp
  mkdir -p "$STATE" || die "could not create $STATE"
  home=$(CDPATH='' cd -- "$FM_HOME" 2>/dev/null && pwd -P) || die "cannot resolve FM_HOME $FM_HOME"
  [ -d "$STATE" ] && [ ! -L "$STATE" ] || die "state directory is unavailable"
  device=$(fm_pr_file_device "$STATE") && [ -n "$device" ] || die "state directory is unavailable"
  fm_pr_regular_destination_on_device_or_absent "$CHECK_SHIM" "$device" || die "$CHECK_SHIM is not a regular file"
  tmp=$(umask 077; mktemp "$STATE/.fm-routine-reports-check.XXXXXX") || die "could not write $CHECK_SHIM"
  if ! shim_content "$home" > "$tmp" || ! chmod 0700 "$tmp" || ! mv -f -- "$tmp" "$CHECK_SHIM"; then
    rm -f -- "$tmp"
    die "could not write $CHECK_SHIM"
  fi
  if ! FM_HOME="$home" "$REGISTER_BIN" "$CHECK_ID" >/dev/null; then
    rm -f -- "$CHECK_SHIM" "$CHECK_TRUST"
    die "could not register $CHECK_SHIM"
  fi
  printf 'armed: state/%s.check.sh\n' "$CHECK_ID"
}

action_disarm() {
  rm -f -- "$CHECK_SHIM" "$CHECK_TRUST" "$RECORD"
  printf 'disarmed: state/%s.check.sh\n' "$CHECK_ID"
}

case "${1:-check}" in
  check) action_check ;;
  show) action_show ;;
  arm) action_arm ;;
  disarm) action_disarm ;;
  -h|--help) usage ;;
  *) usage >&2; exit 2 ;;
esac
