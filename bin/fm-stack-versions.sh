#!/usr/bin/env bash
# Report the installed version of each tool this Starship checkout relies on
# against that tool's latest release, in plain words.
#
# Usage:
#   fm-stack-versions.sh report
#   fm-stack-versions.sh notice
#   fm-stack-versions.sh --help
#
# `report` prints one Markdown section to stdout and always exits 0 once its
# arguments are valid, so a caller can append it to a larger report.
# `notice` prints at most one line, for every home's session start (the
# deferred network phase of bin/fm-bootstrap.sh) and /updatefirstmate's final
# report, and always exits 0:
#   STACK_TOOLS: behind: <tool> installed <version>, latest <version>
#     (small update|quiet-window upgrade); ...[ - could not check: <tool>, ...]
#   STACK_TOOLS: could not check: <tool>, ...
# It is silent when every installed tool is known to be current. A tool whose
# installed version or latest release cannot be read is named under "could
# not check", never counted as current. A tool that is not installed is left
# to bootstrap's MISSING lines and not named.
# Both commands only report: they never install, upgrade, downgrade, or pin
# anything, and never change PATH or any package manager's state.
#
# The tools are the stack beneath Starship that runs unmodified: Herdr,
# treehouse, no-mistakes, and the AXI tools (gh-axi, lavish-axi,
# chrome-devtools-axi, quota-axi, tasks-axi).
# The latest release comes from GitHub Releases for Herdr, treehouse, and
# no-mistakes, and from the npm registry for the AXI tools, each read with one
# bounded curl and parsed with jq.
# The version Starship itself expects is read at run time from the owner that
# pins it, so this script never carries a second copy of a pin:
#   Herdr        exact pin FM_HERDR_CI_VERSION in bin/fm-install-herdr.sh
#   no-mistakes  floor NO_MISTAKES_MIN in bin/fm-bootstrap.sh
#   gh-axi       floor GH_AXI_MIN in bin/fm-bootstrap.sh
#   lavish-axi   floor LAVISH_AXI_MIN in bin/fm-bootstrap.sh
#   quota-axi    floor FM_QUOTA_AXI_MIN in bin/fm-quota-axi-lib.sh
#   tasks-axi    floor FM_TASKS_AXI_MIN in bin/fm-tasks-axi-lib.sh
# treehouse and chrome-devtools-axi have no version pin.
# Pins are read from the checkout at FM_ROOT_OVERRIDE, or this script's own
# checkout, so a home reports against the pins its own Starship carries.
#
# Herdr and treehouse upgrades are flagged as needing a quiet window with no
# workers running: every worker window, including firstmate's, runs inside
# Herdr, and every worker's isolated copy comes from treehouse.
# Any other update is reported as small, to be installed only after a yes.
#
# FM_STACK_VERSIONS_TIMEOUT bounds each version probe and each release lookup
# (default 8 seconds, valid 1..60).
#
# `notice` probes and looks up every tool concurrently, and caches each
# successful release lookup in this home's state/.stack-versions.latest
# (FM_STATE_OVERRIDE, else FM_HOME/state), one `<source> <version> <epoch>`
# record per line, so the lookups run at most once per
# FM_STACK_VERSIONS_CACHE_TTL seconds per home (default 86400, one day).
# Installed versions are probed on every run, so an upgrade shows at once.
# A failed lookup is never cached and is retried on the next run.
# `report` always looks up afresh and leaves the cache alone.
# Under the test suite (FM_TEST_SEAM=1) `notice` stays silent unless
# FM_TEST_STACK_VERSIONS_NOTICE=1, so a fixture's fake tools never reach the
# real release servers.
set -u
export LC_ALL=C

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
# shellcheck source=bin/fm-timeout-lib.sh disable=SC1091
. "$SCRIPT_DIR/fm-timeout-lib.sh"

usage() {
  awk '
    NR == 1 { next }
    /^#/ { sub(/^# ?/, ""); print; next }
    { exit }
  ' "$0" >&2
}

die() {
  printf 'fm-stack-versions: %s\n' "$*" >&2
  exit 2
}

