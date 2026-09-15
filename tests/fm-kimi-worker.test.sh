#!/usr/bin/env bash
# Kimi worker certification wiring: fm-spawn accepts kimi; busy regex and docs match.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
# shellcheck source=tests/lib.sh
. "$ROOT/tests/lib.sh"

test_kimi_launch_template_in_fm_spawn() {
  local spawn="$ROOT/bin/fm-spawn.sh"
  # The per-task isolated KIMI_CODE_HOME this fork once rendered was retired
  # when the shared spawn owner took Kimi over: worker turn-end now rides one
  # marker-delimited Firstmate region in the captain's own config.toml
  # (bin/fm-kimi-turnend-hook.sh) plus a per-task .fm-kimi-turnend pointer, so
  # the launch only has to resolve a verified Kimi executable. What this fork
  # still proves is that kimi remains a dispatchable worker adapter.
  assert_grep "kimi) printf '%s' '__KIMIBIN__" "$spawn" \
    "fm-spawn missing kimi launch_template branch"
  assert_grep 'resolve_kimi_binary' "$spawn" \
    "kimi launch does not resolve a verified kimi executable"
  assert_grep 'fm-kimi-turnend-hook.sh' "$spawn" \
    "kimi spawn does not install the firstmate-owned turn-end hook"
  # Every verified-adapter case list the spawn gates on must accept kimi.
  local case_lists
  case_lists=$(grep -cE '^ *.*claude\|codex\|opencode\|pi\|pi-signed\|grok\|kimi\|cursor' "$spawn" || true)
  [ "$case_lists" -ge 2 ] || \
    fail "fm-spawn verified-adapter case lists missing kimi"
  pass "fm-spawn accepts kimi as a verified worker"
}

test_kimi_busy_regex_wired() {
  local composer="$ROOT/bin/fm-composer-lib.sh"
  local busy="$ROOT/bin/fm-busy-lib.sh"
  local literal_count
  # The single global UI-regex OR this fork extended with Kimi's signatures was
  # retired by the semantic busy-state contract: recorded worker state now comes
  # from an adapter's own machine-readable source, and rendered text survives
  # only as the DELIVERY guard. Kimi's share of that guard is its own signature,
  # never a borrowed one, and its recorded state stays behind the verification
  # gate below until Kimi's turn lifecycle is live-verified.
  # shellcheck source=bin/fm-composer-lib.sh
  . "$composer"
  assert_grep 'FM_DELIVERY_KIMI_BUSY_REGEX_DEFAULT' "$composer" \
    "delivery guard has no Kimi-specific busy signature"
  # shellcheck disable=SC2016 # The composer's own literal, matched verbatim.
  assert_grep 'kimi) regex=$FM_DELIVERY_KIMI_BUSY_REGEX_DEFAULT' "$composer" \
    "kimi is not routed to its own delivery busy signature"
  literal_count=$(grep -Rc '^FM_DELIVERY_KIMI_BUSY_REGEX_DEFAULT=' "$ROOT/bin" | grep -cv ':0$')
  [ "$literal_count" = 1 ] || fail "Kimi delivery signature is defined in $literal_count files, expected exactly one"
  printf '\xf0\x9f\x8c\x91 \xc2\xb7 thinking...\n' | grep -qE "$FM_DELIVERY_KIMI_BUSY_REGEX_DEFAULT" \
    || fail "Kimi busy spinner did not match its delivery signature"
  printf 'K3 thinking: max/high\n' | grep -qE "$FM_DELIVERY_KIMI_BUSY_REGEX_DEFAULT" \
    && fail "Kimi idle footer false-matched the delivery signature"
  assert_grep 'fm_busy_kimi_verified' "$busy" \
    "shared busy owner has no Kimi verification gate"
  assert_grep 'kimi-unverified' "$busy" \
    "an unverified Kimi must classify unknown, never idle"
  pass "Kimi carries its own delivery busy signature and a recorded-state verification gate"
}

test_kimi_harness_doc_marks_verified() {
  local doc="$ROOT/docs/kimi-harness.md"
  [ -f "$doc" ] || fail "docs/kimi-harness.md missing"
  assert_grep '2026-07-23' "$doc" "worker cert doc omits 2026-07-23"
  assert_grep '0.27.0' "$doc" "worker cert doc omits 0.27.0"
  assert_grep 'thinking...' "$doc" "worker cert doc omits thinking... evidence"
  assert_grep 'Running a command' "$doc" "worker cert doc omits Running a command evidence"
  assert_grep 'Interrupted by user' "$doc" "worker cert doc omits interrupt evidence"
  assert_grep '"hook_event_name":"Stop"' "$doc" \
    "worker cert doc omits Stop hook payload evidence"
  assert_grep 'stop_hook_active' "$doc" "worker cert doc omits stop_hook_active"
  pass "docs/kimi-harness.md records dated worker verification"
}

test_harness_adapters_lists_kimi_worker() {
  local skill="$ROOT/.agents/skills/harness-adapters/SKILL.md"
  local ref="$ROOT/.agents/skills/harness-adapters/references/harness/kimi.md"
  # The flat verified-worker sentence this fork extended was replaced by a
  # per-harness reference matrix, so kimi's worker facts are proved where they
  # now live: the adapter roster in the skill, and the reference that carries
  # this fork's dated worker evidence.
  assert_grep 'kimi' "$skill" "adapter roster missing kimi"
  assert_grep 'references/harness/kimi.md' "$skill" \
    "skill does not route kimi to its harness reference"
  [ -f "$ref" ] || fail "harness-adapters has no kimi reference"
  assert_grep 'docs/kimi-harness.md' "$ref" \
    "kimi reference does not cite this fork's dated worker evidence"
  assert_grep '2026-07-23' "$ref" "kimi reference omits the worker verification date"
  if grep -F 'Worker dispatch stays refused' "$ref" >/dev/null; then
    fail "harness-adapters still refuses kimi worker dispatch after certification"
  fi
  pass "harness-adapters routes kimi to a reference carrying its worker certification"
}

test_second_opinion_k3_registry() {
  local so="$ROOT/bin/fm-second-opinion.sh"
  assert_grep "REVIEWER_LABEL='k3'" "$so" "second-opinion missing k3 registry entry"
  assert_grep 'kimi-code/k3' "$so" "second-opinion k3 missing model pin"
  assert_grep '--prompt' "$so" "second-opinion k3 missing --prompt"
  pass "second-opinion registers k3 reviewer"
}

test_kimi_launch_template_in_fm_spawn
test_kimi_busy_regex_wired
test_kimi_harness_doc_marks_verified
test_harness_adapters_lists_kimi_worker
test_second_opinion_k3_registry
