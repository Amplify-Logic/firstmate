#!/usr/bin/env bash
# Behavior tests for bin/fm-fota-stage-run.sh: the run states, the queue
# transport and its receipt, duplicate protection by operation identity, the
# rule that ready needs a readback, and explicit captain acknowledgement.
#
# The transport is an injected stub in a temp directory. Nothing here calls the
# real `codex` binary or reaches a shared companion: the thread identity and the
# transport command are both overridden, so an unconfigured environment queues
# into nothing at all rather than into somebody else's session.
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
mkdir -p "$FM_HOME" "$FM_FOTA_RETURN_DIR" "$TMP/bin"

# An isolated transport stub. It records exactly what it was asked to queue and
# prints a receipt in the shape the real CLI does, so the tests can assert the
# transport was invoked and the receipt was correlated - without any session,
# any network, or any shared companion existing.
QUEUE_LOG="$TMP/queue-calls.log"
STUB="$TMP/bin/codex-stub"
cat > "$STUB" <<'STUBEOF'
#!/usr/bin/env bash
echo "$*" >> "$FM_TEST_QUEUE_LOG"
if [ -n "${FM_TEST_QUEUE_FAIL:-}" ]; then
  echo "stub refused: $FM_TEST_QUEUE_FAIL" >&2
  exit 3
fi
if [ -n "${FM_TEST_QUEUE_HANG:-}" ]; then
  sleep "$FM_TEST_QUEUE_HANG"
fi
echo "queued to thread ${3:-?}"
echo "message_id: stub-msg-$$"
STUBEOF
chmod +x "$STUB"
# A path that exists and cannot be executed: not the same as an absent one to
# the operating system, the same to the captain - nothing was enqueued.
: > "$TMP/bin/not-executable"
chmod 000 "$TMP/bin/not-executable"
export FM_TEST_QUEUE_LOG="$QUEUE_LOG"
export FM_FOTA_QUEUE_CMD="$STUB"
export FM_FOTA_COMPANION_THREAD="isolated-stub-thread"


file_mode() {  # portable octal mode; the repo's established uname switch
  if [ "$(uname)" = Darwin ]; then stat -f %Lp "$1" 2>/dev/null; else stat -c %a "$1" 2>/dev/null; fi
}

PAYLOAD='[{"n": "band_lower", "v": 135},{"n": "band_upper", "v": 140}]'

