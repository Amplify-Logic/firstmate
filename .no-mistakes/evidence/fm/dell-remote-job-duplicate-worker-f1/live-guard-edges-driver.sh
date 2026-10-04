#!/usr/bin/env bash
# Live driver for the yield guard's edges, using the real worker against a disposable queue.
# Usage: live-guard-edges-driver.sh <worktree> <git-rev>
set -u
SRC=$1 REV=$2
T=$(mktemp -d "${TMPDIR:-/tmp}/fm-rj-edge.XXXXXX"); T=$(cd "$T" && pwd -P)
R="$T/remote-root" ACC="$T/account" FMH="$T/fm-home" ST="$T/jobs"
mkdir -p "$R/bin" "$ACC" "$FMH"; chmod 700 "$ACC"
for f in fm-remote-job-lib.sh fm-remote-job-worker.sh fm-remote-delta-read.sh; do
  git -C "$SRC" show "$REV:bin/$f" > "$R/bin/$f"; done
printf 'fixture\n' > "$R/AGENTS.md"
printf '#!/bin/bash\nprintf "ran\\n" > "$1"\nprintf "reply ok\\n"\n' > "$R/bin/fm-reply-job.sh"
chmod +x "$R/bin"/*.sh
git -C "$R" init -q -b main; git -C "$R" -c user.email=t@e -c user.name=t add -A
git -C "$R" -c user.email=t@e -c user.name=t commit -qm fixture
export FM_REMOTE_JOB_STATE_ROOT="$ST"
. "$R/bin/fm-remote-job-lib.sh"
start_sup() { ( set -m; HOME="$ACC" FM_ROOT_OVERRIDE="$R" FM_REMOTE_JOB_STATE_ROOT="$ST" FM_REMOTE_JOB_PLATFORM_OVERRIDE=Linux \
    nohup "$R/bin/fm-remote-job-worker.sh" >> "$1" 2>&1 < /dev/null & echo $! ) ; }
serve_child_of() { pgrep -P "$1" -f -- '--serve' | head -1; }
lockpid() { cat "$ST/worker.lock/pid" 2>/dev/null || true; }
alive() { kill -0 "$1" 2>/dev/null && echo alive || echo exited; }
stop_all() { for p in "$@"; do kill -CONT "$p" 2>/dev/null; kill -TERM -- "-$p" 2>/dev/null; done; sleep 0.5; for p in "$@"; do kill -KILL -- "-$p" 2>/dev/null; done; }
trap 'stop_all ${SUP1:-} ${SUP2:-} ${SUP3:-}; rm -rf "$T"' EXIT
echo "=== guard edges, code rev $(git -C "$SRC" rev-parse --short "$REV") ==="

echo; echo "### Scenario: resumed duplicate must not touch a QUEUED job it does not own"
SUP1=$(start_sup "$T/sup1.log")
for _ in $(seq 1 200); do C1=$(serve_child_of "$SUP1"); [ -n "$C1" ] && [ "$(lockpid)" = "$C1" ] && [ -f "$ST/worker.ready" ] && break; sleep 0.05; done
kill -STOP "$C1"
printf 'Thu Jan  1 00:00:00 2000\n' > "$ST/worker.lock/start"; touch -t 200001010000 "$ST/worker.ready" "$ST/worker.lock"
SUP2=$(start_sup "$T/sup2.log")
for _ in $(seq 1 300); do C2=$(serve_child_of "$SUP2"); [ -n "$C2" ] && [ "$(lockpid)" = "$C2" ] && break; sleep 0.05; done
echo "loop#1=$C1 (stalled)  loop#2=$C2 now owns lock=$(lockpid)"
kill -STOP "$C2"; echo "owner loop#2 paused so the job stays queued"
FM_REMOTE_JOB_TIMEOUT=20 fm_remote_job_stage "$ACC" "$R" "$FMH" fm-reply-job.sh "$T/ran-q" </dev/null >/dev/null
JOB=$FM_REMOTE_JOB_ID; JD="$ST/jobs/$JOB"
echo "staged $JOB state=$(cat "$JD/state" 2>/dev/null)"
kill -CONT "$C1"; echo "loop#1 resumed beside the queued job"
for _ in $(seq 1 100); do kill -0 "$C1" 2>/dev/null || break; sleep 0.05; done
sleep 0.5
echo "loop#1 $(alive "$C1"), supervisor#1 $(alive "$SUP1"); job state=$(cat "$JD/state" 2>/dev/null) claim-dir=$([ -e "$JD/.claim" ] && echo PRESENT || echo absent) ran=$([ -f "$T/ran-q" ] && echo yes || echo no) lock=$(lockpid)"
kill -CONT "$C2"; echo "owner loop#2 resumed"
fm_remote_job_wait "$ACC" "$JOB"; echo "listener: wait rc=$? exit=$FM_REMOTE_JOB_EXIT stdout=$(cat "$FM_REMOTE_JOB_STDOUT") stderr=$(cat "$FM_REMOTE_JOB_STDERR")"
echo "sup1 log: $(cat "$T/sup1.log")"
stop_all "$SUP1" "$SUP2"; SUP1= SUP2=
rm -rf "$ST"

echo; echo "### Scenario: lone worker with a momentarily unreadable lock owner keeps serving (no false yield)"
SUP3=$(start_sup "$T/sup3.log")
for _ in $(seq 1 200); do C3=$(serve_child_of "$SUP3"); [ -n "$C3" ] && [ "$(lockpid)" = "$C3" ] && [ -f "$ST/worker.ready" ] && break; sleep 0.05; done
echo "loop#3=$C3 owns lock=$(lockpid)"
FM_REMOTE_JOB_TIMEOUT=20 fm_remote_job_stage "$ACC" "$R" "$FMH" fm-reply-job.sh "$T/ran-a" </dev/null >/dev/null
fm_remote_job_wait "$ACC" "$FM_REMOTE_JOB_ID"; echo "baseline job: rc=$? exit=$FM_REMOTE_JOB_EXIT stdout=$(cat "$FM_REMOTE_JOB_STDOUT")"
mv "$ST/worker.lock/pid" "$T/pid.saved"; echo "worker.lock/pid removed (owner unreadable, as during a reclaim still publishing)"
sleep 3
echo "after 3s of polls: loop#3 $(alive "$C3"), supervisor#3 $(alive "$SUP3"), heartbeat ready=$(cat "$ST/worker.ready")"
FM_REMOTE_JOB_TIMEOUT=20 fm_remote_job_stage "$ACC" "$R" "$FMH" fm-reply-job.sh "$T/ran-b" </dev/null >/dev/null
fm_remote_job_wait "$ACC" "$FM_REMOTE_JOB_ID"; echo "job while owner unreadable: rc=$? exit=$FM_REMOTE_JOB_EXIT stdout=$(cat "$FM_REMOTE_JOB_STDOUT")"
mv "$T/pid.saved" "$ST/worker.lock/pid"; sleep 2
echo "owner restored to own pid: loop#3 $(alive "$C3")"
echo "sup3 log: $(cat "$T/sup3.log")"
