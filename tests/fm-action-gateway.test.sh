#!/usr/bin/env bash
# Behavior tests for bin/fm-action-gateway.sh broker:
# schema, digest binding, state machine, ceilings, replay/expiry, no outward exec.
set -u

# shellcheck source=tests/lib.sh disable=SC1091
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

GW_SH="$ROOT/bin/fm-action-gateway.sh"
TMP=$(fm_test_tmproot fm-action-gateway)
HOME_DIR="$TMP/home"
DATA_DIR="$HOME_DIR/data"
AUDIT="$DATA_DIR/action-audit.log"
mkdir -p "$DATA_DIR"

# Fixed future expiry so prepare/approve stay valid unless a test overrides now.
EXPIRY=1893456000

valid_request() {
  local kind=${1:-purchase}
  local tier=${2:-autonomous}
  local amount_json=${3:-'"amount_cents": 100,'}
  local idem=${4:-idem-gw-1}
  local nonce=${5:-nonce-gw-1}
  cat <<JSON
{
  "task_id": "task-gw-1",
  "domain": "travel",
  "action_kind": "$kind",
  "target": "https://airline.example/checkout",
  "parameters": { ${amount_json} "currency": "EUR" },
  "requested_consent_tier": "$tier",
  "environment": "prod",
  "policy_version": "1",
  "idempotency_key": "$idem",
  "expires_at": $EXPIRY,
  "nonce": "$nonce"
}
JSON
}

messaging_request() {
  cat <<JSON
{
  "task_id": "task-msg-1",
  "domain": "music-outreach",
  "action_kind": "email.send",
  "target": "smtp://mail.example",
  "parameters": { "recipient": "artist@example.com", "subject": "hello" },
  "requested_consent_tier": "autonomous",
  "environment": "prod",
  "policy_version": "1",
  "idempotency_key": "idem-msg-1",
  "expires_at": $EXPIRY,
  "nonce": "nonce-msg-1"
}
JSON
}

run_gw() {
  FM_HOME="$HOME_DIR" \
  FM_DATA_OVERRIDE="$DATA_DIR" \
  FM_ACTION_AUDIT_LOG="$AUDIT" \
    "$GW_SH" "$@"
}

kv_get() {
  local blob=$1 key=$2
  printf '%s\n' "$blob" | awk -F= -v k="$key" '$1==k {print substr($0,index($0,"=")+1); exit}'
}

test_help_exits_zero() {
  local out rc
  set +e
  out=$("$GW_SH" --help 2>&1)
  rc=$?
  set -e
  expect_code 0 "$rc" "--help exit"
  assert_contains "$out" 'fm-action-gateway.sh' "--help usage"
  assert_contains "$out" 'docs/action-gateway.md' "--help docs pointer"
  pass "fm-action-gateway --help exits 0"
}

test_schema_rejects_missing_and_bad_fields() {
  local out rc
  rm -f "$AUDIT"
  set +e
  out=$(printf '%s' '{"task_id":"x"}' | run_gw prepare 2>&1)
  rc=$?
  set -e
  expect_code 1 "$rc" "missing fields exit"
  assert_contains "$out" 'missing fields' "missing fields message"
  [ ! -f "$AUDIT" ] || [ ! -s "$AUDIT" ] || fail "invalid request must not append audit"

  set +e
  out=$(printf '%s' '{"task_id":"../x","domain":"d","action_kind":"k","target":"t","parameters":{},"requested_consent_tier":"confirm-first","environment":"e","policy_version":"1","idempotency_key":"i","expires_at":'"$EXPIRY"',"nonce":"n"}' | run_gw 2>&1)
  rc=$?
  set -e
  expect_code 1 "$rc" "bad task_id exit"

  set +e
  out=$(printf '%s' '{"task_id":"ok","domain":"d","action_kind":"k","target":"t","parameters":[],"requested_consent_tier":"confirm-first","environment":"e","policy_version":"1","idempotency_key":"i","expires_at":'"$EXPIRY"',"nonce":"n"}' | run_gw 2>&1)
  rc=$?
  set -e
  expect_code 1 "$rc" "parameters must be object"

  set +e
  out=$(printf '%s' '{"task_id":"ok","domain":"d","action_kind":"k","target":"t","parameters":{},"requested_consent_tier":"yolo","environment":"e","policy_version":"1","idempotency_key":"i","expires_at":'"$EXPIRY"',"nonce":"n","extra":1}' | run_gw 2>&1)
  rc=$?
  set -e
  expect_code 1 "$rc" "bad tier / unknown field"
  pass "schema validation rejects incomplete and malformed ActionRequests"
}

