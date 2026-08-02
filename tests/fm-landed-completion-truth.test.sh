#!/usr/bin/env bash
# Regression tests for the completion-truth property of firstmate's captain-facing
# landed surface: a task that JUST completed must appear in the very next report.
#
# The failure this pins was found live in the pure-upstream trial
# (data/fm-upstream-trial-verdict-v2/report.md): Bearings answered "No recent
# completions are in the current baseline" immediately after a scout finished and
# reported its results, and the recap repeated the omission. Our own surface shared
# the defect. Every landed view caps its list, so the newest-first ordering is what
# decides which rows survive the cap; when that ordering was wrong, the cap silently
# discarded the newest completion instead of the oldest.
#
# Two independent ways a just-finished completion used to vanish, both covered here:
#   1. A Done row with no completion date sorted below every dated row, so it was the
#      first row the cap dropped. This is the hand-edited / "manual" backlog path.
#   2. Completion dates are day-granularity, so same-day completions tied and the tie
#      was broken on id. A just-finished task with an alphabetically-low id lost its
#      place to same-day completions that had finished earlier. This is the DEFAULT
#      tasks-axi path, and the one that reproduces the trial failure.
#
# bin/fm-landed-lib.sh owns the ordering rule these tests hold to.
set -u

# shellcheck source=tests/lib.sh
# shellcheck disable=SC1091
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

BEARINGS="$ROOT/bin/fm-bearings-snapshot.sh"
TMP_ROOT=$(fm_test_tmproot fm-landed-truth)

command -v jq >/dev/null 2>&1 || { echo "skip: jq not found"; exit 0; }

NOW=2026-08-03T18:00:00Z
TODAY=2026-08-03

make_home() {  # <name>
  local home=$TMP_ROOT/$1
  mkdir -p "$home/state" "$home/data" "$home/projects" "$home/config"
  : > "$home/data/secondmates.md"
  printf '%s\n' "$home"
}

# Stub only the local tools the snapshot may reach for, and record any network call
# so these tests also prove the landed baseline stays local-only.
make_fakebin() {  # <home>
  local fb
  fb=$(fm_fakebin "$1")
  cat > "$fb/no-mistakes" <<'SH'
#!/usr/bin/env bash
exit 0
SH
  cat > "$fb/tmux" <<'SH'
#!/usr/bin/env bash
exit 0
SH
  cat > "$fb/gh" <<'SH'
#!/usr/bin/env bash
echo "gh $*" >> "$NET_LOG"
exit 1
SH
  cat > "$fb/gh-axi" <<'SH'
#!/usr/bin/env bash
echo "gh-axi $*" >> "$NET_LOG"
exit 1
SH
  chmod +x "$fb/no-mistakes" "$fb/tmux" "$fb/gh" "$fb/gh-axi"
  printf '%s\n' "$fb"
}

run_bearings() {  # <home> <fakebin> <args...>
  local home=$1 fakebin=$2; shift 2
  PATH="$fakebin:$PATH" FM_HOME="$home" FM_BEARINGS_NOW="$NOW" NET_LOG="$home/net.log" \
    "$BEARINGS" "$@"
}

# Write a Done section the way `tasks-axi done` actually writes it: newest completion
# PREPENDED to the top. Verified against tasks-axi 0.2.3, whose `done` inserts each
# newly completed row above the previous ones.
# Args after the header are Done rows, newest FIRST.
write_backlog() {  # <home> <row...>
  local home=$1; shift
  {
    printf '## In flight\n\n## Queued\n\n## Done\n'
    printf '%s\n' "$@"
  } > "$home/data/backlog.md"
}

done_row() {  # <id> <title> <verb> <date-or-empty>
  if [ -n "$4" ]; then
    printf -- '- [x] %s - %s (repo: firstmate) (kind: ship) (%s %s)' "$1" "$2" "$3" "$4"
  else
    printf -- '- [x] %s - %s (repo: firstmate) (kind: ship)' "$1" "$2"
  fi
}

landed_ids() {  # <json>
  printf '%s' "$1" | jq -r '.landed[].id'
}

# The exact trial failure shape on the DEFAULT backlog backend: several tasks complete
# on the same day, and the one that just finished has an id that sorts early. It must
# lead the landed list, not be cut from it.
test_just_finished_same_day_completion_leads_landed() {
  local home fakebin json ids rows i
  home=$(make_home same-day)
  rows=("$(done_row aaa-just-now "The scout that just finished" "done" "$TODAY")")
  for i in 1 2 3 4 5 6; do
    rows+=("$(done_row "zzz-earlier-$i" "Earlier same-day landing $i" "merged" "$TODAY")")
  done
  write_backlog "$home" "${rows[@]}"
  fakebin=$(make_fakebin "$home")
  json=$(run_bearings "$home" "$fakebin" --json)
  ids=$(landed_ids "$json")

  printf '%s\n' "$ids" | grep -qx 'aaa-just-now' \
    || fail "a completion recorded today vanished from landed: $ids"
  [ "$(printf '%s\n' "$ids" | head -1)" = "aaa-just-now" ] \
    || fail "the newest same-day completion must lead landed, got: $ids"
  [ ! -s "$home/net.log" ] \
    || fail "the landed baseline must make no network call, got: $(cat "$home/net.log")"
  pass "a just-finished same-day completion leads the landed baseline"
}

