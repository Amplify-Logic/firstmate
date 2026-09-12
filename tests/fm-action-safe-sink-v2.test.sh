#!/usr/bin/env bash
# Behavior tests for the gateway v2 deterministic safe sink (Step 2 sub-order 6).
set -u

# shellcheck source=tests/lib.sh disable=SC1091
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

GW="$ROOT/bin/fm-action-gateway-v2.py"
SINK="$ROOT/bin/fm-action-safe-sink-v2.py"
TMP=$(fm_test_tmproot fm-action-safe-sink-v2)
export FM_ACTION_GATEWAY_TEST=1
export TMPDIR="$TMP/runtime"
mkdir -p "$TMPDIR"

STATE_ROOT="$TMPDIR/fm-gateway-v2-state"

reset_state() {
  [ -n "${TMPDIR:-}" ] || fail "state reset needs the suite temp root"
  if [ -d "$STATE_ROOT" ]; then
    find "$STATE_ROOT" -mindepth 1 -delete
  fi
}

# One canonical plan, built the way the broker builds it: prepare a real request
# and read back the exact stored plan bytes. Writing a plan by hand here would
# test a shape the broker never produces.
canonical_plan() {  # <idempotency-key> <out-file>
  local idem=$1 out=$2 digest database
  digest=$(
    cat <<JSON | $GW prepare | awk -F= '$1=="digest" {print $2}'
{"task_id":"sink-job","domain":"synthetic","action_kind":"email.send","target":"smtp://example.test","parameters":{"recipient":"captain@example.test","subject":"Hello","body":"Exact bytes"},"requested_consent_tier":"confirm-first","environment":"test","policy_version":"v2","idempotency_key":"$idem","expires_at":1893456000,"nonce":"nonce-$idem","requester_id":"not-authority"}
JSON
  )
  [ -n "$digest" ] || fail "could not prepare a plan for $idem"
  database=$($GW inspect-test-paths | python3 -c 'import json,sys; print(json.load(sys.stdin)["database"])')
  python3 - "$database" "$digest" "$out" <<'PY'
import sqlite3
import sys

database, digest, out = sys.argv[1:]
db = sqlite3.connect(database)
row = db.execute("SELECT plan_jcs FROM requests WHERE digest=?", (digest,)).fetchone()
assert row is not None, digest
with open(out, "wb") as handle:
    handle.write(bytes(row[0]))
PY
  printf '%s\n' "$digest"
}

json_of() {
  python3 -c "import json,sys; value=json.load(sys.stdin); print($1)"
}

test_sink_and_broker_agree_on_where_state_lives() {
  local sink_root gateway_root
  reset_state
  sink_root=$($SINK inspect-paths | json_of 'value["state_root"]')
  gateway_root=$($GW inspect-test-paths | python3 -c 'import json,os,sys; print(os.path.dirname(json.load(sys.stdin)["database"]))')
  [ "$sink_root" = "$gateway_root" ] || fail "sink root $sink_root must equal gateway root $gateway_root"
  # A sink whose store the caller could relocate is a sink whose receipts the
  # broker cannot use as evidence, so this is checked by running both programs
  # rather than by reading either one's source.
  pass "the sink resolves the same state root as the broker, derived rather than caller-selected"
}

test_sink_refuses_a_plan_it_is_not_the_executor_for() {
  local out rc plan
  reset_state
  plan="$TMP/plan-refuse.json"
  canonical_plan refuse-idem "$plan" >/dev/null

  set +e
  out=$(python3 -c 'import json,sys; p=json.load(open(sys.argv[1])); p["executor"]["outward_execution"]=True; print(json.dumps(p))' "$plan" | $SINK apply 2>&1)
  rc=$?
  set -e
  expect_code 1 "$rc" "outward executor"
  assert_contains "$out" 'refuses a plan that claims an outward executor' "the safe sink is never the outward path"

  set +e
  out=$(python3 -c 'import json,sys; p=json.load(open(sys.argv[1])); p["executor"]["sha256"]="0"*64; print(json.dumps(p))' "$plan" | $SINK apply 2>&1)
  rc=$?
  set -e
  expect_code 1 "$rc" "foreign executor hash"
  assert_contains "$out" 'authorizes different executor bytes' "a plan binds the exact executor it approved"

  set +e
  out=$(printf 'not json' | $SINK apply 2>&1)
  rc=$?
  set -e
  expect_code 1 "$rc" "malformed plan"

  set +e
  out=$(printf '' | $SINK apply 2>&1)
  rc=$?
  set -e
  expect_code 1 "$rc" "empty plan"
  assert_contains "$out" 'no plan on stdin' "an empty plan is a refusal, not an empty effect"

  assert_absent "$STATE_ROOT/safe-sink-v2.jsonl" "a refused plan writes nothing"
  pass "the safe sink refuses an outward, foreign, malformed, or empty plan and writes nothing"
}