test_prepare_state_machine_confirm_first_and_ceiling() {
  local out rc digest token line
  rm -f "$AUDIT"
  set +e
  out=$(valid_request purchase autonomous | run_gw prepare 2>&1)
  rc=$?
  set -e
  expect_code 0 "$rc" "prepare exit"
  assert_contains "$out" 'decision=confirm-first' "ceiling forces confirm-first"
  assert_contains "$out" 'state=prepared' "prepared state"
  assert_contains "$out" 'ceiling=spend' "spend ceiling recorded"
  assert_not_contains "$out" 'decision=autonomous' "autonomous tier cannot raise spend floor"
  digest=$(kv_get "$out" digest)
  token=$(kv_get "$out" approval_token)
  [ -n "$digest" ] || fail "digest required"
  [ -n "$token" ] || fail "approval_token required"
  [ "${#digest}" -eq 64 ] || fail "digest must be sha256 hex"
  line=$(tail -n1 "$AUDIT")
  assert_contains "$line" '"event":"prepared"' "audit prepared event"
  assert_contains "$line" '"state":"prepared"' "audit prepared state"
  assert_contains "$line" '"execution":"stubbed"' "audit marks execution stubbed"
  pass "prepare records prepared + spend ceiling + confirm-first"
}

test_digest_binding_refuses_swap_and_bad_token() {
  local out rc digest token other_digest
  rm -f "$AUDIT"
  out=$(valid_request purchase confirm-first '"amount_cents": 100,' idem-bind-1 nonce-a | run_gw prepare 2>&1)
  digest=$(kv_get "$out" digest)
  token=$(kv_get "$out" approval_token)

  # Second prepare with swapped amount => different digest.
  out=$(valid_request purchase confirm-first '"amount_cents": 99999,' idem-bind-2 nonce-b | run_gw prepare 2>&1)
  other_digest=$(kv_get "$out" digest)
  [ "$digest" != "$other_digest" ] || fail "amount change must change digest"

  # Approve first digest with second request's token must fail.
  set +e
  out=$(run_gw approve --digest "$digest" --token "$(kv_get "$out" approval_token)" 2>&1)
  rc=$?
  set -e
  expect_code 1 "$rc" "cross-digest token refused"
  assert_contains "$out" 'token does not bind' "digest-bound refusal"

  # Approve with wrong digest (second) using first token refused.
  set +e
  out=$(run_gw approve --digest "$other_digest" --token "$token" 2>&1)
  rc=$?
  set -e
  expect_code 1 "$rc" "token/digest mismatch refused"

  # Correct binding succeeds.
  set +e
  out=$(run_gw approve --digest "$digest" --token "$token" 2>&1)
  rc=$?
  set -e
  expect_code 0 "$rc" "matching digest+token approve"
  assert_contains "$out" 'state=approved' "approved state"
  pass "approval binds to exact digest; swaps and bad tokens refused"
}

test_token_replay_and_expiry_refused() {
  local out rc digest token
  rm -f "$AUDIT"
  out=$(valid_request http.request confirm-first '' idem-exp-1 nonce-exp | run_gw prepare 2>&1)
  digest=$(kv_get "$out" digest)
  token=$(kv_get "$out" approval_token)

  out=$(run_gw approve --digest "$digest" --token "$token" 2>&1)
  assert_contains "$out" 'state=approved' "first approve ok"

  set +e
  out=$(run_gw approve --digest "$digest" --token "$token" 2>&1)
  rc=$?
  set -e
  expect_code 1 "$rc" "token replay exit"
  assert_contains "$out" 'already consumed' "replay refused"

  # Fresh prepare then approve after expiry.
  rm -f "$AUDIT"
  out=$(valid_request http.request confirm-first '' idem-exp-2 nonce-exp2 | run_gw prepare 2>&1)
  digest=$(kv_get "$out" digest)
  token=$(kv_get "$out" approval_token)
  set +e
  out=$(
    FM_HOME="$HOME_DIR" FM_DATA_OVERRIDE="$DATA_DIR" FM_ACTION_AUDIT_LOG="$AUDIT" \
      FM_ACTION_GATEWAY_NOW=$((EXPIRY + 10)) \
      "$GW_SH" approve --digest "$digest" --token "$token" 2>&1
  )
  rc=$?
  set -e
  expect_code 1 "$rc" "expired approve exit"
  assert_contains "$out" 'expired' "expiry refusal"
  pass "replayed and expired approvals are refused"
}

