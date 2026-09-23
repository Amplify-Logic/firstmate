#!/usr/bin/env bash
# Addendum on the same live home: archived re-read, unchanged re-scan, morning sidecar.
set -u
ROOT=/Users/larstolhurst/.no-mistakes/worktrees/9957e108f4d7/01M3807GDQH8DRHHC1188415J7
H=$1
I() { FM_HOME="$H" FM_ROOT_OVERRIDE="$ROOT" "$ROOT/bin/fm-channel-intake.sh" "$@"; }
R() { FM_HOME="$H" FM_ROOT_OVERRIDE="$ROOT" FM_TODO_BACKLOG_OVERRIDE="$H/backlog.md" "$ROOT/bin/fm-todo-render.sh" "$@"; }
field() { local f; for f in "$H/data/channel-intake/items/$1" "$H/data/channel-intake/archive/$1"; do [ -f "$f" ] && { awk -F= -v k="$2" 'index($0,k"=")==1{print substr($0,length(k)+2)}' "$f"; return; }; done; }
NOW=$(date +%s); HR=3600; IN=$((NOW - 30*HR)); OUT=$((NOW - 28*HR)); LATE=$((NOW - 600))
K=$(cat "$H/keys/frederick")
echo "### 8b. Frederick resolved earlier; re-read shows the partner wrote again after a reply (Lars named)"
cat >"$H/frederick.json" <<J
{"kind":"hubspot-ticket","owner":"natalia@aquablu.example","contacts":["frederick@dealer.example"],
 "events":[{"type":"email","at":$IN,"direction":"inbound","from":"frederick@dealer.example","body":"B.14 again"},
  {"type":"email","at":$OUT,"direction":"outbound","from":"support@aquablu.example","body":"Lars replaced the board remotely, it should be fine now."},
  {"type":"email","at":$LATE,"direction":"inbound","from":"frederick@dealer.example","body":"It failed again this morning."}]}
J
I observe --source H_TICKETS --ref frederick --digest 'frederick v3' --class routine --title "HubSpot ticket frederick" --timeline-file "$H/frederick.json"
echo "in archive: $([ -f "$H/data/channel-intake/archive/$K" ] && echo yes || echo no); in items: $([ -f "$H/data/channel-intake/items/$K" ] && echo yes || echo no)"
echo "archived facts: partner=$(field $K partner) awaiting=$(field $K awaiting) awaiting_since=$(field $K awaiting_since) (expected LATE=$LATE) why=$(field $K awaiting_why)"
echo "state listing:"; I items --state archived | grep -i frederick
echo "### 10. unchanged re-scan read 2 min later makes the line a full timeline re-read"
K2=$(cat "$H/keys/t48375229511")
before=$(field $K2 read_at)
FM_HOME="$H" FM_ROOT_OVERRIDE="$ROOT" FM_CHANNEL_INTAKE_NOW=$((NOW+120)) "$ROOT/bin/fm-channel-intake.sh" observe --source H_TICKETS --ref t48375229511 --digest 't48375229511 v1' --class routine --title "HubSpot ticket t48375229511" --link https://app.hubspot.com/t/t48375229511 --timeline-file "$H/t48375229511.json"
echo "read_at before=$before after=$(field $K2 read_at) updated=$(field $K2 updated)"
echo "### 11. morning sidecar flags a partner ask (older than all) and an undated one"
D=$(date +%F)
printf '{"version":2,"date":"%s","actions":[{"key":"k-m","source":"hubspot","ref":"48622709535","class":"obligation","kind":"reply","title":"Morning partner ask (dated, oldest)","partner_awaiting":true,"awaiting_since":%s,"updated":%s},{"key":"k-u","source":"hubspot","ref":"48622709536","class":"obligation","kind":"reply","title":"Morning partner ask (undated)","partner_awaiting":true,"updated":%s},{"key":"k-o","source":"C_OPS","ref":"m-out","class":"outage","title":"Morning outage","updated":%s}]}\n' "$D" $((NOW - 20*86400)) $((NOW+60)) $((NOW+60)) $((NOW+60)) >"$H/.lavish/today-$D.morning.json"
FM_TODO_RENDER_NOW=$((NOW+180)) R render
P="$H/.lavish/today-$D.html"; cp "$P" "$(dirname "$0")/today-page.html"
python3 - "$P" <<'PY'
import re,sys,html
s=open(sys.argv[1]).read()
m=re.search(r'<div class="strip now">(.*?)</div>',s,re.S)
print("NOW STRIP:")
for li in re.findall(r'<li>(.*?)</li>',m.group(1),re.S):
    print("  -",html.unescape(re.sub('<[^>]+>',' | ',li)).strip(' |'))
sec=s.split('<h2>Replies you owe')[1].split('<h2>')[0] if '<h2>Replies you owe' in s else ''
print("REPLIES YOU OWE (order):")
for w in re.findall(r'<td class="what">(.*?)</td>',sec,re.S):
    print("  -",html.unescape(re.sub('<[^>]+>','|',w)).strip('|')[:150])
PY
echo "### 12. sidecar with partner_awaiting as a string is refused"
cp "$H/.lavish/today-$D.morning.json" "$H/sidecar.good"
sed -i '' 's/"partner_awaiting":true/"partner_awaiting":"true"/' "$H/.lavish/today-$D.morning.json"
FM_TODO_RENDER_NOW=$((NOW+200)) R render; echo "exit=$?"
cp "$H/sidecar.good" "$H/.lavish/today-$D.morning.json"
