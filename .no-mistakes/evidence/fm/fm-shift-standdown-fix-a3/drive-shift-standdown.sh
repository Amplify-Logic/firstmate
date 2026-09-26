#!/usr/bin/env bash
# Live drive of the shift stand-down behaviour against a disposable lab home.
# Real firstmate scripts run unmodified; only hardware boundaries are shimmed:
# pmset/launchctl/tailscale/curl/ps (so nothing real is kicked or re-armed),
# the glasses speaker (FM_SHIFT_ANNOUNCE -> logs the line), away-mode owners
# (so no real daemon starts), and osascript (logs the banner instead of posting
# on the operator desktop). uname reports Darwin so `auto` resolves the banner.
set -u
SRC=$1
LAB=$(cd -P "$(mktemp -d "${TMPDIR:-/tmp}/fm-lab.XXXXXX")" && pwd)
"$SRC/bin/fm-lab-home.sh" create "$LAB" >/dev/null
# The host sentinel only checks a home run from a primary (non-worktree) code
# root, so run a verbatim copy of the change's tracked files from a plain repo.
ROOT="$LAB/code"; mkdir -p "$ROOT"
git -C "$SRC" archive HEAD | tar -x -C "$ROOT"; git -C "$ROOT" init -q
echo "code root: copy of $(git -C "$SRC" rev-parse --short HEAD) at $ROOT"
FB="$LAB/fakebin"; mkdir -p "$FB"
cat > "$FB/pmset" <<'SH'
#!/usr/bin/env bash
case "$*" in "-g ps") echo "Now drawing from 'AC Power'";; "-g") echo ' sleep 1 (sleep prevented by caffeinate)';; esac
SH
cat > "$FB/launchctl" <<'SH'
#!/usr/bin/env bash
case "$1" in print) printf '\tstate = running\n\tpid = 4242\n';; esac; exit 0
SH
cat > "$FB/tailscale" <<'SH'
#!/usr/bin/env bash
if [ "$1" = serve ] && [ "$2" = status ]; then echo 'https://host.ts.net:8443 (tailnet only)'; echo '|-- / proxy http://127.0.0.1:8765'; fi; exit 0
SH
cat > "$FB/curl" <<'SH'
#!/usr/bin/env bash
printf '%s' "${FAKE_HEALTH_CODE:-200}"
SH
printf '#!/usr/bin/env bash\necho claude\n' > "$FB/ps"
printf '#!/usr/bin/env bash\necho Darwin\n' > "$FB/uname"
cat > "$FB/osascript" <<'SH'
#!/usr/bin/env bash
printf 'BANNER %s\n' "$*" >> "$LAB_LOGS/banner.log"
SH
cat > "$LAB/announce" <<'SH'
#!/usr/bin/env bash
[ "${1:-}" = --dry-run ] && exit 0
printf 'SPOKEN %s\n' "$*" >> "$LAB_LOGS/glasses.log"
SH
printf '#!/usr/bin/env bash\n: > "$FM_HOME/state/.afk"\n' > "$LAB/afk-launch"
printf '#!/usr/bin/env bash\nrm -f "$FM_HOME/state/.afk"; echo "away mode stopped"\n' > "$LAB/afk-return"
chmod +x "$FB"/* "$LAB/announce" "$LAB/afk-launch" "$LAB/afk-return"
export LAB_LOGS="$LAB/logs"; mkdir -p "$LAB_LOGS"; : > "$LAB_LOGS/glasses.log"; : > "$LAB_LOGS/banner.log"
cat > "$LAB/state/.supervision-sentinel.plist" <<'P'
<?xml version="1.0" encoding="UTF-8"?>
<plist version="1.0">
<dict>
  <key>Label</key>
  <string>works.earendil.firstmate.supervision-sentinel-v1.lab</string>
  <key>StartInterval</key>
  <integer>60</integer>
</dict>
</plist>
P
date +%s > "$LAB/state/.supervision-sentinel-last-check"
sleep 300 >/dev/null 2>&1 & LOCKPID=$!
echo "$LOCKPID" > "$LAB/state/.lock"; : > "$LAB/state/.last-watcher-beat"

fm() {  # run a real script against the lab home with only plain FM_HOME
  env -u FM_ROOT_OVERRIDE -u FM_STATE_OVERRIDE -u FM_DATA_OVERRIDE -u FM_CONFIG_OVERRIDE -u FM_PROJECTS_OVERRIDE \
    PATH="$FB:/usr/bin:/bin:/usr/sbin:/sbin" FM_HOME="$LAB" LAB_LOGS="$LAB_LOGS" \
    FM_SUPERVISION_MODEL=autoarm FM_SENTINEL_PLATFORM=Darwin FM_SENTINEL_LAUNCHCTL="$FB/launchctl" \
    FM_SHIFT_ANNOUNCE="$LAB/announce" FM_SHIFT_AFK_LAUNCH="$LAB/afk-launch" FM_SHIFT_AFK_RETURN="$LAB/afk-return" \
    FM_SHIFT_HEALTH_WAIT=2 FM_WEDGE_ALARM_TIMEOUT_SECS=10 "$@"
}
step() { printf '\n===== %s =====\n' "$*"; }
rc() { "$@"; printf '[exit %s]\n' "$?"; }
reset_logs() { : > "$LAB_LOGS/glasses.log"; : > "$LAB_LOGS/banner.log"; }
show_logs() { printf -- '--- glasses heard:\n'; cat "$LAB_LOGS/glasses.log"; printf -- '--- desktop banner:\n'; cat "$LAB_LOGS/banner.log"; }
alarm_owner() { fm bash "$ROOT/bin/fm-supervise-daemon.sh" --active-alert "$1" "$LAB/state/.supervision-outage-alarm"; }

step "0. arm a shift: fm-shift.sh start"
rc fm bash "$ROOT/bin/fm-shift.sh" start
step "config/wedge-alarm as written by start (the alarm route)"
cat "$LAB/config/wedge-alarm"
ls -la "$LAB/state/.shift" "$LAB/state/.afk"

step "1a. ARMED: fm-shift.sh status"
rc fm bash "$ROOT/bin/fm-shift.sh" status
step "1b. ARMED: host sentinel check (no watcher running in lab)"
rc fm bash "$ROOT/bin/fm-supervision-sentinel.sh" check
step "1c. ARMED: registered self-check with mailbox down (health 000)"
reset_logs; rm -f "$LAB/state/.shift-mailbox-outage"
rc env -i PATH="$FB:/usr/bin:/bin:/usr/sbin:/sbin" HOME="$HOME" LAB_LOGS="$LAB_LOGS" FAKE_HEALTH_CODE=000 bash "$LAB/state/fm-shift.check.sh"; show_logs
step "1d. ARMED: alarm through the real alarm owner (as the sentinel raises it)"
reset_logs
rc alarm_owner 'SUPERVISION DOWN: glasses shift armed, no crew task in flight'; show_logs

step "2. CAPTAIN GETS HOME: away mode ends by the ordinary route (state/.afk removed), shift record left behind"
rm -f "$LAB/state/.afk"; rm -f "$LAB/state/.supervision-outage" "$LAB/state/.supervision-outage-alarm" "$LAB/state/.shift-mailbox-outage"
ls -la "$LAB/state/.shift"; echo "wedge-alarm still has:"; cat "$LAB/config/wedge-alarm"
step "2a. STALE: fm-shift.sh status"
rc fm bash "$ROOT/bin/fm-shift.sh" status
step "2b. STALE: host sentinel check (no watcher, no tasks)"
rc fm bash "$ROOT/bin/fm-supervision-sentinel.sh" check
step "2c. STALE: registered self-check with mailbox down"
reset_logs
rc env -i PATH="$FB:/usr/bin:/bin:/usr/sbin:/sbin" HOME="$HOME" LAB_LOGS="$LAB_LOGS" FAKE_HEALTH_CODE=000 bash "$LAB/state/fm-shift.check.sh"; show_logs
step "2d. STALE: fm-shift.sh alarm directly (spoken half)"
reset_logs
rc fm bash "$ROOT/bin/fm-shift.sh" alarm 'SUPERVISION DOWN: 1 task(s) in flight'; show_logs
step "2e. STALE: a real crew-task outage alarm through the alarm owner with the leftover block"
reset_logs
rc alarm_owner 'SUPERVISION DOWN: 1 task(s) in flight'; show_logs

step "3. ADVERSARIAL: record gone but block left behind"
rm -f "$LAB/state/.shift"; reset_logs
rc alarm_owner 'SUPERVISION DOWN: 1 task(s) in flight'; show_logs
rc fm bash "$ROOT/bin/fm-shift.sh" status

step "4. ADVERSARIAL: away mode still active but no shift record (away without shift)"
: > "$LAB/state/.afk"; reset_logs
rc fm bash "$ROOT/bin/fm-supervision-sentinel.sh" check
rc fm bash "$ROOT/bin/fm-shift.sh" alarm 'SUPERVISION DOWN: 1 task(s) in flight'; show_logs
rm -f "$LAB/state/.afk"

step "5. teardown-only via fm-shift.sh stop clears the leftover (unchanged behaviour)"
printf 'started_epoch=%s\nstarted_iso=x\n' "$(date +%s)" > "$LAB/state/.shift"
rc fm bash "$ROOT/bin/fm-shift.sh" stop
echo "--- wedge-alarm after stop:"; cat "$LAB/config/wedge-alarm" 2>/dev/null || echo '(absent)'
ls "$LAB/state/.shift" 2>&1

kill "$LOCKPID" 2>/dev/null
rm -rf "$LAB"; echo; echo "lab removed: $( [ -e "$LAB" ] && echo NO || echo yes )"
