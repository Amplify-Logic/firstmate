#!/usr/bin/env bash
# Behavior tests for the daily to-do's durable item store.
#
# Contracts under test, each through bin/fm-todo.sh and the rendered page:
#   - Verification is its own fact: an unchanged re-read and a re-sync never
#     renew it, a sweep downgrades an older check to "not re-checked since",
#     and an explicit verify makes the line current again.
#   - A page command is durable: `done` survives repeated syncs, the next
#     morning and a re-asserted sidecar, and a meaningful new ask resurfaces
#     exactly once with its reason.
#   - An edit after a ledger resolution (edited_digest) reopens the item once.
#   - A stale page revision is refused, a repeated command is harmless, and
#     `you` stays a requested handoff until firstmate accepts it.
#   - Missing or corrupt input closes nothing; a released hold closes only its
#     own item; one ask seen twice is one item, two asks stay two.
#   - A snooze ends on its day without claiming a fresh check.
#   - Only a named, fulfilled close counts as handled without you.
#   - `reopen` brings a handed-over item back to the captain's lane and
#     refuses an item that is already open.
#   - Captain holds no read made current collapse into their own capped fold
#     below the live decisions, and the decisions tile keeps them apart.
#   - Routine activity older than the sweep stays on the page in the same
#     labelled "not re-checked" fold the sections use, capped at ten rows.
#   - A routine item the ledger no longer carries closes as superseded without
#     reaching the Closed since evidence, and an unreadable ledger closes nothing.
#   - The held fold shows the oldest holds first, by the backlog's since date.
#   - Sync prunes a retired routine record thirty days on, and nothing else:
#     a command tombstone and a closed obligation both survive it.
#   - A routine line the captain marked with mine or park is never retired by
#     the intake's absence, so it is never pruned either. A system reopen note
#     is not such a mark: a revived routine thread still retires and prunes.
# shellcheck disable=SC2016
set -u

# shellcheck source=tests/lib.sh disable=SC1091
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

TODO="$ROOT/bin/fm-todo.sh"
RENDER="$ROOT/bin/fm-todo-render.sh"
INTAKE="$ROOT/bin/fm-channel-intake.sh"
TMP_ROOT=$(fm_test_tmproot fm-todo-tests)

# 2026-09-10 in Europe/Amsterdam (CEST, UTC+2).
T_0900=1789023600
T_1000=1789027200
T_1030=1789029000
T_1100=1789030800
T_1500=1789045200
T_NEXT_0900=$((T_0900 + 86400))
T_NEXT_1000=$((T_1000 + 86400))

new_home() {
  local h=$1
  mkdir -p "$h/config" "$h/data/channel-intake" "$h/.lavish"
  printf 'enabled = true\ntimezone = Europe/Amsterdam\ninterval_seconds = 900\n' >"$h/config/channel-intake"
  printf 'C_BRIEF\tslack-channel\tdaily brief channel\n' >"$h/data/channel-intake/sources.tsv"
  : >"$h/backlog.md"
}

intake_at() {
  local h=$1 now=$2
  shift 2
  FM_HOME="$h" FM_ROOT_OVERRIDE="$ROOT" FM_CHANNEL_INTAKE_NOW="$now" "$INTAKE" "$@"
}

todo_at() {
  local h=$1 now=$2
  shift 2
  FM_HOME="$h" FM_ROOT_OVERRIDE="$ROOT" FM_TODO_NOW="$now" \
    FM_TODO_BACKLOG_OVERRIDE="$h/backlog.md" "$TODO" "$@"
}

render_at() {
  local h=$1 now=$2
  shift 2
  FM_HOME="$h" FM_ROOT_OVERRIDE="$ROOT" FM_TODO_RENDER_NOW="$now" \
    FM_TODO_BACKLOG_OVERRIDE="$h/backlog.md" "$RENDER" render "$@" >/dev/null
}

page() {
  cat "$1/.lavish/today-$2.html"
}

# The id, state or revision of the one item whose title contains $2.
field_of() {
  local h=$1 title=$2 col=$3
  todo_at "$h" "$T_1500" list | awk -F '\t' -v t="$title" -v c="$col" 'index($5, t) { print $c; exit }'
}