# Runs and returned results are durable by design, so each test starts from a
# clean slate rather than inheriting another test's live operation identity.
reset_runs() {
  rm -rf "$FM_STATE_OVERRIDE/fota-staging" "$FM_FOTA_RETURN_DIR"
  mkdir -p "$FM_FOTA_RETURN_DIR"
  : > "$QUEUE_LOG"
  unset FM_TEST_QUEUE_FAIL FM_TEST_QUEUE_HANG
  export FM_FOTA_COMPANION_THREAD="isolated-stub-thread"
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

plan_key() {  # plan_key <plan> -> the plan's idempotency key
  PLAN="$1" python3 -c '
import json, os
print(json.load(open(os.environ["PLAN"], encoding="utf-8"))["operation"]["idempotency_key"])
'
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

test_start_queues_through_the_documented_transport() {
  reset_runs
  local plan run_id out record
  plan=$(make_plan 1)
  out=$("$RUNNER" start "$plan" 2>&1)
  run_id=$(printf '%s\n' "$out" | sed -n 's/^run_id=//p')
  assert_contains "$out" 'state=pending' "an accepted queue leaves the run pending"
  assert_contains "$out" 'queue=accepted' "start reports the queue outcome"
  assert_contains "$out" 'receipt=stub-msg-' "start reports the queue receipt"

  # The transport was invoked with the documented flags, against the explicitly
  # configured thread, carrying this run's id so the receipt is correlated.
  assert_grep 'queue --thread isolated-stub-thread --message' "$QUEUE_LOG" \
    "the documented transport was invoked"
  assert_grep "$run_id" "$QUEUE_LOG" "the queued message carries the run id"

  record="$FM_STATE_OVERRIDE/fota-staging/$run_id.json"
  assert_grep '"accepted": true' "$record" "the record stores that the queue accepted"
  assert_grep '"receipt": "stub-msg-' "$record" "the record stores the receipt"
  # Accepted is not pickup, and the record must never let the two be confused.
  assert_grep '"pickup_observed": false' "$record" "a receipt is not pickup"
  pass "start queues through the documented transport and stores the receipt"
}

test_unconfigured_transport_is_prepared_not_pending() {
  reset_runs
  local out run_id
  unset FM_FOTA_COMPANION_THREAD
  out=$("$RUNNER" start "$(make_plan 1)" 2>&1)
  run_id=$(printf '%s\n' "$out" | sed -n 's/^run_id=//p')
  # A generated file alone is only `prepared`. Claiming `pending` here would
  # assert a delivery that never happened.
  assert_contains "$out" 'state=prepared' "an unconfigured transport is prepared"
  assert_contains "$out" 'queue=not-configured' "the outcome names why"
  [ ! -s "$QUEUE_LOG" ] || fail "nothing may be enqueued without a configured thread"
  assert_contains "$("$RUNNER" settle "$run_id")" 'state=prepared' \
    "a prepared run with no result is not re-decided as unknown"
  pass "an unconfigured transport records prepared and enqueues nothing"
}

test_refused_queue_is_honest_and_never_requeued() {
  reset_runs
  local plan out rc first
  plan=$(make_plan 1)
  out=$(FM_TEST_QUEUE_FAIL="no such thread" "$RUNNER" start "$plan" 2>&1)
  first=$(printf '%s\n' "$out" | sed -n 's/^run_id=//p')
  assert_contains "$out" 'state=prepared' "a refused queue is prepared, not pending"
  assert_contains "$out" 'queue=refused' "the outcome names the refusal"
  assert_contains "$out" 'no such thread' "the reason quotes the transport"

  # The duplicate guard covers the queue step: the same operation is never
  # queued a second time just because the first attempt did not land.
  set +e
  out=$("$RUNNER" start "$plan" 2>&1)
  rc=$?
  set -e
  expect_code 1 "$rc" "repeat after a refused queue exits non-zero"
  assert_contains "$out" "already has a prepared run" "the guard names the prepared run"
  assert_contains "$out" "$first" "the guard names the run id"
  pass "a refused queue is an honest state that is never silently re-queued"
}

test_queue_timeout_is_pending_and_never_requeued() {
  reset_runs
  local plan out rc
  plan=$(make_plan 1)
  out=$(FM_TEST_QUEUE_HANG=3 FM_FOTA_QUEUE_TIMEOUT=1 "$RUNNER" start "$plan" 2>&1)
  # A timeout is the one genuinely ambiguous case: the message may or may not
  # have been enqueued. It is never accepted, and never sent again on that doubt.
  assert_contains "$out" 'queue=timeout' "a timed-out queue says so"
  assert_contains "$out" 'state=pending' "an ambiguous delivery stays live"
  set +e
  out=$("$RUNNER" start "$plan" 2>&1)
  rc=$?
  set -e
  expect_code 1 "$rc" "repeat after a timeout exits non-zero"
  pass "a queue timeout is ambiguous, live, and never re-queued"
}

test_generated_request_is_not_world_readable() {
  reset_runs
  local run_id mode
  run_id=$(start_run "$(make_plan 1)")
  # The request carries the same device identifier, payload and operation
  # identity the 0600 record is protected for.
  mode=$(file_mode "$FM_FOTA_RETURN_DIR/$run_id-request.md")
  [ "$mode" = "600" ] || fail "generated request is mode $mode, expected 600"
  pass "the generated request gets the same protection as the record"
}

test_a_settled_record_is_never_overwritten() {
  reset_runs
  local plan key clock first second
  plan=$(make_plan 1)
  key=$(plan_key "$plan")
  # The id stem is pinned, so both starts are GUARANTEED to want the same id
  # rather than racing the wall clock for it. That is the whole point: the
  # collision branch has to run, not merely be likely to.
  clock=$(date +%s)
  export FM_FOTA_RUN_ID_CLOCK="$clock"

  first=$(start_run "$plan" --deadline 0)
  [ "$first" = "$key-$clock" ] || fail "the first run did not take the pinned stem: $first"
  "$RUNNER" settle "$first" >/dev/null
  assert_contains "$("$RUNNER" status "$first")" 'state=unknown' "first run settled unknown"

  # The SAME plan, so the same idempotency key and the same pinned stem. The run
  # has settled, so the duplicate guard lets it through - and the id it wants is
  # already taken, which is exactly the case that used to overwrite the settled
  # record and read its result file back as this run's own evidence.
  second=$(start_run "$plan")
  [ "$second" = "$key-$clock-2" ] \
    || fail "the second run did not take the collision branch: $second"
  unset FM_FOTA_RUN_ID_CLOCK

  assert_contains "$("$RUNNER" status "$first")" 'state=unknown' \
    "the settled outcome survived a later run"
  assert_contains "$("$RUNNER" status "$second")" 'state=pending' \
    "the second run is its own live run"
  pass "a settled record is never written over by a later run"
}

test_a_stale_result_is_never_read_as_a_new_runs_readback() {
  reset_runs
  local plan first second
  plan=$(make_plan 1)
  first=$(start_run "$plan" --deadline 0)
  # A result arrives for the first run, which then settles and is archived by
  # hand - the documented way records are cleared - leaving its result behind.
  write_result "$first" "{\"request_id\":\"$first\",
    \"observed_device_heading\":\"1234567000111\",
    \"exact_draft_payload\":\"$(printf '%s' "$PAYLOAD" | sed 's/"/\\"/g')\",
    \"command_sent\":false}"
  "$RUNNER" settle "$first" >/dev/null
  rm -f "$FM_STATE_OVERRIDE/fota-staging/$first.json"
  second=$(start_run "$plan")
  [ "$first" != "$second" ] || fail "a new run claimed an id whose result already exists"
  assert_contains "$("$RUNNER" settle "$second")" 'state=pending' \
    "the new run has no readback of its own yet"
  pass "a leftover result file is never accepted as a new run's readback"
}

test_deadline_argument_is_validated() {
  reset_runs
  local plan out rc
  plan=$(make_plan 1)
  set +e
  out=$("$RUNNER" start "$plan" --deadline abc 2>&1)
  rc=$?
  set -e
  expect_code 1 "$rc" "non-numeric deadline exit"
  assert_contains "$out" 'fm-fota-stage-run:' "the script owns the message"
  assert_not_contains "$out" 'Traceback' "no uncaught traceback reaches the operator"
  set +e
  out=$("$RUNNER" start "$plan" --deadline 2>&1)
  rc=$?
  set -e
  expect_code 1 "$rc" "missing deadline value exit"
  assert_not_contains "$out" 'Traceback' "a missing value is refused, not interpreted"
  pass "--deadline is validated with this script's own refusal"
}

test_acknowledgement_clears_the_ask_without_losing_the_outcome() {
  reset_runs
  local run_id record out
  run_id=$(start_run "$(make_plan 1)" --deadline 0)
  "$RUNNER" settle "$run_id" >/dev/null
  out=$("$RUNNER" ack "$run_id" --note "checked at the portal")
  assert_contains "$out" 'acknowledged=true' "ack reports the acknowledgement"
  assert_contains "$out" 'state=unknown' "ack does not change the outcome"

  record="$FM_STATE_OVERRIDE/fota-staging/$run_id.json"
  assert_present "$record" "the record still exists"
  assert_grep '"state": "unknown"' "$record" "the unobserved outcome is preserved"
  assert_grep 'verify at the portal' "$record" "the original reason is preserved"
  assert_grep '"sent": false' "$record" "nothing is marked applied"
  assert_contains "$("$RUNNER" list --json)" '"acknowledged": true' \
    "the surface is told it is no longer an open ask"
  pass "an acknowledgement clears the ask and preserves every piece of evidence"
}

refuse_ack() {  # refuse_ack <run-id> <label>
  local out rc
  set +e
  out=$("$RUNNER" ack "$1" 2>&1)
  rc=$?
  set -e
  [ "$rc" -ne 0 ] || fail "acknowledging a $2 run should refuse"
  assert_contains "$out" 'only a settled preparation alert' "the $2 refusal says why"
}

test_a_live_run_cannot_be_acknowledged() {
  reset_runs
  local run_id
  # Every live state, which is the same set the duplicate guard blocks on: a run
  # that has not settled has no outcome the captain could be finished with.
  run_id=$(start_run "$(make_plan 1)" --deadline 600)
  refuse_ack "$run_id" pending
  assert_contains "$("$RUNNER" status "$run_id")" 'state=pending' "the pending run is untouched"

  write_result "$run_id" "{\"request_id\":\"$run_id\",
    \"observed_device_heading\":\"1234567000111\",
    \"exact_draft_payload\":\"$(printf '%s' "$PAYLOAD" | sed 's/"/\\"/g')\",
    \"command_sent\":false}"
  "$RUNNER" settle "$run_id" >/dev/null
  assert_contains "$("$RUNNER" status "$run_id")" 'state=ready' "the run is ready"
  refuse_ack "$run_id" ready

  reset_runs
  unset FM_FOTA_COMPANION_THREAD
  run_id=$(start_run "$(make_plan 1)")
  assert_contains "$("$RUNNER" status "$run_id")" 'state=prepared' "the run is prepared"
  refuse_ack "$run_id" prepared
  pass "no live run - prepared, pending or ready - can be acknowledged away"
}

test_acknowledgement_is_idempotent_and_keeps_the_full_history() {
  reset_runs
  local run_id out
  run_id=$(start_run "$(make_plan 1)" --deadline 0)
  "$RUNNER" settle "$run_id" >/dev/null
  "$RUNNER" ack "$run_id" --note "checked at the portal" >/dev/null
  out=$("$RUNNER" ack "$run_id")
  assert_contains "$out" 'already acknowledged' "a repeat acknowledgement is a no-op"
  assert_contains "$out" 'state=unknown' "the repeat does not touch the outcome"

  # The active ask list is the ONLY thing acknowledgement changes: list and show
  # still carry the run, its outcome, its reason and its evidence paths.
  assert_contains "$("$RUNNER" list)" "$run_id" "list still carries the run"
  out=$("$RUNNER" show "$run_id")
  assert_contains "$out" '"state": "unknown"' "show still carries the outcome"
  assert_contains "$out" 'verify at the portal' "show still carries the reason"
  assert_contains "$out" '"result_path"' "show still carries the evidence path"
  assert_contains "$out" '"queue"' "show still carries the queue receipt record"
  pass "acknowledgement is idempotent and removes nothing but the open ask"
}

test_a_changed_outcome_is_not_covered_by_an_earlier_acknowledgement() {
  reset_runs
  local run_id record
  run_id=$(start_run "$(make_plan 1)" --deadline 0)
  "$RUNNER" settle "$run_id" >/dev/null
  "$RUNNER" ack "$run_id" >/dev/null
  assert_contains "$("$RUNNER" list --json)" '"acknowledged": true' "the alert is acknowledged"

  # The acknowledgement covered one exact outcome. However a later outcome
  # arrives - here by a hand edit, the documented way a record is corrected - it
  # is a different thing to be told about, so the run is an open ask again.
  record="$FM_STATE_OVERRIDE/fota-staging/$run_id.json"
  RECORD="$record" python3 -c '
import json, os
path = os.environ["RECORD"]
record = json.load(open(path, encoding="utf-8"))
record["state"] = "error"
record["reason"] = "readback payload does not match the staged plan"
json.dump(record, open(path, "w", encoding="utf-8"), indent=2, sort_keys=True)
'
  assert_contains "$("$RUNNER" list --json)" '"acknowledged": false' \
    "a changed outcome is not covered by the earlier acknowledgement"
  assert_contains "$("$RUNNER" status "$run_id")" 'acknowledged=superseded' \
    "status names why the acknowledgement no longer stands"
  pass "an acknowledgement never covers an outcome it was not given for"
}

test_the_deck_is_told_exactly_why_a_run_was_never_queued() {
  reset_runs
  local run_id out
  unset FM_FOTA_COMPANION_THREAD
  run_id=$(start_run "$(make_plan 1)")
  out=$("$RUNNER" list --json)
  # not-configured, not-installed and a transport that refused are three
  # different things, and the surface that shows them must be able to say which.
  assert_contains "$out" 'no companion thread is configured' \
    "an unconfigured transport reaches the surface with its own reason"

  reset_runs
  out=$(FM_TEST_QUEUE_FAIL="no such thread" "$RUNNER" start "$(make_plan 1)" 2>&1)
  assert_contains "$("$RUNNER" list --json)" 'no such thread' \
    "a refused transport reaches the surface quoting the transport"

  reset_runs
  out=$(FM_FOTA_QUEUE_CMD="$TMP/bin/not-executable" "$RUNNER" start "$(make_plan 1)" 2>&1)
  assert_not_contains "$out" 'Traceback' "an unusable transport path is not a traceback"
  assert_contains "$out" 'state=prepared' "an unusable transport path is prepared"
  assert_contains "$("$RUNNER" list --json)" 'not-installed' \
    "an unusable transport path is reported as not installed"
  pass "the surface can tell every never-queued reason apart"
}

test_a_failed_start_releases_the_run_id_it_claimed() {
  reset_runs
  local plan key clock rc out
  plan=$(make_plan 1)
  key=$(plan_key "$plan")
  clock=$(date +%s)
  # With the stem pinned the request path is predictable, so it can be made
  # impossible to write - a failure AFTER the id is claimed, which is the only
  # window in which a claim can be left behind.
  mkdir -p "$FM_FOTA_RETURN_DIR/$key-$clock-request.md"
  set +e
  out=$(FM_FOTA_RUN_ID_CLOCK="$clock" "$RUNNER" start "$plan" 2>&1)
  rc=$?
  set -e
  [ "$rc" -ne 0 ] || fail "a start that cannot write its request should fail: $out"
  [ ! -e "$FM_STATE_OVERRIDE/fota-staging/$key-$clock.json" ] \
    || fail "the claimed run id was left behind as a record nothing can read"
  # And the id is free again for a start that can complete.
  rmdir "$FM_FOTA_RETURN_DIR/$key-$clock-request.md"
  [ "$(FM_FOTA_RUN_ID_CLOCK="$clock" start_run "$plan")" = "$key-$clock" ] \
    || fail "the released run id was not reusable"
  pass "a start that cannot complete releases the run id it claimed"
}

test_an_incomplete_plan_is_refused_before_anything_is_claimed() {
  reset_runs
  local plan broken rc out
  plan=$(make_plan 1)
  broken="$TMP/plan-no-target.json"
  PLAN="$plan" BROKEN="$broken" python3 -c '
import json, os
plan = json.load(open(os.environ["PLAN"], encoding="utf-8"))
plan["target"].pop("device_id")
json.dump(plan, open(os.environ["BROKEN"], "w", encoding="utf-8"))
'
  set +e
  out=$("$RUNNER" start "$broken" 2>&1)
  rc=$?
  set -e
  expect_code 1 "$rc" "incomplete plan exit"
  assert_contains "$out" 'fm-fota-stage-run:' "the script owns the message"
  assert_not_contains "$out" 'Traceback' "an incomplete plan is refused, not crashed into"
  # Nothing was claimed, so nothing has to be released.
  [ -z "$(ls -A "$FM_STATE_OVERRIDE/fota-staging" 2>/dev/null)" ] \
    || fail "an incomplete plan claimed a run id"
  [ -z "$(ls -A "$FM_FOTA_RETURN_DIR" 2>/dev/null)" ] \
    || fail "an incomplete plan wrote into the return directory"
  pass "an incomplete plan is refused before a run id is claimed"
}

test_the_generated_request_carries_the_payload_unindented() {
  reset_runs
  local run_id request
  run_id=$(start_run "$(make_plan 1)")
  request="$FM_FOTA_RETURN_DIR/$run_id-request.md"
  # The browser side is told to stage this verbatim, so the payload line must be
  # the plan's payload and nothing else - no leading whitespace that would also
  # turn the whole instruction body into a Markdown code block.
  grep -qxF "$PAYLOAD" "$request" \
    || fail "the payload line is not byte-identical to the plan's payload"
  grep -qxF "# Generated staging request - form preparation only" "$request" \
    || fail "the heading is indented"
  grep -qxF "2. Stage this exact payload into the command field:" "$request" \
    || fail "the instruction body is indented"
  grep -n "^    " "$request" \
    && fail "the generated request carries accidental indentation"
  pass "the generated request carries the payload exactly as the plan holds it"
}

test_the_generated_request_states_the_plans_permitted_origin() {
  reset_runs
  local plan origin run_id request
  plan=$(make_plan 1)
  origin=$(PLAN="$plan" python3 -c '
import json, os
print(json.load(open(os.environ["PLAN"], encoding="utf-8"))["adapter"]["origin"])
')
  # The fixture adapter's invented origin. It reaches the plan as immutable
  # preparation data and is stated verbatim in the request the browser side gets,
  # so the instruction names a real scope instead of a placeholder.
  [ "$origin" = "https://portal.example.invalid" ] \
    || fail "the plan did not carry the adapter's origin: $origin"
  run_id=$(start_run "$plan")
  request="$FM_FOTA_RETURN_DIR/$run_id-request.md"
  grep -qxF "Permitted origin: $origin" "$request" \
    || fail "the generated request does not state the plan's origin"
  assert_not_contains "$(cat "$request")" "declared by the local adapter" \
    "no placeholder stands in for the real scope"
  # Honest about what the wording is: a declaration the browser side is asked to
  # honour, never a claim that this path confines a browser.
  grep -qF "not enforced by it" "$request" \
    || fail "the request does not say the origin is declared rather than enforced"
  pass "the generated request states the plan's own permitted origin"
}

test_a_plan_without_a_usable_origin_is_never_prepared_or_queued() {
  reset_runs
  local plan bad out rc
  plan=$(make_plan 1)
  # Missing, empty, wildcard, and path-bearing: none of them may fall back to a
  # permissive default. A request that cannot name its scope is not dispatched.
  for bad in '__MISSING__' '' '*' 'https://*.example.invalid' \
             'https://portal.example.invalid/devices'; do
    rm -rf "$FM_STATE_OVERRIDE/fota-staging" "$FM_FOTA_RETURN_DIR"
    mkdir -p "$FM_FOTA_RETURN_DIR"
    : > "$QUEUE_LOG"
    bad="$bad" PLAN="$plan" OUT="$TMP/plan-bad-origin.json" python3 -c '
import json, os
plan = json.load(open(os.environ["PLAN"], encoding="utf-8"))
if os.environ["bad"] == "__MISSING__":
    plan["adapter"].pop("origin", None)
else:
    plan["adapter"]["origin"] = os.environ["bad"]
json.dump(plan, open(os.environ["OUT"], "w", encoding="utf-8"))
'
    set +e
    out=$("$RUNNER" start "$TMP/plan-bad-origin.json" 2>&1)
    rc=$?
    set -e
    expect_code 1 "$rc" "origin [$bad] start exit"
    assert_contains "$out" 'fm-fota-stage-run:' "the script owns the message for [$bad]"
    assert_not_contains "$out" 'Traceback' "origin [$bad] is refused, not crashed into"
    # Refused before a run id is claimed, so there is no record, no request file,
    # and - the point of the queue-step refusal - nothing enqueued.
    [ -z "$(ls -A "$FM_STATE_OVERRIDE/fota-staging" 2>/dev/null)" ] \
      || fail "origin [$bad] claimed a run id"
    [ -z "$(ls -A "$FM_FOTA_RETURN_DIR" 2>/dev/null)" ] \
      || fail "origin [$bad] generated a request"
    [ ! -s "$QUEUE_LOG" ] || fail "origin [$bad] reached the transport"
  done
  pass "a plan that cannot name its origin is refused, never queued permissively"
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
test_start_queues_through_the_documented_transport
test_unconfigured_transport_is_prepared_not_pending
test_refused_queue_is_honest_and_never_requeued
test_queue_timeout_is_pending_and_never_requeued
test_generated_request_is_not_world_readable
test_a_settled_record_is_never_overwritten
test_a_stale_result_is_never_read_as_a_new_runs_readback
test_deadline_argument_is_validated
test_acknowledgement_clears_the_ask_without_losing_the_outcome
test_a_live_run_cannot_be_acknowledged
test_acknowledgement_is_idempotent_and_keeps_the_full_history
test_a_changed_outcome_is_not_covered_by_an_earlier_acknowledgement
test_the_deck_is_told_exactly_why_a_run_was_never_queued
test_a_failed_start_releases_the_run_id_it_claimed
test_an_incomplete_plan_is_refused_before_anything_is_claimed
test_the_generated_request_carries_the_payload_unindented
test_the_generated_request_states_the_plans_permitted_origin
test_a_plan_without_a_usable_origin_is_never_prepared_or_queued
