#!/usr/bin/env bash
# Behavior tests for the chart room's derivation and rendering.
# The engine's `data` and `render` commands exist so this can assert the model
# and the pages without binding a socket.
set -u

# shellcheck source=tests/lib.sh
# shellcheck disable=SC1091
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

CHART="$ROOT/bin/fm-chart-room.sh"
TMP_ROOT=$(fm_test_tmproot fm-chart-room)
HOME_DIR="$TMP_ROOT/home"

command -v jq >/dev/null 2>&1 || { echo "skip: jq not found"; exit 0; }
command -v node >/dev/null 2>&1 || { echo "skip: node not found"; exit 0; }
command -v tasks-axi >/dev/null 2>&1 || { echo "skip: tasks-axi not found"; exit 0; }

mkdir -p "$HOME_DIR/data/goals" "$HOME_DIR/state" "$HOME_DIR/config" "$HOME_DIR/projects"
cp "$ROOT/.tasks.toml" "$HOME_DIR/.tasks.toml"
cat > "$HOME_DIR/data/backlog.md" <<'EOF'
## In flight

## Queued

## Done
EOF

cat > "$HOME_DIR/data/projects.md" <<'EOF'
- alpha [no-mistakes +yolo] - The charted project, at github.com/example/alpha-remote (added 2026-08-01)
- beta [local-only] - The project with no chart drawn yet (added 2026-08-02)
EOF

cat > "$HOME_DIR/data/goals/alpha.md" <<'EOF'
# Alpha
Status: DRAFT - awaiting captain approval
Aliases: alpha-legacy-name

## Port of arrival
Alpha carries the weekly run on its own.

## Goals

### g1 - The weekly run finishes without a nudge
Covers: alpha-run-*
Planned:
- A quiet week proves itself

### g2 - The numbers can be trusted
Covers: alpha-run-exception-x1

### g3 - Open to other crews
On ice: your order of 2 August - nothing outward until the run is boring.
Covers: alpha-outward-*
EOF

run_tasks() {
  (cd "$HOME_DIR" && tasks-axi "$@" >/dev/null)
}

chart() {
  FM_HOME="$HOME_DIR" FM_ROOT_OVERRIDE="$ROOT" "$CHART" "$@"
}

# Alpha: one shipped, one under way, one queued, one captain decision, one parked,
# one carrying an explicit goal token, one nothing claims, plus the exact-identity
# exception that must beat the family pattern it sits inside.
run_tasks add alpha-run-foundation-a1 "Lay the weekly run foundation" --kind ship --repo alpha
run_tasks "done" alpha-run-foundation-a1
run_tasks add alpha-run-schedule-a2 "Put the run on a schedule" --kind ship --repo alpha --start
run_tasks add alpha-run-retries-a3 "Give the run its retries" --kind ship --repo alpha
run_tasks add alpha-run-exception-x1 "Reconcile the run's numbers" --kind ship --repo alpha
run_tasks add alpha-outward-invite-o1 "Invite the first outside crew" --kind ship --repo alpha
run_tasks add alpha-decision-d1 "Answer whether the run may email people" --kind captain --repo alpha
run_tasks hold alpha-decision-d1 --reason "Sending mail is outward and irreversible, so it is the captain's word" --kind captain
run_tasks add alpha-parked-p1 "Rebuild the old importer" --kind ship --repo alpha
run_tasks hold alpha-parked-p1 --reason "Parked on captain order until the run is boring" --kind parked
run_tasks add alpha-tagged-t1 "Check every number against its source" --kind ship --repo alpha \
  --body "Some prose about the work.
goal: g2
More prose."
run_tasks add alpha-stray-s1 "A piece of work no goal claims" --kind ship --repo alpha

# The registry remote basename is a second name for the same project.
run_tasks add alpha-remote-named-r1 "Filed under the remote's name" --kind ship --repo example/alpha-remote
# The charter's declared alias is a third.
run_tasks add alpha-alias-named-l1 "Filed under the charter alias" --kind ship --repo alpha-legacy-name

