#!/usr/bin/env bash
# Behavior tests for bin/fm-meetings.sh, the meeting layer over Anarlog.
#
# Every case drives the real entry point against a scratch home and a fake
# `anarlog` command that serves invented meetings from fixture files and logs
# every call, so no case reads a real meeting, records audio, or opens an app.
# The intake model, the inbox and the desk speaker are fakes that record what
# they were handed. Time is pinned through FM_MEETINGS_NOW.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

SUBJECT="$ROOT/bin/fm-meetings.sh"
TMP_ROOT=$(fm_test_tmproot fm-meetings)
FAKES="$TMP_ROOT/fakes"
NOW=1793000000
mkdir -p "$FAKES"

# The fake Anarlog CLI. Fixtures live in $FAKE_ANARLOG_DIR:
#   list.json                 the `meetings list` data array
#   meetings/<id>.json        one meeting as `meetings export --format json` returns it,
#                             plus optional processing_status and recording_import
#   meetings/<id>.md          the Markdown export
#   jobs/<job>.json           an import job's status (absent: still transcribing)
#   import-fails              when present, every import is refused
#   list-fails                when present, every list call fails
# Every call is appended to calls.log; imports also to imports.jsonl.
cat > "$FAKES/anarlog" <<'PY'
#!/usr/bin/env python3
import hashlib, json, os, sys
base = os.environ["FAKE_ANARLOG_DIR"]
args = sys.argv[1:]
with open(os.path.join(base, "calls.log"), "a") as log:
    log.write(" ".join(args) + "\n")
as_json = "--json" in args
args = [a for a in args if a != "--json"]
def out(command, data):
    print(json.dumps({"schema_version": "1", "command": command, "data": data}))
def fail(message):
    print(json.dumps({"error": {"code": "invalid", "exit_code": 1, "message": message}, "schema_version": "1"}, indent=2))
    sys.exit(1)
def meeting(mid):
    path = os.path.join(base, "meetings", mid + ".json")
    if not os.path.exists(path):
        fail("meeting not found")
    with open(path) as handle:
        return json.load(handle)
if args[0] == "doctor":
    out("doctor", {"ready": True, "database": {"path": os.path.join(base, "app.db")}})
    sys.exit(0)
assert args[0] == "meetings" and args[1:3] == ["--source", "local"], args
verb, rest = args[3], args[4:]
if verb == "list":
    if os.path.exists(os.path.join(base, "list-fails")):
        fail("database is locked")
    with open(os.path.join(base, "list.json")) as handle:
        items = json.load(handle)
    if "--query" in rest:
        query = rest[rest.index("--query") + 1].lower()
        items = [i for i in items if query in i["title"].lower()]
    out("meetings.list", items)
elif verb == "get":
    data = meeting(rest[0])
    for key in ("transcripts", "attachments", "capture_pending", "speakers"):
        data.pop(key, None)
    data.setdefault("processing_status", None)
    data.setdefault("recording_import", None)
    out("meetings.get", data)
elif verb == "export":
    data = meeting(rest[0])
    if rest[rest.index("--format") + 1] == "markdown":
        with open(os.path.join(base, "meetings", rest[0] + ".md")) as handle:
            sys.stdout.write(handle.read())
    else:
        data.pop("processing_status", None)
        data.pop("recording_import", None)
        out("meetings.export", data)
elif verb == "import":
    if os.path.exists(os.path.join(base, "import-fails")):
        fail("Open the updated Anarlog desktop app before importing recordings")
    key = rest[rest.index("--request-key") + 1]
    tag = hashlib.sha1(key.encode()).hexdigest()[:8]
    record = {"file": rest[0], "title": rest[rest.index("--title") + 1], "request_key": key,
              "folder": rest[rest.index("--folder") + 1] if "--folder" in rest else ""}
    with open(os.path.join(base, "imports.jsonl"), "a") as log:
        log.write(json.dumps(record) + "\n")
    out("meetings.import", {"job_id": "job-" + tag, "meeting_id": "imp-" + tag,
                            "processing_status": "queued", "summary_status": "pending", "error": None})
elif verb == "import-status":
    path = os.path.join(base, "jobs", rest[0] + ".json")
    status = {"processing_status": "transcribing", "error": None}
    if os.path.exists(path):
        with open(path) as handle:
            status = json.load(handle)
    out("meetings.import_status", dict({"job_id": rest[0], "meeting_id": "", "summary_status": "pending"}, **status))
else:
    fail("unexpected command " + verb)
PY

