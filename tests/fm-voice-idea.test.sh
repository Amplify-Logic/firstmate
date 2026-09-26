#!/usr/bin/env bash
# tests/fm-voice-idea.test.sh - filing an idea spoken into the glasses on its
# Artevo song (bin/fm-voice-idea.py, docs/voice-ideas.md).
#
# Journey 1 of the Artevo build plan, firstmate side: "What a Life, bridge idea"
# and a hum reach the glasses mailbox, the idea is held under its capture id,
# handed to Artevo through the Artevo Inbox, and the glasses hear "Filed to What
# a Life" - or "Saved, waiting for the desk" first when Artevo cannot be reached.
# Sending it twice makes one capture.
#
# Every outside party is a fixture: the mailbox is a temp SQLite file with the
# glasses mailbox's own requests table, the answer and announce CLIs are fakes
# that log what would have been spoken, and Artevo's import is a fake with the
# real importer's report shape and content-hash dedupe. HOME, the Artevo Inbox
# and the career root all live under the test's temp root, so nothing here can
# reach the captain's real inbox, career root, mailbox or glasses.
#
# The real Artevo importer is exercised too when FM_TEST_ARTEVO_CHECKOUT names
# an Artevo checkout, against a temp career root, and the real glasses mailbox
# with its answer and announce CLIs when FM_TEST_GLASSES_CHECKOUT names a
# glasses-voice checkout, against a temp mailbox with no speech keys. Both
# checkouts are only read (bytecode writes are disabled); without them those
# cases report a skip.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

IDEA="$ROOT/bin/fm-voice-idea.py"
ARTEVO_CHECKOUT=${FM_TEST_ARTEVO_CHECKOUT:-}
unset TARTEVO_INBOX TARTEVO_CAREER_ROOT TARTEVO_ROOT TARTEVO_RUNTIME
unset FM_VOICE_IDEA_MAILBOX_DB FM_VOICE_IDEA_TOKEN_FILE FM_VOICE_IDEA_ANSWER
unset FM_VOICE_IDEA_ANNOUNCE FM_VOICE_IDEA_TARTEVO FM_VOICE_IDEA_IMPORT_TIMEOUT
unset FM_VOICE_IDEA_SPEAK_TIMEOUT FM_DATA_OVERRIDE FM_PROJECTS_OVERRIDE
# No speech provider key may reach a real glasses CLI from here: text only.
unset DEEPGRAM_API_KEY DEEPGRAM_API_KEY_FILE ELEVENLABS_API_KEY ELEVENLABS_API_KEY_FILE
unset OPENAI_API_KEY OPENAI_API_KEY_FILE GLASSES_TTS_ENGINE GLASSES_VOICE_RUNTIME GLASSES_VOICE_DB
export PYTHONDONTWRITEBYTECODE=1

ID1=11111111-1111-4111-8111-111111111111
ID2=22222222-2222-4222-8222-222222222222
ID3=33333333-3333-4333-8333-333333333333

# ---------------------------------------------------------------------------
# Fixture world
# ---------------------------------------------------------------------------
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
  unset FAKE_TARTEVO_MODE FAKE_ANNOUNCE_RC FAKE_ANSWER_FAIL
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
[ "${FAKE_ANNOUNCE_RC:-0}" != 2 ] || echo "announce: refused: reads as a yes/no question" >&2
exit "${FAKE_ANNOUNCE_RC:-0}"
SH

  # Artevo's `captures import --json`: the real report shape, content-hash
  # dedupe, and filing by the sidecar's song against the fake catalogue.
  cat > "$tmp/fakes/tartevo" <<'PY'
#!/usr/bin/env python3
import hashlib, json, os, re, sys
from pathlib import Path
with open(os.path.join(os.environ["FAKE_LOG_DIR"], "imports.log"), "a") as log:
    log.write(" ".join(sys.argv[1:]) + "\n")
