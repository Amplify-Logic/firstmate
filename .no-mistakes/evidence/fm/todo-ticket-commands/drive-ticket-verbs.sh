#!/usr/bin/env bash
# Live drive of the to-do page ticket verbs against a disposable lab FM_HOME.
# Usage: drive-ticket-verbs.sh <worktree> <evidence-dir>
set -u
WT=$1 EV=$2
LAB=$(mktemp -d "${TMPDIR:-/tmp}/fm-lab.XXXXXX")
"$WT/bin/fm-lab-home.sh" create "$LAB" >/dev/null
trap 'rm -rf "$LAB"' EXIT
mkdir -p "$LAB/.lavish" "$LAB/data/channel-intake"
printf 'enabled = true\ntimezone = Europe/Amsterdam\ninterval_seconds = 900\ncaptain_names = Lars\nteam_addresses = support@team.example\n' >"$LAB/config/channel-intake"
printf 'C_BRIEF\tslack-channel\tdaily brief channel\nhubspot-lars-tickets\thubspot-tickets\ttickets naming the captain\n' >"$LAB/data/channel-intake/sources.tsv"
: >"$LAB/backlog.md"
E="env -u NO_MISTAKES_GATE -u FM_ROOT_OVERRIDE -u FM_STATE_OVERRIDE -u FM_DATA_OVERRIDE -u FM_CONFIG_OVERRIDE FM_HOME=$LAB FM_TODO_BACKLOG_OVERRIDE=$LAB/backlog.md"
todo() { echo "\$ fm-todo.sh $*"; $E "$WT/bin/fm-todo.sh" "$@"; echo "[exit $?]"; }
render() { $E "$WT/bin/fm-todo-render.sh" render >/dev/null || echo "render failed"; }
intake() { $E "$WT/bin/fm-channel-intake.sh" "$@"; }
DAY=$(TZ=Europe/Amsterdam date +%F)
NOW=$(date +%s)
id_of() { $E "$WT/bin/fm-todo.sh" list | awk -F '\t' -v t="$1" 'index($5, t) { print $1; exit }'; }
col_of() { $E "$WT/bin/fm-todo.sh" list | awk -F '\t' -v t="$1" -v c="$2" 'index($5, t) { print $c; exit }'; }
act_of() { $E "$WT/bin/fm-todo.sh" tickets | awk -F '\t' -v i="TODO_TICKET: $1" -v v="$2" '$1 == i && $4 == v { print $2 }'; }
wakes() { grep -c todo-ticket "$LAB/state/.wake-queue" 2>/dev/null || echo 0; }

echo "== lab FM_HOME: $LAB (today $DAY)"
printf '{"version":2,"date":"%s","actions":[%s]}\n' "$DAY" \
 '{"key":"k1","source":"hubspot","ref":"48576658049","class":"obligation","kind":"reply","title":"Tomra pump leaking","link":"https://app.hubspot.com/contacts/1/record/0-5/48576658049","updated":'"$NOW"'},
  {"key":"k2","source":"slack","ref":"C1-1","class":"obligation","kind":"reply","title":"Queco question in Slack","updated":'"$NOW"'},
  {"key":"k3","source":"hubspot","ref":"48600120191","class":"obligation","kind":"reply","title":"Neshu firmware ticket","updated":'"$NOW"'},
  {"key":"k4","source":"slack","ref":"C9-9","class":"obligation","kind":"reply","title":"Dealer escalation","link":"https://app.hubspot.com/help-desk/1/view/2/ticket/49033119384/thread/5","updated":'"$NOW"'},
  {"key":"k5","source":"slack","ref":"C7-7","class":"obligation","kind":"reply","title":"Two tickets in one thread https://app.hubspot.com/contacts/1/record/0-5/11111111111","link":"https://app.hubspot.com/contacts/1/record/0-5/22222222222","updated":'"$NOW"'}' \
 >"$LAB/.lavish/today-$DAY.morning.json"
render
TOMRA=$(id_of Tomra) NESHU=$(id_of Neshu) QUECO=$(id_of Queco) DEALER=$(id_of Dealer) TWO=$(id_of 'Two tickets')
REV=$(col_of Tomra 4)
echo; echo "== S3 adversarial: free text, untargeted, no-ticket row"
for line in 'close the loop with Natalia first' "waiting on Luc's answer" 'reassign Fauve van Dijk' 'priority high'; do
  todo command --item "$TOMRA" "$line"
done
todo command 'close'
todo command --item "$QUECO" 'close'
echo "wake lines so far: $(wakes)"
todo tickets
echo; echo "== S4 adversarial: row naming two tickets; stale revision"
todo command --item "$TWO" 'close'
todo command --item "$TOMRA" --rev deadbeef 'close'
echo; echo "== S1 queue each verb"
todo command --item "$TOMRA" --rev "$REV" 'reassign Fauve'
todo command --item "$TOMRA" 'note: customer replaced the pump' 'Waiting'
todo command --item "$NESHU" 'close: fixed by firmware 2.4'
todo command --item "$DEALER" 'close'
todo command --item "$TOMRA" 'reassign Fauve'
echo "wake lines: $(wakes)"; grep todo-ticket "$LAB/state/.wake-queue" | tail -1
todo tickets
render; cp "$LAB/.lavish/today-$DAY.html" "$EV/page-1-pending.html"
echo; echo "== S5 Firstmate records results"
todo ticket-done --item "$TOMRA" --action "$(act_of "$TOMRA" note)"
todo ticket-done --item "$TOMRA" --action "$(act_of "$TOMRA" note)" --evidence 'internal note added'
echo "Tomra state after done note: $(col_of Tomra 2)"
todo ticket-done --item "$TOMRA" --action "$(act_of "$TOMRA" reassign)" --evidence 'owner Fauve van Dijk'
echo "Tomra state after done reassign: $(col_of Tomra 2)"
todo ticket-done --item "$NESHU" --action "$(act_of "$NESHU" close)" --evidence 'stage Closed'
echo "Neshu state after done close: $(col_of Neshu 2)"
todo ticket-failed --item "$DEALER" --action "$(act_of "$DEALER" close)" --evidence 'ticket is locked by Natalia'
echo "Dealer state after failed close: $(col_of Dealer 2)"
echo "-- closed row keeps pending/failed marker: close+done on Dealer, then failure"
todo command --item "$DEALER" 'close' 'done'
render; cp "$LAB/.lavish/today-$DAY.html" "$EV/page-2-closed-pending.html"
todo ticket-failed --item "$DEALER" --action "$(act_of "$DEALER" close)" --evidence 'ticket still locked'
render; cp "$LAB/.lavish/today-$DAY.html" "$EV/page-3-results.html"
todo tickets
echo; echo "== journal (last 6)"; tail -6 "$LAB/data/todo/journal"
