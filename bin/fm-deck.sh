#!/usr/bin/env bash
# fm-deck.sh - the captain's private ACTION DECK pane.
#
# One refreshing, read-only terminal view that answers "what is waiting for me"
# above the fold and then shows what is moving. It is captain-private: it renders
# only from records this home already keeps and holds no queue, no cache, and no
# state of its own beyond the frame it is currently drawing.
#
# Sections, most-actionable first:
#   STAGED FOR YOUR CLICK  bin/fm-tray.sh json, grouped by standing order using
#                          bin/fm-order.sh list (age headline, expiry countdown)
#   NEEDS YOU              parked and blocked work, PRs ready to review with
#                          their full URL, and durable captain decisions
#   LOOSE ENDS             data/loose-ends/latest.md, the manual inbox sweep
#   UNDER WAY              one outcome line per recorded worker
#   JUST IN                recent completions and findings
#
# Herdr workspace registration: firstmate opens this pane as its own tab in the
# captain's "Aquablu Starship" workspace with
#   herdr tab create --workspace <id> --label 'Action Deck' --command 'bin/fm-deck.sh'
# where <id> is that workspace's recorded id. This script never drives Herdr
# itself; the screen doctrine owns tab layout.
#
# Every section degrades to an honest empty line rather than an error when its
# source is missing or empty, because a pane that errors out is a pane the
# captain stops trusting.
#
# State vocabulary and colours come from bin/fm-visible-format-lib.sh, the one
# owner of that captain-facing wording. The UNDER WAY state is a projection of
# the durable status stream folded by bin/fm-classify-lib.sh, labelled REPORTED
# because that is what it is: bin/fm-crew-state.sh remains the owner of live
# current state, and the deck deliberately does not call it so a refresh stays
# well under a second.
#
# Usage:
#   fm-deck.sh [--interval <secs>]   refresh until interrupted (default 15)
#   fm-deck.sh --once                print one snapshot and exit
#   fm-deck.sh -h|--help
#
# Environment:
#   FM_HOME / FM_DATA_OVERRIDE / FM_STATE_OVERRIDE / FM_CONFIG_OVERRIDE
#                          home and root directories
#   FM_DECK_COLUMNS        render width; else tput cols, else 100
#   FM_DECK_NOW            override unix epoch for ages and the clock (tests)
#   FM_DECK_JUST_IN        completions to show in JUST IN (default 5)
#   FM_DECK_LOOSE_ENDS     urgent/waiting loose ends to show (default 5)
#   FM_DECK_NEEDS_YOU      rows to show in NEEDS YOU before "+n more" (default 8)
#   FM_DECK_MAX_FRAMES     stop after this many refreshes; test seam so the
#                          suite can assert the loop's redraw without killing a
#                          process. Unset means refresh until interrupted.
#
# Exit:
#   0 on success, or on any single source being absent or unreadable
#   1 on usage error or a missing python3
set -eu

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_ROOT}}"
DATA="${FM_DATA_OVERRIDE:-$FM_HOME/data}"
STATE="${FM_STATE_OVERRIDE:-$FM_HOME/state}"
CONFIG="${FM_CONFIG_OVERRIDE:-$FM_HOME/config}"

DEFAULT_INTERVAL=15
SECTION_MARK='__FM_DECK_SECTION__'

# fm_visible_state / fm_visible_icon own the captain-facing state wording.
# shellcheck source=bin/fm-visible-format-lib.sh
. "$SCRIPT_DIR/fm-visible-format-lib.sh"
# status_open_decisions / status_declared_wait / last_status_line own the durable
# status fold, so the deck never re-derives "is this decision still open".
# shellcheck source=bin/fm-classify-lib.sh
. "$SCRIPT_DIR/fm-classify-lib.sh"
# fm_tasks_axi_backend_available owns whether the backlog is readable this way.
# shellcheck source=bin/fm-tasks-axi-lib.sh
. "$SCRIPT_DIR/fm-tasks-axi-lib.sh"

