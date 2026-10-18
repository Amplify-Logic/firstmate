#!/usr/bin/env bash
# Behavior tests for the call companion (bin/fm-call-*.sh, docs/call-companion.md).
#
# Contracts under test:
#   - Recording starts only with --everyone-agreed; the agreement is written at
#     the top of the transcript, and a start without it records nothing.
#   - The watcher never starts a recording: a new call raises one reminder that
#     names the start command, and a running recording is stopped and archived
#     once the call has been gone for 180 seconds.
#   - Every runtime file lands under the home's data/calls and state/calls,
#     settings come from config/call-companion, and an unknown key is refused.
#   - The microphone pipeline keeps overlapping chunks, labels speech by the
#     track that carried it, and deletes each chunk's audio once transcribed.
#   - The live desk keeps only grounded items, records each once, and the
#     end-of-call notes account for every live item without quoting anyone.
#   - delete removes the current call, one archived call, or everything, and
#     refuses while recording.
#   - The second screen is driven only through the configured ssh host.
# shellcheck disable=SC2016
set -u

# shellcheck source=tests/lib.sh disable=SC1091
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

TMP_ROOT=$(fm_test_tmproot fm-call-companion-tests)
PY=$(command -v python3)
command -v jq >/dev/null 2>&1 || { echo 'ok - skipped: jq is not installed'; exit 0; }

# new_home <name> - an operational home with empty config, data and state.
new_home() {
  local home="$TMP_ROOT/$1"
  mkdir -p "$home/config" "$home/data" "$home/state"
  printf '%s\n' "$home"
}

# Fake ffmpeg and whisper-cli: list a microphone and a loopback, "record" for
# the requested duration, and log what was asked of them.
install_fake_audio_tools() {
  local bin=$1
  mkdir -p "$bin"
  cat > "$bin/ffmpeg" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
args=" $* "
if [[ "$args" == *" -list_devices true "* ]]; then
  printf '[AVFoundation indev] AVFoundation audio devices:\n' >&2
  printf '[AVFoundation indev] [4] MacBook Microphone\n' >&2
  printf '[AVFoundation indev] [7] BlackHole 2ch\n' >&2
  exit 1
fi
if [[ "$args" == *" volumedetect "* ]]; then
  printf '[Parsed_volumedetect] mean_volume: -24.0 dB\n' >&2
  printf '[Parsed_volumedetect] max_volume: -12.0 dB\n' >&2
  printf 'level\t%s\n' "$*" >> "${FFMPEG_LOG:?}"
  exit 0
fi
for argument in "$@"; do
  if [[ "$argument" == *.wav ]]; then : > "$argument"; fi
done
if [[ "$args" == *" -f avfoundation "* ]]; then
  duration=0
  previous=
  for argument in "$@"; do
    if [ "$previous" = -t ]; then duration=$argument; break; fi
    previous=$argument
  done
  printf 'capture-args\t%s\n' "$*" >> "${FFMPEG_LOG:?}"
  printf 'capture-start\t%s\t%s\n' "$$" "$(python3 -c 'import time; print(time.time())')" >> "${FFMPEG_LOG:?}"
  sleep "$duration"
  printf 'capture-end\t%s\t%s\n' "$$" "$(python3 -c 'import time; print(time.time())')" >> "${FFMPEG_LOG:?}"
else
  printf 'mix\t%s\n' "$*" >> "${FFMPEG_LOG:?}"
fi
EOF
  cat > "$bin/whisper-cli" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
prefix=
previous=
for argument in "$@"; do
  if [ "$previous" = -of ]; then prefix=$argument; fi
  previous=$argument
done
printf 'whisper-start\t%s\t%s\n' "$$" "$(python3 -c 'import time; print(time.time())')" >> "${WHISPER_LOG:?}"
sleep "${WHISPER_SLEEP:-0.2}"
printf '%s\n' 'fixture transcript' > "$prefix.txt"
printf 'whisper-end\t%s\t%s\n' "$$" "$(python3 -c 'import time; print(time.time())')" >> "${WHISPER_LOG:?}"
EOF
  chmod +x "$bin/ffmpeg" "$bin/whisper-cli"
  : > "$bin/model.bin"
}

test_consent_gate_and_settings() {
  local home out rc
  home=$(new_home consent)
  out=$(FM_HOME="$home" "$ROOT/bin/fm-call-companion.sh" start --mic 2>&1) && rc=0 || rc=$?
  expect_code 2 "$rc" 'start without agreement did not refuse'
  assert_contains "$out" 'Ask everyone on the call first' 'refusal does not say to ask first'
  assert_contains "$out" '--everyone-agreed' 'refusal does not name the agreement flag'
  [ ! -e "$home/data/calls/transcript.txt" ] || fail 'a refused start wrote a transcript'
  [ -z "$(find "$home/state" -name '*.pid' 2>/dev/null)" ] || fail 'a refused start launched a process'
  out=$(FM_HOME="$home" "$ROOT/bin/fm-call-companion.sh" start --page 12 2>&1) && rc=0 || rc=$?
  expect_code 2 "$rc" 'caption start without agreement did not refuse'

  printf 'speker_name = Alex\n' > "$home/config/call-companion"
  out=$(FM_HOME="$home" "$ROOT/bin/fm-call-companion.sh" status 2>&1) && rc=0 || rc=$?
  [ "$rc" -ne 0 ] || fail 'an unknown settings key was accepted'
  assert_contains "$out" 'unknown key' 'unknown key refusal is not named'
  pass 'recording refuses without everyone agreeing, and an unknown setting is refused'
}

