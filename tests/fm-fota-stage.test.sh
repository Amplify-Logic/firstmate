#!/usr/bin/env bash
# Behavior tests for bin/fm-fota-stage.py: encoding discipline, operation
# identity, eligibility honesty, and the guarantee that staging never sends.
set -u

# shellcheck source=tests/lib.sh disable=SC1091
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

STAGE="$ROOT/bin/fm-fota-stage.py"
ADAPTER="$ROOT/tests/fixtures/staging-portal/adapter.json"
TMP=$(fm_test_tmproot fm-fota-stage)

# A request body. Defaults stage a valid ordered pair on an eligible-prefix id.
request() {
  local attempt=${1:-1}
  local lower=${2:-3.5}
  local upper=${3:-4.0}
  local device=${4:-1234567000111}
  local extra=${5:-}
  cat <<JSON
{
  "action_kind": "device.config.stage",
  "device_id": "$device",
  "environment": "prod",
  "attempt": $attempt,
  "settings": [
    { "name": "band_lower", "value": $lower },
    { "name": "band_upper", "value": $upper }
  ]$extra
}
JSON
}

stage() {  # stage <request-json> -> plan on stdout
  local body=$1 file="$TMP/req.$$.json"
  printf '%s\n' "$body" > "$file"
  "$STAGE" --adapter "$ADAPTER" --request "$file" 2>&1
}

field() {  # field <plan-json> <python-expression over p>
  printf '%s' "$1" | python3 -c "
import json,sys
p=json.load(sys.stdin)
print($2)
"
}

test_encodes_through_the_declared_rule() {
  local plan
  plan=$(stage "$(request)")
  # 3.5 C and 4.0 C under a 100-plus-tenths rule are 135 and 140. Read as plain
  # tenths they would be 35 and 40 - a different band entirely, which is why the
  # rule that produced each number travels with it.
  assert_contains "$plan" '"wire_value": 135' "lower bound encodes through the declared rule"
  assert_contains "$plan" '"wire_value": 140' "upper bound encodes through the declared rule"
  assert_contains "$plan" '"encoding": "offset100_tenths_c"' "each value names its encoding"
  pass "values encode through the declared rule and carry its name"
}

test_payload_matches_the_declared_wire_format() {
  local plan payload
  plan=$(stage "$(request)")
  payload=$(field "$plan" "p['payload']")
  [ "$payload" = '[{"n": "band_lower", "v": 135},{"n": "band_upper", "v": 140}]' ] \
    || fail "payload not in the declared wire format: $payload"
  pass "payload renders in the adapter's declared wire format"
}

