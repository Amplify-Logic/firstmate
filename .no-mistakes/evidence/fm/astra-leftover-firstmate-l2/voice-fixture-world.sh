make_world() {
  local tmp
  tmp=$(fm_test_tmproot fm-voice-idea)
  W=$tmp
  export HOME="$tmp/userhome"
  export FM_HOME="$tmp/home"
  mkdir -p "$HOME" "$FM_HOME/state" "$FM_HOME/data/glasses-voice-runtime" "$tmp/fakes" "$tmp/log" "$tmp/audio"
  export TARTEVO_INBOX="$HOME/Artevo Inbox"
  export TARTEVO_CAREER_ROOT="$tmp/career"
  mkdir -p "$TARTEVO_INBOX" "$TARTEVO_CAREER_ROOT"
  DB="$FM_HOME/data/glasses-voice-runtime/mailbox.db"
  printf 'fixture-token\n' > "$FM_HOME/data/glasses-voice-runtime/relay-token"
  export FAKE_LOG_DIR="$tmp/log"
  export FM_VOICE_IDEA_ANSWER="$tmp/fakes/answer"
  export FM_VOICE_IDEA_ANNOUNCE="$tmp/fakes/announce"
  export FM_VOICE_IDEA_TARTEVO="$tmp/fakes/tartevo"
  unset FAKE_TARTEVO_MODE FAKE_ANNOUNCE_RC FAKE_ANSWER_FAIL FAKE_ANNOUNCE_MODE
  unset FM_VOICE_IDEA_SPEAK_TIMEOUT
  : > "$tmp/log/answers.log"
  : > "$tmp/log/announces.log"
  : > "$tmp/log/imports.log"

  python3 - "$DB" <<'PY'
import sqlite3, sys
db = sqlite3.connect(sys.argv[1])
db.execute("PRAGMA journal_mode=WAL")
db.execute("""CREATE TABLE requests (
    request_id TEXT PRIMARY KEY, question_json TEXT NOT NULL, created_at TEXT NOT NULL,
    state TEXT NOT NULL DEFAULT 'pending', claim_token TEXT, claimed_by TEXT,
    lease_until REAL, answer_json TEXT, answered_at TEXT, transcript_cache TEXT)""")
db.commit()
PY

  # The glasses answer CLI: answers a pending request once, like the mailbox.
  cat > "$tmp/fakes/answer" <<'PY'
#!/usr/bin/env python3
import json, os, sqlite3, sys
rid, text, db = sys.argv[1], sys.argv[3], sys.argv[5]
if not os.environ.get("GLASSES_RELAY_TOKEN"):
    print("error: no token", file=sys.stderr); sys.exit(1)
with open(os.path.join(os.environ["FAKE_LOG_DIR"], "answers.log"), "a") as log:
    log.write(f"{rid}\t{text}\n")
if os.environ.get("FAKE_ANSWER_FAIL"):
    print("error: mailbox busy", file=sys.stderr); sys.exit(1)
conn = sqlite3.connect(db)
row = conn.execute("SELECT state FROM requests WHERE request_id=?", (rid,)).fetchone()
if row is None:
    print(f"error: unknown request {rid}", file=sys.stderr); sys.exit(1)
if row[0] == "answered":
    print(f"error: request {rid} is already answered", file=sys.stderr); sys.exit(1)
conn.execute("UPDATE requests SET state='answered', answer_json=? WHERE request_id=?",
             (json.dumps({"text": text}), rid))
conn.commit()
PY

  cat > "$tmp/fakes/announce" <<'SH'
#!/usr/bin/env bash
[ -n "${GLASSES_RELAY_TOKEN:-}" ] || { echo "announce: no token" >&2; exit 1; }
printf '%s\n' "$1" >> "$FAKE_LOG_DIR/announces.log"
case "${FAKE_ANNOUNCE_MODE:-}" in
  timeout) exec sleep 5 ;;
  killed) kill -KILL "$PPID"; exit 0 ;;
esac
[ "${FAKE_ANNOUNCE_RC:-0}" != 2 ] || echo "announce: refused: reads as a yes/no question" >&2
exit "${FAKE_ANNOUNCE_RC:-0}"
SH

  # Artevo's `captures import --json`: the real report shape, content-hash
  # dedupe, and filing by the sidecar's song against the fake catalogue.
  cat > "$tmp/fakes/tartevo" <<'PY'
#!/usr/bin/env python3
import hashlib, json, os, re, sys, time
from pathlib import Path
with open(os.path.join(os.environ["FAKE_LOG_DIR"], "imports.log"), "a") as log:
    log.write(" ".join(sys.argv[1:]) + "\n")
mode = os.environ.get("FAKE_TARTEVO_MODE", "")
if mode == "fail":
    print("Traceback: store is locked", file=sys.stderr); sys.exit(1)
args = sys.argv[1:]
if mode == "sort-waits" and "--no-sort" not in args:
    time.sleep(30)  # hearing a long recording already waiting to be sorted
assert args[:2] == ["captures", "import"], args
inbox = Path(args[args.index("--inbox") + 1])
root = Path(os.environ["TARTEVO_CAREER_ROOT"])
if mode == "error" or not inbox.is_dir():
    print(json.dumps({"inbox": str(inbox), "error": f"inbox not found: {inbox}", "items": []})); sys.exit(1)
