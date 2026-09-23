#!/usr/bin/env bash
# Live drive of the partner-first to-do wiring against the real CLIs, in an
# isolated FM_HOME, on the real clock. Usage: drive-partner-first.sh ROOT HOME
set -u
ROOT=$1 HOME_DIR=$2
INTAKE="$ROOT/bin/fm-channel-intake.sh"
RENDER="$ROOT/bin/fm-todo-render.sh"
h=$HOME_DIR
rm -rf "$h"
mkdir -p "$h/config" "$h/state" "$h/reports" "$h/data/channel-intake" "$h/.lavish" "$h/tl"
: >"$h/backlog.md"
cat >"$h/config/channel-intake" <<EOF
enabled = true
timezone = Europe/Amsterdam
interval_seconds = 900
report_dir = $h/reports
captain_names = Lars Tolhurst
captain_addresses = lars@team.example
team_addresses = support@team.example
rescan_interval_seconds = 21600
EOF
printf 'C_BRIEF\tslack-channel\tdaily brief channel, top-level messages\n' >"$h/data/channel-intake/sources.tsv"
printf 'H_TICKETS\thubspot-tickets\ttickets owned by or naming the captain\n' >>"$h/data/channel-intake/sources.tsv"

ix() { FM_HOME="$h" FM_ROOT_OVERRIDE="$ROOT" "$INTAKE" "$@"; }
run() { printf '\n$ fm-channel-intake.sh %s\n' "$*"; ix "$@"; printf '[exit %s]\n' "$?"; }
NOW=$(date +%s); D=86400; HR=3600

tl() { cat >"$h/tl/$1.json"; }

# --- the reported tickets and the back-sweep patterns -----------------------
# Frederick: colleague-owned, Lars named only in the email body, no change in >24h.
tl frederick <<EOF
{"kind":"hubspot-ticket","owner":"natalia@team.example","stage":"Waiting for Tech",
 "contacts":["frederick@partner.example"],
 "events":[
  {"type":"email","at":$((NOW-3*D)),"direction":"inbound","from":"frederick@partner.example","to":["support@team.example"],
   "body":"The dispenser is still down after the swap. Can someone look at it?"},
  {"type":"email","at":$((NOW-3*D+2*HR)),"direction":"outbound","from":"support@team.example","to":["frederick@partner.example"],
   "body":"Hi Frederick,\nLars is looking into this. I will keep you updated.\nNatalia"}]}
EOF
# HubSpot ticket 48375229511: no contact association resolved, partner only in the mail.
tl t48375229511 <<EOF
{"kind":"hubspot-ticket","owner":"natalia@team.example","stage":"Waiting for Tech",
 "events":[
  {"type":"email","at":$((NOW-13*D)),"direction":"inbound","from":"rachel@partner.example","body":"Any news on the syrup availability and connectivity?"},
  {"type":"email","at":$((NOW-13*D+150*60)),"direction":"outbound","from":"support@team.example","body":"Lars is looking into this, I will keep you updated."}]}
EOF
# Tech promise without naming Lars.
tl techpromise <<EOF
{"kind":"hubspot-ticket","owner":"natalia@team.example","stage":"Waiting for Tech",
 "contacts":["mark@office.example"],
 "events":[
  {"type":"email","at":$((NOW-5*D)),"direction":"inbound","from":"mark@office.example","body":"The machine keeps showing E.A03 after the reset."},
  {"type":"email","at":$((NOW-5*D+HR)),"direction":"outbound","from":"support@team.example","body":"Our tech team is looking into this, I'll keep you updated."}]}
EOF
# Colleague note "@Lars" nothing answers, parked in Waiting on contact.
tl colleaguenote <<EOF
{"kind":"hubspot-ticket","owner":"luc@team.example","stage":"Waiting on contact",
 "contacts":["chloe@kiosk.example"],
 "events":[
  {"type":"email","at":$((NOW-4*D-HR)),"direction":"inbound","from":"chloe@kiosk.example","body":"Waar kunnen we het serienummer vinden?"},
  {"type":"note","at":$((NOW-4*D)),"author":"luc@team.example","body":"@Lars see attached pictures"}]}
