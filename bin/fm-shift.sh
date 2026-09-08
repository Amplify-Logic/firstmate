#!/usr/bin/env bash
# fm-shift.sh - arm, stand down, and report the captain's glasses voice loop for
# one delivery shift.
#
# The loop itself already works: the captain speaks through his Ray-Ban glasses,
# the phone posts into the local mailbox over Tailscale, firstmate answers, and
# the answer is spoken back. What did not work was ARMING it: four separate
# things have to be true at once, and when one of them is not, the captain finds
# out by talking into silence three streets away. This command verifies all four
# BEFORE arming anything, refuses by name when one fails, and while the shift is
# armed makes an outage reach his ear instead of staying silent.
#
# It orchestrates existing owners and reimplements none of them:
#   away mode        bin/fm-afk-launch.sh start / bin/fm-afk-return.sh
#   supervision      bin/fm-wake-lib.sh's model-aware watcher verdict
#   session lock     bin/fm-lock.sh status
#   the self-check   bin/fm-check-register.sh, run by the fleet watcher
#   the spoken line  the glasses announce CLI, at its own absolute path
#   the watcher alarm  config/wedge-alarm's existing command: channel
# It adds no daemon and no launchd agent of its own.
#
# Usage:
#   fm-shift.sh start     Verify mains power and sleep, the mailbox, the phone's
#                         Tailscale route, and live supervision; refuse naming
#                         the failure if any is not true; then start away mode,
#                         register the outage self-check, route supervision
#                         alarms to the glasses, and speak one confirmation.
#                         Safe to run twice: it re-verifies and re-converges.
#   fm-shift.sh stop      Remove the shift-only arming, hand away mode back to
#                         its return owner, and print what happened during the
#                         shift. Leaves the mailbox, the keep-awake agent, and
#                         the Tailscale mapping alone: those are standing
#                         services the captain also uses at his desk. Safe to
#                         run when no shift is armed.
#   fm-shift.sh status    One line per component. Exits non-zero when a shift is
#                         armed and any component is down; when no shift is
#                         armed it still prints every line but exits 0, because
#                         nothing is claiming to be armed.
#   fm-shift.sh alarm [summary]
#                         Internal. The spoken end of the config/wedge-alarm
#                         `command:` channel installed by start: it turns a
#                         supervision-outage or injection-wedge summary into one
#                         short spoken line. Silent unless a shift is armed.
#
# WHAT CANNOT BE SPOKEN WHILE IT IS BROKEN: the glasses have exactly one channel
# to the captain's ear, and it is the mailbox. A mailbox outage therefore cannot
# be announced while it lasts. The self-check records it, wakes firstmate to
# repair it, and speaks a single line when the loop comes back naming how long
# it was gone - that recovery line is the only one that can actually reach him.
# Every edge is also appended to state/.shift-log as one plain timestamped line
# (`<ISO8601-UTC> <event> <detail>`, events armed/down/up/stood-down), which is
# what stop's report reads. It is deliberately not a state/*.status file: those
# carry the crewmate task protocol, and a shift is not a crew task.
# A supervision (watcher) outage is different: the mailbox is still up, so it
# can be spoken. Detection belongs to the host launchd sentinel
# (bin/fm-supervision-sentinel.sh), which checks this home once a minute and
# treats the armed shift record as work worth supervising even with no crew
# task in flight; its alarm goes out through the config/wedge-alarm command:
# channel that start installs, and that channel is `fm-shift.sh alarm`, which
# speaks one plain line. So a dead watcher or a dead away daemon is spoken
# within the sentinel's beacon grace plus one check interval, not immediately.
#
# Environment (all optional; defaults are the captain's live runtime):
#   FM_SHIFT_MAILBOX_LABEL     mailbox LaunchAgent label
#   FM_SHIFT_KEEPAWAKE_LABEL   keep-awake LaunchAgent label
#   FM_SHIFT_MAILBOX_PORT      loopback port the mailbox serves (default 8765)
#   FM_SHIFT_SERVE_PORT        Tailscale Serve HTTPS port the phone targets (8443)
#   FM_SHIFT_ANNOUNCE          absolute path of the glasses announce CLI
#   FM_SHIFT_MAILBOX_DB        mailbox database, read read-only for the report
#   FM_SHIFT_AFK_LAUNCH        away-mode launch owner
#   FM_SHIFT_AFK_RETURN        away-mode return owner
#   FM_SHIFT_HEALTH_WAIT       seconds to wait for /health after a kickstart (20)
#   FM_SHIFT_CURL_TIMEOUT      per-request /health timeout in seconds (5)
set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_ROOT}}"
STATE="${FM_STATE_OVERRIDE:-$FM_HOME/state}"
CONFIG="${FM_CONFIG_OVERRIDE:-$FM_HOME/config}"

