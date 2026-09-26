#!/usr/bin/env bash
# Live driver: run a real watcher (bin/fm-watch.sh; the arm refuses to run from a
# no-mistakes validation checkout) for a
# disposable lab home on a private fm-lab tmux socket, tear down its state dir
# (or whole home) at a random point in the poll cycle, and record whether the
# watcher exits promptly and names the teardown.
# usage: drive-watcher-teardown.sh <repo-root> <label> <iterations>
set -u
ROOT=$1 LABEL=$2 N=$3
OUTDIR=$(mktemp -d "${TMPDIR:-/tmp}/fm-watchdrive.XXXXXX")
ok=0 slow=0 silent=0
for i in $(seq 1 "$N"); do
  LAB=$(mktemp -d "${TMPDIR:-/tmp}/fm-lab.XXXXXX")
  "$ROOT/bin/fm-lab-home.sh" create "$LAB" >/dev/null; mkdir -p "$LAB/tmux"
  out="$OUTDIR/arm-$i.out"; : > "$out"
  env -u NO_MISTAKES_GATE -u FM_GATE_REFUSE_BYPASS -u FM_ROOT_OVERRIDE -u FM_STATE_OVERRIDE -u FM_DATA_OVERRIDE -u FM_CONFIG_OVERRIDE -u FM_PROJECTS_OVERRIDE \
    TMUX_TMPDIR="$LAB/tmux" tmux -L fm-lab new-session -d -s primary -c "$ROOT" -e FM_HOME="$LAB" \
    "FM_POLL=1 FM_SIGNAL_GRACE=0 FM_CHECK_INTERVAL=999999 FM_HEARTBEAT=999999 exec '$ROOT/bin/fm-watch.sh' > '$out' 2>&1"
  pid=
  for _ in $(seq 1 100); do pid=$(cat "$LAB/state/.watch.lock/pid" 2>/dev/null); [ -n "$pid" ] && [ -e "$LAB/state/.last-watcher-beat" ] && break; pid=; sleep 0.1; done
  if [ -z "$pid" ]; then echo "[$LABEL #$i] no watcher started: $(cat "$out")"; TMUX_TMPDIR="$LAB/tmux" tmux -L fm-lab kill-server; rm -rf "$LAB"; continue; fi
  # random point inside the 1s poll cycle
  perl -e 'select(undef,undef,undef,0.5+rand(1.5))'
  if [ $((i % 2)) -eq 0 ]; then what=home; rm -rf "$LAB/state" "$LAB"; else what=state; rm -rf "$LAB/state"; fi
  t0=$(perl -MTime::HiRes=time -e 'printf "%.2f", time')
  gone=0
  for _ in $(seq 1 30); do kill -0 "$pid" 2>/dev/null || { gone=1; break; }; sleep 0.1; done
  t1=$(perl -MTime::HiRes=time -e 'printf "%.2f", time')
  sleep 0.3
  reason=$(grep -m1 '^watcher: exiting' "$out" || true)
  if [ "$gone" -ne 1 ]; then slow=$((slow+1)); kill -TERM "$pid" 2>/dev/null; verdict="OUTLIVED teardown (>3s)";
  elif [ -z "$reason" ]; then silent=$((silent+1)); verdict="exited with NO logged reason";
  else ok=$((ok+1)); verdict="ok"; fi
  printf '[%s #%02d] removed %-5s pid=%s exited_in=%ss %s | %s\n' "$LABEL" "$i" "$what" "$pid" "$(echo "$t1 - $t0" | bc)" "$verdict" "${reason:-$(tr '\n' ' ' < "$out" | cut -c1-200)}"
  mkdir -p "$LAB/tmux" 2>/dev/null
  TMUX_TMPDIR="$LAB/tmux" tmux -L fm-lab kill-server 2>/dev/null
  rm -rf "$LAB"
done
echo "[$LABEL] summary: $N teardowns -> ok=$ok outlived=$slow silent-exit=$silent"
rm -rf "$OUTDIR"