EOF
# Customer's reply got only an auto-acknowledgement (send with no EMAIL engagement).
tl autoack <<EOF
{"kind":"hubspot-ticket","owner":"lars@team.example","stage":"Waiting for Logistics",
 "contacts":["alex@workplace.example"],"last_message_sent_at":$((NOW-2*D+240)),
 "events":[
  {"type":"email","at":$((NOW-2*D)),"direction":"inbound","from":"alex@workplace.example","body":"Could the delivery charge be amended?"}]}
EOF
# --- controls that must NOT be flagged ---------------------------------------
tl answered <<EOF
{"kind":"hubspot-ticket","owner":"natalia@team.example","stage":"Waiting for Tech",
 "contacts":["rachel@partner.example"],
 "events":[
  {"type":"email","at":$((NOW-3*D)),"direction":"inbound","from":"rachel@partner.example","body":"Any news?"},
  {"type":"email","at":$((NOW-3*D+HR)),"direction":"outbound","from":"support@team.example","body":"Lars is looking into this. I will keep you updated."},
  {"type":"email","at":$((NOW-2*D)),"direction":"outbound","from":"support@team.example","body":"The SIMs are active again as of this morning."}]}
EOF
tl noteanswered <<EOF
{"kind":"hubspot-ticket","owner":"luc@team.example","stage":"Waiting for Tech",
 "contacts":["chloe@kiosk.example"],
 "events":[
  {"type":"note","at":$((NOW-2*D)),"author":"luc@team.example","body":"@Lars can you check the serial?"},
  {"type":"note","at":$((NOW-D)),"author":"lars@team.example","body":"Checked, it is a 2023 build."}]}
EOF
tl uninvolved <<EOF
{"kind":"hubspot-ticket","owner":"luc@team.example","stage":"New",
 "contacts":["john@site.example"],
 "events":[{"type":"email","at":$((NOW-D)),"direction":"inbound","from":"john@site.example","body":"No sparkling water, please send a technician."}]}
EOF
tl internal <<EOF
{"kind":"hubspot-ticket","owner":"luc@team.example","stage":"New","contacts":["joao@team.example"],
 "companies":[{"name":"Aquablu"}],
 "events":[{"type":"note","at":$((NOW-D)),"author":"luc@team.example","body":"@Lars can you check the PCB stock?"}]}
EOF

echo "=== 1. claim: HubSpot source is told the stages and handed a re-scan ==="
run claim

echo; echo "=== 2. Slack checkpoint read: an outage, an urgent and a deadline arrive ==="
run observe --source C_BRIEF --ref slack-outage --digest 'site down' --class outage --title 'Service outage at Schiphol site'
run observe --source C_BRIEF --ref slack-urgent --digest 'urgent' --class urgent --title 'Urgent: board deck numbers'
run observe --source C_BRIEF --ref slack-deadline --digest 'deadline' --class deadline --title 'Deadline: insurer form due Friday'
run complete --source C_BRIEF --checkpoint slack-1

echo; echo "=== 3. HubSpot re-scan: every ticket observed with its timeline ==="
for t in frederick:'Frederick - dispenser down after swap' t48375229511:'Syrup availability and connectivity (48375229511)' \
         techpromise:'E.A03 after reset (tech promised)' colleaguenote:'Serial number question (NS kiosk)' \
         autoack:'Delivery charge amendment' answered:'Connectivity - answered' noteanswered:'Serial - answered by note' \
         uninvolved:'No sparkling water (Luc)' internal:'PCB stock (internal)'; do
  name=${t%%:*} title=${t#*:}
  run observe --source H_TICKETS --ref "$name" --digest "$name v1" --class routine --title "$title" --timeline-file "$h/tl/$name.json"
done
run complete --source H_TICKETS --checkpoint hs-1 --rescanned

echo; echo "=== 4. ledger facts per ticket ==="
for f in "$h"/data/channel-intake/items/*; do
  awk -F= '/^(title|class|partner|awaiting|awaiting_since|awaiting_why)=/{printf "%s=%s | ", $1, substr($0, index($0,"=")+1)} END{print ""}' "$f"
done | sort

echo; echo "=== 5. todo summary ==="
run todo
echo; echo "=== 6. brief ==="
run brief

echo; echo "=== 7. a later claim inside the re-scan interval does not re-scan again ==="
run claim --source H_TICKETS
