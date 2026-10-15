#!/usr/bin/env bash
# Drive the real to-do renderer for Tue 13 Oct 2026 in a throwaway FM_HOME.
# Usage: drive-13oct.sh ROOT OUTDIR LABEL
set -eu
ROOT=$1 OUT=$2 LABEL=$3
H=$(mktemp -d "${TMPDIR:-/tmp}/fm-todo-13oct.XXXXXX")
trap 'rm -rf "$H"' EXIT
mkdir -p "$H/config" "$H/data/channel-intake" "$H/.lavish"
printf 'enabled = true\ntimezone = Europe/Amsterdam\ninterval_seconds = 900\ncaptain_names = Lars\nteam_addresses = support@team.example\n' >"$H/config/channel-intake"
printf 'C_BRIEF\tslack-channel\tdaily brief channel\nH_TICKETS\thubspot-tickets\ttickets naming the captain\n' >"$H/data/channel-intake/sources.tsv"
: >"$H/backlog.md"
t=1791874800            # 2026-10-13 09:00 CEST
fri=$((t - 86400 * 4)) mon=$((t - 86400))
run() { env FM_HOME="$H" FM_ROOT_OVERRIDE="$ROOT" FM_TODO_BACKLOG_OVERRIDE="$H/backlog.md" "$@"; }

# Scenario B input: an awaiting partner reached through the intake ledger
# (a HubSpot ticket timeline: partner asked, team promised Lars is on it).
cat >"$H/csg.json" <<J
{"kind":"hubspot-ticket","owner":"natalia@team.example","stage":"Waiting for Tech",
 "contacts":["ops@csg.example"],
 "events":[{"type":"email","at":$fri,"direction":"inbound","from":"ops@csg.example","body":"Any news on the modem replacement?"},
  {"type":"email","at":$((fri + 3600)),"direction":"outbound","from":"support@team.example","body":"Lars is looking into this. I will keep you updated."}]}
J
run FM_CHANNEL_INTAKE_NOW="$((t - 1800))" "$ROOT/bin/fm-channel-intake.sh" observe --source H_TICKETS \
  --ref 48375229511 --digest v1 --class routine --title 'CSG modem replacement (ledger)' --timeline-file "$H/csg.json" >/dev/null
# Adversarial inputs: a live outage, and an internal urgent ask that only waited long.
run FM_CHANNEL_INTAKE_NOW="$((t - 1200))" "$ROOT/bin/fm-channel-intake.sh" observe --source C_BRIEF \
  --ref out-1 --digest o1 --class outage --title 'Office tower leaking (internal outage)' >/dev/null
run FM_CHANNEL_INTAKE_NOW="$((t - 86400 * 20))" "$ROOT/bin/fm-channel-intake.sh" observe --source C_BRIEF \
  --ref urg-1 --digest u1 --class urgent --title 'Internal wiki cleanup (urgent, 20 days old)' >/dev/null

# Scenario A input: the 13 Oct morning sidecar.
cat >"$H/.lavish/today-2026-10-13.morning.json" <<J
{"version":2,"date":"2026-10-13","actions":[
{"key":"k-m1","source":"calendar","ref":"breakfast","class":"deadline","title":"09:00 Aquabreakfast","ends_at":"2026-10-13T09:45:00+02:00","updated":$t},
{"key":"k-m2","source":"calendar","ref":"onboarding","class":"deadline","title":"12:30 Onboarding","ends_at":"2026-10-13T13:30:00+02:00","updated":$t},
{"key":"k-m3","source":"calendar","ref":"ashlyn","class":"deadline","title":"13:30 Ashlyn/Fauve","ends_at":"2026-10-13T14:00:00+02:00","updated":$t},
{"key":"k-m4","source":"calendar","ref":"rma","class":"deadline","title":"15:00 RMA process","ends_at":"2026-10-13T16:00:00+02:00","updated":$t},
{"key":"k-pm","source":"calendar","ref":"selecta-call","class":"deadline","title":"16:30 Selecta partner call","partner":true,"ends_at":"2026-10-13T17:00:00+02:00","updated":$t},
{"key":"k-sel","source":"hubspot","ref":"selecta","class":"obligation","title":"Selecta service visit","partner":true,"asked_at":$((t - 86400 * 21)),"updated":$t},
{"key":"k-old","source":"hubspot","ref":"old","class":"obligation","title":"Old customer obligation","partner":true,"asked_at":$((t - 86400 * 13)),"updated":$t},
{"key":"k-kaf","source":"hubspot","ref":"kaffeknappen","class":"obligation","kind":"reply","title":"Kaffeknappen PCB promise","partner_awaiting":true,"awaiting_since":$mon,"why":"you promised the PCB on Monday","updated":$t},
{"key":"k-int","source":"slack","ref":"int","class":"obligation","title":"Internal expense approval","asked_at":$((t - 86400 * 5)),"updated":$t}
]}
J
run FM_TODO_RENDER_NOW="$((t + 600))" "$ROOT/bin/fm-todo-render.sh" render >/dev/null
cp "$H/.lavish/today-2026-10-13.html" "$OUT/today-2026-10-13.$LABEL.html"
echo "== $LABEL: Needs you now header =="
grep -o '<h2>Needs you now<small>[^<]*' "$OUT/today-2026-10-13.$LABEL.html" | sed 's/.*<small>//'
echo "== $LABEL: Needs you now order =="
sed -n '/<h2>Needs you now/,/<\/table>/p' "$OUT/today-2026-10-13.$LABEL.html" | grep -o 'class="what">[^<]*' | sed 's/^class="what">//' | nl -w2 -s'. '