# shellcheck source=bin/fm-wake-lib.sh
. "$SCRIPT_DIR/fm-wake-lib.sh"
# shellcheck source=bin/fm-pr-lib.sh
. "$SCRIPT_DIR/fm-pr-lib.sh"
# shellcheck source=bin/fm-check-lib.sh
. "$SCRIPT_DIR/fm-check-lib.sh"
# shellcheck source=bin/fm-supervision-lib.sh
. "$SCRIPT_DIR/fm-supervision-lib.sh"

SHIFT_ID=fm-shift
ARMED="$STATE/$FM_SUP_SHIFT_RECORD_NAME"
OUTAGE_MARK="$STATE/.shift-mailbox-outage"
SHIFT_LOG="$STATE/.shift-log"
LEGACY_STATUS_FILE="$STATE/$SHIFT_ID.status"
CHECK="$STATE/$SHIFT_ID.check.sh"
CHECK_TRUST="$STATE/$SHIFT_ID.check-trust"
WEDGE_CONFIG="$CONFIG/wedge-alarm"
WEDGE_BEGIN="# >>> fm-shift.sh - removed by: fm-shift.sh stop"
WEDGE_END="# <<< fm-shift.sh"

MAILBOX_LABEL="${FM_SHIFT_MAILBOX_LABEL:-com.firstmate.glasses-voice-mailbox}"
KEEPAWAKE_LABEL="${FM_SHIFT_KEEPAWAKE_LABEL:-com.firstmate.glasses-keepawake}"
MAILBOX_PORT="${FM_SHIFT_MAILBOX_PORT:-8765}"
SERVE_PORT="${FM_SHIFT_SERVE_PORT:-8443}"
HEALTH_URL="http://127.0.0.1:$MAILBOX_PORT/health"
ANNOUNCE="${FM_SHIFT_ANNOUNCE:-$FM_HOME/projects/glasses-voice/bin/announce}"
MAILBOX_DB="${FM_SHIFT_MAILBOX_DB:-$FM_HOME/data/glasses-voice-runtime/mailbox.db}"
AFK_LAUNCH="${FM_SHIFT_AFK_LAUNCH:-$SCRIPT_DIR/fm-afk-launch.sh}"
AFK_RETURN="${FM_SHIFT_AFK_RETURN:-$SCRIPT_DIR/fm-afk-return.sh}"
HEALTH_WAIT="${FM_SHIFT_HEALTH_WAIT:-20}"
CURL_TIMEOUT="${FM_SHIFT_CURL_TIMEOUT:-5}"
GUI_DOMAIN="gui/$(id -u)"
WATCH_PATH="$SCRIPT_DIR/fm-watch.sh"
GRACE="${FM_GUARD_GRACE:-300}"

# The one line spoken when a shift is armed. Kept here so preflight can prove
# the whole announce path with --dry-run before anything is armed, and the real
# call at the end speaks exactly what was proven.
ARM_LINE='Shift loop armed. Ask me anything while you ride.'

usage() { sed -n '22,46p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'; }

have() { command -v "$1" >/dev/null 2>&1; }

now_epoch() { date +%s; }
now_iso() { date -u +%Y-%m-%dT%H:%M:%SZ; }

# Local wall-clock HH:MM for an epoch. GNU date has no -r, BSD date has no -d.
local_hm() {
  local epoch=$1
  date -r "$epoch" +%H:%M 2>/dev/null || date -d "@$epoch" +%H:%M 2>/dev/null || printf '?\n'
}

duration_text() {
  local secs=$1 h m
  h=$((secs / 3600))
  m=$(((secs % 3600) / 60))
  if [ "$h" -gt 0 ]; then printf '%sh %sm\n' "$h" "$m"; else printf '%sm\n' "$m"; fi
}