test_start_stop_records_agreement_in_home() {
  local home bin out rc
  home=$(new_home lifecycle)
  bin="$TMP_ROOT/lifecycle-bin"
  install_fake_audio_tools "$bin"
  cat > "$bin/claude" <<'EOF'
#!/usr/bin/env bash
cat > /dev/null
exit 1
EOF
  chmod +x "$bin/claude"
  printf 'speaker_name = Alex\nmulti_output_device =\n' > "$home/config/call-companion"
  export FFMPEG_LOG="$TMP_ROOT/lifecycle-ffmpeg.log" WHISPER_LOG="$TMP_ROOT/lifecycle-whisper.log"
  run_companion() {
    PATH="$bin:$PATH" FM_HOME="$home" FFMPEG_BIN="$bin/ffmpeg" WHISPER_BIN="$bin/whisper-cli" WHISPER_MODEL="$bin/model.bin" \
      MIC_CHUNK_SECONDS=2 MIC_CHUNK_OVERLAP_SECONDS=1 CALL_COMPANION_OPEN_BIN=true CALL_COMPANION_FINAL_NOTES=0 \
      CALL_COMPANION_CLAUDE_BIN="$bin/claude" "$ROOT/bin/fm-call-companion.sh" "$@"
  }
  out=$(run_companion start --mic --everyone-agreed 2>&1) || fail "start failed: $out"
  assert_contains "$out" 'started mic source' 'start did not report the microphone source'
  out=$(run_companion status 2>&1)
  assert_contains "$out" 'mic        running' 'microphone reader is not running'
  assert_contains "$out" 'digest     running' 'live desk is not running'
  grep -q '^# .* recording started (mic) after everyone on the call agreed to be recorded$' "$home/data/calls/transcript.txt" \
    || fail "agreement line missing: $(cat "$home/data/calls/transcript.txt")"
  [ -L "$home/data/calls/public/glance.html" ] || fail 'public desk view was not linked'
  [ ! -e "$home/data/calls/public/transcript.txt" ] || fail 'the transcript is reachable from the public folder'
  out=$(run_companion delete 2>&1) && rc=0 || rc=$?
  [ "$rc" -ne 0 ] || fail 'delete ran while recording'
  for _ in $(seq 1 60); do grep -q 'unknown speaker: fixture transcript' "$home/data/calls/transcript.txt" && break; sleep 0.1; done
  grep -q '^\[[0-9:]*\] unknown speaker: fixture transcript$' "$home/data/calls/transcript.txt" \
    || fail "no transcript line was written: $(cat "$home/data/calls/transcript.txt")"
  out=$(run_companion stop 2>&1) || fail "stop failed: $out"
  out=$(run_companion status 2>&1)
  assert_not_contains "$out" 'running' 'a part kept running after stop'
  tail -n 1 "$home/data/calls/transcript.txt" | grep -q '^# .* recording stopped$' || fail 'stop was not recorded'
  [ -z "$(find "$home/state/calls/audio" -name '*.wav' 2>/dev/null)" ] || fail 'audio outlived its transcript'
  [ ! -e "$ROOT/transcript.txt" ] && [ ! -e "$ROOT/data/calls" ] || fail 'runtime files landed in the code root'
  unset -f run_companion
  pass 'an agreed recording starts, writes into the home, keeps no audio, and records start and stop'
}