# The fake intake model: saves the prompt and answers with $FAKE_MODEL_OUTPUT.
cat > "$FAKES/claude" <<'SH'
#!/usr/bin/env bash
cat > "$FAKE_MODEL_DIR/prompt.$(date +%s%N 2>/dev/null || date +%s).txt"
printf 'called\n' >> "$FAKE_MODEL_DIR/calls"
printf '{"type":"result","structured_output":%s}\n' "$(cat "$FAKE_MODEL_OUTPUT")"
SH

# The fake inbox records each note's request id and body.
cat > "$FAKES/inbox" <<'SH'
#!/usr/bin/env bash
[ "$1" = note ] && [ "$2" = --request-id ] && [ "$4" = - ] || { echo "bad inbox call: $*" >&2; exit 2; }
mkdir -p "$FAKE_INBOX_DIR"
if [ -e "$FAKE_INBOX_DIR/$3" ]; then echo "replay $3"; exit 0; fi
cat > "$FAKE_INBOX_DIR/$3"
echo "queued $3"
SH

# The fake desk speaker records each spoken line, and reports itself off when
# a <spoken>.off marker exists.
cat > "$FAKES/speak" <<'SH'
#!/usr/bin/env bash
if [ "$1" = --enabled ]; then
  if [ -e "$FAKE_SPOKEN.off" ]; then echo disabled; else echo enabled; fi
  exit 0
fi
printf '%s\n' "$*" >> "$FAKE_SPOKEN"
SH
chmod +x "$FAKES/anarlog" "$FAKES/claude" "$FAKES/inbox" "$FAKES/speak"

# fixture.py writes invented meetings with timestamps relative to NOW.
cat > "$FAKES/fixture.py" <<'PY'
import datetime, json, os, sys
base, now = sys.argv[1], int(sys.argv[2])
def iso(offset):
    return datetime.datetime.fromtimestamp(now + offset, datetime.timezone.utc).strftime("%Y-%m-%dT%H:%M:%S.000Z")
spec = json.loads(sys.argv[3])
os.makedirs(os.path.join(base, "meetings"), exist_ok=True)
mid = spec["id"]
ended = spec.get("ended", -900)
meeting = {
    "id": mid, "title": spec.get("title", "Garden planning"), "kind": "meeting", "status": "active",
    "created_at": iso(ended - 1800), "updated_at": iso(spec.get("updated", ended)),
    "started_at": iso(ended - 1800), "ended_at": "" if spec.get("unfinished") else iso(ended),
    "timezone": "", "language": "", "series_id": "", "folder_path": None,
    "note": {"id": mid, "kind": "note", "title": "", "markdown": spec.get("note", "Talk about the garden shed."),
             "template_id": "", "sort_order": 0, "created_at": iso(ended - 1800), "updated_at": iso(ended)},
    "summaries": [] if spec.get("no_summary") else [{"id": "s-" + mid, "kind": "summary", "title": "Summary",
        "markdown": spec.get("summary", "Robin and the captain agreed to compare shed kits."),
        "template_id": "", "sort_order": 0, "created_at": iso(ended), "updated_at": iso(ended)}],
    "participants": spec.get("participants", [{"human_id": "self", "display_name": "Captain", "email": ""}]),
    "action_items": [{"text": t, "status": "open"} for t in spec.get("action_items", [])],
    "transcripts": [{"id": "t-" + mid, "source": spec.get("source", "live"), "provider": "soniqo",
                     "model": spec.get("model", "soniqo-parakeet-streaming"), "language": spec.get("language", "en"),
                     "started_at_ms": 0, "ended_at_ms": None, "memo": "", "text": "", "words": [], "speaker_hints": []}]
                   if not spec.get("no_transcript") else [],
    "speakers": [{"human_id": "self", "name": "Captain", "is_self": True}],
    "attachments": spec.get("attachments", []),
    "capture_pending": spec.get("capture_pending", False),
}
if "recording_import" in spec:
    meeting["recording_import"] = spec["recording_import"]
    meeting["processing_status"] = spec["recording_import"]["processing_status"]
with open(os.path.join(base, "meetings", mid + ".json"), "w") as handle:
    json.dump(meeting, handle)
transcript = spec.get("transcript", "Captain: Let us compare three shed kits.\n\nRobin: Sounds good.")
with open(os.path.join(base, "meetings", mid + ".md"), "w") as handle:
    handle.write(f"# {meeting['title']}\n\n- ID: `{mid}`\n\n## Notes\n\n{meeting['note']['markdown']}\n\n"
                 + "".join(f"## Summary\n\n{s['markdown']}\n\n" for s in meeting["summaries"])
                 + (f"## Transcript\n\n{transcript}" if transcript else ""))
listing = []
path = os.path.join(base, "list.json")
if os.path.exists(path):
    with open(path) as handle:
        listing = [i for i in json.load(handle) if i["id"] != mid]