sidecar() {
  local h=$1 day=$2 body=$3
  printf '{"version":2,"date":"%s","actions":[%s]}\n' "$day" "$body" >"$h/.lavish/today-$day.morning.json"
}

test_a_retired_ledger_record_closes_its_routine_item() {
  local h keep drop out
  h="$TMP_ROOT/retired"
  new_home "$h"
  keep=$(intake_at "$h" "$T_0900" observe --source C_BRIEF --ref keep --digest a --title 'channel stayed chatty' | awk '{ print $2 }')
  drop=$(intake_at "$h" "$T_0900" observe --source C_BRIEF --ref gone --digest b --title 'yesterday small talk' | awk '{ print $2 }')
  render_at "$h" "$T_0900"
  [ "$(field_of "$h" 'small talk' 2)" = open ] || fail 'a routine record did not fold in as an open item'
  # What the intake does once a routine record passes its brief horizon.
  mkdir -p "$h/data/channel-intake/inactive"
  mv "$h/data/channel-intake/items/$drop" "$h/data/channel-intake/inactive/$drop"
  render_at "$h" "$T_1000"
  [ "$(field_of "$h" 'small talk' 2)" = closed ] || fail 'a retired routine record left its item open forever'
  [ "$(field_of "$h" 'stayed chatty' 2)" = open ] || fail 'retiring one record closed another'
  out=$(page "$h" 2026-09-10)
  assert_contains "$(grep -h . "$h/data/todo/items/"*.json)" '"reason": "superseded"' \
    'the retirement closure is not labelled superseded'
  assert_not_contains "$out" 'yesterday small talk' 'a retired routine line still renders on the page'
  # Routine chatter the intake dropped was never an ask, so it is not a closure to show.
  assert_not_contains "$out" 'the intake retired it as routine' 'a retirement reached the Closed since evidence table'
  assert_contains "$out" '<div class="n">0</div><div class="l">Closed since' \
    'a retirement was counted as something closed for you'
  # An unreadable ledger is not an absence: it closes nothing.
  mv "$h/data/channel-intake" "$h/intake.away"
  render_at "$h" "$T_1100"
  [ "$(field_of "$h" 'stayed chatty' 2)" = open ] || fail 'a missing ledger closed a live item'
  mv "$h/intake.away" "$h/data/channel-intake"
  [ "$(grep -c '"reason": "superseded"' "$h/data/todo/journal")" = 1 ] || fail 'the retirement closed more than once'
  pass 'a retired routine record closes its item as superseded and an unreadable ledger closes nothing'
}

test_routine_fold_is_capped_like_the_held_one() {
  local h out n i
  h="$TMP_ROOT/chatter"
  new_home "$h"
  i=1
  while [ "$i" -le 12 ]; do
    intake_at "$h" "$T_0900" observe --source C_BRIEF --ref "chat-$i" --digest "d$i" \
      --title "channel chatter $(printf '%02d' "$i")" >/dev/null
    i=$((i + 1))
  done
  todo_at "$h" "$T_1000" sweep-start >/dev/null
  render_at "$h" "$T_1030"
  out=$(page "$h" 2026-09-10)
  assert_contains "$out" '<summary>12 not re-checked in this build, oldest 10 shown</summary>' \
    'the capped fold still claims every line shows its last check'
  assert_contains "$out" '2 more not re-checked, not shown here.' 'the routine fold is not capped with a count of the rest'
  n=$(printf '%s\n' "$out" | grep -c '<td class="what">channel chatter')
  [ "$n" = 10 ] || fail "the routine fold rendered $n rows, not ten"
  pass 'the routine not re-checked fold is capped at ten rows and a count of the rest'
}

test_held_fold_shows_the_oldest_holds_first() {
  local h out order i
  h="$TMP_ROOT/oldest"
  new_home "$h"
  printf '## Queued\n' >"$h/backlog.md"
  # Written newest first, so file order and hash order both disagree with age.
  i=12
  while [ "$i" -ge 1 ]; do
    printf -- '- [ ] aged-%02d - Approve batch %02d (since 2026-09-%02d) (hold: needs the captain) (hold-kind: captain)\n' \
      "$i" "$i" "$i" >>"$h/backlog.md"
    i=$((i - 1))
  done
  render_at "$h" "$T_1000"
  out=$(page "$h" 2026-09-10)
  order=$(printf '%s\n' "$out" | grep -o '<td class="what">Approve batch [0-9][0-9]' | sed 's/.*batch //' | head -3 | tr '\n' ' ')
  [ "$order" = '01 02 03 ' ] || fail "the held fold is ordered \"$order\", not oldest hold first"
  assert_contains "$out" '2 more held for you, not shown here.' 'the held fold is not capped'
  assert_not_contains "$out" '<td class="what">Approve batch 12' 'the newest hold displaced an older one'
  pass 'the held fold surfaces the oldest holds first, so the cut is stable and meaningful'
}