mode = os.environ.get("FAKE_TARTEVO_MODE", "")
if mode == "fail":
    print("Traceback: store is locked", file=sys.stderr); sys.exit(1)
args = sys.argv[1:]
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
# ---------------------------------------------------------------------------
status_field() {
  "$IDEA" status --json | python3 -c 'import json,sys; rows={r["capture_id"]: r for r in json.load(sys.stdin)}; print(rows[sys.argv[1]][sys.argv[2]])' "$1" "$2"
}

test_recognises_song_first_then_the_idea() {
  local id
  make_world
  make_wav "$W/audio/one.wav" 20
  make_wav "$W/audio/two.wav" 21
  add_question "$ID1" "What a life bridge idea hmm hmm hmm" "$W/audio/one.wav"
  add_question "$ID2" "File this idea for Blue Hour, the chorus" "$W/audio/two.wav"
  add_question 44444444-4444-4444-8444-444444444444 "What a Life, any ideas what to do next?" none
  add_question 55555555-5555-4555-8555-555555555555 "What's on this week?" none
  add_question 66666666-6666-4666-8666-666666666666 "Idea for What a Life, the bridge" none
  add_question 77777777-7777-4777-8777-777777777777 "What a Life" none
  run_check
  assert_contains "$(cat "$W/log/answers.log")" "$ID1	Filed to What a Life." "song first then idea is taken and answered"
  assert_equals "What a Life" "$(status_field "$ID1" song)" "the catalogue title is the song"
  assert_equals "bridge idea hmm hmm hmm" "$(status_field "$ID1" note)" "the words after the song are the note"
  assert_contains "$(cat "$W/log/answers.log")" "$ID2	Filed to Blue Hour." "an explicit lead-in needs no idea word"
  for id in 44444444-4444-4444-8444-444444444444 55555555-5555-4555-8555-555555555555 \
            66666666-6666-4666-8666-666666666666 77777777-7777-4777-8777-777777777777; do
    assert_equals pending "$(question_state "$id")" "not an idea stays pending: $id"
    assert_absent "$FM_HOME/data/voice-ideas/captures/$id" "not an idea is not held: $id"
  done
  assert_equals 2 "$(wc -l < "$W/log/answers.log" | tr -d ' ')" "a question about a song, an ordinary question, a song name not first, and a bare song name are not answered"

  make_world
  make_wav "$W/audio/three.wav" 22
  set_catalogue "What a Life" "What a Life (Acoustic)"
  write_songs_json "What a Life" "What a Life (Acoustic)"
  add_question "$ID3" "What a life acoustic, verse idea" "$W/audio/three.wav"
  "$IDEA" take "$ID3" >/dev/null || fail "take files the longest title"
  assert_equals "$ID3	Filed to What a Life (Acoustic)." "$(cat "$W/log/answers.log")" "the longest leading title wins, as in Artevo"
  pass "recognises song name first, then the idea, and nothing else"
}

