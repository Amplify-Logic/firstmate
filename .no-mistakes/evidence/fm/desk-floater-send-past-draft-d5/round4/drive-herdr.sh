#!/usr/bin/env bash
# Live driver: real bin/fm-desk-voice.sh send against a real Claude Code pane
# in an isolated fm-lab-* Herdr session. Every herdr call the floater makes is
# routed through bin/fm-herdr-lab.sh run by a PATH wrapper.
# Usage: drive-desk-floater-herdr.sh <worktree> <evidence-dir>
set -u
WT=$1 EV=$2
HELPER="$WT/bin/fm-herdr-lab.sh"
DESK="$WT/bin/fm-desk-voice.sh"
ORIGINAL_PATH=$PATH
SESSION=$("$HELPER" name desk-draft)
LAB=$(mktemp -d "${TMPDIR:-/tmp}/fm-lab.XXXXXX")
"$WT/bin/fm-lab-home.sh" create "$LAB" >/dev/null || exit 1
mkdir -p "$LAB/project" "$LAB/fakebin"; git -C "$LAB/project" init -q
LOG="$EV/herdr-transcript.txt"; : > "$LOG"
log() { printf '%s\n' "$*" | tee -a "$LOG"; }
cleanup() {
  PATH="$ORIGINAL_PATH" "$HELPER" teardown "$SESSION" >>"$LOG" 2>&1 && log "teardown $SESSION ok" || log "teardown $SESSION FAILED"
  rm -rf "$LAB"
}
trap cleanup EXIT
cat > "$LAB/fakebin/herdr" <<EOF
#!/usr/bin/env bash
set -u
args=("\$@")
n=\${#args[@]}
if [ "\$n" -ge 2 ] && [ "\${args[\$((n-2))]}" = --session ]; then
  [ "\${args[\$((n-1))]}" = "$SESSION" ] || { echo "wrapper refused foreign session" >&2; exit 97; }
  args=("\${args[@]:0:\$((n-2))}")
fi
exec env PATH="$ORIGINAL_PATH" "$HELPER" run "$SESSION" "\${args[@]}"
EOF
chmod +x "$LAB/fakebin/herdr"
"$HELPER" provision "$SESSION" >>"$LOG" 2>&1 || { log "provision failed"; exit 1; }
lab() { env PATH="$ORIGINAL_PATH" "$HELPER" run "$SESSION" "$@"; }
PANE=$(lab workspace create --cwd "$LAB/project" --label fm-deskdraft --no-focus | jq -er '.result.root_pane.pane_id') || { log "no pane"; exit 1; }
log "herdr $(herdr --version | head -1), claude $(claude --version | head -1), session $SESSION pane $PANE"
lab pane run "$PANE" "cd '$LAB/project' && claude --model haiku" >/dev/null || { log "pane run failed"; exit 1; }
read_screen() { lab pane read "$PANE" --source visible 2>/dev/null; }
state() {
  PATH="$LAB/fakebin:$ORIGINAL_PATH" HERDR_SESSION="$SESSION" bash -c '
    . "$1/bin/fm-backend.sh"; fm_backend_composer_state herdr "$2"' _ "$WT" "$SESSION:$PANE" 2>/dev/null
}
idle=0
for _ in $(seq 1 90); do
  case "$(read_screen)" in
    *'❯ Yes, I trust this folder'*|*'> Yes, I trust this folder'*) lab pane send-keys "$PANE" enter >/dev/null ;;
    *'Yes, I trust this folder'*) lab pane send-keys "$PANE" down >/dev/null ;;
    *) [ "$(state)" = empty ] && { idle=1; break; } ;;
  esac
  sleep 1
done
[ "$idle" = 1 ] || { log "claude never idle"; read_screen | tail -8; exit 1; }
sleep 2
# The lock holder is the claude process under the pane.
cpid=$(pgrep -f "claude --model haiku" | while read -r p; do
  ps -E -p "$p" -o command= 2>/dev/null | grep -q "HERDR_SESSION=$SESSION" && echo "$p"; done | head -1)
[ -n "$cpid" ] || cpid=$(for p in $(pgrep -x claude); do ps eww -p "$p" -o command= | grep -q "HERDR_SESSION=$SESSION" && echo "$p"; done | head -1)
[ -n "$cpid" ] || { log "could not find the lab claude pid"; exit 1; }
echo "$cpid" > "$LAB/state/.lock"
log "lock holder claude pid $cpid"
send() {
  env -u NO_MISTAKES_GATE -u FM_GATE_REFUSE_BYPASS -u FM_ROOT_OVERRIDE -u FM_STATE_OVERRIDE \
    -u FM_DATA_OVERRIDE -u FM_CONFIG_OVERRIDE -u FM_PROJECTS_OVERRIDE \
    -u TMUX -u TMUX_PANE -u HERDR_ENV -u HERDR_PANE_ID -u HERDR_SESSION -u HERDR_SOCKET_PATH \
    PATH="$LAB/fakebin:$ORIGINAL_PATH" FM_HOME="$LAB" "$DESK" send --source herdr-live-driver "$1" 2>"$LAB/send.err"
}
snap() { read_screen > "$EV/herdr-screen-$1.txt"; log "  [screen $1]"; grep -v '^[[:space:]]*$' "$EV/herdr-screen-$1.txt" | tail -n 5 | sed 's/^/    | /' | tee -a "$LOG"; }
wait_word() { for _ in $(seq 1 60); do lab pane read "$PANE" --source recent --lines 200 2>/dev/null | grep -q "⏺ $1" && return 0; sleep 1; done; return 1; }
RES=()

