#!/usr/bin/env bash
# Live driver: stands up an isolated firstmate home and drives the real
# bin/fm-channel-intake.sh and bin/fm-todo-render.sh CLIs with HubSpot ticket
# timelines shaped like the 23 Sep back-sweep rows. Real wall clock, no NOW pins.
set -u
ROOT=/Users/larstolhurst/.no-mistakes/worktrees/9957e108f4d7/01M3807GDQH8DRHHC1188415J7
EV=/Users/larstolhurst/.no-mistakes/evidence/01M3807GDQH8DRHHC1188415J7
H=$(mktemp -d "${TMPDIR:-/tmp}/fm-partner-live.XXXXXX")
mkdir -p "$H/config" "$H/state" "$H/reports" "$H/data/channel-intake" "$H/.lavish"
cat >"$H/config/channel-intake" <<CFG
enabled = true
timezone = Europe/Amsterdam
interval_seconds = 900
report_dir = $H/reports
captain_names = Lars Tolhurst
captain_addresses = lars@aquablu.example
team_addresses = support@aquablu.example
rescan_interval_seconds = 3600
CFG
printf 'C_OPS\tslack-channel\tops channel, top-level messages\n' >"$H/data/channel-intake/sources.tsv"
printf 'H_TICKETS\thubspot-tickets\ttickets owned by or naming the captain\n' >>"$H/data/channel-intake/sources.tsv"
: >"$H/backlog.md"
I() { FM_HOME="$H" FM_ROOT_OVERRIDE="$ROOT" "$ROOT/bin/fm-channel-intake.sh" "$@"; }
R() { FM_HOME="$H" FM_ROOT_OVERRIDE="$ROOT" FM_TODO_BACKLOG_OVERRIDE="$H/backlog.md" "$ROOT/bin/fm-todo-render.sh" "$@"; }
field() { local f; for f in "$H/data/channel-intake/items/$1" "$H/data/channel-intake/archive/$1"; do [ -f "$f" ] && { awk -F= -v k="$2" 'index($0,k"=")==1{print substr($0,length(k)+2)}' "$f"; return; }; done; }
NOW=$(date +%s); HR=3600
IN=$((NOW - 30*HR)); OUT=$((NOW - 28*HR))
tl() { cat >"$H/$1.json"; }

# Frederick: colleague-owned, Lars named only in the body, unchanged >24h.
tl frederick <<J
{"kind":"hubspot-ticket","owner":"natalia@aquablu.example","contacts":["frederick@dealer.example"],
 "companies":[{"domain":"dealer.example"}],
 "events":[{"type":"email","at":$IN,"direction":"inbound","from":"frederick@dealer.example","body":"The dispenser still shows B.14 after the swap. What next?"},
  {"type":"email","at":$OUT,"direction":"outbound","from":"support@aquablu.example","body":"Hi Frederick,\nLars is looking into this, and I will keep you updated.\nNatalia"}]}
J
# 48375229511: no contact/company resolved, partner only in the mail itself.
tl t48375229511 <<J
{"kind":"hubspot-ticket","owner":"natalia@aquablu.example",
 "events":[{"type":"email","at":$((IN - 5*86400)),"direction":"inbound","from":"rachel@caffeine.example","body":"Any news on the syrup availability?"},
  {"type":"email","at":$((OUT - 5*86400)),"direction":"outbound","from":"support@aquablu.example","body":"Lars is following up on this.\nNatalia"}]}
J
# Waiting on contact stage, colleague @Lars note unanswered.
tl ns-note <<J
{"kind":"hubspot-ticket","owner":"luc@aquablu.example","stage":"Waiting on contact","contacts":["chloe@kiosk.example"],
 "events":[{"type":"email","at":$IN,"direction":"inbound","from":"chloe@kiosk.example","body":"Waar vinden we het serienummer?"},
  {"type":"note","at":$OUT,"author":"luc@aquablu.example","body":"@Lars see attached pictures"}]}
