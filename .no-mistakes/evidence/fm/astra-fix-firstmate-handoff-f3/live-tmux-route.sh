#!/usr/bin/env bash
# Live tmux route: private lab tmux socket, controller in a lab pane, real
# tmux new-window -> fm-primary-handoff.sh launch -> exec fm-primary.sh pi ->
# stub pi runtime (synthetic "codex" harness running the real fm-lock.sh).
set -u
ROOT=$1 LAB=$2
ST=$LAB/state FB=$LAB/fakebin HB=$LAB/harness/codex
export ROOT LAB HB FM_HOME=$LAB LAUNCH_LOG=$LAB/launch.log PATH="$FB:/usr/bin:/bin:/opt/homebrew/bin"
export TMUX_TMPDIR=$LAB/tmux
mkdir -p "$TMUX_TMPDIR"
T() { /opt/homebrew/bin/tmux -L fm-lab "$@"; }
rm -rf "$ST"/.lock "$ST"/.lock-* "$ST"/.primary-*; : > "$LAUNCH_LOG"
cat > "$LAB/config/primary-handoff" <<'JSON'
{"enabled": true, "threshold_percent_remaining": 15, "poll_seconds": 60,
 "cooldown_seconds": 300, "chain": ["claude-fable", "pi", "codex"]}
JSON
printf 'schema=fm-primary-active.v1\nprofile=claude-fable\npid=\nstarted_at=1\nupdated_at=1\n' > "$ST/.primary-active"
cp "$FB/pi" "$FB/pi.orig"
cat > "$FB/pi" <<'SH'
#!/bin/bash
printf 'launch pi argv=%s token=%s profile=%s at %s\n' "$*" "${FM_HANDOFF_TOKEN:-}" "${FM_HANDOFF_PROFILE:-}" "$(date +%T)" >> "$LAUNCH_LOG"
exec "$HB" -c '"$ROOT/bin/fm-lock.sh" >/dev/null || exit 1; while :; do sleep 0.2; done'
SH
chmod +x "$FB/pi"
T new-session -d -s primary -x 200 -y 50 -c "$ROOT" \
  "env -u FM_HANDOFF_TOKEN \"$HB\" -c 'trap \"exit 0\" TERM; \"\$ROOT/bin/fm-lock.sh\" >/dev/null && echo outgoing-holder-ready; while :; do sleep 0.2; done'"
for _ in $(seq 50); do [ -s "$ST/.lock" ] && break; sleep 0.1; done
OUT=$(head -1 "$ST/.lock")
echo "outgoing synthetic primary in lab tmux pane: pid=$OUT"
echo "\$ fm-lock.sh status: $("$ROOT/bin/fm-lock.sh" status | head -1)"
echo
echo "\$ (inside lab tmux pane) fm-primary-handoff.sh execute --force --to pi   [default tmux route]"
T new-window -d -n ctl "env -u FM_HANDOFF_LAUNCH_CMD FM_HANDOFF_STARTUP_SECS=20 FM_HANDOFF_WAIT_DEAD_SECS=5 \"$ROOT/bin/fm-primary-handoff.sh\" execute --force --to pi > \"$LAB/ctl.log\" 2>&1; echo exit=\$? >> \"$LAB/ctl.log\"; sleep 30"
for _ in $(seq 300); do grep -q '^exit=' "$LAB/ctl.log" 2>/dev/null && break; sleep 0.1; done
sed 's/^/    /' "$LAB/ctl.log"
echo
echo "--- tmux list-windows (lab socket):"; T list-windows -a -F '    #{session_name}:#{window_index} #{window_name} pane_pid=#{pane_pid} cmd=#{pane_current_command}'
echo "--- launch log:"; sed 's/^/    /' "$LAUNCH_LOG"
echo "--- outgoing $OUT: $(kill -0 "$OUT" 2>/dev/null && echo alive || echo dead)"
echo "--- fm-lock.sh status: $("$ROOT/bin/fm-lock.sh" status | head -1)"
echo "--- state/.primary-handoff:"; grep -E '^(phase|from|to|token|shutdown_requested|incoming_pid|error)=' "$ST/.primary-handoff" | sed 's/^/    /'
echo "--- state/.lock-handoff:"; grep -E '^(token|profile|pid)=' "$ST/.lock-handoff" | sed 's/^/    /'
echo "--- state/.primary-active:"; grep -E '^(profile|pid)=' "$ST/.primary-active" | sed 's/^/    /'
inc=$(head -1 "$ST/.lock"); echo "--- incoming holder $inc ancestry:"; p=$inc; for _ in 1 2 3 4; do ps -o pid=,ppid=,comm= -p "$p" | sed 's/^/    /'; p=$(ps -o ppid= -p "$p" | tr -d ' '); [ "$p" -gt 1 ] 2>/dev/null || break; done
T kill-server
mv "$FB/pi.orig" "$FB/pi"
sleep 0.5
echo "--- after lab tmux kill-server: lock status: $("$ROOT/bin/fm-lock.sh" status | head -1)"