# Beta has no charter and must still render.
run_tasks add beta-first-b1 "The one piece of beta work" --kind ship --repo beta

# Work whose project matches nothing on the register must stay visible.
run_tasks add gamma-orphan-g1 "Work with no project on the register" --kind ship --repo gamma

# Two identities the shadowed reader below refuses to hydrate: one whose read
# fails outright, one whose output does not parse.
run_tasks add alpha-unreadable-u1 "The record that refuses to be read" --kind ship --repo alpha
run_tasks add alpha-garbled-u2 "The record whose output makes no sense" --kind ship --repo alpha

# A reader that answers for every identity except those two, so the enumerated
# set stays the same while two of its records cannot be hydrated.
BROKEN_BIN="$TMP_ROOT/broken-bin"
mkdir -p "$BROKEN_BIN"
REAL_TASKS_AXI=$(command -v tasks-axi)
cat > "$BROKEN_BIN/tasks-axi" <<SH
#!/usr/bin/env bash
if [ "\${1:-}" = show ]; then
  case "\${2:-}" in
    alpha-unreadable-u1) printf 'tasks-axi: that record could not be read\n' >&2; exit 1 ;;
    alpha-garbled-u2) printf 'not the scalar format at all\n'; exit 0 ;;
  esac
fi
exec "$REAL_TASKS_AXI" "\$@"
SH
chmod +x "$BROKEN_BIN/tasks-axi"

MODEL="$HOME_DIR/model.json"
chart data > "$MODEL" || fail "chart room could not derive the model"

alpha() { jq -r "$1" < "$MODEL"; }

test_charter_parses_into_lanes() {
  local lanes
  lanes=$(alpha '.projects[] | select(.name=="alpha") | .lanes | length')
  [ "$lanes" = 4 ] || fail "expected three goals plus Other work, got $lanes lanes"
  [ "$(alpha '.projects[] | select(.name=="alpha") | .draft')" = true ] \
    || fail "a DRAFT charter must be reported as awaiting approval"
  [ "$(alpha '.projects[] | select(.name=="alpha") | .lanes[0].title')" = "The weekly run finishes without a nudge" ] \
    || fail "goal titles did not survive parsing"
  [ "$(alpha '.projects[] | select(.name=="alpha") | .lanes[0].planned')" = 1 ] \
    || fail "the planned bullet was not parsed"
  [ "$(alpha '.projects[] | select(.name=="alpha") | .lanes[2].onIce')" = true ] \
    || fail "the on-ice goal was not marked"
  pass "a charter parses into goals, planned lines, and an on-ice lane"
}

test_goal_token_and_covers_mapping() {
  local g2
  g2=$(alpha '.projects[] | select(.name=="alpha") | .lanes[] | select(.id=="g2") | .items | sort | join(",")')
  # alpha-tagged-t1 carries an explicit goal token; alpha-run-exception-x1 is
  # named outright by g2 and must beat g1's alpha-run-* family.
  [ "$g2" = "alpha-run-exception-x1,alpha-tagged-t1" ] \
    || fail "goal token and exact-identity mapping did not both land in g2 (got: $g2)"
  local g1
  g1=$(alpha '.projects[] | select(.name=="alpha") | .lanes[] | select(.id=="g1") | .items | length')
  [ "$g1" = 3 ] || fail "the alpha-run-* family should hold its three remaining items, got $g1"
  pass "an explicit goal token and a named exception both beat the family pattern"
}

test_unmapped_work_lands_in_a_visible_bucket() {
  local other
  other=$(alpha '.projects[] | select(.name=="alpha") | .lanes[] | select(.id=="other")')
  [ "$(printf '%s' "$other" | jq -r '.other')" = true ] || fail "the trailing lane is not the Other work lane"
  printf '%s' "$other" | jq -e '.items | index("alpha-stray-s1")' >/dev/null \
    || fail "untagged work must land in the visible Other work bucket"
  pass "work no goal claims lands in a visible bucket instead of vanishing"
}

