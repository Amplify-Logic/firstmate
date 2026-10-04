#!/usr/bin/env bash
# Live driver: reproduce the larsdell condition (two Linux supervisors, two
# --serve loops on one account queue) with real fm-remote-job-worker.sh
# processes from a given git ref, then submit jobs the way the Mac listener
# does (fm_remote_job_stage + fm_remote_job_wait) and report what comes back.
# Usage: drive-duplicate-worker.sh <repo-worktree> <git-ref> <label>
set -u
SRC=$1 REF=$2 LABEL=$3
LAB=$(mktemp -d "${TMPDIR:-/tmp}/fm-dupworker.XXXXXX"); LAB=$(cd "$LAB" && pwd -P)
ROOT="$LAB/root"; HOMEDIR="$LAB/account"; STATE="$LAB/jobs"; RHOME="$LAB/remote-home"
mkdir -p "$ROOT/bin" "$HOMEDIR" "$RHOME"; chmod 700 "$HOMEDIR"
for f in fm-remote-job-lib.sh fm-remote-job-worker.sh fm-remote-delta-read.sh; do
  git -C "$SRC" show "$REF:bin/$f" > "$ROOT/bin/$f"; done
printf 'lab\n' > "$ROOT/AGENTS.md"
cat > "$ROOT/bin/fm-reply-job.sh" <<'SH'
#!/bin/bash
sleep 2
printf 'reply from dell second mate: %s\n' "$1"
SH
chmod +x "$ROOT/bin"/*.sh
git -C "$ROOT" init -q -b main; git -C "$ROOT" -c user.email=l@x -c user.name=lab add -A
git -C "$ROOT" -c user.email=l@x -c user.name=lab commit -qm lab
export HOME="$HOMEDIR" FM_ROOT_OVERRIDE="$ROOT" FM_REMOTE_JOB_STATE_ROOT="$STATE" FM_REMOTE_JOB_PLATFORM_OVERRIDE=Linux
log() { printf '[%s %s] %s\n' "$LABEL" "$(date +%T)" "$*"; }
procs() { ps -axo pid=,ppid=,pgid=,command= | grep "$ROOT/bin/fm-remote-job-worker.sh" | grep -v grep | sed 's#'"$ROOT"'#$LAB_ROOT#'; }
cleanup() { pkill -KILL -f "$ROOT/bin/fm-" 2>/dev/null; rm -rf "$LAB"; }
trap cleanup EXIT
log "source ref $REF ($(git -C "$SRC" rev-parse --short "$REF"))"
# Supervisor A: the normal Linux launch (no args -> supervisor -> --serve child).
set -m
"$ROOT/bin/fm-remote-job-worker.sh" 2> "$LAB/supA.err" & SUPA=$!
for _ in $(seq 300); do SERVEA=$(cat "$STATE/worker.lock/pid" 2>/dev/null); [ -n "$SERVEA" ] && [ -f "$STATE/worker.ready" ] && break; sleep 0.05; done
log "supervisor A pid=$SUPA owns queue via --serve pid=$SERVEA"
# Stall A's serving loop past the heartbeat bound with drifted ps start records.
kill -STOP "$SERVEA"
printf 'Thu Jan  1 00:00:00 2000\n' > "$STATE/worker.lock/start"
touch -t 200001010000 "$STATE/worker.ready" "$STATE/worker.lock"
"$ROOT/bin/fm-remote-job-worker.sh" 2> "$LAB/supB.err" & SUPB=$!
for _ in $(seq 300); do SERVEB=$(cat "$STATE/worker.lock/pid" 2>/dev/null); [ -n "$SERVEB" ] && [ "$SERVEB" != "$SERVEA" ] && break; sleep 0.05; done
log "supervisor B pid=$SUPB reclaimed queue via --serve pid=$SERVEB"
kill -CONT "$SERVEA"
log "stalled loop A resumed; process table now:"; procs
. "$ROOT/bin/fm-remote-job-lib.sh"
ok=0; bad=0
for n in 1 2 3 4 5; do
  FM_REMOTE_JOB_TIMEOUT=30 fm_remote_job_stage "$HOMEDIR" "$ROOT" "$RHOME" fm-reply-job.sh "msg-$n" </dev/null >/dev/null || { log "stage failed: $FM_REMOTE_JOB_ERROR"; bad=$((bad+1)); continue; }
  id=$FM_REMOTE_JOB_ID
  if fm_remote_job_wait "$HOMEDIR" "$id"; then
    out=$(cat "$FM_REMOTE_JOB_STDOUT"); err=$(cat "$FM_REMOTE_JOB_STDERR")
    log "job $n exit=$FM_REMOTE_JOB_EXIT stdout=[$out] stderr=[$err]"
    if [ "$FM_REMOTE_JOB_EXIT" -eq 0 ] && [ "$out" = "reply from dell second mate: msg-$n" ]; then ok=$((ok+1)); else bad=$((bad+1)); fi
  else log "job $n wait failed: $FM_REMOTE_JOB_ERROR"; bad=$((bad+1)); fi
done
log "process table after jobs:"; procs
log "supervisor A alive? $(kill -0 $SUPA 2>/dev/null && echo yes || echo no); serve A alive? $(kill -0 $SERVEA 2>/dev/null && echo yes || echo no)"
log "supervisor B alive? $(kill -0 $SUPB 2>/dev/null && echo yes || echo no); serve B alive? $(kill -0 $SERVEB 2>/dev/null && echo yes || echo no)"
log "lock owner pid=$(cat "$STATE/worker.lock/pid" 2>/dev/null) ready pid=$(cat "$STATE/worker.ready" 2>/dev/null)"
log "supervisor A stderr:"; sed 's/^/    /' "$LAB/supA.err" | tail -5
log "supervisor B stderr:"; sed 's/^/    /' "$LAB/supB.err" | tail -5
if [ -f "$HOMEDIR/.firstmate/remote-job/logs/dev.firstmate.remote-job.log" ]; then log "worker log races:"; grep -c 'File exists\|supervisor' "$HOMEDIR/.firstmate/remote-job/logs/dev.firstmate.remote-job.log"; fi
log "RESULT: $ok/5 replies delivered, $bad failed"