say() { printf '%s\n' "$*"; }
warn() { printf 'fm-shift: %s\n' "$*" >&2; }

append_log() {  # <event> <detail>
  printf '%s %s %s\n' "$(now_iso)" "$1" "$2" >> "$SHIFT_LOG"
}

# ---------------------------------------------------------------------------
# Component probes. Each sets PROBE_LINE (one status line) and, when it fails,
# PROBE_FIX (what the captain or firstmate does about it), and returns 0/1.
# ---------------------------------------------------------------------------
PROBE_LINE=
PROBE_FIX=

agent_running() {  # <label>
  local out
  have launchctl || return 1
  out=$(launchctl print "$GUI_DOMAIN/$1" 2>/dev/null) || return 1
  printf '%s\n' "$out" | grep -qE '^[[:space:]]*state = running[[:space:]]*$'
}

sleep_prevented() {
  local out
  out=$(pmset -g 2>/dev/null) || return 1
  printf '%s\n' "$out" | grep -qE '^[[:space:]]*sleep[[:space:]]+[0-9]+[[:space:]]+\(sleep prevented by' && return 0
  printf '%s\n' "$out" | grep -qE '^[[:space:]]*SleepDisabled[[:space:]]+1[[:space:]]*$'
}

mailbox_health_code() {
  have curl || { printf '\n'; return 1; }
  curl -s -o /dev/null -w '%{http_code}' -m "$CURL_TIMEOUT" "$HEALTH_URL" 2>/dev/null
}

mailbox_healthy() { [ "$(mailbox_health_code)" = 200 ]; }

serve_mapping_armed() {
  have tailscale || return 1
  tailscale serve status 2>/dev/null | awk \
    -v port=":$SERVE_PORT" -v target="http://127.0.0.1:$MAILBOX_PORT" '
    /^https:\/\// { block = (index($0, port) > 0); next }
    block && index($0, target) > 0 { found = 1 }
    END { exit(found ? 0 : 1) }'
}

probe_power() {
  PROBE_FIX=
  if ! have pmset; then
    PROBE_LINE='power: UNKNOWN - pmset is not available on this host'
    PROBE_FIX='the glasses loop runs on the captain Mac; nothing else can hold off its sleep'
    return 1
  fi
  if ! pmset -g ps 2>/dev/null | grep -q 'AC Power'; then
    PROBE_LINE='power: DOWN - the Mac is running on battery'
    PROBE_FIX='plug the Mac into mains and leave the lid open; the keep-awake assertion only holds off system sleep on AC power, so a shift on battery is a dead loop'
    return 1
  fi
  if ! sleep_prevented; then
    PROBE_LINE='power: DOWN - nothing is holding off system sleep'
    PROBE_FIX="start the keep-awake agent: launchctl kickstart -k $GUI_DOMAIN/$KEEPAWAKE_LABEL (and leave the lid open)"
    return 1
  fi
  PROBE_LINE='power: ok - on mains power, system sleep held off (keep the lid open)'
  return 0
}

probe_keepawake() {
  PROBE_FIX=
  if agent_running "$KEEPAWAKE_LABEL"; then
    PROBE_LINE="keep-awake: ok - $KEEPAWAKE_LABEL is running"
    return 0
  fi
  PROBE_LINE="keep-awake: DOWN - $KEEPAWAKE_LABEL is not running"
  PROBE_FIX="launchctl kickstart -k $GUI_DOMAIN/$KEEPAWAKE_LABEL"
  return 1
}

probe_mailbox() {
  local code
  PROBE_FIX=
  if ! agent_running "$MAILBOX_LABEL"; then
    PROBE_LINE="mailbox: DOWN - $MAILBOX_LABEL is not running"
    PROBE_FIX="launchctl kickstart -k $GUI_DOMAIN/$MAILBOX_LABEL - never start a second copy by hand, it fights launchd for the port"
    return 1
  fi
  code=$(mailbox_health_code)
  if [ "$code" != 200 ]; then
    PROBE_LINE="mailbox: DOWN - the service is running but /health answered ${code:-nothing}"
    PROBE_FIX="launchctl kickstart -k $GUI_DOMAIN/$MAILBOX_LABEL, then re-check /health; a crash-looping service answers nothing"
    return 1
  fi
  PROBE_LINE='mailbox: ok - the service is running and answering its health check'
  return 0
}

