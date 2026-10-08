#!/usr/bin/env bash
# Live drive of the to-do page fixes against a disposable FM_HOME.
set -u
ROOT=$1; LAB=$2
I="$ROOT/bin/fm-channel-intake.sh"; T="$ROOT/bin/fm-todo.sh"; R="$ROOT/bin/fm-todo-render.sh"
T0900=1791442800; T1000=1791446400; T1030=1791448200; T1100=1791450000; T1500=1791464400
OCT5=1791183600; OCT7=1791356400
intake() { local n=$1; shift; echo "\$ fm-channel-intake.sh $*  [at $(TZ=Europe/Amsterdam date -r $n '+%a %d %b %H:%M')]"; FM_HOME="$LAB" FM_ROOT_OVERRIDE="$ROOT" FM_CHANNEL_INTAKE_NOW="$n" "$I" "$@" 2>&1; echo "  -> exit $?"; }
todo() { local n=$1; shift; echo "\$ fm-todo.sh $*  [at $(TZ=Europe/Amsterdam date -r $n '+%a %d %b %H:%M')]"; FM_HOME="$LAB" FM_ROOT_OVERRIDE="$ROOT" FM_TODO_NOW="$n" FM_TODO_BACKLOG_OVERRIDE="$LAB/backlog.md" "$T" "$@" 2>&1; echo "  -> exit $?"; }
render() { local n=$1; echo "\$ fm-todo-render.sh render  [at $(TZ=Europe/Amsterdam date -r $n '+%a %d %b %H:%M')]"; FM_HOME="$LAB" FM_ROOT_OVERRIDE="$ROOT" FM_TODO_RENDER_NOW="$n" FM_TODO_BACKLOG_OVERRIDE="$LAB/backlog.md" "$R" render 2>&1 | tail -2; echo "  -> exit $?"; }
id_of() { FM_HOME="$LAB" FM_ROOT_OVERRIDE="$ROOT" FM_TODO_NOW=$T1500 FM_TODO_BACKLOG_OVERRIDE="$LAB/backlog.md" "$T" list | awk -F '\t' -v t="$1" 'index($5,t){print $1; exit}'; }
q() { FM_HOME="$LAB" FM_ROOT_OVERRIDE="$ROOT" FM_CHANNEL_INTAKE_NOW="$1" "$I" "${@:2}" >/dev/null 2>&1; }

mkdir -p "$LAB/config" "$LAB/data/channel-intake" "$LAB/.lavish"
printf 'enabled = true\ntimezone = Europe/Amsterdam\ninterval_seconds = 900\ncaptain_names = Lars Tolhurst\n' >"$LAB/config/channel-intake"
printf 'C_SUPPORT\tslack-channel\tsupport channel\nD_DMS\tslack-dms\tDMs with Natalia and Queco\nCAL\tcalendar\tLars calendar\nA_RMA\tasana-projects\tPartner RMA board and tasks assigned to Lars\nH_TICKETS\thubspot-tickets\tLars HubSpot tickets\nFLEET\ttelemetry-fleet-alerts\tfleet telemetry\n' >"$LAB/data/channel-intake/sources.tsv"
: >"$LAB/backlog.md"

echo "################ S5 adversarial: observe refusals"
intake $T0900 observe --source C_SUPPORT --ref 1791442800.1 --digest x
intake $T0900 observe --source FLEET --condition b14 --count 3 --units systems --digest u
intake $T0900 observe --source FLEET --condition freezing --count 2 --units '867280069323517 (-1.0 C), 867280069323962 (0.5 C)' --digest f
intake $T0900 observe --source FLEET --condition freezing --count 1 --units '867280069323962 (0.5 C)' --digest g