# ---------------------------------------------------------------------------
# Journey 1: filed, and the glasses hear the receipt
# ---------------------------------------------------------------------------
test_journey_files_the_idea_and_speaks_the_receipt() {
  local audio name
  make_world
  make_wav "$W/audio/hum.wav" 1
  add_question "$ID1" "What a life bridge idea mm mm mm" "$W/audio/hum.wav"
  run_check
  expect_code 0 "$CHECK_RC" "check exits 0"
  assert_equals "" "$CHECK_OUT" "a filed idea wakes nobody"
  assert_equals "$ID1	Filed to What a Life." "$(cat "$W/log/answers.log")" "the glasses hear Filed to What a Life, once"
  assert_equals "" "$(cat "$W/log/announces.log")" "nothing announced when the answer carried the receipt"
  assert_equals answered "$(question_state "$ID1")" "the question is answered"

  audio=$(find "$TARTEVO_INBOX" -maxdepth 1 -name 'What a Life - glasses idea - * - 11111111.wav')
  [ -n "$audio" ] || fail "the recording is in the Artevo Inbox under a name leading with the song"
  cmp -s "$audio" "$W/audio/hum.wav" || fail "the inbox copy is the recording's exact bytes"
  name=$(basename "$audio" .wav)
  assert_grep '"how": "named"' "$TARTEVO_INBOX/$name.artevo.json" "the sidecar gives the song as the captain's word"
  assert_grep '"song": "What a Life"' "$TARTEVO_INBOX/$name.artevo.json" "the sidecar names the song"
  assert_grep '"note": "bridge idea mm mm mm"' "$TARTEVO_INBOX/$name.artevo.json" "the sidecar carries his words"
  assert_equals 1 "$(fake_capture_count)" "one Artevo capture"
  assert_present "$FM_HOME/data/voice-ideas/captures/$ID1/audio.wav" "the capture is held under its capture id"
  assert_contains "$("$IDEA" status)" "What a Life  filed: Filed to What a Life." "status says filed"

  run_check
  assert_equals 1 "$(wc -l < "$W/log/answers.log" | tr -d ' ')" "a second sweep says nothing again"
  pass "journey 1: held under its capture id, filed through the Artevo Inbox, receipt spoken once"
}

test_an_ordinary_question_is_left_for_firstmate() {
  make_world
  make_wav "$W/audio/q.wav" 2
  add_question "$ID1" "What's on this week?" "$W/audio/q.wav"
  run_check
  assert_equals "" "$CHECK_OUT" "no wake for an ordinary question"
  assert_equals "" "$(cat "$W/log/answers.log")" "an ordinary question is not answered here"
  assert_equals pending "$(question_state "$ID1")" "it stays pending for firstmate"
  assert_absent "$FM_HOME/data/voice-ideas/captures/$ID1" "nothing is held"
  assert_equals "" "$(cat "$W/log/imports.log")" "Artevo is not touched"
  pass "an ordinary question is left pending for firstmate"
}

# ---------------------------------------------------------------------------
# The desk is unreachable: held, said so, filed later
# ---------------------------------------------------------------------------
test_unreachable_desk_holds_the_capture_and_files_it_later() {
  make_world
  make_wav "$W/audio/hum.wav" 3
  add_question "$ID1" "What a Life, bridge idea" "$W/audio/hum.wav"
  export FAKE_TARTEVO_MODE=fail
  run_check
  assert_equals "$ID1	Saved, waiting for the desk." "$(cat "$W/log/answers.log")" "the glasses hear it is saved and waiting"
  assert_contains "$CHECK_OUT" "glasses idea for What a Life is saved but waiting for the desk" "firstmate is told once"
  assert_contains "$CHECK_OUT" "gave no report" "with the reason"
  assert_present "$FM_HOME/data/voice-ideas/captures/$ID1/audio.wav" "the audio is held"

  run_check
  assert_equals "" "$CHECK_OUT" "a still-waiting capture does not wake again"
  assert_equals 1 "$(wc -l < "$W/log/answers.log" | tr -d ' ')" "the waiting line is said once"

  unset FAKE_TARTEVO_MODE
  run_check
  assert_equals "Filed to What a Life." "$(cat "$W/log/announces.log")" "the receipt reaches the glasses when the desk is back"
  assert_equals 1 "$(wc -l < "$W/log/answers.log" | tr -d ' ')" "the question is not answered twice"
  assert_equals 1 "$(fake_capture_count)" "one capture"
  run_check
  assert_equals 1 "$(wc -l < "$W/log/announces.log" | tr -d ' ')" "the receipt is said once"
  pass "an unreachable desk: saved and waiting, then filed and announced once"
}