test_watch_reminds_and_stops_but_never_starts() {
  local w out
  w="$TMP_ROOT/watch"
  mkdir -p "$w/state"
  : > "$w/pages"; : > "$w/ps"; : > "$w/mic-pids"; : > "$w/recording"
  cat > "$w/companion" <<'STUB'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "${FIXTURE_LOG:?}"
if [ "$1" = status ]; then
  if [ -s "${FIXTURE_RECORDING:?}" ]; then printf 'mic        running (pid 42)\n'; else printf 'mic        stopped\n'; fi
fi
exit 0
STUB
  cat > "$w/notify" <<'STUB'
#!/usr/bin/env bash
printf '%s\n' "$1" >> "${FIXTURE_NOTES:?}"
STUB
  chmod +x "$w/companion" "$w/notify"
  run_at() {
    CALL_WATCH_NOW_EPOCH=$1 CALL_COMPANION_STATE_DIR="$w/state" CALL_WATCH_PAGES_FILE="$w/pages" CALL_WATCH_PS_FILE="$w/ps" \
      CALL_WATCH_MIC_PIDS_FILE="$w/mic-pids" CALL_WATCH_COMPANION="$w/companion" CALL_WATCH_NOTIFY_BIN="$w/notify" \
      FIXTURE_LOG="$w/lifecycle.log" FIXTURE_NOTES="$w/notes.log" FIXTURE_RECORDING="$w/recording" \
      "$ROOT/bin/fm-call-watch.sh" --once
  }
  count() { grep -c "^$1\$" "$w/lifecycle.log" 2>/dev/null || true; }
  notes() { wc -l < "$w/notes.log" 2>/dev/null | tr -d ' ' || printf 0; }

  # A Meet tab with nobody recording: one reminder naming the caption start, no start, no stop.
  printf '%s\n' '3 https://meet.google.com/abc-defg-hij' > "$w/pages"
  run_at 1000; run_at 1100
  [ "$(notes)" -eq 1 ] || fail "expected one reminder, got $(notes)"
  grep -q 'not recording.*ask everyone first.*fm-call-companion.sh start --page 3 --everyone-agreed' "$w/notes.log" \
    || fail "reminder does not name the caption start: $(cat "$w/notes.log")"
  : > "$w/pages"
  run_at 1279; run_at 1280
  ! grep -q '^start' "$w/lifecycle.log" || fail 'the watcher started a recording'
  [ "$(count stop)" -eq 0 ] || fail 'the watcher stopped a recording nobody started'
  [ "$(jq -r .active "$w/state/call-watch.json")" = false ] || fail 'the ended call is still open'

  # A Zoom call recorded by hand: the reminder names the microphone start, and the end stops and archives it.
  printf '%s\n' '501 /Applications/zoom.us.app/Contents/MacOS/zoom.us' > "$w/ps"
  printf '501\tus.zoom.xos\n' > "$w/mic-pids"
  run_at 2000
  tail -n 1 "$w/notes.log" | grep -q 'fm-call-companion.sh start --mic --everyone-agreed' || fail 'reminder does not name the microphone start'
  printf 'yes\n' > "$w/recording"
  run_at 2100
  : > "$w/mic-pids"
  run_at 2200
  [ "$(count stop)" -eq 0 ] || fail 'the recording stopped before the call had been gone 180 seconds'
  run_at 2280
  [ "$(count stop)" -eq 1 ] && [ "$(count reset)" -eq 1 ] || fail "ended call was not stopped and archived: $(cat "$w/lifecycle.log")"
  ! grep -q '^start' "$w/lifecycle.log" || fail 'the watcher started a recording'

  # A running recording is never reminded about, and a failed probe keeps a microphone call open.
  printf '%s\n' '601 /Applications/Arc.app/Contents/Frameworks/ArcCore.framework/Helpers/Browser Helper.app/Contents/MacOS/Browser Helper --type=utility' > "$w/ps"
  printf '601\tcompany.thebrowser.browser.helper\n' > "$w/mic-pids"
  before=$(notes)
  run_at 3000
  [ "$(notes)" -eq "$before" ] || fail 'a call already being recorded raised a reminder'
  [ "$(jq -r .mic_pid "$w/state/call-watch.json")" = 601 ] || fail 'browser helper process was not tracked'
  printf '%s\n' '#!/usr/bin/env bash' 'exit 1' > "$w/broken-helper"; chmod +x "$w/broken-helper"
  CALL_WATCH_NOW_EPOCH=3500 CALL_COMPANION_STATE_DIR="$w/state" CALL_WATCH_PAGES_FILE="$w/pages" CALL_WATCH_PS_FILE="$w/ps" \
    CALL_WATCH_MIC_HELPER="$w/broken-helper" CALL_WATCH_MIC_HELPER_SOURCE=/nonexistent CALL_WATCH_COMPANION="$w/companion" \
    CALL_WATCH_NOTIFY_BIN="$w/notify" FIXTURE_LOG="$w/lifecycle.log" FIXTURE_NOTES="$w/notes.log" FIXTURE_RECORDING="$w/recording" \
    "$ROOT/bin/fm-call-watch.sh" --once 2>/dev/null
  [ "$(count stop)" -eq 1 ] && [ "$(jq -r .active "$w/state/call-watch.json")" = true ] || fail 'a failed probe cut a live call'

  # Our own recorder holding the microphone is not a call.
  : > "$w/recording"
  : > "$w/mic-pids"; run_at 4000
  printf '%s\n' '801 /opt/homebrew/bin/ffmpeg -f avfoundation -i :1' > "$w/ps"
  printf '801\t\n' > "$w/mic-pids"
  before=$(notes)
  run_at 5000
  [ "$(notes)" -eq "$before" ] && [ "$(jq -r .active "$w/state/call-watch.json")" = false ] || fail 'the recorder itself counted as a call'

  out=$(FM_HOME="$TMP_ROOT/watch-home" "$ROOT/bin/fm-call-watch.sh" render)
  assert_contains "$out" '<string>--once</string>' 'the LaunchAgent does not poll once per run'
  assert_contains "$out" '<integer>20</integer>' 'the LaunchAgent is not on a 20 second cadence'
  assert_contains "$out" '<key>PATH</key>' 'the LaunchAgent carries no PATH for Homebrew tools'
  assert_contains "$out" "$TMP_ROOT/watch-home/state/calls/watch/launchd.stderr.log" 'the LaunchAgent logs outside the home'
  unset -f run_at count notes
  pass 'the watcher reminds once, never starts, stops an ended recording, and holds a call on a failed probe'
}

