#!/usr/bin/env bash
# Drives bin/fm-claude-reply-speak.sh (the Claude Stop hook) with real Stop
# payloads, as a child of a process named "claude" that holds the home lock,
# through the REAL bin/fm-speak.sh. The register owner is a pass-through fake
# that refuses decision requests (exit 2) like the real one; the speaker renders
# each handed-over line with the real macOS `say -o` to an .aiff (never plays).
set -u
WT=$1; EVID=$2
LAB=$(mktemp -d /tmp/fm-reply-speak-drive.XXXXXX)
trap 'rm -rf "$LAB"' EXIT
git clone -q "$WT" "$LAB/home"; cp -R "$WT/bin/." "$LAB/home/bin/"
H="$LAB/home"; mkdir -p "$H/state" "$H/config" "$LAB/fakebin"
printf 'enabled = true\n' > "$H/config/speak"
ln -s /bin/bash "$LAB/fakebin/claude"
cat > "$LAB/shaper" <<'S'
#!/usr/bin/env bash
shift; t=$*
case "$t" in *"Shall I"*|*"Should I"*|*"approve?"*) echo "refused: asks the captain to decide" >&2; exit 2;; esac
printf '%s\n' "$t"
S
N=0
cat > "$LAB/speaker" <<S
#!/usr/bin/env bash
prev=; f=
for a in "\$@"; do [ "\$prev" != -f ] || f=\$a; prev=\$a; done
[ -n "\$f" ] || exit 0
n=\$(( \$(wc -l < "$LAB/audio.log" 2>/dev/null || echo 0) + 1 ))
printf '%s\n' "\$(cat "\$f")" >> "$LAB/audio.log"
/usr/bin/say -f "\$f" -o "$EVID/spoken-\$(cat "$LAB/case")-\$n.aiff"
S
chmod +x "$LAB/shaper" "$LAB/speaker"
export FM_DEEPGRAM_ENV_FILE=/dev/null FM_SPEAK_SHAPER="$LAB/shaper" FM_SPEAK_SAY="$LAB/speaker"
unset DEEPGRAM_API_KEY GLASSES_ANNOUNCE_CONFIG

stop() {  # <case> <reply> [home]
  local c=$1 reply=$2 home=${3:-$H} before after
  printf '%s' "$c" > "$LAB/case"
  touch "$LAB/audio.log"; before=$(wc -l < "$LAB/audio.log" | tr -d ' ')
  jq -cn --arg m "$reply" '{session_id:"drive",hook_event_name:"Stop",stop_hook_active:false,last_assistant_message:$m}' \
    | FM_HOME="$home" FM_REPLY_SPEAK_SETTLE_MS="${SETTLE:-300}" "$LAB/fakebin/claude" -c \
      'printf "%s\n" "$$" > "$FM_HOME/state/.lock"; "$FM_HOME/bin/fm-claude-reply-speak.sh"; echo "hook exit=$?"'
  sleep 2   # detached speaker
  after=$(wc -l < "$LAB/audio.log" 2>/dev/null | tr -d ' '); after=${after:-0}
  printf '\n### %s\nreply:  %q\n' "$c" "$reply"
  if [ "$after" -gt "$before" ]; then sed -n "$((before+1)),${after}p" "$LAB/audio.log" | sed 's/^/SPOKEN: /'; else echo "SPOKEN: (nothing)"; fi
}