test_state_transitions_execute_stub_to_unknown() {
  local out rc digest token count
  rm -f "$AUDIT"
  out=$(valid_request http.request confirm-first '' idem-exec-1 nonce-exec | run_gw prepare 2>&1)
  digest=$(kv_get "$out" digest)
  token=$(kv_get "$out" approval_token)

  set +e
  out=$(run_gw execute --digest "$digest" 2>&1)
  rc=$?
  set -e
  expect_code 1 "$rc" "execute before approve refused"
  assert_contains "$out" 'requires approved' "must be approved first"

  out=$(run_gw approve --digest "$digest" --token "$token" 2>&1)
  assert_contains "$out" 'state=approved' "approved"

  out=$(run_gw execute --digest "$digest" 2>&1)
  assert_contains "$out" 'state=unknown' "stub ends unknown"
  assert_contains "$out" 'execution-not-wired' "explicit stub reason"
  out=$(run_gw status --digest "$digest" 2>&1)
  assert_contains "$out" 'state=unknown' "status shows unknown"
  count=$(grep -c '"event":"executing"' "$AUDIT" || true)
  [ "$count" -eq 1 ] || fail "expected one executing event"
  count=$(grep -c '"event":"unknown"' "$AUDIT" || true)
  [ "$count" -ge 1 ] || fail "expected unknown terminal event"
  pass "state machine prepared->approved->executing->unknown (stub)"
}

test_messaging_ceiling_non_graduatable() {
  local out
  rm -f "$AUDIT"
  out=$(messaging_request | run_gw prepare 2>&1)
  assert_contains "$out" 'decision=confirm-first' "messaging confirm-first"
  assert_contains "$out" 'ceiling=messaging' "messaging ceiling"
  assert_not_contains "$out" 'decision=autonomous' "tier cannot raise messaging floor"
  pass "messaging hard ceiling stays confirm-first"
}

test_crash_replay_defaults_to_confirm_first() {
  local out digest token
  rm -f "$AUDIT"
  out=$(valid_request http.request confirm-first '' idem-crash-1 nonce-crash | run_gw prepare 2>&1)
  digest=$(kv_get "$out" digest)
  token=$(kv_get "$out" approval_token)
  out=$(run_gw approve --digest "$digest" --token "$token" 2>&1)
  assert_contains "$out" 'state=approved' "approved before simulated crash"

  # Simulate crash mid-execute: append executing without terminal.
  python3 -c '
import json, os, sys
path = sys.argv[1]
digest = sys.argv[2]
line = json.dumps({
  "ts": 1,
  "event": "executing",
  "state": "executing",
  "digest": digest,
  "request_id": "crash-sim",
  "decision": "confirm-first",
  "execution": "stubbed",
}, separators=(",", ":"), sort_keys=True) + "\n"
with open(path, "a", encoding="utf-8") as fh:
    fh.write(line)
' "$AUDIT" "$digest"

  out=$(run_gw status --digest "$digest" 2>&1)
  assert_contains "$out" 'state=unknown' "replay views executing as unknown"
  assert_contains "$out" 'decision=confirm-first' "posture confirm-first"

  out=$(run_gw replay 2>&1)
  assert_contains "$out" 'decision=confirm-first' "replay decision"
  assert_contains "$out" 'crash_unknown_recovered=1' "persisted recovery"
  out=$(run_gw status --digest "$digest" 2>&1)
  assert_contains "$out" 'state=unknown' "persisted unknown after replay"
  pass "crash replay defaults to confirm-first and recovers executing"
}