test_captain_calls_are_separated_from_parked_work() {
  jq -e '.decisions | map(.id) | index("alpha-decision-d1")' < "$MODEL" >/dev/null \
    || fail "a captain-kind hold must appear as an answer the captain owes"
  jq -e '.decisions | map(.id) | index("alpha-parked-p1")' < "$MODEL" >/dev/null \
    && fail "parked work must not be presented as an answer the captain owes"
  jq -e '.iced | map(.id) | index("alpha-parked-p1")' < "$MODEL" >/dev/null \
    || fail "parked work must still be visible with its reason"
  [ "$(jq -r '.iced[] | select(.id=="alpha-parked-p1") | .reason' < "$MODEL")" \
    = "Parked on captain order until the run is boring" ] \
    || fail "the plain park reason must be carried through"
  pass "answers the captain owes are separated from work parked with a reason"
}

test_a_project_is_claimed_by_its_own_name_and_its_aliases() {
  local alpha_ids
  alpha_ids=$(alpha '.projects[] | select(.name=="alpha") | [.lanes[].items[]] | sort | join(",")')
  case "$alpha_ids" in
    *alpha-remote-named-r1*) : ;;
    *) fail "work filed under the registry remote name did not reach its project" ;;
  esac
  case "$alpha_ids" in
    *alpha-alias-named-l1*) : ;;
    *) fail "work filed under the charter alias did not reach its project" ;;
  esac
  jq -e '.unregistered | index("gamma-orphan-g1")' < "$MODEL" >/dev/null \
    || fail "work matching no registered project must stay visible"
  pass "a project claims its own name, its remote name, and its charter aliases"
}

test_a_project_without_a_charter_still_renders() {
  [ "$(alpha '.projects[] | select(.name=="beta") | .charter')" = false ] \
    || fail "beta should have no charter"
  [ "$(alpha '.projects[] | select(.name=="beta") | .lanes')" = null ] \
    || fail "an uncharted project must not invent lanes"
  local page
  page=$(chart render /p/beta) || fail "an uncharted project must still render"
  assert_contains "$page" "The one piece of beta work" "uncharted project page lost its work"
  assert_contains "$page" "The work" "uncharted project page should not claim to be a goal map"
  pass "a project with no charter renders flat and functional"
}

test_every_view_is_reachable_and_nothing_is_a_dead_end() {
  local home project node goal report
  home=$(chart render /) || fail "the fleet home did not render"
  assert_contains "$home" "Captain&#8217;s call" "the home does not lead with the captain's call"
  assert_contains "$home" "/p/alpha" "the home does not link to its projects"
  assert_contains "$home" "gamma-orphan-g1" "the home hides work with no project"

  project=$(chart render /p/alpha) || fail "the goal map did not render"
  assert_contains "$project" "Alpha carries the weekly run on its own." "the port of arrival is missing"
  assert_contains "$project" "waiting for your approval" "a draft chart must say it is a proposal"

  # Every row the map draws must carry the identity that opens its detail, and
  # so must every lane heading: the captain's standing complaint about the mock
  # was cards that looked live and did nothing.
  local rows dead
  rows=$(printf '%s' "$project" | grep -o '<li [^>]*>' | wc -l | tr -d ' ')
  dead=$(printf '%s' "$project" | grep -o '<li [^>]*>' | grep -cv 'data-node=\|data-expand=' || true)
  [ "$rows" -gt 0 ] || fail "the goal map drew no rows at all"
  [ "$dead" = 0 ] || fail "$dead rows on the goal map open nothing"
  dead=$(printf '%s' "$project" | grep -o '<div class="lane-head[^>]*>' | grep -cv 'data-node=' || true)
  [ "$dead" = 0 ] || fail "$dead lane headings on the goal map open nothing"

  node=$(chart render /p/alpha/node/alpha-decision-d1) || fail "a decision node did not render"
  assert_contains "$node" "Waiting on your answer" "the decision node does not say where it stands"
  goal=$(chart render "/p/alpha/node/goal:g1") || fail "a goal node did not render"
  assert_contains "$goal" "The weekly run finishes without a nudge" "the goal node lost its goal"
  assert_contains "$goal" "A quiet week proves itself" "the goal node lost its planned line"

  mkdir -p "$HOME_DIR/data/alpha-run-foundation-a1"
  printf '# Foundation\n\nWhat was found.\n' > "$HOME_DIR/data/alpha-run-foundation-a1/report.md"
  report=$(chart render /report/alpha-run-foundation-a1) || fail "a report did not render"
  assert_contains "$report" "What was found." "the report body was not rendered"
  pass "home, goal map, node, goal and report views all render with no dead rows"
}

