#!/usr/bin/env bash
# Live drive of the to-do page fixes against a disposable lab home, real clock.
set -u
WT=/Users/larstolhurst/.no-mistakes/worktrees/9957e108f4d7/01M4DXBK2S9MRA80NVB7C97AZ1
E=/Users/larstolhurst/.no-mistakes/evidence/01M4DXBK2S9MRA80NVB7C97AZ1
LAB=$(mktemp -d "${TMPDIR:-/tmp}/fm-lab.XXXXXX")
"$WT/bin/fm-lab-home.sh" create "$LAB" >/dev/null
echo "$LAB" >/tmp/fmlive-scripts/lab-path
export FM_HOME="$LAB"
unset NO_MISTAKES_GATE FM_GATE_REFUSE_BYPASS FM_ROOT_OVERRIDE FM_STATE_OVERRIDE FM_DATA_OVERRIDE FM_CONFIG_OVERRIDE FM_PROJECTS_OVERRIDE
I="$WT/bin/fm-channel-intake.sh"; T="$WT/bin/fm-todo.sh"; R="$WT/bin/fm-todo-render.sh"
run() { printf '\n$ %s\n' "$*"; "$@" 2>&1; printf '[exit %s]\n' "$?"; }
mkdir -p "$LAB/data/channel-intake" "$LAB/.lavish"
printf 'enabled = true\ntimezone = Europe/Amsterdam\ninterval_seconds = 900\ncaptain_names = Lars Tolhurst\nteam_addresses = support@aquablu.example\n' >"$LAB/config/channel-intake"
printf 'C_BRIEF\tslack-channel\tdaily brief channel\nD_DMS\tslack-dms\tDMs with Natalia and Queco\nCAL\tcalendar\tthe captain calendar\nA_REQ\tasana-projects\ttasks assigned to the captain\nA_RMA\tasana-projects\tpartner RMA board\nH_TICKETS\thubspot-tickets\ttickets naming the captain\nFLEET\ttelemetry-fleet-alerts\tfleet telemetry\n' >"$LAB/data/channel-intake/sources.tsv"
NOW=$(date +%s); D=86400; DAY=$(date +%F)
echo "=== LAB=$LAB  now=$(date)"

echo; echo "##### S5 adversarial: observe refusals"
run "$I" observe --source C_BRIEF --ref 1791000000.10 --digest a
run "$I" observe --source FLEET --condition b14 --count 3 --units systems --digest u
run "$I" observe --source FLEET --condition freezing --count 2 --units '867280069323517 (-1.0 C), 867280069323962 (0.5 C)' --digest f
run "$I" observe --source FLEET --condition freezing --count 1 --units '867280069323962 (0.5 C)' --digest g