J
# Auto-acknowledgement only: a HubSpot send with no EMAIL engagement.
tl autoack <<J
{"kind":"hubspot-ticket","owner":"captain","contacts":["alex@workplace.example"],"last_message_sent_at":$((IN + 240)),
 "events":[{"type":"email","at":$IN,"direction":"inbound","from":"alex@workplace.example","body":"Could the delivery charge be amended?"}]}
J
# Tech promise, no Lars named.
tl techpromise <<J
{"kind":"hubspot-ticket","owner":"natalia@aquablu.example","contacts":["mark@office.example"],
 "events":[{"type":"email","at":$IN,"direction":"inbound","from":"mark@office.example","body":"E.A03 keeps coming back."},
  {"type":"email","at":$OUT,"direction":"outbound","from":"support@aquablu.example","body":"Our tech team is looking into this, I'll keep you updated.\nNatalia"}]}
J
# Colleague answered from her own mailbox (not a team address): does not discharge.
tl ownmailbox <<J
{"kind":"hubspot-ticket","owner":"lars@aquablu.example","contacts":["pieter@hotel.example"],"last_message_sent_at":$OUT,
 "events":[{"type":"email","at":$IN,"direction":"inbound","from":"pieter@hotel.example","body":"Is the invoice corrected yet?"},
  {"type":"email","at":$OUT,"direction":"outbound","from":"natalia@aquablu.example","body":"I have asked finance about it."}]}
J
# --- adversarial: must NOT be flagged ---
tl answered <<J
{"kind":"hubspot-ticket","owner":"natalia@aquablu.example","contacts":["rachel@caffeine.example"],
 "events":[{"type":"email","at":$IN,"direction":"inbound","from":"rachel@caffeine.example","body":"Any news?"},
  {"type":"email","at":$OUT,"direction":"outbound","from":"support@aquablu.example","body":"Lars is looking into this. I will keep you updated."},
  {"type":"email","at":$((OUT+3600)),"direction":"outbound","from":"support@aquablu.example","body":"The SIMs are active again."}]}
J
tl chase <<J
{"kind":"hubspot-ticket","owner":"captain","stage":"Waiting on contact","contacts":["ruud@kantoor.example"],
 "events":[{"type":"email","at":$IN,"direction":"inbound","from":"ruud@kantoor.example","body":"De tap geeft geen water."},
  {"type":"email","at":$OUT,"direction":"outbound","from":"support@aquablu.example","author":"captain","body":"Following up on my previous email: could you send the serial number?\nKun je de filter nakijken? Laat het me weten.\nLars"}]}
J
tl uninvolved <<J
{"kind":"hubspot-ticket","owner":"luc@aquablu.example","contacts":["john@site.example"],
 "events":[{"type":"email","at":$IN,"direction":"inbound","from":"john@site.example","body":"No sparkling water, send a technician."}]}
J
tl internal <<J
{"kind":"hubspot-ticket","owner":"luc@aquablu.example","contacts":["joao@aquablu.example"],
 "events":[{"type":"note","at":$OUT,"author":"luc@aquablu.example","body":"@Lars can you check the PCB stock?"}]}
J

echo "### home: $H"
echo "### 1. claim for the HubSpot source (first claim: stages + rescan lines)"
I tick >/dev/null 2>&1
I claim --source H_TICKETS
echo "### 2. an outage and an urgent item arrive on the ops channel"
I observe --source C_OPS --ref out-1 --digest 'site down' --class outage --title 'Service outage at Schiphol site'
I observe --source C_OPS --ref urg-1 --digest 'urgent' --class urgent --title 'Urgent: CEO demo unit offline'
echo "### 3. the re-scan observes each ticket with its timeline (all handed in as routine)"
mkdir -p "$H/keys"; K() { cat "$H/keys/$1"; }
for t in frederick t48375229511 ns-note autoack techpromise ownmailbox answered chase uninvolved internal; do
  line=$(I observe --source H_TICKETS --ref "$t" --digest "$t v1" --class routine --title "HubSpot ticket $t" --link "https://app.hubspot.com/t/$t" --timeline-file "$H/$t.json")
  awk '{print $2}' <<<"$line" >"$H/keys/$t"
  printf '%-14s %-60s partner=%s awaiting=%s class=%s\n    why=%s\n' "$t" "$line" "$(field "$(K $t)" partner)" "$(field "$(K $t)" awaiting)" "$(field "$(K $t)" class)" "$(field "$(K $t)" awaiting_why)"