test_mic_pipeline_overlap_and_cleanup() {
  local home bin duty pipeline_pid capture_child whisper_child stopped_at elapsed
  home=$(new_home pipeline)
  bin="$TMP_ROOT/pipeline-bin"
  install_fake_audio_tools "$bin"
  export FFMPEG_LOG="$TMP_ROOT/pipeline-ffmpeg.log" WHISPER_LOG="$TMP_ROOT/pipeline-whisper.log"
  FM_HOME="$home" FFMPEG_BIN="$bin/ffmpeg" WHISPER_BIN="$bin/whisper-cli" WHISPER_MODEL="$bin/model.bin" \
    MIC_CHUNK_SECONDS=2 MIC_CHUNK_OVERLAP_SECONDS=1 MIC_MAX_CHUNKS=3 \
    "$ROOT/bin/fm-call-mic.sh" 2> "$TMP_ROOT/pipeline.stderr" || fail "pipeline failed: $(cat "$TMP_ROOT/pipeline.stderr")"
  [ "$(grep -c '^capture-start' "$FFMPEG_LOG")" -eq 3 ] || fail 'three chunks were not captured'
  [ "$(grep -c '^whisper-start' "$WHISPER_LOG")" -eq 3 ] || fail 'three chunks were not transcribed'
  grep -q -- '-i :4' "$FFMPEG_LOG" || fail 'the microphone was not captured'
  grep -q -- '-i :7' "$FFMPEG_LOG" || fail 'the loopback was not captured'
  grep -q 'amix=inputs=2' "$FFMPEG_LOG" || fail 'tracks were not mixed'
  grep -q 'alimiter=limit=0.891' "$FFMPEG_LOG" || fail 'tracks were not limited'
  [ "$(wc -l < "$home/data/calls/transcript.txt" | tr -d ' ')" -eq 3 ] || fail 'transcript lines missing'
  [ -z "$(find "$home/state/calls/audio" -type f 2>/dev/null)" ] || fail "chunk audio outlived its transcript: $(find "$home/state/calls/audio" -type f)"
  duty=$("$PY" - "$FFMPEG_LOG" "$WHISPER_LOG" <<'PYEOF'
import sys
captures = {}
for line in open(sys.argv[1], encoding="utf-8"):
    if line.startswith(("capture-start", "capture-end")):
        kind, pid, stamp = line.rstrip().split("\t", 2)
        captures.setdefault(pid, {})[kind] = float(stamp)
intervals = sorted((row["capture-start"], row["capture-end"]) for row in captures.values())
merged = []
for start, end in intervals:
    if not merged or start > merged[-1][1]:
        merged.append([start, end])
    else:
        merged[-1][1] = max(merged[-1][1], end)
duty = sum(end - start for start, end in merged) / (intervals[-1][1] - intervals[0][0])
first_whisper = min(float(line.split("\t")[2]) for line in open(sys.argv[2], encoding="utf-8") if line.startswith("whisper-start"))
assert duty >= 0.90, duty
assert first_whisper < intervals[-1][1], "transcription waited for the last capture"
print(f"{duty * 100:.1f}")
PYEOF
) || fail 'chunks did not overlap into continuous capture'

  : > "$FFMPEG_LOG"; : > "$WHISPER_LOG"
  WHISPER_SLEEP=30 FM_HOME="$home" FFMPEG_BIN="$bin/ffmpeg" WHISPER_BIN="$bin/whisper-cli" WHISPER_MODEL="$bin/model.bin" \
    MIC_CHUNK_SECONDS=2 MIC_CHUNK_OVERLAP_SECONDS=1 \
    "$ROOT/bin/fm-call-mic.sh" > /dev/null 2> "$TMP_ROOT/signal.stderr" &
  pipeline_pid=$!
  fm_test_track_pid "$pipeline_pid"
  for _ in $(seq 1 80); do
    [ -s "$WHISPER_LOG" ] && [ "$(grep -c '^capture-start' "$FFMPEG_LOG")" -ge 2 ] && break
    sleep 0.1
  done
  [ -s "$WHISPER_LOG" ] || fail 'no transcription started before the signal'
  capture_child=$(awk -F '\t' '/^capture-start/{pid=$2} END{print pid}' "$FFMPEG_LOG")
  whisper_child=$(awk -F '\t' '/^whisper-start/{print $2; exit}' "$WHISPER_LOG")
  stopped_at=$("$PY" -c 'import time; print(time.time())')
  kill -TERM "$pipeline_pid"
  wait "$pipeline_pid" 2>/dev/null || true
  elapsed=$("$PY" -c "import time; print(time.time() - $stopped_at)")
  ! kill -0 "$capture_child" 2>/dev/null || fail 'capture outlived the stop'
  ! kill -0 "$whisper_child" 2>/dev/null || fail 'transcription outlived the stop'
  "$PY" -c "assert float('$elapsed') < 2.0, '$elapsed'" || fail "stop took ${elapsed}s"
  [ -z "$(find "$home/state/calls/audio" -name '*.wav' 2>/dev/null)" ] || fail 'a stop left chunk audio behind'
  pass "microphone pipeline keeps ${duty}% capture, cleans up on stop, and deletes chunk audio"
}