if not spec.get("unlisted"):
    listing.insert(0, {k: meeting[k] for k in ("id", "title", "kind", "status", "created_at", "updated_at",
                                               "started_at", "ended_at", "series_id", "folder_path")})
with open(path, "w") as handle:
    json.dump(listing, handle)
PY

# new_home <name>: a scratch home with its own fake Anarlog data and recorders.
new_home() {
  local home="$TMP_ROOT/$1"
  mkdir -p "$home/state" "$home/config" "$home/anarlog/jobs" "$home/model" "$home/inbox"
  printf 'glasses_folder = %s\n' "$home/glasses" > "$home/config/meetings"
  printf '[]\n' > "$home/anarlog/list.json"
  : > "$home/anarlog/calls.log"
  printf '%s\n' "$home"
}

# meeting <home> <json-spec>: add or replace one invented meeting.
meeting() {
  python3 "$FAKES/fixture.py" "$1/anarlog" "$NOW" "$2"
}

# run <home> <now-offset> <args...>: run the subject in <home> at NOW + offset.
run() {
  local home=$1 offset=$2
  shift 2
  env FM_HOME="$home" FM_MEETINGS_NOW=$((NOW + offset)) \
    FM_MEETINGS_ANARLOG="$FAKES/anarlog" FAKE_ANARLOG_DIR="$home/anarlog" \
    FM_MEETINGS_CLAUDE="$FAKES/claude" FAKE_MODEL_DIR="$home/model" FAKE_MODEL_OUTPUT="$home/model/output.json" \
    FM_MEETINGS_INBOX="$FAKES/inbox" FAKE_INBOX_DIR="$home/inbox" \
    FM_MEETINGS_SPEAK="$FAKES/speak" FAKE_SPOKEN="$home/spoken.txt" \
    "$SUBJECT" "$@"
}

# baseline <home>: arm-time record well before the fixtures' meetings ended.
baseline() {
  mkdir -p "$1/state/meetings"
  printf '{"version":1,"baseline":%s,"meetings":{},"files":{},"notices":{}}\n' $((NOW - 86400)) \
    > "$1/state/meetings/records.json"
}

model_says() {
  printf '%s\n' "$2" > "$1/model/output.json"
}

phase_of() {
  python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["meetings"].get(sys.argv[2], {}).get("phase", ""))' \
    "$1/state/meetings/records.json" "$2"
}

test_help_and_usage() {
  local out rc=0
  out=$("$SUBJECT" --help 2>&1) || rc=$?
  expect_code 0 "$rc" "--help exits 0"
  assert_contains "$out" "fm-meetings.sh intake" "--help lists intake"
  rc=0
  out=$("$SUBJECT" bogus 2>&1) || rc=$?
  expect_code 2 "$rc" "an unknown action exits 2"
  assert_contains "$out" "unknown action" "an unknown action is named"
  pass "fm-meetings: help and usage"
}

test_arm_binds_the_check_and_disarm_removes_it() {
  local home out
  home=$(new_home arm)
  out=$(FM_HOME="$home" "$SUBJECT" arm 2>&1) || fail "arm must succeed: $out"
  assert_contains "$out" "armed: state/meetings.check.sh" "arm names the shim"
  assert_present "$home/state/meetings.check-trust" "arm binds the shim for the watcher"
  assert_contains "$(cat "$home/state/meetings.check.sh")" "fm-meetings.sh check" "the shim runs the check"
  assert_contains "$(cat "$home/state/meetings.check.sh")" "FM_HOME=$home" "the shim pins the home"
  assert_grep '"baseline"' "$home/state/meetings/records.json" "arm records the arming time"
  out=$(FM_HOME="$home" "$SUBJECT" arm 2>&1) || fail "re-arm must succeed: $out"
  out=$(FM_HOME="$home" "$SUBJECT" disarm 2>&1) || fail "disarm must succeed: $out"
  assert_absent "$home/state/meetings.check.sh" "disarm removes the shim"
  assert_absent "$home/state/meetings.check-trust" "disarm removes the trust binding"
  assert_present "$home/state/meetings/records.json" "disarm keeps the meeting records"
  pass "fm-meetings: arm binds the check, disarm removes it and keeps the records"
}

test_meetings_before_arming_are_left_alone() {
  local home out
  home=$(new_home before-arm)
  meeting "$home" '{"id":"m-old","ended":-900,"source":"batch_transcription","model":"soniqo-parakeet-batch"}'
  out=$(run "$home" 0 check)
  assert_equals "" "$out" "the first poll sets the baseline and announces nothing"
  assert_equals baseline "$(phase_of "$home" m-old)" "a meeting that ended before arming is left alone"
  pass "fm-meetings: meetings that ended before arming are left alone"
}