test_sync_prunes_only_retired_routine_records() {
  local h chatter gone kept
  h="$TMP_ROOT/prune"
  new_home "$h"
  chatter=$(intake_at "$h" "$T_0900" observe --source C_BRIEF --ref chat --digest a --title 'old channel chatter' | awk '{ print $2 }')
  intake_at "$h" "$T_0900" observe --source C_BRIEF --ref ask --digest b --class urgent --title 'dealer needs an answer' >/dev/null
  render_at "$h" "$T_0900"
  kept=$(field_of "$h" 'dealer needs' 1)
  todo_at "$h" "$T_0900" command --item "$kept" 'done' >/dev/null
  # What the intake does once a routine record passes its brief horizon.
  mkdir -p "$h/data/channel-intake/inactive"
  mv "$h/data/channel-intake/items/$chatter" "$h/data/channel-intake/inactive/$chatter"
  render_at "$h" "$T_1000"
  gone=$(field_of "$h" 'old channel chatter' 1)
  [ -n "$gone" ] || fail 'the retired record never became an item'
  # A day short of the retention the record is still queryable.
  render_at "$h" "$((T_1000 + 29 * 86400))"
  [ "$(field_of "$h" 'old channel chatter' 2)" = closed ] || fail 'a retired record was pruned before its retention'
  render_at "$h" "$((T_1000 + 31 * 86400))"
  [ -z "$(field_of "$h" 'old channel chatter' 2)" ] || fail 'a retired routine record outlived its retention'
  [ ! -f "$h/data/todo/items/$gone.json" ] || fail 'the pruned record is still on disk'
  # Everything that was ever an ask survives, so done keeps suppressing a reopen.
  [ "$(field_of "$h" 'dealer needs' 2)" = closed ] || fail 'a command tombstone was pruned with the chatter'
  [ "$(grep -c '"reason": "superseded"' "$h/data/todo/journal")" = 1 ] || fail 'pruning trimmed the journal'
  pass 'sync prunes a retired routine record after thirty days and keeps every ask it ever tracked'
}

test_a_marked_routine_line_is_never_retired_by_the_intake() {
  local h claimed parked loose mine_id park_id out
  h="$TMP_ROOT/marked"
  new_home "$h"
  claimed=$(intake_at "$h" "$T_0900" observe --source C_BRIEF --ref mark --digest a --title 'supplier posted a price list' | awk '{ print $2 }')
  parked=$(intake_at "$h" "$T_0900" observe --source C_BRIEF --ref park --digest b --title 'shipping notice for week 38' | awk '{ print $2 }')
  loose=$(intake_at "$h" "$T_0900" observe --source C_BRIEF --ref loose --digest c --title 'nobody claimed this one' | awk '{ print $2 }')
  render_at "$h" "$T_0900"
  mine_id=$(field_of "$h" 'price list' 1)
  park_id=$(field_of "$h" 'shipping notice' 1)
  todo_at "$h" "$T_0900" command --item "$mine_id" 'mine' >/dev/null
  todo_at "$h" "$T_0900" command --item "$park_id" 'park til tomorrow' >/dev/null
  # The intake retires all three once they pass the brief horizon.
  mkdir -p "$h/data/channel-intake/inactive"
  mv "$h/data/channel-intake/items/$claimed" "$h/data/channel-intake/inactive/$claimed"
  mv "$h/data/channel-intake/items/$parked" "$h/data/channel-intake/inactive/$parked"
  mv "$h/data/channel-intake/items/$loose" "$h/data/channel-intake/inactive/$loose"
  render_at "$h" "$T_1000"
  [ "$(field_of "$h" 'nobody claimed' 2)" = closed ] || fail 'an unmarked routine record was not retired'
  [ "$(field_of "$h" 'price list' 2)" = open ] || fail 'a routine line the captain claimed was auto-closed'
  [ "$(field_of "$h" 'shipping notice' 2)" = open ] || fail 'a routine line the captain parked was auto-closed'
  out=$(page "$h" 2026-09-10)
  assert_contains "$out" 'supplier posted a price list' 'the claimed line vanished from the page'
  assert_contains "$out" 'shipping notice for week 38' 'the parked line vanished from the page'
  # Never auto-closed means never pruned, however long the ledger stays silent.
  render_at "$h" "$((T_1000 + 31 * 86400))"
  [ -f "$h/data/todo/items/$mine_id.json" ] || fail 'the claimed line was pruned'
  [ -f "$h/data/todo/items/$park_id.json" ] || fail 'the parked line was pruned'
  [ "$(field_of "$h" 'price list' 2)" = open ] || fail 'the claimed line closed once its park had passed'
  pass 'a routine line the captain marked is never retired by the intake, nor pruned'
}

