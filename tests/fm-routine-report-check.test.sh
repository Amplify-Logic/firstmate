#!/usr/bin/env bash
# Tests for fm-routine-report-check.sh, the laptop-side notice for scheduled
# cloud routine reports.
#
# The remote is a local bare repository named through FM_ROUTINE_REPORTS_URL,
# so no case reads GitHub. The cases pin what a supervisor relies on: one
# generic line per new report and silence otherwise, no report text in that
# line, no write to the remote, and a check the watcher will actually run.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

CHECK="$ROOT/bin/fm-routine-report-check.sh"
TMP_ROOT=$(fm_test_tmproot fm-routine-report-check)
fm_git_identity fmtest fmtest@example.invalid

READY='routine report ready: a scheduled cloud routine published a new report; review it with bin/fm-routine-report-check.sh show'

make_home() {
  local home="$TMP_ROOT/$1"
  mkdir -p "$home/state"
  printf '%s\n' "$home"
}

make_remote() {  # <name> -> path of a bare remote with a main branch only
  local dir="$TMP_ROOT/$1-remote"
  fm_git_init_commit "$dir-src" >/dev/null
  git clone -q --bare "$dir-src" "$dir.git"
  printf '%s\n' "$dir.git"
}

# publish <remote> <file> <text>: a new commit on routine-reports holding the
# previous files plus <file>, the way a routine publishes.
publish() {
  local remote=$1 file=$2 text=$3 blob tree parent commit
  blob=$(printf '%s\n' "$text" | git -C "$remote" hash-object -w --stdin)
  if parent=$(git -C "$remote" rev-parse --verify --quiet refs/heads/routine-reports); then
    tree=$( { git -C "$remote" ls-tree "$parent" | awk -F '\t' -v f="$file" '$2 != f'
      printf '100644 blob %s\t%s\n' "$blob" "$file"; } | git -C "$remote" mktree)
    commit=$(git -C "$remote" commit-tree "$tree" -p "$parent" -m report)
  else
    tree=$(printf '100644 blob %s\t%s\n' "$blob" "$file" | git -C "$remote" mktree)
    commit=$(git -C "$remote" commit-tree "$tree" -m report)
  fi
  git -C "$remote" update-ref refs/heads/routine-reports "$commit"
}

run_check() {  # <home> <remote> [action] [env assignments...]
  local home=$1 remote=$2 action=${3:-check}
  shift 3 2>/dev/null || shift $#
  env FM_HOME="$home" FM_ROUTINE_REPORTS_URL="file://$remote" FM_ROUTINE_REPORT_INTERVAL=0 "$@" "$CHECK" "$action"
}

test_a_new_report_is_announced_once() {
  local home remote out
  home=$(make_home once)
  remote=$(make_remote once)
  out=$(run_check "$home" "$remote") || fail "check failed before any report"
  assert_equals "" "$out" "a missing branch was announced"
  publish "$remote" creator-watch.md "first digest with SECRET-LOOKING third-party text"
  out=$(run_check "$home" "$remote")
  assert_equals "$READY" "$out" "the first report was not announced with the generic line"
  out=$(run_check "$home" "$remote")
  assert_equals "" "$out" "the same report was announced twice"
  publish "$remote" creator-watch.md "second digest"
  out=$(run_check "$home" "$remote")
  assert_equals "$READY" "$out" "a newer report was not announced"
  pass "each new report is announced once with one generic line"
}

test_probes_wait_for_the_interval() {
  local home remote out
  home=$(make_home interval)
  remote=$(make_remote interval)
  publish "$remote" creator-watch.md "first"
  run_check "$home" "$remote" check FM_ROUTINE_REPORT_INTERVAL=3600 >/dev/null
  publish "$remote" creator-watch.md "second"
  out=$(run_check "$home" "$remote" check FM_ROUTINE_REPORT_INTERVAL=3600)
  assert_equals "" "$out" "the remote was probed again inside the interval"
  out=$(run_check "$home" "$remote")
  assert_equals "$READY" "$out" "the report held back by the interval was lost"
  pass "probes are spaced by the interval and a held-back report still arrives"
}

