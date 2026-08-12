#!/usr/bin/env bash
# Native worker-runtime exam contract and artifact renderer tests.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
# shellcheck source=tests/lib.sh
. "$ROOT/tests/lib.sh"

EXAM="$ROOT/bin/fm-harness-exam.sh"
EXPECTATIONS="$ROOT/bin/fm-harness-exam-adapters.tsv"

assert_executable() {
  [ -x "$1" ] || fail "$1 is not executable"
}

test_supported_adapter_matrix() {
  local listed expected fields adapter
  listed=$($EXAM --list)
  expected=$'claude\ncodex\nopencode\npi\ngrok\ncursor\nkimi'
  [ "$listed" = "$expected" ] || fail "adapter list drifted: $listed"
  while IFS= read -r adapter; do
    fields=$(awk -F '\t' -v a="$adapter" '!/^#/ && $1 == a { print NF }' "$EXPECTATIONS")
    [ "$fields" = 14 ] || fail "$adapter expectation row has $fields fields, expected 14"
  done <<< "$listed"
  pass "exam carries one complete expectation row for all seven worker adapters"
}

test_probe_set_and_kimi_plan() {
  local plan
  plan=$($EXAM --plan kimi)
  assert_contains "$plan" $'probes\tautonomy,composer,busy,interrupt,turn-end,liveness,exit,resume' \
    "plan does not expose the approved eight probes"
  assert_contains "$plan" $'busy\tthinking\\.\\.\\.|Running a command' \
    "Kimi plan lost its two busy phases"
  assert_contains "$plan" $'interrupt\tC-c' "Kimi plan lost Ctrl+C"
  assert_contains "$plan" $'interrupt_regex\tInterrupted by user' \
    "Kimi plan hides the interrupt text the probe is scored on"
  assert_contains "$plan" $'comm_regex\tkimi' "Kimi plan hides the liveness comm marker"
  assert_contains "$plan" $'argv_regex\tkimi-code|/kimi([ /]|$)' "Kimi plan hides the liveness argv marker"
  assert_contains "$plan" $'resume\t--continue' "Kimi plan lost continue resume"
  assert_contains "$plan" $'liveness\talive' "Kimi plan lost its liveness verdict"
  assert_contains "$plan" $'model\tkimi-code/k3' "Kimi plan lost its pinned model"
  pass "Kimi plan is driven by the certified adapter facts"
}

test_pi_known_liveness_limit_is_explicit() {
  local plan
  plan=$($EXAM --plan pi)
  assert_contains "$plan" $'liveness\tunknown' "Pi must not claim an unsupported alive verdict"
  assert_grep 'pi-coding-agent' "$EXPECTATIONS" "Pi raw argv marker is missing"
  pass "Pi liveness records the backend limitation and the raw process marker"
}

test_codex_resume_uses_recorded_session_id() {
  local dir command
  dir=$(fm_test_tmproot harness-exam-codex-resume)
  export FM_HARNESS_EXAM_SOURCE_ONLY=1
  # shellcheck source=bin/fm-harness-exam.sh
  . "$EXAM"
  unset FM_HARNESS_EXAM_SOURCE_ONLY
  load_expectation codex
  LAB_HOME="$dir/home"
  LAB_ROOT="$dir/lab"
  MODEL=-
  build_launch_command 1 01234567-89ab-cdef-0123-456789abcdef
  command=$RESUME_CMD
  assert_contains "$command" "'resume' '01234567-89ab-cdef-0123-456789abcdef'" \
    "Codex resume does not use the recorded session id"
  assert_not_contains "$command" "--last" "Codex resume still bypasses the adapter record"
  pass "Codex resume command is driven by the recorded per-adapter fact"
}