probe_announce() {
  PROBE_FIX=
  if [ ! -x "$ANNOUNCE" ]; then
    PROBE_LINE="voice out: DOWN - no announce command at $ANNOUNCE"
    PROBE_FIX='the glasses-voice checkout is missing or not built; without it nothing can be spoken into the glasses'
    return 1
  fi
  if ! "$ANNOUNCE" --dry-run "$ARM_LINE" >/dev/null 2>&1; then
    PROBE_LINE='voice out: DOWN - the announce path refused a dry run'
    PROBE_FIX="run: $ANNOUNCE --dry-run 'test' and read its error; the mailbox database or the voice keys are unreadable"
    return 1
  fi
  PROBE_LINE='voice out: ok - firstmate can speak into the glasses'
  return 0
}

probe_serve() {
  PROBE_FIX=
  if ! have tailscale; then
    PROBE_LINE='phone route: UNKNOWN - tailscale is not available on this host'
    PROBE_FIX='the phone reaches the mailbox only over Tailscale Serve'
    return 1
  fi
  if serve_mapping_armed; then
    PROBE_LINE="phone route: ok - Tailscale Serve maps :$SERVE_PORT to the mailbox"
    return 0
  fi
  PROBE_LINE="phone route: DOWN - Tailscale Serve has no :$SERVE_PORT mapping to the mailbox"
  PROBE_FIX="tailscale serve --bg --https=$SERVE_PORT http://127.0.0.1:$MAILBOX_PORT (a Serve config reset drops it)"
  return 1
}

probe_supervision() {
  local lock
  PROBE_FIX=
  lock=$("$SCRIPT_DIR/fm-lock.sh" status 2>/dev/null || printf 'lock: unknown')
  case "$lock" in
    *'held by live harness'*) ;;
    *)
      PROBE_LINE='supervision: DOWN - no live firstmate session holds this home'
      PROBE_FIX='start a firstmate session here and run its session start; a question nobody is awake to hear is the same as no loop at all'
      return 1
      ;;
  esac
  fm_watcher_supervision_verdict "$STATE" "$WATCH_PATH" "$GRACE" "$FM_HOME"
  if [ "$FM_WATCHER_VERDICT_OK" = true ]; then
    PROBE_LINE='supervision: ok - a firstmate session is live and watching'
    return 0
  fi
  case "$FM_WATCHER_VERDICT_REASON" in
    no-watcher) PROBE_LINE='supervision: DOWN - the session is live but nothing is watching for questions' ;;
    *) PROBE_LINE='supervision: DOWN - nothing has watched for questions recently' ;;
  esac
  PROBE_FIX='resume the session supervision cycle in the firstmate session for this home before leaving'
  return 1
}

probe_away() {
  PROBE_FIX=
  if [ -e "$STATE/.afk" ]; then
    PROBE_LINE='away mode: ok - firstmate keeps answering while you are out'
    return 0
  fi
  PROBE_LINE='away mode: DOWN - firstmate is not in away mode'
  PROBE_FIX="$AFK_LAUNCH start"
  return 1
}

probe_selfcheck() {
  PROBE_FIX=
  if [ ! -f "$CHECK" ] || [ ! -f "$CHECK_TRUST" ]; then
    PROBE_LINE='outage self-check: DOWN - not registered'
    PROBE_FIX='fm-shift.sh start registers it'
    return 1
  fi
  if ! fm_custom_check_registered "$STATE" "$SHIFT_ID"; then
    PROBE_LINE='outage self-check: DOWN - registered, but the watcher rejects it (the check changed after registration)'
    PROBE_FIX='fm-shift.sh start rewrites and re-registers it'
    return 1
  fi
  PROBE_LINE='outage self-check: ok - registered, watching the mailbox every sweep'
  return 0
}

probe_alarm_route() {
  PROBE_FIX=
  if [ ! -f "$WEDGE_CONFIG" ] || ! grep -Fqx "$WEDGE_BEGIN" "$WEDGE_CONFIG"; then
    PROBE_LINE='supervision alarm: DOWN - a supervision outage would not reach your ear'
    PROBE_FIX='fm-shift.sh start routes it through the announce path'
    return 1
  fi
  if grep -qE '^[[:space:]]*off[[:space:]]*$' "$WEDGE_CONFIG"; then
    PROBE_LINE='supervision alarm: DOWN - alarms are switched off in this home'
    PROBE_FIX="remove the 'off' line from $WEDGE_CONFIG; it silences every alarm channel"
    return 1
  fi
  PROBE_LINE='supervision alarm: ok - a supervision outage is spoken into the glasses'
  return 0
}

