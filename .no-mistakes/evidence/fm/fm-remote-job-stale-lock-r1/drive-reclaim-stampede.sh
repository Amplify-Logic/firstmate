#!/usr/bin/env bash
# Live driver: the Dell's actual shape - many workers hitting ONE stale
# ownership lock at the same moment on a loaded machine. Exactly one may end up
# serving the account queue; none may fail into the supervisor's restart path.
#
# Usage: drive-reclaim-stampede.sh <worker-script> <label> [workers]
set -u
WORKER_SRC=$1
LABEL=$2
N=${3:-12}
REPO=/Users/larsmusic/.no-mistakes/worktrees/f569cc43ac96/01M2RQM0H30CJJKX0BHV4NFVJ0
WORK=$(mktemp -d "${TMPDIR:-/tmp}/fm-stampede-$LABEL.XXXXXX")
WORK=$(cd -P -- "$WORK" && pwd -P)
ROOT="$WORK/remote-root"; ACCT="$WORK/account"; STATE="$WORK/remote-jobs"
RC=0
say() { printf '%s\n' "$*"; }
step() { printf '\n=== %s ===\n' "$*"; }
bad() { printf 'FAIL: %s\n' "$*"; RC=1; }
PIDS=()
cleanup() { for p in "${PIDS[@]:-}"; do kill -KILL "$p" 2>/dev/null; done; rm -rf -- "$WORK"; }
trap cleanup EXIT

# The queue directories a live account already has; creating them here keeps
# the stampede on the ownership lock instead of racing state preparation.
mkdir -p "$ROOT/bin" "$ACCT" "$WORK/remote-home" "$STATE/worker.lock" "$STATE/logs" \
  "$STATE/jobs" "$STATE/.seq-claims"
