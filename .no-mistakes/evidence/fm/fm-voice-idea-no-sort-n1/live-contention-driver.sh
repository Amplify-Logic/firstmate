#!/usr/bin/env bash
# drive.sh <label> <script>: one scratch world, real Artevo import + real whisper.cpp,
# a long unsorted recording already in the Artevo Inbox, then a glasses idea arrives.
set -u
LABEL=$1 IDEA=$2
ART=$HOME/starship/projects/artevo-workspace
W=$(mktemp -d /tmp/fmvi-live/world-$LABEL.XXXX)
export HOME_REAL=$HOME
export FM_HOME="$W/home" TARTEVO_INBOX="$W/inbox" TARTEVO_CAREER_ROOT="$W/career"
export FM_VOICE_IDEA_TARTEVO="$ART/bin/tartevo" FM_VOICE_IDEA_ANSWER="$W/answer" FM_VOICE_IDEA_ANNOUNCE="$W/announce"
unset FM_VOICE_IDEA_IMPORT_TIMEOUT DEEPGRAM_API_KEY ELEVENLABS_API_KEY OPENAI_API_KEY
export PYTHONDONTWRITEBYTECODE=1 FAKE_LOG="$W/spoken.log"
mkdir -p "$FM_HOME/data/glasses-voice-runtime" "$TARTEVO_INBOX" "$TARTEVO_CAREER_ROOT"
DB="$FM_HOME/data/glasses-voice-runtime/mailbox.db"; echo tok > "$FM_HOME/data/glasses-voice-runtime/relay-token"; : > "$FAKE_LOG"
cat > "$W/answer" <<'AP'
#!/usr/bin/env python3
import json, os, sqlite3, sys
rid, text, db = sys.argv[1], sys.argv[3], sys.argv[5]
open(os.environ["FAKE_LOG"], "a").write(f"answer\t{rid}\t{text}\n")
c = sqlite3.connect(db)
if c.execute("SELECT state FROM requests WHERE request_id=?", (rid,)).fetchone()[0] == "answered":
    print("already answered", file=sys.stderr); sys.exit(1)
c.execute("UPDATE requests SET state='answered', answer_json=? WHERE request_id=?", (json.dumps({"text": text}), rid)); c.commit()
AP
printf '#!/usr/bin/env bash\nprintf "announce\\t%%s\\n" "$1" >> "$FAKE_LOG"\n' > "$W/announce"
chmod +x "$W/answer" "$W/announce"
python3 - "$DB" <<'PY'
import sqlite3, sys
db = sqlite3.connect(sys.argv[1])
db.execute("""CREATE TABLE requests (request_id TEXT PRIMARY KEY, question_json TEXT NOT NULL, created_at TEXT NOT NULL,
 state TEXT NOT NULL DEFAULT 'pending', claim_token TEXT, claimed_by TEXT, lease_until REAL, answer_json TEXT,
 answered_at TEXT, transcript_cache TEXT)"""); db.commit()
PY
PYTHONPATH="$ART" python3 - <<'PY'
import os
from pathlib import Path
from core.store import Store
with Store(Path(os.environ["TARTEVO_CAREER_ROOT"])) as store:
    store.upsert("work", {"title": "What a Life", "slug": "what-a-life", "form": "song", "stage": "recording", "source": "manual"})
PY
"$FM_VOICE_IDEA_TARTEVO" captures songs-json >/dev/null
# A long phone memo on no song ("Not sure"), waiting to be heard and sorted.
cp /tmp/fmvi-live/long.wav "$TARTEVO_INBOX/Walk memo - 2026-09-27 101500.wav"
echo '{"song": "Not sure", "how": "picked"}' > "$TARTEVO_INBOX/Walk memo - 2026-09-27 101500.artevo.json"
# The glasses idea.
python3 - "$DB" <<'PY'
import base64, json, math, sqlite3, struct, sys, wave, io
buf = io.BytesIO(); w = wave.open(buf, "wb"); w.setnchannels(1); w.setsampwidth(2); w.setframerate(16000)
w.writeframes(b"".join(struct.pack("<h", int(6000*math.sin(i/7))) for i in range(16000))); w.close()
rid = "11111111-1111-4111-8111-111111111111"
q = {"contract_version": "1.0", "kind": "voice-question", "request_id": rid, "created_at": "2026-09-27T10:20:00Z",
     "transcript": "What a Life, bridge idea",
     "audio": {"media_type": "audio/wav", "filename": "capture.wav", "data_base64": base64.b64encode(buf.getvalue()).decode()}}
c = sqlite3.connect(sys.argv[1]); c.execute("INSERT INTO requests (request_id, question_json, created_at) VALUES (?,?,?)", (rid, json.dumps(q), q["created_at"])); c.commit()
PY
echo "== $LABEL: $IDEA"
for n in 1 2; do
  s=$(date +%s)
  out=$("$IDEA" check 2>&1); rc=$?
  echo "-- check $n: rc=$rc elapsed=$(( $(date +%s) - s ))s"
  [ -n "$out" ] && printf '   check output: %s\n' "$out"
done
echo "-- spoken to the glasses:"; sed 's/^/   /' "$FAKE_LOG"
echo "-- status:"; "$IDEA" status | sed 's/^/   /'
echo "-- real Artevo store captures:"
python3 - "$TARTEVO_CAREER_ROOT/store.sqlite" <<'PY'
import sqlite3, sys
c = sqlite3.connect(sys.argv[1])
cols = [r[1] for r in c.execute("PRAGMA table_info(captures)")]
want = [x for x in ("source_path", "filing", "transcript_status", "state") if x in cols]
for row in c.execute(f"SELECT {', '.join(want)} FROM captures"):
    print("   " + " | ".join(str(v).split('/')[-1] if v else str(v) for v in row))
PY
echo "world: $W"
