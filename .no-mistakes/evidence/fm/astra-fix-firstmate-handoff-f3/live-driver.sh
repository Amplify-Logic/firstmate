#!/usr/bin/env bash
# Live driver: real bin/fm-primary-handoff.sh / fm-lock.sh / fm-primary.sh CLIs
# against a disposable marked lab FM_HOME, synthetic harness holders (a bash
# symlinked as "codex" that runs the real fm-lock.sh acquisition) and stub
# runtime CLIs. Usage: live-driver.sh <worktree> <lab> <scenario>
set -u
ROOT=$1 LAB=$2 SCEN=$3
export ROOT LAB FM_HOME=$LAB
ST=$LAB/state
FB=$LAB/fakebin
HB=$LAB/harness/codex
export HB
mkdir -p "${HB%/*}" "$FB"
[ -L "$HB" ] || ln -s /bin/bash "$HB"
export PATH="$FB:/usr/bin:/bin"
H="$ROOT/bin/fm-primary-handoff.sh"
LAUNCH_LOG=$LAB/launch.log
export LAUNCH_LOG

say() { printf '\n$ %s\n' "$*"; }
show_state() {
  echo "--- state/.primary-handoff:"; sed 's/^/    /' "$ST/.primary-handoff" 2>/dev/null || echo "    (absent)"
  echo "--- fm-lock.sh status: $("$ROOT/bin/fm-lock.sh" status 2>&1 | head -1)"
  echo "--- state/.lock-handoff:"; sed 's/^/    /' "$ST/.lock-handoff" 2>/dev/null || echo "    (absent)"
  echo "--- state/.primary-active profile: $(sed -n 's/^profile=//p' "$ST/.primary-active" 2>/dev/null)"
  echo "--- launches: $(wc -l < "$LAUNCH_LOG" 2>/dev/null | tr -d ' ' || echo 0)"
}
reset_home() {
  for p in $(cat "$LAB/pids" 2>/dev/null); do kill -9 "$p" 2>/dev/null; done
  : > "$LAB/pids"
  rm -rf "$ST"/.lock "$ST"/.lock-* "$ST"/.primary-* "$ST"/.afk* "$ST"/.lock.acquire "$LAB/term-received"
  : > "$LAUNCH_LOG"
}
# Outgoing primary: a synthetic harness that acquires the real session lock.
start_outgoing() { # [term-delay-secs]
  local delay=${1:-0}
  env -u FM_HANDOFF_TOKEN -u FM_HANDOFF_PROFILE TERM_DELAY="$delay" "$HB" -c '
    trap "touch \"$LAB/term-received\"; sleep \"$TERM_DELAY\"; exit 0" TERM
    "$ROOT/bin/fm-lock.sh" >/dev/null || exit 1
    while :; do sleep 0.2; done' >/dev/null 2>&1 &
  OUT=$!
  echo "$OUT" >> "$LAB/pids"
  local i=0
  while [ "$(head -1 "$ST/.lock" 2>/dev/null)" != "$OUT" ] && [ $i -lt 100 ]; do sleep 0.1; i=$((i+1)); done
  echo "outgoing synthetic primary pid=$OUT acquired lock: $(head -1 "$ST/.lock")"
}
write_active() { printf 'schema=fm-primary-active.v1\nprofile=%s\npid=\nstarted_at=1\nupdated_at=1\n' "$1" > "$ST/.primary-active"; }
write_config() {
  cat > "$LAB/config/primary-handoff" <<JSON
{"enabled": true, "threshold_percent_remaining": 15, "poll_seconds": 60,
 "cooldown_seconds": 300, "chain": ["claude-fable", "pi", "codex"]}
JSON
}
write_quota_low() {
  cat > "$LAB/quota.json" <<'JSON'
{"providers":[{"provider":"claude","state":{"status":"fresh"},"windows":[
 {"id":"five_hour","kind":"session","percentRemaining":5},{"id":"seven_day","kind":"weekly","percentRemaining":80}]},
 {"provider":"codex","state":{"status":"fresh"},"windows":[
 {"id":"five_hour","kind":"session","percentRemaining":90},{"id":"weekly","kind":"weekly","percentRemaining":90}]}]}
JSON
  export FM_HANDOFF_QUOTA_JSON=$LAB/quota.json
}
# Incoming runtime stub: synthetic harness running the real acquisition path.
launch_incoming() {
  printf 'launch %s at %s\n' "$1" "$(date +%T)" >> "$LAUNCH_LOG"
  echo "$$" >> "$LAB/pids"
  exec "$HB" -c 'sleep "${STARTUP_DELAY:-0}"; [ "${NO_ACK:-0}" = 1 ] && { while :; do sleep 1; done; }
    "$ROOT/bin/fm-lock.sh" >/dev/null || exit 1; while :; do sleep 0.2; done'
}
export -f launch_incoming
custom_route() { export FM_HANDOFF_LAUNCH_CMD=launch_incoming FM_HANDOFF_PREFLIGHT_CMD=true; }
alive() { kill -0 "$1" 2>/dev/null && echo alive || echo dead; }
descendants_kill9() { # kill a controller tree, sparing the detached launcher
  local root=$1 pids p
  pids=$(ps -A -o pid=,ppid=,args= | awk -v r="$root" '
    { pid[$1]=$2; line[$1]=$0 } END { for (p in pid) { q=p; while (q in pid && q!=r && q>1) q=pid[q]; if (q==r && line[p] ~ /fm-primary-handoff.sh execute/) print p } }')
  for p in $root $pids; do kill -9 "$p" 2>/dev/null && echo "kill -9 controller pid $p"; done
}

case "$SCEN" in
  f1-release-stale)
    reset_home
    echo "## F1: release-stale is serialized with session acquisition (.lock.acquire)"
    "$HB" -c 'exit 0' & dead=$!; wait $dead
    echo "$dead" > "$ST/.lock"; echo stale-session > "$ST/.lock-session"; echo token=x > "$ST/.lock-handoff"
    echo "state/.lock records dead pid $dead (stale)"
    # An in-flight acquisition holds the claim mutex and publishes a NEW live owner.
    "$HB" -c 'while :; do sleep 0.2; done' >/dev/null 2>&1 & NEW=$!; echo "$NEW" >> "$LAB/pids"
    bash -c '. "$ROOT/bin/fm-wake-lib.sh"; STATE="$1"; fm_lock_try_acquire "$1/.lock.acquire" || exit 9
      echo "acquirer: holding .lock.acquire at $(date +%T.%N 2>/dev/null || date +%T)"; sleep 3
      echo "$2" > "$1/.lock"; echo "acquirer: published live owner $2, releasing mutex at $(date +%T)"
      fm_lock_release "$1/.lock.acquire"' _ "$ST" "$NEW" &
    acq=$!; sleep 0.5
    say "fm-lock.sh release-stale   (started at $(date +%T) while acquisition in flight)"
    "$ROOT/bin/fm-lock.sh" release-stale; echo "exit=$? finished at $(date +%T)"
    wait $acq
    echo "state/.lock now: $(cat "$ST/.lock" 2>/dev/null || echo ABSENT) (live owner $NEW is $(alive "$NEW"))"
    say "fm-lock.sh status"; "$ROOT/bin/fm-lock.sh" status | head -1
    echo; echo "## F1b: genuinely stale lock + sidecars are removed under the mutex"
    kill -9 "$NEW"; wait "$NEW" 2>/dev/null
    echo stale-session > "$ST/.lock-session"; echo token=x > "$ST/.lock-handoff"
    say "fm-lock.sh release-stale"; "$ROOT/bin/fm-lock.sh" release-stale; echo "exit=$?"
    ls -a "$ST" | grep -E '^\.lock' || echo "(no .lock, .lock-session, .lock-handoff remain)"
    ;;
  f2-preflight)
    reset_home; write_config; write_active claude-fable
    echo "## F2a: no launch route (outside tmux, no custom route) refuses BEFORE signalling"
    start_outgoing
    say "env -u TMUX fm-primary-handoff.sh execute --force --to pi"
    env -u TMUX -u FM_HANDOFF_LAUNCH_CMD "$H" execute --force --to pi; echo "exit=$?"
    echo "outgoing $OUT: $(alive "$OUT"); TERM received: $([ -e "$LAB/term-received" ] && echo YES || echo no)"
    show_state
    echo; echo "## F2b: explicit --to target whose CLI is missing refuses BEFORE signalling"
    custom_route; mv "$FB/pi" "$FB/pi.off"
    say "fm-primary-handoff.sh execute --force --to pi   (pi CLI removed from PATH)"
    "$H" execute --force --to pi; echo "exit=$?"
    mv "$FB/pi.off" "$FB/pi"
    echo "outgoing $OUT: $(alive "$OUT"); TERM received: $([ -e "$LAB/term-received" ] && echo YES || echo no)"
    show_state
    echo; echo "## F2c: custom route whose preflight fails refuses BEFORE signalling"
    say "FM_HANDOFF_PREFLIGHT_CMD=false fm-primary-handoff.sh execute --force --to pi"
    FM_HANDOFF_PREFLIGHT_CMD=false "$H" execute --force --to pi; echo "exit=$?"
    echo "outgoing $OUT: $(alive "$OUT"); TERM received: $([ -e "$LAB/term-received" ] && echo YES || echo no)"
    show_state
    ;;
  f2-ack)
    reset_home; write_config; write_active claude-fable; custom_route
    echo "## F2d: launch command that starts but never acquires the lock is NOT acknowledged"
    start_outgoing
    say "NO_ACK=1 FM_HANDOFF_STARTUP_SECS=3 fm-primary-handoff.sh execute --force --to pi"
    NO_ACK=1 FM_HANDOFF_STARTUP_SECS=3 FM_HANDOFF_WAIT_DEAD_SECS=5 "$H" execute --force --to pi; echo "exit=$?"
    show_state
    reset_home; write_active claude-fable
    echo; echo "## F2e: happy path completes only on a bound acquisition receipt"
    start_outgoing
    say "STARTUP_DELAY=2 fm-primary-handoff.sh execute --force --to pi"
    STARTUP_DELAY=2 FM_HANDOFF_STARTUP_SECS=15 FM_HANDOFF_WAIT_DEAD_SECS=5 "$H" execute --force --to pi; echo "exit=$?"
    echo "outgoing $OUT: $(alive "$OUT")"
    show_state
    inc=$(head -1 "$ST/.lock"); echo "incoming holder $inc comm=$(ps -o comm= -p "$inc")"
    ;;
  f3-crash)
    reset_home; write_config; write_active claude-fable; custom_route
    for ph in planning releasing launching; do
      reset_home; write_active claude-fable
      echo; echo "## F3: controller SIGKILLed at durable phase '$ph', then plain check recovers"
      start_outgoing
      say "FM_HANDOFF_INJECT_CRASH=$ph fm-primary-handoff.sh execute --force --to pi"
      FM_HANDOFF_INJECT_CRASH=$ph FM_HANDOFF_WAIT_DEAD_SECS=5 "$H" execute --force --to pi; echo "exit=$? (killed)"
      show_state
      say "fm-primary-handoff.sh check"
      FM_HANDOFF_STARTUP_SECS=15 FM_HANDOFF_WAIT_DEAD_SECS=5 "$H" check; echo "exit=$?"
      echo "outgoing $OUT: $(alive "$OUT")"
      show_state
    done
    reset_home; write_active claude-fable
    echo; echo "## F3: controller tree SIGKILLed externally while waiting for incoming acknowledgement"
    start_outgoing
    STARTUP_DELAY=6 FM_HANDOFF_STARTUP_SECS=30 FM_HANDOFF_WAIT_DEAD_SECS=5 "$H" execute --force --to pi &
    ctl=$!; sleep 3
    descendants_kill9 "$ctl"; wait "$ctl" 2>/dev/null
    show_state
    say "fm-primary-handoff.sh check   (launcher from crashed controller still starting)"
    FM_HANDOFF_STARTUP_SECS=15 "$H" check; echo "exit=$?"
    show_state
    say "fm-primary-handoff.sh check   (again; must be a no-op cooldown, no relaunch)"
    "$H" check; echo "exit=$?"; echo "--- launches: $(wc -l < "$LAUNCH_LOG" | tr -d ' ')"
    ;;
  f3-delayed-shutdown)
    reset_home; write_config; write_active claude-fable; custom_route
    echo "## F3: signalled outgoing outlives wait, preflight temporarily fails, then exits; one replacement"
    start_outgoing 6
    say "FM_HANDOFF_WAIT_DEAD_SECS=2 fm-primary-handoff.sh execute --force --to pi"
    FM_HANDOFF_WAIT_DEAD_SECS=2 "$H" execute --force --to pi; echo "exit=$?"
    echo "TERM received: $([ -e "$LAB/term-received" ] && echo YES || echo no); outgoing $OUT: $(alive "$OUT")"
    show_state
    say "env -u TMUX -u FM_HANDOFF_LAUNCH_CMD fm-primary-handoff.sh check   (route unavailable)"
    env -u TMUX -u FM_HANDOFF_LAUNCH_CMD "$H" check; echo "exit=$?"
    show_state
    echo "waiting for signalled outgoing to exit..."; while kill -0 "$OUT" 2>/dev/null; do sleep 0.2; done
    echo "outgoing $OUT: dead"
    say "fm-primary-handoff.sh check   (route restored)"
    FM_HANDOFF_STARTUP_SECS=15 "$H" check; echo "exit=$?"
    show_state
    say "fm-primary-handoff.sh check   (again)"; "$H" check; echo "exit=$?"; echo "--- launches: $(wc -l < "$LAUNCH_LOG" | tr -d ' ')"
    ;;
  f4-afk)
    reset_home; write_config; write_active claude-fable; write_quota_low; custom_route
    echo "## F4: canonical away contract (state/.afk-contract) blocks automatic handoff"
    start_outgoing
    printf 'version=2\n' > "$ST/.afk-contract"
    echo "state/.afk-contract present; state/.afk absent: $([ -e "$ST/.afk" ] && echo no || echo yes)"
    say "fm-primary-handoff.sh check   (claude quota 5% < 15% threshold)"
    "$H" check; echo "exit=$?"
    say "fm-primary-handoff.sh execute   (no --force)"
    "$H" execute; echo "exit=$?"
    echo "outgoing $OUT: $(alive "$OUT"); TERM received: $([ -e "$LAB/term-received" ] && echo YES || echo no)"
    show_state
    echo; echo "## F4 control: remove the contract; the same check now hands off automatically"
    rm -f "$ST/.afk-contract"
    say "fm-primary-handoff.sh check"
    FM_HANDOFF_STARTUP_SECS=15 FM_HANDOFF_WAIT_DEAD_SECS=5 "$H" check; echo "exit=$?"
    echo "outgoing $OUT: $(alive "$OUT")"
    show_state
    ;;
  cleanup) reset_home ;;
esac
case "$SCEN" in
  disabled-recovery)
    reset_home; rm -f "$LAB/config/primary-handoff"; write_active claude-fable; custom_route
    echo "## Disabled/absent config: forced handoff crashes mid-launch; check and run still reconcile"
    start_outgoing
    say "FM_HANDOFF_INJECT_CRASH=launching fm-primary-handoff.sh execute --force   (config absent, default chain)"
    FM_HANDOFF_INJECT_CRASH=launching FM_HANDOFF_WAIT_DEAD_SECS=5 "$H" execute --force 2>/dev/null; echo "exit=$? (killed)"
    show_state
    say "fm-primary-handoff.sh run   (config absent)"
    FM_HANDOFF_STARTUP_SECS=15 "$H" run; echo "exit=$?"
    show_state
    say "fm-primary-handoff.sh check"; "$H" check; echo "exit=$?"; echo "--- launches: $(wc -l < "$LAUNCH_LOG" | tr -d ' ')"
    ;;
esac
