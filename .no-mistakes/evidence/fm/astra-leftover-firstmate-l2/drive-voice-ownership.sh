#!/usr/bin/env bash
# Crash-state drive: a by-hash marker names ID1 but captures/ID1 was never
# published (crash between ownership write and publication). A second request
# with the same bytes then runs through the real CLI.
set -u
IDEA_BIN=$1; LABEL=$2
fm_test_tmproot() { mktemp -d "${TMPDIR:-/tmp}/$1.XXXXXX"; }
. "$(dirname "$0")/voice-fixture-world.sh"
export PYTHONDONTWRITEBYTECODE=1
ID1=11111111-1111-4111-8111-111111111111
ID2=22222222-2222-4222-8222-222222222222
make_world; make_wav "$W/audio/hum.wav" 92
add_question "$ID1" "What a Life bridge idea" "$W/audio/hum.wav"
add_question "$ID2" "What a Life bridge idea" "$W/audio/hum.wav"
spool="$FM_HOME/data/voice-ideas"
digest=$(shasum -a 256 "$W/audio/hum.wav" | cut -d' ' -f1)
mkdir -p "$spool/by-hash"; chmod 700 "$spool" "$spool/by-hash"
printf '%s\n' "$ID1" > "$spool/by-hash/$digest"
echo "[$LABEL] crashed state: by-hash marker -> $(cat "$spool/by-hash/$digest"); captures/$ID1 exists? $([ -d "$spool/captures/$ID1" ] && echo yes || echo no)"
"$IDEA_BIN" take "$ID2"; echo "take ID2 exit=$?"
"$IDEA_BIN" status --json | python3 -c 'import json,sys
for r in json.load(sys.stdin): print("  status", r["capture_id"], r.get("state"), "duplicate_of=%s" % r.get("duplicate_of"))'
echo "  answers spoken: $(cut -f2 "$W/log/answers.log" | tr '\n' '|')"
echo "  marker now -> $(cat "$spool/by-hash/$digest")"
"$IDEA_BIN" take "$ID1"; echo "take ID1 exit=$?"
"$IDEA_BIN" status --json | python3 -c 'import json,sys
for r in json.load(sys.stdin): print("  status", r["capture_id"], r.get("state"), "duplicate_of=%s" % r.get("duplicate_of"))'
echo "  Artevo captures imported: $(fake_capture_count 2>/dev/null || echo 0)"
