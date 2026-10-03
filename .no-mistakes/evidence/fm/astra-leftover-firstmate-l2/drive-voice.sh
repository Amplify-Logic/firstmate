#!/usr/bin/env bash
# Live drive of bin/fm-voice-idea.py (target and base) with fake transports in a
# throwaway FM_HOME; mimics the watcher stopping a check: group TERM, 0.2s, group KILL.
set -u
ROOT=$1; IDEA_BIN=$2; LABEL=$3
fm_test_tmproot() { mktemp -d "${TMPDIR:-/tmp}/$1.XXXXXX"; }
. "$(dirname "$0")/voice-fixture-world.sh"
export PYTHONDONTWRITEBYTECODE=1
ID1=11111111-1111-4111-8111-111111111111
ID2=22222222-2222-4222-8222-222222222222
hang_tool() {  # leader + child both ignore TERM; record pids
cat > "$1" <<'PY'
#!/usr/bin/env python3
import os, pathlib, signal, subprocess, sys, time
signal.signal(signal.SIGTERM, signal.SIG_IGN)
child = subprocess.Popen([sys.executable, "-c", "import signal,time; signal.signal(signal.SIGTERM, signal.SIG_IGN); time.sleep(40)"])
pathlib.Path(os.environ["FAKE_LOG_DIR"], "pids").write_text(f"{os.getpid()} {child.pid}")
time.sleep(40)
PY
chmod +x "$1"; }
alive() { local s; s=$(ps -o stat= -p "$1" 2>/dev/null | tr -d ' '); [ -n "$s" ] && [ "${s#Z}" = "$s" ]; }
report_pids() { local p out=""; for p in $(cat "$W/log/pids"); do if alive "$p"; then out="$out $p:ALIVE"; else out="$out $p:gone"; fi; done; echo "transport pids after:$out"; for p in $(cat "$W/log/pids"); do kill -9 "$p" 2>/dev/null; done; }

echo "=== [$LABEL] watcher cancels 'check' during each transport ==="
for phase in import answer announce; do
  make_world; make_wav "$W/audio/hum.wav" 91
  add_question "$ID1" "What a Life bridge idea" "$W/audio/hum.wav" audio/wav
  [ "$phase" != announce ] || python3 -c 'import sqlite3,sys; c=sqlite3.connect(sys.argv[1]); c.execute("UPDATE requests SET state=\"answered\", answer_json=\"{}\""); c.commit()' "$DB"
  case $phase in import) hang_tool "$FM_VOICE_IDEA_TARTEVO";; answer) hang_tool "$FM_VOICE_IDEA_ANSWER";; announce) hang_tool "$FM_VOICE_IDEA_ANNOUNCE";; esac
  export FM_VOICE_IDEA_IMPORT_TIMEOUT=30 FM_VOICE_IDEA_SPEAK_TIMEOUT=30
  if [ $phase = announce ]; then cmd=(take "$ID1"); else cmd=(check); fi
  python3 - "$IDEA_BIN" "$W/log/pids" "${cmd[@]}" <<'PY'
import os, pathlib, signal, subprocess, sys, time
m = pathlib.Path(sys.argv[2])
p = subprocess.Popen([sys.argv[1]] + sys.argv[3:], start_new_session=True, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
for _ in range(300):
    if m.exists() and len(m.read_text().split()) == 2: break
    time.sleep(0.05)
os.killpg(p.pid, signal.SIGTERM); time.sleep(0.2)
try: os.killpg(p.pid, signal.SIGKILL)
except (ProcessLookupError, PermissionError): pass
print("check exit:", p.wait(5)); time.sleep(0.5)
PY
  echo -n "phase=$phase "; report_pids
  [ $phase != announce ] || echo "announce-attempt: $(cat "$FM_HOME/data/voice-ideas/captures/$ID1/announce-attempt.json" 2>/dev/null)"
done

echo "=== [$LABEL] import timeout with TERM-ignoring descendants ==="
make_world; make_wav "$W/audio/hum.wav" 92
add_question "$ID1" "What a Life bridge idea" "$W/audio/hum.wav" audio/wav
hang_tool "$FM_VOICE_IDEA_TARTEVO"; export FM_VOICE_IDEA_IMPORT_TIMEOUT=1
start=$(python3 -c 'import time;print(time.time())')
"$IDEA_BIN" take "$ID1"; echo "take exit=$?"
python3 -c 'import time,sys;print("elapsed %.2fs" % (time.time()-float(sys.argv[1])))' "$start"
report_pids
echo "answers spoken: $(cat "$W/log/answers.log")"