# H0: first message into an empty box so Claude has a turn to suggest from.
log "== H0: empty box"
out=$(send 'Reply with only the word OSPREY'); log "  send -> $out"; cat "$LAB/send.err" | tee -a "$LOG"
wait_word OSPREY && a=1 || a=0; log "  answered=$a"
[[ $out == 'sent: herdr '* ]] && [ "$a" = 1 ] && RES+=("H0 pass") || RES+=("H0 FAIL ($out)")
box() {
  PATH="$LAB/fakebin:$ORIGINAL_PATH" HERDR_SESSION="$SESSION" bash -c '
    . "$1/bin/fm-backend.sh"; fm_backend_source herdr
    cap=$(fm_backend_capture herdr "$2" 80) && fm_composer_extract_selected_content styled=0 "$cap"' _ "$WT" "$SESSION:$PANE" 2>/dev/null
}
clear_box() { for _ in $(seq 1 40); do [ "$(state)" = empty ] && return 0; lab pane send-keys "$PANE" ctrl+u >/dev/null; sleep 0.3; done; }
recent() { lab pane read "$PANE" --source recent-unwrapped --lines 400 2>/dev/null; }
idle() { for _ in $(seq 1 90); do read_screen | grep -q 'esc to interrupt' || return 0; sleep 1; done; }

# Round 4: messages past a draft on Herdr are pasted whole. Pass on `sent`
# when the submitted prompt holds the message's head and tail markers, the
# draft is back in the box and never submitted, and the message left the box.
hcase() {  # <tag> <nsentences> <typed|paste>
  local tag=$1 ns=$2 kind=$3 msg i out head tail draftmark b subm left dsub
  idle; clear_box
  head="HEAD${tag//-/}" tail="TAIL${tag//-/}"
  if [ "$kind" = paste ]; then
    draftmark="pasted log ${tag}"
    lab pane send-text "$PANE" $'\e[200~'"$draftmark line A"$'\n'"$draftmark line B"$'\n'"$draftmark line C"$'\n'"$draftmark line D"$'\n'"$draftmark line E"$'\n\e[201~' >/dev/null
  else
    draftmark="SWIFT draft ${tag} kept aside"
    lab pane send-text "$PANE" "$draftmark" >/dev/null
  fi
  sleep 1.5
  msg="$head Captain's dictated note, no reply needed beyond a short acknowledgement."
  for i in $(seq 1 "$ns"); do msg="$msg Sentence $i: the calibration log for the lab bench was reviewed and the numbers look steady."; done
  msg="$msg $tail"
  log "== $tag: ${#msg}-char message past a $kind draft"
  log "  state before: $(state) box before: $(box | head -c 80)"; snap "$tag-before"
  out=$(send "$msg"); log "  send -> $out"; cat "$LAB/send.err" | tee -a "$LOG"
  sleep 3; idle; sleep 1; snap "$tag-after"
  recent > "$EV/herdr-screen-$tag-recent.txt"
  b=$(box)
  subm=0; recent | grep -q "❯ $head" && recent | grep -q "$tail" && subm=1
  left=0; printf '%s' "$b" | grep -q "$head\|$tail" && left=1
  dsub=$(recent | grep -c "$draftmark" || true)
  log "  box now: $(printf '%s' "$b" | head -c 100)"
  log "  submitted-whole=$subm message-left-in-box=$left draft-lines-in-transcript=$dsub state=$(state)"
  case "$out" in
    'sent: herdr '*)
      if [ "$subm" = 1 ] && [ "$left" = 0 ] && [ "$(state)" = pending ] \
        && { { [ "$kind" = typed ] && [ "$dsub" = 1 ] && [ "$b" = "$draftmark" ]; } \
          || { [ "$kind" = paste ] && [ "$dsub" = 0 ] && printf '%s' "$b" | grep -q '^\[Pasted text #[0-9]* +[0-9]* lines\]$'; }; }; then
        RES+=("$tag pass (sent, submitted whole, draft back)")
      else RES+=("$tag FAIL (sent but subm=$subm left=$left dsub=$dsub box=$(printf '%s' "$b" | head -c 60))"); fi ;;
    *) RES+=("$tag FAIL ($out)") ;;
  esac
}
hcase H2 0 typed
hcase H4-m1300 13 typed
hcase H4 33 typed
hcase H4p 33 paste

log "== H3: footer already shows a stash, plus a new draft"
idle; clear_box
lab pane send-text "$PANE" 'FALCON stash the captain set aside' >/dev/null; sleep 1
lab pane send-keys "$PANE" ctrl+s >/dev/null; sleep 1.2
lab pane send-text "$PANE" 'WREN second draft' >/dev/null; sleep 1.2
snap H3-before
out=$(send 'PLOVER short note'); log "  send -> $out"; sleep 2; snap H3-after
b=$(box); stashed=0; read_screen | grep -Eq '›[[:space:]]*stashed' && stashed=1
[[ $out == 'mailbox: '* ]] && [ "$b" = 'WREN second draft' ] && [ "$stashed" = 1 ] && ! recent | grep -q '❯ PLOVER' \
  && RES+=("H3 pass") || RES+=("H3 FAIL ($out box=$b stashed=$stashed)")
clear_box
log "== summary"; printf '%s\n' "${RES[@]}" | tee -a "$LOG"