test_an_unreachable_remote_is_silent_and_retried() {
  local home remote out
  home=$(make_home unreachable)
  remote=$(make_remote unreachable)
  out=$(run_check "$home" "$TMP_ROOT/no-such-remote.git") || fail "an unreachable remote made check fail"
  assert_equals "" "$out" "an unreachable remote was announced"
  publish "$remote" creator-watch.md "first"
  out=$(run_check "$home" "$remote")
  assert_equals "$READY" "$out" "a report after a failed probe was not announced"
  pass "an unreachable remote is silent and the next probe still announces"
}

test_show_prints_reports_and_writes_nothing() {
  local home remote out before after
  home=$(make_home show)
  remote=$(make_remote show)
  publish "$remote" README.md "branch readme"
  publish "$remote" creator-watch.md "creator digest body"
  before=$(git -C "$remote" for-each-ref --format='%(refname) %(objectname)')
  out=$(run_check "$home" "$remote" show) || fail "show failed"
  after=$(git -C "$remote" for-each-ref --format='%(refname) %(objectname)')
  assert_contains "$out" "===== creator-watch.md =====" "show did not name the report"
  assert_contains "$out" "creator digest body" "show did not print the report"
  assert_not_contains "$out" "branch readme" "show printed the branch README as a report"
  assert_equals "$before" "$after" "show changed the remote"
  pass "show prints every report and changes nothing"
}

test_arm_registers_the_check_and_disarm_removes_it() {
  local home mode
  home=$(make_home arm)
  FM_HOME="$home" "$CHECK" arm >/dev/null || fail "arm failed"
  assert_present "$home/state/routine-reports.check.sh" "arm did not write the shim"
  mode=$(stat -c %a "$home/state/routine-reports.check.sh" 2>/dev/null || stat -f %Lp "$home/state/routine-reports.check.sh")
  assert_equals 700 "$mode" "the shim is not mode 700"
  assert_grep 'fm-custom-check-v1' "$home/state/routine-reports.check-trust" "arm did not bind the shim's bytes"
  FM_HOME="$home" "$CHECK" arm >/dev/null || fail "arming twice failed"
  assert_grep 'fm-custom-check-v1' "$home/state/routine-reports.check-trust" "re-arming lost the binding"
  printf 'x\n' > "$home/state/.routine-reports"
  FM_HOME="$home" "$CHECK" disarm >/dev/null || fail "disarm failed"
  assert_absent "$home/state/routine-reports.check.sh" "disarm left the shim"
  assert_absent "$home/state/routine-reports.check-trust" "disarm left the binding"
  assert_absent "$home/state/.routine-reports" "disarm left the record"
  pass "arm registers a trusted check and disarm removes every trace"
}

test_the_armed_shim_runs_the_check() {
  local home remote out
  home=$(make_home shim)
  remote=$(make_remote shim)
  FM_HOME="$home" "$CHECK" arm >/dev/null || fail "arm failed"
  publish "$remote" creator-watch.md "first"
  out=$(env -u FM_HOME FM_ROUTINE_REPORTS_URL="file://$remote" FM_ROUTINE_REPORT_INTERVAL=0 \
    "$home/state/routine-reports.check.sh")
  assert_equals "$READY" "$out" "the armed shim did not announce the report"
  assert_present "$home/state/.routine-reports" "the shim did not record into its own home"
  pass "the armed shim runs the check against its own home"
}

test_invalid_settings_and_action_refuse() {
  local home status
  home=$(make_home invalid)
  status=0; FM_HOME="$home" FM_ROUTINE_REPORT_INTERVAL=5 "$CHECK" check >/dev/null 2>&1 || status=$?
  expect_code 2 "$status" "an interval under a minute"
  status=0; FM_HOME="$home" FM_ROUTINE_REPORT_PROBE_SECS=60 "$CHECK" check >/dev/null 2>&1 || status=$?
  expect_code 2 "$status" "a probe bound over the watcher's"
  status=0; FM_HOME="$home" "$CHECK" bogus >/dev/null 2>&1 || status=$?
  expect_code 2 "$status" "an unknown action"
  pass "invalid settings and actions are refused"
}

test_a_new_report_is_announced_once
test_probes_wait_for_the_interval
test_an_unreachable_remote_is_silent_and_retried
test_show_prints_reports_and_writes_nothing
test_arm_registers_the_check_and_disarm_removes_it
test_the_armed_shim_runs_the_check
test_invalid_settings_and_action_refuse