test_idempotency_key_conflict() {
  local out rc
  rm -f "$AUDIT"
  valid_request purchase confirm-first '"amount_cents": 100,' idem-same nonce-1 | run_gw prepare >/dev/null
  set +e
  out=$(valid_request purchase confirm-first '"amount_cents": 200,' idem-same nonce-2 | run_gw prepare 2>&1)
  rc=$?
  set -e
  expect_code 1 "$rc" "idempotency conflict exit"
  assert_contains "$out" 'idempotency_key reuse with differing digest' "conflict message"
  pass "idempotency key reuse with differing digest is refused"
}

test_file_input_and_second_prepare() {
  local req out rc count
  rm -f "$AUDIT"
  req="$TMP/req.json"
  valid_request purchase confirm-first '"amount_cents": 50,' idem-file-1 nonce-file | cat > "$req"
  set +e
  out=$(run_gw --file "$req" 2>&1)
  rc=$?
  set -e
  expect_code 0 "$rc" "--file exit"
  assert_contains "$out" 'decision=confirm-first' "--file decision"
  assert_contains "$out" 'state=prepared' "--file state"
  count=$(wc -l < "$AUDIT" | tr -d ' ')
  [ "$count" -ge 1 ] || fail "expected audit line after --file prepare"
  pass "--file input prepares with durable audit line"
}

test_audit_failure_yields_no_decision() {
  local out rc blocked
  blocked="$TMP/blocked-audit"
  mkdir -p "$blocked"
  set +e
  out=$(
    valid_request | FM_HOME="$HOME_DIR" FM_DATA_OVERRIDE="$DATA_DIR" \
      FM_ACTION_AUDIT_LOG="$blocked" "$GW_SH" prepare 2>&1
  )
  rc=$?
  set -e
  expect_code 1 "$rc" "audit failure exit"
  assert_not_contains "$out" 'decision=' "no decision when audit path is unusable"
  pass "failed audit write emits no decision"
}

test_no_outward_effect_codepaths() {
  local hits out digest token
  # Static: broker source must not grow real egress primitives.
  set +e
  hits=$(
    # Strip the embedded policy kind strings / docs pointers; scan for call-like use.
    grep -E \
      -e '\bcurl\b' -e '\bwget\b' -e '\bnc\b' -e '\bopenssl\s+s_client\b' \
      -e 'urllib\.request' -e 'http\.client' -e 'smtplib' -e 'socket\.create_connection' \
      -e 'subprocess\.' -e 'os\.system' -e 'requests\.' \
      "$GW_SH" || true
  )
  set -e
  [ -z "$hits" ] || fail "gateway source must not call outward effect primitives: $hits"

  rm -f "$AUDIT"
  out=$(valid_request http.request confirm-first '' idem-noeff-1 nonce-noeff | run_gw prepare 2>&1)
  digest=$(kv_get "$out" digest)
  token=$(kv_get "$out" approval_token)
  run_gw approve --digest "$digest" --token "$token" >/dev/null
  out=$(run_gw execute --digest "$digest" 2>&1)
  assert_contains "$out" 'execution-not-wired' "execute is stub"
  # Dynamic: only the audit log under DATA_DIR should change; no network sidecars.
  find "$TMP" -type f ! -path "$AUDIT" ! -path "$TMP/req.json" 2>/dev/null \
    | grep -E 'mail|smtp|http-out|payment|egress' \
    && fail "unexpected egress artifact under temp root" || true
  pass "no code path performs a real outward effect"
}

test_help_exits_zero
test_schema_rejects_missing_and_bad_fields
test_prepare_state_machine_confirm_first_and_ceiling
test_digest_binding_refuses_swap_and_bad_token
test_token_replay_and_expiry_refused
test_state_transitions_execute_stub_to_unknown
test_messaging_ceiling_non_graduatable
test_crash_replay_defaults_to_confirm_first
test_idempotency_key_conflict
test_file_input_and_second_prepare
test_audit_failure_yields_no_decision
test_no_outward_effect_codepaths