test_native_batch_meeting_is_announced_once() {
  local home out
  home=$(new_home native)
  baseline "$home"
  meeting "$home" '{"id":"m-native","title":"Shed plans","ended":-60,"source":"batch_transcription","model":"soniqo-parakeet-batch"}'
  out=$(run "$home" 0 check)
  assert_equals "" "$out" "a meeting that changed a minute ago is still settling"
  out=$(run "$home" 300 check)
  assert_contains "$out" "meetings: 1 meeting(s) ready for intake (Shed plans)" "a settled meeting is announced"
  out=$(run "$home" 600 check)
  assert_equals "" "$out" "it is announced only once"
  assert_no_grep "import" "$home/anarlog/calls.log" "Anarlog's own Batch transcript needs no speaker pass"
  pass "fm-meetings: a meeting Anarlog already ran its Batch pass on is announced once"
}

test_capture_pending_and_missing_summary_wait() {
  local home out
  home=$(new_home pending)
  baseline "$home"
  meeting "$home" '{"id":"m-pend","title":"Still saving","ended":-900,"capture_pending":true,"source":"batch_transcription"}'
  out=$(run "$home" 0 check)
  assert_equals "" "$out" "a capture Anarlog is still finishing is not announced"
  meeting "$home" '{"id":"m-pend","title":"Still saving","ended":-300,"no_summary":true,"source":"batch_transcription"}'
  out=$(run "$home" 0 check)
  assert_equals "" "$out" "a meeting without its summary waits for it"
  out=$(run "$home" 400 check)
  assert_contains "$out" "Still saving" "after ten minutes it goes ahead without a summary"
  pass "fm-meetings: pending captures and missing summaries wait"
}

test_live_only_meeting_gets_a_speaker_pass() {
  local home out child job
  home=$(new_home speaker-pass)
  baseline "$home"
  # Anarlog keeps a meeting's folder under sessions/, inside any meeting folders.
  mkdir -p "$home/anarlog/sessions/Trips/m-live"
  printf 'RIFF-fake-audio' > "$home/anarlog/sessions/Trips/m-live/audio.wav"
  meeting "$home" '{"id":"m-live","title":"Bike trip","ended":-900,"attachments":[{"id":"a1","relative_path":"audio.wav","filename":"audio.wav","content_type":"audio/wav","size_bytes":15,"sha256":""}]}'
  out=$(run "$home" 0 check)
  assert_equals "" "$out" "nothing is announced while the speaker pass runs"
  assert_grep '"request_key": "fm-meetings-speakers-m-live"' "$home/anarlog/imports.jsonl" "the recording is imported for Anarlog's Batch pass"
  assert_grep '"title": "Bike trip (speaker pass)"' "$home/anarlog/imports.jsonl" "the speaker-pass copy is titled after its meeting"
  assert_grep "$home/anarlog/sessions/Trips/m-live/audio.wav" "$home/anarlog/imports.jsonl" "the meeting's own recording is the one imported"
  assert_equals speaker-pass "$(phase_of "$home" m-live)" "the meeting waits on the speaker pass"
  child=$(python3 -c 'import json,sys; print(json.loads(open(sys.argv[1]).readline())["request_key"])' "$home/anarlog/imports.jsonl")
  child=$(printf '%s' "$child" | python3 -c 'import hashlib,sys; print(hashlib.sha1(sys.stdin.read().encode()).hexdigest()[:8])')
  job="job-$child"
  meeting "$home" "{\"id\":\"imp-$child\",\"title\":\"Bike trip (speaker pass)\",\"ended\":-60,\"source\":\"batch_transcription\",\"model\":\"soniqo-parakeet-batch\",\"recording_import\":{\"job_id\":\"$job\",\"meeting_id\":\"imp-$child\",\"processing_status\":\"transcribing\",\"summary_status\":\"pending\",\"error\":null},\"transcript\":\"Captain: Firstmate, do it: plan the route along the river.\\n\\nSpeaker 2: Fine by me.\"}"
  out=$(run "$home" 60 check)
  assert_equals "" "$out" "an unfinished speaker pass keeps waiting"
  printf '{"processing_status":"done","error":null}\n' > "$home/anarlog/jobs/$job.json"
  out=$(run "$home" 120 check)
  assert_contains "$out" "1 meeting(s) ready for intake (Bike trip)" "the meeting is announced once its speaker pass is done"
  assert_not_contains "$out" "(speaker pass)" "the speaker-pass copy is never announced on its own"
  assert_equals 1 "$(grep -c . "$home/anarlog/imports.jsonl")" "the speaker pass is requested once"

  model_says "$home" '{"outcome":"The route goes along the river.","actions":[],"spoken_orders":[{"candidate":1,"instruction":"Plan the bike route along the river","evidence":"plan the route along the river","outward":false,"destructive":false,"other_person":false}]}'
  out=$(run "$home" 180 intake)
  assert_contains "$out" "Bike trip: 1 clear follow-up(s) to start" "the captain's spoken order is a clear follow-up"
  assert_not_contains "$out" "live transcript only" "the speaker-pass transcript counts as final"
  assert_grep "Plan the bike route along the river" "$home/inbox/meeting-m-live-start" "the spoken order goes to firstmate ready to start"
  assert_grep "Firstmate, do it: plan the route" "$(ls "$home"/model/prompt.*)" "the model reads the speaker-pass transcript"
  pass "fm-meetings: a live-only meeting gets Anarlog's Batch pass through its own import"
}