test_a_revived_routine_thread_still_retires_and_prunes() {
  local h key id
  h="$TMP_ROOT/revived"
  new_home "$h"
  key=$(intake_at "$h" "$T_0900" observe --source C_BRIEF --ref thread --digest a --title 'weekly ops thread' | awk '{ print $2 }')
  render_at "$h" "$T_0900"
  id=$(field_of "$h" 'weekly ops thread' 1)
  # Quiet past the brief horizon, so the intake retires it.
  mkdir -p "$h/data/channel-intake/inactive"
  mv "$h/data/channel-intake/items/$key" "$h/data/channel-intake/inactive/$key"
  render_at "$h" "$T_1000"
  [ "$(field_of "$h" 'weekly ops thread' 2)" = closed ] || fail 'the quiet thread was not retired'
  # A later message on the same ref restores the record, and the item reopens
  # with a system note. That note is the system's, not a mark the captain made.
  intake_at "$h" "$T_1030" observe --source C_BRIEF --ref thread --digest b --title 'weekly ops thread' >/dev/null
  render_at "$h" "$T_1100"
  [ "$(field_of "$h" 'weekly ops thread' 2)" = open ] || fail 'a revived routine record did not reopen its item'
  assert_contains "$(page "$h" 2026-09-10)" 'reopened' 'the reopen left no note on the line'
  # Quiet again: a reopen note must not exempt it from retirement forever.
  mv "$h/data/channel-intake/items/$key" "$h/data/channel-intake/inactive/$key"
  render_at "$h" "$T_1500"
  [ "$(field_of "$h" 'weekly ops thread' 2)" = closed ] || fail 'a reopen note exempted a routine line from retirement'
  render_at "$h" "$((T_1500 + 31 * 86400))"
  [ -z "$(field_of "$h" 'weekly ops thread' 2)" ] || fail 'the revived thread outlived its retention'
  [ ! -f "$h/data/todo/items/$id.json" ] || fail 'the revived thread was never pruned'
  pass 'a reopen note is not a captain mark: a revived routine thread still retires and prunes'
}

test_verification_is_never_renewed_by_sync() {
  local h out
  h="$TMP_ROOT/verification"
  new_home "$h"
  intake_at "$h" "$T_0900" observe --source C_BRIEF --ref v1 --digest a --class urgent --title 'dealer quote' >/dev/null
  todo_at "$h" "$T_1000" sweep-start >/dev/null
  # An unchanged re-read after the sweep does not renew the 09:00 check.
  intake_at "$h" "$T_1030" observe --source C_BRIEF --ref v1 --digest a --class urgent --title 'dealer quote' >/dev/null
  render_at "$h" "$T_1030"
  out=$(page "$h" 2026-09-10)
  assert_contains "$out" 'dealer quote<span class="prov unv">not re-checked since 09:00 CEST</span>' \
    'a check older than the sweep was shown as current'
  assert_contains "$out" 'No action re-checked in this build' 'the Now strip claimed a stale item'
  todo_at "$h" "$T_1030" verify --item "$(field_of "$h" 'dealer quote' 1)" --how 'Slack thread read directly' >/dev/null
  render_at "$h" "$T_1100"
  out=$(page "$h" 2026-09-10)
  assert_contains "$out" 'dealer quote<span class="prov obs">read 10:30 CEST</span>' 'an explicit verify was not recorded'
  assert_contains "$out" 'Slack thread read directly' 'the verification method is not on the line'
  # A later render never moves the check forward on its own.
  render_at "$h" "$T_1500"
  assert_contains "$(page "$h" 2026-09-10)" 'read 10:30 CEST' 'a re-render renewed the verification time'
  # A new day without a new read is not current.
  render_at "$h" "$T_NEXT_0900"
  assert_contains "$(page "$h" 2026-09-11)" 'not re-checked since Thu 10 Sep 10:30 CEST' \
    'yesterday'"'"'s check was treated as current today'
  pass 'verification changes only on a source read or an explicit verify, never on a sync or render'
}