chmod 700 "$ACCT" "$STATE" "$STATE/worker.lock" "$STATE/jobs" "$STATE/.seq-claims" "$STATE/logs"
cp "$REPO/bin/fm-remote-job-lib.sh" "$REPO/bin/fm-remote-delta-read.sh" "$ROOT/bin/"
cp "$WORKER_SRC" "$ROOT/bin/fm-remote-job-worker.sh"
chmod 755 "$ROOT/bin"/*.sh
printf 'fixture\n' > "$ROOT/AGENTS.md"
cat > "$ROOT/bin/fm-probe-job.sh" <<'SH'
#!/bin/bash
printf 'job ran once\n'
SH
chmod 755 "$ROOT/bin/fm-probe-job.sh"
git -C "$ROOT" init -q -b main
git -C "$ROOT" -c user.email=t@e.x -c user.name=T add AGENTS.md bin >/dev/null
git -C "$ROOT" -c user.email=t@e.x -c user.name=T commit -qm fixture

# The crashed owner's records, aged past every staleness window.
printf '999999\n' > "$STATE/worker.lock/pid"
printf 'a start ps will never report\n' > "$STATE/worker.lock/start"
printf 'a command ps will never report\n' > "$STATE/worker.lock/command"
printf 'interrupted\n' > "$STATE/worker.lock/.pid.XXXXXX"
printf '999999\n' > "$STATE/worker.ready"
chmod 600 "$STATE/worker.lock"/* "$STATE/worker.lock"/.[!.]* "$STATE/worker.ready"
touch -t 200001010000 "$STATE/worker.lock" "$STATE/worker.ready"

export FM_REMOTE_JOB_STATE_ROOT="$STATE" FM_REMOTE_JOB_PLATFORM_OVERRIDE=Linux
export FM_REMOTE_JOB_QUEUE_TIMEOUT=60 FM_REMOTE_JOB_TIMEOUT=30

step "$N workers start at once on one stale lock"
for i in $(seq 1 "$N"); do
  HOME="$ACCT" FM_ROOT_OVERRIDE="$ROOT" FM_REMOTE_JOB_STATE_ROOT="$STATE" \
    FM_REMOTE_JOB_PLATFORM_OVERRIDE=Linux "$ROOT/bin/fm-remote-job-worker.sh" --serve \
    > "$WORK/w$i.out" 2> "$WORK/w$i.err" &
  PIDS+=("$!")
done
say "launched: ${PIDS[*]}"

DEADLINE=$((SECONDS + 40))
while [ "$SECONDS" -lt "$DEADLINE" ]; do
  alive=0
  for p in "${PIDS[@]}"; do kill -0 "$p" 2>/dev/null && alive=$((alive + 1)); done
  [ "$alive" -le 1 ] && break
  sleep 0.5
done

# Let the surviving owner publish one heartbeat before reading ownership.
for _ in $(seq 1 100); do
  hb=$(cat "$STATE/worker.ready" 2>/dev/null || true)
  [ -n "$hb" ] && [ "$hb" != 999999 ] && break
  sleep 0.1
done

step "outcome per worker"
ALIVE=(); EXITED_OK=0; EXITED_BAD=0
for idx in "${!PIDS[@]}"; do
  p=${PIDS[$idx]}
  if kill -0 "$p" 2>/dev/null; then
    ALIVE+=("$p")
    say "worker $((idx + 1)) pid $p: still serving"
  else
    wait "$p" 2>/dev/null; rc=$?
    if [ "$rc" -eq 0 ]; then
      EXITED_OK=$((EXITED_OK + 1))
    else
      EXITED_BAD=$((EXITED_BAD + 1))
      say "worker $((idx + 1)) pid $p: exited $rc -- $(tr -d '\n' < "$WORK/w$((idx + 1)).err")"
    fi
  fi
done
say "serving: ${#ALIVE[@]}   deferred cleanly (exit 0): $EXITED_OK   failed (nonzero): $EXITED_BAD"

step "recorded ownership"
say "worker.lock contents: $(ls -A "$STATE/worker.lock" | tr '\n' ' ')"
say "worker.lock/pid: $(cat "$STATE/worker.lock/pid" 2>/dev/null || echo '<none>')"
say "worker.ready:    $(cat "$STATE/worker.ready" 2>/dev/null || echo '<none>')"
[ "${#ALIVE[@]}" -eq 1 ] || bad "expected exactly one serving worker, got ${#ALIVE[@]}"
[ "$EXITED_BAD" -eq 0 ] || bad "$EXITED_BAD worker(s) failed into the supervisor's restart path"
[ "$(cat "$STATE/worker.lock/pid" 2>/dev/null)" = "$(cat "$STATE/worker.ready" 2>/dev/null)" ] \
  || bad "the lock owner and the heartbeat disagree"
[ -e "$STATE/worker.lock/claim" ] && bad "a claim marker was left behind"
[ -e "$STATE/worker.lock/.pid.XXXXXX" ] && bad "the crash leftover was not swept"

step "the account still serves exactly one result for one job"
# shellcheck source=/dev/null
. "$ROOT/bin/fm-remote-job-lib.sh"
if fm_remote_job_stage "$ACCT" "$ROOT" "$WORK/remote-home" fm-probe-job.sh </dev/null >/dev/null; then
  JOB=$FM_REMOTE_JOB_ID
  if fm_remote_job_wait "$ACCT" "$JOB"; then
    say "job $JOB exit=$FM_REMOTE_JOB_EXIT stdout=$(tr -d '\n' < "$FM_REMOTE_JOB_STDOUT")"
    [ "$FM_REMOTE_JOB_EXIT" -eq 0 ] || bad "the job failed on the surviving owner"
    [ "$(wc -l < "$FM_REMOTE_JOB_STDOUT" | tr -d ' ')" = 1 ] || bad "the job ran more than once"
  else
    bad "no worker served the job: $FM_REMOTE_JOB_ERROR"
  fi
else
  bad "the job could not be staged: $FM_REMOTE_JOB_ERROR"
fi

step "RESULT"
[ "$RC" -eq 0 ] && say "PASS ($LABEL): one owner, no failures, queue served" || say "NO-GO ($LABEL)"
exit "$RC"
