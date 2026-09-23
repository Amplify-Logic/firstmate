#!/usr/bin/env bash
# Stand up an isolated firstmate home that mirrors the captain's complaint day
# (an outage, a deadline, a partner ticket awaiting him, a long-waiting urgent
# ask, obligations, routine chatter, many captain-held backlog holds, a handed-
# over item, closed items, open tickets and a morning calendar/worth-knowing
# fragment), then render the daily to-do page with the product's own CLI.
# Usage: drive-day.sh ROOT HOME
set -eu
ROOT=$1 H=$2
INTAKE="$ROOT/bin/fm-channel-intake.sh" TODO="$ROOT/bin/fm-todo.sh" RENDER="$ROOT/bin/fm-todo-render.sh"
T_0900=1789023600 T_1000=1789027200 T_1100=1789030800 T_1400=1789041600 T_1500=1789045200 T_1530=1789047000
T_Y=1788958800
rm -rf "$H"; mkdir -p "$H/config" "$H/data/channel-intake" "$H/.lavish"
printf 'enabled = true\ntimezone = Europe/Amsterdam\ninterval_seconds = 900\n' >"$H/config/channel-intake"
printf 'C_BRIEF\tslack-channel\tdaily brief channel\nhubspot-lars-tickets\thubspot-tickets\tpartner tickets\n' >"$H/data/channel-intake/sources.tsv"
printf '## Queued\n' >"$H/backlog.md"
for n in $(seq -w 1 83); do
  printf -- '- [ ] hold-%s - Approve fleet change %s (since 2026-09-01) (hold: needs the captain) (hold-kind: captain)\n' "$n" "$n" >>"$H/backlog.md"
done
ia() { local now=$1; shift; FM_HOME="$H" FM_ROOT_OVERRIDE="$ROOT" FM_CHANNEL_INTAKE_NOW="$now" "$INTAKE" "$@"; }
td() { local now=$1; shift; FM_HOME="$H" FM_ROOT_OVERRIDE="$ROOT" FM_TODO_NOW="$now" FM_TODO_BACKLOG_OVERRIDE="$H/backlog.md" "$TODO" "$@"; }
rn() { local now=$1; shift; FM_HOME="$H" FM_ROOT_OVERRIDE="$ROOT" FM_TODO_RENDER_NOW="$now" FM_TODO_BACKLOG_OVERRIDE="$H/backlog.md" "$RENDER" render "$@"; }

ia $T_0900 observe --source C_BRIEF --ref obl --digest a --class obligation --title 'Answer the installer training question' --link https://slack.example/obl >/dev/null
ia $T_0900 observe --source C_BRIEF --ref dl --digest b --class deadline --title 'Sign off the Q4 service budget before 17:00' --link https://slack.example/dl >/dev/null
ia $T_1400 observe --source C_BRIEF --ref out --digest c --class outage --title 'REFILL+ at Hotel Arena is down, guests without water' --link https://slack.example/out >/dev/null
ia $T_1500 observe --source hubspot-lars-tickets --ref urg --digest d --class urgent --title 'Dealer asking about a 26-day-old spare part order' --link https://hubspot.example/urg >/dev/null
ia $T_0900 observe --source C_BRIEF --ref rt --digest e --class routine --title 'Weekly newsletter draft shared' >/dev/null
ia $T_0900 observe --source C_BRIEF --ref rt2 --digest e2 --class routine --title 'Office lunch order' >/dev/null
kw=$(ia $T_0900 observe --source C_BRIEF --ref w --digest f --class urgent --title 'Dealer quote for Catena' | awk '{print $2}')
kd=$(ia $T_0900 observe --source C_BRIEF --ref d --digest g --class urgent --title 'Invoice dispute with Alvina' | awk '{print $2}')
ia $T_1000 resolve --item "$kw" --reason 'handed to Naomi, she answers the dealer' --waiting >/dev/null
ia $T_1100 resolve --item "$kd" --reason 'credit note sent, customer confirmed' >/dev/null

# Morning sweep: a partner ticket awaiting him and a structured obligation.
printf '{"version":2,"date":"2026-09-10","sweep_started":%s,"actions":[{"key":"k-p","source":"hubspot","ref":"t-9","class":"obligation","kind":"reply","title":"Partner Watermark BV awaiting your answer on the SLA","why":"they asked twice, last on Tuesday","partner_awaiting":true,"awaiting_since":%s,"updated":%s},{"key":"k-rl","source":"C_BRIEF","ref":"rl","class":"obligation","title":"Pallet delivery slot for Friday","digest":"ask-1","updated":%s}]}\n' \
  "$T_0900" "$T_Y" "$T_0900" "$T_0900" >"$H/.lavish/today-2026-09-10.morning.json"
cat >"$H/.lavish/today-2026-09-10.morning.html" <<'HTML'
<h2>Calendar</h2><ul><li>10:00 Ops stand-up</li><li>14:00 Partner review with Watermark BV</li></ul>
<h2>Worth knowing</h2><ul><li>Hotel Arena contract renews next month.</li></ul>
<h2>Your open tickets</h2><p>STALE MORNING COPY OF THE TICKETS TABLE</p>
HTML
printf '%s' '[{"id":"101","subject":"Alvina consumption report","stage":"Waiting for Tech","last_in":"10 Sep 10:36","last_out":"10 Sep 16:10","link":"https://app.hubspot.com/r/101"},{"id":"102","subject":"Sparkling water is ambient","stage":"Waiting on contact","last_in":"10 Sep 13:38","last_out":"","link":"https://app.hubspot.com/r/102"}]' \
  | ia $T_1500 tickets --owner 'Lars Tolhurst' >/dev/null

rn $T_1000 >/dev/null
# Reopen by a sweep change (system-written note) and a manual reopen with a reason.
if [ -x "$TODO" ]; then
  id=$(td $T_1000 list | awk -F '\t' 'index($5,"Pallet delivery slot") {print $1; exit}')
  if [ -n "$id" ]; then
    td $T_1000 command --item "$id" 'done' >/dev/null || true
    rn $T_1100 >/dev/null
    sed -i '' 's/"digest":"ask-1","updated":'"$T_0900"'/"digest":"ask-2","updated":'"$T_1100"'/' "$H/.lavish/today-2026-09-10.morning.json"
  fi
  oid=$(td $T_1000 list | awk -F '\t' 'index($5,"installer training") {print $1; exit}')
  if [ -n "$oid" ]; then
    td $T_1000 close --item "$oid" --evidence 'answered in thread' --actor Naomi >/dev/null || true
    td $T_1100 reopen --item "$oid" --reason 'reopened at the captain'"'"'s request after C_BRIEF-ops asked again' >/dev/null || true
  fi
fi
rn $T_1530 >/dev/null
echo "$H/.lavish/today-2026-09-10.html"
