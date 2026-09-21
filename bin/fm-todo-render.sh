#!/usr/bin/env bash
# Deterministic renderer for the day's Lavish to-do page.
#
# Usage:
#   fm-todo-render.sh render [--out FILE] [--morning-section FILE]
#                            [--date YYYY-MM-DD] [--if-exists] [--open]
#   fm-todo-render.sh path [--date YYYY-MM-DD]
#   fm-todo-render.sh --help
#
# WHAT THIS IS. A PURE RENDERER. It makes NO model call, opens no network
# connection, reads no source system and never decides anything about an item.
# It reads the channel-intake ledger this home already holds and writes
# .lavish/today-<YYYY-MM-DD>.html from it. Running it twice over an unchanged
# ledger at the same minute produces the same bytes, which is what lets the
# 30-minute channel read refresh the page's ordering for free.
#
# NOTHING IS INVENTED AND NOTHING IS CARRIED FORWARD. Every line on the live
# section comes from a record in data/channel-intake/items or
# data/channel-intake/archive. An item the ledger does not hold does not
# appear, and an earlier version of the page is never read back for content:
# the page is rebuilt from the ledger each time. That is the mechanical half of
# the `daily-todo-freshness` contract - the verification half stays with the
# orchestrator that wrote those records.
#
# TWO INPUTS, ONE OUTPUT.
#   (a) The ledger. Open items become the live section, ranked by class -
#       outage, urgent, deadline, obligation, routine - and then newest
#       `updated` first inside each class, so a severe item arriving at 15:00
#       sits above a routine one from 09:00 without anyone re-ordering it by
#       hand. `automation-candidate` is a PROPOSAL and never a human
#       obligation, so it is excluded here exactly as `fm-channel-intake.sh
#       todo` excludes it. Items in `waiting` go to "Waiting on others", and
#       items archived on the rendered local day go to "Closed since morning"
#       with the resolution text the captain's own `resolve --reason` recorded.
#   (b) An OPTIONAL hand-verified morning section: the HTML body fragment the
#       orchestrator writes at 06:00 after running the `daily-todo-freshness`
#       stages. It is copied through byte for byte below the live section and
#       is never parsed, rewritten or re-ordered, because those lines were
#       verified by hand and this renderer cannot re-verify them. Its default
#       path is the page path with `.html` replaced by `.morning.html`.
#       Absent, the page simply has no morning section.
#
# PROVENANCE IS ON EVERY LINE. Each live row carries its source label and the
# ledger's `updated` stamp rendered in the configured local zone, which is the
# time that item was last read from its channel. The page header carries the
# render time separately, so "when was this page built" and "when was this line
# read" can never be confused for each other.
#
# HOUSE STYLE COMES FROM A TEMPLATE, NOT FROM LAVISH. bin/templates/
# today-page.head.html and today-page.foot.html hold the head, the styles and
# the legend, derived from the hand-authored .lavish/today-2026-09-15.html that
# set the house style. The page therefore renders identically with nothing
# else installed and no visual tool running.
#
# Configuration is read - never written - from the private, gitignored
# config/channel-intake, and only the two keys this renderer needs:
#   timezone      IANA zone for the local day and every rendered time
#   sources_file  private inventory, read only for a source's coverage label
# Every other key belongs to bin/fm-channel-intake.sh, which owns that file.
set -eu

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$ROOT}}"
CONFIG="${FM_CONFIG_OVERRIDE:-$FM_HOME/config}"
DATA="${FM_DATA_OVERRIDE:-$FM_HOME/data}"
LAVISH_DIR="${FM_LAVISH_OVERRIDE:-$FM_HOME/.lavish}"
CONFIG_FILE="$CONFIG/channel-intake"
INTAKE_DIR="$DATA/channel-intake"
ITEM_DIR="$INTAKE_DIR/items"
ARCHIVE_DIR="$INTAKE_DIR/archive"
TEMPLATE_DIR="${FM_TODO_TEMPLATE_DIR:-$SCRIPT_DIR/templates}"
HEAD_TEMPLATE="$TEMPLATE_DIR/today-page.head.html"
FOOT_TEMPLATE="$TEMPLATE_DIR/today-page.foot.html"

# The live section's rank order. First token is the most urgent, and the whole
# order is stated once here so the ordering cannot drift between the ranking
# and the rendering.
RANKED_CLASSES='outage urgent deadline obligation routine'

