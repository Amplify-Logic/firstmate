#!/usr/bin/env bash
# Live driver: stand the remote-job worker up the way `fm on` does (ensure path
# -> Linux restart supervisor -> serving worker) against an account whose worker
# family was killed mid-flight, the way the Dell's suspend/resume left it.
#
# Usage: drive-stale-lock-reclaim.sh <worker-script> <label>
# Prints a transcript of what an operator would see.
set -u

WORKER_SRC=$1
LABEL=$2
REPO=/Users/larsmusic/.no-mistakes/worktrees/f569cc43ac96/01M2RQM0H30CJJKX0BHV4NFVJ0
WORK=$(mktemp -d "${TMPDIR:-/tmp}/fm-reclaim-$LABEL.XXXXXX")
WORK=$(cd -P -- "$WORK" && pwd -P)
ROOT="$WORK/remote-root"
ACCT="$WORK/account"
STATE="$WORK/remote-jobs"
LOG="$STATE/logs/dev.firstmate.remote-job.log"
RC=0

say() { printf '%s\n' "$*"; }
step() { printf '\n=== %s ===\n' "$*"; }
bad() { printf 'FAIL: %s\n' "$*"; RC=1; }

cleanup() {
  if [ -f "$STATE/worker.pid" ]; then
    pid=$(cat "$STATE/worker.pid" 2>/dev/null || true)
    case "$pid" in ''|*[!0-9]*) ;; *) pgid=$(ps -o pgid= -p "$pid" 2>/dev/null | tr -d ' ') ; [ -n "$pgid" ] && kill -KILL -- "-$pgid" 2>/dev/null; kill -KILL "$pid" 2>/dev/null ;; esac
  fi
  for p in ${SPAWNED:-}; do
    pgid=$(ps -o pgid= -p "$p" 2>/dev/null | tr -d ' ')
    [ -n "$pgid" ] && kill -KILL -- "-$pgid" 2>/dev/null
    kill -KILL "$p" 2>/dev/null
  done
  rm -rf -- "$WORK"
}
trap cleanup EXIT
SPAWNED=

