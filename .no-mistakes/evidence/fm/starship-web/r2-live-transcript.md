# fm-web round 2 live validation (lab home, real Claude Code v2.1.292 primary on private tmux socket fm-lab, headless Chrome over CDP)

Lab primary ran bin/fm-lock.sh: state/.lock=38395 (claude pid), .lock-session=3dc9eec1-…; <claude-config>/sessions/38395.json sessionId=3dc9eec1-…
fm-web.sh start --port 0 -> http://127.0.0.1:51849/?token=<redacted>

1. Sign in, page send "Round 2 web check A: … mango." -> "Typed into the first mate's chat."; page shows message + "mango", header Ready.  (r2-01)
2. /clear typed in the primary terminal:
   sidecar .lock-session stays 3dc9eec1-… (stale, same as round-1 failure); sessions/38395.json sessionId -> 32f86c80-…
   new transcript 32f86c80-….jsonl created immediately with the /clear local-command records.
   Page switched to the new session at once (items: "/clear").  (r2-02)
   Page send "After-clear check: reply with the single word pineapple." -> "Typed into the first mate's chat."
   Page then shows "/clear | After-clear check … pineapple. | pineapple", header Ready. Sidecar still 3dc9eec1-….  (r2-03)  PASS (round-1 failure fixed)
3. /clear again with the primary idle, no message sent: page header reads "Working" 30 s later while the terminal shows an empty idle prompt.  (r2-04)  FAIL
   New transcript ends with: user isMeta local-command-caveat, user "<command-name>/clear</command-name>…", system subtype=local_command.
   Conversation._user classifies the /clear command record as a user item and sets busy=True; nothing after it clears busy.
   After a page send + reply the header returned to Ready. /cost (a dialog, writes no transcript record) did not reproduce it.  (r2-05)
4. Primary stopped (kill-server): sessions/38395.json removed, header "Not running", page falls back to sidecar session (pre-clear conversation),
   page send -> "The chat was busy, so it went to the first mate's mailbox."; state/desk-voice/inbox/<id>.json written.  (r2-06)
Teardown: fm-web.sh stop, Chrome killed, fm-lab tmux server killed, lab home rm -rf.
