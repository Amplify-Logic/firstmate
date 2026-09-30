#!/usr/bin/env bash
# Live drive of the daily to-do page's auto-expiry through the real CLIs
# (bin/fm-todo-render.sh render, bin/fm-todo.sh list/command/reopen) in a
# throwaway FM_HOME. Usage: drive-expiry.sh WORKTREE EVIDENCE_DIR [PY_DIR]
set -u
WT=$1; EV=$2; PYDIR=${3:-}
[ -n "$PYDIR" ] && export PATH="$PYDIR:$PATH"
echo "python3 used: $(command -v python3) $(python3 --version 2>&1)"
H=$(mktemp -d "${TMPDIR:-/tmp}/fm-todo-live.XXXXXX")
mkdir -p "$H/config" "$H/data/channel-intake" "$H/.lavish"
printf 'enabled = true\ntimezone = Europe/Amsterdam\ninterval_seconds = 900\n' >"$H/config/channel-intake"
printf 'C_BRIEF\tslack-channel\tdaily brief channel\n' >"$H/data/channel-intake/sources.tsv"
: >"$H/backlog.md"
E="env -u NO_MISTAKES_GATE -u FM_ROOT_OVERRIDE -u FM_DATA_OVERRIDE -u FM_STATE_OVERRIDE -u FM_CONFIG_OVERRIDE -u FM_PROJECTS_OVERRIDE FM_HOME=$H FM_TODO_BACKLOG_OVERRIDE=$H/backlog.md"
T0900=1790751600; T1045=1790757900; T1115=1790759700; T1145=1790761500; T1500=1790773200; N0900=1790838000; N1000=$((N0900+3600))
render() { echo "\$ fm-todo-render.sh render   # clock $(TZ=Europe/Amsterdam date -r "$1" '+%F %H:%M %Z')"; $E FM_TODO_RENDER_NOW=$1 "$WT/bin/fm-todo-render.sh" render >/dev/null; echo "exit=$?"; }
todo() { local now=$1; shift; echo "\$ fm-todo.sh $*"; $E FM_TODO_NOW=$now "$WT/bin/fm-todo.sh" "$@"; }
list() { todo "$1" list | awk -F'\t' '{printf "  %-8s %s\n", $2, $5}'; }
needs() { sed -n '/<h2>Needs you now/,/<\/table>/p' "$H/.lavish/today-$1.html" | grep -o 'class="what">[^<]*' | sed 's/^class="what">/  needs-you: /'; }
closed() { sed -n '/<summary>Closed today/,/<\/details>/p' "$H/.lavish/today-$1.html" | sed 's/<[^>]*>/ /g' | tr -s ' ' | grep -v '^ *$' | sed 's/^/  closed-fold: /'; }
side() { printf '{"version":2,"date":"%s","sweep_started":%s,"actions":[%s]}\n' "$1" "$2" "$3" >"$H/.lavish/today-$1.morning.json"; echo "# morning sidecar today-$1.morning.json:"; python3 -m json.tool "$H/.lavish/today-$1.morning.json" | sed 's/^/    /'; }