test_done_survives_and_a_new_ask_resurfaces_once() {
  local h id out reopens
  h="$TMP_ROOT/done"
  new_home "$h"
  sidecar "$h" 2026-09-10 '{"key":"k-0910","source":"firstmate-backlog","ref":"catena","class":"urgent","title":"Catena firmware call","digest":"ask-1","updated":'"$T_0900"'}'
  render_at "$h" "$T_1000"
  id=$(field_of "$h" 'Catena' 1)
  out=$(todo_at "$h" "$T_1000" command --item "$id" 'done')
  assert_contains "$out" "TODO_CMD: done $id" 'done was not applied'
  render_at "$h" "$T_1100"
  render_at "$h" "$T_1500"
  # Next morning the sidecar re-asserts the same ask with a new key and wording.
  sidecar "$h" 2026-09-11 '{"key":"k-0911","source":"firstmate-backlog","ref":"catena","class":"urgent","title":"Catena: still the firmware call","digest":"ask-1","updated":'"$T_NEXT_0900"'}'
  render_at "$h" "$T_NEXT_0900"
  [ "$(field_of "$h" 'Catena' 2)" = closed ] || fail 'done did not survive the next morning'
  assert_not_contains "$(page "$h" 2026-09-11)" 'id="item-'"$id"'"' 'a done item came back on the page'
  # A meaningful change of the ask reopens it once, with the reason shown.
  sidecar "$h" 2026-09-11 '{"key":"k-0911","source":"firstmate-backlog","ref":"catena","class":"urgent","title":"Catena: now a thermostat call","digest":"ask-2","updated":'"$T_NEXT_0900"'}'
  render_at "$h" "$T_NEXT_1000"
  render_at "$h" "$T_NEXT_1000"
  out=$(page "$h" 2026-09-11)
  [ "$(field_of "$h" 'Catena' 2)" = open ] || fail 'a changed ask did not reopen'
  assert_contains "$out" 'reopened: firstmate-backlog changed after it was closed (fulfilled)' 'the reopen reason is missing'
  reopens=$(grep -c '"to": "open"' "$h/data/todo/journal")
  [ "$reopens" = 1 ] || fail "the item reopened $reopens times, not once"
  pass 'done survives repeated syncs and the next morning; a changed ask resurfaces once with its reason'
}

test_edit_after_resolution_reopens_once() {
  local h key
  h="$TMP_ROOT/edited"
  new_home "$h"
  key=$(intake_at "$h" "$T_0900" observe --source C_BRIEF --ref e1 --digest a --class urgent --title 'invoice dispute' | awk '{ print $2 }')
  intake_at "$h" "$T_1000" resolve --item "$key" --reason 'credit note sent' >/dev/null
  render_at "$h" "$T_1000"
  [ "$(field_of "$h" 'invoice dispute' 2)" = closed ] || fail 'a ledger resolution did not close the item'
  intake_at "$h" "$T_1100" observe --source C_BRIEF --ref e1 --digest b --class urgent --title 'invoice dispute' >/dev/null
  render_at "$h" "$T_1100"
  render_at "$h" "$T_1500"
  [ "$(field_of "$h" 'invoice dispute' 2)" = open ] || fail 'an edit after resolution did not reopen the item'
  [ "$(grep -c '"to": "open"' "$h/data/todo/journal")" = 1 ] || fail 'the archived resolution re-closed or re-reopened the item'
  pass 'an edit after a ledger resolution reopens the item once and the old resolution does not re-close it'
}