echo; echo "################ seed asks (some days old, with rotting relative times)"
intake $OCT5 observe --source C_SUPPORT --ref 1791183600.5 --digest a --class obligation --title 'tidy the internal wiki'
intake $OCT5 observe --source C_SUPPORT --ref 1791183600.6 --digest a --class obligation --title 'PARTNER WAITING 14 DAYS - Kasper asked yesterday about the spare filters'
intake $OCT7 observe --source C_SUPPORT --ref 1791356400.1 --digest b --class obligation --partner --title 'Natalia relays a dealer question on cooling'
intake $T0900 observe --source C_SUPPORT --ref 1791442800.2 --digest c --class obligation --title 'black screen at 869951034894703'
intake $T0900 observe --source A_RMA --ref rma-17 --digest d --class obligation --title 'Partner RMA: tower return costs'
intake $T0900 observe --source C_SUPPORT --ref 1791442800.3 --digest e --class obligation --title 'Send the quote by tomorrow'
intake $T0900 observe --source C_SUPPORT --ref 1791442800.4 --digest e --class obligation --title 'Approve 30 days extension'
intake $T0900 observe --source C_SUPPORT --ref 1791442800.7 --digest e --class obligation --title 'Return within 14 days?'
intake $T0900 observe --source FLEET --ref ota-9 --digest o --class obligation --title 'Raise thermostat OTA? 3 systems'
intake $T0900 observe --source C_SUPPORT --ref 1791442800.8 --digest h --class urgent --title 'invoice question from finance'
printf '{"version":2,"date":"2026-10-08","actions":[{"key":"k-t","source":"firstmate","ref":"voice-pr","class":"obligation","kind":"approval","title":"merge the voice fix?","updated":%s},{"key":"k-yb","source":"hubspot","ref":"t-45","class":"obligation","kind":"reply","title":"YellowBeard consumption report","partner_awaiting":true,"awaiting_since":%s,"updated":%s}]}\n' $T0900 $OCT5 $T0900 >"$LAB/.lavish/today-2026-10-08.morning.json"
todo $T0900 sweep-start
render $T0900

echo; echo "################ S2: Lars closes one himself (actor Lars)"
todo $T1000 close --item "$(id_of 'invoice question')" --evidence 'Lars answered in the thread at 09:55' --actor Lars

echo; echo "################ S1: 30-minute pass claim lists recheck: lines"
intake $T1030 claim --source C_SUPPORT
todo $T1030 sweep-start --pass
todo $T1100 verify --item "$(id_of 'black screen')" --how 'read the Slack thread'
todo $T1100 verify --item "$(id_of 'Natalia relays')" --how 'read the Slack thread'
intake $T1100 complete --source C_SUPPORT --checkpoint p1

echo; echo "################ S4: coverage sources get their own reads"
intake $T1030 claim --source D_DMS
intake $T1030 claim --source CAL
intake $T1030 claim --source A_RMA
intake $T1030 complete --source A_RMA --checkpoint a1 --relisted
echo "(second claim same day: expect no relist)"; intake $T1100 claim --source A_RMA
intake $T1030 complete --source C_SUPPORT --checkpoint x --relisted

echo; echo "################ S4b adversarial: HubSpot pass needs its tickets + rescan"
intake $T1030 claim --source H_TICKETS
intake $T1030 complete --source H_TICKETS --checkpoint h1 --rescanned
printf '[{"id":"49149551973","subject":"Problem with the unit","stage":"Waiting on us","last_in":"2026-10-08T06:24:04Z","last_out":"","link":"https://app.example/49149551973"}]' >"$LAB/tickets.json"
echo "\$ fm-channel-intake.sh tickets --owner captain < tickets.json"; FM_HOME="$LAB" FM_ROOT_OVERRIDE="$ROOT" FM_CHANNEL_INTAKE_NOW=$T1030 "$I" tickets --owner captain <"$LAB/tickets.json"; echo "  -> exit $?"
intake $T1030 complete --source H_TICKETS --checkpoint h1
intake $T1030 complete --source H_TICKETS --checkpoint h1 --rescanned

echo; echo "################ S5b: resolve --waiting date rule"
K=$(basename "$(grep -l "Approve 30 days" "$LAB"/data/channel-intake/items/*)")
for r in 'waiting on Lars for 3 decisions' 'Lars will answer Sat' 'waiting on you' 'Lars will decide 2 options'; do intake $T1100 resolve --item "$K" --waiting --reason "$r"; done
for r in 'Queco will send you the logs' 'Lars handed it to Sara' 'waiting on Lars until 14 Oct' 'Lars will answer Friday'; do intake $T1100 resolve --item "$K" --waiting --reason "$r"; done

echo; echo "################ S3: mine on YellowBeard; final render"
todo $T1100 command --item "$(id_of 'YellowBeard')" mine
render $T1500
