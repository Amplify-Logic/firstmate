#!/usr/bin/env bash
# Behavior tests for bin/fm-order.sh: parse, arm-refusal, graduate-refusal.
set -u

# shellcheck source=tests/lib.sh disable=SC1091
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

ORDER_SH="$ROOT/bin/fm-order.sh"
REGISTER="$ROOT/bin/fm-check-register.sh"
TMP=$(fm_test_tmproot fm-order)
HOME_DIR="$TMP/home"
DATA_DIR="$HOME_DIR/data"
STATE_DIR="$HOME_DIR/state"
ORDERS="$DATA_DIR/orders"
mkdir -p "$ORDERS" "$STATE_DIR" "$HOME_DIR/config" "$DATA_DIR/action-gateway"

NOW=1700000000

run_order() {
  FM_HOME="$HOME_DIR" \
  FM_DATA_OVERRIDE="$DATA_DIR" \
  FM_STATE_OVERRIDE="$STATE_DIR" \
  FM_ACTION_GATEWAY_TEST=1 \
  FM_ACTION_GATEWAY_NOW="$NOW" \
    "$ORDER_SH" "$@"
}

write_order() {
  local slug=$1 status=${2:-DRAFT}
  cat > "$ORDERS/${slug}.md" <<EOF
# ${slug}
Slug: ${slug}
Status: ${status}

## Watch
A fixture watch.

## Stage
crm.update drafts.

## Last click
The message.

## Reaches me
Tier 2.

## Route
Cleared: fixture.
EOF
}

test_help_exits_zero() {
  local out rc
  set +e
  out=$("$ORDER_SH" --help 2>&1)
  rc=$?
  set -e
  expect_code 0 "$rc" "--help exit"
  assert_contains "$out" 'fm-order.sh' "--help usage"
  assert_contains "$out" 'docs/ops-command-center.md' "--help docs pointer"
  pass "fm-order --help exits 0"
}

test_missing_status_fails_loudly() {
  local out rc
  printf '%s\n' '# no status here' > "$ORDERS/broken.md"
  set +e
  out=$(run_order list 2>&1)
  rc=$?
  set -e
  expect_code 1 "$rc" "missing Status exit"
  assert_contains "$out" 'missing Status' "loud missing Status"
  rm -f "$ORDERS/broken.md"
  pass "missing Status fails loudly"
}

test_arm_refuses_without_by_captain() {
  local out rc
  write_order fixture-arm DRAFT
  set +e
  out=$(run_order arm fixture-arm 2>&1)
  rc=$?
  set -e
  expect_code 1 "$rc" "arm without flag exit"
  assert_contains "$out" '--by-captain' "arm names the required flag"
  assert_contains "$out" 'must not self-arm' "arm names the authority rule"
  grep -F 'Status: DRAFT' "$ORDERS/fixture-arm.md" >/dev/null \
    || fail "DRAFT Status must be unchanged without --by-captain"
  pass "arm without --by-captain refuses and does not mutate"
}

test_arm_with_flag_flips_draft_to_armed() {
  local out rc
  write_order fixture-arm2 DRAFT
  set +e
  out=$(run_order arm fixture-arm2 --by-captain 2>&1)
  rc=$?
  set -e
  expect_code 0 "$rc" "arm with flag exit"
  assert_contains "$out" 'armed: fixture-arm2' "arm success"
  grep -E '^Status: ARMED \(captain ' "$ORDERS/fixture-arm2.md" >/dev/null \
    || fail "Status must become ARMED"
  pass "arm --by-captain flips DRAFT to ARMED"
}

test_disarm_refuses_without_flag() {
  local out rc
  write_order fixture-disarm 'ARMED (captain 2026-08-28)'
  set +e
  out=$(run_order disarm fixture-disarm 2>&1)
  rc=$?
  set -e
  expect_code 1 "$rc" "disarm without flag exit"
  assert_contains "$out" '--by-captain' "disarm names the required flag"
  pass "disarm without --by-captain refuses"
}

