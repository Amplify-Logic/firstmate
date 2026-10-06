# fm-web round 3 live validation (target f90dcdf1; lab home, real Claude Code v2.1.292 primary on private tmux socket fm-lab, headless Chrome over CDP)

Lab primary ran bin/fm-lock.sh: state/.lock=65909 (claude pid), .lock-session=5405920b-…
fm-web.sh start --port 0 -> http://127.0.0.1:52240/?token=<redacted>; status "running on 127.0.0.1:52240"

1. Sign in with the token link -> address bar drops the token (http://127.0.0.1:52240/), conversation shown, header Ready. (r3-01)
2. Page send (typed + Enter) "Round 3 web check: reply with the single word kiwi." -> "Typed into the first mate's chat."; page shows message + "kiwi", header Ready. (r3-02)
3. Idle /clear typed in the primary terminal, nothing sent:
   sidecar .lock-session stays 5405920b-… ; sessions/65909.json sessionId -> 70e45b05-…
   Page switched to the new session at once (only "/clear"), header "Ready" at +6 s and still "Ready" at +41 s;
   terminal shows an empty idle prompt.  (r3-03, r3-04)  PASS (round-2 failure fixed)
4. Page send after the idle clear "…run the bash command sleep 12, then reply … grape." -> "Typed into the first mate's chat.";
   at +7 s header "Working" with the Bash line in progress (r3-05); after the turn header "Ready" with "grape" (r3-06, dark r3-07).
5. /context typed in the terminal while idle then dismissed: header stays Ready.
6. Guards (r3-guards.txt): no cookie 403, bad token 403, cookie HttpOnly+SameSite=Strict, rebinding Host 403,
   POST without CSRF 403, cross-origin Origin 403, token never in web.log, listener only on 127.0.0.1.
7. Primary stopped (kill-server): header "Not running"; page send -> "The chat was busy, so it went to the first mate's mailbox.";
   state/desk-voice/inbox/20261006T211809Z-86b92544.json {"source":"web","transcript":"Sent while the primary is stopped."}  (r3-08)
Teardown: fm-web.sh stop, Chrome killed, fm-lab tmux server killed, lab home rm -rf.
