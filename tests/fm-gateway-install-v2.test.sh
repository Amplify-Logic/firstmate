#!/usr/bin/env bash
# Behavior tests for the gateway v2 installation lifecycle (Step 2 sub-order 7).
#
# The subject under test is a script that must NOT act. Every test here runs it
# for real and then asserts that nothing on this machine changed, because a
# preview that quietly installed would pass any test that only read its output.
set -u

# shellcheck source=tests/lib.sh disable=SC1091
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

INSTALL="$ROOT/bin/fm-gateway-install-v2.sh"
TMP=$(fm_test_tmproot fm-gateway-install-v2)

# The privileged paths the script names. Nothing in this suite may create any of
# them, and the suite asserts that after every command they are still absent.
PRIVILEGED_PATHS=(
  /usr/local/libexec/firstmate
  /var/db/firstmate/gateway
  /var/run/firstmate/gateway
  /Library/LaunchDaemons/ai.firstmate.gateway-v2.plist
  /Library/LaunchDaemons/ai.firstmate.gateway-v2-runner.plist
)

assert_nothing_installed() {  # <label>
  local label=$1 path
  for path in "${PRIVILEGED_PATHS[@]}"; do
    [ ! -e "$path" ] || fail "$label created or touched $path"
  done
}

test_preview_prints_the_plan_and_installs_nothing() {
  local out
  out=$("$INSTALL" preview)
  assert_contains "$out" 'NOTHING BELOW HAS BEEN DONE' "the preview says plainly that it did not act"
  assert_contains "$out" '_firstmate_gateway' "the broker principal is named"
  assert_contains "$out" '_firstmate_runner' "the runner principal is named"
  assert_contains "$out" '/var/db/firstmate/gateway' "the state root is named"
  assert_contains "$out" 'ecdsa-p256-sha256' "the production approver algorithm is named"
  assert_contains "$out" 'fm-action-safe-sink-v2.py' "the bound executor is named"
  # The preview has to be honest about what installation does not prove, or it
  # becomes the document someone cites as evidence of isolation.
  assert_contains "$out" 'planned and unverified' "the preview refuses to claim the boundary is proved"
  assert_contains "$out" 'Secure Enclave' "the unproven Secure Enclave step is named"
  assert_not_contains "$out" 'rm -rf' "no recursive delete appears anywhere in the plan"
  assert_nothing_installed preview
  pass "preview prints the complete activation plan, claims nothing it has not proved, and installs nothing"
}

test_check_reports_absence_honestly() {
  local out rc
  set +e
  out=$("$INSTALL" check)
  rc=$?
  set -e
  expect_code 3 "$rc" "check on an uninstalled machine"
  assert_contains "$out" 'The gateway is NOT installed' "check reports the truth"
  assert_contains "$out" 'absent   /var/db/firstmate/gateway' "check names each absent path"
  assert_nothing_installed check
  pass "check reports what is actually installed and exits nonzero when the boundary is absent"
}

test_apply_always_refuses() {
  local out rc
  set +e
  out=$("$INSTALL" apply 2>&1)
  rc=$?
  set -e
  expect_code 3 "$rc" "apply"
  assert_contains "$out" 'refusing to install' "apply refuses"
  assert_contains "$out" "captain's own step" "apply says whose step it is"
  assert_nothing_installed apply
  pass "apply always refuses and never performs a privileged installation"
}

test_uninstall_preview_never_deletes_a_tree() {
  local out
  out=$("$INSTALL" rollback-preview)
  assert_contains "$out" 'NOTHING BELOW HAS BEEN DONE' "the uninstall preview says plainly that it did not act"
  # The property that matters: uninstall moves directories aside under a
  # timestamp. A recursive delete built from a shell variable is one empty
  # variable away from removing a shared ancestor, and an uninstall that
  # destroys the audit record is worse than one that leaves a directory behind.
  assert_not_contains "$out" 'rm -rf' "uninstall must never recursively delete"
  assert_not_contains "$out" 'rm -r ' "uninstall must never recursively delete"
  assert_contains "$out" 'sudo mv --' "directories are quarantined by moving them"
  assert_contains "$out" 'uninstalled-' "the quarantine is timestamped"
  assert_nothing_installed rollback-preview
  pass "the uninstall preview quarantines by moving and never deletes a directory tree"
}

test_emitted_artifacts_are_guarded_and_inert() {
  local dir out rc line
  dir="$TMP/artifacts"
  out=$("$INSTALL" artifacts "$dir")
  assert_contains "$out" 'none has been run' "the artifacts are declared unrun"
  for line in ai.firstmate.gateway-v2.plist install.sh check.sh uninstall.sh; do
    assert_present "$dir/$line" "artifact $line"
    [ ! -x "$dir/$line" ] || fail "$line must not be executable"
  done

  # Each emitted script validates its own paths, because a person runs it
  # standalone with sudo and cannot rely on the authoring script's checks.
  for line in install.sh uninstall.sh; do
    assert_grep 'assert_fixed_path()' "$dir/$line" "$line must carry its own path guard"
    assert_grep 'assert_contained()' "$dir/$line" "$line must carry its own containment guard"
    assert_grep 'assert_not_symlink()' "$dir/$line" "$line must carry its own symlink guard"
    assert_no_grep 'rm -rf' "$dir/$line" "$line must never recursively delete"
    sh -n "$dir/$line" || fail "$line must be valid shell"
  done
  assert_grep 'assert_owner()' "$dir/uninstall.sh" "uninstall must check ownership before removing anything"

  # Every path the emitted scripts hand to a command is a literal, so an emptied
  # constant cannot silently become a shared ancestor.
  assert_no_grep 'rm -f' "$dir/install.sh" "install performs no removal at all"
  assert_grep '/Library/LaunchDaemons/ai.firstmate.gateway-v2.plist' "$dir/uninstall.sh" "uninstall names exact literal plist paths"

  # Running either one without the confirmation flag must do nothing at all.
  for line in install.sh uninstall.sh; do
    set +e
    out=$(sh "$dir/$line" 2>&1)
    rc=$?
    set -e
    expect_code 3 "$rc" "$line without the confirmation flag"
    assert_contains "$out" 'refusing to run without' "$line refuses without confirmation"
  done
  assert_nothing_installed artifacts
  pass "the emitted install and uninstall artifacts are inert, self-guarding, and refuse to run unconfirmed"
}

test_artifacts_refuse_an_occupied_or_unsafe_directory() {
  local dir out rc
  dir="$TMP/occupied"
  mkdir -p "$dir"
  printf 'existing\n' > "$dir/keep.txt"
  set +e
  out=$("$INSTALL" artifacts "$dir" 2>&1)
  rc=$?
  set -e
  expect_code 1 "$rc" "occupied artifact directory"
  assert_contains "$out" 'must be empty' "artifacts never overwrite a directory it did not create"
  assert_present "$dir/keep.txt" "the existing file survives"

  ln -s "$TMP" "$TMP/link-dir"
  set +e
  out=$("$INSTALL" artifacts "$TMP/link-dir" 2>&1)
  rc=$?
  set -e
  expect_code 1 "$rc" "symlinked artifact directory"
  assert_contains "$out" 'is a symlink' "a symlinked destination is refused rather than followed"
  pass "artifacts refuses an occupied or symlinked directory instead of writing through it"
}

test_preview_prints_the_plan_and_installs_nothing
test_check_reports_absence_honestly
test_apply_always_refuses
test_uninstall_preview_never_deletes_a_tree
test_emitted_artifacts_are_guarded_and_inert
test_artifacts_refuse_an_occupied_or_unsafe_directory
