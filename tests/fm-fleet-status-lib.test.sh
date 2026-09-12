#!/usr/bin/env bash
# Fleet-field supply regressions: bin/fm-fleet-status-lib.sh.
#
# These cases never call bin/fm-crew-state.sh. A fixture reader stands in for it,
# so the suite exercises the folding, caching, and refusal rules without touching
# a crew, a pane, or the validation pipeline.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

TMP_ROOT=$(fm_test_tmproot fm-fleet-status-lib)
STATE="$TMP_ROOT/state"
FLEET_FIX="$TMP_ROOT/fleet"
BINDIR="$TMP_ROOT/bin"
mkdir -p "$STATE" "$FLEET_FIX" "$BINDIR"

ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)

cat > "$BINDIR/fake-crew-state" <<'SH'
#!/usr/bin/env bash
[ -z "${FM_FLEET_TEST_READER_FAIL:-}" ] || exit 1
[ -f "$FM_FLEET_FIXTURE/$1" ] || exit 1
cat "$FM_FLEET_FIXTURE/$1"
SH
chmod +x "$BINDIR/fake-crew-state"

# A reader that records every id it was asked about, so a case can prove the
# canonical reader was not consulted at all.
cat > "$BINDIR/counting-crew-state" <<'SH'
#!/usr/bin/env bash
printf '%s\n' "$1" >> "$FM_FLEET_TEST_CALLS"
[ -f "$FM_FLEET_FIXTURE/$1" ] || exit 1
cat "$FM_FLEET_FIXTURE/$1"
SH
chmod +x "$BINDIR/counting-crew-state"

export FM_FLEET_FIXTURE="$FLEET_FIX"

task() {  # <id> <kind> <canonical line>
  fm_write_meta "$STATE/$1.meta" "kind=$2"
  printf '%s\n' "$3" > "$FLEET_FIX/$1"
}