test_live_desk_grounding() {
  local home bin now
  home=$(new_home desk)
  bin="$TMP_ROOT/desk-bin"
  mkdir -p "$bin" "$home/data/calls"
  now=$(date '+%H:%M:%S')
  printf 'digest_model = haiku\nspeaker_name = Alex\n' > "$home/config/call-companion"
  cat > "$bin/claude" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
printf 'cwd=%s args=%s\n' "$PWD" "$*" >> "${FIXTURE_ARGS:?}"
prompt=$(cat)
ts=${FIXTURE_TS:?}
if [[ "$prompt" == *"Firstmate, build that"* ]]; then
  printf '```json\n{"where_we_are":"The rollout shape is agreed [%s]","decisions":[{"text":"Pilot with five customers","verbatim_quote":"Let’s pilot with five customers.","speaker":"Mara","time":"[%s]"},{"text":"Pricing tiers were confirmed","verbatim_quote":"The prices are just first ideas.","speaker":"Mara","time":"[%s]"}],"next_steps":[{"text":"Draft the refined pilot checklist","owner":"Alex","when":"Friday","source_quote":"Alex will draft the checklist by Friday.","time":"[%s]"}],"open_questions":[{"text":"What is the pilot success threshold?","why_now":"Mara could answer before launch","time":"[%s]"}],"triggered_actions":[{"instruction":"Build the pilot dashboard","decision_context":"The five-customer pilot was approved","verbatim_quote":"Firstmate, build that pilot dashboard.","speaker":"Alex","time":"[%s]"}]}\n```\n' "$ts" "$ts" "$ts" "$ts" "$ts" "$ts"
else
  printf '```json\n{"where_we_are":"The group is shaping a pilot [%s]","decisions":[{"text":"Pilot with five customers","verbatim_quote":"Let’s pilot with five customers.","speaker":"Mara","time":"[%s]"},{"text":"Pricing tiers were confirmed","verbatim_quote":"The prices are just first ideas.","speaker":"Mara","time":"[%s]"}],"next_steps":[{"text":"Draft the pilot checklist","owner":"Alex","when":"Friday","source_quote":"Alex will draft the checklist by Friday.","time":"[%s]"}],"open_questions":[{"text":"What defines pilot success?","why_now":"The pilot scope is set but its outcome is not","time":"[%s]"}],"triggered_actions":[]}\n```\n' "$ts" "$ts" "$ts" "$ts" "$ts"
fi
EOF
  chmod +x "$bin/claude"
  {
    printf '# 2026-10-18 13:00:00 CEST recording started (mic) after everyone on the call agreed to be recorded\n'
    printf "[%s] Mara: Let's pilot with five customers.\n" "$now"
    printf '[%s] Mara: The prices are just first ideas.\n' "$now"
    printf '[%s] Alex: Alex will draft the checklist by Friday.\n' "$now"
  } > "$home/data/calls/transcript.txt"
  run_digest() {
    FM_HOME="$home" FIXTURE_TS="$now" FIXTURE_ARGS="$TMP_ROOT/desk-claude.args" CALL_COMPANION_CLAUDE_BIN="$bin/claude" \
      "$ROOT/bin/fm-call-digest.sh" --once 2>> "$TMP_ROOT/desk.stderr"
  }
  run_digest || fail "digest failed: $(cat "$TMP_ROOT/desk.stderr")"
  printf '[%s] Alex: Firstmate, build that pilot dashboard.\n' "$now" >> "$home/data/calls/transcript.txt"
  run_digest; run_digest
  local digest="$home/data/calls/digest.json" state="$home/state/calls"
  jq -e '(.decisions|length)==1 and (.next_steps|length)==1 and .next_steps[0].text=="Draft the refined pilot checklist" and (.triggered_actions|length)==1' "$digest" >/dev/null \
    || fail "digest did not keep exactly the grounded items: $(cat "$digest")"
  grep -q 'dropped unsupported or ungrounded decision: Pricing tiers were confirmed' "$TMP_ROOT/desk.stderr" || fail 'ungrounded decision was not dropped'
  grep -q -- '--model haiku' "$TMP_ROOT/desk-claude.args" || fail 'digest_model setting was not used'
  grep -q -- '--tools  --no-session-persistence' "$TMP_ROOT/desk-claude.args" || fail "the desk model was given tools: $(cat "$TMP_ROOT/desk-claude.args")"
  ! grep -q "cwd=$home\|cwd=$ROOT" "$TMP_ROOT/desk-claude.args" || fail 'the desk model ran inside a Starship directory, where its hooks fire'
  [ "$(wc -l < "$state/triggers.log" | tr -d ' ')" -eq 1 ] || fail 'spoken order was not recorded exactly once'
  [ "$(wc -l < "$state/decisions.log" | tr -d ' ')" -eq 1 ] || fail 'decision was not recorded exactly once'
  jq -se 'length == 3 and ([.[].id] | unique | length) == 3' "$state/live-items.jsonl" >/dev/null || fail 'live items were not recorded once each'
  printf '%s\t%s\n' '[12:00:00]' 'Started the rollout scout' > "$state/actions.log"
  run_digest
  grep -q 'Build the pilot dashboard' "$home/data/calls/desk.md" || fail 'spoken order missing from the desk'
  grep -q 'Started the rollout scout' "$home/data/calls/glance.html" || fail 'Firstmate action missing from the glance page'
  FM_HOME="$home" "$ROOT/bin/fm-call-digest.sh" --final-batch
  tail -n 1 "$state/decisions-batch.log" | grep -Eq '^flush\t\[[0-9]{2}:[0-9]{2}:[0-9]{2}\]\tfinal$' || fail 'final batch record missing'
  [ -z "$(find "$state/logs" -name 'digest-*' 2>/dev/null)" ] || fail 'a successful digest left call text in the logs'
  unset -f run_digest
  pass 'the live desk keeps grounded items, records each once, and uses the configured model'
}

