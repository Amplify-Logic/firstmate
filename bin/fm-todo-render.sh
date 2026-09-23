#!/usr/bin/env bash
# Deterministic renderer for the day's Lavish to-do page.
#
# Usage:
#   fm-todo-render.sh render [--out FILE] [--morning-section FILE]
#                            [--date YYYY-MM-DD] [--if-exists]
#   fm-todo-render.sh path [--date YYYY-MM-DD]
#   fm-todo-render.sh settings      (timezone= and sources_file= for fm-todo.sh)
#   fm-todo-render.sh --help
#
# WHAT THIS IS. A DETERMINISTIC RENDERER over the to-do item store. It makes
# NO model call, opens no network connection and reads no source system. Each
# render first runs `bin/fm-todo.sh sync`, which folds the channel ledger, the
# morning sidecar and the captain-held backlog into data/todo, and then writes
# .lavish/today-<YYYY-MM-DD>.html from those item records alone. bin/fm-todo.sh
# owns the item record, identity, verification, reopening and page commands.
# Running it twice over unchanged records at the same minute produces the same
# bytes, which is what lets the 30-minute channel read refresh the page.
#
# NOTHING IS INVENTED AND NOTHING IS READ BACK. An earlier version of the page
# is never read for content. That is the mechanical half of the
# `daily-todo-freshness` contract - the verification half stays with the
# orchestrator that records each re-read with `fm-todo.sh verify`.
#
# PAGE SHAPE. One "Needs you now" list of every open decision, approval and
# reply, in action order: first a live problem or hard deadline (class outage
# or deadline), then a partner-facing ask awaiting him (`partner_first`,
# oldest ask first), then everything else by class, newest read first. An
# urgent class alone - which a long wait earns - never lifts a line into the
# first tier. There is no summary strip, no separate Now box and no sweep
# banner, and no item renders twice. A captain-held backlog decision no read
# made current stays off the page; the backlog still holds it. Fleet
# conditions follow, then collapsed folds for waiting on others (including
# requested handoffs), other channel activity (its lines not current for this
# build in one capped "not re-checked" fold), everything closed since the
# previous sweep ("Closed today" when that is the start of the day) with its
# evidence and actor, parked, "mine" and the email agent block; then the live
# "Your open tickets" fold, whose summary keeps its read time or out-of-date
# label, the morning detail fragment (calendar, worth knowing) and the intake
# coverage fold (each enrolled source's last successful read and last
# failure, which is separate from item freshness). Routine chatter the intake
# dropped from its ledger was never an ask and is not a closure. Sections with
# nothing in them are omitted. The closed fold counts as "handled without
# you" only a fulfilled close with a named actor other than the captain.
#
# EACH ROW IS THE CLASS BADGE, THE ASK, AT MOST ONE SHORT CONTEXT LINE (a
# reopen note, else the why, else the ask's wording), ITS READ TIME, the Open
# link and a "note" toggle. Where the line came from and how it was read stay
# in the row's data-source and data-how attributes for audit, never in the
# visible text. The toggle opens a one-line box that queues the typed line
# into the open Lavish review session with the item's id and the revision the
# page showed, so bin/fm-todo.sh can apply a page command to exactly the ask
# he was looking at; with no review session connected the box says so and
# queues nothing. Routine activity and the list-style folds carry no box.
#
# YOUR OPEN TICKETS IS LIVE. That section is rendered on every build from
# data/channel-intake/tickets.json, which `bin/fm-channel-intake.sh tickets`
# alone writes and whose header owns the format: the count with its stage
# breakdown, each ticket's stage exactly as stored, and the snapshot's own
# read time, in one collapsed fold whose summary carries that read time. A
# snapshot older than two of the intake's configured
# `interval_seconds` polls, and never less than an hour, is headed out of date
# with that read time and never called live; a missing or unreadable one says
# the tickets could not be read. Any "Your open tickets" section in a morning
# detail file, at any depth, is dropped with everything after it up to the
# next h2, because it is always an older read than the snapshot.
#
# FRESHNESS IS ON EVERY LINE. A line is "read <time>" only when its recorded
# check is at or after this build's sweep (or the start of the day) and
# checked the revision shown; otherwise "not re-checked since <time>", or
# "cannot verify" when no read was ever recorded. The page header carries the
# render time separately, so build time and read time are never confused.
#
# MORNING COMPOSITION CONTRACT (version 1, or 2 with the optional fields):
# details-only context such as the calendar goes in today-<date>.morning.html,
# action metadata in today-<date>.morning.json: {version, date:"YYYY-MM-DD",
# actions:[{key, source, ref, class, title, link, updated}], and in version 2
# optionally sweep_started (epoch the day's verification pass began),
# email_agent_source (the named next-actions report for the email agent block,
# relative to the home) and per action kind (decision|approval|reply|info,
# default decision), ask, why, verified_how, digest (a fingerprint of the ask,
# the only thing that may reopen a closed item) and aliases (extra
# `source:ref` identities of the SAME ask), partner_awaiting (the JSON boolean
# true for a partner-facing ask awaiting him) and awaiting_since (epoch second
# of that ask; an ask with none sorts after every dated partner ask)}.
# A partner-facing ask awaiting him - flagged here or by the channel intake's
# timeline assessment - ranks in the page's partner tier, oldest ask first. `updated` is the SAME-DAY
# verification epoch from daily-todo-freshness. Decisions and waiting-on-you
# lines belong only in actions, never duplicated in the details HTML. The
# fragment must not contain a document shell/header/h1. Invalid supplied
# metadata fails the render and changes neither the store nor the page;
# legacy HTML without metadata stays in a closed historical-reference
# disclosure, and its pilot-connectivity prose is omitted.
#
# THE EMAIL AGENT BLOCK is dated reference read from the report the sidecar
# names, labelled with that file's written time; it is never treated as
# fresh obligations and no file is picked by guessing the newest.
#
# HOUSE STYLE COMES FROM A TEMPLATE, NOT FROM LAVISH. bin/templates/
# today-page.head.html and today-page.foot.html hold the head, the styles and
# the legend, derived from the hand-authored .lavish/today-2026-09-15.html that
# set the house style. The page therefore renders identically with nothing
# else installed and no visual tool running.
#
# Configuration is read - never written - from the private, gitignored
# config/channel-intake, and only the three keys this renderer needs:
#   timezone          IANA zone for the local day and every rendered time
#   sources_file      private inventory, read only for a source's coverage label
#   interval_seconds  the intake's poll cadence, default 900; two of those
#                     polls, and never less than an hour, is how long an
#                     open-tickets snapshot still counts as live
# A value this renderer rejects for one of those three exits 2, as it does for
# a missing template. Every other key belongs to bin/fm-channel-intake.sh,
# which owns that file.
set -eu

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$ROOT}}"
CONFIG="${FM_CONFIG_OVERRIDE:-$FM_HOME/config}"
DATA="${FM_DATA_OVERRIDE:-$FM_HOME/data}"
LAVISH_DIR="${FM_LAVISH_OVERRIDE:-$FM_HOME/.lavish}"
CONFIG_FILE="$CONFIG/channel-intake"
INTAKE_DIR="$DATA/channel-intake"
STORE="${FM_TODO_STORE_OVERRIDE:-$DATA/todo}"
TEMPLATE_DIR="${FM_TODO_TEMPLATE_DIR:-$SCRIPT_DIR/templates}"
HEAD_TEMPLATE="$TEMPLATE_DIR/today-page.head.html"
FOOT_TEMPLATE="$TEMPLATE_DIR/today-page.foot.html"