test_unknown_addresses_refuse_plainly() {
  local missing
  missing=$(chart render /p/nowhere) && fail "an unknown project should not render as a project"
  assert_contains "$missing" "Nothing at that address" "an unknown project did not refuse plainly"
  missing=$(chart render /report/../../etc/passwd) && fail "a traversal address must not resolve"
  pass "unknown and unsafe addresses refuse with a plain page"
}

# The whole design rests on nothing hiding. A record tasks-axi list enumerated
# but whose own record cannot be read must therefore still be on the page,
# marked, and it must not take the rest of the page down with it.
test_a_record_that_cannot_be_read_stays_visible_and_marked() {
  local model home_page project_page
  model=$(PATH="$BROKEN_BIN:$PATH" chart data) \
    || fail "one record that cannot be read must not fail the whole derivation"
  printf '%s' "$model" | jq -e '.unreadable | index("alpha-unreadable-u1")' >/dev/null \
    || fail "a record whose read failed was dropped instead of kept"
  printf '%s' "$model" | jq -e '.unreadable | index("alpha-garbled-u2")' >/dev/null \
    || fail "a record whose output did not parse was dropped instead of kept"
  # Everything else still derives: the charted lanes are untouched.
  [ "$(printf '%s' "$model" | jq -r '.projects[] | select(.name=="alpha") | .lanes[] | select(.id=="g1") | .items | length')" = 3 ] \
    || fail "two unreadable records disturbed the rest of the model"

  home_page=$(PATH="$BROKEN_BIN:$PATH" chart render /) \
    || fail "the fleet home must still render when a record cannot be read"
  assert_contains "$home_page" "alpha-unreadable-u1" "a record that cannot be read vanished from the home page"
  assert_contains "$home_page" "alpha-garbled-u2" "a record that did not parse vanished from the home page"
  assert_contains "$home_page" "could not be read" "an unreadable record was not marked as such"
  assert_contains "$home_page" "UNREADABLE" "the unreadable rows carry no marker"
  assert_contains "$home_page" "gamma-orphan-g1" "one unreadable record blanked the rest of the home page"

  project_page=$(PATH="$BROKEN_BIN:$PATH" chart render /p/alpha) \
    || fail "the goal map must still render when a record cannot be read"
  assert_contains "$project_page" "Lay the weekly run foundation" \
    "one unreadable record emptied the goal map"
  pass "a record that cannot be read stays visible and marked, and the rest still renders"
}

test_the_chart_room_speaks_the_captains_language() {
  local pages term
  pages=$(chart render /; chart render /p/alpha; chart render /p/alpha/node/alpha-decision-d1)
  for term in worktree teardown yolo crewmate harness backend "no-mistakes" hold_kind in_flight \
    "fail-closed" wake watcher heartbeat brief; do
    case "$pages" in
      *"$term"*) fail "the chart room shows the captain an internal word: $term" ;;
    esac
  done
  pass "rendered pages carry no internal vocabulary"
}

test_charter_parses_into_lanes
test_goal_token_and_covers_mapping
test_unmapped_work_lands_in_a_visible_bucket
test_captain_calls_are_separated_from_parked_work
test_a_project_is_claimed_by_its_own_name_and_its_aliases
test_a_project_without_a_charter_still_renders
test_every_view_is_reachable_and_nothing_is_a_dead_end
test_unknown_addresses_refuse_plainly
test_a_record_that_cannot_be_read_stays_visible_and_marked
test_the_chart_room_speaks_the_captains_language