done
I complete --source H_TICKETS --checkpoint "$NOW" --rescanned
echo "### 4. second claim within rescan interval (rescan line should be absent)"
I claim --source H_TICKETS
echo "### 5. todo summary"
I todo
echo "### 6. brief (What needs you)"
I brief | sed -n '/^## What needs you/,/^## [^W]/p'
echo "### 7. render the day page"
R render
P=$(ls "$H"/.lavish/today-*.html | head -1)
cp "$P" "$EV/today-page.html"
echo "page=$P"
python3 - "$P" <<'PY'
import re,sys,html
s=open(sys.argv[1]).read()
m=re.search(r'<div class="strip now">(.*?)</div>',s,re.S)
print("NOW STRIP:")
for li in re.findall(r'<li>(.*?)</li>',m.group(1) if m else '',re.S):
    print("  -",html.unescape(re.sub('<[^>]+>',' ',li)).split('  ')[0][:200].strip())
sec=s.split('<h2>Replies you owe')[1] if '<h2>Replies you owe' in s else ''
print("REPLIES YOU OWE (order):")
for w in re.findall(r'<td class="what">(.*?)</td>',sec.split('<h2>')[0],re.S):
    print("  -",html.unescape(re.sub('<[^>]+>','|',w)).strip('|')[:140])
PY
echo "### 8. resolve Frederick, then a later re-read finds the partner writing again"
I resolve --item "$(K frederick)" --reason 'replied to Frederick'
LATE=$((NOW - 600))
tl frederick <<J
{"kind":"hubspot-ticket","owner":"natalia@aquablu.example","contacts":["frederick@dealer.example"],
 "events":[{"type":"email","at":$IN,"direction":"inbound","from":"frederick@dealer.example","body":"B.14 again"},
  {"type":"email","at":$OUT,"direction":"outbound","from":"support@aquablu.example","body":"Replaced the board, should be fine now."},
  {"type":"email","at":$LATE,"direction":"inbound","from":"frederick@dealer.example","body":"It failed again this morning."}]}
J
I observe --source H_TICKETS --ref frederick --digest 'frederick v2' --class routine --title "HubSpot ticket frederick" --timeline-file "$H/frederick.json"
echo "archived? $( [ -f "$H/data/channel-intake/archive/$(K frederick)" ] && echo yes || echo no) awaiting=$(field "$(K frederick)" awaiting) since=$(field "$(K frederick)" awaiting_since) (LATE=$LATE) why=$(field "$(K frederick)" awaiting_why)"
echo "### 9. malformed timelines are refused"
sed "s/\"at\":$IN,/\"at\":${IN}000,/" "$H/techpromise.json" >"$H/millis.json"
I observe --source H_TICKETS --ref millis --digest m --class routine --title millis --timeline-file "$H/millis.json"; echo "exit=$?"
sed 's/"from":"support@aquablu.example"/"from":"Aquablu Support <support@aquablu.example>"/' "$H/techpromise.json" >"$H/display.json"
I observe --source H_TICKETS --ref display --digest d --class routine --title display --timeline-file "$H/display.json"; echo "exit=$?"
echo "items for refused refs: $(I items | grep -c 'millis\|display')"
echo "HOME=$H"