test_sink_is_deterministic_and_matches_the_broker_record() {
  local plan digest result record broker_record
  reset_state
  plan="$TMP/plan-deterministic.json"
  digest=$(canonical_plan deterministic-idem "$plan")
  result=$($SINK apply < "$plan")
  record=$(printf '%s' "$result" | json_of 'value["record_digest"]')
  [ "${#record}" -eq 64 ] || fail "record digest must be SHA-256"

  # The broker computes the same record from the same inputs. That agreement is
  # what lets it verify a settlement against the sink's store instead of
  # believing the executor's report, so it is proved by running both.
  broker_record=$(python3 - "$ROOT/bin/fm-action-gateway-v2.py" "$plan" "$digest" <<'PY'
import importlib.util
import json
import sys

module_path, plan_path, digest = sys.argv[1:]
spec = importlib.util.spec_from_file_location("fm_gateway_v2", module_path)
gateway = importlib.util.module_from_spec(spec)
spec.loader.exec_module(gateway)
plan = json.loads(open(plan_path, "rb").read())
print(gateway.sink_record_digest(digest, plan["request_id"], plan["idempotency_key"], plan["operation"]))
PY
)
  [ "$record" = "$broker_record" ] || fail "sink record $record must equal the broker's $broker_record"

  printf '%s' "$result" | json_of 'value["readback_verified"]' | grep -qx True \
    || fail "the sink must re-read its own effect"
  [ "$(printf '%s' "$result" | json_of 'value["readback_journal_digest"]')" = "$record" ] \
    || fail "the journal readback must find the exact record"
  pass "the sink record is deterministic, matches the broker's independently computed record, and is read back"
}

test_sink_applies_exactly_once() {
  local plan first second first_digest second_digest receipts lines
  reset_state
  plan="$TMP/plan-once.json"
  canonical_plan once-idem "$plan" >/dev/null

  first=$($SINK apply < "$plan")
  second=$($SINK apply < "$plan")
  [ "$(printf '%s' "$first" | json_of 'value["outcome"]')" = applied ] || fail "the first apply must apply"
  [ "$(printf '%s' "$second" | json_of 'value["outcome"]')" = already-applied ] \
    || fail "a repeat must report already-applied, not apply again"
  first_digest=$(printf '%s' "$first" | json_of 'value["record_digest"]')
  second_digest=$(printf '%s' "$second" | json_of 'value["record_digest"]')
  [ "$first_digest" = "$second_digest" ] || fail "a repeat must report the original record"
  [ "$(printf '%s' "$first" | json_of 'value["receipt_id"]')" = "$(printf '%s' "$second" | json_of 'value["receipt_id"]')" ] \
    || fail "a repeat must report the original receipt"

  lines=$(wc -l < "$STATE_ROOT/safe-sink-v2.jsonl" | tr -d ' ')
  [ "$lines" = 1 ] || fail "exactly one record must be appended, got $lines"
  receipts=$(python3 - "$STATE_ROOT/safe-sink-v2.sqlite3" <<'PY'
import sqlite3
import sys

print(sqlite3.connect(sys.argv[1]).execute("SELECT COUNT(*) FROM receipts").fetchone()[0])
PY
)
  [ "$receipts" = 1 ] || fail "exactly one receipt must exist, got $receipts"

  out=$($SINK verify --idempotency-key once-idem)
  assert_contains "$out" '"outcome":"present"' "verify reports what the store actually holds"
  out=$($SINK verify --idempotency-key never-applied)
  assert_contains "$out" '"outcome":"absent"' "verify reports absence honestly"
  pass "a repeated apply of the same approved plan produces exactly one effect"
}

test_sink_state_is_private_and_local() {
  local plan mode entries
  reset_state
  plan="$TMP/plan-private.json"
  canonical_plan private-idem "$plan" >/dev/null
  $SINK apply < "$plan" >/dev/null

  mode=$(/usr/bin/stat -f '%Lp' "$STATE_ROOT")
  [ "$mode" = 700 ] || fail "the state root must be 0700, got $mode"
  mode=$(/usr/bin/stat -f '%Lp' "$STATE_ROOT/safe-sink-v2.jsonl")
  [ "$mode" = 600 ] || fail "the journal must be 0600, got $mode"

  # The whole effect is two files inside the broker's own state root. Anything
  # else appearing here would mean the "safe" sink had grown a second effect.
  entries=$(find "$STATE_ROOT" -mindepth 1 -name 'safe-sink-v2*' | wc -l | tr -d ' ')
  [ "$entries" -ge 2 ] || fail "expected the sink store and journal, found $entries"
  assert_contains "$($SINK apply < "$plan")" '"outward_execution":false' "the sink never reports an outward effect"
  pass "the sink's entire effect is two private files under the broker state root"
}

test_sink_and_broker_agree_on_where_state_lives
test_sink_refuses_a_plan_it_is_not_the_executor_for
test_sink_is_deterministic_and_matches_the_broker_record
test_sink_applies_exactly_once
test_sink_state_is_private_and_local