TIMEOUT=${FM_STACK_VERSIONS_TIMEOUT:-8}
case "$TIMEOUT" in ''|*[!0-9]*|0) die 'FM_STACK_VERSIONS_TIMEOUT must be a whole number from 1 to 60' ;; esac
[ "$TIMEOUT" -le 60 ] || die 'FM_STACK_VERSIONS_TIMEOUT must be a whole number from 1 to 60'
CACHE_TTL=${FM_STACK_VERSIONS_CACHE_TTL:-86400}
case "$CACHE_TTL" in ''|*[!0-9]*) die 'FM_STACK_VERSIONS_CACHE_TTL must be a whole number of seconds' ;; esac
STATE_DIR="${FM_STATE_OVERRIDE:-${FM_HOME:-$ROOT}/state}"
CACHE_FILE="$STATE_DIR/.stack-versions.latest"

# One row per tool:
#   display|command|latest source|pin kind|pin file|pin variable|quiet window
# latest source is github:<owner>/<repo>, github-var:<file>:<variable> (the
# repository slug read from that owner), or npm:<package>.
TOOLS='Herdr|herdr|github-var:bin/fm-install-herdr.sh:FM_HERDR_CI_REPO|exact|bin/fm-install-herdr.sh|FM_HERDR_CI_VERSION|herdr
treehouse|treehouse|github:kunchenguid/treehouse|none|||treehouse
no-mistakes|no-mistakes|github:kunchenguid/no-mistakes|floor|bin/fm-bootstrap.sh|NO_MISTAKES_MIN|
gh-axi|gh-axi|npm:gh-axi|floor|bin/fm-bootstrap.sh|GH_AXI_MIN|
lavish-axi|lavish-axi|npm:lavish-axi|floor|bin/fm-bootstrap.sh|LAVISH_AXI_MIN|
chrome-devtools-axi|chrome-devtools-axi|npm:chrome-devtools-axi|none|||
quota-axi|quota-axi|npm:quota-axi|floor|bin/fm-quota-axi-lib.sh|FM_QUOTA_AXI_MIN|
tasks-axi|tasks-axi|npm:tasks-axi|floor|bin/fm-tasks-axi-lib.sh|FM_TASKS_AXI_MIN|'

# First dotted number in the text, so "herdr 0.7.4", "v2.0.0", and
# "no-mistakes version v1.84.0 (4822244)" all parse.
parse_version() {
  printf '%s' "$1" | grep -oE '[0-9]+(\.[0-9]+)+' | head -n 1
}

