#!/usr/bin/env bash
# Drive the channel intake CLI end to end in a disposable lab home:
# claim a HubSpot source, observe 13 Oct-style colleague-owned tickets with
# timelines, complete, then render the captain's to-do page.
# Usage: drive.sh <repo-root> <out-dir>
set -u
REPO=$1 OUT=$2
mkdir -p "$OUT"
LAB=$(mktemp -d "${TMPDIR:-/tmp}/fm-lab.XXXXXX")
"$REPO/bin/fm-lab-home.sh" create "$LAB" >/dev/null 2>&1 || mkdir -p "$LAB/state" "$LAB/data" "$LAB/config" "$LAB/projects"
mkdir -p "$LAB/data/channel-intake" "$LAB/reports" "$LAB/tl"
cat >"$LAB/config/channel-intake" <<EOF
enabled = true
timezone = Europe/Amsterdam
interval_seconds = 900
notify_recipient = U_CAPTAIN
notify_recipient_verified = true
report_dir = $LAB/reports
captain_names = Lars Tolhurst
captain_addresses = lars@aquablu.example
team_addresses = support@aquablu.example
rescan_interval_seconds = 3600
EOF
printf 'H_TICKETS\thubspot-tickets\ttickets owned by or naming the captain\n' >"$LAB/data/channel-intake/sources.tsv"
NOW=1791874800   # 2026-10-13 09:00 Europe/Amsterdam
IN=$((NOW - 30*3600)) OUTB=$((NOW - 28*3600))
run() { env -u FM_ROOT_OVERRIDE -u FM_STATE_OVERRIDE -u FM_DATA_OVERRIDE -u FM_CONFIG_OVERRIDE FM_HOME="$LAB" FM_CHANNEL_INTAKE_NOW="$NOW" "$REPO/bin/fm-channel-intake.sh" "$@"; }

tl() { # name owner contact inbound-body [outbound-body] [note-body]
  local name=$1 owner=$2 contact=$3 inb=$4 outb=${5:-} note=${6:-} ev
  ev="{\"type\":\"email\",\"at\":$IN,\"direction\":\"inbound\",\"from\":\"$contact\",\"body\":$(python3 -c 'import json,sys;print(json.dumps(sys.argv[1]))' "$inb")}"
  [ -n "$outb" ] && ev="$ev,{\"type\":\"email\",\"at\":$OUTB,\"direction\":\"outbound\",\"from\":\"support@aquablu.example\",\"body\":$(python3 -c 'import json,sys;print(json.dumps(sys.argv[1]))' "$outb")}"
  [ -n "$note" ] && ev="$ev,{\"type\":\"note\",\"at\":$((OUTB+60)),\"author\":\"$owner\",\"body\":$(python3 -c 'import json,sys;print(json.dumps(sys.argv[1]))' "$note")}"
  printf '{"kind":"hubspot-ticket","owner":"%s","stage":"Waiting for Tech","contacts":["%s"],"events":[%s]}\n' "$owner" "$contact" "$ev" >"$LAB/tl/$name.json"
}

echo "=== claim --source H_TICKETS ==="
run claim --source H_TICKETS

# Colleague-owned tickets that must NOT reach his page.
tl luc-cargill-tech  luc@aquablu.example ops@cargill.example \
  "The REFILL+ keeps showing B.14 after the reset." \
  "Our tech team is looking into this, I'll keep you updated.\nLuc"
tl luc-sportcity-techteam luc@aquablu.example fm@sportcity.example \
  "Geen bruiswater meer sinds maandag." \
  "Ons techteam gaat ernaar kijken, ik houd je op de hoogte.\nLuc"
tl natalia-citygym-tech natalia@aquablu.example ops@citygym.example \
  "Unit offline since Friday." \
  "The technical team is looking into this.\nNatalia"
tl luc-duinrell-passing luc@aquablu.example tech@duinrell.example \
  "Hi Luc, Lars installed the unit last year; it now shows B.14, what should we do?"
tl luc-keiron-about luc@aquablu.example ops@keiron.example \
  "The unit shows B.14 again." "" "Should we escalate this to Lars?"
tl luc-footer-thanks luc@aquablu.example chloe@kiosk.example \
  "Hi Lars,
The unit is back online. Thanks!

Kind regards, Chloe Smith - Facility Manager, Cargill Netherlands
Please consider the environment before printing this email."
# Tickets that MUST reach his page.
tl luc-at-mention luc@aquablu.example ops@cargill.example \
  "The unit shows B.14 again." "" "@Lars can you check the PCB on this one?"
tl luc-greet-ask luc@aquablu.example fm@sportcity.example \
  "Hi Lars,
The systems are offline since Monday. Could you check the connectivity?

Met vriendelijke groet, Jan de Vries | SportCity B.V."
tl luc-vocative luc@aquablu.example ops@keiron.example \
  "The unit shows B.14 again." "" "Can you check this, Lars?"
tl lars-own-tech captain mark@partner.example \
  "The machine keeps showing E.A03 after the reset." \
  "Our tech team is looking into this, I'll keep you updated.\nNatalia"

echo
echo "=== observe each ticket with --timeline-file ==="
for f in "$LAB"/tl/*.json; do
  n=$(basename "$f" .json)
  printf '%-26s ' "$n"
  o=$(run observe --source H_TICKETS --ref "ticket-$n" --digest "$n v1" --class routine \
    --title "HubSpot ticket $n" --timeline-file "$f" 2>&1)
  key="$LAB/data/channel-intake/items/$(printf '%s' "$o" | awk '{print $2}')"
  printf '%s ' "$(printf '%s' "$o" | awk '{print $1}')"
  if [ -f "$key" ]; then
    printf -- '-> class=%s awaiting=%s why=%s' "$(awk -F= '$1=="class"{print $2}' "$key")" \
      "$(awk -F= '$1=="awaiting"{print $2}' "$key")" "$(awk -F= '$1=="awaiting_why"{print substr($0,14)}' "$key")"
  else printf '%s' "$o"; fi
  echo
done
printf '[]' | run tickets --owner captain >/dev/null
echo
echo "=== complete --rescanned ==="
run complete --source H_TICKETS --checkpoint c1 --rescanned

echo
echo "=== render the to-do page ==="
env -u FM_ROOT_OVERRIDE FM_HOME="$LAB" FM_CHANNEL_INTAKE_NOW="$NOW" "$REPO/bin/fm-todo-render.sh" render --out "$OUT/todo.html" --date 2026-10-13
echo "rendered $OUT/todo.html"
echo
echo "=== tickets on the 'Needs you now' page ==="
python3 - "$OUT/todo.html" <<'PY'
import re,sys,html
t=open(sys.argv[1]).read()
needs=t.split('<h2>Needs you now',1)[1].split('</table>',1)[0]
rest=t.split('<h2>Needs you now',1)[1].split('</table>',1)[1]
for n in dict.fromkeys(re.findall(r'HubSpot ticket ([\w-]+)', needs)): print('  NEEDS YOU NOW:', n)
for n in dict.fromkeys(re.findall(r'HubSpot ticket ([\w-]+)', rest)): print('  folded (other channel activity):', n)
PY
rm -rf "$LAB"
