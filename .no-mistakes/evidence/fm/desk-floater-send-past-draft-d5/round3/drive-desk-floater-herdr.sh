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
LOG="$EV/herdr-driver-transcript.txt"; : > "$LOG"
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

# H1: box shows only whatever Claude draws after a reply (a dim suggested
# prompt when it offers one) -> reads empty, message goes straight in.
log "== H1: after a reply (suggested prompt if Claude offers one)"
sleep 6
log "  state before: $(state)"; snap H1-before
lab pane read "$PANE" --source visible --format ansi > "$EV/herdr-screen-H1-before.ansi" 2>/dev/null || true
out=$(send 'Reply with only the word HERON'); log "  send -> $out"; cat "$LAB/send.err" | tee -a "$LOG"
wait_word HERON && a=1 || a=0; log "  answered=$a"; snap H1-after
[[ $out == 'sent: herdr '* ]] && [ "$a" = 1 ] && RES+=("H1 pass") || RES+=("H1 FAIL ($out)")

# H2: typed draft -> Ctrl+S through Herdr, message alone, draft back.
log "== H2: typed draft in the box"
sleep 4
for _ in $(seq 1 10); do [ "$(state)" = empty ] && break; lab pane send-keys "$PANE" ctrl+u >/dev/null; sleep 0.3; done
DRAFT='KESTREL draft the captain has not sent'
lab pane send-text "$PANE" "$DRAFT" >/dev/null; sleep 1.5
log "  state before: $(state)"; snap H2-before
out=$(send 'Reply with only the word EGRET'); log "  send -> $out"; cat "$LAB/send.err" | tee -a "$LOG"
wait_word EGRET && a=1 || a=0; sleep 2; log "  answered=$a state after: $(state)"; snap H2-after
rec=$(lab pane read "$PANE" --source recent --lines 200 2>/dev/null)
printf '%s\n' "$rec" > "$EV/herdr-screen-H2-recent.txt"
n=$(printf '%s\n' "$rec" | grep -cF "$DRAFT")
sub=$(printf '%s\n' "$rec" | grep -E '^❯ Reply' | grep -c KESTREL)
log "  draft occurrences=$n draft-in-submitted=$sub"
[[ $out == 'sent: herdr '* ]] && [ "$a" = 1 ] && [ "$n" = 1 ] && [ "$sub" = 0 ] && [ "$(state)" = pending ] && RES+=("H2 pass") || RES+=("H2 FAIL ($out n=$n sub=$sub)")


box() {
  PATH="$LAB/fakebin:$ORIGINAL_PATH" HERDR_SESSION="$SESSION" bash -c '
    . "$1/bin/fm-backend.sh"; fm_backend_source herdr
    cap=$(fm_backend_capture herdr "$2" 60) && fm_composer_extract_selected_content styled=0 "$cap"' _ "$WT" "$SESSION:$PANE" 2>/dev/null
}
clear_box() { for _ in $(seq 1 30); do [ "$(state)" = empty ] && return 0; lab pane send-keys "$PANE" ctrl+u >/dev/null; sleep 0.3; done; }