test_a_missing_inbox_uses_the_last_song_list() {
  make_world
  make_wav "$W/audio/one.wav" 4
  make_wav "$W/audio/two.wav" 5
  add_question "$ID1" "Blue Hour hook idea" "$W/audio/one.wav"
  run_check
  assert_contains "$(cat "$W/log/answers.log")" "Filed to Blue Hour." "first idea filed while the inbox is here"

  mv "$TARTEVO_INBOX" "$W/inbox-away"
  add_question "$ID2" "What a Life, bridge idea" "$W/audio/two.wav"
  run_check
  assert_contains "$(tail -n 1 "$W/log/answers.log")" "Saved, waiting for the desk." "recognised from the kept song list"
  assert_contains "$CHECK_OUT" "the Artevo Inbox folder is not on this Mac" "the reason is plain"

  mv "$W/inbox-away" "$TARTEVO_INBOX"
  run_check
  assert_equals "Filed to What a Life." "$(cat "$W/log/announces.log")" "filed once the inbox is back"
  pass "a missing inbox still recognises the song from the kept list and files later"
}

# ---------------------------------------------------------------------------
# Sending it twice makes one capture
# ---------------------------------------------------------------------------
test_sending_it_twice_makes_one_capture() {
  make_world
  make_wav "$W/audio/hum.wav" 6
  add_question "$ID1" "What a Life bridge idea" "$W/audio/hum.wav"
  run_check
  run_check
  assert_equals 1 "$(wc -l < "$W/log/answers.log" | tr -d ' ')" "one request is answered once"

  # The same recording again under a new request id.
  add_question "$ID2" "What a Life bridge idea" "$W/audio/hum.wav"
  run_check
  assert_equals "$ID2	Already filed to What a Life." "$(tail -n 1 "$W/log/answers.log")" "a second send hears it is already filed"
  assert_equals 1 "$(inbox_audio_count)" "the second send is not handed over again"
  assert_equals 1 "$(fake_capture_count)" "one Artevo capture"
  assert_equals 1 "$(wc -l < "$W/log/imports.log" | tr -d ' ')" "Artevo's import ran once"
  assert_contains "$("$IDEA" status)" "duplicate: Already filed to What a Life." "status names the duplicate"
  pass "sending it twice makes one capture"
}

test_a_duplicate_while_the_first_waits_is_said_once() {
  make_world
  make_wav "$W/audio/hum.wav" 7
  export FAKE_TARTEVO_MODE=fail
  add_question "$ID1" "What a Life bridge idea" "$W/audio/hum.wav"
  add_question "$ID2" "What a Life bridge idea" "$W/audio/hum.wav"
  run_check
  assert_contains "$(cat "$W/log/answers.log")" "$ID2	Already saved, waiting for the desk." "the duplicate is told it is saved"
  unset FAKE_TARTEVO_MODE
  run_check
  assert_equals "Filed to What a Life." "$(cat "$W/log/announces.log")" "one receipt for both sends"
  assert_equals 1 "$(fake_capture_count)" "one Artevo capture"
  pass "a duplicate of a waiting capture produces one receipt"
}

# ---------------------------------------------------------------------------
# Honest states
# ---------------------------------------------------------------------------
test_honest_failures_are_spoken() {
  make_world
  add_question "$ID1" "What a Life, bridge idea" none
  run_check
  assert_equals "$ID1	I couldn't file that idea: no recording came with it." "$(cat "$W/log/answers.log")" "no recording is said plainly"
  assert_contains "$CHECK_OUT" "could not be filed" "firstmate is told"

  make_wav "$W/audio/hum.webm" 8
  add_question "$ID2" "Blue Hour chorus idea" "$W/audio/hum.webm" "audio/webm"
  run_check
  assert_contains "$(tail -n 1 "$W/log/answers.log")" "Artevo can't take that recording format" "an unsupported format is said plainly"
  assert_equals "" "$(cat "$W/log/imports.log")" "nothing unfileable is handed to Artevo"

  # Artevo no longer has the song (renamed since the song list was written).
  make_wav "$W/audio/three.wav" 9
  set_catalogue "Blue Hour"
  add_question "$ID3" "What a Life verse idea" "$W/audio/three.wav"
  run_check
  assert_contains "$(tail -n 1 "$W/log/answers.log")" "Saved in Artevo, but not filed to What a Life." "Artevo's own verdict is what is said"
  pass "no recording, a format Artevo cannot take, and an unfiled capture are each said plainly"
}

