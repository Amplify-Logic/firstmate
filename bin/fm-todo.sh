#!/usr/bin/env bash
# The daily to-do's durable item store: one record per thing asked of the captain.
#
# Usage:
#   fm-todo.sh sync [--morning-json FILE]
#   fm-todo.sh sweep-start [--at EPOCH]
#   fm-todo.sh verify --item ID --how TEXT [--rev REV] [--at EPOCH]
#   fm-todo.sh close --item ID --evidence TEXT [--reason fulfilled|dismissed|superseded] [--actor NAME]
#   fm-todo.sh reopen --item ID [--reason TEXT]
#   fm-todo.sh ack --item ID
#   fm-todo.sh command [--item ID [--rev REV]] [LINE ...]   (lines on stdin when none given)
#   fm-todo.sh list [--state open|waiting|closed]
#   fm-todo.sh --help
#
# WHAT THIS IS. A LOCAL STORE ONLY. It never reads a source system, opens a
# network connection or sends anything. It folds durable records this home
# already holds into one item per ask, and bin/fm-todo-render.sh renders the
# day page from those items and nothing else:
#   - the channel-intake ledger (data/channel-intake items/ and archive/);
#   - the morning action sidecar .lavish/today-<date>.morning.json, whose
#     schema bin/fm-todo-render.sh owns;
#   - captain-held tasks in the markdown backlog, `(hold-kind: captain)`.
# Every render runs `sync` first, so the morning sweep and the 30-minute
# intake update the same items instead of the page being re-scraped.
#
# ITEM RECORD. data/todo/items/<id>.json keeps: aliases, one slot per source
# (its last observation and its own revision), `state` open|waiting|closed,
# `closure` {reason fulfilled|dismissed|superseded|resolved|released, actor,
# evidence, at}, `owner`, `snoozed_until`, `pending` handoff, `verification`
# {at, how, rev} and `rev`, the item's meaningful revision over its slots.
# data/todo/journal is an append-only line per transition or command effect.
# One lock serializes sync and every write.
#
# IDENTITY. An item is one ask. It is matched by an explicitly shared alias
# only: a ledger record's `source:ref`, key and provenance tokens; a morning
# action's `source:ref`, key and optional `aliases`; `firstmate-backlog:<task>`.
# Two asks on one ticket are two items unless a source says they are the same.
#
# VERIFICATION IS ITS OWN FACT. Sync never renews it. It changes only on a
# newer source read: an open ledger record's change time (an unchanged re-read
# keeps its old time, a hand-over is not a read), a morning action's same-day
# `updated`, or an explicit `verify` by the orchestrator running the
# daily-todo-freshness procedure, which owns how an item is re-read. A backlog
# hold time and a report's written time are never verification. The page calls
# a line current only when its check is at or after this build's sweep
# (`sweep-start`, or `sweep_started` in the sidecar; else the start of the
# day) and checked the revision now shown.
#
# CHANGES, NOT SNAPSHOTS. Sync applies only what changed since the last sync,
# so repeated syncs, an old sidecar and a re-asserted morning action are
# no-ops; closures and commands are tombstones that survive them. A closed
# item reopens, with the reason shown, only when one of its sources' own
# meaningful revision changes: the ledger's `edited_digest` over `digest`, a
# morning action's explicit `digest` (never its reworded title or daily key),
# a backlog hold's reason and date. Missing, unreadable or refused input closes
# nothing; a task that leaves the readable backlog's held set releases only
# that item.
#
# PAGE COMMANDS. `command` applies the captain's one-line verbs:
#   drop <words>            closed as dismissed
#   done <words>            closed as fulfilled
#   park <words> til <when> snoozed until YYYY-MM-DD, today, tomorrow, a
#                           weekday or next week; back on that day
#   mine <words>            owner=captain; tracked, not surfaced
#   you <words>: <what>     pending handoff to firstmate
#   dig <words>             pending investigation by firstmate
# Prefer --item with the row's id and --rev with the revision the page showed
# (both are in the page's queued note); a stale --rev is refused so an old page
# cannot act on a changed ask. Without --item, <words> must match exactly one
# open item's title or ask. Repeating a command is harmless (`already`).
# `you`/`dig` stay "handoff requested" on the page until firstmate accepts
# them with `ack`, which moves the item to waiting with owner firstmate;
# `reopen` brings a closed or waiting item back to the captain's lane, ending
# the hand-over, and refuses an item that is already open.
# Each line prints one `TODO_CMD:` result naming the item's source refs. A
# held backlog decision is never answered here: done/drop on one says to
# record the answer through bin/fm-captain-hold.sh, and the item releases when
# the backlog does. A line with no leading verb prints `TODO_CMD:
# not-a-command` and changes nothing. Exit 1 when any line was refused.
#
# Paths: data/todo (FM_TODO_STORE_OVERRIDE), data/channel-intake, and the
# backlog path from .tasks.toml's markdown backend (FM_TODO_BACKLOG_OVERRIDE).
# The zone and source inventory are the ones bin/fm-todo-render.sh resolves.
# FM_TODO_NOW pins the clock for tests.
set -eu

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$ROOT}}"
DATA="${FM_DATA_OVERRIDE:-$FM_HOME/data}"
STORE="${FM_TODO_STORE_OVERRIDE:-$DATA/todo}"
INTAKE_DIR="$DATA/channel-intake"

