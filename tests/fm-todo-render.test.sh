#!/usr/bin/env bash
# Behavior tests for the deterministic daily to-do page renderer.
#
# Contracts under test:
#   - Urgency wins the order: an outage sits above an urgent item, which sits
#     above a routine one, whatever order the ledger recorded them in.
#   - Recency breaks the tie inside a class, so a severe item arriving at 15:00
#     leads the class over one recorded at 09:00 and the page re-ranks itself
#     without anyone re-ordering it by hand.
#   - Waiting and closed work never mix into the live section: a handed-over
#     item renders under "Waiting on others" with its hand-over note, and an
#     item archived on the rendered day renders under "Cleared today"
#     with its recorded resolution.
#   - An item archived on an earlier day is history, not something that closed
#     since this morning, and never reappears.
#   - Every live line carries its own read time, taken from the ledger's
#     `updated` stamp in the configured local zone, and the page's own render
#     stamp is a separate, differently labelled time.
#   - Legacy morning prose remains a labelled historical reference; structured
#     morning actions join the queue and ledger resolutions supersede them.
#   - Nothing is invented and nothing is carried forward: a resolved item does
#     not survive into the next render of the same page.
#   - The page renders with no visual tool installed, from the tracked house
#     style templates, and a missing template is refused rather than producing
#     an unstyled page.
#   - The 30-minute read refreshes an existing page and never manufactures one:
#     a completed channel read re-ranks a page that exists, reports a page that
#     does not, and a renderer that fails never fails the read.
# shellcheck disable=SC2016
set -u

# shellcheck source=tests/lib.sh disable=SC1091
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

RENDER="$ROOT/bin/fm-todo-render.sh"
INTAKE="$ROOT/bin/fm-channel-intake.sh"
TMP_ROOT=$(fm_test_tmproot fm-todo-render-tests)

# 2026-09-10 in Europe/Amsterdam (CEST, UTC+2).
T_0900=1789023600
T_1100=1789030800
T_1500=1789045200
T_1530=1789047000
T_YESTERDAY_1500=1788958800  # 2026-09-09 15:00 local

new_home() {
  local h=$1
  mkdir -p "$h/config" "$h/state" "$h/data/channel-intake" "$h/.lavish"
  cat >"$h/config/channel-intake" <<EOF
enabled = true
timezone = Europe/Amsterdam
interval_seconds = 900
EOF
  printf 'C_BRIEF\tslack-channel\tdaily brief channel, top-level messages\n' \
    >"$h/data/channel-intake/sources.tsv"
  printf 'M_ACTION\tgmail\tmail carrying the action label only\n' \
    >>"$h/data/channel-intake/sources.tsv"
}

# Every invocation pins the clock instead of sleeping or suspending anything.
observe_at() {
  local h=$1 now=$2
  shift 2
  FM_HOME="$h" FM_ROOT_OVERRIDE="$ROOT" FM_CHANNEL_INTAKE_NOW="$now" "$INTAKE" "$@"
}

render_at() {
  local h=$1 now=$2
  shift 2
  FM_HOME="$h" FM_ROOT_OVERRIDE="$ROOT" FM_TODO_RENDER_NOW="$now" "$RENDER" "$@"
}

page_of() {
  printf '%s/.lavish/today-2026-09-10.html\n' "$1"
}

# The rendered order of a set of titles, one per line, as the page presents
# them. Read from the written page rather than from any internal call, so the
# assertion is about what the captain actually sees.
title_order() {
  local page=$1
  shift
  grep -o 'class="what">[^<]*' "$page" | sed 's/^class="what">//'
}

# The 1-based position of a fixed string in the rendered page.
line_of() {
  grep -n -F "$2" "$1" | head -n 1 | cut -d: -f1
}