usage() {
  cat <<'EOF' >&2
usage: fm-deck.sh [--interval <secs>]
       fm-deck.sh --once
       fm-deck.sh -h|--help

The captain's private Action Deck pane: staged actions awaiting his click, what
needs him, his loose ends, live work, and recent outcomes. Read-only over
records this home already keeps; it approves, merges, and mutates nothing.
EOF
}

fail() {
  printf 'fm-deck: %s\n' "$*" >&2
  exit 1
}

now_ts() {
  if [ -n "${FM_DECK_NOW:-}" ]; then
    printf '%s\n' "$FM_DECK_NOW"
    return 0
  fi
  date +%s
}

render_width() {
  local cols
  if [ -n "${FM_DECK_COLUMNS:-}" ]; then
    printf '%s\n' "$FM_DECK_COLUMNS"
    return 0
  fi
  if cols=$(tput cols 2>/dev/null) && [ -n "$cols" ] && [ "$cols" -gt 0 ] 2>/dev/null; then
    printf '%s\n' "$cols"
    return 0
  fi
  printf '%s\n' 100
}

meta_value() {  # <meta-file> <key>
  sed -n "s/^$2=//p" "$1" 2>/dev/null | tail -1
}

# The home's own display name, so the pane says "Starship" not a path.
home_label() {
  "$SCRIPT_DIR/fm-project-display-name.sh" "$(basename "$FM_HOME")" 2>/dev/null || basename "$FM_HOME"
}

# --- source collection ------------------------------------------------------
# Each collector prints its blob and always succeeds: an absent or broken source
# yields an empty blob, and the renderer turns that into an honest empty section.

collect_tray() {
  "$SCRIPT_DIR/fm-tray.sh" json 2>/dev/null || printf '%s\n' '[]'
}

collect_orders() {
  "$SCRIPT_DIR/fm-order.sh" list 2>/dev/null || true
}

collect_backlog() {
  # Deliberately NOT fm_tasks_axi_backend_available: that probe shells out three
  # more times to confirm the MUTATION features (update --archive-body, atomic
  # multi-id mv) this pane will never use, and it is the single slowest thing in
  # a refresh. A view needs only "is this home's backlog readable this way", and
  # a `list` that fails anyway falls through to an honest empty section.
  fm_backlog_backend_manual "$CONFIG" && return 0
  command -v tasks-axi >/dev/null 2>&1 || return 0
  [ -f "$DATA/backlog.md" ] || return 0
  # --file pins the read to THIS home's backlog: without it tasks-axi resolves
  # its markdown path relative to the caller's directory, so the pane would show
  # whatever queue happened to sit under the shell's cwd. Same reason
  # bin/fm-backlog-handoff.sh passes it.
  tasks-axi list --file "$DATA/backlog.md" \
    --fields hold_kind,hold_reason,links,closed,blocked_by,held,priority \
    2>/dev/null || true
}

collect_loose_ends() {
  local f="$DATA/loose-ends/latest.md"
  [ -f "$f" ] || return 0
  # Home-relative, because the pane points him at a file to open, not at a path
  # to parse; the absolute prefix is the same on every line and just costs width.
  printf 'path\t%s\n' "${f#"$FM_HOME"/}"
  printf 'age_secs\t%s\n' "$(file_age_secs "$f")"
  printf 'body\n'
  cat "$f" 2>/dev/null || true
}

file_age_secs() {  # <file> -> seconds since mtime, or -1
  local f=$1 mtime now
  mtime=$(stat -f %m "$f" 2>/dev/null || stat -c %Y "$f" 2>/dev/null || true)
  case "$mtime" in
    ''|*[!0-9]*) printf '%s\n' -1; return 0 ;;
  esac
  now=$(now_ts)
  printf '%s\n' "$((now - mtime))"
}