test_credentials_are_selected_read_only_copies() {
  local dir source lab
  dir=$(fm_test_tmproot harness-exam-credentials)
  source="$dir/source"
  lab="$dir/lab"
  mkdir -p "$source/.codex" "$source/.claude" "$lab"
  printf 'codex-token\n' > "$source/.codex/auth.json"
  printf 'model = "test"\n' > "$source/.codex/config.toml"
  printf 'claude-token\n' > "$source/.claude/.credentials.json"
  export FM_HARNESS_EXAM_SOURCE_ONLY=1
  # shellcheck source=bin/fm-harness-exam.sh
  . "$EXAM"
  unset FM_HARNESS_EXAM_SOURCE_ONLY
  ADAPTER=codex
  SOURCE_HOME="$source"
  LAB_HOME="$lab"
  prepare_credential_bridges
  [ -f "$lab/.codex/auth.json" ] || fail "selected Codex authentication was not copied"
  [ ! -L "$lab/.codex/auth.json" ] || fail "selected Codex authentication remains linked to its source"
  [ ! -w "$lab/.codex/auth.json" ] || fail "selected Codex authentication copy is writable"
  assert_absent "$lab/.claude/.credentials.json" "unselected Claude credential crossed into the Codex lab"
  printf 'changed\n' > "$source/.codex/auth.json"
  [ "$(cat "$lab/.codex/auth.json")" = codex-token ] || fail "isolated credential changed with its source"
  pass "only the selected adapter receives isolated read-only credential copies"
}

test_ambient_tmux_survives_full_failed_exam() {
  command -v tmux >/dev/null 2>&1 || { pass "ambient tmux survival skipped because tmux is unavailable"; return; }
  local dir socket runtime_path rc
  dir=$(fm_test_tmproot harness-exam-ambient-tmux)
  socket="$dir/ambient.sock"
  runtime_path="$dir/bin"
  mkdir -p "$runtime_path"
  cat > "$runtime_path/kimi" <<'EOF'
#!/usr/bin/env bash
if [ "${1:-}" = --version ]; then printf 'fake-kimi 1\n'; exit 0; fi
exit 0
EOF
  chmod +x "$runtime_path/kimi"
  tmux -S "$socket" new-session -d -s unrelated
  set +e
  TMUX="$socket,999,0" PATH="$runtime_path:$PATH" "$EXAM" kimi --timeout 11 --output "$dir/output" >/dev/null 2>&1
  rc=$?
  set -e
  [ "$rc" -ne 0 ] || fail "fake runtime unexpectedly passed the full exam"
  tmux -S "$socket" has-session -t unrelated 2>/dev/null \
    || fail "full exam cleanup killed an unrelated tmux session"
  tmux -S "$socket" kill-session -t unrelated
  pass "full exam cleanup preserves unrelated tmux sessions"
}

test_unknown_adapter_refuses_before_output() {
  local dir rc out
  dir=$(fm_test_tmproot harness-exam-refuse)
  set +e
  out=$($EXAM bogus --output "$dir/out" 2>&1)
  rc=$?
  set -e
  [ "$rc" = 2 ] || fail "unknown adapter returned $rc, expected 2"
  assert_contains "$out" "unsupported adapter 'bogus'" "unknown adapter refusal was not specific"
  assert_absent "$dir/out" "unknown adapter created an output directory"
  pass "unsupported adapters stop before creating lab or output state"
}

