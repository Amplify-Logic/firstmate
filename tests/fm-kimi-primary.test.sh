#!/usr/bin/env bash
# Kimi primary detection and primary/worker role separation regressions.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

# A fake ps that reports a bash ancestor terminating at pid 1, so the ancestry
# layer proves nothing and only the marker layer can answer. Marker-vs-ancestry
# precedence itself is pinned by tests/fm-harness-precedence.test.sh; this suite
# asserts only that the Kimi launch marker beats INHERITED runtime markers, which
# is what it was written for and the one thing a live contradicting ancestor
# would otherwise mask.
blind_ancestry_bin() {  # <dir>
  local fakebin
  fakebin=$(fm_fakebin "$1")
  cat > "$fakebin/ps" <<'SH'
#!/usr/bin/env bash
case "$*" in
  *'ppid='*) printf '%s\n' 1 ;;
  *) printf '%s\n' bash ;;
esac
SH
  chmod +x "$fakebin/ps"
  printf '%s\n' "$fakebin"
}

test_stable_primary_marker_wins() {
  local out config blind
  blind=$(blind_ancestry_bin "$(fm_test_tmproot fm-kimi-harness-blind)")
  out=$(PATH="$blind:$PATH" FM_PRIMARY_HARNESS=kimi CLAUDECODE=1 "$ROOT/bin/fm-harness.sh")
  [ "$out" = kimi ] || fail "stable Kimi child marker did not win over inherited runtime markers (got $out)"
  config=$(fm_test_tmproot fm-kimi-harness-config)
  mkdir -p "$config"
  printf 'codex\n' > "$config/crew-harness"
  out=$(FM_PRIMARY_HARNESS=kimi FM_CONFIG_OVERRIDE="$config" "$ROOT/bin/fm-harness.sh" crew)
  [ "$out" = codex ] || fail "configured worker runtime was coupled to the Kimi primary (got $out)"
  pass "fm-harness: stable Kimi marker detects the primary while configured worker selection stays separate"
}

test_worker_set_includes_kimi() {
  local usage
  usage=$(sed -n '1,200p' "$ROOT/bin/fm-spawn.sh")
  assert_contains "$usage" 'kimi' \
    "documented verified worker set missing kimi"
  # The isolated KIMI_CODE_HOME this fork once rendered was retired with the
  # shared spawn owner's Kimi rewrite; tests/fm-kimi-worker.test.sh owns the
  # current launch contract. What stays pinned here is only that the worker
  # launch exists and is not coupled to the primary profile.
  assert_grep "kimi) printf '%s' '__KIMIBIN__" \
    "$ROOT/bin/fm-spawn.sh" \
    "fm-spawn missing kimi worker launch template"
  pass "fm-spawn: Kimi is a verified worker while primary detection stays separate"
}

test_stable_primary_marker_wins
test_worker_set_includes_kimi