usage() {
  awk '
    NR == 1 { next }
    /^#/ { sub(/^# ?/, ""); print; next }
    { exit }
  ' "$0" >&2
}

die() {
  printf 'fm-todo: %s\n' "$*" >&2
  exit 2
}

now_epoch() {
  local value=${FM_TODO_NOW:-${FM_TODO_RENDER_NOW:-}}
  if [ -n "$value" ]; then
    case "$value" in
      *[!0-9]*) die "FM_TODO_NOW must be an epoch second: $value" ;;
    esac
    printf '%s\n' "$value"
    return 0
  fi
  date +%s
}

# The markdown backend's path from .tasks.toml, relative to this home; any
# other backend has no file to fold, so held tasks are simply not read.
backlog_path() {
  local toml="$FM_HOME/.tasks.toml" rel
  if [ -n "${FM_TODO_BACKLOG_OVERRIDE:-}" ]; then
    printf '%s\n' "$FM_TODO_BACKLOG_OVERRIDE"
    return 0
  fi
  [ -f "$toml" ] || toml="$ROOT/.tasks.toml"
  [ -f "$toml" ] || return 0
  grep -Eq '^backend[[:space:]]*=[[:space:]]*"markdown"' "$toml" || return 0
  rel=$(sed -nE '/^\[markdown\]/,/^\[/ s/^path[[:space:]]*=[[:space:]]*"([^"]+)".*/\1/p' "$toml" | head -n 1)
  [ -n "$rel" ] || return 0
  case "$rel" in
    /*) printf '%s\n' "$rel" ;;
    *) printf '%s/%s\n' "$FM_HOME" "$rel" ;;
  esac
}

# The zone and source inventory are the ones bin/fm-todo-render.sh resolves
# from config/channel-intake; this script reads them rather than a second copy.
settings=$("$SCRIPT_DIR/fm-todo-render.sh" settings) || exit 2
zone=$(printf '%s\n' "$settings" | sed -n 's/^timezone=//p')
sources=$(printf '%s\n' "$settings" | sed -n 's/^sources_file=//p')
[ -z "$zone" ] || export TZ="$zone"

case "${1:-}" in
  -h|--help) usage; exit 0 ;;
  '') usage; exit 2 ;;
esac
cmd=$1
shift
case "$cmd" in
  sync|sweep-start|verify|close|reopen|ack|command|list) ;;
  *) die "unknown command: $cmd" ;;
esac

args=()
morning=''
while [ "$#" -gt 0 ]; do
  case "$1" in
    --morning-json) [ "$#" -ge 2 ] || die '--morning-json requires a value'; morning=$2; shift 2 ;;
    --item|--how|--evidence|--at|--state|--rev|--actor|--reason)
      [ "$#" -ge 2 ] || die "$1 requires a value"; args+=("$1" "$2"); shift 2 ;;
    --*) die "unknown argument: $1" ;;
    *) args+=("$1"); shift ;;
  esac
done

exec python3 "$SCRIPT_DIR/fm-todo-items.py" "$cmd" --store "$STORE" --now "$(now_epoch)" \
  --intake "$INTAKE_DIR" --sources "$sources" --backlog "$(backlog_path)" \
  --morning-json "$morning" ${args[@]+"${args[@]}"}
