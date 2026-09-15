#!/usr/bin/env bash
# Cursor and Kimi primary-profile detection, and the worker-boundary regression.
#
# bin/fm-primary.sh establishes the primary's identity at the launch boundary and
# states it in FM_PRIMARY_HARNESS, because Kimi publishes no unambiguous native
# marker and a Cursor primary does not clear an inherited CLAUDECODE. That claim
# is observable through `fm-harness.sh marker`; `detect_own` deliberately lets a
# contradicting harness ANCESTOR outrank it, so a variable leaked into an
# unrelated pane cannot rename that session. Assert the marker layer here rather
# than detect_own, whose verdict depends on the ancestry of whatever ran the test.
set -u

# shellcheck source=tests/lib.sh
# shellcheck disable=SC1091
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

test_primary_marker_states_the_launched_identity() {
  local out
  out=$(FM_PRIMARY_HARNESS=cursor CLAUDECODE=1 "$ROOT/bin/fm-harness.sh" marker)
  [ "$out" = cursor ] || fail "Cursor primary marker lost to an inherited CLAUDECODE (got '$out')"
  out=$(FM_PRIMARY_HARNESS=kimi CLAUDECODE=1 "$ROOT/bin/fm-harness.sh" marker)
  [ "$out" = kimi ] || fail "Kimi primary marker lost to an inherited CLAUDECODE (got '$out')"
  pass "fm-harness: the primary launcher's established identity survives an inherited foreign marker"
}

test_ancestry_still_outranks_a_leaked_marker() {
  local out
  # A marker with no matching process in the ancestry must not rename this
  # session: the test itself runs under some other harness or a bare shell.
  out=$(FM_PRIMARY_HARNESS=cursor "$ROOT/bin/fm-harness.sh")
  [ "$out" != cursor ] || [ -n "${CURSOR_AGENT:-}" ] || \
    fail "a leaked FM_PRIMARY_HARNESS renamed a session with no Cursor ancestor"
  pass "fm-harness: ancestry still arbitrates a marker that no live process supports"
}

test_configured_worker_selection_stays_separate() {
  local out config
  config=$(fm_test_tmproot fm-cursor-harness-config)
  mkdir -p "$config"
  printf 'codex\n' > "$config/crew-harness"
  out=$(FM_PRIMARY_HARNESS=cursor FM_CONFIG_OVERRIDE="$config" "$ROOT/bin/fm-harness.sh" crew)
  [ "$out" = codex ] || fail "configured worker runtime was coupled to the Cursor primary (got $out)"
  pass "fm-harness: configured worker selection stays separate from the primary profile"
}

test_worker_set_still_includes_the_fork_adapters() {
  local usage
  usage=$("$ROOT/bin/fm-spawn.sh" --help 2>&1 || true)
  assert_contains "$usage" 'cursor' "fm-spawn lost cursor from its documented worker set"
  assert_contains "$usage" 'kimi' "fm-spawn lost kimi from its documented worker set"
  assert_contains "$usage" 'prime-agent' "fm-spawn lost prime-agent from its documented worker set"
  pass "fm-spawn: primary-profile support does not remove the fork's verified worker adapters"
}

test_primary_marker_states_the_launched_identity
test_ancestry_still_outranks_a_leaked_marker
test_configured_worker_selection_stays_separate
test_worker_set_still_includes_the_fork_adapters