test_hook_fixtures_are_isolated_per_adapter() {
  local dir adapter
  dir=$(fm_test_tmproot harness-exam-hooks)
  export FM_HARNESS_EXAM_SOURCE_ONLY=1
  # shellcheck source=bin/fm-harness-exam.sh
  . "$EXAM"
  unset FM_HARNESS_EXAM_SOURCE_ONLY
  SOURCE_HOME="$dir/source"
  mkdir -p "$SOURCE_HOME"
  for adapter in claude codex opencode pi grok cursor kimi; do
    LAB_ROOT="$dir/$adapter"
    LAB_HOME="$LAB_ROOT/home"
    WORKSPACE="$LAB_ROOT/workspace"
    HOOK_MARKER="$LAB_ROOT/turn-ended"
    HOOK_RAW="$LAB_ROOT/turn-end.raw"
    HOOK_KIND=$adapter
    mkdir -p "$LAB_HOME" "$WORKSPACE"
    prepare_hook || fail "could not prepare $adapter hook fixture"
  done
  jq empty "$dir/claude/workspace/.claude/settings.local.json" \
    "$dir/grok/home/.grok/hooks/fm-harness-exam.json" \
    "$dir/cursor/workspace/.cursor/hooks.json" \
    || fail "generated JSON hook fixture is invalid"
  assert_grep 'session.idle' "$dir/opencode/workspace/.opencode/plugins/fm-harness-exam.js" \
    "OpenCode hook does not observe session idle"
  assert_grep 'turn_end' "$dir/pi/pi-turn-end.ts" "Pi hook does not observe turn_end"
  assert_grep 'event = "Stop"' "$dir/kimi/home/.kimi-code/config.toml" \
    "Kimi isolated home does not register Stop"
  pass "all seven adapters receive isolated native turn-end hook fixtures"
}

test_renderer_fails_closed_and_emits_scorecard() {
  local dir probe json score
  dir=$(fm_test_tmproot harness-exam-render)
  export FM_HARNESS_EXAM_SOURCE_ONLY=1
  # shellcheck source=bin/fm-harness-exam.sh
  . "$EXAM"
  unset FM_HARNESS_EXAM_SOURCE_ONLY
  OUTPUT="$dir/output"
  ARTIFACTS="$OUTPUT/evidence"
  RESULTS_TSV="$OUTPUT/.results.tsv"
  ADAPTER=kimi
  VERSION=0.31.1
  WORKSPACE="$dir/lab/workspace"
  RUN_FAILED=0
  mkdir -p "$ARTIFACTS"
  : > "$RESULTS_TSV"
  for probe in autonomy composer busy interrupt turn-end liveness exit; do
    record_result "$probe" pass "$probe evidence captured" "evidence/$probe.txt"
  done
  record_missing_results
  render_results
  json="$OUTPUT/results.json"
  score="$OUTPUT/scorecard.md"
  [ "$(jq -r '.score.passed' "$json")" = 7 ] || fail "renderer pass count is wrong"
  [ "$(jq -r '.score.total' "$json")" = 8 ] || fail "renderer total is wrong"
  [ "$(jq -r '.probes[] | select(.probe == "resume") | .status' "$json")" = fail ] \
    || fail "missing probe was not failed closed"
  assert_grep '**7/8**' "$score" "scorecard omitted score"
  assert_grep "\`resume\` | **fail**" "$score" "scorecard omitted failed probe"
  pass "renderer emits JSON and Markdown while missing evidence fails closed"
}

test_documented_isolation_and_evidence_contract() {
  local doc="$ROOT/docs/harness-exam.md"
  assert_grep 'private Unix home' "$doc" "documentation omits private home isolation"
  assert_grep 'private tmux socket' "$doc" "documentation omits tmux isolation"
  assert_grep 'Every scored observation comes from outside the runtime pane.' "$doc" \
    "documentation omits outside observer requirement"
  assert_grep 'results.json' "$doc" "documentation omits machine-readable scorecard"
  assert_grep 'raw turn-end payload' "$doc" "documentation omits raw hook evidence"
  assert_grep "does not update \`docs/toolchain-manifest.tsv\`" "$doc" \
    "documentation does not keep certification updates deliberate"
  pass "documentation states the isolation, evidence, and non-mutation boundaries"
}

assert_executable "$EXAM"
assert_executable "$0"
test_supported_adapter_matrix
test_probe_set_and_kimi_plan
test_pi_known_liveness_limit_is_explicit
test_codex_resume_uses_recorded_session_id
test_credentials_are_selected_read_only_copies
test_unknown_adapter_refuses_before_output
test_hook_fixtures_are_isolated_per_adapter
test_renderer_fails_closed_and_emits_scorecard
test_documented_isolation_and_evidence_contract
test_ambient_tmux_survives_full_failed_exam
