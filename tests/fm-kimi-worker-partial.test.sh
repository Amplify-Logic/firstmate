#!/usr/bin/env bash
# Partial Kimi worker certification must not enable fm-spawn dispatch.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
# shellcheck source=tests/lib.sh
. "$ROOT/tests/lib.sh"

test_kimi_still_refused_from_fm_spawn() {
  local spawn_head
  spawn_head=$(sed -n '1,90p' "$ROOT/bin/fm-spawn.sh")
  assert_not_contains "$spawn_head" 'claude|codex|opencode|pi|grok|kimi' \
    "partial Kimi worker evidence accidentally entered fm-spawn's verified worker set"
  # launch_template case list must still omit kimi
  if grep -E '^\s*kimi\)' "$ROOT/bin/fm-spawn.sh" >/dev/null; then
    fail "fm-spawn launch_template gained a kimi branch on partial evidence"
  fi
  pass "fm-spawn still refuses kimi as a worker"
}

test_kimi_harness_doc_marks_unverified_and_refused() {
  local doc="$ROOT/docs/kimi-harness.md"
  [ -f "$doc" ] || fail "docs/kimi-harness.md missing"
  assert_grep 'UNVERIFIED' "$doc" "partial record lacks UNVERIFIED markers"
  assert_grep '403' "$doc" "partial record omits the 403 quota reason"
  assert_grep 'worker dispatch stays refused' "$doc" \
    "partial record does not state that worker dispatch stays refused"
  assert_grep '0.27.0' "$doc" "partial record omits Kimi 0.27.0"
  assert_grep '2026-07-21' "$doc" "partial record omits the lab date"
  # Must not claim busy/interrupt/turn-end as verified worker facts.
  if grep -iE 'busy-pane signature.*verified live|interrupt of a running turn.*verified live|crewmate turn-end.*verified live' "$doc" >/dev/null; then
    fail "docs/kimi-harness.md claims a mid-turn surface was verified live"
  fi
  pass "docs/kimi-harness.md records partial verify and refuse-dispatch"
}

test_harness_adapters_keeps_kimi_out_of_verified_workers() {
  local skill="$ROOT/.agents/skills/harness-adapters/SKILL.md"
  assert_grep 'Worker dispatch stays refused' "$skill" \
    "harness-adapters does not keep Kimi worker dispatch refused"
  assert_grep 'The verified WORKER adapters are `claude`, `codex`, `opencode`, `pi`, `grok`, and `cursor`' "$skill" \
    "verified WORKER adapter list unexpectedly changed"
  if grep -E 'The verified WORKER adapters are .*kimi' "$skill" >/dev/null; then
    fail "kimi was added to the verified WORKER adapter list on partial evidence"
  fi
  pass "harness-adapters keeps kimi out of the verified worker set"
}

test_kimi_still_refused_from_fm_spawn
test_kimi_harness_doc_marks_unverified_and_refused
test_harness_adapters_keeps_kimi_out_of_verified_workers