# ---------------------------------------------------------------------------
# The registered self-check. Written by start, run by the fleet watcher, removed
# by stop. It stays inside the watcher's per-check timeout: one health request,
# no repair, no second copy of anything.
# ---------------------------------------------------------------------------
write_check() {
  local tmp
  tmp=$(mktemp "$STATE/.fm-shift-check.XXXXXX") || return 1
  cat > "$tmp" <<CHECK_EOF
#!/bin/bash
# Generated by bin/fm-shift.sh start; removed by bin/fm-shift.sh stop.
# Prints one line only when firstmate should wake: the moment the voice loop
# stops answering, and the moment it comes back. One line per episode, never one
# per sweep - the outage marker below is what makes a continuing outage silent.
STATE=$(printf '%q' "$STATE")
ANNOUNCE=$(printf '%q' "$ANNOUNCE")
HEALTH_URL=$(printf '%q' "$HEALTH_URL")
CURL_TIMEOUT=$(printf '%q' "$CURL_TIMEOUT")
ARMED="\$STATE/$(printf '%q' "$FM_SUP_SHIFT_RECORD_NAME")"
MARK="\$STATE/.shift-mailbox-outage"
LOG="\$STATE/.shift-log"

[ -f "\$ARMED" ] || exit 0
# No way to ask: stay silent rather than report a false outage.
command -v curl >/dev/null 2>&1 || exit 0

NOW=\$(date -u +%Y-%m-%dT%H:%M:%SZ)
CODE=\$(curl -s -o /dev/null -w '%{http_code}' -m "\$CURL_TIMEOUT" "\$HEALTH_URL" 2>/dev/null)

if [ "\$CODE" = 200 ]; then
  [ -e "\$MARK" ] || exit 0
  SINCE=\$(cat "\$MARK" 2>/dev/null)
  NOW_S=\$(date +%s)
  case "\$SINCE" in
    ''|*[!0-9]*) MINUTES=0 ;;
    *) MINUTES=\$(((NOW_S - SINCE + 30) / 60)) ;;
  esac
  if [ "\$MINUTES" -gt 0 ]; then
    GONE="about \$MINUTES minutes"
  else
    GONE="less than a minute"
  fi
  # Durable record and wake line first, announce last: the watcher kills this
  # check at its timeout and keeps only what was printed by then, so a slow
  # announce must never cost the recovery record or the wake.
  rm -f "\$MARK"
  printf '%s up voice loop recovered after %s down\n' "\$NOW" "\$GONE" >> "\$LOG"
  printf 'glasses voice loop recovered after %s down\n' "\$GONE"
  # The only line that can actually reach his ear about a mailbox outage: while
  # it was down, the glasses had no channel at all.
  "\$ANNOUNCE" "The voice loop dropped for \$GONE and is back up now." >/dev/null 2>&1
  exit 0
fi

[ ! -e "\$MARK" ] || exit 0
date +%s > "\$MARK"
printf '%s down voice loop health check answered %s\n' "\$NOW" "\${CODE:-nothing}" >> "\$LOG"
printf 'glasses voice loop is down: health answered %s\n' "\${CODE:-nothing}"
exit 0
CHECK_EOF
  chmod 0700 "$tmp" || { rm -f "$tmp"; return 1; }
  mv -f "$tmp" "$CHECK" || { rm -f "$tmp"; return 1; }
}

