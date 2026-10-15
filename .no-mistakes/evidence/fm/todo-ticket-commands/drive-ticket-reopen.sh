#!/usr/bin/env bash
# Live drive: two-ticket refusal, and handoff/reopen through the real channel intake, in a lab FM_HOME.
set -u
WT=$1 EV=$2
LAB=$(mktemp -d "${TMPDIR:-/tmp}/fm-lab.XXXXXX")
"$WT/bin/fm-lab-home.sh" create "$LAB" >/dev/null
trap 'rm -rf "$LAB"' EXIT
mkdir -p "$LAB/.lavish" "$LAB/data/channel-intake"
printf 'enabled = true\ntimezone = Europe/Amsterdam\ninterval_seconds = 900\ncaptain_names = Lars\nteam_addresses = support@team.example\n' >"$LAB/config/channel-intake"
printf 'hubspot-lars-tickets\thubspot-tickets\ttickets naming the captain\n' >"$LAB/data/channel-intake/sources.tsv"
: >"$LAB/backlog.md"
E="env -u NO_MISTAKES_GATE -u FM_ROOT_OVERRIDE -u FM_STATE_OVERRIDE -u FM_DATA_OVERRIDE -u FM_CONFIG_OVERRIDE FM_HOME=$LAB FM_TODO_BACKLOG_OVERRIDE=$LAB/backlog.md"
todo() { echo "\$ fm-todo.sh $*"; $E "$WT/bin/fm-todo.sh" "$@"; echo "[exit $?]"; }
render() { $E "$WT/bin/fm-todo-render.sh" render >/dev/null || echo "render failed"; }
DAY=$(TZ=Europe/Amsterdam date +%F)
col_of() { $E "$WT/bin/fm-todo.sh" list | awk -F '\t' -v t="$1" -v c="$2" 'index($5, t) { print $c; exit }'; }
act_of() { $E "$WT/bin/fm-todo.sh" tickets | awk -F '\t' -v i="TODO_TICKET: $1" -v v="$2" '$1 == i && $4 == v { print $2 }'; }
observe() { # ref digest title timeline
  echo "\$ fm-channel-intake.sh observe --ref $1 --digest $2"
  $E "$WT/bin/fm-channel-intake.sh" observe --source hubspot-lars-tickets --ref "$1" --digest "$2" --class obligation \
    --title "$3" --timeline-file "$LAB/$4.json"; }
add_event() { python3 -I -c 'import json,sys; p=sys.argv[1]; d=json.load(open(p)); d["events"].append(json.loads(sys.argv[2])); open(p,"w").write(json.dumps(d))' "$LAB/$1.json" "$2"; }
show_rec() { grep -h '^\(last_inbound_at\|awaiting\|awaiting_since\|partner\)=' "$LAB"/data/channel-intake/items/*"$1"* 2>/dev/null | tr '\n' ' '; echo; }

NOW=$(date +%s); ASKED=$((NOW - 86400))
echo "== S4 two tickets on one row"
printf '{"version":2,"date":"%s","actions":[{"key":"k5","source":"hubspot","ref":"33333333333","class":"obligation","kind":"reply","title":"Merged two-ticket row","link":"https://app.hubspot.com/contacts/1/record/0-5/44444444444","updated":%s}]}\n' "$DAY" "$NOW" >"$LAB/.lavish/today-$DAY.morning.json"
render
todo command --item "$(col_of 'Merged' 1)" 'close'

echo; echo "== S6/S7 handoff and reopen through the intake"
cat >"$LAB/tomra.json" <<J
{"kind":"hubspot-ticket","owner":"natalia@team.example","contacts":["rachel@tomra.example"],
 "events":[{"type":"email","at":$ASKED,"direction":"inbound","from":"rachel@tomra.example","body":"The pump is leaking."},
  {"type":"email","at":$((ASKED + 3600)),"direction":"outbound","from":"support@team.example","body":"Lars is looking into this. I will keep you updated."}]}
J
cat >"$LAB/neshu.json" <<J
{"kind":"hubspot-ticket","owner":"captain","contacts":["tim@neshu.example"],
 "events":[{"type":"email","at":$ASKED,"direction":"inbound","from":"tim@neshu.example","body":"Is the firmware out?"},
  {"type":"email","at":$((ASKED + 3600)),"direction":"outbound","from":"support@team.example","body":"Yes, it is live."}]}
J
cat >"$LAB/queco.json" <<J
{"kind":"hubspot-ticket","owner":"captain","contacts":["ann@queco.example"],
 "events":[{"type":"email","at":$ASKED,"direction":"inbound","from":"ann@queco.example","body":"Can you swap the filter?"},
  {"type":"email","at":$((ASKED + 3600)),"direction":"outbound","from":"support@team.example","body":"Booked for Friday."}]}
J
observe 48576658049 v1 'Tomra pump ticket' tomra
observe 48600120191 v1 'Neshu ticket' neshu
observe 48700000001 v1 'Queco filter ticket' queco
echo "Tomra intake facts: $(show_rec 48576658049)"
render
TOMRA=$(col_of Tomra 1) NESHU=$(col_of Neshu 1) QUECO=$(col_of Queco 1)
todo command --item "$TOMRA" 'waiting'
todo command --item "$NESHU" 'close' 'done'
todo command --item "$QUECO" 'close: filter swapped'
sleep 2
# Race: Queco's customer writes after the verb, before Firstmate records the close.
add_event queco '{"type":"email","at":'"$(date +%s)"',"direction":"inbound","from":"ann@queco.example","body":"Actually it is leaking again."}'
sleep 1
todo ticket-done --item "$TOMRA" --action "$(act_of "$TOMRA" waiting)" --evidence 'stage Waiting on contact'
todo ticket-done --item "$NESHU" --action "$(act_of "$NESHU" close)" --evidence 'stage Closed'
todo ticket-done --item "$QUECO" --action "$(act_of "$QUECO" close)" --evidence 'stage Closed'
sleep 1
for t in tomra neshu queco; do
  add_event $t '{"type":"note","at":'"$(date +%s)"',"author":"captain","body":"change by Lars via assistant: page verb"}'
done
echo "-- our own HubSpot write (note + stage) observed as a new revision"
observe 48576658049 v2 'Tomra pump ticket' tomra
observe 48600120191 v2 'Neshu ticket' neshu
observe 48700000001 v2 'Queco filter ticket' queco
render
echo "after own write: Tomra=$(col_of Tomra 2) Neshu=$(col_of Neshu 2) Queco=$(col_of Queco 2)"
cp "$LAB/.lavish/today-$DAY.html" "$EV/page-4-after-own-write.html"
sleep 2
echo "-- partners write again after the handoff"
add_event tomra '{"type":"email","at":'"$(date +%s)"',"direction":"inbound","from":"rachel@tomra.example","body":"Any news?"}'
add_event neshu '{"type":"email","at":'"$(date +%s)"',"direction":"inbound","from":"tim@neshu.example","body":"It broke again."}'
observe 48576658049 v3 'Tomra pump ticket' tomra
observe 48600120191 v3 'Neshu ticket' neshu
echo "Tomra intake facts: $(show_rec 48576658049)"
render
echo "after partner wrote: Tomra=$(col_of Tomra 2) Neshu=$(col_of Neshu 2) Queco=$(col_of Queco 2)"
cp "$LAB/.lavish/today-$DAY.html" "$EV/page-5-partner-wrote.html"
grep -o 'reopened: [^<"]*' "$EV/page-5-partner-wrote.html" | sort -u
