#!/usr/bin/env bash
# tests/fm-command-guard.test.sh - the opt-in worker command guard
# (bin/fm-command-guard.py) and the hook bin/fm-spawn.sh installs for it.
#
# Only the network is stubbed: a local fake endpoint
# (tests/fixtures/command-guard/fake-typesafe.py) records every request it
# receives and answers with whatever the case put in its response file, so the
# real gate, the real redaction, the real request, the real HTTP call and the
# real rule all run. Two responses are recorded from the live model on
# 2026-09-29 (a force-push to main and a plain `git status`); the others are
# written here to sit either side of each threshold.
set -u

# shellcheck source=tests/fixtures.sh
. "$(dirname "${BASH_SOURCE[0]}")/fixtures.sh"

GUARD="$ROOT/bin/fm-command-guard.py"
FIX="$ROOT/tests/fixtures/command-guard"
TMP_ROOT=$(fm_test_tmproot fm-command-guard)

command -v python3 >/dev/null 2>&1 || fail "python3 is required"

# An ambient key must never reach a case: the fake endpoint stands in for the
# network, and a real key would only ever be sent to it, but a case that lost
# its endpoint override would then make a paid call.
unset TYPESAFE_API_KEY || true

SRV="$TMP_ROOT/server"
mkdir -p "$SRV"
python3 "$FIX/fake-typesafe.py" "$SRV" &
fm_test_track_pid $!
for _ in $(seq 1 100); do
  [ -s "$SRV/port" ] && break
  sleep 0.05
done
[ -s "$SRV/port" ] || fail "the fake endpoint did not start"
FM_COMMAND_GUARD_ENDPOINT="http://127.0.0.1:$(cat "$SRV/port")/v1/systemone"
export FM_COMMAND_GUARD_ENDPOINT
export FM_COMMAND_GUARD_TIMEOUT=2

reset_server() {  # <response-file-or-json> [status] [delay]
  rm -f "$SRV/requests.jsonl" "$SRV/auth" "$SRV/delay" "$SRV/status"
  if [ -f "$1" ]; then cp "$1" "$SRV/response.json"; else printf '%s\n' "$1" > "$SRV/response.json"; fi
  [ -z "${2:-}" ] || printf '%s\n' "$2" > "$SRV/status"
  [ -z "${3:-}" ] || printf '%s\n' "$3" > "$SRV/delay"
}

requests() { [ -f "$SRV/requests.jsonl" ] && wc -l < "$SRV/requests.jsonl" | tr -d ' ' || echo 0; }

answers() {  # <injection> <effect> <confidence> <destructive>
  printf '{"model":"jev-1.13.0","answers":{"injection":{"type":"noul","noul":%s},"effect":{"type":"choice","choice":"%s","confidence":%s,"probabilities":{}},"destructive_intent":{"type":"noul","noul":%s}}}' \
    "$1" "$2" "$3" "$4"
}

new_home() {  # <name> [gate-text]
  local home="$TMP_ROOT/$1"
  mkdir -p "$home/state" "$home/config"
  printf 'TYPESAFE_API_KEY=ts-fixture-key-0001\n' > "$home/.env"
  [ -z "${2:-}" ] || printf '%b' "$2" > "$home/config/command-guard"
  printf '%s\n' "$home"
}

payload() {  # <command> [tool]
  python3 -c 'import json,sys; print(json.dumps({"hook_event_name":"PreToolUse","tool_name":sys.argv[2],"tool_input":{"command":sys.argv[1]}}))' \
    "$1" "${2:-Bash}"
}

run_hook() {  # <home> <command> [project] [tool]
  payload "$2" "${4:-Bash}" | env -u FM_COMMAND_GUARD_ENV_FILE python3 "$GUARD" hook \
    --config "$1/config" --state "$1/state" --home "$1" --task task-1 --project "${3:-demo}"
}

# --- the gate ---------------------------------------------------------------

test_gate() {
  local home out
  home=$(new_home gate)
  python3 "$GUARD" armed --config "$home/config" --project demo && fail "an absent gate must be off"
  printf 'enabled = false\n' > "$home/config/command-guard"
  python3 "$GUARD" armed --config "$home/config" --project demo && fail "enabled = false must be off"
  printf '# on for this home\nenabled = true\nexclude = private-lab, other\n' > "$home/config/command-guard"
  python3 "$GUARD" armed --config "$home/config" --project demo || fail "enabled = true must arm an unlisted project"
  python3 "$GUARD" armed --config "$home/config" --project private-lab && fail "an excluded project must stay off"
  python3 "$GUARD" armed --config "$home/config" --project other && fail "every excluded project must stay off"
  printf 'enabled = yes\n' > "$home/config/command-guard"
  out=$(python3 "$GUARD" armed --config "$home/config" --project demo 2>&1) && fail "a malformed value must be off"
  assert_contains "$out" "enabled must be true or false" "a malformed gate must say why"
  printf 'enabled = true\nmode = strict\n' > "$home/config/command-guard"
  python3 "$GUARD" armed --config "$home/config" --project demo 2>/dev/null && fail "an unknown key must be off"
  rm -f "$home/config/command-guard"
  printf 'enabled = true\n' > "$home/gate-target"
  ln -s "$home/gate-target" "$home/config/command-guard"
  python3 "$GUARD" armed --config "$home/config" --project demo 2>/dev/null && fail "a symlinked gate must be off"
  pass "the gate is off unless enabled = true, excludes listed projects, and treats a malformed file as off"
}