# ---------------------------------------------------------------------------
# Supervision alarms into the glasses, through the existing config/wedge-alarm
# command: channel. A sentinel-delimited block so stop removes exactly this and
# never a directive the captain wrote himself.
# ---------------------------------------------------------------------------
wedge_block_remove() {
  local tmp
  [ -f "$WEDGE_CONFIG" ] || return 0
  grep -Fqx "$WEDGE_BEGIN" "$WEDGE_CONFIG" || return 0
  tmp=$(mktemp "$CONFIG/.fm-shift-wedge.XXXXXX") || return 1
  awk -v begin="$WEDGE_BEGIN" -v end="$WEDGE_END" '
    $0 == begin { skip = 1; next }
    $0 == end { skip = 0; next }
    !skip { print }' "$WEDGE_CONFIG" > "$tmp" || { rm -f "$tmp"; return 1; }
  if grep -qE '[^[:space:]]' "$tmp"; then
    mv -f "$tmp" "$WEDGE_CONFIG" || { rm -f "$tmp"; return 1; }
  else
    rm -f "$tmp" "$WEDGE_CONFIG" || return 1
  fi
}

wedge_block_install() {
  local lead=
  wedge_block_remove || return 1
  mkdir -p "$CONFIG" || return 1
  if [ -s "$WEDGE_CONFIG" ] && [ -n "$(tail -c1 "$WEDGE_CONFIG")" ]; then
    lead=$'\n'
  fi
  {
    printf '%s%s\n' "$lead" "$WEDGE_BEGIN"
    # shellcheck disable=SC2016  # $1 must stay literal: the channel owner runs this through `sh -c "<cmd>" fm-wedge-alarm "<summary>"`.
    printf 'command:%s alarm "$1"\n' "$(printf '%q' "$SCRIPT_DIR/fm-shift.sh")"
    printf '%s\n' "$WEDGE_END"
  } >> "$WEDGE_CONFIG" || return 1
}

# ---------------------------------------------------------------------------
# Commands.
# ---------------------------------------------------------------------------
FAILED_LINES=()
FAILED_FIXES=()
OK_LINES=()

run_probe() {  # <probe function>
  if "$1"; then
    OK_LINES+=("$PROBE_LINE")
    return 0
  fi
  FAILED_LINES+=("$PROBE_LINE")
  FAILED_FIXES+=("$PROBE_FIX")
  return 1
}

kickstart_agent() {  # <label>
  have launchctl || return 1
  launchctl kickstart -k "$GUI_DOMAIN/$1" >/dev/null 2>&1
}

# Bring the mailbox back the way the runbook prescribes - through launchd, never
# a second copy - and wait for /health rather than assuming the restart worked.
remediate_mailbox() {
  local waited=0
  kickstart_agent "$MAILBOX_LABEL" || return 1
  while [ "$waited" -lt "$HEALTH_WAIT" ]; do
    sleep 1
    waited=$((waited + 1))
    mailbox_healthy && return 0
  done
  return 1
}

remediate_serve() {
  have tailscale || return 1
  tailscale serve --bg "--https=$SERVE_PORT" "http://127.0.0.1:$MAILBOX_PORT" >/dev/null 2>&1 || return 1
  serve_mapping_armed
}

refuse() {
  local i
  printf 'REFUSED: the shift loop is NOT armed.\n\n' >&2
  for i in "${!FAILED_LINES[@]}"; do
    printf '  %s\n' "${FAILED_LINES[$i]}" >&2
    [ -z "${FAILED_FIXES[$i]}" ] || printf '      fix: %s\n' "${FAILED_FIXES[$i]}" >&2
  done
  printf '\nNothing was armed, on purpose: a half-armed shift is worse than a refused one.\n' >&2
  exit 1
}