test_a_question_answered_elsewhere_gets_the_receipt_announced() {
  local out rc
  make_world
  make_wav "$W/audio/hum.wav" 10
  add_question "$ID1" "" "$W/audio/hum.wav" audio/wav answered
  out=$("$IDEA" take "$ID1" --song "what a life"); rc=$?
  expect_code 0 "$rc" "take with the song the caller heard"
  assert_contains "$out" "filed: What a Life: Filed to What a Life." "take reports the receipt"
  assert_equals "" "$(cat "$W/log/answers.log")" "an answered question is not answered again"
  assert_equals "Filed to What a Life." "$(cat "$W/log/announces.log")" "the receipt is announced instead"
  pass "a question already answered gets its receipt as an announcement"
}

test_a_refused_receipt_wakes_firstmate_and_is_not_marked_spoken() {
  local err
  make_world
  make_wav "$W/audio/hum.wav" 16
  add_question "$ID1" "What a Life bridge idea" "$W/audio/hum.wav" audio/wav answered
  export FAKE_ANNOUNCE_RC=2
  err=$("$IDEA" take "$ID1" 2>&1 >/dev/null) || fail "take files the idea"
  assert_equals "Filed to What a Life." "$(cat "$W/log/announces.log")" "the receipt was offered to the glasses"
  assert_contains "$err" "receipt for What a Life could not be spoken: announce: refused" "firstmate is told the receipt was refused"
  assert_contains "$("$IDEA" status)" "filed: Filed to What a Life. (receipt not spoken yet)" "status does not call a refused receipt spoken"
  assert_equals False "$(status_field "$ID1" spoken)" "nor does status --json"
  run_check
  assert_equals "" "$CHECK_OUT" "told once"
  assert_equals 1 "$(wc -l < "$W/log/announces.log" | tr -d ' ')" "a refusal is not offered again"
  unset FAKE_ANNOUNCE_RC
  pass "a refused receipt wakes firstmate once and status says it was not spoken"
}

test_take_refuses_words_that_are_not_an_idea() {
  local rc
  make_world
  make_wav "$W/audio/q.wav" 11
  add_question "$ID1" "What's on this week?" "$W/audio/q.wav"
  "$IDEA" take "$ID1" >/dev/null 2>&1; rc=$?
  expect_code 3 "$rc" "not an idea"
  assert_absent "$FM_HOME/data/voice-ideas/captures/$ID1" "nothing held"
  "$IDEA" take "not-an-id" >/dev/null 2>&1; rc=$?
  expect_code 1 "$rc" "a malformed id is refused"
  pass "take refuses words that are not an idea and ids that are not request ids"
}

test_an_unspoken_receipt_is_retried_and_reported_once() {
  make_world
  make_wav "$W/audio/hum.wav" 12
  add_question "$ID1" "What a Life bridge idea" "$W/audio/hum.wav"
  export FAKE_ANSWER_FAIL=1
  run_check
  assert_contains "$CHECK_OUT" "receipt for What a Life could not be spoken" "firstmate is told the receipt did not land"
  run_check
  assert_equals "" "$CHECK_OUT" "told once"
  unset FAKE_ANSWER_FAIL
  run_check
  assert_equals answered "$(question_state "$ID1")" "the receipt lands when the mailbox answers again"
  assert_equals "Filed to What a Life." "$(tail -n 1 "$W/log/answers.log" | cut -f2)" "and it is the receipt"
  assert_equals 1 "$(fake_capture_count)" "retrying the answer does not re-import"
  pass "an answer that fails is retried and reported once"
}