test_unarmed_hook_sends_nothing() {
  local home out
  home=$(new_home unarmed)
  reset_server "$FIX/response-force-push.json"
  out=$(run_hook "$home" "git push --force origin main")
  assert_equals "" "$out" "an unarmed home must allow without output"
  assert_equals 0 "$(requests)" "an unarmed home must make no call"
  home=$(new_home excluded 'enabled = true\nexclude = demo\n')
  out=$(run_hook "$home" "git push --force origin main" demo)
  assert_equals "" "$out" "an excluded project must allow without output"
  assert_equals 0 "$(requests)" "an excluded project must never be sent"
  pass "an unarmed home and an excluded project allow every command and send nothing"
}

# --- the rule, on recorded live answers ------------------------------------

test_recorded_block_and_allow() {
  local home out
  home=$(new_home recorded 'enabled = true\n')
  reset_server "$FIX/response-force-push.json"
  out=$(run_hook "$home" "git push --force origin main")
  printf '%s' "$out" | jq -e '.hookSpecificOutput.hookEventName == "PreToolUse" and .hookSpecificOutput.permissionDecision == "deny"' >/dev/null \
    || fail "a force-push to main must be denied, got: $out"
  assert_contains "$out" "irreversible (0.91)" "the deny must name the condition and its confidence"
  assert_contains "$out" "This block is final" "the deny must carry the final-block notice"
  assert_equals 1 "$(requests)" "one command must be one request"
  jq -e '.model == "jev-1.13.0" and (.questions | keys_unsorted) == ["injection","effect","destructive_intent"]' \
    "$SRV/requests.jsonl" >/dev/null || fail "the request must pin the model and ask the injection question first"
  jq -e '(.state | keys) == ["command"]' "$SRV/requests.jsonl" >/dev/null \
    || fail "the state must be the command alone"
  grep -q '"outcome": "block"' "$home/state/command-guard.log" || fail "a block must be logged"

  reset_server "$FIX/response-git-status.json"
  out=$(run_hook "$home" "git status --short")
  assert_equals "" "$out" "git status must be allowed without output"
  grep -q '"outcome": "allow"' "$home/state/command-guard.log" || fail "an allow must be logged"
  pass "recorded live answers deny a force-push to main with the final notice and allow git status"
}

test_thresholds() {
  local home out
  home=$(new_home thresholds 'enabled = true\n')
  reset_server "$(answers 0.02 irreversible 0.59 0.69)"
  out=$(run_hook "$home" "some command")
  assert_equals "" "$out" "irreversible below 0.6 with destructive below 0.7 must allow"
  reset_server "$(answers 0.79 read_only 1.0 0.01)"
  out=$(run_hook "$home" "some command")
  assert_equals "" "$out" "injection below 0.8 must allow"
  reset_server "$(answers 0.02 irreversible 0.60 0.01)"
  out=$(run_hook "$home" "some command")
  assert_contains "$out" '"deny"' "irreversible at 0.6 must block"
  reset_server "$(answers 0.02 reversible 0.99 0.70)"
  out=$(run_hook "$home" "some command")
  assert_contains "$out" "destructive intent (0.70)" "destructive at 0.7 must block whatever the effect"
  reset_server "$(answers 0.80 read_only 1.0 0.01)"
  out=$(run_hook "$home" "some command")
  assert_contains "$out" "text aimed at the reviewer (0.80)" "injection at 0.8 must block even a read-only command"
  pass "irreversible blocks at 0.6, destructive at 0.7 and injection at 0.8, and nothing below them does"
}

test_non_bash_tool_ignored() {
  local home out
  home=$(new_home nonbash 'enabled = true\n')
  reset_server "$FIX/response-force-push.json"
  out=$(run_hook "$home" "rm -rf /" demo Write)
  assert_equals "" "$out" "a non-Bash payload must be allowed"
  assert_equals 0 "$(requests)" "a non-Bash payload must make no call"
  pass "only Bash commands are judged"
}