cmd_start() {
  local rearm=false started_epoch
  [ -f "$ARMED" ] && rearm=true

  run_probe probe_power || true
  run_probe probe_keepawake || true

  if ! probe_mailbox; then
    remediate_mailbox
    run_probe probe_mailbox || true
  else
    OK_LINES+=("$PROBE_LINE")
  fi

  run_probe probe_announce || true

  if ! probe_serve; then
    remediate_serve
    run_probe probe_serve || true
  else
    OK_LINES+=("$PROBE_LINE")
  fi

  run_probe probe_supervision || true

  [ "${#FAILED_LINES[@]}" -eq 0 ] || refuse

  if ! "$AFK_LAUNCH" start; then
    FAILED_LINES+=('away mode: DOWN - it would not start')
    FAILED_FIXES+=("run $AFK_LAUNCH start by hand and read its error; without away mode firstmate stops answering the moment you leave")
    refuse
  fi

  started_epoch=$(now_epoch)
  if [ "$rearm" = false ]; then
    # Scoped umask: the armed record is private, and nothing else this run
    # writes should inherit the tighter mask.
    if ! ( umask 077; {
             printf 'started_epoch=%s\n' "$started_epoch"
             printf 'started_iso=%s\n' "$(now_iso)"
           } > "$ARMED" ); then
      warn 'could not record the armed shift; away mode is running, stand it down with fm-shift.sh stop'
      exit 1
    fi
    append_log armed 'shift armed'
  fi

  if ! write_check || ! "$SCRIPT_DIR/fm-check-register.sh" "$SHIFT_ID" >/dev/null; then
    rm -f "$CHECK" "$CHECK_TRUST"
    [ "$rearm" = true ] || rm -f "$ARMED"
    FAILED_LINES+=('outage self-check: DOWN - it could not be registered')
    FAILED_FIXES+=('without it an outage while you are out would reach you as silence; away mode is still running, stand it down with fm-shift.sh stop')
    refuse
  fi

  local alarm_note=
  if ! wedge_block_install; then
    alarm_note='WARNING: a supervision outage will NOT be spoken into your glasses; the alarm route could not be installed.'
  elif ! probe_alarm_route; then
    alarm_note="WARNING: $PROBE_LINE - ${PROBE_FIX}."
  fi

  say 'Shift loop armed.'
  local line
  for line in "${OK_LINES[@]+"${OK_LINES[@]}"}"; do say "  $line"; done
  say '  away mode: ok - firstmate answers while you are out'
  say '  outage self-check: ok - an outage wakes firstmate and is spoken when the loop returns'
  if [ -z "$alarm_note" ]; then
    say '  supervision alarm: ok - the host sentinel speaks a watcher outage into the glasses within minutes'
  else
    say "  $alarm_note"
  fi
  say ''
  say 'Stand it down with: fm-shift.sh stop'

  if ! "$ANNOUNCE" "$ARM_LINE" >/dev/null 2>&1; then
    warn 'the confirmation could not be spoken into the glasses, though every check passed - do not leave until you have heard one'
    exit 1
  fi
  return 0
}

# Read one key from the armed record.
armed_field() {  # <key>
  [ -f "$ARMED" ] || return 1
  sed -n "s/^$1=//p" "$ARMED" | head -1
}

# Questions the captain asked while the shift ran, straight from the mailbox.
# Read-only and best effort: an unreadable database reports as unknown rather
# than as zero.
shift_mailbox_line() {  # <started_iso>
  local since=$1 counts total answered
  have sqlite3 || { printf 'questions asked: unknown (no sqlite3 to read the mailbox)\n'; return 0; }
  [ -f "$MAILBOX_DB" ] || { printf 'questions asked: unknown (no mailbox database)\n'; return 0; }
  counts=$(sqlite3 "file:$MAILBOX_DB?mode=ro" \
    "SELECT count(*), sum(state = 'answered') FROM requests WHERE created_at >= '$since';" 2>/dev/null) || {
    printf 'questions asked: unknown (the mailbox database could not be read)\n'
    return 0
  }
  total=${counts%%|*}
  answered=${counts##*|}
  [ -n "$total" ] || total=0
  case "$answered" in ''|*[!0-9]*) answered=0 ;; esac
  printf 'questions asked: %s (%s answered)\n' "$total" "$answered"
}

# Outage episodes this shift, from the self-check's own durable log lines.
shift_outage_line() {  # <started_iso>
  local downs ups
  [ -f "$SHIFT_LOG" ] || { printf 'interruptions: none\n'; return 0; }
  downs=$(awk -v since="$1" '$2 == "down" && $1 >= since' "$SHIFT_LOG" | wc -l | tr -d ' ')
  ups=$(awk -v since="$1" '$2 == "up" && $1 >= since' "$SHIFT_LOG" | wc -l | tr -d ' ')
  if [ "$downs" -eq 0 ]; then
    printf 'interruptions: none\n'
  elif [ "$ups" -ge "$downs" ]; then
    printf 'interruptions: %s, and the loop came back each time\n' "$downs"
  else
    printf 'interruptions: %s, and the loop was still down when you got back\n' "$downs"
  fi
}