test_speaker_pass_falls_back_to_the_live_transcript() {
  local home out
  home=$(new_home fallback)
  baseline "$home"
  meeting "$home" '{"id":"m-noaudio","title":"Quick chat","ended":-900}'
  out=$(run "$home" 0 check)
  assert_contains "$out" "Quick chat" "a meeting without a recording is announced at once"
  model_says "$home" '{"outcome":"Nothing was settled.","actions":[],"spoken_orders":[]}'
  out=$(run "$home" 60 intake)
  assert_contains "$out" "live transcript only: Anarlog kept no recording" "the outcome says only the live transcript was used, and why"
  assert_grep "Only the live transcript was available." "$home/spoken.txt" "the spoken line says so too"

  home=$(new_home fallback-failed)
  baseline "$home"
  mkdir -p "$home/anarlog/sessions/m-fail"
  printf 'audio' > "$home/anarlog/sessions/m-fail/rec.m4a"
  meeting "$home" '{"id":"m-fail","title":"Failed pass","ended":-900,"attachments":[{"relative_path":"rec.m4a","filename":"rec.m4a","content_type":"audio/mp4"}]}'
  touch "$home/anarlog/import-fails"
  out=$(run "$home" 0 check)
  assert_equals "" "$out" "a refused speaker pass is retried while there is time"
  out=$(run "$home" 11000 check)
  assert_contains "$out" "Failed pass" "after the wait the live transcript is used"
  model_says "$home" '{"outcome":"Nothing was settled.","actions":[],"spoken_orders":[]}'
  out=$(run "$home" 11100 intake)
  assert_contains "$out" "Anarlog could not start the speaker pass (anarlog meetings import" "the reason the speaker pass is missing is reported"
  assert_contains "$out" "Open the updated Anarlog desktop app" "with Anarlog's own words for it"

  home=$(new_home fallback-missing)
  baseline "$home"
  meeting "$home" '{"id":"m-gone","title":"Missing file","ended":-900,"attachments":[{"relative_path":"audio.wav","filename":"audio.wav","content_type":"audio/wav"}]}'
  run "$home" 0 check >/dev/null
  model_says "$home" '{"outcome":"Nothing was settled.","actions":[],"spoken_orders":[]}'
  out=$(run "$home" 60 intake)
  assert_contains "$out" "the meeting's recording could not be found on this Mac" "a recording Anarlog lists but this Mac lacks is named as the reason"
  assert_absent "$home/anarlog/imports.jsonl" "nothing is imported without the recording"
  pass "fm-meetings: the live transcript is used only when the speaker pass cannot run, and the outcome says so"
}

test_work_meeting_is_never_processed() {
  local home out
  home=$(new_home work)
  baseline "$home"
  printf 'work_marker = Examplecorp\nwork_words = none\n' >> "$home/config/meetings"
  meeting "$home" '{"id":"m-work","title":"Quarterly sync","ended":-900,"source":"batch_transcription","participants":[{"human_id":"p1","display_name":"Sam","email":"sam@examplecorp.test"}]}'
  run "$home" 0 check >/dev/null
  out=$(run "$home" 60 intake)
  assert_equals "work meeting, not processed: Quarterly sync" "$out" "a work meeting gets only the one-line note"
  assert_absent "$home/model/calls" "a work meeting never reaches the model"
  assert_equals "" "$(ls "$home/inbox")" "a work meeting files nothing"
  assert_absent "$home/spoken.txt" "a work meeting is not spoken"
  assert_absent "$home/data/meetings/m-work/intake.json" "a work meeting keeps no intake record"

  home=$(new_home work-words)
  baseline "$home"
  printf '# private words\nExamplecorp\n' > "$home/config/leak-words"
  meeting "$home" '{"id":"m-work2","title":"Planning","ended":-900,"source":"batch_transcription","summary":"Roadmap for EXAMPLECORP customers."}'
  run "$home" 0 check >/dev/null
  out=$(run "$home" 60 intake)
  assert_equals "work meeting, not processed: Planning" "$out" "a word from the home's word list marks a work meeting"
  pass "fm-meetings: a work meeting is never sent to a model or actioned"
}

