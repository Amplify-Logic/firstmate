# fm-web live validation transcript (lab home, real Claude Code primary on private tmux socket fm-lab)

## Launcher
fm-web.sh start --port 0  -> http://127.0.0.1:50958/?token=<redacted>   (exit 0)
fm-web.sh status          -> running on 127.0.0.1:50958 (pid 61721)
lsof LISTEN               -> TCP 127.0.0.1:50958 only
state/web mode 700, state/web/token mode 600
fm-web.sh stop            -> stopped; status -> stopped (rc 3); curl -> connection refused; url -> "not running" (rc 1)

## Sign-in and guards (curl against live server)
?token=<valid>                       303 -> Location: /, Set-Cookie fm_web_<port>; HttpOnly; SameSite=Strict
GET / no cookie                      403
GET /api/conversation no cookie      403
GET / wrong token                    403
forged cookie                        403
valid cookie                         200
Host: evil.example:<port>            403   (DNS rebinding)
Host: localhost:<port>               200
POST /api/send no CSRF header        403
POST wrong CSRF                      403
POST Origin: http://evil.example     403
POST Sec-Fetch-Site: cross-site      403
POST no cookie                       403
POST "image" that is text            400 {"outcome":"failed","detail":"only PNG, JPEG, GIF or WebP images can be attached"}
CSP: default-src 'none'; style-src 'nonce-…'; script-src 'nonce-…'; …
token occurrences in web.log / web.log.start: 0 / 0
GUARD-PROBE text reaching primary pane or mailbox: 0 / 0

## Page-driven sends (headless Chrome over CDP, typing in the page, Enter)
1. "Web page check: … three numbered options …"  -> "Typed into the first mate's chat."; primary replied; page rendered
   1./2./3. (ol start=null,2,3 across blank-line-separated items) and a table.
2. pasted PNG + text -> thumbnail shown, saved to state/desk-voice/shots/ (0600), primary received path, Read it, replied "solid red".
   Header showed "Working" during the turn, "Ready" after.
3. "2" sent while primary showed a permission selection dialog -> "The chat was busy, so it went to the first mate's mailbox.";
   pane byte-identical before/after (dialog NOT answered); mailbox JSON source=web transcript="2"; wake queued.
4. primary killed -> header "Not running"; send -> mailbox.

## FAIL: /clear in the primary
Before: state/.lock-session = 66d6e1cf-…; after /clear the primary's CLAUDE_CODE_SESSION_ID = 78b597e0-…
Sidecar stayed 66d6e1cf-… (fm-lock.sh status: held by live harness pid). Page kept showing the pre-clear conversation.
Page send "After-clear check: reply with the single word pineapple." -> "Typed into the first mate's chat."; primary answered
"pineapple" in the terminal; after 60s the page still showed neither the message nor the reply, header "Ready".
Only after the primary explicitly ran bin/fm-lock.sh did the sidecar become 78b597e0-… and the page switch to the new conversation.