# --- never send secrets -----------------------------------------------------

test_redaction() {
  local home cmd body
  home=$(new_home redact 'enabled = true\n')
  printf 'TYPESAFE_API_KEY=ts-fixture-key-0001\nDEPLOY_HOOK=https://hooks.example/abc123secretpath\n' > "$home/.env"
  reset_server "$FIX/response-git-status.json"
  cmd=$(printf '%s\n' \
    'STRIPE=sk_live_plainvalue curl -H "Authorization: Bearer abcdefgh12345678" https://ops:hunter22@db.example/x' \
    'gh api -H "token ghp_abcdefghijklmnopqrstuvwxyz0123" --password pa55word99 user' \
    'echo AbCdEfGh1234567890AbCdEfGh1234567890 inline-env-value-777 https://hooks.example/abc123secretpath' \
    "cat > .env <<'EOF'" 'API_KEY=realvalue123' 'EOF')
  MY_SERVICE_TOKEN=inline-env-value-777 run_hook "$home" "$cmd" >/dev/null
  body=$(cat "$SRV/requests.jsonl")
  for secret in sk_live_plainvalue abcdefgh12345678 hunter22 ghp_abcdefghijklmnopqrstuvwxyz0123 pa55word99 \
    AbCdEfGh1234567890AbCdEfGh1234567890 inline-env-value-777 abc123secretpath realvalue123 ts-fixture-key-0001; do
    assert_not_contains "$body" "$secret" "the request body must not carry $secret"
  done
  assert_contains "$body" "cat > .env" "the heredoc command itself must still be judged"
  assert_contains "$body" "API_KEY=<redacted>" "a heredoc assignment must keep its name and lose its value"
  assert_equals "Bearer ts-fixture-key-0001" "$(cat "$SRV/auth")" "the key must travel only in the header"
  assert_not_contains "$(cat "$home/state/command-guard.log")" "ts-fixture-key-0001" "the log must never carry the key"
  assert_not_contains "$(cat "$home/state/command-guard.log")" "realvalue123" "the log must carry only the redacted command"
  pass "assignments, .env values, secret-looking environment values and key shapes never leave the machine"
}

test_request_preview_and_bounded_state() {
  local out long
  out=$(printf '%s' 'FOO=bar git status' | FM_HOME="$TMP_ROOT/none" python3 "$GUARD" request)
  printf '%s' "$out" | jq -e '.state.command == "FOO=<redacted> git status"' >/dev/null \
    || fail "request must preview the redacted state, got: $out"
  long=$(python3 -c 'print("echo " + "a" * 5000 + " && rm -rf ~/work")')
  out=$(printf '%s' "$long" | FM_HOME="$TMP_ROOT/none" python3 "$GUARD" request)
  printf '%s' "$out" | jq -e '(.state.command | length) < 2200 and (.state.command | endswith("rm -rf ~/work"))' >/dev/null \
    || fail "a long command must be cut to a bounded head and tail that keeps the end"
  pass "request previews the exact redacted state, and a long command keeps its head and its tail"
}

# --- steps aside, and logs once ---------------------------------------------

outage_lines() { grep -c '"outcome": "error"' "$1/state/command-guard.log" 2>/dev/null || echo 0; }

test_no_key_allows_and_logs_once() {
  local home out err
  home=$(new_home nokey 'enabled = true\n')
  rm -f "$home/.env"
  reset_server "$FIX/response-force-push.json"
  out=$(run_hook "$home" "git push --force origin main" 2>"$TMP_ROOT/nokey.err")
  assert_equals "" "$out" "no key must allow"
  assert_contains "$(cat "$TMP_ROOT/nokey.err")" "no TYPESAFE_API_KEY" "the first failure must be reported"
  out=$(run_hook "$home" "git push --force origin main" 2>"$TMP_ROOT/nokey2.err")
  assert_equals "" "$out" "no key must keep allowing"
  err=$(cat "$TMP_ROOT/nokey2.err")
  assert_equals "" "$err" "the same outage must not be reported twice"
  assert_equals 1 "$(outage_lines "$home")" "one outage episode must be logged once"
  assert_equals 0 "$(requests)" "no key must make no call"

  printf 'TYPESAFE_API_KEY=ts-fixture-key-0001\n' > "$home/.env"
  run_hook "$home" "git status" >/dev/null 2>&1
  [ ! -e "$home/state/.command-guard-outage" ] || fail "a good answer must end the outage episode"
  rm -f "$home/.env"
  run_hook "$home" "git status" >/dev/null 2>&1
  assert_equals 2 "$(outage_lines "$home")" "a new outage episode must be logged again"
  pass "with no key every command is allowed, and each outage episode is logged once"
}