echo; echo "##### Seed asks (ask time via --source-epoch)"
run "$I" observe --source C_BRIEF --ref r-wiki --digest a --class obligation --source-epoch $((NOW-5*D)) --title 'tidy the internal wiki'
run "$I" observe --source C_BRIEF --ref r-relay --digest b --class obligation --partner --source-epoch $((NOW-2*D)) --title 'Natalia relays a dealer question'
run "$I" observe --source C_BRIEF --ref r-sys --digest c --class obligation --source-epoch $((NOW-1*D)) --title 'black screen at 869951034894703'
run "$I" observe --source A_RMA --ref r-rma --digest d --class obligation --source-epoch $((NOW-3*3600)) --title 'Partner RMA: tower return costs'
run "$I" observe --source C_BRIEF --ref r-rot --digest e --class obligation --source-epoch $((NOW-3*D)) --title 'PARTNER WAITING 14 DAYS - Kasper asked yesterday'
run "$I" observe --source C_BRIEF --ref r-dead --digest e2 --class obligation --source-epoch $((NOW-3600)) --title 'Send the quote by tomorrow'
run "$I" observe --source C_BRIEF --ref r-lars --digest f --class obligation --source-epoch $((NOW-4*3600)) --title 'invoice question from finance'
run "$I" observe --source C_BRIEF --ref r-chat --digest g --class routine --title 'lunch is in the kitchen'
run "$I" observe --source FLEET --ref ota-1 --digest h --class obligation --title 'Raise thermostat OTA? 3 systems'
cat >"$LAB/.lavish/today-$DAY.morning.json" <<J
{"version":2,"date":"$DAY","actions":[
{"key":"k-t","source":"firstmate","ref":"voice-pr","class":"obligation","kind":"approval","title":"merge the voice fix?","tooling":true,"updated":$NOW},
{"key":"k-y","source":"hubspot","ref":"t-45","class":"obligation","kind":"reply","title":"YellowBeard consumption report","partner_awaiting":true,"awaiting_since":$((NOW-6*D)),"updated":$NOW}]}
J
printf '[{"id":"49149551973","subject":"Problem with the unit","stage":"Waiting on us","last_in":"%sT06:24:04Z","last_out":"","link":"https://app.hubspot.com/49149551973"}]' "$DAY" >/tmp/fmlive-scripts/tickets.json
run "$I" tickets --owner captain </tmp/fmlive-scripts/tickets.json
# Re-observe the system-id ask now so its last read is newest: order must not follow last check.
sleep 1; run "$I" observe --source C_BRIEF --ref r-sys --digest c2 --class obligation
echo; echo "##### Morning sweep + first render"
run "$T" sweep-start
run "$R" render
cp "$LAB/.lavish/today-$DAY.html" "$E/page-1-morning.html"

echo; echo "##### S1: claim prints recheck lines + kind-specific reads"
sleep 1; run "$I" claim
echo; echo "##### S1: pass floor, re-read one, Lars closes one, skip the rest, complete counts misses"
run "$T" sweep-start --pass
ID_RELAY=$("$T" list | awk -F'\t' 'index($5,"Natalia relays"){print $1;exit}')
ID_LARS=$("$T" list | awk -F'\t' 'index($5,"invoice question"){print $1;exit}')
ID_YB=$("$T" list | awk -F'\t' 'index($5,"YellowBeard"){print $1;exit}')
sleep 1
run "$T" verify --item "$ID_RELAY" --how 'read the Slack thread'
run "$T" close --item "$ID_LARS" --evidence 'Lars answered in the thread' --actor Lars
run "$I" complete --source C_BRIEF --checkpoint c-1

echo; echo "##### S4 adversarial: HubSpot complete without this pass's tickets / rescan"
run "$I" complete --source H_TICKETS --checkpoint h1 --rescanned
run "$I" tickets --owner captain </tmp/fmlive-scripts/tickets.json
run "$I" complete --source H_TICKETS --checkpoint h1
run "$I" complete --source H_TICKETS --checkpoint h1 --rescanned
run "$I" complete --source A_REQ --checkpoint a1 --relisted
run "$I" claim --source A_REQ

echo; echo "##### S3: mine keeps YellowBeard tracked, not surfaced"
run "$T" command --item "$ID_YB" mine

echo; echo "##### S5 adversarial: resolve --waiting needs a date or a named non-captain owner"
KEY=$("$I" items --state open | awk -F'\t' 'index($0,"tidy the internal wiki"){print $1;exit}')
echo "ledger key=$KEY"
for r in 'later' 'Lars will do it later' 'He will reply later' 'Everything will settle later' 'Whoever will pick it up' 'Mine will wait' 'waiting on you'; do
  run "$I" resolve --item "$KEY" --waiting --reason "$r"
done
run "$I" resolve --item "$KEY" --waiting --reason 'Queco will send the logs'
run "$I" resolve --item "$KEY" --waiting --reason 'waiting on Lars until 14 Oct'

echo; echo "##### Final render"
run "$R" render
cp "$LAB/.lavish/today-$DAY.html" "$E/page-2-after-pass.html"
run "$T" list
