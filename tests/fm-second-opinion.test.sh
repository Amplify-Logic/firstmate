#!/usr/bin/env bash
# Behavior tests for bin/fm-second-opinion.sh: rival-model second-opinion wrapper.
#
# Covers happy-path --out header writes for the default fable reviewer and the
# grok and sol reviewers, the hostile-review prompt reaching the reviewer,
# neutral-cwd enforcement, unknown reviewer refusal, per-reviewer quota floors
# plus FM_SECOND_OPINION_FORCE override, grok's refusal on an unavailable
# reading, ambient API-key stripping, and empty reviewer output as a loud
# failure. Every reviewer binary is stubbed so the suite never spends a real
# model run.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

SO_SH="$ROOT/bin/fm-second-opinion.sh"
TMP=$(fm_test_tmproot fm-second-opinion)
BASE_PATH=${FM_TEST_BASE_PATH:-/usr/bin:/bin:/usr/sbin:/sbin}

# write_quota_fixture <path> <codex five_hour> <claude model:fable>
#   <claude seven_day> <cursor included_usage>
# Pass "-" to omit a window. Cursor api_usage is always 90 and Claude five_hour
# always 1, so a reviewer reading the wrong window is caught.
write_quota_fixture() {
  local path=$1 codex=$2 fable=$3 week=$4 included=$5
  local codex_w='' claude_w='' cursor_w=''
  [ "$codex" = - ] || codex_w=$(printf '{"id":"five_hour","kind":"session","percentRemaining":%s},{"id":"model:sol","kind":"model","percentRemaining":1}' "$codex")
  claude_w='{"id":"five_hour","kind":"session","percentRemaining":1}'
  [ "$fable" = - ] || claude_w+=$(printf ',{"id":"model:fable","kind":"model","percentRemaining":%s}' "$fable")
  [ "$week" = - ] || claude_w+=$(printf ',{"id":"seven_day","kind":"weekly","percentRemaining":%s}' "$week")
  cursor_w='{"id":"api_usage","kind":"monthly","percentRemaining":90}'
  [ "$included" = - ] || cursor_w+=$(printf ',{"id":"included_usage","kind":"monthly","percentRemaining":%s}' "$included")
  cat >"$path" <<JSON
{
  "schemaVersion": 2,
  "providers": [
    { "provider": "codex", "windows": [${codex_w}], "state": { "status": "fresh" } },
    { "provider": "claude", "windows": [${claude_w}], "state": { "status": "fresh" } },
    { "provider": "cursor", "windows": [${cursor_w}], "state": { "status": "fresh" } }
  ]
}
JSON
}

# install_reviewer_stub <fakebin> <binary-name> [ok|empty|fail]
install_reviewer_stub() {
  local fakebin=$1 name=$2 mode=${3:-ok}
  cat >"$fakebin/$name" <<SH
#!/usr/bin/env bash
set -u
printf '%s\\n' "\$*" > "\${FM_SECOND_OPINION_TEST_ARGV_LOG:?}"
pwd -P > "\${FM_SECOND_OPINION_CWD_LOG:?}"
if [ -n "\${ANTHROPIC_API_KEY+x}" ] || [ -n "\${OPENAI_API_KEY+x}" ]; then
  printf 'API key was set\\n' >&2
  exit 9
fi
case "${mode}" in
  empty)
    exit 0
    ;;
  fail)
    printf 'stub reviewer refusal\\n' >&2
    exit 3
    ;;
  *)
    printf 'FINDING: CRITICAL - stub finding for: %s\\n' "\$#"
    printf 'hostile review body\\n'
    exit 0
    ;;
esac
SH
  chmod +x "$fakebin/$name"
}

# run_so <dir> <quota-json-or-empty> [extra env assignments...] -- <wrapper args...>
# Runs the wrapper with only the stub fakebin ahead of the base PATH and the
# per-case argv/cwd logs; sets RUN_OUT and RUN_RC.
run_so() {
  local dir=$1 quota=$2
  shift 2
  local envs=()
  while [ "$#" -gt 0 ] && [ "$1" != -- ]; do
    envs+=("$1")
    shift
  done
  shift
  set +e
  RUN_OUT=$(
    env -u FM_SECOND_OPINION_BIN -u FM_SECOND_OPINION_FORCE \
      PATH="$dir/fakebin:$BASE_PATH" \
      FM_SECOND_OPINION_QUOTA_JSON="$quota" \
      FM_SECOND_OPINION_QUOTA_AXI=quota-axi-absent \
      FM_SECOND_OPINION_TEST_ARGV_LOG="$dir/argv.txt" \
      FM_SECOND_OPINION_CWD_LOG="$dir/cwd.txt" \
      "${envs[@]+"${envs[@]}"}" \
      "$SO_SH" "$@" 2>&1
  )
  RUN_RC=$?
  set -e
}

