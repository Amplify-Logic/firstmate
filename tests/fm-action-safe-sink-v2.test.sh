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

# The two roots are separate by design: the broker owns one, the executor owns
# the other, and neither program may write the other's.
STATE_ROOT="$TMPDIR/fm-gateway-v2-state"
SINK_ROOT="$TMPDIR/fm-gateway-v2-sink"

reset_state() {
  local root
  [ -n "${TMPDIR:-}" ] || fail "state reset needs the suite temp root"
  for root in "$STATE_ROOT" "$SINK_ROOT"; do
    if [ -d "$root" ]; then
      chmod u+rwx "$root" 2>/dev/null || true
      find "$root" -mindepth 1 -delete
    fi
  done
}

# Every mode assertion below reads a file the sink actually created. This suite
# runs as one UID, so it proves the generated modes and the journal mode the
# broker's read-only path depends on, and proves nothing about two separated
# principals: that remains the captain-at-Mac measurement made by
# bin/fm-worker-boundary-regression.sh against a real installation.
assert_mode() {  # <path> <expected>
  local observed
  observed=$(/usr/bin/stat -f '%Lp' "$1")
  [ "$observed" = "$2" ] || fail "$1 must be mode $2, got $observed"
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

test_sink_root_is_its_own_and_not_the_broker_root() {
  local sink_root broker_root expected_by_broker
  reset_state
  # Checked by running both programs rather than by reading either one's source.
  # A sink whose store the caller could relocate is a sink whose receipts the
  # broker cannot use as evidence, and a sink writing inside the broker's own
  # 0700 root could not write at all once the two accounts are distinct.
  sink_root=$($SINK inspect-paths | json_of 'value["sink_root"]')
  broker_root=$($GW inspect-test-paths | json_of 'value["state_root"]')
  expected_by_broker=$($GW inspect-test-paths | json_of 'value["sink_root"]')
  [ -n "$sink_root" ] || fail "the sink must report its own root"
  [ "$sink_root" != "$broker_root" ] || fail "the receipt store must not live under the broker root $broker_root"
  [ "$sink_root" = "$expected_by_broker" ] || fail "the broker looks for the store at $expected_by_broker, the sink writes it at $sink_root"
  pass "the receipt store has its own root, derived rather than caller-selected, and both programs resolve the same one"
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

  assert_absent "$SINK_ROOT/safe-sink-v2.jsonl" "a refused plan writes nothing"
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

  lines=$(wc -l < "$SINK_ROOT/safe-sink-v2.jsonl" | tr -d ' ')
  [ "$lines" = 1 ] || fail "exactly one record must be appended, got $lines"
  receipts=$(python3 - "$SINK_ROOT/safe-sink-v2.sqlite3" <<'PY'
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

test_sink_store_is_group_readable_and_writable_by_nobody_else() {
  local plan entries sidecar loose
  reset_state
  plan="$TMP/plan-private.json"
  canonical_plan private-idem "$plan" >/dev/null
  $SINK apply < "$plan" >/dev/null

  # 0750 on the directory and 0640 on every file is exactly what gives the
  # broker read authority over the evidence it settles from and no authority to
  # author any of it.
  assert_mode "$SINK_ROOT" 750
  assert_mode "$SINK_ROOT/safe-sink-v2.sqlite3" 640
  assert_mode "$SINK_ROOT/safe-sink-v2.jsonl" 640
  for sidecar in safe-sink-v2.sqlite3-journal safe-sink-v2.sqlite3-wal safe-sink-v2.sqlite3-shm; do
    [ -e "$SINK_ROOT/$sidecar" ] || continue
    assert_mode "$SINK_ROOT/$sidecar" 640
  done
  loose=$(find "$SINK_ROOT" -perm +022 | wc -l | tr -d ' ')
  [ "$loose" = 0 ] || fail "nothing in the receipt store may be group-writable or other-writable"
  loose=$(find "$SINK_ROOT" -perm +007 | wc -l | tr -d ' ')
  [ "$loose" = 0 ] || fail "nothing in the receipt store may be reachable by others"

  # The whole effect is two files inside the executor's own store root. Anything
  # else appearing here would mean the "safe" sink had grown a second effect.
  entries=$(find "$SINK_ROOT" -mindepth 1 -name 'safe-sink-v2.sqlite3' -o -mindepth 1 -name 'safe-sink-v2.jsonl' | wc -l | tr -d ' ')
  [ "$entries" = 2 ] || fail "expected the sink store and journal, found $entries"
  assert_absent "$STATE_ROOT/safe-sink-v2.sqlite3" "the sink writes nothing into the broker root"
  assert_contains "$($SINK apply < "$plan")" '"outward_execution":false' "the sink never reports an outward effect"
  pass "the receipt store is the executor's own, group-readable, and writable by nobody else"
}

test_broker_reads_the_store_without_being_able_to_write_it() {
  local plan out
  reset_state
  plan="$TMP/plan-readonly.json"
  canonical_plan readonly-idem "$plan" >/dev/null
  $SINK apply < "$plan" >/dev/null

  # A WAL store would defeat the broker's read outright: a read-only opener has
  # to create the -shm wal-index beside the database, so a reader that cannot
  # write the directory is refused. The directory is made unwritable here to
  # prove the broker's read works through group read on the files alone.
  assert_absent "$SINK_ROOT/safe-sink-v2.sqlite3-wal" "the store must not be in WAL mode"
  assert_absent "$SINK_ROOT/safe-sink-v2.sqlite3-shm" "the store must not carry a WAL index"
  chmod 0500 "$SINK_ROOT"
  out=$(python3 - "$ROOT/bin/fm-action-gateway-v2.py" readonly-idem <<'BROKER_READ'
import importlib.util
import sqlite3
import sys
import urllib.parse

module_path, idempotency_key = sys.argv[1:]
spec = importlib.util.spec_from_file_location("fm_gateway_v2", module_path)
gateway = importlib.util.module_from_spec(spec)
spec.loader.exec_module(gateway)
presence, digest = gateway.observed_sink_record(idempotency_key)
print(f"presence={presence}")
print(f"digest_len={len(digest or '')}")
uri = f"file:{urllib.parse.quote(str(gateway.sink_database_path()))}?mode=ro"
connection = sqlite3.connect(uri, uri=True)
try:
    connection.execute("DELETE FROM receipts")
    print("write=accepted")
except sqlite3.Error as exc:
    print(f"write=refused:{exc}")
finally:
    connection.close()
readonly = sqlite3.connect(uri, uri=True)
print("journal_mode=" + str(readonly.execute("PRAGMA journal_mode").fetchone()[0]))
readonly.close()
BROKER_READ
)
  chmod 0750 "$SINK_ROOT"
  assert_contains "$out" 'presence=present' "the broker reads the sink's own store through group read"
  assert_contains "$out" 'digest_len=64' "the broker reads back the record digest it settles from"
  assert_contains "$out" 'write=refused' "the broker's connection to the receipt store cannot write it"
  assert_not_contains "$out" 'journal_mode=wal' "a WAL store could not be read by a reader that cannot write the directory"
  pass "the broker reads a real store it cannot write, through a directory it cannot write either"
}

test_sink_root_is_its_own_and_not_the_broker_root
test_sink_refuses_a_plan_it_is_not_the_executor_for
test_sink_is_deterministic_and_matches_the_broker_record
test_sink_applies_exactly_once
test_sink_store_is_group_readable_and_writable_by_nobody_else
test_broker_reads_the_store_without_being_able_to_write_it
