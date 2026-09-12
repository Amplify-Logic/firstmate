#!/usr/bin/env bash
# Behavior tests for bin/fm-fota-stage-run.sh: the four run states, duplicate
# protection by operation identity, and the rule that ready needs a readback.
set -u

# shellcheck source=tests/lib.sh disable=SC1091
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

STAGE="$ROOT/bin/fm-fota-stage.py"
RUNNER="$ROOT/bin/fm-fota-stage-run.sh"
ADAPTER="$ROOT/tests/fixtures/staging-portal/adapter.json"
TMP=$(fm_test_tmproot fm-fota-stage-run)
export FM_HOME="$TMP/home"
export FM_STATE_OVERRIDE="$TMP/home/state"
export FM_FOTA_RETURN_DIR="$TMP/return"
mkdir -p "$FM_HOME" "$FM_FOTA_RETURN_DIR"

PAYLOAD='[{"n": "band_lower", "v": 135},{"n": "band_upper", "v": 140}]'

# Runs and returned results are durable by design, so each test starts from a
# clean slate rather than inheriting another test's live operation identity.
reset_runs() {
  rm -rf "$FM_STATE_OVERRIDE/fota-staging" "$FM_FOTA_RETURN_DIR"
  mkdir -p "$FM_FOTA_RETURN_DIR"
}

make_plan() {  # make_plan <attempt> -> plan path
  local attempt=${1:-1} req="$TMP/req-$1.json" plan="$TMP/plan-$1.json"
  cat > "$req" <<JSON
{ "action_kind": "device.config.stage", "device_id": "1234567000111",
  "environment": "prod", "attempt": $attempt,
  "settings": [ { "name": "band_lower", "value": 3.5 },
                { "name": "band_upper", "value": 4.0 } ] }
JSON
  "$STAGE" --adapter "$ADAPTER" --request "$req" --out "$plan" >/dev/null
  printf '%s\n' "$plan"
}

start_run() {  # start_run <plan> -> run id
  "$RUNNER" start "$@" 2>&1 | sed -n 's/^run_id=//p'
}

write_result() {  # write_result <run-id> <json-body>
  printf '%s\n' "$2" > "$FM_FOTA_RETURN_DIR/$1-result.json"
}

test_start_records_pending_and_generates_the_request() {
  reset_runs
  local plan run_id request
  plan=$(make_plan 1)
  run_id=$(start_run "$plan")
  [ -n "$run_id" ] || fail "start did not return a run id"
  assert_contains "$("$RUNNER" status "$run_id")" 'state=pending' "new run is pending"

  # The request is generated from the plan, not hand-written: it must carry the
  # operation identity, the exact target and the exact payload.
  request="$FM_FOTA_RETURN_DIR/$run_id-request.md"
  assert_present "$request" "generated request file exists"
  assert_grep "$run_id" "$request" "request carries the run id"
  assert_grep "1234567000111" "$request" "request names the exact target"
  assert_grep "$PAYLOAD" "$request" "request carries the exact staged payload"
  assert_grep "Do not press the send control" "$request" "request forbids sending"
  pass "start records pending and generates the request from the plan"
}

test_duplicate_operation_is_refused() {
  reset_runs
  local plan first out rc
  plan=$(make_plan 1)
  first=$(start_run "$plan")
  set +e
  out=$("$RUNNER" start "$plan" 2>&1)
  rc=$?
  set -e
  expect_code 1 "$rc" "duplicate start exit"
  assert_contains "$out" "already has a pending run" "duplicate names the live run"
  assert_contains "$out" "$first" "duplicate names the run id"
  # A deliberate retry is a different attempt ordinal, so it is a new identity
  # and is allowed - the guard blocks accidental repeats, not intended ones.
  assert_contains "$("$RUNNER" status "$(start_run "$(make_plan 2)")")" 'state=pending' \
    "a raised attempt ordinal starts a new run"
  pass "a repeat is refused while a deliberate retry is allowed"
}

test_matching_readback_settles_ready() {
  reset_runs
  local run_id
  run_id=$(start_run "$(make_plan 1)")
  write_result "$run_id" "{\"request_id\":\"$run_id\",
    \"observed_device_heading\":\"1234567000111\",
    \"exact_draft_payload\":\"$(printf '%s' "$PAYLOAD" | sed 's/"/\\"/g')\",
    \"command_sent\":false,\"error\":null}"
  assert_contains "$("$RUNNER" settle "$run_id")" 'state=ready' "matching readback is ready"
  assert_contains "$("$RUNNER" status "$run_id")" 'sent=false' "ready did not send"
  pass "a readback matching the plan settles ready"
}

test_payload_spacing_does_not_change_the_verdict() {
  reset_runs
  local run_id
  run_id=$(start_run "$(make_plan 1)")
  # Same payload, different incidental whitespace. The verdict must follow what
  # the payload means, not how the field happened to render it.
  write_result "$run_id" "{\"request_id\":\"$run_id\",
    \"observed_device_heading\":\"1234567000111\",
    \"exact_draft_payload\":\"[{\\\"n\\\":\\\"band_lower\\\",\\\"v\\\":135}, {\\\"n\\\":\\\"band_upper\\\",\\\"v\\\":140}]\",
    \"command_sent\":false,\"error\":null}"
  assert_contains "$("$RUNNER" settle "$run_id")" 'state=ready' "respaced payload still ready"
  pass "payload comparison ignores incidental whitespace"
}