test_speaker_labels_and_final_notes() {
  local d labels expected
  d="$TMP_ROOT/notes"
  mkdir -p "$d"
  # Alex alone 0.5-4.5 s and 11-15 s; the far side 5.5-10 s (leaking into the
  # microphone 35 dB down, as from laptop speakers); both at 21-25 s; silence after.
  "$PY" - "$d" <<'PYEOF'
import math, random, struct, sys, wave
rate = 16000
def write(path, samples):
    with wave.open(path, "wb") as handle:
        handle.setnchannels(1); handle.setsampwidth(2); handle.setframerate(rate)
        handle.writeframes(b"".join(struct.pack("<h", max(-32768, min(32767, int(round(v * 32767))))) for v in samples))
def on(t, spans):
    return any(a <= t <= b for a, b in spans)
random.seed(7)
n = rate * 30
loop = [0.3 * math.sin(2 * math.pi * 220 * i / rate) if on(i / rate, [(5.5, 10), (21, 25)]) else 0.0 for i in range(n)]
mic = [(0.03 * math.sin(2 * math.pi * 330 * i / rate) if on(i / rate, [(0.5, 4.5), (11, 15), (21, 25)]) else 0.0) + loop[i] * 10 ** (-35 / 20) + random.gauss(0, 0.0003) for i in range(n)]
write(sys.argv[1] + "/loop.wav", loop)
write(sys.argv[1] + "/mic.wav", mic)
PYEOF
  cat > "$d/mix.json" <<'EOF'
{"transcription":[
 {"offsets":{"from":500,"to":4500},"text":" We ship the studio first."},
 {"offsets":{"from":5500,"to":10000},"text":" The staging link comes on Tuesday."},
 {"offsets":{"from":11000,"to":15000},"text":" I will write the tasks tonight."},
 {"offsets":{"from":21000,"to":25000},"text":" Both talking at once."},
 {"offsets":{"from":26000,"to":29500},"text":" Thank you."}
]}
EOF
  labels=$("$PY" "$ROOT/bin/fm-call-speaker-split.py" --whisper "$d/mix.json" --mic "$d/mic.wav" --loop "$d/loop.wav" --start 13:00:00 --local-name Alex 2> "$d/split.err")
  expected='[13:00:00] Alex: We ship the studio first.
[13:00:05] others: The staging link comes on Tuesday.
[13:00:11] Alex: I will write the tasks tonight.
[13:00:21] unknown speaker: Both talking at once.'
  [ "$labels" = "$expected" ] || fail "unexpected labels: $labels"
  grep -q 'dropped 1 segment' "$d/split.err" || fail 'speech invented over silence was kept'
  "$PY" "$ROOT/bin/fm-call-speaker-split.py" --whisper "$d/mix.json" --mic "$d/mic.wav" --loop "$d/loop.wav" --start 13:00:00 --local-name Alex --shared-room 2>/dev/null \
    | grep -q ' Alex: ' && fail 'a shared room still named the local speaker'
  "$PY" "$ROOT/bin/fm-call-speaker-split.py" --whisper "$d/mix.json" --mic "$d/mic.wav" --start 13:00:00 2>/dev/null \
    | grep -v ' unknown speaker: ' | grep -q . && fail 'microphone-only audio was attributed to a person'

  printf '%s\n' "$labels" '[13:00:30] Alex: We ship the studio first and then we will see.' > "$d/transcript.txt"
  cat > "$d/live-items.jsonl" <<'EOF'
{"id":"D-130000-aaaa","kind":"decision","text":"Ship the studio first.","verbatim_quote":"We ship the studio first.","speaker":"Alex","time":"[13:00:00]"}
{"id":"S-130005-bbbb","kind":"next_step","text":"Send the staging link on Monday.","owner":"Unassigned","when":"Monday","source_quote":"The staging link comes on Tuesday.","time":"[13:00:05]"}
{"id":"Q-130021-cccc","kind":"open_question","text":"Who was talking?","why_now":"","time":"[13:00:21]"}
EOF
  cat > "$d/response.json" <<'EOF'
{"summary":"The call settled the build order and the timing of the staging link.","items":[
 {"id":"D-130000-aaaa","kind":"decision","status":"confirmed","text":"Build the studio surface before anything else.","speaker":"Alex","owner":"","when":"","time":"[13:00:00]","evidence_quote":"We ship the studio first.","reason":"","merged_into":""},
 {"id":"S-130005-bbbb","kind":"next_step","status":"revised","text":"The far side sends the staging link.","speaker":"others","owner":"Unassigned","when":"Tuesday","time":"[13:00:05]","evidence_quote":"The staging link comes on Tuesday.","reason":"The day was Tuesday, not Monday.","merged_into":""},
 {"id":"NEW","kind":"next_step","status":"new","text":"Alex writes up the tasks the same evening.","speaker":"Alex","owner":"Alex","when":"tonight","time":"[13:00:11]","evidence_quote":"I will write the tasks tonight.","reason":"","merged_into":""},
 {"id":"NEW","kind":"decision","status":"new","text":"Hire a designer.","speaker":"Alex","owner":"","when":"","time":"[13:00:11]","evidence_quote":"We hire a designer.","reason":"","merged_into":""},
 {"id":"NEW","kind":"open_question","status":"new","text":"We ship the studio first and then we will see.","speaker":"Alex","owner":"","when":"","time":"[13:00:00]","evidence_quote":"We ship the studio first.","reason":"","merged_into":""}
]}
EOF
  "$PY" "$ROOT/bin/fm-call-final-notes.py" --transcript "$d/transcript.txt" --live-items "$d/live-items.jsonl" --out-dir "$d/out" \
    --date 2026-10-18 --local-name Alex --response "$d/response.json" 2> "$d/notes.err" || fail "notes failed: $(cat "$d/notes.err")"
  jq -e '[.items[] | select(.id=="Q-130021-cccc" and .status=="not reviewed")] | length == 1' "$d/out/notes.json" >/dev/null || fail 'a skipped live item vanished'
  jq -e '[.items[] | select(.id=="S-130005-bbbb" and .status=="revised" and .when=="Tuesday")] | length == 1' "$d/out/notes.json" >/dev/null || fail 'a revision was lost'
  jq -e '[.items[] | select(.status=="new" and (.id|test("^S-130011-[0-9a-f]{4}$")) and .checked=="evidence verified")] | length == 1' "$d/out/notes.json" >/dev/null || fail 'a new item was not re-grounded'
  jq -e '.rejected | length == 1 and .[0].problem == "evidence not found on the cited line"' "$d/out/notes.json" >/dev/null || fail 'an ungrounded new item was kept'
  jq -e '[.items[] | select(.text|startswith("(Wording withheld"))] | length == 1' "$d/out/notes.json" >/dev/null || fail 'copied wording was not withheld'
  ! grep -q 'We ship the studio first\|staging link comes on Tuesday\|write the tasks tonight' "$d/out/notes.md" "$d/out/notes.html" || fail 'the notes quote the call'
  grep -q "^- \*\*Alex\*\*: speech heard only on this Mac's microphone" "$d/out/notes.md" || fail 'the local speaker legend is missing'
  pass 'speech is labelled by its track, and the notes keep every live item, re-ground new ones, and quote nobody'
}