CFG_TIMEZONE=
CFG_SOURCES_FILE=

# A NON-whitespace separator, the same one bin/fm-channel-intake.sh writes its
# scanned columns with: tab is an IFS whitespace character, so `read` would
# merge two adjacent empty columns into one and shift every later field.
FIELD_SEP=$'\037'

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

# --- ledger reading ---------------------------------------------------------

for_each_item() {
  local dir=$1 f
  [ -d "$dir" ] || return 0
  for f in "$dir"/*; do
    [ -f "$f" ] && [ ! -L "$f" ] || continue
    printf '%s\n' "$f"
  done
}

# One awk process for the whole directory rather than one per field per record,
# the same bound bin/fm-channel-intake.sh's own surfaces take, so refreshing
# the page on every 30-minute read stays cheap as the ledger grows.
scan_records() {
  local dir=$1 files
  shift
  files=$(for_each_item "$dir")
  [ -n "$files" ] || return 0
  # shellcheck disable=SC2016
  printf '%s\n' "$files" | tr '\n' '\0' | xargs -0 awk -v keylist="$*" '
    function flush(   i, out) {
      if (path == "") return
      out = path
      for (i = 1; i <= nk; i++) { out = out "\037" val[i]; val[i] = "" }
      print out
      path = ""
    }
    BEGIN { nk = split(keylist, keys, " ") }
    FNR == 1 { flush(); path = FILENAME }
    {
      for (i = 1; i <= nk; i++) {
        if (index($0, keys[i] "=") == 1) val[i] = substr($0, length(keys[i]) + 2)
      }
    }
    END { flush() }
  '
}

# The coverage sentence the private inventory records for a source, which is
# the honest label for "where was this read". Absent from the inventory, the
# source id itself is printed rather than a guess.
source_label() {
  local id=$1 label=
  [ -n "$id" ] || { printf 'unattributed\n'; return 0; }
  if [ -f "$CFG_SOURCES_FILE" ] && [ ! -L "$CFG_SOURCES_FILE" ]; then
    label=$(awk -F'\t' -v want="$id" '$1 == want { print $2; exit }' "$CFG_SOURCES_FILE")
  fi
  if [ -n "$label" ]; then
    printf '%s (%s)\n' "$label" "$id"
  else
    printf '%s\n' "$id"
  fi
}

# --- html -------------------------------------------------------------------

esc() {
  printf '%s' "${1:-}" \
    | LC_ALL=C sed -e 's/&/\&amp;/g' -e 's/</\&lt;/g' -e 's/>/\&gt;/g' \
        -e 's/"/\&quot;/g' -e "s/'/\&#39;/g"
}

class_pill() {
  case "$1" in
    outage) printf 'bad\n' ;;
    urgent) printf 'warn\n' ;;
    deadline) printf 'warn\n' ;;
    obligation) printf 'info\n' ;;
    *) printf 'ok\n' ;;
  esac
}

class_rank() {
  local want=$1 c rank=0
  for c in $RANKED_CLASSES; do
    rank=$((rank + 1))
    [ "$c" != "$want" ] || { printf '%s\n' "$rank"; return 0; }
  done
  printf '99\n'
}

is_ranked_class() {
  local want=$1 c
  for c in $RANKED_CLASSES; do
    [ "$c" != "$want" ] || return 0
  done
  return 1
}

link_cell() {
  local link=$1
  if [ -n "$link" ]; then
    printf '<td class="links"><a href="%s" target="_blank" rel="noreferrer">Open</a></td>' \
      "$(esc "$link")"
  else
    printf '<td class="links"><span class="nolink">no link recorded</span></td>'
  fi
}

# --- sections ---------------------------------------------------------------

# Open items, ranked. The sort key is built here rather than in awk so the
# class order stays the single list above: rank, then descending `updated` so
# the newest arrival leads its class, then the key so two records stamped in
# the same second still render in one fixed order.
live_rows() {
  local path state class title link source updated rows='' rank sorted
  local item_class item_title item_link item_source item_updated
  while IFS="$FIELD_SEP" read -r path state class title link source updated; do
    [ -n "$path" ] || continue
    [ "$state" = open ] || continue
    is_ranked_class "$class" || continue
    case "$updated" in ''|*[!0-9]*) updated=0 ;; esac
    rank=$(class_rank "$class")
    rows="$rows$rank$FIELD_SEP$updated$FIELD_SEP${path##*/}$FIELD_SEP$class$FIELD_SEP$title$FIELD_SEP$link$FIELD_SEP$source$FIELD_SEP$updated