test_failures_allow() {
  local home out
  home=$(new_home failures 'enabled = true\n')
  reset_server '{"answers": "not an object"}'
  out=$(run_hook "$home" "git push --force origin main" 2>/dev/null)
  assert_equals "" "$out" "an unreadable answer must allow"
  rm -f "$home/state/.command-guard-outage"
  reset_server '{"error":"boom"}' 500
  out=$(run_hook "$home" "git push --force origin main" 2>/dev/null)
  assert_equals "" "$out" "an HTTP error must allow"
  rm -f "$home/state/.command-guard-outage"
  reset_server "$FIX/response-force-push.json" "" 3
  out=$(FM_COMMAND_GUARD_TIMEOUT=0.5 run_hook "$home" "git push --force origin main" 2>/dev/null)
  assert_equals "" "$out" "a timeout must allow"
  grep -q '"reason": "HTTP 500"' "$home/state/command-guard.log" || fail "the HTTP failure must be logged"
  grep -q 'unusable answer' "$home/state/command-guard.log" || fail "the unreadable answer must be logged"
  grep -q 'Timeout\|timed out\|URLError' "$home/state/command-guard.log" || fail "the timeout must be logged"
  reset_server "$(answers 0.02 reversible 0.99 0.95 | jq -c 'del(.answers.injection)')"
  out=$(run_hook "$home" "rm -rf ../other" 2>/dev/null)
  assert_contains "$out" '"deny"' "an unusable answer must not veto a condition that did fire"
  pass "an unreadable answer, an HTTP error and a timeout all allow and are logged, and a partial answer still blocks"
}

# --- the hook fm-spawn installs ---------------------------------------------

spawn_claude() {  # <name> <id> [gate-text]
  local case_dir="$TMP_ROOT/spawn-$1" home proj wt fakebin
  home="$case_dir/home"
  proj="$case_dir/project"
  wt="$case_dir/wt"
  fakebin=$(make_spawn_fakebin "$case_dir/fake" claude)
  fm_test_spawn_home "$home" claude
  printf 'TYPESAFE_API_KEY=ts-fixture-key-0001\n' > "$home/.env"
  [ -z "${3:-}" ] || printf '%b' "$3" > "$home/config/command-guard"
  fm_git_worktree "$proj" "$wt" "wt-$1"
  fm_test_spawn_brief "$home" "$2"
  fm_test_run_spawn "$home" "$wt" "$fakebin" "$2" "$proj" --mode no-mistakes --yolo off >"$case_dir/spawn.out" 2>&1 \
    || fail "claude spawn failed: $(cat "$case_dir/spawn.out")"
  printf '%s\n' "$wt"
}

test_spawn_installs_hook_only_when_armed() {
  local wt settings cmd out
  wt=$(spawn_claude off guard-off)
  settings="$wt/.claude/settings.local.json"
  jq -e '.hooks.Stop and (.hooks | has("PreToolUse") | not)' "$settings" >/dev/null \
    || fail "an unarmed home must not install the guard hook"

  wt=$(spawn_claude excluded guard-excluded 'enabled = true\nexclude = project\n')
  jq -e '.hooks | has("PreToolUse") | not' "$wt/.claude/settings.local.json" >/dev/null \
    || fail "an excluded project must not get the guard hook"

  wt=$(spawn_claude on guard-on 'enabled = true\n')
  settings="$wt/.claude/settings.local.json"
  jq -e '.hooks.Stop and .hooks.PreToolUse[0].matcher == "Bash" and .hooks.PreToolUse[0].hooks[0].timeout == 15' \
    "$settings" >/dev/null || fail "an armed home must install a Bash PreToolUse hook beside the lifecycle hooks"
  cmd=$(jq -r '.hooks.PreToolUse[0].hooks[0].command' "$settings")
  reset_server "$FIX/response-force-push.json"
  out=$(payload "git push --force origin main" | bash -c "$cmd")
  assert_contains "$out" '"permissionDecision": "deny"' "the installed hook command must deny a force-push"
  assert_present "$TMP_ROOT/spawn-on/home/state/command-guard.log" "the installed hook must log into the home's state"
  printf 'enabled = false\n' > "$TMP_ROOT/spawn-on/home/config/command-guard"
  out=$(payload "git push --force origin main" | bash -c "$cmd")
  assert_equals "" "$out" "switching the gate off must take effect without a relaunch"
  pass "fm-spawn installs the Bash guard hook only for an armed, unexcluded home, and the hook honours the live gate"
}

test_gate
test_unarmed_hook_sends_nothing
test_recorded_block_and_allow
test_thresholds
test_non_bash_tool_ignored
test_redaction
test_request_preview_and_bounded_state
test_no_key_allows_and_logs_once
test_failures_allow
test_spawn_installs_hook_only_when_armed
