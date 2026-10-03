#!/usr/bin/env bash
# Drive the real PreToolUse hook (bin/fm-command-guard.py hook) against the
# repo's fake TypeSafe endpoint in a throwaway home. Invented key only.
set -u
ROOT=$1; LABEL=$2; FIX=$3
T=$(mktemp -d "${TMPDIR:-/tmp}/fm-guard-drive.XXXXXX"); SRV=$T/srv; mkdir -p "$SRV"
python3 "$FIX/fake-typesafe.py" "$SRV" & SRVPID=$!
for _ in $(seq 1 100); do [ -s "$SRV/port" ] && break; sleep 0.05; done
export FM_COMMAND_GUARD_ENDPOINT="http://127.0.0.1:$(cat "$SRV/port")/v1/systemone" FM_COMMAND_GUARD_TIMEOUT=2
unset TYPESAFE_API_KEY
home=$T/home; mkdir -p "$home/state" "$home/config"
printf 'TYPESAFE_API_KEY=ts-fixture-key-0001\n' > "$home/.env"; printf 'enabled = true\n' > "$home/config/command-guard"
cp "$FIX/response-force-push.json" "$SRV/response.json"
hook() { python3 -c 'import json,sys; print(json.dumps({"hook_event_name":"PreToolUse","tool_name":"Bash","tool_input":{"command":sys.argv[1]}}))' "$1" \
  | env -u FM_COMMAND_GUARD_ENV_FILE python3 "$ROOT/bin/fm-command-guard.py" hook --config "$home/config" --state "$home/state" --home "$home" --task t1 --project demo; }

echo "=== [$LABEL] A: Jev blocks after 1s, then the decision log write stalls (log is a FIFO with no reader) ==="
printf '1\n' > "$SRV/delay"; mkfifo "$home/state/command-guard.log"
s=$(python3 -c "import time;print(time.time())"); out=$(hook "git push --force origin main" 2>"$T/err"); rc=$?; e=$(python3 -c "import time,sys;print('%.2f' % (time.time()-float(sys.argv[1])))" "$s")
echo "  exit=$rc elapsed=${e}s"
echo "  decision: $(printf '%s' "$out" | python3 -c 'import json,sys
d=sys.stdin.read().strip()
print(json.loads(d)["hookSpecificOutput"]["permissionDecision"] if d else "<none: command would be ALLOWED>")')"
echo "  stderr: $(cat "$T/err")"
echo "  outage marker present: $([ -e "$home/state/.command-guard-outage" ] && echo yes || echo no)"
rm -f "$home/state/command-guard.log" "$home/state/.command-guard-outage" "$SRV/delay"

echo "=== [$LABEL] B: 8 concurrent hooks against a >2 MiB log (rotation race) ==="
python3 -c 'import sys; open(sys.argv[1],"w").write("old history line\n" * (2*1024*1024//17 + 50))' "$home/state/command-guard.log"
before=$(shasum "$home/state/command-guard.log" | cut -c1-12)
pids=""; for i in 1 2 3 4 5 6 7 8; do hook "git push --force origin main" >/dev/null 2>&1 & pids="$pids $!"; done; wait $pids
echo "  .1 holds original history: $([ "$(shasum "$home/state/command-guard.log.1" 2>/dev/null | cut -c1-12)" = "$before" ] && echo yes || echo NO)"
echo "  decisions in fresh log: $(grep -c '"outcome": "block"' "$home/state/command-guard.log" 2>/dev/null) (want 8)"
kill $SRVPID 2>/dev/null; wait $SRVPID 2>/dev/null; rm -rf "$T"