CFG_TIMEZONE=
CFG_SOURCES_FILE=
CFG_INTERVAL=900

usage() {
  awk '
    NR == 1 { next }
    /^#/ { sub(/^# ?/, ""); print; next }
    { exit }
  ' "$0" >&2
}

die() {
  printf 'fm-todo-render: %s\n' "$*" >&2
  exit 2
}

# --- configuration ----------------------------------------------------------

# Same proof bin/fm-channel-intake.sh takes: date(1) treats a zone it cannot
# resolve as UTC and still exits 0, which would silently move both the local
# day and every stamped read time on the page.
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

# Deliberately tolerant of keys this renderer does not use: the gate owns that
# file and already refuses an unknown key, so refusing again here would only
# break the renderer whenever a knob is added to the gate.
load_config() {
  local line key value
  [ -f "$CONFIG_FILE" ] && [ ! -L "$CONFIG_FILE" ] || return 0
  while IFS= read -r line || [ -n "$line" ]; do
    line=$(printf '%s\n' "$line" | sed -E 's/^[[:space:]]+//; s/[[:space:]]+$//')
    case "$line" in ''|'#'*) continue ;; esac
    case "$line" in *=*) ;; *) continue ;; esac
    key=$(printf '%s\n' "${line%%=*}" | tr -d '[:space:]')
    value=$(printf '%s\n' "${line#*=}" | sed -E 's/^[[:space:]]+//; s/[[:space:]]+$//')
    case "$key" in
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
        case "$value" in
          ''|*[!0-9]*|0) die "interval_seconds must be a positive integer: $value" ;;
        esac
        CFG_INTERVAL=$value
        ;;
      sources_file)
        case "$value" in
          /*) CFG_SOURCES_FILE=$value ;;
          *) die "sources_file must be an absolute path: $value" ;;
        esac
        ;;
    esac
  done <"$CONFIG_FILE"
  [ -n "$CFG_SOURCES_FILE" ] || CFG_SOURCES_FILE="$INTAKE_DIR/sources.tsv"
}

# --- clock ------------------------------------------------------------------

now_epoch() {
  local value=${FM_TODO_RENDER_NOW:-}
  if [ -n "$value" ]; then
    case "$value" in
      ''|*[!0-9]*) die "FM_TODO_RENDER_NOW must be an epoch second: $value" ;;
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

# --- composition ------------------------------------------------------------

render_page() {
  local epoch=$1 day=$2 morning=$3 sidecar=$4
  [ -f "$HEAD_TEMPLATE" ] && [ ! -L "$HEAD_TEMPLATE" ] \
    || die "house-style head template is missing: $HEAD_TEMPLATE"
  [ -f "$FOOT_TEMPLATE" ] && [ ! -L "$FOOT_TEMPLATE" ] \
    || die "house-style foot template is missing: $FOOT_TEMPLATE"
  awk -v title="Today - $(local_fmt "$epoch" '%A %-d %B %Y')" \
    '{ gsub(/\{\{TITLE\}\}/, title); print }' "$HEAD_TEMPLATE"
  printf '<header><div><div class="kicker">Aquablu Starship</div><h1>Today</h1></div>\n'
  printf '<div class="meta">%s<br>Page rebuilt from the to-do records at <span class="mono">%s</span>.<br>Each line carries its own last check.</div></header>\n' \
    "$(local_fmt "$epoch" '%A %-d %B %Y')" "$(local_fmt "$epoch" '%H:%M %Z')"
  python3 "$SCRIPT_DIR/fm-todo-compose.py" "$STORE" "$morning" "$day" "$epoch" "$CFG_TIMEZONE" \
    "$FM_HOME" "$sidecar" "$INTAKE_DIR" "$CFG_SOURCES_FILE" "$CFG_INTERVAL" || return 1
  cat "$FOOT_TEMPLATE"
}

page_path() {
  local day=$1
  printf '%s/today-%s.html\n' "$LAVISH_DIR" "$day"
}

default_morning_section() {
  local out=$1
  printf '%s\n' "${out%.html}.morning.html"
}

write_atomic() {
  local dest=$1 body=$2 parent tmp
  parent=${dest%/*}
  mkdir -p "$parent"
  tmp=$(umask 077; mktemp "$parent/.todo-render.XXXXXX") || return 1
  printf '%s\n' "$body" >"$tmp" || { rm -f "$tmp"; return 1; }
  chmod 600 "$tmp"
  mv -f "$tmp" "$dest"
}

resolve_day() {
  local day=$1
  [ -n "$day" ] || return 0
  printf '%s\n' "$day" | grep -Eq '^[0-9]{4}-[0-9]{2}-[0-9]{2}$' \
    || die "--date must be YYYY-MM-DD: $day"
}

render_cmd() {
  local out='' morning='' day='' if_exists=false epoch body sidecar
  while [ "$#" -gt 0 ]; do
    case "$1" in
      --out) [ "$#" -ge 2 ] || die '--out requires a value'; out=$2; shift 2 ;;
      --morning-section) [ "$#" -ge 2 ] || die '--morning-section requires a value'; morning=$2; shift 2 ;;
      --date) [ "$#" -ge 2 ] || die '--date requires a value'; day=$2; shift 2 ;;
      --if-exists) if_exists=true; shift ;;
      *) die "unknown render argument: $1" ;;
    esac
  done
  resolve_day "$day"
  epoch=$(now_epoch)
  [ -n "$day" ] || day=$(local_date "$epoch")
  if [ -n "$out" ]; then
    case "$out" in
      /*) ;;
      *) die "--out must be an absolute path: $out" ;;
    esac
    case "/$out/" in
      */../*) die "--out must not contain a .. path component: $out" ;;
    esac
  else
    out=$(page_path "$day")
  fi
  # The 30-minute refresh path passes this: a home that never wrote a morning
  # page is not having one manufactured for it by a background read.
  if [ "$if_exists" = true ] && { [ ! -f "$out" ] || [ -L "$out" ]; }; then
    printf 'TODO_RENDER: no page at %s yet; nothing refreshed\n' "$out"
    return 0
  fi
  if [ -z "$morning" ]; then
    morning=$(default_morning_section "$out")
    [ -f "$morning" ] && [ ! -L "$morning" ] || morning=''
  else
    case "$morning" in
      /*) ;;
      *) die "--morning-section must be an absolute path: $morning" ;;
    esac
    [ -f "$morning" ] && [ ! -L "$morning" ] \
      || die "--morning-section is not a regular file: $morning"
  fi
  sidecar="${out%.html}.morning.json"
  [ -z "$morning" ] || sidecar="${morning%.html}.json"
  [ -f "$sidecar" ] && [ ! -L "$sidecar" ] || sidecar=''
  # The store is folded first and the page composed only from it; a refused
  # sidecar changes neither the store nor the page.
  FM_TODO_NOW="$epoch" "$SCRIPT_DIR/fm-todo.sh" sync --morning-json "$sidecar" >/dev/null \
    || die "item sync failed; existing page preserved"
  body=$(render_page "$epoch" "$day" "$morning" "$sidecar") || die "composition failed; existing page preserved"
  write_atomic "$out" "$body" || die "cannot write the page: $out"
  printf 'TODO_RENDER: %s rendered at %s\n' "$out" "$(local_fmt "$epoch" '%H:%M %Z')"
}

path_cmd() {
  local day='' epoch
  while [ "$#" -gt 0 ]; do
    case "$1" in
      --date) [ "$#" -ge 2 ] || die '--date requires a value'; day=$2; shift 2 ;;
      *) die "unknown path argument: $1" ;;
    esac
  done
  resolve_day "$day"
  epoch=$(now_epoch)
  [ -n "$day" ] || day=$(local_date "$epoch")
  page_path "$day"
}

load_config

case "${1:-}" in
  render) shift; render_cmd "$@" ;;
  path) shift; path_cmd "$@" ;;
  settings) printf 'timezone=%s\nsources_file=%s\n' "$CFG_TIMEZONE" "$CFG_SOURCES_FILE" ;;
  -h|--help) usage ;;
  '') usage; exit 2 ;;
  *) die "unknown command: $1" ;;
esac
