#!/usr/bin/env bash
# Install and inspect the local morning-intake schedule on macOS launchd.
#
# Usage:
#   fm-morning-intake-schedule.sh render
#   fm-morning-intake-schedule.sh install
#   fm-morning-intake-schedule.sh status
#   fm-morning-intake-schedule.sh remove
#   fm-morning-intake-schedule.sh --help
#
# The schedule is intentionally visible, not an opaque cron entry.
# `render` prints the complete plist, `status` prints its path, the resolved
# knobs and the installed definition, and `install` writes
# ~/Library/LaunchAgents/<label>.plist, loads it, and arms the watcher check.
#
# `StartInterval` plus `RunAtLoad` is the whole trigger. launchd runs the job on
# login and then on the interval, and a job whose interval elapsed while the
# machine was asleep runs shortly after it wakes. That is the catch-up path, and
# it is why the intake is described as the FIRST AVAILABLE MORNING rather than a
# lid-open event: launchd exposes no such event here and none is claimed.
#
# The gate itself lives in bin/fm-morning-intake.sh, which owns the local day,
# the threshold, deduplication, retries and the completion watermark. This
# script only decides WHEN that gate is consulted, and reads the cadence back
# from the gate owner rather than parsing config a second time.
#
# The label is derived from FM_HOME, so each operational home installs its own
# agent and installing here never disturbs another home's schedule.
set -eu

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$ROOT}}"
DATA="${FM_DATA_OVERRIDE:-$FM_HOME/data}"
INTAKE="$SCRIPT_DIR/fm-morning-intake.sh"

usage() {
  awk '
    NR == 1 { next }
    /^#/ { sub(/^# ?/, ""); print; next }
    { exit }
  ' "$0" >&2
}

die() {
  printf 'fm-morning-intake-schedule: %s\n' "$*" >&2
  exit 2
}

[ -x "$INTAKE" ] || die "intake gate is not executable: $INTAKE"

intake() {
  FM_HOME="$FM_HOME" FM_ROOT_OVERRIDE="$ROOT" "$INTAKE" "$@"
}

xml_escape() {
  printf '%s' "$1" | sed 's/&/\&amp;/g; s/</\&lt;/g; s/>/\&gt;/g; s/"/\&quot;/g; s/'"'"'/\&apos;/g'
}

home_key=$(printf '%s' "$FM_HOME" | cksum | awk '{print $1}')
LABEL="dev.firstmate.morning-intake.$home_key"
AGENTS_DIR=${FM_MORNING_INTAKE_LAUNCH_AGENTS_DIR:-$HOME/Library/LaunchAgents}
PLIST="$AGENTS_DIR/$LABEL.plist"
# Overridable so the behavior suite can install and remove against a temporary
# home without loading anything into the operator's real launchd session.
LAUNCHCTL=${FM_MORNING_INTAKE_LAUNCHCTL:-launchctl}

render() {
  local interval root home program stdout stderr
  interval=$(intake interval)
  root=$(xml_escape "$ROOT")
  home=$(xml_escape "$FM_HOME")
  program=$(xml_escape "$INTAKE")
  stdout=$(xml_escape "$DATA/morning-intake/launchd.stdout.log")
  stderr=$(xml_escape "$DATA/morning-intake/launchd.stderr.log")
  cat <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>Label</key>
  <string>$LABEL</string>
  <key>ProgramArguments</key>
  <array>
    <string>$program</string>
    <string>run</string>
  </array>
  <key>WorkingDirectory</key>
  <string>$root</string>
  <key>EnvironmentVariables</key>
  <dict>
    <key>FM_HOME</key>
    <string>$home</string>
    <key>FM_ROOT_OVERRIDE</key>
    <string>$root</string>
  </dict>
  <key>StartInterval</key>
  <integer>$interval</integer>
  <key>RunAtLoad</key>
  <true/>
  <key>StandardOutPath</key>
  <string>$stdout</string>
  <key>StandardErrorPath</key>
  <string>$stderr</string>
</dict>
</plist>
EOF
}

install_schedule() {
  local tmp domain
  [ "$#" -eq 0 ] || die 'install takes no arguments'
  [ "$(uname)" = Darwin ] || die 'install requires macOS launchd; use render for an inspectable scheduler definition'
  # Refuse rather than enrolling a home that never opted in: this is what keeps
  # a fresh clone or a seeded secondmate from acquiring a schedule by accident.
  [ "$(intake status | awk '$1 == "enabled:" { print $2 }')" = true ] \
    || die "this home is not opted in; add 'enabled = true' to config/morning-intake first"
  mkdir -p "$AGENTS_DIR" "$DATA/morning-intake"
  tmp=$(mktemp "$AGENTS_DIR/.morning-intake.XXXXXX")
  render >"$tmp"
  chmod 600 "$tmp"
  if command -v plutil >/dev/null 2>&1; then
    plutil -lint "$tmp" >/dev/null || { rm -f "$tmp"; die 'rendered plist failed plutil validation'; }
  fi
  mv -f "$tmp" "$PLIST"
  domain="gui/$(id -u)"
  "$LAUNCHCTL" bootout "$domain/$LABEL" >/dev/null 2>&1 || true
  "$LAUNCHCTL" bootstrap "$domain" "$PLIST"
  # Arm the live-session delivery path too, so a running fleet is actually woken
  # instead of only discovering the intake at the next session start.
  intake arm-check
  printf 'installed: %s\n' "$PLIST"
  printf 'interval_seconds: %s\n' "$(intake interval)"
}

status_schedule() {
  [ "$#" -eq 0 ] || die 'status takes no arguments'
  printf 'plist: %s\n' "$PLIST"
  intake status
  if [ -f "$PLIST" ]; then
    printf '%s\n' '--- installed definition ---'
    cat "$PLIST"
    if [ "$(uname)" = Darwin ]; then
      printf '%s\n' '--- launchd status ---'
      "$LAUNCHCTL" print "gui/$(id -u)/$LABEL" 2>&1 || true
    fi
  else
    printf 'not installed; inspect the proposed definition with: %s render\n' "$0"
  fi
}

remove_schedule() {
  [ "$#" -eq 0 ] || die 'remove takes no arguments'
  "$LAUNCHCTL" bootout "gui/$(id -u)/$LABEL" >/dev/null 2>&1 || true
  rm -f "$PLIST"
  # Durable records under data/morning-intake are deliberately left in place:
  # removing the schedule is not the same as discarding the intake history.
  intake disarm-check >/dev/null 2>&1 || true
  printf 'removed: %s\n' "$PLIST"
}

case "${1:-}" in
  render) shift; [ "$#" -eq 0 ] || die 'render takes no arguments'; render ;;
  install) shift; install_schedule "$@" ;;
  status) shift; status_schedule "$@" ;;
  remove) shift; remove_schedule "$@" ;;
  -h|--help) usage ;;
  '') usage; exit 2 ;;
  *) die "unknown command: $1" ;;
esac
