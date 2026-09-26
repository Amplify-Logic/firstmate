#!/usr/bin/env bash
# Live journey 1 against the real product pieces, all in throwaway dirs:
# a marked lab FM_HOME, the real glasses relay mailbox + answer + announce CLIs,
# the real Artevo importer against a temp career root and temp inbox, and the
# watcher check written by `fm-voice-idea.py arm`, run as the watcher would.
set -u
WT=/Users/larsmusic/.no-mistakes/worktrees/f569cc43ac96/01M3F3PKGYA2HHHJGJ2BWXPWQW
IDEA=$WT/bin/fm-voice-idea.py
A=/Users/larsmusic/starship/projects/artevo-workspace
GV=/Users/larsmusic/starship/projects/glasses-voice
T=$(mktemp -d "${TMPDIR:-/tmp}/fmvi-live.XXXXXX")
LAB="$T/lab"
"$WT/bin/fm-lab-home.sh" create "$LAB" >/dev/null || exit 1
export FM_HOME="$LAB" HOME="$T/userhome" PYTHONDONTWRITEBYTECODE=1
export TARTEVO_INBOX="$HOME/Artevo Inbox" TARTEVO_CAREER_ROOT="$T/career"
unset TARTEVO_ROOT TARTEVO_RUNTIME DEEPGRAM_API_KEY ELEVENLABS_API_KEY OPENAI_API_KEY GLASSES_TTS_ENGINE GLASSES_VOICE_RUNTIME GLASSES_VOICE_DB
mkdir -p "$HOME" "$TARTEVO_INBOX" "$TARTEVO_CAREER_ROOT" "$LAB/data/glasses-voice-runtime" "$T/bin" "$T/audio"
DB="$LAB/data/glasses-voice-runtime/mailbox.db"
printf 'lab-token\n' > "$LAB/data/glasses-voice-runtime/relay-token"
GVPATH="$GV/relay:$GV/mac-agent:$GV/harness"
printf '#!/usr/bin/env bash\nPYTHONPATH=%q exec python3 -m glasses_voice_cli.answer "$@"\n' "$GVPATH" > "$T/bin/answer"
printf '#!/usr/bin/env bash\nexec %q "$@"\n' "$A/bin/tartevo" > "$T/bin/tartevo"
chmod +x "$T/bin/answer" "$T/bin/tartevo"
export FM_VOICE_IDEA_ANSWER="$T/bin/answer" FM_VOICE_IDEA_ANNOUNCE="$GV/bin/announce" FM_VOICE_IDEA_TARTEVO="$T/bin/tartevo"

say() { printf '\n### %s\n' "$*"; }
wav() { python3 - "$1" "$2" <<'PY'
import math, struct, sys, wave
w = wave.open(sys.argv[1], "wb"); w.setnchannels(1); w.setsampwidth(2); w.setframerate(16000)
s = int(sys.argv[2]); w.writeframes(b"".join(struct.pack("<h", int(6000*math.sin(i/(5+s)))) for i in range(8000))); w.close()
PY
}
# VoiceLoop's POST, through the real relay mailbox backend.
send() { GLASSES_RELAY_TOKEN=lab-token PYTHONPATH="$GVPATH" python3 - "$DB" "$@" <<'PY'
import base64, sys
from relay import AuthContext, LocalMailboxBackend, VoiceQuestion
db, rid, words, audio = sys.argv[1:5]
q = {"contract_version": "1.0", "kind": "voice-question", "request_id": rid,
     "created_at": "2026-09-26T11:00:00Z", "transcript": words}
if audio != "none":
    q["audio"] = {"media_type": "audio/wav", "filename": "capture.wav",
                  "data_base64": base64.b64encode(open(audio, "rb").read()).decode()}
r = LocalMailboxBackend("lab-token", db).submit_question(VoiceQuestion.from_dict(q), AuthContext("lab-token"))
print("  relay accepted", rid, "->", getattr(r, "state", r))
PY
}
glasses() { python3 - "$DB" <<'PY'
import json, sqlite3, sys
db = sqlite3.connect(sys.argv[1])
for rid, state, ans in db.execute("SELECT request_id, state, answer_json FROM requests ORDER BY created_at, request_id"):
    print(f"  answer  {rid[:8]} {state:9} {json.loads(ans)['text'] if ans else '-'}")
try:
    for (raw,) in db.execute("SELECT announcement_json FROM announcements ORDER BY rowid"):
        print(f"  announce {json.loads(raw)['text']}")
except sqlite3.Error:
    pass
PY
}
sweep() {  # the watcher runs a copy of the check with its own environment
  cp "$LAB/state/fm-glasses-idea.check.sh" "$T/snap.check.sh"
  local out; out=$(cd / && env -u FM_HOME -u TARTEVO_INBOX -u TARTEVO_CAREER_ROOT -u FM_VOICE_IDEA_ANSWER -u FM_VOICE_IDEA_ANNOUNCE -u FM_VOICE_IDEA_TARTEVO bash "$T/snap.check.sh" 2>&1); echo "  check rc=$? stdout=[${out}]"
}