test_commands_refuse_stale_pages_and_track_handoffs() {
  local h id rev out code
  h="$TMP_ROOT/commands"
  new_home "$h"
  intake_at "$h" "$T_0900" observe --source C_BRIEF --ref c1 --digest a --class urgent --title 'Tomra restore' >/dev/null
  render_at "$h" "$T_0900"
  id=$(field_of "$h" 'Tomra' 1)
  rev=$(field_of "$h" 'Tomra' 4)
  assert_contains "$(page "$h" 2026-09-10)" "rev:&quot;$rev&quot;" 'the page does not carry the revision it shows'
  intake_at "$h" "$T_1000" observe --source C_BRIEF --ref c1 --digest b --class urgent --title 'Tomra restore' >/dev/null
  render_at "$h" "$T_1000"
  out=$(todo_at "$h" "$T_1000" command --item "$id" --rev "$rev" 'drop') && code=0 || code=$?
  expect_code 1 "$code" 'a command from a stale page was applied'
  assert_contains "$out" 'refresh the page first' 'the stale refusal does not say why'
  [ "$(field_of "$h" 'Tomra' 2)" = open ] || fail 'a refused command changed the item'
  rev=$(field_of "$h" 'Tomra' 4)
  todo_at "$h" "$T_1000" command --item "$id" --rev "$rev" 'you: ask Queco for the three facts' >/dev/null
  out=$(todo_at "$h" "$T_1000" command --item "$id" --rev "$rev" 'you: ask Queco for the three facts')
  assert_contains "$out" 'TODO_CMD: already you' 'a repeated command was not idempotent'
  render_at "$h" "$T_1030"
  assert_contains "$(page "$h" 2026-09-10)" 'handoff requested, not yet accepted: ask Queco for the three facts' \
    'a requested handoff was not shown as pending'
  todo_at "$h" "$T_1030" ack --item "$id" >/dev/null
  render_at "$h" "$T_1100"
  [ "$(field_of "$h" 'Tomra' 2)" = waiting ] || fail 'an accepted handoff did not move to waiting'
  assert_contains "$(page "$h" 2026-09-10)" 'firstmate has it: ask Queco for the three facts' 'the accepted owner is not shown'
  out=$(todo_at "$h" "$T_1100" command 'mine' 'no verb here') && code=0 || code=$?
  expect_code 1 "$code" 'a verb with no matching words was not refused'
  assert_contains "$out" 'TODO_CMD: not-a-command no verb here' 'a plain line was treated as a command'
  pass 'stale pages are refused, repeats are harmless, and a handoff stays requested until accepted'
}

