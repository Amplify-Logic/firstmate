#!/usr/bin/env bash
# Live driver: runs the real fm-remote-job-worker.sh (Linux supervisor mode) against a
# disposable account home + queue, recreating the larsdell duplicate-serving-loop state.
# Usage: live-duplicate-worker-driver.sh <worktree> <git-rev> <label>
set -u
SRC=$1 REV=$2 LABEL=$3
T=$(mktemp -d "${TMPDIR:-/tmp}/fm-rj-live.XXXXXX"); T=$(cd "$T" && pwd -P)
R="$T/remote-root" ACC="$T/account" FMH="$T/fm-home" ST="$T/jobs"
mkdir -p "$R/bin" "$ACC" "$FMH"; chmod 700 "$ACC"
for f in fm-remote-job-lib.sh fm-remote-job-worker.sh fm-remote-delta-read.sh; do
  git -C "$SRC" show "$REV:bin/$f" > "$R/bin/$f"; done
printf 'fixture\n' > "$R/AGENTS.md"
cat > "$R/bin/fm-reply-job.sh" <<'SH'
#!/bin/bash
printf 'started\n' > "$1"
sleep 2
printf 'reply from dell second mate\n'
SH
chmod +x "$R/bin"/*.sh
git -C "$R" init -q -b main; git -C "$R" -c user.email=t@e -c user.name=t add -A
git -C "$R" -c user.email=t@e -c user.name=t commit -qm fixture
export FM_REMOTE_JOB_STATE_ROOT="$ST"
. "$R/bin/fm-remote-job-lib.sh"
start_sup() { # <log>
  ( set -m; HOME="$ACC" FM_ROOT_OVERRIDE="$R" FM_REMOTE_JOB_STATE_ROOT="$ST" FM_REMOTE_JOB_PLATFORM_OVERRIDE=Linux \
    nohup "$R/bin/fm-remote-job-worker.sh" >> "$1" 2>&1 < /dev/null & echo $! ) ; }
serve_child_of() { pgrep -P "$1" -f -- '--serve' | head -1; }
lockpid() { cat "$ST/worker.lock/pid" 2>/dev/null || true; }
alive() { kill -0 "$1" 2>/dev/null && echo alive || echo exited; }
cleanup() { for p in ${SUP1:-} ${SUP2:-}; do kill -CONT "$p" 2>/dev/null; kill -TERM -- "-$p" 2>/dev/null; done; sleep 0.5
  for p in ${SUP1:-} ${SUP2:-}; do kill -KILL -- "-$p" 2>/dev/null; done; rm -rf "$T"; }
trap cleanup EXIT
echo "=== [$LABEL] code rev $(git -C "$SRC" rev-parse --short "$REV") ==="
SUP1=$(start_sup "$T/sup1.log")
for _ in $(seq 1 200); do C1=$(serve_child_of "$SUP1"); [ -n "$C1" ] && [ "$(lockpid)" = "$C1" ] && [ -f "$ST/worker.ready" ] && break; sleep 0.05; done
echo "supervisor#1 pid=$SUP1  serve-loop#1 pid=$C1  lock owner=$(lockpid)"
kill -STOP "$C1"; echo "serve-loop#1 stalled (SIGSTOP) - its heartbeat goes stale"
printf 'Thu Jan  1 00:00:00 2000\n' > "$ST/worker.lock/start"
touch -t 200001010000 "$ST/worker.ready" "$ST/worker.lock"
SUP2=$(start_sup "$T/sup2.log")
for _ in $(seq 1 300); do C2=$(serve_child_of "$SUP2"); [ -n "$C2" ] && [ "$(lockpid)" = "$C2" ] && break; sleep 0.05; done
echo "supervisor#2 pid=$SUP2  serve-loop#2 pid=$C2  lock owner=$(lockpid)  (reclaimed stale lock)"
echo "--- two worker parents + two serve loops on one queue (the larsdell state):"
ps -o pid=,ppid=,command= -p "$SUP1,$C1,$SUP2,$C2" | sed "s#$R#<root>#"
FM_REMOTE_JOB_TIMEOUT=20 fm_remote_job_stage "$ACC" "$R" "$FMH" fm-reply-job.sh "$T/started" </dev/null >/dev/null
JOB=$FM_REMOTE_JOB_ID
for _ in $(seq 1 200); do [ -f "$T/started" ] && break; sleep 0.05; done
echo "job $JOB staged by listener; running=$([ -f "$T/started" ] && echo yes || echo no)"
kill -CONT "$C1"; echo "serve-loop#1 resumed (SIGCONT)"
fm_remote_job_wait "$ACC" "$JOB"; WRC=$?
echo "--- listener result: wait rc=$WRC exit=${FM_REMOTE_JOB_EXIT:-?}"
echo "stdout: $(cat "$FM_REMOTE_JOB_STDOUT" 2>/dev/null)"
echo "stderr: $(cat "$FM_REMOTE_JOB_STDERR" 2>/dev/null)"
sleep 1
echo "--- after: serve-loop#1 $(alive "$C1"), supervisor#1 $(alive "$SUP1"), serve-loop#2 $(alive "$C2"), supervisor#2 $(alive "$SUP2"), lock owner=$(lockpid) ready=$(cat "$ST/worker.ready" 2>/dev/null)"
FM_REMOTE_JOB_TIMEOUT=20 fm_remote_job_stage "$ACC" "$R" "$FMH" fm-reply-job.sh "$T/started2" </dev/null >/dev/null
fm_remote_job_wait "$ACC" "$FM_REMOTE_JOB_ID"; echo "--- follow-up job: wait rc=$? exit=$FM_REMOTE_JOB_EXIT stdout=$(cat "$FM_REMOTE_JOB_STDOUT")"
echo "--- worker log (supervisor#1):"; cat "$T/sup1.log"
echo "--- worker log (supervisor#2):"; cat "$T/sup2.log"
echo "claim-race lines in logs: $(cat "$T"/sup*.log | grep -c -e '.claim: File exists' -e '.claim/supervisor')"