test_intake_sorts_clear_actions_from_review_items() {
  local home out start review
  home=$(new_home intake)
  baseline "$home"
  meeting "$home" '{"id":"m-mix","title":"Garden planning","ended":-900,"source":"batch_transcription","transcript":"Captain: Let us compare three shed kits and their prices.\n\nRobin: I will send you the measurements.\n\nRobin: Firstmate, do it, order the cheapest one."}'
  run "$home" 0 check >/dev/null
  model_says "$home" '{"outcome":"They will compare shed kits.","actions":[
    {"title":"Compare three shed kits","instruction":"Research three garden shed kits and compare prices","evidence":"compare three shed kits and their prices","clear":true,"why_review":"","outward":false,"destructive":false,"other_person":false},
    {"title":"Draft a planting plan","instruction":"Draft a planting plan","evidence":"words that were never said","clear":true,"why_review":"","outward":false,"destructive":false,"other_person":false},
    {"title":"Email Robin the shed list","instruction":"Email the list","evidence":"Let us compare three shed kits","clear":true,"why_review":"","outward":false,"destructive":false,"other_person":false},
    {"title":"Get measurements from Robin","instruction":"Wait for the measurements","evidence":"I will send you the measurements","clear":false,"why_review":"Robin owns it","outward":false,"destructive":false,"other_person":true}],
    "spoken_orders":[{"candidate":1,"instruction":"Buy the cheapest shed","evidence":"order the cheapest one","outward":true,"destructive":false,"other_person":false}]}'
  out=$(run "$home" 60 intake)
  assert_contains "$out" "Garden planning: 1 clear follow-up(s) to start, 4 for the captain's tap, outcome spoken" "the intake reports the split"
  start="$home/inbox/meeting-m-mix-start"
  review="$home/inbox/meeting-m-mix-review"
  assert_grep "Compare three shed kits" "$start" "a clear, grounded, internal action is ready to start"
  assert_grep 'Source: "compare three shed kits and their prices"' "$start" "the start note carries its source snippet"
  assert_grep "not typed by the captain" "$start" "the note says it was extracted, not typed"
  assert_no_grep "Email Robin" "$start" "an outward action never starts on its own"
  assert_grep "Draft a planting plan (waits because its source could not be found" "$review" "an action without a found source waits"
  assert_grep "Email Robin the shed list (waits because it would act toward someone outside Starship" "$review" "an outward action waits even when the model called it clear"
  assert_grep "touches another person's commitment" "$review" "another person's commitment waits"
  assert_grep "someone other than the captain said it" "$review" "a spoken order from someone else waits"
  assert_grep "Garden planning" "$home/spoken.txt" "one spoken line goes to the desk"
  assert_grep "1 clear follow-up handed to Starship, 4 waiting for your tap." "$home/spoken.txt" "the spoken line gives the split"
  assert_present "$home/data/meetings/m-mix/intake.json" "the intake record is kept"
  assert_equals taken "$(phase_of "$home" m-mix)" "the meeting is marked taken in"
  out=$(run "$home" 120 intake)
  assert_equals "no meetings are waiting for intake" "$out" "a taken meeting is not taken in again"
  out=$(run "$home" 120 intake m-mix)
  assert_contains "$out" "already handled" "naming a taken meeting does not repeat it"
  assert_equals 1 "$(grep -c . "$home/model/calls")" "the model ran once"
  pass "fm-meetings: intake starts only clear grounded internal work and holds the rest for the captain"
}

test_failed_intake_stays_ready() {
  local home out rc=0
  home=$(new_home intake-fail)
  baseline "$home"
  meeting "$home" '{"id":"m-retry","title":"Retry me","ended":-900,"source":"batch_transcription"}'
  run "$home" 0 check >/dev/null
  printf 'not json' > "$home/model/output.json"
  out=$(run "$home" 60 intake) || rc=$?
  expect_code 1 "$rc" "a failed intake exits 1"
  assert_contains "$out" "intake failed: Retry me" "the failure is named"
  assert_equals ready "$(phase_of "$home" m-retry)" "the meeting stays ready for the next intake"
  assert_equals "" "$(ls "$home/inbox")" "a failed intake files nothing"
  pass "fm-meetings: a failed intake leaves the meeting ready"
}