# version_cmp <a> <b>: prints newer, older, or same for a against b.
version_cmp() {
  local a=$1 b=$2 i left right
  local -a ap bp
  IFS=. read -r -a ap <<< "$a"
  IFS=. read -r -a bp <<< "$b"
  i=0
  while [ "$i" -lt "${#ap[@]}" ] || [ "$i" -lt "${#bp[@]}" ]; do
    left=$((10#${ap[i]:-0}))
    right=$((10#${bp[i]:-0}))
    if [ "$left" -gt "$right" ]; then
      printf 'newer\n'
      return 0
    elif [ "$left" -lt "$right" ]; then
      printf 'older\n'
      return 0
    fi
    i=$((i + 1))
  done
  printf 'same\n'
}

# Value of a plain `VAR=value` assignment in a tracked owner file, or nothing.
owner_value() {
  local file=$1 var=$2
  [ -n "$file" ] && [ -n "$var" ] && [ -f "$ROOT/$file" ] || return 0
  sed -n -E "s/^${var}=\"?([^\"[:space:]]+)\"?.*$/\\1/p" "$ROOT/$file" | head -n 1
}

installed_version() {
  local command_name=$1 banner
  banner=$(fm_run_timed "$TIMEOUT" "$command_name" --version </dev/null 2>&1) || true
  parse_version "$banner"
}

latest_version() {
  local source=$1 kind rest repo body raw
  command -v curl >/dev/null 2>&1 || return 0
  command -v jq >/dev/null 2>&1 || return 0
  kind=${source%%:*}
  rest=${source#*:}
  case "$kind" in
    github) repo=$rest ;;
    github-var) repo=$(owner_value "${rest%%:*}" "${rest#*:}") ;;
    npm)
      body=$(fm_run_timed "$TIMEOUT" curl -fsSL --max-time "$TIMEOUT" \
        "https://registry.npmjs.org/$rest/latest" 2>/dev/null) || return 0
      raw=$(printf '%s' "$body" | jq -r '.version // empty' 2>/dev/null) || return 0
      parse_version "$raw"
      return 0
      ;;
    *) return 0 ;;
  esac
  case "$repo" in
    */*) ;;
    *) return 0 ;;
  esac
  body=$(fm_run_timed "$TIMEOUT" curl -fsSL --max-time "$TIMEOUT" \
    -H 'Accept: application/vnd.github+json' \
    "https://api.github.com/repos/$repo/releases/latest" 2>/dev/null) || return 0
  raw=$(printf '%s' "$body" | jq -r '.tag_name // empty' 2>/dev/null) || return 0
  parse_version "$raw"
}

quiet_reason() {
  case "$1" in
    herdr) printf 'every worker window, including firstmate'"'"'s, runs inside Herdr' ;;
    treehouse) printf 'every worker'"'"'s isolated copy comes from treehouse' ;;
  esac
}

join_names() {
  local out='' name
  for name in "$@"; do
    if [ -z "$out" ]; then out=$name; else out="$out, $name"; fi
  done
  printf '%s' "$out"
}

report() {
  local display command_name source pin_kind pin_file pin_var quiet
  local installed latest pin line cmp pin_cmp reason
  local -a behind=() current=() unknown=() absent=() lines=()
  while IFS='|' read -r display command_name source pin_kind pin_file pin_var quiet; do
    [ -n "$display" ] || continue
    pin=
    cmp=
    [ "$pin_kind" = none ] || pin=$(owner_value "$pin_file" "$pin_var")
    if ! command -v "$command_name" >/dev/null 2>&1; then
      absent+=("$display")
      lines+=("- $display: not installed here.")
      continue
    fi
    installed=$(installed_version "$command_name")
    latest=$(latest_version "$source")
    if [ -z "$installed" ]; then
      unknown+=("$display")
      line="- $display: installed, but its version could not be read"
      [ -z "$latest" ] || line="$line; latest release $latest"
      lines+=("$line.")
      continue
    fi
    if [ -z "$latest" ]; then
      unknown+=("$display")
      line="- $display: installed $installed; the latest release could not be read (offline or rate-limited)."
    else
      cmp=$(version_cmp "$installed" "$latest")
      case "$cmp" in
        older)
          behind+=("$display")
          line="- $display: installed $installed, latest $latest - behind."
          ;;
        same)
          current+=("$display")
          line="- $display: installed $installed, latest $latest - up to date."
          ;;
        newer)
          current+=("$display")
          line="- $display: installed $installed, newer than the latest release $latest."
          ;;
      esac
    fi
    if [ -n "$pin" ]; then
      pin_cmp=$(version_cmp "$installed" "$pin")
      case "$pin_kind" in
        exact)
          # Named whenever the installed or latest version is not the pin, so
          # an upgrade past what Starship verified is never mistaken for safe.
          if [ "$pin_cmp" != same ] || { [ -n "$latest" ] && [ "$latest" != "$pin" ]; }; then
            line="$line Starship's own tests are verified on $pin."
          fi
          ;;
        floor)
          [ "$pin_cmp" != older ] || line="$line Below the $pin Starship needs."
          ;;
      esac
    fi
    if [ -n "$latest" ] && [ "$cmp" = older ]; then
      reason=$(quiet_reason "$quiet")
      if [ -n "$reason" ]; then
        line="$line Upgrade only in a quiet window with no workers running, because $reason."
      else
        line="$line A small update: install it only after a yes."
      fi
    fi
    lines+=("$line")
  done <<< "$TOOLS"

  printf '## Tool versions\n\n'
  if [ "${#behind[@]}" -gt 0 ]; then
    printf 'Behind: %s.\n' "$(join_names "${behind[@]}")"
  else
    printf 'Behind: none.\n'
  fi
  [ "${#current[@]}" -eq 0 ] || printf 'Up to date: %s.\n' "$(join_names "${current[@]}")"
  [ "${#unknown[@]}" -eq 0 ] || printf 'Could not compare: %s.\n' "$(join_names "${unknown[@]}")"
  [ "${#absent[@]}" -eq 0 ] || printf 'Not installed: %s.\n' "$(join_names "${absent[@]}")"
  printf '\n'
  for line in "${lines[@]}"; do
    printf '%s\n' "$line"
  done
  printf '\nThis is a report only. Nothing was installed or upgraded.\n'
}

# Latest version cached for <source> within CACHE_TTL, or nothing. A record
# stamped in the future is treated as stale rather than trusted forever.
cached_latest() {
  local source=$1 now
  [ -f "$CACHE_FILE" ] && [ ! -L "$CACHE_FILE" ] || return 0
  now=$(date +%s)
  awk -F '\t' -v source="$source" -v now="$now" -v ttl="$CACHE_TTL" '
    $1 == source && $3 ~ /^[0-9]+$/ && $3 <= now && now - $3 < ttl { latest = $2 }
    END { if (latest != "") print latest }
  ' "$CACHE_FILE" 2>/dev/null
}

# One `|`-separated row for a tool (a non-blank separator, so an empty field
# survives `read`):
#   display|installed|latest|quiet|source|fetched (1 when looked up now)
notice_row() {
  local display=$1 command_name=$2 source=$3 quiet=$4 installed latest fetched=0
  installed=$(installed_version "$command_name")
  latest=$(cached_latest "$source")
  if [ -z "$latest" ]; then
    latest=$(latest_version "$source")
    [ -z "$latest" ] || fetched=1
  fi
  printf '%s|%s|%s|%s|%s|%s\n' "$display" "$installed" "$latest" "$quiet" "$source" "$fetched"
}

# cache_store <records>: merge fresh `<source> TAB <version>` lines into the
# cache, replacing each source's earlier record. Best effort: a home without a
# writable state directory simply looks up again next time.
cache_store() {
  local fresh=$1 now tmp
  [ -d "$STATE_DIR" ] && [ ! -L "$CACHE_FILE" ] || return 0
  now=$(date +%s)
  tmp=$(mktemp "$CACHE_FILE.XXXXXX" 2>/dev/null) || return 0
  if {
    [ ! -f "$CACHE_FILE" ] || printf '%s' "$fresh" | awk -F '\t' '
      NR == FNR { fresh[$1] = 1; next }
      NF == 3 && !($1 in fresh)
    ' - "$CACHE_FILE"
    printf '%s' "$fresh" | awk -F '\t' -v OFS='\t' -v now="$now" '{ print $1, $2, now }'
  } >"$tmp" 2>/dev/null && mv -f "$tmp" "$CACHE_FILE" 2>/dev/null; then
    return 0
  fi
  rm -f "$tmp" 2>/dev/null || true
}

notice() {
  local display command_name source pin_kind pin_file pin_var quiet
  local dir i item installed latest fetched fresh line clause
  local -a behind=() unknown=()
  dir=$(mktemp -d "${TMPDIR:-/tmp}/fm-stack-versions.XXXXXX" 2>/dev/null) || return 0
  i=0
  while IFS='|' read -r display command_name source pin_kind pin_file pin_var quiet; do
    [ -n "$display" ] || continue
    command -v "$command_name" >/dev/null 2>&1 || continue
    i=$((i + 1))
    notice_row "$display" "$command_name" "$source" "$quiet" >"$dir/$i" 2>/dev/null &
  done <<< "$TOOLS"
  wait
  fresh=
  i=1
  while [ -f "$dir/$i" ]; do
    IFS='|' read -r display installed latest quiet source fetched <"$dir/$i" || true
    i=$((i + 1))
    [ -n "$display" ] || continue
    [ "$fetched" != 1 ] || fresh="$fresh$source"$'\t'"$latest"$'\n'
    if [ -z "$installed" ] || [ -z "$latest" ]; then
      unknown+=("$display")
      continue
    fi
    [ "$(version_cmp "$installed" "$latest")" = older ] || continue
    if [ -n "$quiet" ]; then
      behind+=("$display installed $installed, latest $latest (quiet-window upgrade)")
    else
      behind+=("$display installed $installed, latest $latest (small update)")
    fi
  done
  rm -rf "$dir"
  [ -z "$fresh" ] || cache_store "$fresh"
  clause=
  [ "${#unknown[@]}" -eq 0 ] || clause="could not check: $(join_names "${unknown[@]}")"
  if [ "${#behind[@]}" -gt 0 ]; then
    line="STACK_TOOLS: behind: ${behind[0]}"
    for item in "${behind[@]:1}"; do
      line="$line; $item"
    done
    [ -z "$clause" ] || line="$line - $clause"
    printf '%s\n' "$line"
  elif [ -n "$clause" ]; then
    printf 'STACK_TOOLS: %s\n' "$clause"
  fi
}

case "${1:-}" in
  report)
    [ "$#" -eq 1 ] || die 'report takes no arguments'
    report
    ;;
  notice)
    [ "$#" -eq 1 ] || die 'notice takes no arguments'
    if [ "${FM_TEST_SEAM:-}" = 1 ] && [ "${FM_TEST_STACK_VERSIONS_NOTICE:-}" != 1 ]; then
      exit 0
    fi
    notice
    ;;
  -h|--help)
    usage
    ;;
  '')
    usage
    exit 2
    ;;
  *)
    die "unknown command: $1"
    ;;
esac