test_severity_then_recency_orders_the_live_section() {
  local h page order

  h="$TMP_ROOT/ordering"
  new_home "$h"

  # Deliberately recorded in the WRONG order: the routine item is oldest and
  # first, the outage is newest and last, so nothing but the ranking can
  # produce the expected page.
  observe_at "$h" "$T_0900" observe --source C_BRIEF --ref r-routine \
    --digest a --class routine --title 'routine housekeeping' >/dev/null
  observe_at "$h" "$T_0900" observe --source M_ACTION --ref r-urgent-old \
    --digest b --class urgent --title 'older urgent ask' >/dev/null
  observe_at "$h" "$T_1500" observe --source C_BRIEF --ref r-urgent-new \
    --digest c --class urgent --title 'newer urgent ask' >/dev/null
  observe_at "$h" "$T_1500" observe --source C_BRIEF --ref r-outage \
    --digest d --class outage --title 'tap down at the customer' >/dev/null

  render_at "$h" "$T_1530" render >/dev/null
  page=$(page_of "$h")
  order=$(title_order "$page")

  [ "$order" = 'tap down at the customer
newer urgent ask
older urgent ask
routine housekeeping' ] || fail "the live section is not ranked as expected:
$order"

  pass 'the live section ranks outage above urgent above routine, newest first inside each class'
}

test_waiting_and_closed_never_mix_into_the_live_section() {
  local h page key_wait key_done key_old out

  h="$TMP_ROOT/placement"
  new_home "$h"

  out=$(observe_at "$h" "$T_0900" observe --source C_BRIEF --ref w1 \
    --digest a --class urgent --title 'quote for the dealer')
  key_wait=$(printf '%s' "$out" | awk '{ print $2 }')
  out=$(observe_at "$h" "$T_0900" observe --source M_ACTION --ref d1 \
    --digest b --class urgent --title 'invoice dispute')
  key_done=$(printf '%s' "$out" | awk '{ print $2 }')
  out=$(observe_at "$h" "$T_YESTERDAY_1500" observe --source M_ACTION --ref d0 \
    --digest c --class urgent --title 'yesterdays closed ask')
  key_old=$(printf '%s' "$out" | awk '{ print $2 }')

  observe_at "$h" "$T_1100" resolve --item "$key_wait" \
    --reason 'handed to Naomi, she answers the dealer' --waiting >/dev/null
  observe_at "$h" "$T_1100" resolve --item "$key_done" \
    --reason 'credit note sent, customer confirmed' >/dev/null
  observe_at "$h" "$T_YESTERDAY_1500" resolve --item "$key_old" \
    --reason 'closed yesterday' >/dev/null

  render_at "$h" "$T_1530" render >/dev/null
  page=$(page_of "$h")

  # Placement, not mere presence: the waiting item must sit after the waiting
  # heading, and the closed one after the closed heading.
  assert_contains "$(cat "$page")" 'handed to Naomi, she answers the dealer' \
    'the hand-over note is missing from the page'
  [ "$(line_of "$page" 'quote for the dealer')" -gt "$(line_of "$page" '<summary>Waiting on others</summary>')" ] \
    || fail 'a handed-over item did not render under Waiting on others'
  [ "$(line_of "$page" 'invoice dispute')" -gt "$(line_of "$page" '<summary>Cleared today')" ] \
    || fail 'an item archived today did not render under Closed since morning'
  assert_contains "$(cat "$page")" 'credit note sent, customer confirmed' \
    'the recorded resolution is missing from the closed table'

  # An earlier day's archive is history, not something that closed this
  # morning, so it must appear nowhere on today's page.
  assert_not_contains "$(cat "$page")" 'yesterdays closed ask' \
    'an item archived on an earlier day reappeared on todays page'

  # And the waiting item stays inside its own block rather than leaking into
  # the live table above it or the closed table below it.
  [ "$(line_of "$page" 'quote for the dealer')" -lt "$(line_of "$page" '<summary>Cleared today')" ] \
    || fail 'the waiting item did not stay inside the Waiting on others block'

  pass 'waiting, closed-today and closed-earlier items each render in exactly one place'
}

test_every_line_carries_its_own_read_time() {
  local h page

  h="$TMP_ROOT/provenance"
  new_home "$h"
  observe_at "$h" "$T_0900" observe --source C_BRIEF --ref p1 \
    --digest a --class urgent --title 'morning ask' >/dev/null
  observe_at "$h" "$T_1500" observe --source C_BRIEF --ref p2 \
    --digest b --class urgent --title 'afternoon ask' >/dev/null

  render_at "$h" "$T_1530" render >/dev/null
  page=$(page_of "$h")

  # The provenance stamp is the ledger's read time for THAT item, in the
  # configured zone - not the render time and not one shared stamp.
  assert_contains "$(cat "$page")" 'morning ask<span class="prov obs">read 09:00 CEST</span>' \
    'the morning line does not carry its own read time'
  assert_contains "$(cat "$page")" 'afternoon ask<span class="prov obs">read 15:00 CEST</span>' \
    'the afternoon line does not carry its own read time'
  # The page's own build time is separate and separately labelled.
  assert_contains "$(cat "$page")" 'rebuilt from the channel ledger at <span class="mono">15:30 CEST</span>' \
    'the page does not stamp its own render time'
  assert_contains "$(cat "$page")" 'slack-channel (C_BRIEF)' \
    'the line does not name the channel it was read on'

  pass 'each live line carries the channel and the time that item was read, separately from the render stamp'
}

test_legacy_morning_is_a_historical_reference() {
  local h page fragment

  h="$TMP_ROOT/morning-fragment"
  new_home "$h"
  observe_at "$h" "$T_0900" observe --source C_BRIEF --ref m1 \
    --digest a --class urgent --title 'live item' >/dev/null

  # Deliberately awkward content: an unclosed-looking construct, an entity, an
  # ampersand and an ordering the renderer would change if it parsed it.
  fragment="$h/.lavish/today-2026-09-10.morning.html"
  cat >"$fragment" <<'FRAG'
<div class="wrap"><header><h1>Old Today heading</h1></header>
<h2>Verified this morning<small>read by hand at 06:00</small></h2>
<div class="note"><b>Accenture Lochristi.</b> Stage read live &amp; unchanged.</div>
<ul><li>routine last</li><li>outage first</li></ul>
<h2>Pilot-partner connectivity</h2><p>Retired silence observation</p>
<h2>Calendar through Friday</h2><p>Calendar snapshot</p>
</div>
FRAG

  render_at "$h" "$T_1530" render >/dev/null
  page=$(page_of "$h")

  assert_contains "$(cat "$page")" '<summary>Earlier morning reference - not re-verified by this update</summary>' 'legacy content must be collapsed and labelled'
  assert_contains "$(cat "$page")" 'Stage read live &amp; unchanged.' 'legacy evidence must survive'
  [ "$(grep -c '<h1>' "$page")" = 1 ] || fail 'page must have one title'
  assert_not_contains "$(cat "$page")" 'Retired silence observation' 'retired connectivity must not return'
  [ "$(line_of "$page" 'Calendar snapshot')" -lt "$(line_of "$page" '<summary>Earlier morning reference')" ] || fail 'calendar should be visible below the action queue'
  pass 'legacy morning content stays in a labelled historical disclosure'

}

test_structured_morning_merges_and_ledger_supersedes() {
  local h page key out
  h="$TMP_ROOT/structured"
  new_home "$h"
  out=$(observe_at "$h" "$T_0900" observe --source C_BRIEF --ref shared --digest a --class urgent --title 'ledger action')
  key=$(printf '%s' "$out" | awk '{ print $2 }')
  cat >"$h/.lavish/today-2026-09-10.morning.html" <<'HTML'
<h2>Tickets and calendar</h2><p>Detail without duplicate actions</p>
HTML
  cat >"$h/.lavish/today-2026-09-10.morning.json" <<JSON
{"version":1,"date":"2026-09-10","actions":[
{"key":"morning-only","source":"C_BRIEF","ref":"decision","class":"urgent","title":"new morning decision","updated":$T_1100},
{"key":"$key","source":"C_BRIEF","ref":"shared","class":"urgent","title":"duplicate morning action","updated":$T_0900}]}
JSON
  render_at "$h" "$T_1530" render >/dev/null
  page=$(page_of "$h")
  [ "$(line_of "$page" 'new morning decision')" -lt "$(line_of "$page" 'ledger action')" ] || fail 'morning and ledger priorities must sort together'
  assert_not_contains "$(cat "$page")" 'duplicate morning action' 'ledger identity must win'
  observe_at "$h" "$T_1500" resolve --item "$key" --reason 'no longer needed' >/dev/null
  render_at "$h" "$T_1530" render >/dev/null
  assert_not_contains "$(cat "$page")" 'duplicate morning action' 'resolved ledger item must not reappear from morning'
  [ "$(line_of "$page" 'no longer needed')" -gt "$(line_of "$page" '<summary>Cleared today')" ] || fail 'cleared reason must be in closed footer'
  cp "$page" "$h/previous.html"
  printf '{invalid' >"$h/.lavish/today-2026-09-10.morning.json"
  if render_at "$h" "$T_1530" render >/dev/null 2>&1; then fail 'invalid metadata must refuse'; fi
  cmp -s "$page" "$h/previous.html" || fail 'failed composition must preserve page'
  pass 'morning actions merge, resolutions win, and invalid metadata preserves the page'
}

test_fleet_snapshots_group_without_accumulating() {
  local h page out first second
  h="$TMP_ROOT/fleet"
  new_home "$h"
  printf 'FLEET\ttelemetry-fleet-alerts\tfault conditions\n' >>"$h/data/channel-intake/sources.tsv"
  out=$(observe_at "$h" "$T_0900" observe --source FLEET --condition b14 --count 10 --units 'Old 867684070443686' --digest first)
  first=$(printf '%s' "$out" | awk '{ print $2 }')
  out=$(observe_at "$h" "$T_1500" observe --source FLEET --condition b14 --count 11 --units 'Newest 867684070443687' --digest second)
  second=$(printf '%s' "$out" | awk '{ print $2 }')
  [ "$first" = "$second" ] || fail 'successive snapshots must update one stable identity'
  observe_at "$h" "$T_1500" observe --source FLEET --condition freezing --count 58 --units 'Cold 867684070443688' --digest cold >/dev/null
  observe_at "$h" "$T_0900" observe --source FLEET --ref legacy-read --class routine --title 'Fleet: 9 active B.14 units, 57 coolers under 1 C (first read)' --digest legacy >/dev/null
  render_at "$h" "$T_1530" render >/dev/null
  page=$(page_of "$h")
  [ "$(grep -c 'class="watch-line"' "$page")" = 2 ] || fail 'fleet must have one line per condition'
  assert_contains "$(cat "$page")" '11 units at 15:00 CEST' 'use newest full count, never sum reads'
  assert_contains "$(cat "$page")" 'Newest 867684070443687' 'newest unit missing'
  assert_not_contains "$(cat "$page")" 'Old 867684070443686' 'old unit must not compete with current snapshot'
  [ "$(line_of "$page" 'Newest 867684070443687')" -gt "$(line_of "$page" '<h2>Watching')" ] || fail 'fleet condition leaked into needs-you'
  if observe_at "$h" "$T_1500" observe --source FLEET --condition offline --count 1 --units example --digest bad >/dev/null 2>&1; then fail 'silence conditions must refuse'; fi
  pass 'fleet snapshots group by condition with newest counts and units'
}

test_nothing_is_carried_forward_between_renders() {
  local h page out key

  h="$TMP_ROOT/no-carry-forward"
  new_home "$h"
  out=$(observe_at "$h" "$T_0900" observe --source C_BRIEF --ref c1 \
    --digest a --class urgent --title 'ask that gets answered')
  key=$(printf '%s' "$out" | awk '{ print $2 }')
  render_at "$h" "$T_1100" render >/dev/null
  page=$(page_of "$h")
  assert_contains "$(cat "$page")" 'ask that gets answered' \
    'the open item never rendered in the first place'

  observe_at "$h" "$T_1500" resolve --item "$key" --reason 'answered in the thread' >/dev/null
  render_at "$h" "$T_1530" render >/dev/null

  # It may appear in the closed table, but never again as open work.
  [ "$(line_of "$page" 'ask that gets answered')" -gt "$(line_of "$page" '<summary>Cleared today')" ] \
    || fail 'a resolved item survived into the live section of the next render'

  # An empty ledger renders an honest empty page rather than the previous one.
  observe_at "$h" "$T_1500" resolve --item "$key" --reason 'again' >/dev/null 2>&1 || true
  rm -f "$h/data/channel-intake/archive"/*
  render_at "$h" "$T_1530" render >/dev/null
  assert_not_contains "$(cat "$page")" 'ask that gets answered' \
    'the renderer read content back from the page it had already written'
  assert_contains "$(cat "$page")" 'Nothing open.' \
    'an empty ledger did not render as an empty page'

  pass 'the page is rebuilt from the ledger every time, so nothing is invented or carried forward'
}

test_house_style_comes_from_the_tracked_templates() {
  local h page out code

  h="$TMP_ROOT/house-style"
  new_home "$h"
  observe_at "$h" "$T_0900" observe --source C_BRIEF --ref s1 \
    --digest a --class outage --title 'tap down' >/dev/null
  render_at "$h" "$T_1530" render >/dev/null
  page=$(page_of "$h")

  # A complete, self-contained page: the house variables, the severity pills
  # and the provenance legend, with nothing fetched and no tool running.
  assert_contains "$(cat "$page")" '<!doctype html>' 'the page has no document type'
  assert_contains "$(cat "$page")" '--accent:#0b4f8a' 'the house palette is missing'
  assert_contains "$(cat "$page")" '<span class="pill bad">outage</span>' \
    'the severity pill is missing from the outage row'
  assert_contains "$(cat "$page")" 'could not be confirmed from any source available here' \
    'the provenance legend is missing'
  assert_contains "$(cat "$page")" '<title>Today - Thursday 10 September 2026</title>' \
    'the page title was not filled in'

  # A missing template is refused, never silently rendered unstyled.
  out=$(FM_HOME="$h" FM_ROOT_OVERRIDE="$ROOT" FM_TODO_RENDER_NOW="$T_1530" \
    FM_TODO_TEMPLATE_DIR="$TMP_ROOT/no-such-templates" "$RENDER" render 2>&1) \
    && code=0 || code=$?
  expect_code 2 "$code" 'a missing house-style template still rendered a page'
  assert_contains "$out" 'house-style head template is missing' \
    'the refusal did not name the missing template'

  pass 'the page renders from the tracked house-style templates with no visual tool installed'
}

test_completed_read_refreshes_an_existing_page_only() {
  local h page out order code

  h="$TMP_ROOT/refresh-wiring"
  new_home "$h"
  observe_at "$h" "$T_0900" observe --source C_BRIEF --ref f1 \
    --digest a --class routine --title 'routine item' >/dev/null

  # No page written yet: a completed read says so and manufactures nothing.
  out=$(observe_at "$h" "$T_0900" complete --source C_BRIEF --checkpoint cp1)
  assert_contains "$out" 'nothing refreshed' 'a read with no page did not report it'
  assert_absent "$(page_of "$h")" 'a background read manufactured a page nobody wrote'

  # With the morning page on disk, the 15:00 outage reaches the top on the
  # read that recorded it, with no second command and no model call.
  render_at "$h" "$T_1100" render >/dev/null
  page=$(page_of "$h")
  observe_at "$h" "$T_1500" observe --source C_BRIEF --ref f2 \
    --digest b --class outage --title 'tap down at the customer' >/dev/null
  out=$(observe_at "$h" "$T_1530" complete --source C_BRIEF --checkpoint cp2)
  assert_contains "$out" 'rendered at 15:30 CEST' 'the completed read did not refresh the page'
  order=$(title_order "$page")
  [ "$order" = 'tap down at the customer
routine item' ] || fail "the refresh did not re-rank the page:
$order"

  # A renderer that fails is reported and never fails the read itself. The
  # failure is a real one - the house-style templates are pointed somewhere
  # they are not - rather than a stubbed exit code.
  out=$(FM_HOME="$h" FM_ROOT_OVERRIDE="$ROOT" FM_CHANNEL_INTAKE_NOW="$T_1530" \
    FM_TODO_TEMPLATE_DIR="$TMP_ROOT/no-such-templates" \
    "$INTAKE" complete --source C_BRIEF --checkpoint cp3) && code=0 || code=$?
  expect_code 0 "$code" 'a failing renderer failed the completed read'
  assert_contains "$out" 'read complete, checkpoint cp3' \
    'the read itself was not reported after a failing renderer'
  assert_contains "$out" 'the day page was not refreshed' \
    'a failing renderer was not reported'
  [ "$(grep -c 'checkpoint=cp3' "$h/data/channel-intake/sources/C_BRIEF/state")" -ge 1 ] \
    || fail 'the checkpoint the read advanced was lost when the render failed'

  pass 'a completed read refreshes an existing page, never manufactures one, and never fails on the render'
}

# A ticket table read once in the morning goes stale within the hour, and a
# closed ticket presented as open is the exact failure this guards.
test_live_tickets_replace_the_frozen_table_and_raise_waiting_on_us() {
  local h page
  h="$TMP_ROOT/live-tickets"
  new_home "$h"
  observe_at "$h" "$T_1100" observe --source C_BRIEF --ref t1 \
    --digest d --class obligation --title 'routine item' >/dev/null

  # The morning fragment carries its own frozen copy of the table.
  cat >"$h/.lavish/today-2026-09-10.morning.html" <<'EOF'
<section class="morning-details">
  <h2>Your open tickets</h2>
  <p class="sub">Ten tickets carry you as owner, read at 09:48.</p>
  <div class="tablewrap"><table><tbody><tr><td>frozen ticket row</td></tr></tbody></table></div>
  <h2>Calendar</h2>
  <p>nothing booked</p>
</section>
EOF
  cat >"$h/.lavish/today-2026-09-10.morning.json" <<'JSON'
{"version":1,"date":"2026-09-10","actions":[]}
JSON

  cat >"$h/data/channel-intake/tickets.json" <<EOF
{"version":1,"read_at":$T_1100,"tickets":[
 {"id":"111","subject":"customer is waiting","stage":"Waiting on us","last_in":"10 Sep 10:00","last_out":"-","link":"https://example.invalid/111"},
 {"id":"222","subject":"sitting with the customer","stage":"Waiting on contact","last_in":"9 Sep 09:00","last_out":"9 Sep 10:00"}]}
EOF

  render_at "$h" "$T_1500" render >/dev/null
  page=$(page_of "$h")

  assert_contains "$(cat "$page")" 'customer is waiting' \
    'a ticket waiting on us never reached the page'
  assert_contains "$(cat "$page")" 'sitting with the customer' \
    'the live ticket table was not rendered'
  [ "$(grep -c 'frozen ticket row' "$page")" -eq 0 ] \
    || fail 'the frozen morning ticket table survived beside the live one'
  [ "$(grep -c '<h2>Your open tickets</h2>' "$page")" -eq 1 ] \
    || fail 'the page carries more than one ticket table'
  assert_contains "$(cat "$page")" 'nothing booked' \
    'dropping the frozen ticket table took the rest of the morning fragment with it'

  # Only the ticket the customer is waiting on is an action; the other stays
  # in the table.
  [ "$(line_of "$page" 'customer is waiting')" -lt "$(line_of "$page" 'Your open tickets')" ] \
    || fail 'the waiting-on-us ticket was not raised above the table'

  # A file stamped in the future is not a read that happened, so the morning
  # snapshot must stand rather than a fabricated live table.
  cat >"$h/data/channel-intake/tickets.json" <<EOF
{"version":1,"read_at":$((T_1500 + 3600)),"tickets":[{"id":"333","subject":"from the future","stage":"Waiting on us"}]}
EOF
  render_at "$h" "$T_1500" render >/dev/null
  [ "$(grep -c 'from the future' "$page")" -eq 0 ] \
    || fail 'a future-dated ticket file was presented as a live read'
  assert_contains "$(cat "$page")" 'frozen ticket row' \
    'the morning snapshot was dropped even though no live read was usable'

  pass 'a live ticket read replaces the frozen table and raises waiting-on-us items'
}

test_severity_then_recency_orders_the_live_section
test_waiting_and_closed_never_mix_into_the_live_section
test_every_line_carries_its_own_read_time
test_legacy_morning_is_a_historical_reference
test_structured_morning_merges_and_ledger_supersedes
test_fleet_snapshots_group_without_accumulating
test_nothing_is_carried_forward_between_renders
test_house_style_comes_from_the_tracked_templates
test_completed_read_refreshes_an_existing_page_only
test_live_tickets_replace_the_frozen_table_and_raise_waiting_on_us