echo "== real hook + real fm-speak.sh, Claude-named harness holding state/.lock =="
stop S01-plain-reply "Captain, the finances fix merged and the deploy is green."
stop S02-second-reply-next-turn "Captain, the calendar sync is back and nothing else needs you tonight."
stop S03-exact-shipshape "Captain, shipshape."
stop S03b-exact-shipshape-padded $'  \n Captain, shipshape. \n\n'
stop S04-shipshape-then-news-paragraph $'Captain, shipshape.\n\nThe finances fix merged and the deploy is running; I will report when it lands.'
stop S05-shipshape-then-news-one-line "Captain, shipshape. But the deploy failed and needs your eyes."
stop S06-near-miss-lowercase "captain, shipshape"
stop S07-decision-reply "Captain, the PR is green. Shall I merge it?"
stop S08-markdown $'## Status\n\nCaptain, the **scout** finished; see [report](https://example.com/r) in `data/x`.\n\n| a | b |\n|---|---|\n\n```sh\nrm -rf /\n```'
# model spoke itself during the turn, then the hook must stay silent; next turn speaks again
printf '%s' S09-model-spoke > "$LAB/case"
FM_HOME="$H" "$H/bin/fm-speak.sh" "Captain, model spoke this line itself." >/dev/null 2>&1; sleep 2
echo; echo "(model itself spoke during the next turn via bin/fm-speak.sh: $(tail -1 "$LAB/audio.log"))"
stop S09-hook-after-model-spoke "Captain, this reply was already spoken by the model."
stop S10-turn-after-model-spoke "Captain, the next turn still speaks."
# superseded Stop: one Claude-named harness fires two Stops 0.3s apart with a 1.5s settle window
printf '%s' S11-superseded > "$LAB/case"; before=$(wc -l < "$LAB/audio.log" | tr -d ' ')
FM_HOME="$H" FM_REPLY_SPEAK_SETTLE_MS=1500 "$LAB/fakebin/claude" -c '
  printf "%s\n" "$$" > "$FM_HOME/state/.lock"
  jq -cn "{hook_event_name:\"Stop\",last_assistant_message:\"Captain, mid-turn line that a newer Stop superseded.\"}" | "$FM_HOME/bin/fm-claude-reply-speak.sh" &
  sleep 0.3
  jq -cn "{hook_event_name:\"Stop\",last_assistant_message:\"Captain, the real final reply after the continuation.\"}" | "$FM_HOME/bin/fm-claude-reply-speak.sh" &
  wait'
sleep 2
echo; echo "### S11-superseded-stop (two Stops 0.3s apart, 1.5s settle)"; after=$(wc -l < "$LAB/audio.log" | tr -d ' '); [ "$after" -gt "$before" ] && sed -n "$((before+1)),\$p" "$LAB/audio.log" | sed 's/^/SPOKEN: /' || echo "SPOKEN: (nothing)"
# muted
FM_HOME="$H" "$H/bin/fm-speak.sh" --mute >/dev/null 2>&1
stop S12-muted-home "Captain, this must not be heard while muted."
FM_HOME="$H" "$H/bin/fm-speak.sh" --unmute >/dev/null 2>&1
# not opted in
mv "$H/config/speak" "$H/config/speak.off"
stop S13-not-enabled-home "Captain, this must not be heard without opt-in."
mv "$H/config/speak.off" "$H/config/speak"
# worker worktree of the same repo
git -C "$H" worktree add -q "$LAB/crew-wt" -b crew >/dev/null 2>&1; cp -R "$H/bin/." "$LAB/crew-wt/bin/"; mkdir -p "$LAB/crew-wt/state" "$LAB/crew-wt/config"; cp "$H/config/speak" "$LAB/crew-wt/config/"
stop S14-crew-worktree "Captain, a crew worker must never speak." "$LAB/crew-wt"
# session not holding the lock (no claude ancestry)
printf '%s' S15 > "$LAB/case"; before=$(wc -l < "$LAB/audio.log" | tr -d ' ')
echo 99999 > "$H/state/.lock"
jq -cn '{hook_event_name:"Stop",last_assistant_message:"Captain, a non-lock session must not speak."}' | FM_HOME="$H" FM_REPLY_SPEAK_SETTLE_MS=0 "$H/bin/fm-claude-reply-speak.sh"; sleep 2
echo; echo "### S15-session-without-home-lock"; after=$(wc -l < "$LAB/audio.log" | tr -d ' '); [ "$after" -gt "$before" ] && tail -1 "$LAB/audio.log" | sed 's/^/SPOKEN: /' || echo "SPOKEN: (nothing)"