# Project the durable status stream onto one canonical state name plus the note
# that goes with it. Open decisions win over the last line, because a keyed
# needs-decision or blocked must never be masked by a later unrelated event -
# that is exactly what status_open_decisions folds for.
reported_state() {  # <status-file> -> "<state>\t<note>"
  local f=$1 decisions row note last verb effective resolve
  if [ ! -f "$f" ]; then
    printf 'none\t'
    return 0
  fi
  decisions=$(status_open_decisions "$f")
  if [ -n "$decisions" ]; then
    row=$(printf '%s\n' "$decisions" | awk -F'\t' '$2 == "needs-decision" { print; exit }')
    [ -n "$row" ] || row=$(printf '%s\n' "$decisions" | awk -F'\t' '$2 == "blocked" { print; exit }')
    if [ -n "$row" ]; then
      note=$(printf '%s' "$row" | cut -f3-)
      case "$(printf '%s' "$row" | cut -f2)" in
        needs-decision) printf 'parked\t%s' "$note" ;;
        *) printf 'blocked\t%s' "$note" ;;
      esac
      return 0
    fi
  fi
  last=$(last_status_line "$f")
  if [ -z "$last" ]; then
    printf 'none\t'
    return 0
  fi
  # A trailing `resolved:` line is an event about a DECISION, not the crew's own
  # last word about the work, so read the state from the line before it. Without
  # this, a worker that finished or failed and then had an unrelated decision
  # resolved afterwards renders as still working - a failed worker showing up
  # blue on his pane is the wrong way round to be wrong. This is the same
  # look-back status_declared_wait performs, taken from the fold's own helper so
  # the two readings cannot disagree.
  resolve=${FM_CLASSIFY_RESOLVE_VERB:-$FM_CLASSIFY_RESOLVE_VERB_DEFAULT}
  if [ "$(status_line_verb "$last")" = "$resolve" ]; then
    effective=$(_fm_last_non_resolve_line "$f")
    [ -z "$effective" ] || last=$effective
  fi
  note=$(status_line_note "$last")
  if status_declared_wait "$f"; then
    printf 'paused\t%s' "$note"
    return 0
  fi
  # Map every verb the status vocabulary defines, so `unknown` means a verb this
  # projection genuinely does not know rather than a common one that happens to
  # land on the same label by luck. A declared wait reaches here whenever the
  # fold did not already claim it above - for example a pause behind a trailing
  # resolve line that closed an ordinary decision rather than a captain hold.
  verb=$(status_line_verb "$last")
  case "$verb" in
    done) printf 'done\t%s' "$note" ;;
    failed) printf 'failed\t%s' "$note" ;;
    working) printf 'working\t%s' "$note" ;;
    "${FM_CLASSIFY_PAUSED_VERB:-$FM_CLASSIFY_PAUSED_VERB_DEFAULT}") printf 'paused\t%s' "$note" ;;
    "${FM_CLASSIFY_CAPTAIN_HELD_VERB:-$FM_CLASSIFY_CAPTAIN_HELD_VERB_DEFAULT}") printf 'paused\t%s' "$note" ;;
    *) printf 'unknown\t%s' "$note" ;;
  esac
}

# One TSV row per recorded worker:
#   id, kind, project label, outcome, state, note, seconds since last heard, PR
collect_tasks() {
  local meta id kind project outcome status_log state note heard pr row
  [ -d "$STATE" ] || return 0
  for meta in "$STATE"/*.meta; do
    [ -e "$meta" ] || continue
    id=$(basename "$meta" .meta)
    kind=$(meta_value "$meta" kind)
    [ -n "$kind" ] || kind=ship
    project=$(project_label "$meta")
    outcome=$("$SCRIPT_DIR/fm-task-outcome.sh" "$id" "$(meta_value "$meta" outcome)" 2>/dev/null || printf '%s' "$id")
    status_log="$STATE/$id.status"
    row=$(reported_state "$status_log")
    state=$(printf '%s' "$row" | cut -f1)
    note=$(printf '%s' "$row" | cut -f2-)
    if [ -f "$status_log" ]; then
      heard=$(file_age_secs "$status_log")
    else
      heard=-1
    fi
    pr=$(meta_value "$meta" pr)
    printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n' \
      "$id" "$kind" "$project" "$(one_line "$outcome")" \
      "$state" "$(one_line "$note")" "$heard" "$pr"
  done
}

one_line() {  # <text>
  printf '%s' "$1" | tr '\r\n\t' '   ' | tr -s ' ' | sed 's/^ *//; s/ *$//'
}

