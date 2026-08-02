#!/usr/bin/env bash
# Behavior tests for private Markdown report rendering and loopback opening.
set -eu

# shellcheck source=tests/lib.sh disable=SC1091
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
READ="$ROOT/bin/fm-read.sh"
TMP_ROOT=$(fm_test_tmproot fm-read-tests)
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

first=$(FM_HOME="$HOME_DIR" FM_ROOT_OVERRIDE="$ROOT" "$READ" --no-open sample-task)
second=$(FM_HOME="$HOME_DIR" FM_ROOT_OVERRIDE="$ROOT" "$READ" --no-open sample-task)
[ "$first" = "$second" ] || fail "same report rendered to different output names"
case "$first" in "$HOME_DIR/.lavish/read-"*.html) ;; *) fail "output was not written under the private .lavish directory: $first" ;; esac
assert_contains "$(cat "$first")" "<h1>Report heading</h1>" "bare-id output lost the source heading"
assert_contains "$(cat "$first")" '<div class="tw"><table>' "report table was not placed in its overflow wrapper"
pass "bare task ids resolve and deterministic output names are reused"

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