cmd_stop() {
  local started_epoch started_iso now ran

  if [ ! -f "$ARMED" ]; then
    # Safe to run with nothing armed: clear any arming that outlived a shift so
    # a stale check can never speak, and leave away mode alone - it may be on
    # for something that has nothing to do with a shift.
    rm -f "$CHECK" "$CHECK_TRUST" "$OUTAGE_MARK" "$LEGACY_STATUS_FILE"
    wedge_block_remove || warn "could not tidy the alarm route in $WEDGE_CONFIG"
    say 'No shift is armed. Nothing to stand down.'
    return 0
  fi

  started_epoch=$(armed_field started_epoch)
  started_iso=$(armed_field started_iso)
  case "$started_epoch" in ''|*[!0-9]*) started_epoch=$(now_epoch) ;; esac
  [ -n "$started_iso" ] || started_iso=$(now_iso)
  now=$(now_epoch)
  ran=$((now - started_epoch))
  [ "$ran" -ge 0 ] || ran=0

  rm -f "$CHECK" "$CHECK_TRUST" "$OUTAGE_MARK" "$LEGACY_STATUS_FILE"
  wedge_block_remove || warn "could not tidy the alarm route in $WEDGE_CONFIG"

  # Hand away mode back to its own return owner first, so the shift report below
  # is one block rather than a block wrapped around that owner's output. The
  # armed record is dropped only once away mode has genuinely stopped, so a
  # failed return leaves a shift for the next stop to retry rather than an
  # away daemon nothing claims any more.
  local away_out away_rc=0
  away_out=$("$AFK_RETURN" 2>&1) || away_rc=$?
  if [ ! -e "$STATE/.afk" ]; then
    rm -f "$ARMED"
    append_log stood-down 'shift stood down'
  fi

  say 'Shift stood down.'
  say "  ran: $(duration_text "$ran") ($(local_hm "$started_epoch") to $(local_hm "$now"))"
  say "  $(shift_mailbox_line "$started_iso")"
  say "  $(shift_outage_line "$started_iso")"
  local rc=0
  if [ -e "$STATE/.afk" ]; then
    rc=1
    say "  away mode: STILL RUNNING - its return owner could not stop it; run fm-shift.sh stop again to retry, or stop it by hand with $AFK_LAUNCH stop, then run $AFK_RETURN"
    printf '%s\n' "$away_out" | sed 's/^/      /'
  elif [ "$away_rc" -eq 0 ]; then
    say '  away mode: stopped'
  else
    say '  away mode: stopped, and there is catch-up to clear before ordinary work resumes:'
    printf '%s\n' "$away_out" | sed 's/^/      /'
  fi
  say '  left running: the mailbox, the keep-awake agent and the phone route (you use those at your desk too)'
  return "$rc"
}

cmd_status() {
  local armed=false rc=0
  [ -f "$ARMED" ] && armed=true

  if [ "$armed" = true ]; then
    say "shift: armed since $(local_hm "$(armed_field started_epoch)")"
  else
    say 'shift: not armed'
  fi

  local p
  for p in probe_power probe_keepawake probe_mailbox probe_announce probe_serve \
           probe_supervision probe_away probe_selfcheck probe_alarm_route; do
    if "$p"; then
      say "  $PROBE_LINE"
    else
      say "  $PROBE_LINE"
      [ -z "$PROBE_FIX" ] || say "      fix: $PROBE_FIX"
      rc=1
    fi
  done

  [ "$armed" = true ] || return 0
  return "$rc"
}

# The spoken end of the config/wedge-alarm command: channel. The raw summary
# carries task ids and durations that must never be spoken, so it is read only
# to tell the two alarm kinds apart, never relayed.
cmd_alarm() {
  local summary=${1:-} line
  [ -f "$ARMED" ] || return 0
  case "$summary" in
    *'SUPERVISION DOWN'*)
      line='Firstmate stopped watching. Your questions are not being picked up until that is fixed.' ;;
    *)
      line='Firstmate is stuck and is not picking up your questions right now.' ;;
  esac
  [ -x "$ANNOUNCE" ] || return 1
  "$ANNOUNCE" "$line" >/dev/null 2>&1
}

case "${1:-}" in
  start) shift; cmd_start "$@" ;;
  stop) shift; cmd_stop "$@" ;;
  status) shift; cmd_status "$@" ;;
  alarm) shift; cmd_alarm "$@" ;;
  -h|--help|help) usage ;;
  *) usage >&2; exit 2 ;;
esac