test_missing_readback_settles_unknown_not_ready() {
  reset_runs
  local run_id
  run_id=$(start_run "$(make_plan 1)")
  # A result that asserts success but reports nothing it actually read back.
  write_result "$run_id" "{\"request_id\":\"$run_id\",\"outcome\":\"success\",\"error\":null}"
  local out
  out=$("$RUNNER" settle "$run_id")
  assert_contains "$out" 'state=unknown' "unsupported success claim is unknown"
  assert_not_contains "$out" 'state=ready' "an assertion alone never reaches ready"
  pass "a success claim without a readback settles unknown, never ready"
}

test_wrong_target_settles_error() {
  reset_runs
  local run_id
  run_id=$(start_run "$(make_plan 1)")
  write_result "$run_id" "{\"request_id\":\"$run_id\",
    \"observed_device_heading\":\"9999999000222\",
    \"exact_draft_payload\":\"$(printf '%s' "$PAYLOAD" | sed 's/"/\\"/g')\",
    \"command_sent\":false}"
  assert_contains "$("$RUNNER" settle "$run_id")" 'state=error' "wrong target is an error"
  pass "a readback from the wrong target settles error"
}

test_mismatched_payload_settles_error() {
  reset_runs
  local run_id
  run_id=$(start_run "$(make_plan 1)")
  write_result "$run_id" "{\"request_id\":\"$run_id\",
    \"observed_device_heading\":\"1234567000111\",
    \"exact_draft_payload\":\"[{\\\"n\\\":\\\"band_lower\\\",\\\"v\\\":130}]\",
    \"command_sent\":false}"
  assert_contains "$("$RUNNER" settle "$run_id")" 'state=error' "payload mismatch is an error"
  pass "a readback that contradicts the staged payload settles error"
}

test_reported_send_is_a_contract_violation() {
  reset_runs
  local run_id out
  run_id=$(start_run "$(make_plan 1)")
  write_result "$run_id" "{\"request_id\":\"$run_id\",
    \"observed_device_heading\":\"1234567000111\",
    \"exact_draft_payload\":\"$(printf '%s' "$PAYLOAD" | sed 's/"/\\"/g')\",
    \"command_sent\":true}"
  out=$("$RUNNER" settle "$run_id")
  assert_contains "$out" 'state=error' "a reported send is an error"
  assert_contains "$out" 'must not send' "the reason names the violated contract"
  pass "a result reporting a send is never accepted as ready"
}

test_unattributable_result_settles_unknown() {
  reset_runs
  local run_id
  run_id=$(start_run "$(make_plan 1)")
  write_result "$run_id" '{"request_id":"some-other-run",
    "observed_device_heading":"1234567000111","command_sent":false}'
  assert_contains "$("$RUNNER" settle "$run_id")" 'state=unknown' "foreign id is unattributable"
  pass "a result carrying another run's id is not attributed to this one"
}

test_deadline_without_result_settles_unknown_not_error() {
  reset_runs
  local run_id out
  run_id=$(start_run "$(make_plan 1)" --deadline 0)
  out=$("$RUNNER" settle "$run_id")
  # Nothing was observed. That is not the same as observing that nothing
  # happened, so it must not be reported as a failure.
  assert_contains "$out" 'state=unknown' "a passed deadline is unknown"
  assert_contains "$out" 'verify at the portal' "unknown tells the operator what to do"
  assert_not_contains "$out" 'state=error' "an unobserved outcome is not an error"
  pass "a passed deadline settles unknown and directs a human to verify"
}

test_pending_before_deadline_stays_pending() {
  reset_runs
  local run_id
  run_id=$(start_run "$(make_plan 1)" --deadline 600)
  assert_contains "$("$RUNNER" settle "$run_id")" 'state=pending' "still pending inside deadline"
  pass "a run inside its deadline stays pending rather than guessing"
}

test_settled_run_is_not_resettled() {
  reset_runs
  local run_id
  run_id=$(start_run "$(make_plan 1)" --deadline 0)
  "$RUNNER" settle "$run_id" >/dev/null
  assert_contains "$("$RUNNER" settle "$run_id")" 'already settled' "second settle is a no-op"
  pass "a settled run is never re-decided"
}

test_runner_never_sends() {
  reset_runs
  local hits
  set +e
  hits=$(grep -nE 'Send Command"?\)|click\(|curl|wget|playwright' "$RUNNER" \
    | grep -v 'Do not press the send control' || true)
  set -e
  [ -z "$hits" ] || fail "runner must not drive a browser or reach outward: $hits"
  pass "the runner holds no send or browser-driving code path"
}

test_start_records_pending_and_generates_the_request
test_duplicate_operation_is_refused
test_matching_readback_settles_ready
test_payload_spacing_does_not_change_the_verdict
test_missing_readback_settles_unknown_not_ready
test_wrong_target_settles_error
test_mismatched_payload_settles_error
test_reported_send_is_a_contract_violation
test_unattributable_result_settles_unknown
test_deadline_without_result_settles_unknown_not_error
test_pending_before_deadline_stays_pending
test_settled_run_is_not_resettled
test_runner_never_sends
