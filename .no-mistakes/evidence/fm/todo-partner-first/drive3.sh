#!/usr/bin/env bash
# Resolved partner ticket, synced closed, then the partner writes again: the
# re-read records fresh facts on the archived record and the reopened to-do
# item ranks partner-first on those current facts.
set -u
ROOT=/Users/larstolhurst/.no-mistakes/worktrees/9957e108f4d7/01M3807GDQH8DRHHC1188415J7
H=$1
I() { FM_HOME="$H" FM_ROOT_OVERRIDE="$ROOT" FM_CHANNEL_INTAKE_NOW=$T "$ROOT/bin/fm-channel-intake.sh" "$@"; }
R() { FM_HOME="$H" FM_ROOT_OVERRIDE="$ROOT" FM_TODO_RENDER_NOW=$T FM_TODO_BACKLOG_OVERRIDE="$H/backlog.md" "$ROOT/bin/fm-todo-render.sh" render >/dev/null; }
L() { FM_HOME="$H" FM_ROOT_OVERRIDE="$ROOT" FM_TODO_NOW=$T FM_TODO_BACKLOG_OVERRIDE="$H/backlog.md" "$ROOT/bin/fm-todo.sh" list | grep 'Dealer Oost'; }
NOW=$(date +%s); T=$((NOW+300)); IN=$((NOW - 50*3600))
cat >"$H/oost.json" <<J
{"kind":"hubspot-ticket","owner":"captain","contacts":["jan@oost.example"],
 "events":[{"type":"email","at":$IN,"direction":"inbound","from":"jan@oost.example","body":"Waar blijft de onderdelenlevering?"}]}
J
key=$(I observe --source H_TICKETS --ref oost --digest oost1 --class routine --title 'Dealer Oost parts delivery' --timeline-file "$H/oost.json" | awk '{print $2}')
R; echo "after first read:  $(L)"
T=$((T+60)); I resolve --item "$key" --reason 'answered by phone' >/dev/null; R; echo "after resolve:     $(L)"
T=$((T+60)); LATE=$((T-120))
cat >"$H/oost.json" <<J
{"kind":"hubspot-ticket","owner":"captain","contacts":["jan@oost.example"],
 "events":[{"type":"email","at":$IN,"direction":"inbound","from":"jan@oost.example","body":"Waar blijft de onderdelenlevering?"},
  {"type":"email","at":$((IN+3600)),"direction":"outbound","from":"lars@aquablu.example","body":"Komt deze week."},
  {"type":"email","at":$LATE,"direction":"inbound","from":"jan@oost.example","body":"Nog steeds niets ontvangen."}]}
J
I observe --source H_TICKETS --ref oost --digest oost2 --class routine --title 'Dealer Oost parts delivery' --timeline-file "$H/oost.json"
R; echo "after re-read:     $(L)"
D=$(date +%F); P="$H/.lavish/today-$D.html"; cp "$P" "$(dirname "$0")/today-page.html"
sed -n '/<div class="strip now">/,/<\/div>/p' "$P" | grep -o '<li>.*</li>' | sed 's/<[^>]*>/ | /g;s/  */ /g'
grep -o 'reopened[^<]*' "$P" | head -2
echo "awaiting_since=$(awk -F= '/^awaiting_since=/{print $2}' $H/data/channel-intake/archive/$key) LATE=$LATE"