# H3: adversarial: the captain already keeps a stash -> mailbox, stash kept.
log "== H3: footer already shows a stash, plus a new draft"
clear_box
lab pane send-text "$PANE" 'FALCON stash the captain set aside' >/dev/null; sleep 1
lab pane send-keys "$PANE" ctrl+s >/dev/null; sleep 1.2
lab pane send-text "$PANE" 'WREN second draft' >/dev/null; sleep 1.2
log "  state before: $(state)"; snap H3-before
out=$(send 'Reply with only the word PLOVER'); log "  send -> $out"; cat "$LAB/send.err" | tee -a "$LOG"
sleep 4; snap H3-after
mb=${out#mailbox: }; [ -f "$mb" ] && log "  mailbox file holds: $(cat "$mb")"
b=$(box); log "  box: $b"
stashed=0; read_screen | grep -Eq '›[[:space:]]*stashed' && stashed=1
sub=0; lab pane read "$PANE" --source recent --lines 200 | grep -q '⏺ PLOVER' && sub=1
clear_box; lab pane send-keys "$PANE" ctrl+s >/dev/null; sleep 1.2; snap H3-unstash
fal=$(box | grep -c FALCON)
[[ $out == 'mailbox: '* ]] && [ -f "$mb" ] && [ "$b" = 'WREN second draft' ] && [ "$stashed" = 1 ] && [ "$sub" = 0 ] && [ "$fal" = 1 ] \
  && RES+=("H3 pass") || RES+=("H3 FAIL ($out box=$b stashed=$stashed sub=$sub falcon=$fal)")
clear_box

# H4: adversarial: a ~3.2k-char message past a draft is `sent` only if submitted.
log "== H4: long message past a typed draft"
lab pane send-text "$PANE" 'SWIFT draft kept aside' >/dev/null; sleep 1.2
long='Reply with only the word IBISH and nothing else. Ignore this filler, which stands in for a long voice transcript:'
for i in $(seq 1 110); do long="$long words number $i of a long dictated floater message,"; done
log "  message length ${#long}; state before: $(state)"; snap H4-before
out=$(send "$long"); log "  send -> $out"; cat "$LAB/send.err" | tee -a "$LOG"
wait_word IBISH && a=1 || a=0; sleep 2; snap H4-after
b=$(box); log "  answered=$a box: $(printf '%s' "$b" | head -c 160)"
left=0; printf '%s' "$b" | grep -q 'dictated floater' && left=1
sw=0; printf '%s' "$b" | grep -q 'SWIFT draft kept aside' && sw=1
case "$out" in
  'sent: herdr '*) [ "$a" = 1 ] && [ "$left" = 0 ] && [ "$sw" = 1 ] && RES+=("H4 pass (sent+submitted, draft back)") || RES+=("H4 FAIL (sent but a=$a left=$left draft=$sw)") ;;
  'mailbox: '*) mb=${out#mailbox: }; [ -f "$mb" ] && grep -q IBISH "$mb" && [ "$a" = 0 ] && [ "$left" = 0 ] && [ "$sw" = 1 ] && RES+=("H4 pass (mailbox, draft restored)") || RES+=("H4 FAIL (mailbox a=$a left=$left draft=$sw)") ;;
  *) RES+=("H4 UNCONFIRMED/other ($out a=$a left=$left draft=$sw)") ;;
esac

# H5: a ~960-char message past a typed draft -> sent, submitted, draft back.
log "== H5: medium message past a typed draft"
clear_box
lab pane send-text "$PANE" 'SWIFT draft kept aside' >/dev/null; sleep 1.2
med='Reply with only the word PIPIT and nothing else. Ignore this filler, which stands in for a voice transcript:'
for i in $(seq 1 16); do med="$med words number $i of a dictated floater message,"; done
log "  message length ${#med}; state before: $(state)"; snap H5-before
out=$(send "$med"); log "  send -> $out"; cat "$LAB/send.err" | tee -a "$LOG"
wait_word PIPIT && a=1 || a=0; sleep 2; snap H5-after
b=$(box); log "  answered=$a box: $(printf '%s' "$b" | head -c 160)"
sub=$(lab pane read "$PANE" --source recent --lines 300 | grep -E '^❯ Reply' | grep -c SWIFT)
case "$out" in
  'sent: herdr '*) [ "$a" = 1 ] && [ "$b" = 'SWIFT draft kept aside' ] && [ "$sub" = 0 ] && RES+=("H5 pass (sent+submitted, draft back)") || RES+=("H5 FAIL (sent but a=$a box=$b sub=$sub)") ;;
  'mailbox: '*) [ "$a" = 0 ] && [ "$b" = 'SWIFT draft kept aside' ] && RES+=("H5 mailbox (draft restored)") || RES+=("H5 FAIL (mailbox a=$a box=$b)") ;;
  *) RES+=("H5 other ($out a=$a)") ;;
esac

log "== summary"; printf '%s\n' "${RES[@]}" | tee -a "$LOG"
