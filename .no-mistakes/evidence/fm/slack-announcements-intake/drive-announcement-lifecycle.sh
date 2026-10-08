#!/usr/bin/env bash
# Continues the home from drive-announcements.sh: edit (moved date), then the retire horizon.
set -u
ROOT=$1; H=$2
ep() { TZ=Europe/Amsterdam date -j -f '%Y-%m-%d %H:%M:%S' "$1" +%s; }
I() { local now=$1; shift; FM_HOME="$H" FM_ROOT_OVERRIDE="$ROOT" FM_CHANNEL_INTAKE_NOW="$now" "$ROOT/bin/fm-channel-intake.sh" "$@"; }
R() { local now=$1; shift; FM_HOME="$H" FM_ROOT_OVERRIDE="$ROOT" FM_TODO_RENDER_NOW="$now" "$ROOT/bin/fm-todo-render.sh" "$@"; }
POST=$(ep '2026-10-08 14:21:00'); EDIT=$(ep '2026-10-09 09:30:00')
fold() { grep -o '<summary>Updates[^<]*</summary>' "$1" || echo '(no Updates fold)'; grep -o '<td>[^<]*webshop[^<]*</td>' "$1" || true; grep -c 'Closed today' "$1" | sed 's/^/Closed-today mentions: /'; }
echo "### 8. Valerie edits the post on 9 Oct: webshop date moved to 22 Oct"
I "$EDIT" observe --source C_TEAM --ref 1791462060.000200 --digest 'aquablu furniture limited release v2' \
  --class update --source-epoch "$POST" \
  --title 'Aquablu Furniture limited release (REFILL+ Series 2 cabinet), 50 units - live on the partner webshop 22 Oct' \
  --link 'https://aquablu.slack.com/archives/C_TEAM/p1791462060000200'
I "$EDIT" notify-due; echo "notify-due exit=$? (no output expected)"
R "$EDIT" render >/dev/null; fold "$H/.lavish/today-2026-10-09.html"
echo; echo "### 9. tick on 10 Oct (past the 1-day routine horizon)"
I "$(ep '2026-10-10 12:00:00')" tick >/dev/null; ls "$H/data/channel-intake/items" | wc -l | sed 's/^ */open items in polled set: /'
echo; echo "### 10. tick on 23 Oct 08:00: >14d after both were first read (8 Oct 14:45), <14d after the 9 Oct 09:30 edit"
T23=$(ep '2026-10-23 08:00:00'); I "$T23" tick >/dev/null
I "$T23" items --state inactive | sed 's/^/inactive: /'
R "$T23" render >/dev/null; fold "$H/.lavish/today-2026-10-23.html"
echo; echo "### 11. tick on 24 Oct 10:00 (>14d after the edit)"
T24=$(ep '2026-10-24 10:00:00'); I "$T24" tick >/dev/null
I "$T24" items --state inactive | sed 's/^/inactive: /'
R "$T24" render >/dev/null; fold "$H/.lavish/today-2026-10-24.html"
grep -c 'Furniture' "$H/.lavish/today-2026-10-24.html" | sed 's/^/Furniture mentions on 24 Oct page: /'