test_missing_input_closes_nothing_and_release_is_scoped() {
  local h
  h="$TMP_ROOT/inputs"
  new_home "$h"
  cat >"$h/backlog.md" <<'MD'
## Queued
- [ ] fleet-a - Approve reads on unit A (since 2026-09-01) (hold: needs the captain's go (reads, not pushes)) (hold-kind: captain)
- [ ] fleet-b - Approve reads on unit B (since 2026-09-01) (hold: needs the captain's go) (hold-kind: captain)
- [ ] plain - Ordinary queued work (since 2026-09-01)
MD
  render_at "$h" "$T_0900"
  [ "$(field_of "$h" 'unit A' 2)" = open ] || fail 'a captain hold was not folded in'
  assert_contains "$(page "$h" 2026-09-10)" 'needs the captain&#x27;s go (reads, not pushes)' 'the nested hold reason was cut'
  assert_contains "$(page "$h" 2026-09-10)" 'cannot verify - no source read recorded' 'a backlog hold was shown as verified'
  assert_not_contains "$(page "$h" 2026-09-10)" 'Ordinary queued work' 'an unheld task reached the page'
  mv "$h/backlog.md" "$h/backlog.moved"
  render_at "$h" "$T_1000"
  [ "$(field_of "$h" 'unit A' 2)" = open ] || fail 'a missing backlog closed a held item'
  grep -v fleet-b "$h/backlog.moved" >"$h/backlog.md"
  render_at "$h" "$T_1100"
  [ "$(field_of "$h" 'unit B' 2)" = closed ] || fail 'a released hold did not close its item'
  [ "$(field_of "$h" 'unit A' 2)" = open ] || fail 'releasing one hold closed another'
  assert_contains "$(page "$h" 2026-09-10)" 'no longer held for you in the backlog' 'the release evidence is missing'
  cp -R "$h/data/todo" "$h/todo.before"
  printf '{broken' >"$h/.lavish/today-2026-09-10.morning.json"
  if render_at "$h" "$T_1500" 2>/dev/null; then fail 'a corrupt sidecar was accepted'; fi
  diff -r "$h/data/todo/items" "$h/todo.before/items" >/dev/null || fail 'a refused sync changed the store'
  pass 'missing or corrupt input closes nothing and a released hold closes only its own item'
}

test_identity_snooze_and_counter() {
  local h out id key
  h="$TMP_ROOT/identity"
  new_home "$h"
  key=$(intake_at "$h" "$T_0900" observe --source C_BRIEF --ref t1 --digest a --class urgent --title 'ticket ask one' | awk '{ print $2 }')
  sidecar "$h" 2026-09-10 '{"key":"'"$key"'","source":"C_BRIEF","ref":"t1","class":"urgent","title":"same ask from the sweep","updated":'"$T_0900"'},{"key":"second","source":"C_BRIEF","ref":"t1-b","class":"urgent","title":"ticket ask two","updated":'"$T_0900"'}'
  render_at "$h" "$T_1000"
  [ "$(todo_at "$h" "$T_1000" list | wc -l | tr -d ' ')" = 2 ] || fail 'one ask seen twice was not one item, or two asks merged'
  id=$(field_of "$h" 'ticket ask two' 1)
  todo_at "$h" "$T_1000" command --item "$id" 'park til tomorrow' >/dev/null
  render_at "$h" "$T_1030"
  assert_contains "$(page "$h" 2026-09-10)" 'back on 2026-09-11' 'a parked item is not listed with its date'
  render_at "$h" "$T_NEXT_0900"
  out=$(page "$h" 2026-09-11)
  assert_contains "$out" 'ticket ask two<span class="prov unv">not re-checked since' 'a snooze expiry claimed a fresh check'
  todo_at "$h" "$T_NEXT_0900" close --item "$(field_of "$h" 'ticket ask one' 1)" --evidence 'Naomi answered the dealer' --actor Naomi >/dev/null
  todo_at "$h" "$T_NEXT_0900" command --item "$id" 'drop' >/dev/null
  render_at "$h" "$T_NEXT_1000"
  out=$(page "$h" 2026-09-11)
  assert_contains "$out" '<div class="n">1</div><div class="l">Handled without you' 'a named fulfilled close was not counted'
  assert_contains "$out" '<div class="n">2</div><div class="l">Closed since' 'the closed count is wrong'
  assert_contains "$out" 'fulfilled by Naomi' 'the closing actor is not shown'
  assert_contains "$out" 'dismissed by you' 'a dismissal was not labelled as one'
  pass 'one ask seen twice dedupes, a snooze returns unverified, and only a named fulfilled close counts'
}

test_reopen_returns_a_handed_over_item_to_the_captain() {
  local h id out code
  h="$TMP_ROOT/reopen"
  new_home "$h"
  intake_at "$h" "$T_0900" observe --source C_BRIEF --ref r1 --digest a --class urgent --title 'Queco rollout sign-off' >/dev/null
  render_at "$h" "$T_0900"
  id=$(field_of "$h" 'Queco' 1)
  todo_at "$h" "$T_0900" command --item "$id" 'you: ask Queco for the three facts' >/dev/null
  todo_at "$h" "$T_0900" ack --item "$id" >/dev/null
  [ "$(field_of "$h" 'Queco' 2)" = waiting ] || fail 'an accepted handoff did not move to waiting'
  out=$(todo_at "$h" "$T_1000" reopen --item "$id" --reason 'Queco bounced it back to you')
  assert_contains "$out" "reopen $id -> open" 'reopen left a handed-over item where it was'
  [ "$(field_of "$h" 'Queco' 2)" = open ] || fail 'a waiting item did not come back to the captain lane'
  render_at "$h" "$T_1000"
  out=$(page "$h" 2026-09-10)
  assert_contains "$out" 'Queco bounced it back to you' 'the reopen reason is not on the line'
  assert_not_contains "$out" 'firstmate has it' 'the hand-over survived the reopen'
  out=$(todo_at "$h" "$T_1000" reopen --item "$id" 2>&1) && code=0 || code=$?
  expect_code 2 "$code" 'reopening an already open item was a silent no-op'
  assert_contains "$out" 'is already open' 'the refusal does not say why'
  pass 'reopen brings a handed-over item back to the captain and refuses one already open'
}

test_held_decisions_collapse_below_the_live_ones() {
  local h out n
  h="$TMP_ROOT/held"
  new_home "$h"
  printf '## Queued\n' >"$h/backlog.md"
  n=1
  while [ "$n" -le 12 ]; do
    printf -- '- [ ] hold-%02d - Approve change %02d (since 2026-09-01) (hold: needs the captain) (hold-kind: captain)\n' \
      "$n" "$n" >>"$h/backlog.md"
    n=$((n + 1))
  done
  sidecar "$h" 2026-09-10 '{"key":"k-live","source":"C_BRIEF","ref":"live-1","class":"urgent","title":"Sign the Catena quote","updated":'"$T_1000"'}'
  todo_at "$h" "$T_1000" sweep-start >/dev/null
  render_at "$h" "$T_1030"
  out=$(page "$h" 2026-09-10)
  assert_contains "$out" '<div class="n">1</div><div class="l">Decisions awaiting you</div><div class="s">1 open in all · 12 held, not re-checked</div>' \
    'the decisions tile does not keep captain holds apart from what was read today'
  assert_contains "$out" '<summary>Held decisions not re-checked (12)</summary>' 'the captain holds are not in their own fold'
  assert_contains "$out" '2 more held for you, not shown here.' 'the held fold is not capped with a count of the rest'
  n=$(printf '%s\n' "$out" | grep -c '<td class="what">Approve change')
  [ "$n" = 10 ] || fail "the held fold rendered $n rows, not ten"
  assert_not_contains "$out" 'None re-checked in this build.' 'holds left the live decisions section looking empty'
  case "${out%%<summary>Held decisions*}" in
    *'Sign the Catena quote'*) ;;
    *) fail 'the held fold is not below the live decisions section' ;;
  esac
  pass 'captain holds nobody re-checked collapse into a capped fold under the decisions read today'
}