test_delete_current_archived_and_all() {
  local home out rc
  home=$(new_home delete)
  mkdir -p "$home/data/calls/archive" "$home/state/calls/logs"
  printf '[10:00:00] Alex: first call\n' > "$home/data/calls/archive/20261017-100000-transcript.txt"
  printf '{}\n' > "$home/data/calls/archive/20261017-100000-digest.json"
  printf '[11:00:00] Alex: second call\n' > "$home/data/calls/archive/20261017-110000-transcript.txt"
  printf '[12:00:00] Alex: current call\n' > "$home/data/calls/transcript.txt"
  printf 'notes\n' > "$home/data/calls/notes.md"
  printf '{}\n' > "$home/state/calls/live-items.jsonl"
  printf 'current call text\n' > "$home/state/calls/logs/digest-raw.abc123"
  printf '[12:00:00]\tdo it\n' > "$home/state/calls/triggers.log"
  out=$(FM_HOME="$home" "$ROOT/bin/fm-call-companion.sh" list)
  [ "$out" = "20261017-100000
20261017-110000" ] || fail "list did not print the archived stamps: $out"
  FM_HOME="$home" "$ROOT/bin/fm-call-companion.sh" delete >/dev/null || fail 'delete of the current call failed'
  [ ! -e "$home/data/calls/transcript.txt" ] && [ ! -e "$home/data/calls/notes.md" ] && [ ! -e "$home/state/calls/live-items.jsonl" ] \
    || fail 'the current call survived delete'
  [ -z "$(find "$home/state/calls/logs" -type f)" ] || fail 'call text survived in the logs'
  [ -e "$home/data/calls/archive/20261017-100000-transcript.txt" ] || fail 'delete of the current call touched the archive'
  FM_HOME="$home" "$ROOT/bin/fm-call-companion.sh" delete 20261017-100000 >/dev/null || fail 'delete of an archived call failed'
  [ -z "$(find "$home/data/calls/archive" -name '20261017-100000-*')" ] || fail 'the archived call survived'
  [ -e "$home/data/calls/archive/20261017-110000-transcript.txt" ] || fail 'another archived call was deleted'
  out=$(FM_HOME="$home" "$ROOT/bin/fm-call-companion.sh" delete 20261017-100000 2>&1) && rc=0 || rc=$?
  [ "$rc" -ne 0 ] || fail 'deleting a missing call reported success'
  out=$(FM_HOME="$home" "$ROOT/bin/fm-call-companion.sh" delete '../x' 2>&1) && rc=0 || rc=$?
  expect_code 2 "$rc" 'a malformed stamp was accepted'
  FM_HOME="$home" "$ROOT/bin/fm-call-companion.sh" delete --all >/dev/null || fail 'delete --all failed'
  [ ! -e "$home/data/calls" ] && [ ! -e "$home/state/calls/triggers.log" ] || fail 'delete --all left a call behind'
  pass 'delete removes the current call, one archived call, or every call'

}

test_second_screen_uses_configured_host() {
  local home bin hypr
  home=$(new_home display)
  bin="$TMP_ROOT/display-bin"
  hypr="$TMP_ROOT/display-hypr"
  mkdir -p "$bin" "$hypr/test-signature"
  printf 'display_host = deskbox\ndisplay_url = https://desk.example.test/glance.html\n' > "$home/config/call-companion"
  cat > "$bin/ssh" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
while [ "$#" -gt 0 ]; do
  case "$1" in -o) shift 2;; deskbox) shift; break;; *) printf 'unexpected ssh host: %s\n' "$1" >&2; exit 9;; esac