test_help_exits_zero() {
  local out rc
  set +e
  out=$("$SO_SH" --help 2>&1)
  rc=$?
  set -e
  expect_code 0 "$rc" "--help exit"
  assert_contains "$out" 'fm-second-opinion.sh --out' "--help usage"
  assert_contains "$out" 'Default reviewer is fable' "--help names the default reviewer"
  assert_contains "$out" 'docs/second-opinion.md' "--help docs pointer"
  pass "fm-second-opinion --help exits 0"
}

test_default_fable_happy_path() {
  local dir="$TMP/fable"
  fm_fakebin "$dir" >/dev/null
  install_reviewer_stub "$dir/fakebin" claude ok
  write_quota_fixture "$dir/quota.json" 80 89 42 50

  run_so "$dir" "$dir/quota.json" \
    ANTHROPIC_API_KEY=should-be-stripped OPENAI_API_KEY=should-be-stripped -- \
    --out "$dir/out.md" -- "adopt the gateway design"

  expect_code 0 "$RUN_RC" "fable happy-path exit"
  assert_contains "$(cat "$dir/out.md")" '# Second-opinion review' \
    "fable: header present"
  assert_contains "$(cat "$dir/out.md")" 'Reviewer: fable' \
    "fable: default reviewer in header"
  assert_contains "$(cat "$dir/out.md")" 'Subject: adopt the gateway design' \
    "fable: subject in header"
  assert_contains "$(cat "$dir/out.md")" 'hostile review body' \
    "fable: reviewer body written"
  assert_contains "$(cat "$dir/argv.txt")" '-p --model claude-fable-5-1 --effort medium' \
    "fable: claude print mode on Fable at medium effort"
  assert_contains "$(cat "$dir/argv.txt")" '--strict-mcp-config' \
    "fable: user MCP servers excluded"
  assert_contains "$(cat "$dir/argv.txt")" 'You are a hostile design reviewer' \
    "fable: hostile-review prompt passed as argv"
  assert_contains "$(cat "$dir/argv.txt")" 'Check threading, concurrency, timeouts, retries and idempotency explicitly' \
    "fable: concurrency and retry rule reaches the reviewer"
  assert_contains "$RUN_OUT" 'Claude Fable week percentRemaining=42' \
    "fable: advisory reads the lower of model:fable and seven_day, not five_hour"
  assert_not_contains "$RUN_OUT" 'API key was set' \
    "fable: must not pass ambient API keys into claude"
  pass "fm-second-opinion defaults to fable, writes --out, and strips API keys"
}

test_fable_quota_floor() {
  local dir="$TMP/fable-quota"
  fm_fakebin "$dir" >/dev/null
  install_reviewer_stub "$dir/fakebin" claude ok

  write_quota_fixture "$dir/low-model.json" 80 5 60 50
  run_so "$dir" "$dir/low-model.json" -- --out "$dir/out-model.md" -- "low fable slice"
  expect_code 1 "$RUN_RC" "fable: low model:fable refuses"
  assert_contains "$RUN_OUT" 'Claude Fable week percentRemaining 5 is below floor 10' \
    "fable: model:fable floor refusal message"
  assert_absent "$dir/out-model.md" "fable: no --out when refusing on model:fable"

  write_quota_fixture "$dir/low-week.json" 80 70 4 50
  run_so "$dir" "$dir/low-week.json" -- --out "$dir/out-week.md" -- "low claude week"
  expect_code 1 "$RUN_RC" "fable: low seven_day refuses"
  assert_absent "$dir/out-week.md" "fable: no --out when refusing on seven_day"

  run_so "$dir" "$dir/low-week.json" FM_SECOND_OPINION_FORCE=1 -- \
    --out "$dir/out-force.md" -- "low claude week forced"
  expect_code 0 "$RUN_RC" "fable: FORCE overrides the floor"
  assert_contains "$RUN_OUT" 'FM_SECOND_OPINION_FORCE=1' "fable: force advisory"

  write_quota_fixture "$dir/none.json" 80 - - 50
  run_so "$dir" "$dir/none.json" -- --out "$dir/out-na.md" -- "no claude reading"
  expect_code 0 "$RUN_RC" "fable: unavailable reading proceeds"
  assert_contains "$RUN_OUT" 'Claude Fable week reading unavailable; proceeding' \
    "fable: unavailable reading warns"
  pass "fm-second-opinion enforces the Claude Fable floor and proceeds on no reading"
}