test_glasses_calls_flow_into_the_same_intake() {
  local home out key tag
  home=$(new_home glasses)
  baseline "$home"
  mkdir -p "$home/glasses"
  printf 'fake-m4a' > "$home/glasses/call one.m4a"
  printf 'notes' > "$home/glasses/call one.txt"
  touch -t 202601010101 "$home/glasses/call one.m4a"
  out=$(run "$home" 0 check)
  assert_absent "$home/anarlog/imports.jsonl" "a file is not imported the first time it is seen"
  out=$(run "$home" 300 check)
  assert_grep '"request_key": "fm-meetings-glasses-' "$home/anarlog/imports.jsonl" "a stable shared call is imported into Anarlog"
  assert_grep '"title": "Glasses call 2026-01-01 01:01"' "$home/anarlog/imports.jsonl" "the import is titled as a glasses call"
  key=$(python3 -c 'import json,sys; print(json.loads(open(sys.argv[1]).readline())["request_key"])' "$home/anarlog/imports.jsonl")
  tag=$(printf '%s' "$key" | python3 -c 'import hashlib,sys; print(hashlib.sha1(sys.stdin.read().encode()).hexdigest()[:8])')
  meeting "$home" "{\"id\":\"imp-$tag\",\"title\":\"Glasses call 2026-01-01 01:01\",\"ended\":-60,\"unfinished\":true,\"source\":\"batch_transcription\",\"language\":\"nl\",\"recording_import\":{\"job_id\":\"job-$tag\",\"meeting_id\":\"imp-$tag\",\"processing_status\":\"done\",\"summary_status\":\"done\",\"error\":null}}"
  out=$(run "$home" 360 check)
  assert_contains "$out" "ready for intake (Glasses call 2026-01-01 01:01)" "the transcribed glasses call is announced"
  out=$(run "$home" 600 check)
  assert_equals 1 "$(grep -c . "$home/anarlog/imports.jsonl")" "a shared file is imported once"
  assert_present "$home/glasses/call one.m4a" "the shared file is left in place"
  out=$(run "$home" 600 status)
  assert_contains "$out" "call one.txt" "a non-audio file is listed"
  assert_contains "$out" "skipped" "and skipped"
  model_says "$home" '{"outcome":"Dinner is on Friday.","actions":[],"spoken_orders":[]}'
  touch "$home/spoken.txt.off"
  out=$(run "$home" 660 intake)
  assert_contains "$out" "Glasses call 2026-01-01 01:01: 0 clear follow-up(s)" "the glasses call runs through the same intake"
  assert_contains "$out" "desk voice is off" "a home without desk voice is told so rather than told it spoke"
  assert_absent "$home/spoken.txt" "nothing is handed to a desk voice that is off"
  assert_grep '"origin": "glasses"' "$home/data/meetings/imp-$tag/intake.json" "its record says it came from the glasses"
  assert_grep '"language": "nl"' "$home/data/meetings/imp-$tag/intake.json" "its record keeps the language Anarlog heard"
  pass "fm-meetings: shared glasses calls are imported once and flow into the same intake"
}

test_unreadable_anarlog_is_reported_once() {
  local home out
  home=$(new_home broken)
  baseline "$home"
  touch "$home/anarlog/list-fails"
  out=$(run "$home" 0 check)
  assert_contains "$out" "meetings: Anarlog cannot be read: anarlog meetings list failed: database is locked" "a broken Anarlog is reported with its own error"
  out=$(run "$home" 300 check)
  assert_equals "" "$out" "the same problem is reported only once"
  rm -f "$home/anarlog/list-fails"
  run "$home" 600 check >/dev/null
  touch "$home/anarlog/list-fails"
  out=$(run "$home" 900 check)
  assert_contains "$out" "Anarlog cannot be read" "it is reported again after it cleared and came back"
  pass "fm-meetings: an unreadable Anarlog is reported once until it clears"
}

test_recall_answers_from_personal_meetings_only() {
  local home out
  home=$(new_home recall)
  baseline "$home"
  printf 'work_marker = Examplecorp\nwork_words = none\n' >> "$home/config/meetings"
  meeting "$home" '{"id":"m-robin","title":"Garden planning","ended":-900,"source":"batch_transcription","participants":[{"human_id":"r","display_name":"Robin","email":""}]}'
  meeting "$home" '{"id":"m-robin-work","title":"Robin at Examplecorp","ended":-800,"source":"batch_transcription"}'
  run "$home" 0 check >/dev/null
  model_says "$home" '{"outcome":"They agreed to compare shed kits.","actions":[{"title":"Compare shed kits","instruction":"Compare shed kits","evidence":"compare three shed kits","clear":true,"why_review":"","outward":false,"destructive":false,"other_person":false}],"spoken_orders":[]}'
  run "$home" 60 intake >/dev/null
  out=$(run "$home" 120 recall what did we agree with Robin)
  assert_contains "$out" "Garden planning (with Robin)" "recall finds the personal meeting by person"
  assert_contains "$out" "Outcome: They agreed to compare shed kits." "recall gives what was agreed"
  assert_contains "$out" "Follow-up started: Compare shed kits" "recall lists the follow-ups"
  assert_not_contains "$out" "Examplecorp" "recall never answers from a work meeting"
  pass "fm-meetings: recall answers from personal meetings only"
}