echo "=== S1: the reported case - 11:00 Enjojj sync (ends 11:30) on 2026-09-30"
side 2026-09-30 $T0900 '{"key":"m1","source":"calendar","ref":"enjojj-sync","class":"deadline","title":"11:00 Enjojj monthly partner sync - you host it","ends_at":"2026-09-30T11:30:00+02:00","updated":'$T0900'},{"key":"m2","source":"calendar","ref":"supplier","class":"deadline","title":"16:00 supplier call","ends_at":"2026-09-30T16:30:00+02:00","updated":'$T0900'},{"key":"m3","source":"hubspot","ref":"t9","class":"urgent","title":"dealer invoice reply","updated":'$T0900'},{"key":"m4","source":"hubspot","ref":"t10","class":"deadline","title":"quote due today for Acme","ends_at":"2026-09-30T23:59:59+02:00","updated":'$T0900'},{"key":"m5","source":"calendar","ref":"standup","class":"deadline","title":"08:00 ops standup (UTC Z end)","ends_at":"2026-09-30T06:30:00Z","updated":'$T0900'},{"key":"m6","source":"calendar","ref":"review","class":"deadline","title":"10:00 design review","ends_at":"2026-09-30T11:00:00+02:00","updated":'$T0900'},{"key":"m7","source":"calendar","ref":"oneonone","class":"deadline","title":"10:30 1:1 with Sam","ends_at":"2026-09-30T11:00:00+02:00","updated":'$T0900'}'
render $T1045
cp "$H/.lavish/today-2026-09-30.html" "$EV/page-2026-09-30-1045.html"
list $T1045; needs 2026-09-30
echo "# captain marks two lines at 10:45: a 'you' handoff and a park until tomorrow"
todo $T1045 command --item "$(todo $T1045 list | awk -F'\t' 'index($5,"design review"){print $1}' | tail -1)" 'you: send the recap'
todo $T1045 command --item "$(todo $T1045 list | awk -F'\t' 'index($5,"1:1 with Sam"){print $1}' | tail -1)" 'park til tomorrow'
render $T1145
cp "$H/.lavish/today-2026-09-30.html" "$EV/page-2026-09-30-1145.html"
list $T1145; needs 2026-09-30; closed 2026-09-30
grep -o '"handoff requested[^"]*\|handoff requested' "$H/.lavish/today-2026-09-30.html" | head -1 | sed 's/^/  page shows: /'
echo "# journal entries by auto-expiry:"; grep '"auto-expiry"' "$H/data/todo/journal" | python3 -c 'import sys,json
for l in sys.stdin:
  d=json.loads(l); print("  ", {k:d[k] for k in d if k in ("item","to","from","actor","reason","evidence","note")})'

echo "=== S2: repeated sync is idempotent (no second close per end time)"
render $T1500
echo "  auto-expiry journal lines: $(grep -c '"actor": "auto-expiry"' "$H/data/todo/journal")"

echo "=== S3: deliberate reopen of the expired Enjojj line stays open"
EID=$(todo $T1500 list | awk -F'\t' 'index($5,"Enjojj"){print $1}' | tail -1)
todo $T1500 reopen --item "$EID" --reason 'running over'
render $T1500; list $T1500 | grep Enjojj
echo "  auto-expiry journal lines: $(grep -c '"actor": "auto-expiry"' "$H/data/todo/journal")"

echo "=== S4: next day - due-today deadline expired, lapsed park expires, handoff still held"
side 2026-10-01 $N0900 '{"key":"m1","source":"hubspot","ref":"t9","class":"urgent","title":"dealer invoice reply","updated":'$N0900'}'
render $N0900
list $N0900
echo "=== S5: next-day sweep re-lists the expired Acme quote with no end time -> reopens"
side 2026-10-01 $N0900 '{"key":"m1","source":"hubspot","ref":"t9","class":"urgent","title":"dealer invoice reply","updated":'$N0900'},{"key":"m4","source":"hubspot","ref":"t10","class":"urgent","title":"quote due today for Acme","updated":'$N0900'}'
render $N1000
cp "$H/.lavish/today-2026-10-01.html" "$EV/page-2026-10-01-1000.html"
list $N1000; needs 2026-10-01
echo "=== S6: adversarial - zoneless ends_at refuses the sidecar, closes nothing"
side 2026-10-01 $N0900 '{"key":"m9","source":"calendar","ref":"bad","class":"deadline","title":"zoneless meeting","ends_at":"2026-10-01T10:30:00","updated":'$N0900'}'
before=$(todo $N1000 list | md5)
$E FM_TODO_RENDER_NOW=$((N1000+60)) "$WT/bin/fm-todo-render.sh" render >/dev/null; echo "render exit=$?"
[ "$before" = "$(todo $N1000 list | md5)" ] && echo "  store unchanged after refusal" || echo "  STORE CHANGED"
rm -rf "$H"