# ---------------------------------------------------------------------------
# The watcher check
# ---------------------------------------------------------------------------
test_arm_registers_a_check_the_watcher_can_run() {
  local shim rc first
  make_world
  "$IDEA" arm >/dev/null || fail "arm succeeds"
  shim="$FM_HOME/state/fm-glasses-idea.check.sh"
  assert_present "$shim" "the check is written"
  assert_present "$FM_HOME/state/fm-glasses-idea.check-trust" "and bound"
  assert_equals 700 "$(python3 -c 'import os,stat,sys; print(format(stat.S_IMODE(os.stat(sys.argv[1]).st_mode), "o"))' "$shim")" "the check is mode 700"
  # The watcher walks state/*.check.sh in glob order and stops at the first
  # line printed, so this check must come before the generic glasses check.
  : > "$FM_HOME/state/fm-glasses-wake-wiring-w2.check.sh"
  first=$(cd "$FM_HOME/state" && for c in *.check.sh; do printf '%s\n' "$c"; break; done)
  rm -f "$FM_HOME/state/fm-glasses-wake-wiring-w2.check.sh"
  assert_equals fm-glasses-idea.check.sh "$first" "the idea check runs before the generic glasses check"

  make_wav "$W/audio/hum.wav" 13
  add_question "$ID1" "What a Life bridge idea" "$W/audio/hum.wav"
  # The watcher runs a copy from a snapshot with its own environment.
  (cd / && env -u TARTEVO_INBOX -u FM_HOME bash "$shim" >/dev/null 2>&1); rc=$?
  expect_code 0 "$rc" "the shim runs"
  assert_equals "$ID1	Filed to What a Life." "$(cat "$W/log/answers.log")" "the armed check files the idea with the baked settings"

  "$IDEA" disarm >/dev/null || fail "disarm succeeds"
  assert_absent "$shim" "the check is retired"
  assert_absent "$FM_HOME/state/fm-glasses-idea.check-trust" "with its binding"
  assert_present "$FM_HOME/data/voice-ideas/captures/$ID1" "held ideas are kept"
  pass "arm registers a check the watcher can run; disarm retires it and keeps the ideas"
}

# ---------------------------------------------------------------------------
# The real Artevo importer, when an Artevo checkout is named
# ---------------------------------------------------------------------------
test_real_artevo_import_files_once() {
  local count
  if [ -z "$ARTEVO_CHECKOUT" ] || [ ! -x "$ARTEVO_CHECKOUT/bin/tartevo" ]; then
    printf 'ok - # SKIP real Artevo importer (set FM_TEST_ARTEVO_CHECKOUT to an Artevo checkout)\n'
    return 0
  fi
  make_world
  export FM_VOICE_IDEA_TARTEVO="$ARTEVO_CHECKOUT/bin/tartevo"
  rm -f "$TARTEVO_INBOX/songs.json" "$TARTEVO_CAREER_ROOT/catalogue.json"
  PYTHONPATH="$ARTEVO_CHECKOUT" python3 - <<'PY' || fail "a temp career root with one song"
import os
from pathlib import Path
from core.store import Store
with Store(Path(os.environ["TARTEVO_CAREER_ROOT"])) as store:
    store.upsert("work", {"title": "What a Life", "slug": "what-a-life", "form": "song",
                          "stage": "recording", "source": "manual"})
PY
  "$FM_VOICE_IDEA_TARTEVO" captures songs-json >/dev/null || fail "Artevo writes songs.json"

  make_wav "$W/audio/hum.wav" 14
  add_question "$ID1" "What a life, bridge idea" "$W/audio/hum.wav"
  run_check
  assert_equals "$ID1	Filed to What a Life." "$(cat "$W/log/answers.log")" "the real import files it on the song"
  add_question "$ID2" "What a life, bridge idea" "$W/audio/hum.wav"
  run_check
  assert_equals "$ID2	Already filed to What a Life." "$(tail -n 1 "$W/log/answers.log")" "a second send"
  count=$(python3 - "$TARTEVO_CAREER_ROOT/store.sqlite" <<'PY'
import sqlite3, sys
rows = sqlite3.connect(sys.argv[1]).execute("SELECT filing FROM captures").fetchall()
print(",".join(row[0] for row in rows))
PY
)
  assert_equals named "$count" "one capture, filed as named, in the real store"
  pass "the real Artevo importer files the idea as named, once"
}

