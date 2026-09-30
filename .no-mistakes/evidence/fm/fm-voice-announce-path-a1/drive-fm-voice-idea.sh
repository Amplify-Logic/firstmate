#!/usr/bin/env bash
# Live: real bin/fm-voice-idea.py + real starship-voice/glasses-voice announce copies,
# found through the DEFAULT $FM_HOME/projects path (no FM_VOICE_IDEA_ANNOUNCE),
# against a disposable real mailbox (relay.LocalMailboxBackend), no speech keys.
LAB=/var/folders/1g/hctp3vpn27b1zrlsn4nsfg680000gn/T//fm-voice-lab.gfu6nF
. "$LAB/voice-idea-lib.sh"
ROOT=/Users/larsmusic/.no-mistakes/worktrees/f569cc43ac96/01M3T4T210EVTKQH1J3DZJSATS; IDEA="$ROOT/bin/fm-voice-idea.py"
scenario() {  # <label> <projects...>
  local label=$1; shift
  make_world
  rm -f "$DB" "$DB-wal" "$DB-shm"
  unset FM_VOICE_IDEA_ANNOUNCE
  mkdir -p "$FM_HOME/projects"
  for p in "$@"; do cp -R "$LAB/pristine/$p" "$FM_HOME/projects/$p"; done
  gv="$LAB/pristine/starship-voice"
  export FM_VOICE_IDEA_ANSWER="$W/fakes/real-answer"
  printf '#!/usr/bin/env bash\nPYTHONPATH=%q/relay:%q/mac-agent:%q/harness exec python3 -m glasses_voice_cli.answer "$@"\n' "$gv" "$gv" "$gv" > "$FM_VOICE_IDEA_ANSWER"
  chmod +x "$FM_VOICE_IDEA_ANSWER"
  make_wav "$W/audio/hum.wav" 15
  GLASSES_RELAY_TOKEN=fixture-token PYTHONPATH="$gv/relay:$gv/mac-agent:$gv/harness" python3 - "$DB" "$ID1" "$W/audio/hum.wav" <<'PY'
import base64, sys
from relay import AuthContext, LocalMailboxBackend, VoiceQuestion
db, rid, audio = sys.argv[1:4]
q = VoiceQuestion.from_dict({"contract_version": "1.0", "kind": "voice-question", "request_id": rid,
    "created_at": "2026-09-30T11:00:00Z", "transcript": "What a life, bridge idea",
    "audio": {"media_type": "audio/wav", "filename": "capture.wav",
              "data_base64": base64.b64encode(open(audio, "rb").read()).decode()}})
LocalMailboxBackend("fixture-token", db).submit_question(q, AuthContext("fixture-token"))
PY
  : > "$LAB/trace.log"
  echo "### $label"
  echo "\$ ls \$FM_HOME/projects -> $(ls "$FM_HOME/projects" | tr '\n' ' ')   (FM_VOICE_IDEA_ANNOUNCE unset)"
  export FAKE_TARTEVO_MODE=fail; run_check; echo "\$ fm-voice-idea.py check  (desk unreachable) -> rc=$CHECK_RC"
  unset FAKE_TARTEVO_MODE; run_check; echo "\$ fm-voice-idea.py check  (desk back)        -> rc=$CHECK_RC"
  echo "  real mailbox contents (answer, then announcements):"
  python3 - "$DB" <<'PY' | sed 's/^/    /'
import json, sqlite3, sys
db = sqlite3.connect(sys.argv[1])
print("answer:", json.loads(db.execute("SELECT answer_json FROM requests").fetchone()[0])["text"])
for (raw,) in db.execute("SELECT announcement_json FROM announcements"):
    print("announcement:", json.loads(raw)["text"])
PY
  echo "  announce clone(s) that ran: $(cut -d' ' -f1 "$LAB/trace.log" | sort -u | tr '\n' ' ')"
  echo
}
scenario "glasses-voice retired: only starship-voice cloned" starship-voice
scenario "both clones present -> starship-voice preferred" starship-voice glasses-voice
scenario "only the retiring glasses-voice clone -> fallback" glasses-voice