"
  done <<EOF
$(scan_records "$ITEM_DIR" state class title link source updated)
EOF
  [ -n "$(printf '%s' "$rows" | tr -d '[:space:]')" ] || return 0
  sorted=$(printf '%s' "$rows" | LC_ALL=C sort -t"$FIELD_SEP" -k1,1n -k2,2nr -k3,3)
  while IFS="$FIELD_SEP" read -r _ _ _ item_class item_title item_link item_source item_updated; do
    [ -n "$item_class" ] || continue
    printf '<tr><td class="who">%s<span class="org">%s</span></td>\n' \
      "$(esc "$item_class")" "$(esc "$(source_label "$item_source")")"
    printf '<td class="what">%s<span class="prov obs">read %s</span></td>\n' \
      "$(esc "${item_title:-untitled item}")" \
      "$(esc "$(local_fmt "$item_updated" '%H:%M %Z')")"
    printf '<td class="since"><span class="lab">class</span><span class="pill %s">%s</span></td>\n' \
      "$(class_pill "$item_class")" "$(esc "$item_class")"
    printf '%s</tr>\n' "$(link_cell "$item_link")"
  done <<EOF
$sorted
EOF
}

waiting_rows() {
  local path state class title link source updated resolution
  while IFS="$FIELD_SEP" read -r path state class title link source updated resolution; do
    [ -n "$path" ] || continue
    [ "$state" = waiting ] || continue
    case "$updated" in ''|*[!0-9]*) updated=0 ;; esac
    printf '<li><b>%s</b> - %s<span class="why">%s, handed over %s</span></li>\n' \
      "$(esc "${title:-untitled item}")" \
      "$(esc "${resolution:-no hand-over note recorded}")" \
      "$(esc "$(source_label "$source")")" \
      "$(esc "$(local_fmt "$updated" '%H:%M %Z')")"
  done <<EOF
$(scan_records "$ITEM_DIR" state class title link source updated resolution)
EOF
}

# Archived on the RENDERED local day only. An older archive is history, not
# something that closed since this morning, and printing it would quietly
# reopen yesterday's page inside today's.
closed_rows() {
  local day=$1 path state title source resolved_at resolution rows sorted
  local r_title r_source r_resolution r_at
  rows=''
  while IFS="$FIELD_SEP" read -r path state title source resolved_at resolution; do
    [ -n "$path" ] || continue
    [ "$state" = archived ] || continue
    case "$resolved_at" in ''|*[!0-9]*) continue ;; esac
    [ "$(local_date "$resolved_at")" = "$day" ] || continue
    rows="$rows$resolved_at$FIELD_SEP${path##*/}$FIELD_SEP$title$FIELD_SEP$source$FIELD_SEP$resolution$FIELD_SEP$resolved_at
"
  done <<EOF
$(scan_records "$ARCHIVE_DIR" state title source resolved_at resolution)
EOF
  [ -n "$(printf '%s' "$rows" | tr -d '[:space:]')" ] || return 0
  sorted=$(printf '%s' "$rows" | LC_ALL=C sort -t"$FIELD_SEP" -k1,1nr -k2,2)
  while IFS="$FIELD_SEP" read -r _ _ r_title r_source r_resolution r_at; do
    [ -n "$r_at" ] || continue
    printf '<tr class="closed"><td class="who">%s</td><td class="what">%s</td>' \
      "$(esc "$(source_label "$r_source")")" "$(esc "${r_title:-untitled item}")"
    printf '<td class="what">%s</td><td class="since">%s</td></tr>\n' \
      "$(esc "${r_resolution:-no resolution recorded}")" \
      "$(esc "$(local_fmt "$r_at" '%H:%M %Z')")"
  done <<EOF
$sorted
EOF
}

count_lines() {
  local text=$1
  [ -n "$(printf '%s' "$text" | tr -d '[:space:]')" ] || { printf '0\n'; return 0; }
  printf '%s\n' "$text" | grep -c '^<' || true
}