# The project a worker is changing, as the captain names it.
project_label() {  # <meta-file>
  local explicit project slug
  explicit=$(meta_value "$1" herdr_project_name)
  if [ -n "$explicit" ]; then
    one_line "$explicit"
    return 0
  fi
  project=$(meta_value "$1" project)
  [ -n "$project" ] || { printf '%s' '-'; return 0; }
  slug=$(basename "$project")
  "$SCRIPT_DIR/fm-project-display-name.sh" "$slug" 2>/dev/null || printf '%s' "$slug"
}

# The captain-facing state label and dot for every state the projection emits,
# resolved here so the renderer never re-implements the vocabulary.
collect_vocabulary() {
  local canonical visible
  for canonical in parked failed blocked working paused 'done' unknown none; do
    visible=$(fm_visible_state "$canonical")
    printf '%s\t%s\t%s\n' "$canonical" "$visible" "$(fm_visible_icon "$visible")"
  done
}

emit_payload() {
  printf '%s now\n%s\n' "$SECTION_MARK" "$(now_ts)"
  printf '%s width\n%s\n' "$SECTION_MARK" "$(render_width)"
  printf '%s home\n%s\n' "$SECTION_MARK" "$(home_label)"
  printf '%s interval\n%s\n' "$SECTION_MARK" "$1"
  printf '%s limits\n%s\t%s\t%s\n' "$SECTION_MARK" \
    "${FM_DECK_JUST_IN:-5}" "${FM_DECK_LOOSE_ENDS:-5}" "${FM_DECK_NEEDS_YOU:-8}"
  printf '%s vocabulary\n' "$SECTION_MARK"
  collect_vocabulary
  printf '%s tray\n' "$SECTION_MARK"
  collect_tray
  printf '%s orders\n' "$SECTION_MARK"
  collect_orders
  printf '%s backlog\n' "$SECTION_MARK"
  collect_backlog
  printf '%s tasks\n' "$SECTION_MARK"
  collect_tasks
  printf '%s loose_ends\n' "$SECTION_MARK"
  collect_loose_ends
}

render() {  # <interval-or-empty>
  emit_payload "$1" | python3 "$SCRIPT_DIR/fm-deck-render.py" "$SECTION_MARK"
}

main() {
  local interval=$DEFAULT_INTERVAL once=0 frame

  while [ "$#" -gt 0 ]; do
    case "$1" in
      -h|--help) usage; exit 0 ;;
      --once) once=1; shift ;;
      --interval)
        [ "$#" -ge 2 ] || fail "--interval requires seconds"
        case "$2" in
          ''|*[!0-9]*) fail "--interval must be a positive whole number of seconds" ;;
        esac
        [ "$2" -gt 0 ] || fail "--interval must be a positive whole number of seconds"
        interval=$2
        shift 2
        ;;
      approve|execute|merge|arm|disarm|graduate)
        fail "read-only view: $1 stays on its own command; the deck never acts"
        ;;
      *) usage; exit 1 ;;
    esac
  done

  command -v python3 >/dev/null 2>&1 || fail "python3 not found"

  if [ "$once" -eq 1 ]; then
    render ''
    return 0
  fi

  # Draw into a variable first, then clear and print in one write, so a refresh
  # does not flash a half-built pane at him.
  local drawn=0 max=${FM_DECK_MAX_FRAMES:-0}
  while :; do
    frame=$(render "$interval")
    printf '\033[H\033[2J\033[3J%s\n' "$frame"
    drawn=$((drawn + 1))
    if [ "$max" -gt 0 ] && [ "$drawn" -ge "$max" ]; then
      return 0
    fi
    sleep "$interval"
  done
}

main "$@"