test_routine_activity_keeps_its_not_re_checked_fold() {
  local h out
  h="$TMP_ROOT/activity"
  new_home "$h"
  intake_at "$h" "$T_0900" observe --source C_BRIEF --ref n1 --digest a --title 'weekly partner newsletter' >/dev/null
  todo_at "$h" "$T_1000" sweep-start >/dev/null
  intake_at "$h" "$T_1030" observe --source C_BRIEF --ref n2 --digest b --title 'new partner joined the channel' >/dev/null
  render_at "$h" "$T_1100"
  out=$(page "$h" 2026-09-10)
  assert_contains "$out" '<summary>Other channel activity</summary>' 'the routine activity fold is missing'
  assert_contains "$out" 'new partner joined the channel<span class="prov obs">read 10:30 CEST</span>' \
    'a routine line read after the sweep is not shown as current'
  assert_contains "$out" 'weekly partner newsletter<span class="prov unv">not re-checked since 09:00 CEST</span>' \
    'a routine line older than the sweep vanished from the page'
  assert_contains "$out" '<summary>1 not re-checked in this build - each shows its last check</summary>' \
    'stale routine activity is not in the labelled fold the sections use'
  pass 'routine activity older than the sweep stays on the page in its own not re-checked fold'
}

test_verification_is_never_renewed_by_sync
test_done_survives_and_a_new_ask_resurfaces_once
test_edit_after_resolution_reopens_once
test_commands_refuse_stale_pages_and_track_handoffs
test_missing_input_closes_nothing_and_release_is_scoped
test_identity_snooze_and_counter
test_reopen_returns_a_handed_over_item_to_the_captain
test_held_decisions_collapse_below_the_live_ones
test_routine_activity_keeps_its_not_re_checked_fold
test_a_retired_ledger_record_closes_its_routine_item
test_routine_fold_is_capped_like_the_held_one
test_held_fold_shows_the_oldest_holds_first
test_sync_prunes_only_retired_routine_records
test_a_marked_routine_line_is_never_retired_by_the_intake
test_a_revived_routine_thread_still_retires_and_prunes