# ---------------------------------------------------------------------------
# The real glasses mailbox and its answer and announce CLIs, when named
# ---------------------------------------------------------------------------
test_real_glasses_mailbox_hears_waiting_then_filed() {
  local gv lines
  gv=${FM_TEST_GLASSES_CHECKOUT:-}
  if [ -z "$gv" ] || [ ! -x "$gv/bin/announce" ]; then
    printf 'ok - # SKIP real glasses mailbox (set FM_TEST_GLASSES_CHECKOUT to a glasses-voice checkout)\n'
    return 0
  fi
  make_world
  rm -f "$DB" "$DB-wal" "$DB-shm"
  export FM_VOICE_IDEA_ANNOUNCE="$gv/bin/announce"
  export FM_VOICE_IDEA_ANSWER="$W/fakes/real-answer"
  printf '#!/usr/bin/env bash\nPYTHONPATH=%q/relay:%q/mac-agent:%q/harness exec python3 -m glasses_voice_cli.answer "$@"\n' \
    "$gv" "$gv" "$gv" > "$FM_VOICE_IDEA_ANSWER"
  chmod +x "$FM_VOICE_IDEA_ANSWER"
  make_wav "$W/audio/hum.wav" 15
  GLASSES_RELAY_TOKEN=fixture-token PYTHONPATH="$gv/relay:$gv/mac-agent:$gv/harness" \
    python3 - "$DB" "$ID1" "$W/audio/hum.wav" <<'PY' || fail "the real mailbox takes the question"
import base64, sys
from relay import AuthContext, LocalMailboxBackend, VoiceQuestion
db, rid, audio = sys.argv[1:4]
question = VoiceQuestion.from_dict({
    "contract_version": "1.0", "kind": "voice-question", "request_id": rid,
    "created_at": "2026-09-26T11:00:00Z", "transcript": "What a life, bridge idea",
    "audio": {"media_type": "audio/wav", "filename": "capture.wav",
              "data_base64": base64.b64encode(open(audio, "rb").read()).decode()}})
LocalMailboxBackend("fixture-token", db).submit_question(question, AuthContext("fixture-token"))
PY
  export FAKE_TARTEVO_MODE=fail
  run_check
  unset FAKE_TARTEVO_MODE
  run_check
  lines=$(python3 - "$DB" <<'PY'
import json, sqlite3, sys
db = sqlite3.connect(sys.argv[1])
print(json.loads(db.execute("SELECT answer_json FROM requests").fetchone()[0])["text"])
for (raw,) in db.execute("SELECT announcement_json FROM announcements"):
    print(json.loads(raw)["text"])
PY
)
  assert_equals "Saved, waiting for the desk."$'\n'"Filed to What a Life." "$lines" "the real mailbox carries the waiting answer, then the receipt"
  pass "the real glasses mailbox hears saved and waiting, then filed"
}

test_recognises_song_first_then_the_idea
test_journey_files_the_idea_and_speaks_the_receipt
test_an_ordinary_question_is_left_for_firstmate
test_unreachable_desk_holds_the_capture_and_files_it_later
test_a_missing_inbox_uses_the_last_song_list
test_sending_it_twice_makes_one_capture
test_a_duplicate_while_the_first_waits_is_said_once
test_honest_failures_are_spoken
test_a_question_answered_elsewhere_gets_the_receipt_announced
test_a_refused_receipt_wakes_firstmate_and_is_not_marked_spoken
test_take_refuses_words_that_are_not_an_idea
test_an_unspoken_receipt_is_retried_and_reported_once
test_arm_registers_a_check_the_watcher_can_run
test_real_artevo_import_files_once
test_real_glasses_mailbox_hears_waiting_then_filed