# The hand-edited / manual-backend path: a completion is recorded but not yet dated.
# An undated row must never be treated as the oldest thing in the fleet.
test_undated_completion_is_not_ranked_as_oldest() {
  local home fakebin json ids rows i
  home=$(make_home undated)
  rows=("$(done_row just-now "The scout that just finished" "done" "")")
  for i in 1 2 3 4 5 6; do
    rows+=("$(done_row "older-$i" "Older landing $i" "merged" "$(printf '2026-07-%02d' "$i")")")
  done
  write_backlog "$home" "${rows[@]}"
  fakebin=$(make_fakebin "$home")
  json=$(run_bearings "$home" "$fakebin" --json)
  ids=$(landed_ids "$json")

  printf '%s\n' "$ids" | grep -qx 'just-now' \
    || fail "an undated completion vanished from landed: $ids"
  [ "$(printf '%s\n' "$ids" | head -1)" = "just-now" ] \
    || fail "an undated completion must rank as recent, not oldest, got: $ids"
  pass "an undated completion is ranked as recent rather than oldest"
}

# The cap is the mechanism that turned a mis-ordering into a disappearance, so pin the
# invariant directly: whatever the cap drops, it is never the newest completion.
test_cap_drops_oldest_never_newest() {
  local home fakebin json ids count rows i
  home=$(make_home cap-drops-oldest)
  rows=("$(done_row newest-today "The task that just finished" "done" "$TODAY")")
  for i in $(seq 1 20); do
    rows+=("$(done_row "history-$i" "Historical landing $i" "merged" "$(printf '2026-07-%02d' "$i")")")
  done
  write_backlog "$home" "${rows[@]}"
  fakebin=$(make_fakebin "$home")
  json=$(run_bearings "$home" "$fakebin" --json)
  ids=$(landed_ids "$json")
  count=$(printf '%s\n' "$ids" | grep -c .)

  [ "$count" -lt 21 ] || fail "expected the landed list to be capped, got $count rows"
  [ "$(printf '%s\n' "$ids" | head -1)" = "newest-today" ] \
    || fail "the cap must never drop the newest completion, got: $ids"
  printf '%s\n' "$ids" | grep -qx 'history-1' \
    && fail "the cap must drop the OLDEST completions, but the oldest survived: $ids"
  printf '%s' "$json" | jq -e '
    [.omitted[]?.surface] | any(test("landed"))
  ' >/dev/null || fail "a capped landed list must disclose that it was capped: $json"
  pass "the landed cap drops the oldest completions and discloses the cap"
}

# A completion recorded AFTER an earlier report was generated must show up in the next
# one: the surface reads current backlog state each run and holds no prior baseline.
test_completion_recorded_after_an_earlier_report_appears_next_run() {
  local home fakebin first second rows
  home=$(make_home after-earlier-report)
  rows=("$(done_row settled "Landed a while ago" "merged" "2026-07-01")")
  write_backlog "$home" "${rows[@]}"
  fakebin=$(make_fakebin "$home")

  first=$(run_bearings "$home" "$fakebin" --json)
  landed_ids "$first" | grep -qx 'fresh-completion' \
    && fail "the first report should not yet show the later completion"

  # The task completes now, prepended exactly as tasks-axi records it.
  write_backlog "$home" \
    "$(done_row fresh-completion "Finished after the first report" "done" "$TODAY")" \
    "${rows[@]}"

  second=$(run_bearings "$home" "$fakebin" --json)
  landed_ids "$second" | grep -qx 'fresh-completion' \
    || fail "a completion recorded after an earlier report is missing: $(landed_ids "$second")"
  [ "$(landed_ids "$second" | head -1)" = "fresh-completion" ] \
    || fail "the newly recorded completion must lead landed: $(landed_ids "$second")"
  pass "a completion recorded after an earlier report appears in the next one"
}

# The same ordering must hold for work a secondmate completed in its own home, which
# reaches the captain only through the bounded cross-home roll-up.
test_secondmate_just_finished_completion_survives_rollup() {
  local home mate fakebin json ids rows i
  home=$(make_home mate-rollup)
  mate="$TMP_ROOT/mate-rollup-home"
  mkdir -p "$mate/state" "$mate/data" "$mate/config" "$mate/projects" "$mate/bin"
  printf '# Firstmate fixture\n' > "$mate/AGENTS.md"
  printf 'mate\n' > "$mate/.fm-secondmate-home"
  printf -- '- mate - fixture domain (home: %s; scope: fixture work; projects: firstmate; added 2026-07-11)\n' \
    "$mate" > "$home/data/secondmates.md"
  write_backlog "$home" "$(done_row main-old "Main home older landing" "merged" "2026-07-02")"

  rows=("$(done_row mate-just-now "Secondmate work that just finished" "done" "$TODAY")")
  for i in $(seq 1 15); do
    rows+=("$(done_row "mate-history-$i" "Secondmate history $i" "merged" "$(printf '2026-07-%02d' "$i")")")
  done
  write_backlog "$mate" "${rows[@]}"

  fakebin=$(make_fakebin "$home")
  json=$(run_bearings "$home" "$fakebin" --json)
  ids=$(landed_ids "$json")

  printf '%s\n' "$ids" | grep -qx 'mate-just-now' \
    || fail "a secondmate's just-finished completion vanished from landed: $ids"
  [ ! -s "$home/net.log" ] \
    || fail "the cross-home roll-up must make no network call, got: $(cat "$home/net.log")"
  pass "a secondmate's just-finished completion survives the cross-home roll-up"
}

test_just_finished_same_day_completion_leads_landed
test_undated_completion_is_not_ranked_as_oldest
test_cap_drops_oldest_never_newest
test_completion_recorded_after_an_earlier_report_appears_next_run
test_secondmate_just_finished_completion_survives_rollup
