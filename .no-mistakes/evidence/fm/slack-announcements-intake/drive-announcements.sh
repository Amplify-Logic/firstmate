#!/usr/bin/env bash
# Drives the real intake + day-page CLIs against a throwaway home for the team-announcement change.
set -u
ROOT=$1; H=$2
ep() { TZ=Europe/Amsterdam date -j -f '%Y-%m-%d %H:%M:%S' "$1" +%s; }
POST=$(ep '2026-10-08 14:21:00'); NOW=$(ep '2026-10-08 14:45:00'); OLD=$(ep '2026-10-06 10:00:00')
I() { local now=$1; shift; env -u FM_STATE_OVERRIDE -u FM_DATA_OVERRIDE -u FM_CONFIG_OVERRIDE FM_HOME="$H" FM_ROOT_OVERRIDE="$ROOT" FM_CHANNEL_INTAKE_NOW="$now" "$ROOT/bin/fm-channel-intake.sh" "$@"; }
R() { local now=$1; shift; env -u FM_STATE_OVERRIDE -u FM_DATA_OVERRIDE -u FM_CONFIG_OVERRIDE FM_HOME="$H" FM_ROOT_OVERRIDE="$ROOT" FM_TODO_RENDER_NOW="$now" "$ROOT/bin/fm-todo-render.sh" "$@"; }
mkdir -p "$H/config" "$H/state" "$H/reports" "$H/data/channel-intake" "$H/.lavish"
cat >"$H/config/channel-intake" <<EOF
enabled = true
timezone = Europe/Amsterdam
interval_seconds = 1800
notify_recipient = U_CAPTAIN
notify_recipient_verified = true
report_dir = $H/reports
EOF
printf 'C_LARS\tslack-channel\t@mentions of the captain\n' >"$H/data/channel-intake/sources.tsv"
printf 'C_TEAM\tslack-announcements\t#channel-team announcements, kept posts only\n' >>"$H/data/channel-intake/sources.tsv"
echo "### 1. claim at 14:45 (both sources due on first poll)"; I "$NOW" claim
echo; echo "### 2. adversarial: --class update from the @mention source (must be refused)"
I "$NOW" observe --source C_LARS --ref 1791462000.000100 --digest x --class update --title 'Furniture launch'; echo "exit=$?"
echo; echo "### 3. observe Valerie's Furniture post as an update"
I "$NOW" observe --source C_TEAM --ref 1791462060.000200 --digest 'aquablu furniture limited release v1' \
  --class update --source-epoch "$POST" \
  --title 'Aquablu Furniture limited release (REFILL+ Series 2 cabinet), 50 units - live on the partner webshop' \
  --link 'https://aquablu.slack.com/archives/C_TEAM/p1791462060000200'; echo "exit=$?"
echo; echo "### 3b. an older update and a real ask from the @mention source"
I "$NOW" observe --source C_TEAM --ref 1791280000.000300 --digest 'price list' --class update --source-epoch "$OLD" \
  --title 'Flavour box price list changes from 1 Nov' --link 'https://aquablu.slack.com/archives/C_TEAM/p1791280000000300'
I "$NOW" observe --source C_LARS --ref 1791463000.000400 --digest 'rma' --class obligation --title 'Approve the RMA for Hotel Krasnapolsky'
I "$NOW" complete --source C_TEAM --checkpoint 1791462060.000200 >/dev/null; I "$NOW" complete --source C_LARS --checkpoint 1791463000.000400 >/dev/null
echo; echo "### 4. notify-due (update must not appear)"; I "$NOW" notify-due; echo "exit=$?"
echo; echo "### 5. todo (update must not appear; RMA ask must)"; I "$NOW" todo
echo; echo "### 6. brief (update listed under what changed)"; I "$NOW" brief
echo; echo "### 7. render day page"; R "$NOW" render; ls "$H/.lavish"