reset_state() {
  rm -f "$STATE"/*.meta "$STATE"/.status-fleet-state* 2>/dev/null || true
  rm -f "$FLEET_FIX"/* 2>/dev/null || true
}

counts() {  # [env assignments already exported by the caller]
  bash -c '
    . "$1/bin/fm-fleet-status-lib.sh"
    fm_fleet_status_counts "$2"
  ' _ "$ROOT" "$STATE"
}

# --- folding ---------------------------------------------------------------

test_canonical_states_fold_into_the_five_fields() {
  local out
  reset_state
  task busy crew 'state: working · source: pane · harness busy'
  task pipe crew 'state: working · source: run-step · run ci'
  task wait crew 'state: paused · source: status-log · upstream release'
  task gate crew 'state: parked · source: run-step · awaiting approval'
  task stuck crew 'state: blocked · source: status-log · needs a credential'
  task broke crew 'state: failed · source: run-step · run failed'
  task shipped crew 'state: done · source: run-step · checks passed'
  task ghost crew 'state: unknown · source: none · backend target gone'
  task mate secondmate 'state: working · source: pane · harness busy'

  out=$(FM_FLEET_STATE_NO_CACHE=1 FM_FLEET_STATE_READER="$BINDIR/fake-crew-state" counts)
  # records working validating paused attention known
  [ "$out" = $'8\t1\t1\t1\t3\t1' ] \
    || fail "canonical states did not fold into the documented fields: $(printf '%s' "$out" | tr '\t' ' ')"
  pass "fleet status: canonical states fold into records, working, validating, paused and attention"
}

# The whole point of the change: a meta file is a record, and a record is not a
# worker. Second mates are direct reports, not work items, and stay out entirely.
test_records_are_counted_apart_from_live_workers() {
  local out records working
  reset_state
  task live crew 'state: working · source: pane · harness busy'
  task gone1 crew 'state: unknown · source: none · backend target gone: w8:pV'
  task gone2 crew 'state: unknown · source: none · no metadata'
  task gone3 crew 'state: done · source: run-step · checks passed'

  out=$(FM_FLEET_STATE_NO_CACHE=1 FM_FLEET_STATE_READER="$BINDIR/fake-crew-state" counts)
  records=$(printf '%s' "$out" | cut -f1)
  working=$(printf '%s' "$out" | cut -f2)
  [ "$records" = 4 ] || fail "four task records were not all counted as records: $records"
  [ "$working" = 1 ] || fail "task records were counted as running workers: $working"
  pass "fleet status: task records are counted apart from live workers"
}

# --- refusals --------------------------------------------------------------

test_an_incomplete_fold_is_refused_rather_than_published_short() {
  local out
  reset_state
  task one crew 'state: working · source: pane · harness busy'
  task two crew 'state: working · source: pane · harness busy'
  rm -f "$FLEET_FIX/two"

  out=$(FM_FLEET_STATE_NO_CACHE=1 FM_FLEET_STATE_READER="$BINDIR/fake-crew-state" counts)
  [ "$out" = $'2\t0\t0\t0\t0\t0' ] \
    || fail "a fold the reader could not complete was published anyway: $(printf '%s' "$out" | tr '\t' ' ')"
  pass "fleet status: an incomplete fold is refused instead of reported as a quieter fleet"
}

test_a_broken_reader_never_becomes_an_idle_fleet() {
  local out known
  reset_state
  task one crew 'state: working · source: pane · harness busy'

  out=$(FM_FLEET_STATE_NO_CACHE=1 FM_FLEET_TEST_READER_FAIL=1 \
    FM_FLEET_STATE_READER="$BINDIR/fake-crew-state" counts)
  known=$(printf '%s' "$out" | cut -f6)
  [ "$known" = 0 ] || fail "a reader that answers nothing was treated as a real reading"
  out=$(FM_FLEET_STATE_NO_CACHE=1 FM_FLEET_STATE_READER="$TMP_ROOT/not-a-reader" counts)
  known=$(printf '%s' "$out" | cut -f6)
  [ "$known" = 0 ] || fail "a missing reader was treated as a real reading"
  pass "fleet status: a broken or missing canonical reader reports unknown, never an idle fleet"
}

# A reading is about the fleet it was taken for. Applying it to a different set
# of tasks would report, with full confidence, numbers for work that is not
# there any more.
test_a_reading_for_another_fleet_is_discarded() {
  local out known
  reset_state
  task one crew 'state: working · source: pane · harness busy'
  out=$(FM_FLEET_STATE_NOW=1000 FM_FLEET_STATE_TTL=600 \
    FM_FLEET_STATE_READER="$BINDIR/fake-crew-state" counts)
  # Prime the cache directly, the way a completed refresh would.
  bash -c '
    . "$1/bin/fm-fleet-status-lib.sh"
    _fm_fleet_collect "$2" 1000 "$3" > "$2/.status-fleet-state"
  ' _ "$ROOT" "$STATE" "$BINDIR/fake-crew-state"
  out=$(FM_FLEET_STATE_NOW=1010 FM_FLEET_STATE_TTL=600 FM_FLEET_STATE_MAX_AGE=600 \
    FM_FLEET_STATE_READER="$BINDIR/fake-crew-state" counts)
  known=$(printf '%s' "$out" | cut -f6)
  [ "$known" = 1 ] || fail "a fresh cached reading for this fleet was not used: $out"

  task two crew 'state: paused · source: status-log · upstream release'
  out=$(FM_FLEET_STATE_NOW=1010 FM_FLEET_STATE_TTL=600 FM_FLEET_STATE_MAX_AGE=600 \
    FM_FLEET_STATE_READER="$BINDIR/fake-crew-state" counts)
  known=$(printf '%s' "$out" | cut -f6)
  [ "$known" = 0 ] || fail "a reading taken before the fleet changed was applied to the new fleet"
  pass "fleet status: a cached reading is discarded once the fleet it covered has changed"
}

test_a_reading_that_has_aged_out_is_discarded() {
  local out known
  reset_state
  task one crew 'state: working · source: pane · harness busy'
  bash -c '
    . "$1/bin/fm-fleet-status-lib.sh"
    _fm_fleet_collect "$2" 1000 "$3" > "$2/.status-fleet-state"
  ' _ "$ROOT" "$STATE" "$BINDIR/fake-crew-state"

  out=$(FM_FLEET_STATE_NOW=1100 FM_FLEET_STATE_TTL=600 FM_FLEET_STATE_MAX_AGE=300 \
    FM_FLEET_STATE_READER="$BINDIR/fake-crew-state" counts)
  [ "$(printf '%s' "$out" | cut -f6)" = 1 ] \
    || fail "a reading inside its maximum age was discarded: $out"

  out=$(FM_FLEET_STATE_NOW=2000 FM_FLEET_STATE_TTL=600 FM_FLEET_STATE_MAX_AGE=300 \
    FM_FLEET_STATE_READER="$BINDIR/fake-crew-state" counts)
  known=$(printf '%s' "$out" | cut -f6)
  [ "$known" = 0 ] || fail "a reading past its maximum age was still reported as current"
  pass "fleet status: a reading past its maximum age is discarded rather than shown as current"
}

test_a_malformed_cached_reading_is_refused() {
  local out known
  reset_state
  task one crew 'state: working · source: pane · harness busy'
  printf '1000\tnot-a-number\t0\t0\t0\tsig\n' > "$STATE/.status-fleet-state"
  out=$(FM_FLEET_STATE_NOW=1010 FM_FLEET_STATE_TTL=600 FM_FLEET_STATE_MAX_AGE=600 \
    FM_FLEET_STATE_READER="$BINDIR/fake-crew-state" counts)
  known=$(printf '%s' "$out" | cut -f6)
  [ "$known" = 0 ] || fail "a malformed cached reading was rendered as a real one"
  pass "fleet status: a malformed cached reading is refused"
}

# --- cost ------------------------------------------------------------------

# The renderer draws once a second and the canonical reader costs about a second
# per task, so the frame must never be the thing that calls it.
test_a_frame_never_calls_the_canonical_reader() {
  local calls
  reset_state
  task one crew 'state: working · source: pane · harness busy'
  task two crew 'state: paused · source: status-log · upstream release'
  export FM_FLEET_TEST_CALLS="$TMP_ROOT/calls"
  : > "$FM_FLEET_TEST_CALLS"

  # A claimed refresh is already in flight, so this frame may not start one.
  printf '' > "$STATE/.status-fleet-state.refreshing"
  FM_FLEET_STATE_NOW=$(date +%s) FM_FLEET_STATE_TTL=600 FM_FLEET_STATE_WARM_TTL=600 \
    FM_FLEET_STATE_READER="$BINDIR/counting-crew-state" counts >/dev/null

  calls=$(wc -l < "$FM_FLEET_TEST_CALLS" | tr -d ' ')
  [ "$calls" = 0 ] \
    || fail "a single frame consulted the canonical reader $calls times; the frame must only read the cache"
  unset FM_FLEET_TEST_CALLS
  pass "fleet status: a frame reads the cache and never calls the canonical reader itself"
}

test_only_one_refresh_is_claimed_at_a_time() {
  local now
  reset_state
  task one crew 'state: working · source: pane · harness busy'
  now=$(date +%s)
  bash -c '
    . "$1/bin/fm-status-cache-lib.sh"
    fm_status_claim_refresh "$2" "$3" 600 || exit 1
    fm_status_claim_refresh "$2" "$3" 600 && exit 1
    # A claim older than its window is reclaimable, so a refresher that died
    # without writing cannot wedge the field at unknown forever.
    fm_status_claim_refresh "$2" "$(($3 + 601))" 600 || exit 1
    exit 0
  ' _ "$ROOT" "$STATE/claim" "$now" \
    || fail "the refresh claim did not serialize one refresher and then release"
  pass "fleet status: exactly one refresh is claimed at a time, and a dead claim is reclaimable"
}

test_canonical_states_fold_into_the_five_fields
test_records_are_counted_apart_from_live_workers
test_an_incomplete_fold_is_refused_rather_than_published_short
test_a_broken_reader_never_becomes_an_idle_fleet
test_a_reading_for_another_fleet_is_discarded
test_a_reading_that_has_aged_out_is_discarded
test_a_malformed_cached_reading_is_refused
test_a_frame_never_calls_the_canonical_reader
test_only_one_refresh_is_claimed_at_a_time