# --- render -----------------------------------------------------------------

render_page() {
  local epoch=$1 day=$2 morning=$3 live waiting closed n_live n_waiting n_closed

  [ -f "$HEAD_TEMPLATE" ] && [ ! -L "$HEAD_TEMPLATE" ] \
    || die "house-style head template is missing: $HEAD_TEMPLATE"
  [ -f "$FOOT_TEMPLATE" ] && [ ! -L "$FOOT_TEMPLATE" ] \
    || die "house-style foot template is missing: $FOOT_TEMPLATE"

  live=$(live_rows)
  waiting=$(waiting_rows)
  closed=$(closed_rows "$day")
  n_live=$(count_lines "$live")
  n_live=$((n_live / 4))
  n_waiting=$(count_lines "$waiting")
  n_closed=$(count_lines "$closed")

  awk -v title="Today - $(local_fmt "$epoch" '%A %-d %B %Y')" \
    '{ gsub(/\{\{TITLE\}\}/, title); print }' "$HEAD_TEMPLATE"

  printf '\n<header>\n'
  printf '<div><div class="kicker">Aquablu Starship</div><h1>Today</h1></div>\n'
  printf '<div class="meta">%s<br>\n' "$(esc "$(local_fmt "$epoch" '%A %-d %B %Y')")"
  printf 'Live section rebuilt from the channel ledger at <span class="mono">%s</span>.<br>\n' \
    "$(esc "$(local_fmt "$epoch" '%H:%M %Z')")"
  printf 'Each row carries the time that item was last read on its own channel.</div>\n'
  printf '</header>\n\n'

  printf '<div class="tiles">\n'
  printf '<div class="tile"><div class="n">%s</div><div class="l">Open, ranked below</div><div class="s">from the channel ledger</div></div>\n' "$n_live"
  printf '<div class="tile"><div class="n">%s</div><div class="l">Waiting on others</div><div class="s">handed over, not closed</div></div>\n' "$n_waiting"
  printf '<div class="tile"><div class="n">%s</div><div class="l">Closed since morning</div><div class="s">with the reason recorded</div></div>\n' "$n_closed"
  printf '</div>\n\n'

  printf '<h2>Live now<small>most severe first, newest first inside each class</small></h2>\n'
  if [ -n "$live" ]; then
    printf '<div class="tablewrap"><table>\n'
    printf '<thead><tr><th>Class</th><th>What</th><th>Severity</th><th></th></tr></thead>\n<tbody>\n'
    printf '%s\n' "$live"
    printf '</tbody></table></div>\n'
  else
    printf '<div class="note"><b>Nothing open.</b> The channel ledger holds no open item for this home right now.</div>\n'
  fi

  printf '\n<h2>Waiting on others<small>handed over, still on the ledger</small></h2>\n'
  printf '<div class="strip">\n'
  if [ -n "$waiting" ]; then
    printf '<ul>\n%s\n</ul>\n' "$waiting"
  else
    printf '<p class="sub">Nothing is waiting on anyone else.</p>\n'
  fi
  printf '</div>\n'

  printf '\n<h2>Closed since morning<small>archived today, with the recorded reason</small></h2>\n'
  if [ -n "$closed" ]; then
    printf '<div class="tablewrap"><table>\n'
    printf '<thead><tr><th>Source</th><th>What</th><th>Resolution</th><th>Closed</th></tr></thead>\n<tbody>\n'
    printf '%s\n' "$closed"
    printf '</tbody></table></div>\n'
  else
    printf '<div class="note">Nothing has been closed on this day yet.</div>\n'
  fi

  # The hand-verified morning section, byte for byte. It is never parsed and
  # never re-ordered: those lines were verified by hand under the
  # `daily-todo-freshness` stages and this renderer cannot re-verify them.
  if [ -n "$morning" ]; then
    printf '\n<!-- fm-todo-render: hand-verified morning section begins -->\n'
    cat "$morning"
    printf '\n<!-- fm-todo-render: hand-verified morning section ends -->\n'
  fi

  printf '\n'
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
  local out='' morning='' day='' if_exists=false epoch body
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
  body=$(render_page "$epoch" "$day" "$morning")
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
  -h|--help) usage ;;
  '') usage; exit 2 ;;
  *) die "unknown command: $1" ;;
esac