store_path = root / "fake-store.json"
store = json.loads(store_path.read_text()) if store_path.exists() else {"captures": []}
catalogue = json.loads((root / "catalogue.json").read_text())
norm = lambda t: " ".join(re.sub(r"[^0-9a-z]+", " ", str(t or "").casefold()).split())
items = []
for path in sorted(inbox.iterdir()):
    if path.name.startswith(".") or path.suffix.lower() not in (".wav", ".m4a", ".mp3"):
        continue
    st = path.stat()
    item = {"path": path.name, "status": None, "detail": None}
    known = [c for c in store["captures"] if c["source_path"] == str(path) and c["size"] == st.st_size]
    digest = "sha256:" + hashlib.sha256(path.read_bytes()).hexdigest()
    same = [c for c in store["captures"] if c["hash"] == digest]
    if known:
        cap, item["status"] = known[0], "already_imported"
    elif same:
        cap, item["status"] = same[0], "duplicate"
    else:
        sidecar = path.with_name(path.stem + ".artevo.json")
        said = json.loads(sidecar.read_text()).get("song") if sidecar.exists() else None
        title = next((t for t in catalogue if norm(t) == norm(said)), None)
        cap = {"id": f"cpt_{len(store['captures']) + 1}", "hash": digest, "source_path": str(path),
               "size": st.st_size, "filing": "named" if title else "unfiled", "song_title": title}
        (root / "audio").mkdir(exist_ok=True)
        (root / "audio" / (digest.split(":")[1] + path.suffix)).write_bytes(path.read_bytes())
        store["captures"].append(cap)
        item["status"] = "imported"
    item.update(capture_id=cap["id"], content_hash=cap["hash"], filing=cap["filing"],
                song_title=cap["song_title"], suggested_song_title=None, asset_path=None)
    items.append(item)
store_path.write_text(json.dumps(store))
print(json.dumps({"inbox": str(inbox), "dry_run": False, "error": None, "items": items, "ignored": []}))
PY
  chmod +x "$tmp/fakes/answer" "$tmp/fakes/announce" "$tmp/fakes/tartevo"
  set_catalogue "What a Life" "Blue Hour"
  write_songs_json "What a Life" "Blue Hour"
}

# The fake importer's catalogue, which a test can let drift from songs.json.
set_catalogue() {
  python3 -c 'import json,sys; print(json.dumps(sys.argv[2:]))' _ "$@" > "$TARTEVO_CAREER_ROOT/catalogue.json"
}

# The songs.json Artevo keeps in the inbox (schema_version 1).
write_songs_json() {
  python3 - "$TARTEVO_INBOX/songs.json" "$@" <<'PY'
import json, re, sys
titles = sys.argv[2:]
songs = [{"id": f"wrk_{i}", "title": t, "slug": re.sub(r"[^a-z0-9]+", "-", t.lower()).strip("-"),
          "choice": t} for i, t in enumerate(titles)]
doc = {"schema_version": 1, "source": "artevo", "songs": songs,
       "choices": titles + ["New song…", "Not sure"],
       "ids_by_choice": {s["title"]: s["id"] for s in songs}}
open(sys.argv[1], "w").write(json.dumps(doc))
PY
}

# make_wav <path> <seed>: a short distinct WAV, the fixture recording.
make_wav() {
  python3 - "$1" "$2" <<'PY'
import math, struct, sys, wave
w = wave.open(sys.argv[1], "wb")
w.setnchannels(1); w.setsampwidth(2); w.setframerate(16000)
seed = int(sys.argv[2])
w.writeframes(b"".join(struct.pack("<h", int(6000 * math.sin(i / (5 + seed)))) for i in range(8000)))
w.close()
PY
}

# add_question <id> <transcript> [<audio file>|none] [<media type>] [<state>]
add_question() {
  python3 - "$DB" "$@" <<'PY'
import base64, json, sqlite3, sys
db, rid, transcript = sys.argv[1], sys.argv[2], sys.argv[3]
audio_path = sys.argv[4] if len(sys.argv) > 4 else "none"
media = sys.argv[5] if len(sys.argv) > 5 else "audio/wav"
state = sys.argv[6] if len(sys.argv) > 6 else "pending"
question = {"contract_version": "1.0", "kind": "voice-question", "request_id": rid,
            "created_at": "2026-09-26T10:15:30.250Z", "transcript": transcript or None}
if audio_path != "none":
    question["audio"] = {"media_type": media, "filename": "capture.wav",
                         "data_base64": base64.b64encode(open(audio_path, "rb").read()).decode()}
answer = json.dumps({"text": "Something else entirely."}) if state == "answered" else None
conn = sqlite3.connect(db)
conn.execute("INSERT INTO requests (request_id, question_json, created_at, state, answer_json) VALUES (?,?,?,?,?)",
             (rid, json.dumps(question), question["created_at"], state, answer))
conn.commit()
PY
}

question_state() {
  python3 -c 'import sqlite3,sys; print(sqlite3.connect(sys.argv[1]).execute("select state from requests where request_id=?", (sys.argv[2],)).fetchone()[0])' "$DB" "$1"
}

fake_capture_count() {
  python3 -c 'import json,sys; print(len(json.load(open(sys.argv[1]))["captures"]))' "$TARTEVO_CAREER_ROOT/fake-store.json"
}

inbox_audio_count() {
  find "$TARTEVO_INBOX" -maxdepth 1 -name '*.wav' ! -name '.*' | wc -l | tr -d ' '
}

run_check() {
  CHECK_OUT=$("$IDEA" check 2>"$W/log/check.err")
  CHECK_RC=$?
}

# ---------------------------------------------------------------------------
# Recognition: song name first, then the idea