mkdir -p "$ROOT/bin" "$ACCT" "$WORK/remote-home"
chmod 700 "$ACCT"
cp "$REPO/bin/fm-remote-job-lib.sh" "$REPO/bin/fm-remote-delta-read.sh" "$ROOT/bin/"
cp "$WORKER_SRC" "$ROOT/bin/fm-remote-job-worker.sh"
chmod 755 "$ROOT/bin"/*.sh
printf 'fixture\n' > "$ROOT/AGENTS.md"
cat > "$ROOT/bin/fm-probe-job.sh" <<'SH'
#!/bin/bash
printf 'job ran on worker pid %s with FM_HOME=%s\n' "$$" "$FM_HOME"
SH
chmod 755 "$ROOT/bin/fm-probe-job.sh"
git -C "$ROOT" init -q -b main
git -C "$ROOT" -c user.email=t@e.x -c user.name=T add AGENTS.md bin >/dev/null
git -C "$ROOT" -c user.email=t@e.x -c user.name=T commit -qm fixture

export FM_REMOTE_JOB_STATE_ROOT="$STATE"
export FM_REMOTE_JOB_PLATFORM_OVERRIDE=Linux
export FM_REMOTE_JOB_QUEUE_TIMEOUT=30
export FM_REMOTE_JOB_TIMEOUT=30
# Keep a storming supervisor bounded so the transcript stays readable.
export FM_REMOTE_JOB_SUPERVISOR_MAX_RESTARTS=20
export FM_REMOTE_JOB_SUPERVISOR_MAX_BACKOFF_SECONDS=1
# shellcheck source=/dev/null
. "$ROOT/bin/fm-remote-job-lib.sh"

step "1. operator brings the account's remote worker up (fm on ensure path)"
if fm_remote_job_ensure_worker "$ROOT" "$ACCT"; then
  say "ensure_worker: ready, serving pid $(cat "$STATE/worker.pid")"
else
  bad "ensure_worker could not start a first worker: $FM_REMOTE_JOB_ERROR"
  exit 1
fi
FIRST_PID=$(cat "$STATE/worker.pid")
FIRST_PGID=$(ps -o pgid= -p "$FIRST_PID" | tr -d ' ')

step "2. the machine suspends and the worker family is killed (Dell resume)"
kill -KILL -- "-$FIRST_PGID" 2>/dev/null || true
sleep 1
kill -0 "$FIRST_PID" 2>/dev/null && bad "the killed worker family is still alive"
say "killed worker family pgid $FIRST_PGID"
say "ownership lock left behind:"
ls -A "$STATE/worker.lock" | sed 's/^/  worker.lock\//'
# A shutdown killed between mktemp and mv leaves a half-written record temp.
printf 'interrupted\n' > "$STATE/worker.lock/.command.XXXXXX"
chmod 600 "$STATE/worker.lock/.command.XXXXXX"
# Resume: the heartbeat and the lock are both long stale.
touch -t 200001010000 "$STATE/worker.lock" "$STATE/worker.ready" "$STATE/worker.pid"
say "plus a half-written .command.XXXXXX left by the interrupted shutdown"
say "worker.ready heartbeat aged to $(date -r "$STATE/worker.ready" '+%Y-%m-%d %H:%M')"

step "3. the next worker starts on that stale lock (what fm on does on resume)"
: > "$LOG"
START=$(date +%s)
if fm_remote_job_ensure_worker "$ROOT" "$ACCT"; then
  ELAPSED=$(( $(date +%s) - START ))
  NEW_PID=$(cat "$STATE/worker.pid")
  say "ensure_worker: READY after ${ELAPSED}s, serving pid $NEW_PID"
  say "worker.lock/pid now: $(cat "$STATE/worker.lock/pid" 2>/dev/null || echo '<none>')"
  [ "$(cat "$STATE/worker.lock/pid")" = "$NEW_PID" ] || bad "the lock does not record the new serving worker"
  kill -0 "$NEW_PID" 2>/dev/null || bad "the recorded owner is not alive"
else
  ELAPSED=$(( $(date +%s) - START ))
  bad "ensure_worker could not reclaim the stale lock after ${ELAPSED}s: $FM_REMOTE_JOB_ERROR"
fi

step "4. supervisor log (restart storm evidence)"
STORM=$(grep -c 'cannot acquire or safely reclaim worker ownership' "$LOG" 2>/dev/null || true)
say "worker startup failures logged: ${STORM:-0}"
sed -n '1,12p' "$LOG" | sed 's/^/  /'
[ "${STORM:-0}" -eq 0 ] || bad "the replacement worker restart-stormed ${STORM} times"

step "5. an operator's remote job actually runs on the reclaimed worker"
if fm_remote_job_stage "$ACCT" "$ROOT" "$WORK/remote-home" fm-probe-job.sh </dev/null >/dev/null; then
  JOB=$FM_REMOTE_JOB_ID
  if fm_remote_job_wait "$ACCT" "$JOB"; then
    say "job $JOB exit=$FM_REMOTE_JOB_EXIT"
    say "job stdout: $(cat "$FM_REMOTE_JOB_STDOUT")"
    [ "$FM_REMOTE_JOB_EXIT" -eq 0 ] || bad "the job did not succeed on the reclaimed worker"
  else
    bad "the job never completed on the reclaimed worker: $FM_REMOTE_JOB_ERROR"
  fi
else
  bad "the job could not be staged: $FM_REMOTE_JOB_ERROR"
fi

step "RESULT"
[ "$RC" -eq 0 ] && say "PASS ($LABEL): stale lock reclaimed, no restart storm, job served" \
  || say "NO-GO ($LABEL): see FAIL lines above"
exit "$RC"