test_measurement_and_setting_rules_do_not_mix() {
  local plan
  plan=$(stage "$(request 1 3.5 4.0 1234567000111 ',
  "telemetry": [ { "name": "band_lower", "available": true, "raw": 44,
                   "encoding": "plain_tenths_c", "observed_at": "2026-09-12T13:52:00Z" } ]')")
  # Same plan, same device: a setting decodes by one rule (135 -> 3.5) while a
  # reported measurement decodes by another (44 -> 4.4). Decoding that 44 with
  # the setting rule would yield -5.6, so the split is per key, not per device.
  assert_contains "$plan" '"decoded": 4.4' "measurement decodes by its own rule"
  assert_contains "$plan" '"wire_value": 135' "setting still decodes by the setting rule"
  pass "a measurement and a setting use separate rules on one device"
}

test_encodings_validate_rather_than_coerce() {
  local out rc
  # float(True) is 1.0, which under a tenths rule reads back as a perfectly
  # plausible 1.0 C band bound synthesised out of a flag. A number is required.
  set +e
  out=$(stage '{"action_kind":"device.config.stage","device_id":"1234567000111",
    "environment":"prod","attempt":1,
    "settings":[{"name":"band_lower","value":true}]}')
  rc=$?
  set -e
  expect_code 1 "$rc" "boolean into a numeric encoding exit"
  assert_contains "$out" "takes a number" "the refusal names the contract"
  assert_not_contains "$out" '"wire_value": 110' "no number is synthesised from a flag"

  set +e
  out=$(stage '{"action_kind":"device.config.stage","device_id":"1234567000111",
    "environment":"prod","attempt":1,
    "settings":[{"name":"band_lower","value":"3.5"}]}')
  rc=$?
  set -e
  expect_code 1 "$rc" "string into a numeric encoding exit"
  assert_contains "$out" "takes a number" "a numeric-looking string is still not a number"

  # The same discipline in the other direction: the string "false" is truthy.
  set +e
  out=$(stage '{"action_kind":"device.config.stage","device_id":"1234567000111",
    "environment":"prod","attempt":1,
    "settings":[{"name":"feature_flag","value":"false"}]}')
  rc=$?
  set -e
  expect_code 1 "$rc" "string into a boolean encoding exit"
  assert_contains "$out" "takes true or false" "the boolean refusal names the contract"
  pass "encodings validate in both directions rather than coercing"
}

test_a_telemetry_row_without_a_usable_value_is_unavailable_not_a_crash() {
  local plan
  # A row claiming availability with no raw value at all.
  plan=$(stage "$(request 1 3.5 4.0 1234567000111 ',
  "telemetry": [ { "name": "band_lower", "available": true,
                   "encoding": "plain_tenths_c" } ]')")
  assert_not_contains "$plan" 'Traceback' "an incidental telemetry defect is not a traceback"
  assert_contains "$plan" '"available": false' "it becomes the third state"
  assert_contains "$plan" '"decoded": null' "nothing is decoded from nothing"
  assert_contains "$plan" 'no raw value' "the plan says why it is unusable"

  # A row whose raw value is not a number.
  plan=$(stage "$(request 1 3.5 4.0 1234567000111 ',
  "telemetry": [ { "name": "band_lower", "available": true, "raw": "n/a",
                   "encoding": "plain_tenths_c" } ]')")
  assert_not_contains "$plan" 'Traceback' "a non-numeric raw is not a traceback"
  assert_contains "$plan" '"available": false' "a non-numeric raw is unavailable"
  # And the staged setting is still correctly reported as not read.
  assert_contains "$plan" "Current values were not read for: band_lower, band_upper" \
    "an unusable row never counts as coverage"
  pass "a telemetry row without a usable value is unavailable, never a traceback"
}

test_an_undeclared_telemetry_encoding_is_unavailable_not_a_reading() {
  local plan out rc
  plan=$(stage "$(request 1 3.5 4.0 1234567000111 ',
  "telemetry": [ { "name": "band_upper", "available": true, "raw": "n/a",
                   "encoding": "made_up_rule",
                   "observed_at": "2026-09-12T13:52:00Z" } ]')")
  # An encoding this tool does not implement decodes to nothing. Left available
  # the row would silence the unknown below, and the plan would imply it knows a
  # current value it never decoded - the same defect a missing raw would cause,
  # so it resolves the same way rather than by a second rule for one field.
  assert_contains "$plan" '"available": false' "an undeclared telemetry encoding is unavailable"
  assert_contains "$plan" '"decoded": null' "nothing is decoded through a rule that does not exist"
  assert_contains "$plan" 'does not implement' "the plan names why the row is unusable"
  assert_contains "$plan" '"observed_at": null' "no age is carried for a row that read nothing"
  assert_contains "$plan" "Current values were not read for: band_lower, band_upper" \
    "an undecodable row never silences the unread-values unknown"

  # The same encoding name on the SETTINGS path stays a strict refusal: that
  # number would be staged into a device command, so a wrong rule is worse than
  # no rule. The asymmetry is deliberate and pinned here.
  set +e
  out=$(STAGE="$STAGE" ADAPTER="$ADAPTER" TMP="$TMP" python3 - <<'PY'
import json, os, subprocess, sys

tmp = os.environ["TMP"]
adapter = json.load(open(os.environ["ADAPTER"], encoding="utf-8"))
adapter["settings"]["band_upper"]["encoding"] = "made_up_rule"
adapter_path = os.path.join(tmp, "undeclared-encoding-adapter.json")
with open(adapter_path, "w", encoding="utf-8") as handle:
    json.dump(adapter, handle)

request_path = os.path.join(tmp, "undeclared-encoding-request.json")
with open(request_path, "w", encoding="utf-8") as handle:
    json.dump(
        {
            "action_kind": "device.config.stage",
            "device_id": "1234567000111",
            "environment": "prod",
            "attempt": 1,
            "settings": [{"name": "band_upper", "value": 4.0}],
        },
        handle,
    )

done = subprocess.run(
    [os.environ["STAGE"], "--adapter", adapter_path, "--request", request_path],
    capture_output=True, text=True,
)
sys.stdout.write(done.stdout + done.stderr)
sys.exit(done.returncode)
PY
)
  rc=$?
  set -e
  expect_code 1 "$rc" "undeclared setting encoding exit"
  assert_contains "$out" "unknown encoding" "the settings refusal names the undeclared rule"
  assert_not_contains "$out" '"wire_value"' "no number is staged through an unimplemented rule"
  pass "an undeclared telemetry encoding is unavailable, while a setting still refuses"
}

test_the_payload_is_serialised_not_interpolated() {
  local out
  # An adapter whose declared name key carries a quote and a backslash. Rendered
  # by interpolation this emits broken JSON that the run's readback comparison
  # can no longer parse - a good preparation settling unknown for no reason.
  out=$(STAGE="$STAGE" ADAPTER="$ADAPTER" TMP="$TMP" python3 - <<'PY'
import json, os, subprocess, sys

tmp = os.environ["TMP"]
adapter = json.load(open(os.environ["ADAPTER"], encoding="utf-8"))
adapter["command_format"]["name_key"] = 'n"\\x'
adapter_path = os.path.join(tmp, "quoting-adapter.json")
with open(adapter_path, "w", encoding="utf-8") as handle:
    json.dump(adapter, handle)

request_path = os.path.join(tmp, "quoting-request.json")
with open(request_path, "w", encoding="utf-8") as handle:
    json.dump(
        {
            "action_kind": "device.config.stage",
            "device_id": "1234567000111",
            "environment": "prod",
            "attempt": 1,
            "settings": [{"name": "band_lower", "value": 3.5}],
        },
        handle,
    )

done = subprocess.run(
    [os.environ["STAGE"], "--adapter", adapter_path, "--request", request_path],
    capture_output=True, text=True,
)
if done.returncode != 0:
    sys.exit("stage failed: %s" % (done.stderr or done.stdout))
payload = json.loads(done.stdout)["payload"]
rows = json.loads(payload)
assert rows == [{'n"\\x': "band_lower", "v": 135}], rows
print("payload parses: %s" % payload)
PY
) || fail "the payload did not survive a quoted adapter key: $out"
  pass "the payload escapes correctly by construction, whatever the adapter names"
}

test_unconfirmed_encoding_is_refused() {
  local out rc
  set +e
  out=$(stage '{"action_kind":"device.config.stage","device_id":"1234567000111",
    "environment":"prod","attempt":1,
    "settings":[{"name":"unconfirmed_setting","value":3.5}]}')
  rc=$?
  set -e
  expect_code 1 "$rc" "unconfirmed encoding exit"
  assert_contains "$out" "not confirmed" "refusal names the unconfirmed encoding"
  pass "a declared but unconfirmed encoding is refused, not guessed"
}

test_undeclared_setting_is_refused() {
  local out rc
  set +e
  out=$(stage '{"action_kind":"device.config.stage","device_id":"1234567000111",
    "environment":"prod","attempt":1,
    "settings":[{"name":"invented_setting","value":1}]}')
  rc=$?
  set -e
  expect_code 1 "$rc" "undeclared setting exit"
  assert_contains "$out" "not declared" "refusal names the undeclared setting"
  pass "an undeclared setting is refused"
}

test_ordered_pair_violation_is_refused() {
  local out rc
  set +e
  out=$(stage "$(request 1 4.5 4.0)")
  rc=$?
  set -e
  expect_code 1 "$rc" "inverted band exit"
  assert_contains "$out" "must be below" "refusal explains the ordering"
  pass "an inverted ordered pair is refused"
}

test_same_operation_yields_the_same_identity() {
  local a b
  a=$(field "$(stage "$(request)")" "p['operation']['idempotency_key']")
  b=$(field "$(stage "$(request)")" "p['operation']['idempotency_key']")
  # The whole point of correction 3: re-preparing one real operation must be
  # recognisable as the same operation, so a repeated click cannot become a
  # second device command.
  [ "$a" = "$b" ] || fail "same operation produced different identities: $a vs $b"
  pass "re-preparing the same operation yields the same identity"
}

test_different_values_and_attempts_are_different_identities() {
  local base other retry
  base=$(field "$(stage "$(request)")" "p['operation']['idempotency_key']")
  other=$(field "$(stage "$(request 1 3.0 4.0)")" "p['operation']['idempotency_key']")
  retry=$(field "$(stage "$(request 2)")" "p['operation']['idempotency_key']")
  [ "$base" != "$other" ] || fail "a different band reused an identity"
  [ "$base" != "$retry" ] || fail "a deliberate retry reused an identity"
  assert_contains "$retry" "attempt-2" "the retry ordinal is visible in the key"
  pass "changed values and deliberate retries get distinct, visible identities"
}

test_eligibility_is_unverified_without_observed_rows() {
  local plan
  plan=$(stage "$(request)")
  assert_contains "$plan" '"state": "unverified"' "eligibility unverified by default"
  # A matching model prefix must not be reported as sufficient.
  assert_contains "$plan" '"prefix_necessary_condition": true' "prefix recorded as necessary only"
  pass "a matching prefix alone leaves eligibility unverified"
}

test_observed_rows_decide_eligibility_both_ways() {
  local ok bad
  ok=$(stage "$(request 1 3.5 4.0 1234567000111 ',
    "observed_settings": ["band_lower", "band_upper"]')")
  assert_contains "$ok" '"state": "verified"' "observed rows verify eligibility"
  bad=$(stage "$(request 1 3.5 4.0 1234567000111 ',
    "observed_settings": ["band_lower"]')")
  assert_contains "$bad" '"state": "ineligible"' "a missing row makes the target ineligible"
  assert_contains "$bad" 'band_upper' "the refusal names the missing row"
  pass "eligibility follows observed rows, in both directions"
}

test_unread_current_values_are_named_not_implied() {
  local plan
  plan=$(stage "$(request 1 3.5 4.0 1234567000111 ',
  "telemetry": [ { "name": "some_other_field", "available": true, "raw": 44,
                   "encoding": "plain_tenths_c", "observed_at": "2026-09-12T13:52:00Z" } ]')")
  # A reading for an unrelated field must not be counted as coverage of the
  # settings being staged, or the preview implies a current state it never read.
  assert_contains "$plan" "Current values were not read for: band_lower, band_upper" \
    "unread staged settings are named"
  pass "a reading elsewhere is not treated as knowing the staged values"
}

test_unavailable_telemetry_is_never_rendered_as_a_reading() {
  local plan
  plan=$(stage "$(request 1 3.5 4.0 1234567000111 ',
  "telemetry": [ { "name": "band_lower", "available": false } ]')")
  assert_contains "$plan" '"available": false' "unavailable stays unavailable"
  assert_contains "$plan" '"raw": null' "no value is invented for it"
  assert_contains "$plan" '"observed_at": null' "no age is invented for it"
  pass "unavailable telemetry is a third state, not a reading"
}

test_plan_makes_no_safety_claim_and_never_sends() {
  local plan
  plan=$(stage "$(request)")
  assert_contains "$plan" '"claimed": false' "no physical-safety claim"
  assert_contains "$plan" '"performed": false' "nothing was sent"
  assert_contains "$plan" '"authorized": false' "sending is not authorized here"
  assert_contains "$plan" '"verified_against_page": false' "target not yet verified against a page"
  pass "a plan claims no safety, sends nothing, and says the target is unverified"
}

test_preview_hash_binds_the_exact_preview() {
  local base same changed
  base=$(field "$(stage "$(request)")" "p['preview_hash']")
  same=$(field "$(stage "$(request)")" "p['preview_hash']")
  changed=$(field "$(stage "$(request 1 3.0 4.0)")" "p['preview_hash']")
  [ "$base" = "$same" ] || fail "identical previews hashed differently"
  [ "$base" != "$changed" ] || fail "a changed value did not change the preview hash"
  pass "the preview hash binds the exact staged preview"
}

test_the_permitted_origin_is_staged_and_validated() {
  local plan origin hashed out rc
  plan=$(stage "$(request)")
  origin=$(field "$plan" "p['adapter']['origin']")
  # The fixture adapter's invented origin, carried through as immutable
  # preparation data rather than left for a later step to re-derive.
  [ "$origin" = "https://portal.example.invalid" ] \
    || fail "the adapter's declared origin did not reach the plan: $origin"
  # And it is inside the preview the approval hash binds, so it cannot be
  # swapped after the fact without changing the hash the captain approved.
  hashed=$(field "$plan" "p['preview_hash']")
  [ -n "$hashed" ] || fail "no preview hash was produced"

  # Every unresolvable or malformed shape is a refusal. None of them may fall
  # back to a permissive default, and a wildcard is never an allowlist.
  local bad
  for bad in '__MISSING__' '' '*' 'https://*.example.invalid' 'example.invalid' \
             'https://portal.example.invalid/devices' 'not an origin at all'; do
    set +e
    out=$(STAGE="$STAGE" ADAPTER="$ADAPTER" TMP="$TMP" BAD="$bad" python3 - <<'PY'
import json, os, subprocess, sys

tmp = os.environ["TMP"]
adapter = json.load(open(os.environ["ADAPTER"], encoding="utf-8"))
if os.environ["BAD"] == "__MISSING__":
    adapter["portal"].pop("origin", None)
else:
    adapter["portal"]["origin"] = os.environ["BAD"]
adapter_path = os.path.join(tmp, "origin-adapter.json")
with open(adapter_path, "w", encoding="utf-8") as handle:
    json.dump(adapter, handle)

request_path = os.path.join(tmp, "origin-request.json")
with open(request_path, "w", encoding="utf-8") as handle:
    json.dump(
        {
            "action_kind": "device.config.stage",
            "device_id": "1234567000111",
            "environment": "prod",
            "attempt": 1,
            "settings": [{"name": "band_lower", "value": 3.5}],
        },
        handle,
    )

done = subprocess.run(
    [os.environ["STAGE"], "--adapter", adapter_path, "--request", request_path],
    capture_output=True, text=True,
)
sys.stdout.write(done.stdout + done.stderr)
sys.exit(done.returncode)
PY
)
    rc=$?
    set -e
    expect_code 1 "$rc" "origin [$bad] refusal exit"
    assert_contains "$out" "origin" "the refusal names the origin [$bad]"
    assert_not_contains "$out" '"preview_hash"' "no plan is produced for origin [$bad]"
  done
  pass "the permitted origin is staged from the adapter, or the preparation refuses"
}

test_no_outward_effect_codepaths() {
  local hits
  set +e
  hits=$(grep -E -e '\burllib\b' -e 'http\.client' -e 'socket\.' -e 'subprocess' \
    -e 'os\.system' -e 'requests\.' -e '\bcurl\b' "$STAGE" || true)
  set -e
  [ -z "$hits" ] || fail "the preparer must not reach outward: $hits"
  pass "the preparer has no outward-effect code path"
}

test_attempt_ordinal_is_required() {
  local out rc
  set +e
  out=$(stage '{"action_kind":"device.config.stage","device_id":"1234567000111",
    "environment":"prod","settings":[{"name":"band_lower","value":3.5}]}')
  rc=$?
  set -e
  expect_code 1 "$rc" "missing attempt exit"
  assert_contains "$out" "attempt" "refusal names the missing ordinal"
  pass "operation identity refuses to form without an attempt ordinal"
}

test_encodes_through_the_declared_rule
test_payload_matches_the_declared_wire_format
test_encodings_validate_rather_than_coerce
test_a_telemetry_row_without_a_usable_value_is_unavailable_not_a_crash
test_an_undeclared_telemetry_encoding_is_unavailable_not_a_reading
test_the_payload_is_serialised_not_interpolated
test_measurement_and_setting_rules_do_not_mix
test_unconfirmed_encoding_is_refused
test_undeclared_setting_is_refused
test_ordered_pair_violation_is_refused
test_same_operation_yields_the_same_identity
test_different_values_and_attempts_are_different_identities
test_eligibility_is_unverified_without_observed_rows
test_observed_rows_decide_eligibility_both_ways
test_unread_current_values_are_named_not_implied
test_unavailable_telemetry_is_never_rendered_as_a_reading
test_plan_makes_no_safety_claim_and_never_sends
test_preview_hash_binds_the_exact_preview
test_the_permitted_origin_is_staged_and_validated
test_no_outward_effect_codepaths
test_attempt_ordinal_is_required