test_grok_happy_path_and_floor() {
  local dir="$TMP/grok"
  fm_fakebin "$dir" >/dev/null
  install_reviewer_stub "$dir/fakebin" cursor-agent ok

  write_quota_fixture "$dir/ok.json" 80 89 42 15
  run_so "$dir" "$dir/ok.json" -- --reviewer grok --out "$dir/out.md" -- "pick the schema"
  expect_code 0 "$RUN_RC" "grok happy-path exit"
  assert_contains "$(cat "$dir/out.md")" 'Reviewer: grok' "grok: reviewer in header"
  assert_contains "$(cat "$dir/argv.txt")" '-p --model grok-4.7-xhigh --mode ask --trust' \
    "grok: cursor-agent read-only print invocation"
  assert_contains "$(cat "$dir/argv.txt")" 'Check threading, concurrency' \
    "grok: concurrency and retry rule reaches the reviewer"
  assert_contains "$RUN_OUT" 'Cursor included usage percentRemaining=15' \
    "grok: advisory reads included_usage"

  write_quota_fixture "$dir/low.json" 80 89 42 6
  run_so "$dir" "$dir/low.json" -- --reviewer grok --out "$dir/out-low.md" -- "pool nearly empty"
  expect_code 1 "$RUN_RC" "grok: low included pool refuses despite API balance"
  assert_contains "$RUN_OUT" 'Cursor included usage percentRemaining 6 is below floor 10' \
    "grok: included-pool refusal message"
  assert_absent "$dir/out-low.md" "grok: no --out when refusing"

  run_so "$dir" "$dir/low.json" FM_SECOND_OPINION_FORCE=1 -- \
    --reviewer grok --out "$dir/out-force.md" -- "pool nearly empty forced"
  expect_code 0 "$RUN_RC" "grok: FORCE overrides the floor"
  assert_contains "$(cat "$dir/out-force.md")" 'hostile review body' \
    "grok: forced run writes review"
  pass "fm-second-opinion runs grok on Cursor and refuses below the included-pool floor"
}

test_grok_refuses_unavailable_reading() {
  local dir="$TMP/grok-na"
  fm_fakebin "$dir" >/dev/null
  install_reviewer_stub "$dir/fakebin" cursor-agent ok

  write_quota_fixture "$dir/none.json" 80 89 42 -
  run_so "$dir" "$dir/none.json" -- --reviewer grok --out "$dir/out.md" -- "no included reading"
  expect_code 1 "$RUN_RC" "grok: missing included_usage refuses"
  assert_contains "$RUN_OUT" 'Cursor included usage reading unavailable' \
    "grok: unavailable-reading refusal message"
  assert_absent "$dir/argv.txt" "grok: reviewer never launched without a reading"
  assert_absent "$dir/out.md" "grok: no --out without a reading"

  run_so "$dir" "" -- --reviewer grok --out "$dir/out-tool.md" -- "no quota tooling"
  expect_code 1 "$RUN_RC" "grok: absent quota tooling refuses"
  assert_absent "$dir/out-tool.md" "grok: no --out without quota tooling"

  run_so "$dir" "$dir/none.json" FM_SECOND_OPINION_FORCE=1 -- \
    --reviewer grok --out "$dir/out-force.md" -- "no included reading forced"
  expect_code 0 "$RUN_RC" "grok: FORCE overrides an unavailable reading"
  assert_contains "$RUN_OUT" 'reading unavailable but FM_SECOND_OPINION_FORCE=1' \
    "grok: forced unavailable advisory"
  pass "fm-second-opinion refuses grok when the Cursor included pool cannot be read"
}

