#!/usr/bin/env bash
# Replays the 13 Oct 2026 report against a disposable lab home: a HubSpot
# re-scan observes colleague-owned tickets (Luc's direct clients, Natalia's)
# plus tickets that really are Lars's, then the to-do page is rendered.
# Usage: oct13-colleague-tickets.sh <checkout-root> <label>
set -eu
ROOT=$1 LABEL=$2
LAB=$(mktemp -d "${TMPDIR:-/tmp}/fm-lab.XXXXXX")
trap 'rm -rf "$LAB"' EXIT
"$ROOT/bin/fm-lab-home.sh" create "$LAB" >/dev/null
mkdir -p "$LAB/config" "$LAB/state" "$LAB/reports" "$LAB/data/channel-intake" "$LAB/.lavish"
: >"$LAB/backlog.md"
cat >"$LAB/config/channel-intake" <<EOF
enabled = true
timezone = Europe/Amsterdam
interval_seconds = 900
stale_after_seconds = 5400
backoff_seconds = 900
backoff_max_seconds = 3600
notify_recipient = U_CAPTAIN
notify_recipient_verified = true
report_dir = $LAB/reports
captain_names = Lars Tolhurst
captain_addresses = lars@team.example
team_addresses = support@team.example
rescan_interval_seconds = 3600
EOF
printf 'H_TICKETS\thubspot-tickets\tHubSpot tickets owned by or naming the captain\n' >"$LAB/data/channel-intake/sources.tsv"

NOW=1791874800          # 13 Oct 2026 09:00 Europe/Amsterdam
IN=$((NOW - 30 * 3600)) OUT=$((NOW - 28 * 3600))
intake() { env -u FM_ROOT_OVERRIDE -u FM_STATE_OVERRIDE -u FM_DATA_OVERRIDE -u FM_CONFIG_OVERRIDE \
  FM_HOME="$LAB" FM_CHANNEL_INTAKE_NOW="$1" "$ROOT/bin/fm-channel-intake.sh" "${@:2}"; }

tl() { # name owner contact events-json
  printf '{"kind":"hubspot-ticket","owner":"%s","stage":"Waiting for Tech","contacts":["%s"],"events":[%s]}\n' \
    "$2" "$3" "$4" >"$LAB/$1.json"
}
inb() { printf '{"type":"email","at":%s,"direction":"inbound","from":"%s","body":"%s"}' "$1" "$2" "$3"; }
outb() { printf '{"type":"email","at":%s,"direction":"outbound","from":"support@team.example","body":"%s"}' "$1" "$2"; }
note() { printf '{"type":"note","at":%s,"author":"%s","body":"%s"}' "$1" "$2" "$3"; }

# --- Colleague-owned: nobody tagged or asked Lars -------------------------------
tl sportcity luc@team.example ops@sportcity.example \
  "$(inb $IN ops@sportcity.example 'The machine keeps showing E.A03 after the reset.'),$(outb $OUT 'Our tech team is looking into this, I will keep you updated.\nLuc')"
tl citygym luc@team.example fm@citygym.example \
  "$(outb $((IN - 14400)) 'Our tech team is looking into this, I will keep you updated.\nLuc'),$(outb $((IN - 7200)) 'Please try a reset in the meantime.\nLuc'),$(inb $IN fm@citygym.example 'The reset did not help, any news?')"
tl duinrell luc@team.example facility@duinrell.example \
  "$(inb $IN facility@duinrell.example 'The unit in hall 2 is leaking.'),$(note $OUT luc@team.example 'Discussed with Lars, closing.')"
tl cargill luc@team.example ops@cargill.example \
  "$(inb $IN ops@cargill.example 'Hi Luc, Lars installed the unit last year; it now shows B.14, what should we do?')"
tl keiron natalia@team.example office@keiron.example \
  "$(inb $IN office@keiron.example 'Any news on the syrup availability?'),$(outb $OUT 'Lars is looking into this. I will keep you updated.\nNatalia')"
tl ask-about luc@team.example chloe@kiosk.example \
  "$(inb $IN chloe@kiosk.example 'The unit shows B.14 again.'),$(note $OUT luc@team.example 'Should we ask Lars?')"
# --- Lars's: he owns it, or he is @mentioned or asked directly ------------------
tl own-ticket captain mark@partner.example \
  "$(inb $IN mark@partner.example 'The machine keeps showing E.A03 after the reset.'),$(outb $OUT 'Our tech team is looking into this, I will keep you updated.\nNatalia')"
tl at-mention luc@team.example chloe@kiosk.example \
  "$(inb $IN chloe@kiosk.example 'The unit shows B.14 again.'),$(note $OUT luc@team.example '@Lars can you look at the PCB on this one')"
tl direct-ask luc@team.example rachel@partner.example \
  "$(inb $IN rachel@partner.example 'Hi Lars,\ncould you check the connectivity? The systems should really be online.')"
tl dutch-ask natalia@team.example kantoor@klant.example \
  "$(inb $IN kantoor@klant.example 'De unit geeft B.14.'),$(note $OUT natalia@team.example 'Kun jij hier even naar kijken Lars?')"

echo "=== [$LABEL] claim (the re-scan handed to the orchestrator) ==="
intake $NOW claim 2>&1 | grep -E '^(claim|stages|rescan):' | cut -c1-400
echo
echo "=== [$LABEL] observe --timeline-file per ticket (owner -> awaiting / class) ==="
printf '%-12s %-22s %-8s %-11s %s\n' ticket owner awaiting class why
for t in sportcity citygym duinrell cargill keiron ask-about own-ticket at-mention direct-ask dutch-ask; do
  line=$(intake $NOW observe --source H_TICKETS --ref "$t" --digest "$t v1" --class routine \
    --title "$t" --timeline-file "$LAB/$t.json")
  key=$(printf '%s' "$line" | awk '{print $2}')
  f="$LAB/data/channel-intake/items/$key"
  g() { awk -F= -v k="$1" 'index($0, k "=") == 1 { print substr($0, length(k) + 2) }' "$f"; }
  owner=$(python3 -c 'import json,sys;print(json.load(open(sys.argv[1]))["owner"])' "$LAB/$t.json")
  printf '%-12s %-22s %-8s %-11s %s\n' "$t" "$owner" "$(g awaiting)" "$(g class)" "$(g awaiting_why)"
done
intake $NOW complete --source H_TICKETS --checkpoint c1 --rescanned >/dev/null 2>&1 || true

echo
echo "=== [$LABEL] rendered to-do page: Needs you now ==="
env -u FM_ROOT_OVERRIDE FM_HOME="$LAB" FM_TODO_RENDER_NOW=$((NOW + 3600)) FM_TODO_BACKLOG_OVERRIDE="$LAB/backlog.md" \
  "$ROOT/bin/fm-todo-render.sh" render >/dev/null
page="$LAB/.lavish/today-2026-10-13.html"
sed -n '/<h2>Needs you now/,/<\/table>/p' "$page" | grep -o 'class="what">[^<]*' | sed 's/^class="what">/  - /'
cp "$page" "$(dirname "$0")/todo-page-$LABEL.html"