done
if [ "${1:-}" = true ]; then exit 0; fi
if [ "${1:-}" = 'bash -s' ]; then
  cat > /dev/null
  [ "${FIXTURE_LID_STATE:-closed}" = open ]
  exit
fi
FIRSTMATE_HYPR_DIR=${FIXTURE_HYPR_DIR:?} PATH=${FIXTURE_BIN:?}:$PATH bash -c "$1"
EOF
  cat > "$bin/hyprctl" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
printf '%s\n' "$*" >> "${HYPR_LOG:?}"
if [ "$*" = 'clients -j' ]; then
  printf '[{"initialClass":"chrome-desk.example.test__glance.html-Default","address":"0xd35c","fullscreen":0},{"initialClass":"chrome-example.test__page-Default","address":"0x71e0","fullscreen":0}]\n'
elif [ "$*" = 'activeworkspace -j' ]; then
  printf '{"id":7}\n'
fi
EOF
  chmod +x "$bin/ssh" "$bin/hyprctl"
  run() {
    FM_HOME="$home" CALL_COMPANION_FINAL_NOTES=0 CALL_COMPANION_SSH_BIN="$bin/ssh" CALL_COMPANION_OPEN_BIN=true \
      FIXTURE_BIN="$bin" FIXTURE_HYPR_DIR="$hypr" HYPR_LOG="$TMP_ROOT/hypr.log" "$ROOT/bin/fm-call-companion.sh" "$@"
  }
  FIXTURE_LID_STATE=closed run desk --display >/dev/null
  [ ! -s "$TMP_ROOT/hypr.log" ] || fail 'a closed lid still drove the screen'
  grep -q 'lid closed or display unavailable' "$home/state/calls/display-note" || fail 'the closed lid was not noted on the desk'
  FIXTURE_LID_STATE=open run desk --display >/dev/null
  FIXTURE_LID_STATE=open run show-display 'https://example.test/page?a=1'
  FIXTURE_LID_STATE=open run hide-display
  FIXTURE_LID_STATE=open run stop >/dev/null
  grep -Fq 'dispatch hl.dsp.exec_cmd("chromium --app=https://desk.example.test/glance.html")' "$TMP_ROOT/hypr.log" || fail 'the desk url was not opened'
  grep -Fq 'dispatch hl.dsp.window.fullscreen({window="address:0xd35c"})' "$TMP_ROOT/hypr.log" || fail 'the desk was not made full screen'
  grep -Fq 'dispatch hl.dsp.window.close({window="address:0x71e0"})' "$TMP_ROOT/hypr.log" || fail 'the other page was not closed'
  grep -Fq 'dispatch hl.dsp.window.close({window="address:0xd35c"})' "$TMP_ROOT/hypr.log" || fail 'stop did not close the desk'
  [ ! -e "$home/state/calls/display-desk-address" ] && [ ! -e "$home/state/calls/display-view-address" ] || fail 'window records outlived their windows'
  unset -f run
  pass 'the second screen is driven only through the configured host, and a closed lid is skipped'
}

test_consent_gate_and_settings
test_start_stop_records_agreement_in_home
test_watch_reminds_and_stops_but_never_starts
test_mic_pipeline_overlap_and_cleanup
test_live_desk_grounding
test_speaker_labels_and_final_notes
test_delete_current_archived_and_all
test_second_screen_uses_configured_host
