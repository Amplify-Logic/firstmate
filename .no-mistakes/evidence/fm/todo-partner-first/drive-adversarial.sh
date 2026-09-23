#!/usr/bin/env bash
# Adversarial follow-ups on the home drive-partner-first.sh built. Usage: ROOT HOME
set -u
ROOT=$1 h=$2
INTAKE="$ROOT/bin/fm-channel-intake.sh"
ix() { FM_HOME="$h" FM_ROOT_OVERRIDE="$ROOT" "$INTAKE" "$@"; }
run() { printf '\n$ fm-channel-intake.sh %s\n' "$*"; ix "$@"; printf '[exit %s]\n' "$?"; }
snap() { (cd "$h/data/channel-intake" && find items archive -type f -exec shasum {} + 2>/dev/null | sort); }
NOW=$(date +%s); D=86400; HR=3600

echo "=== A. malformed timelines are refused and change nothing ==="
before=$(snap)
sed 's/"from":"support@team.example"/"from":"Aquablu Support <support@team.example>"/' "$h/tl/frederick.json" >"$h/tl/bad-display.json"
run observe --source H_TICKETS --ref bad-display --digest v1 --class routine --title 'bad display' --timeline-file "$h/tl/bad-display.json"
python3 - "$h/tl/frederick.json" "$h/tl/bad-millis.json" <<'EOF'
import json,sys; d=json.load(open(sys.argv[1])); d['events'][0]['at']*=1000; json.dump(d,open(sys.argv[2],'w'))
EOF
run observe --source H_TICKETS --ref bad-millis --digest v1 --class routine --title 'bad millis' --timeline-file "$h/tl/bad-millis.json"
sed 's/"kind":"hubspot-ticket"/"kind":"email-thread"/' "$h/tl/frederick.json" >"$h/tl/bad-kind.json"
run observe --source H_TICKETS --ref bad-kind --digest v1 --class routine --title 'bad kind' --timeline-file "$h/tl/bad-kind.json"
sed 's/"contacts":\["frederick@partner.example"\]/"contacts":"frederick@partner.example"/' "$h/tl/frederick.json" >"$h/tl/bad-contacts.json"
run observe --source H_TICKETS --ref bad-contacts --digest v1 --class routine --title 'bad contacts' --timeline-file "$h/tl/bad-contacts.json"
[ "$before" = "$(snap)" ] && echo "ledger unchanged after the four refusals: yes" || echo "ledger unchanged after the four refusals: NO"

echo; echo "=== B. an unchanged ticket re-read by the re-scan later is a fresh read ==="
key=$(grep -l '^title=Frederick' "$h"/data/channel-intake/items/*); key=${key##*/}
printf 'before: read_at=%s updated=%s\n' "$(grep '^read_at=' "$h/data/channel-intake/items/$key" | cut -d= -f2)" "$(grep '^updated=' "$h/data/channel-intake/items/$key" | cut -d= -f2)"
FM_CHANNEL_INTAKE_NOW=$((NOW + 120)) ix observe --source H_TICKETS --ref frederick --digest 'frederick v1' --class routine \
  --title 'Frederick - dispenser down after swap' --timeline-file "$h/tl/frederick.json"
printf 'after:  read_at=%s updated=%s\n' "$(grep '^read_at=' "$h/data/channel-intake/items/$key" | cut -d= -f2)" "$(grep '^updated=' "$h/data/channel-intake/items/$key" | cut -d= -f2)"

echo; echo "=== C. the captain answers Frederick; ledger resolve, later re-scan shows partner waiting again ==="
run resolve --item "$key" --reason 'captain replied to Frederick'
cat >"$h/tl/frederick-v2.json" <<EOF
{"kind":"hubspot-ticket","owner":"natalia@team.example","stage":"Waiting on contact",
 "contacts":["frederick@partner.example"],
 "events":[
  {"type":"email","at":$((NOW-3*D)),"direction":"inbound","from":"frederick@partner.example","body":"The dispenser is still down after the swap."},
  {"type":"email","at":$((NOW-3*D+2*HR)),"direction":"outbound","from":"support@team.example","body":"Lars is looking into this. I will keep you updated."},
  {"type":"email","at":$((NOW-HR)),"direction":"outbound","from":"lars@team.example","body":"Replacement pump ships tomorrow."},
  {"type":"email","at":$((NOW-10*60)),"direction":"inbound","from":"frederick@partner.example","body":"Thanks - which carrier, and do we need to be on site?"}]}
EOF
run observe --source H_TICKETS --ref frederick --digest 'frederick v2' --class routine --title 'Frederick - dispenser down after swap' --timeline-file "$h/tl/frederick-v2.json"
printf 'open item present: %s\n' "$([ -f "$h/data/channel-intake/items/$key" ] && echo yes || echo no)"
grep -E '^(state|class|resolution|partner|awaiting|awaiting_since|awaiting_why)=' "$h/data/channel-intake/archive/$key"

echo; echo "=== D. complete refreshes the existing day page ==="
run complete --source H_TICKETS --checkpoint hs-2 --rescanned