test_graduate_refuses_irreversible() {
  local out rc
  write_order fixture-grad 'ARMED (captain 2026-08-28)'
  set +e
  out=$(run_order graduate fixture-grad device.config.push --by-captain 2>&1)
  rc=$?
  set -e
  expect_code 1 "$rc" "graduate irreversible exit"
  assert_contains "$out" 'not graduatable' "graduate names the refusal"
  assert_contains "$out" 'device.config.push' "graduate names the kind"
  grep -F 'GRADUATED:' "$ORDERS/fixture-grad.md" >/dev/null \
    && fail "GRADUATED line must not be appended for irreversible kinds" || true
  pass "graduate refuses irreversible kinds via the gateway classifier"
}

test_graduate_refuses_messaging() {
  local out rc
  write_order fixture-grad-mail 'ARMED (captain 2026-08-28)'
  set +e
  out=$(run_order graduate fixture-grad-mail email.send --by-captain 2>&1)
  rc=$?
  set -e
  expect_code 1 "$rc" "graduate messaging exit"
  assert_contains "$out" 'not graduatable' "messaging not graduatable"
  pass "graduate refuses messaging kinds via the gateway classifier"
}

test_graduate_external_kind_appends() {
  local out rc
  write_order fixture-grad-ok 'ARMED (captain 2026-08-28)'
  set +e
  out=$(run_order graduate fixture-grad-ok crm.update --by-captain 2>&1)
  rc=$?
  set -e
  expect_code 0 "$rc" "graduate external exit"
  assert_contains "$out" 'graduated: fixture-grad-ok crm.update' "graduate success"
  grep -E '^GRADUATED: crm.update \(captain ' "$ORDERS/fixture-grad-ok.md" >/dev/null \
    || fail "GRADUATED line must be appended"
  pass "graduate of an external kind appends GRADUATED"
}

test_run_refuses_unregistered_check() {
  local out rc
  write_order fixture-run DRAFT
  set +e
  out=$(run_order run fixture-run 2>&1)
  rc=$?
  set -e
  expect_code 1 "$rc" "run unregistered exit"
  assert_contains "$out" 'no registered check' "run names the missing check"
  pass "run refuses when no registered check exists"
}

test_run_executes_registered_check() {
  local out rc check
  write_order fixture-run2 DRAFT
  check="$STATE_DIR/order-fixture-run2.check.sh"
  cat > "$check" <<'SH'
#!/usr/bin/env bash
printf 'proactive-outbound: 2 clients need contact\n'
SH
  chmod 0700 "$check"
  FM_HOME="$HOME_DIR" FM_STATE_OVERRIDE="$STATE_DIR" "$REGISTER" order-fixture-run2 >/dev/null \
    || fail "could not register order check"
  set +e
  out=$(run_order run fixture-run2 2>&1)
  rc=$?
  set -e
  expect_code 0 "$rc" "run registered exit"
  assert_contains "$out" '2 clients need contact' "run prints check output"
  [ -f "$STATE_DIR/order-fixture-run2.check.log" ] || fail "run must write a last-fire log"
  pass "run executes a registered check and prints its output"
}

test_list_shows_status_tray_and_last_fire() {
  local out rc
  write_order fixture-list 'ARMED (captain 2026-08-28)'
  set +e
  out=$(run_order list 2>&1)
  rc=$?
  set -e
  expect_code 0 "$rc" "list exit"
  assert_contains "$out" 'fixture-list' "list names the slug"
  assert_contains "$out" 'Status: ARMED' "list includes Status"
  assert_contains "$out" 'tray=' "list includes tray depth"
  assert_contains "$out" 'last_fire=' "list includes last fire"
  pass "list prints slug, Status, tray depth, and last fire"
}

test_help_exits_zero
test_missing_status_fails_loudly
test_arm_refuses_without_by_captain
test_arm_with_flag_flips_draft_to_armed
test_disarm_refuses_without_flag
test_graduate_refuses_irreversible
test_graduate_refuses_messaging
test_graduate_external_kind_appends
test_run_refuses_unregistered_check
test_run_executes_registered_check
test_list_shows_status_tray_and_last_fire