say "Artevo: a temp career root with the songs 'What a Life' and 'Hey! Do You Remember?'"
PYTHONPATH="$A" python3 - <<'PY'
import os
from pathlib import Path
from core.store import Store
with Store(Path(os.environ["TARTEVO_CAREER_ROOT"])) as s:
    s.upsert("work", {"title": "What a Life", "slug": "what-a-life", "form": "song", "stage": "recording", "source": "manual"})
    s.upsert("work", {"title": "Hey! Do You Remember?", "slug": "hey-do-you-remember", "form": "song", "stage": "recording", "source": "manual"})
PY
"$T/bin/tartevo" captures songs-json
# Seed the glasses mailbox schema with a throwaway request, answered away.
GLASSES_RELAY_TOKEN=lab-token PYTHONPATH="$GVPATH" python3 -c "
from relay import LocalMailboxBackend; LocalMailboxBackend('lab-token', '$DB')" 2>/dev/null || true

say "arm the watcher check in the lab home"
"$IDEA" arm; ls "$LAB/state" | grep idea

R1=a1111111-1111-4111-8111-111111111111; R2=a2222222-2222-4222-8222-222222222222
R3=a3333333-3333-4333-8333-333333333333; R4=a4444444-4444-4444-8444-444444444444
R5=a5555555-5555-4555-8555-555555555555
wav "$T/audio/hum.wav" 3; wav "$T/audio/hey.wav" 9

say "Scenario A: desk away (Artevo's command unavailable). Captain says 'What a Life, bridge idea' and hums"
chmod -x "$T/bin/tartevo"
send "$R1" "What a Life, bridge idea" "$T/audio/hum.wav"
send "$R3" "What's on this week?" none
send "$R4" "What a Life, any ideas what to do next?" none
sweep; glasses
"$IDEA" status

say "Scenario B: VoiceLoop re-sends the same request while the desk is still away"
send "$R1" "What a Life, bridge idea" "$T/audio/hum.wav" 2>&1 | tail -1
sweep; glasses

say "Scenario C: the desk is back"
chmod +x "$T/bin/tartevo"
sweep; glasses
"$IDEA" status

say "Artevo's view: captures filed to What a Life, and the audio in the career root"
"$T/bin/tartevo" captures list what-a-life
asset=$(find "$TARTEVO_CAREER_ROOT" -path '*captures/audio/*.wav' | head -1)
echo "  asset: ${asset#$T/}"; cmp "$asset" "$T/audio/hum.wav" && echo "  asset bytes == the hum captured on the glasses"
"$T/bin/tartevo" captures transcripts 2>&1 | head -5

say "Scenario D: the same hum sent again under a new request id"
send "$R2" "What a Life, bridge idea" "$T/audio/hum.wav"
sweep; glasses
echo "  Artevo captures in store: $(python3 -c "import sqlite3;print(sqlite3.connect('$TARTEVO_CAREER_ROOT/store.sqlite').execute('select count(*), group_concat(filing) from captures').fetchone())")"
echo "  wav files in inbox: $(find "$TARTEVO_INBOX" -maxdepth 1 -name '*.wav' | wc -l | tr -d ' ')"

say "Scenario E (adversarial): 'Hey! Do You Remember?' idea while the desk is away; the real announce refuses the receipt"
chmod -x "$T/bin/tartevo"
send "$R5" "Hey do you remember, hook idea" "$T/audio/hey.wav"
sweep
chmod +x "$T/bin/tartevo"
sweep; glasses
"$IDEA" status
"$IDEA" status --json | python3 -c 'import json,sys; [print("  spoken=", r["spoken"], r["song"]) for r in json.load(sys.stdin)]'
cat "$LAB/data/voice-ideas/captures/$R5/said-final" 2>/dev/null | sed 's/^/  said-final: /'
sweep

say "disarm keeps the ideas"
"$IDEA" disarm; ls "$LAB/state" | grep -c idea; ls "$LAB/data/voice-ideas/captures" | wc -l
rm -rf "$T"; echo "lab removed: $([ -e "$T" ] && echo no || echo yes)"