test_notes_land_in_the_real_inbox() {
  local home out
  home=$(new_home real-inbox)
  baseline "$home"
  # An away record keeps the real inbox from ringing a primary pane that a
  # scratch home does not have; the note and its wake are still written.
  touch "$home/state/.afk"
  meeting "$home" '{"id":"m-real","title":"Garden planning","ended":-900,"source":"batch_transcription"}'
  run "$home" 0 check >/dev/null
  model_says "$home" '{"outcome":"They will compare shed kits.","actions":[{"title":"Compare shed kits","instruction":"Compare three shed kits","evidence":"compare three shed kits","clear":true,"why_review":"","outward":false,"destructive":false,"other_person":false}],"spoken_orders":[]}'
  out=$(env FM_MEETINGS_INBOX="$ROOT/bin/fm-inbox.sh" FM_HOME="$home" FM_MEETINGS_NOW=$((NOW + 60)) \
    FM_MEETINGS_ANARLOG="$FAKES/anarlog" FAKE_ANARLOG_DIR="$home/anarlog" \
    FM_MEETINGS_CLAUDE="$FAKES/claude" FAKE_MODEL_DIR="$home/model" FAKE_MODEL_OUTPUT="$home/model/output.json" \
    FM_MEETINGS_SPEAK="$FAKES/speak" FAKE_SPOKEN="$home/spoken.txt" "$SUBJECT" intake)
  assert_contains "$out" "Garden planning: 1 clear follow-up(s) to start" "the intake ran against the real inbox"
  assert_grep "request_id=meeting-m-real-start" "$(ls "$home"/state/inbox/*.note)" "the start note is a durable inbox note keyed by meeting"
  assert_grep "Meeting follow-ups ready to start" "$(ls "$home"/state/inbox/*.note)" "the note opens with the line the skill is loaded on"
  assert_grep "inbox" "$home/state/.wake-queue" "the note wakes firstmate"
  pass "fm-meetings: follow-ups land in the real inbox as durable, waking notes"
}

test_example_config_is_accepted_and_typos_refused() {
  local home out rc=0
  home=$(new_home config)
  cp "$ROOT/docs/examples/meetings" "$home/config/meetings"
  out=$(run "$home" 0 status 2>&1) || rc=$?
  expect_code 0 "$rc" "the shipped example config is accepted: $out"
  printf 'speaker_pas = off\n' >> "$home/config/meetings"
  rc=0
  out=$(run "$home" 0 status 2>&1) || rc=$?
  expect_code 1 "$rc" "an unknown key is refused"
  assert_contains "$out" "unknown key speaker_pas" "the refused key is named"
  pass "fm-meetings: the example config is accepted and a typo is refused"
}

test_layer_only_reads_anarlog_and_imports() {
  local home
  for home in "$TMP_ROOT"/*/anarlog; do
    [ -f "$home/calls.log" ] || continue
    if grep -v -E '^(--json )?(doctor|meetings --source local (list|get|export|import|import-status)( |$))' "$home/calls.log" >/dev/null; then
      fail "the layer called Anarlog outside its read and import commands: $(grep -v -E '^(--json )?(doctor|meetings --source local (list|get|export|import|import-status)( |$))' "$home/calls.log" | head -1)"
    fi
  done
  pass "fm-meetings: the layer only reads Anarlog and asks it to import recordings"
}

test_help_and_usage
test_arm_binds_the_check_and_disarm_removes_it
test_meetings_before_arming_are_left_alone
test_native_batch_meeting_is_announced_once
test_capture_pending_and_missing_summary_wait
test_live_only_meeting_gets_a_speaker_pass
test_speaker_pass_falls_back_to_the_live_transcript
test_work_meeting_is_never_processed
test_intake_sorts_clear_actions_from_review_items
test_failed_intake_stays_ready
test_glasses_calls_flow_into_the_same_intake
test_unreadable_anarlog_is_reported_once
test_recall_answers_from_personal_meetings_only
test_notes_land_in_the_real_inbox
test_example_config_is_accepted_and_typos_refused
test_layer_only_reads_anarlog_and_imports
