#!/usr/bin/env bash
# Behavior tests for private Markdown report rendering and loopback opening.
set -eu

# shellcheck source=tests/lib.sh disable=SC1091
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
READ="$ROOT/bin/fm-read.sh"
TMP_ROOT=$(fm_test_tmproot fm-read-tests)
# The renderer reports normalised absolute paths, so compare against a fixture
# root normalised the same way (TMPDIR commonly carries a trailing slash).
TMP_ROOT=${TMP_ROOT//\/\//\/}
HOME_DIR="$TMP_ROOT/home"
FAKEBIN="$TMP_ROOT/bin"
LOG="$TMP_ROOT/lavish.log"
mkdir -p "$HOME_DIR/data/sample-task" "$FAKEBIN"
trap 'rm -rf "$TMP_ROOT"' EXIT HUP INT TERM

cat > "$HOME_DIR/data/sample-task/report.md" <<'MD'
# Report heading

## Findings

| Item | Result |
| --- | --- |
| Reader | Works |
MD
cat > "$TMP_ROOT/notes.md" <<'MD'
# Explicit heading
MD
printf 'not markdown\n' > "$TMP_ROOT/notes.txt"

cat > "$TMP_ROOT/edge.md" <<'MD'
Evidence: status_file_write=ok for LAVISH_AXI_LINK_HOST and FM_READ_TEST_LOG.

Danger [click](javascript:alert(1)) beside a | pipe in prose
---

Safe [docs](https://example.com/a) link.

| A | B |
| - | - |
| 1 | 2 | 3 |

- top level
  - nested child
- second top
MD

file_mode() {
  if [ "$(uname)" = Darwin ]; then
    stat -f %Lp "$1"
  else
    stat -c %a "$1"
  fi
}

cat > "$FAKEBIN/lavish-axi" <<'SH'
#!/usr/bin/env bash
printf 'host=%s link=%s port=%s file=%s\n' \
  "${LAVISH_AXI_HOST:-}" "${LAVISH_AXI_LINK_HOST:-}" "${LAVISH_AXI_PORT:-}" "${1:-}" >> "$FM_READ_TEST_LOG"
printf 'session:\n  url: "http://%s:%s/session/fake"\n' "$LAVISH_AXI_LINK_HOST" "$LAVISH_AXI_PORT"
SH
chmod +x "$FAKEBIN/lavish-axi"

out=$(cd "$TMP_ROOT" && FM_HOME="$HOME_DIR" FM_ROOT_OVERRIDE="$ROOT" \
  FM_LAVISH_BIN="$FAKEBIN/lavish-axi" FM_READ_TEST_LOG="$LOG" \
  "$READ" --no-open notes.md)
[ -f "$out" ] || fail "explicit Markdown path did not produce HTML"
assert_contains "$(cat "$out")" "<h1>Explicit heading</h1>" "explicit path output lost its heading"
[ ! -e "$LOG" ] || fail "--no-open launched Lavish"
pass "explicit paths render headings and --no-open does not launch"

edge_out=$(cd "$TMP_ROOT" && FM_HOME="$HOME_DIR" FM_ROOT_OVERRIDE="$ROOT" "$READ" --no-open edge.md)
edge=$(cat "$edge_out")
edge_flat=$(tr '\n' ' ' < "$edge_out")
assert_contains "$edge" "status_file_write=ok for LAVISH_AXI_LINK_HOST and FM_READ_TEST_LOG." \
  "snake_case identifiers were mangled by intra-word emphasis"
assert_not_contains "$edge" 'href="javascript' "an unsafe URL scheme reached the rendered page"
assert_contains "$edge" '<a href="https://example.com/a">docs</a>' "a safe http link was dropped by scheme filtering"
assert_contains "$edge" "<hr>" "a rule after pipe-bearing prose was swallowed by a bogus table"
assert_contains "$edge" '<th style="text-align:left">A</th>' "a single-dash table divider was not recognised"
assert_contains "$edge" ">3</td>" "a row wider than its header silently lost trailing cells"
assert_contains "$edge_flat" "<li>top level <ul> <li>nested child" "an indented sub-item was flattened to a sibling"
pass "renderer keeps identifiers, rules, tables, and nesting intact and refuses unsafe URL schemes"

first=$(FM_HOME="$HOME_DIR" FM_ROOT_OVERRIDE="$ROOT" "$READ" --no-open sample-task)
second=$(FM_HOME="$HOME_DIR" FM_ROOT_OVERRIDE="$ROOT" "$READ" --no-open sample-task)
[ "$first" = "$second" ] || fail "same report rendered to different output names"
case "$first" in "$HOME_DIR/.lavish/read-sample-task-"*.html) ;; *) fail "task report page was not named for its task id: $first" ;; esac
assert_contains "$(cat "$first")" "<title>Sample Task</title>" "task report page was not titled for its task id"
assert_contains "$(cat "$first")" "<h1>Report heading</h1>" "bare-id output lost the source heading"
assert_contains "$(cat "$first")" '<div class="tw"><table>' "report table was not placed in its overflow wrapper"
pass "bare task ids resolve, name and title their page, and reuse a deterministic output name"

[ "$(file_mode "$first")" = 600 ] || fail "private report page is not owner-only: $(file_mode "$first")"
[ "$(file_mode "$HOME_DIR/.lavish")" = 700 ] || fail "private page directory is not owner-only: $(file_mode "$HOME_DIR/.lavish")"
pass "rendered pages and their directory stay owner-only"

if FM_HOME="$HOME_DIR" FM_ROOT_OVERRIDE="$ROOT" "$READ" --no-open "$TMP_ROOT/notes.txt" >"$TMP_ROOT/non-md.out" 2>&1; then
  fail "non-Markdown input was accepted"
fi
assert_contains "$(cat "$TMP_ROOT/non-md.out")" "refusing non-Markdown file" "non-Markdown refusal was unclear"
pass "non-Markdown files are refused"

if FM_HOME="$HOME_DIR" FM_ROOT_OVERRIDE="$ROOT" "$READ" --no-open missing-task >"$TMP_ROOT/missing.out" 2>&1; then
  fail "missing bare task id was accepted"
fi
assert_contains "$(cat "$TMP_ROOT/missing.out")" "$HOME_DIR/data/missing-task/report.md" "missing-id error did not name the report path it checked"
pass "missing bare ids name the report path that was checked"

open_out=$(FM_HOME="$HOME_DIR" FM_ROOT_OVERRIDE="$ROOT" FM_LAVISH_BIN="$FAKEBIN/lavish-axi" \
  FM_READ_TEST_LOG="$LOG" FM_READ_PORT=4491 "$READ" sample-task)
assert_contains "$open_out" 'http://127.0.0.1:4491/session/fake' "open did not print the Lavish URL"
opened=$(cat "$LOG")
assert_contains "$opened" "host=127.0.0.1 link=127.0.0.1 port=4491 file=$first" "open did not bind Lavish to IPv4 loopback with the rendered page"
pass "open launches Lavish on IPv4 loopback and prints its URL"
