#!/usr/bin/env bash
# Live driver, two cases with real fm-remote-job-worker.sh processes from <ref>:
#  midjob:  the stalled duplicate loop resumes WHILE the owner is running a
#           listener job; the job must still publish its own result.
#  unowned: the owner's lock/pid is briefly unreadable (reclaim mid-publish);
#           the owner must keep serving rather than treat it as a takeover.
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
[ -z "${2:-}" ] || printf 'started\n' > "$2"
sleep 3
printf 'reply from dell second mate: %s\n' "$1"
SH
chmod +x "$ROOT/bin"/*.sh
git -C "$ROOT" init -q -b main; git -C "$ROOT" -c user.email=l@x -c user.name=lab add -A
git -C "$ROOT" -c user.email=l@x -c user.name=lab commit -qm lab
export HOME="$HOMEDIR" FM_ROOT_OVERRIDE="$ROOT" FM_REMOTE_JOB_STATE_ROOT="$STATE" FM_REMOTE_JOB_PLATFORM_OVERRIDE=Linux
log() { printf '[%s %s] %s\n' "$LABEL" "$(date +%T)" "$*"; }
cleanup() { pkill -KILL -f "$ROOT/bin/fm-" 2>/dev/null; rm -rf "$LAB"; }
trap cleanup EXIT
. "$ROOT/bin/fm-remote-job-lib.sh"
set -m
log "== midjob case, ref $(git -C "$SRC" rev-parse --short "$REF")"
"$ROOT/bin/fm-remote-job-worker.sh" 2> "$LAB/supA.err" & SUPA=$!
for _ in $(seq 300); do SERVEA=$(cat "$STATE/worker.lock/pid" 2>/dev/null); [ -n "$SERVEA" ] && [ -f "$STATE/worker.ready" ] && break; sleep 0.05; done
kill -STOP "$SERVEA"
printf 'Thu Jan  1 00:00:00 2000\n' > "$STATE/worker.lock/start"
touch -t 200001010000 "$STATE/worker.ready" "$STATE/worker.lock"
"$ROOT/bin/fm-remote-job-worker.sh" 2> "$LAB/supB.err" & SUPB=$!
for _ in $(seq 300); do SERVEB=$(cat "$STATE/worker.lock/pid" 2>/dev/null); [ -n "$SERVEB" ] && [ "$SERVEB" != "$SERVEA" ] && break; sleep 0.05; done
log "A serve=$SERVEA stalled; B serve=$SERVEB owns queue"
FM_REMOTE_JOB_TIMEOUT=30 fm_remote_job_stage "$HOMEDIR" "$ROOT" "$RHOME" fm-reply-job.sh midjob "$LAB/started" </dev/null >/dev/null
id=$FM_REMOTE_JOB_ID
for _ in $(seq 200); do [ -f "$LAB/started" ] && break; sleep 0.05; done
log "owner B is running job $id (started marker present: $([ -f "$LAB/started" ] && echo yes || echo no)); resuming A now"
kill -CONT "$SERVEA"
fm_remote_job_wait "$HOMEDIR" "$id"; log "midjob job exit=$FM_REMOTE_JOB_EXIT stdout=[$(cat "$FM_REMOTE_JOB_STDOUT")] stderr=[$(cat "$FM_REMOTE_JOB_STDERR")]"
sleep 1
log "supervisor A alive? $(kill -0 $SUPA 2>/dev/null && echo yes || echo no); serve A alive? $(kill -0 $SERVEA 2>/dev/null && echo yes || echo no); B serve alive? $(kill -0 $SERVEB 2>/dev/null && echo yes || echo no); lock pid=$(cat "$STATE/worker.lock/pid")"
log "supervisor A stderr: $(cat "$LAB/supA.err")"

log "== unowned case: lock/pid briefly unreadable on the sole owner B"
mv "$STATE/worker.lock/pid" "$LAB/pid.aside"
FM_REMOTE_JOB_TIMEOUT=30 fm_remote_job_stage "$HOMEDIR" "$ROOT" "$RHOME" fm-reply-job.sh unowned </dev/null >/dev/null
id=$FM_REMOTE_JOB_ID
sleep 2.5
log "after 2.5s with no readable owner: B serve alive? $(kill -0 $SERVEB 2>/dev/null && echo yes || echo no); job state=$(cat "$STATE/jobs/$id/state" 2>/dev/null)"
mv "$LAB/pid.aside" "$STATE/worker.lock/pid"
fm_remote_job_wait "$HOMEDIR" "$id"; log "unowned job exit=$FM_REMOTE_JOB_EXIT stdout=[$(cat "$FM_REMOTE_JOB_STDOUT")] stderr=[$(cat "$FM_REMOTE_JOB_STDERR")]"
log "B serve still alive? $(kill -0 $SERVEB 2>/dev/null && echo yes || echo no); supervisor B stderr: [$(cat "$LAB/supB.err")]"