test_sol_still_available_with_codex_floor() {
  local dir="$TMP/sol"
  fm_fakebin "$dir" >/dev/null
  install_reviewer_stub "$dir/fakebin" pi ok

  write_quota_fixture "$dir/ok.json" 80 1 1 1
  run_so "$dir" "$dir/ok.json" -- --reviewer sol --out "$dir/out.md" -- "sol review"
  expect_code 0 "$RUN_RC" "sol happy-path exit"
  assert_contains "$(cat "$dir/out.md")" 'Reviewer: sol' "sol: reviewer in header"
  assert_contains "$(cat "$dir/argv.txt")" '--print --model openai-codex/gpt-5.6-sol --thinking xhigh' \
    "sol: pi invocation"
  assert_contains "$RUN_OUT" 'Codex general-window percentRemaining=80' \
    "sol: advisory ignores the model-kind window"

  write_quota_fixture "$dir/low.json" 5 90 90 90
  run_so "$dir" "$dir/low.json" -- --reviewer sol --out "$dir/out-low.md" -- "low codex"
  expect_code 1 "$RUN_RC" "sol: low Codex refuses"
  assert_contains "$RUN_OUT" 'below floor' "sol: refusal message"
  assert_absent "$dir/out-low.md" "sol: no --out when refusing"
  pass "fm-second-opinion keeps sol on its Codex floor"
}

test_neutral_cwd_not_repo() {
  local dir="$TMP/cwd" cwd_recorded repo
  fm_fakebin "$dir" >/dev/null
  install_reviewer_stub "$dir/fakebin" claude ok
  write_quota_fixture "$dir/quota.json" 90 90 90 90
  repo=$(cd "$ROOT" && pwd -P)

  run_so "$dir" "$dir/quota.json" -- --out "$dir/out.md" -- "neutral cwd check"

  expect_code 0 "$RUN_RC" "neutral-cwd exit"
  cwd_recorded=$(cat "$dir/cwd.txt")
  [ -n "$cwd_recorded" ] || fail "neutral-cwd: cwd log empty"
  case "$cwd_recorded" in
    "$repo"|"$repo"/*)
      fail "neutral-cwd: reviewer cwd is the repo or inside it ($cwd_recorded)"
      ;;
  esac
  assert_contains "$RUN_OUT" 'wrote' "neutral-cwd: completed write"
  pass "fm-second-opinion does not invoke the reviewer with the repo as cwd"
}

test_unknown_reviewer_refused() {
  local dir="$TMP/unknown"
  fm_fakebin "$dir" >/dev/null
  install_reviewer_stub "$dir/fakebin" claude ok
  write_quota_fixture "$dir/quota.json" 90 90 90 90

  run_so "$dir" "$dir/quota.json" -- \
    --out "$dir/out.md" --reviewer not-a-real-reviewer -- "should refuse"

  expect_code 1 "$RUN_RC" "unknown-reviewer exit"
  assert_contains "$RUN_OUT" 'unknown reviewer: not-a-real-reviewer' \
    "unknown-reviewer: refusal message"
  assert_absent "$dir/out.md" "unknown-reviewer: must not write --out"
  pass "fm-second-opinion refuses unknown reviewer names loudly"
}

test_missing_reviewer_cli() {
  local dir="$TMP/missing"
  fm_fakebin "$dir" >/dev/null
  write_quota_fixture "$dir/quota.json" 90 90 90 90

  run_so "$dir" "$dir/quota.json" -- --reviewer grok --out "$dir/out.md" -- "no cli"

  expect_code 127 "$RUN_RC" "missing-cli exit"
  assert_contains "$RUN_OUT" 'reviewer binary not found on PATH: cursor-agent' \
    "missing-cli: names the binary"
  assert_contains "$RUN_OUT" 'cursor-agent for grok' "missing-cli: install hint"
  assert_absent "$dir/out.md" "missing-cli: must not write --out"
  pass "fm-second-opinion refuses with 127 when the reviewer CLI is absent"
}

test_empty_reviewer_output_fails_loudly() {
  local dir="$TMP/empty"
  fm_fakebin "$dir" >/dev/null
  install_reviewer_stub "$dir/fakebin" claude empty
  write_quota_fixture "$dir/quota.json" 90 90 90 90

  run_so "$dir" "$dir/quota.json" -- --out "$dir/out.md" -- "empty body"

  expect_code 1 "$RUN_RC" "empty-output exit"
  assert_contains "$RUN_OUT" 'empty output' "empty-output: loud failure message"
  assert_absent "$dir/out.md" "empty-output: must not write empty --out"
  pass "fm-second-opinion treats empty reviewer output as a loud failure"
}

test_help_exits_zero
test_default_fable_happy_path
test_fable_quota_floor
test_grok_happy_path_and_floor
test_grok_refuses_unavailable_reading
test_sol_still_available_with_codex_floor
test_neutral_cwd_not_repo
test_unknown_reviewer_refused
test_missing_reviewer_cli
test_empty_reviewer_output_fails_loudly
