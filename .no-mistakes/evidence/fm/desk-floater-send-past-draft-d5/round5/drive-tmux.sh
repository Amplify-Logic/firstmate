#!/usr/bin/env bash
# Live driver (round 5, target 45143acc): real bin/fm-desk-voice.sh send against a real Claude
# Code primary in a disposable marked lab home on a private tmux socket.
# Usage: drive-tmux.sh <worktree> <evidence-dir>
set -u
WT=$1 EV=$2
DESK="$WT/bin/fm-desk-voice.sh"
LAB=$(mktemp -d "${TMPDIR:-/tmp}/fm-lab.XXXXXX")
"$WT/bin/fm-lab-home.sh" create "$LAB" >/dev/null || exit 1
mkdir -p "$LAB/tmux" "$LAB/project"; git -C "$LAB/project" init -q
export TMUX_TMPDIR="$LAB/tmux"
t() { tmux -L fm-lab "$@"; }
cleanup() { t kill-server >/dev/null 2>&1; rm -rf "$LAB"; }
trap cleanup EXIT
LOG="$EV/tmux-transcript.txt"; : > "$LOG"
log() { printf '%s\n' "$*" | tee -a "$LOG"; }
screen() { t capture-pane -p -t primary 2>/dev/null; }
scroll() { t capture-pane -p -J -S -2000 -t primary 2>/dev/null; }
snap() { screen > "$EV/tmux-screen-$1.txt"; t capture-pane -e -p -t primary > "$EV/tmux-screen-$1.ansi" 2>/dev/null
  log "  [screen $1]"; screen | grep -v '^[[:space:]]*$' | tail -n 5 | sed 's/^/    | /' | tee -a "$LOG" >/dev/null; }
state() { TMUX="$(t display-message -p '#{socket_path}'),0,0" bash -c '. "$1/bin/fm-backend.sh"; fm_backend_composer_state tmux primary' _ "$WT" 2>/dev/null; }
box() { TMUX="$(t display-message -p '#{socket_path}'),0,0" bash -c '. "$1/bin/fm-backend.sh"; fm_backend_source tmux
  cap=$(fm_backend_capture tmux primary 80) && fm_composer_extract_selected_content styled=0 "$cap"' _ "$WT" 2>/dev/null; }
send() { env -u NO_MISTAKES_GATE -u FM_GATE_REFUSE_BYPASS -u FM_ROOT_OVERRIDE -u FM_STATE_OVERRIDE \
    -u FM_DATA_OVERRIDE -u FM_CONFIG_OVERRIDE -u FM_PROJECTS_OVERRIDE \
    -u TMUX -u TMUX_PANE -u HERDR_ENV -u HERDR_PANE_ID -u HERDR_SOCKET_PATH \
    FM_HOME="$LAB" bash "$DESK" send --source live-driver "$1" 2>"$LAB/send.err"; }
clear_box() { local i; for i in $(seq 1 40); do [ "$(state)" = empty ] && return 0; t send-keys -t primary C-u; sleep 0.2; done; return 1; }
idle() { local i; for i in $(seq 1 90); do screen | grep -q 'esc to interrupt' || return 0; sleep 1; done; return 1; }
RES=()
result() { RES+=("$1: $2"); log "RESULT $1: $2"; }
env -u NO_MISTAKES_GATE -u FM_GATE_REFUSE_BYPASS -u FM_ROOT_OVERRIDE -u FM_STATE_OVERRIDE \
  -u FM_DATA_OVERRIDE -u FM_CONFIG_OVERRIDE -u FM_PROJECTS_OVERRIDE \
  tmux -L fm-lab new-session -d -s primary -x 120 -y 45 -c "$LAB/project" -e FM_HOME="$LAB" "claude --model haiku" || exit 1
ready=0
for _ in $(seq 1 60); do
  case "$(screen)" in
    *'❯ Yes, I trust this folder'*) t send-keys -t primary Enter ;;
    *'Yes, I trust this folder'*) t send-keys -t primary Down ;;
  esac
  [ "$(state)" = empty ] && { ready=1; break; }
  sleep 1
done
[ "$ready" = 1 ] || { log "claude never ready"; screen; exit 1; }
t display-message -p -t primary '#{pane_pid}' > "$LAB/state/.lock"
log "claude $(claude --version | head -1), tmux $(tmux -V), lab $LAB"
sleep 2

# case <tag> <nsentences> <draft-kind typed|paste>
# Pass on `sent`: the submitted prompt in the transcript holds the message's
# head and tail markers, the draft is back in the box (pending) and was never
# submitted, and the message is not left in the box.
lcase() {
  local tag=$1 ns=$2 kind=$3 msg i out head tail draftmark subm left boxnow
  idle; clear_box
  head="HEAD${tag//-/}" tail="TAIL${tag//-/}"
  if [ "$kind" = paste ]; then
    draftmark="pasted log ${tag}"
    printf '%s line A\n%s line B\n%s line C\n%s line D\n%s line E\n' "$draftmark" "$draftmark" "$draftmark" "$draftmark" "$draftmark" > "$LAB/paste.txt"
    t load-buffer -b pb "$LAB/paste.txt"; t paste-buffer -p -b pb -t primary; sleep 1.5
  else
    draftmark="SWIFT draft ${tag} kept aside"
    t send-keys -t primary -l "$draftmark"; sleep 1
  fi
  msg="$head Captain's dictated note, no reply needed beyond a short acknowledgement."
  for i in $(seq 1 "$ns"); do msg="$msg Sentence $i: the calibration log for the lab bench was reviewed and the numbers look steady."; done
  msg="$msg $tail"
  # adversarial: a paste terminator and newlines inside the dictated text
  [ "$tag" = E-esc ] && msg="$head first half"$'\e[201~\n\n'"second half after an injected paste end and a newline $tail"
  log "== $tag: ${#msg}-char message past a $kind draft"
  log "  state before: $(state) box before: $(box | head -c 80)"; snap "$tag-before"
  out=$(send "$msg"); log "  fm-desk-voice send -> $out"; sed 's/^/  stderr: /' "$LAB/send.err" | tee -a "$LOG"
  sleep 3; idle; sleep 1; snap "$tag-after"
  boxnow=$(box)
  subm=0; scroll | grep -q "^❯ $head" && scroll | grep -q "$tail" && subm=1
  # the tail marker only outside the box means it left the box
  left=0; printf '%s' "$boxnow" | grep -q "$head\|$tail" && left=1
  # a typed draft shows once (in the box); a pasted draft never (a placeholder)
  dsub=$(scroll | grep -c "$draftmark" || true)
  log "  box now: $(printf '%s' "$boxnow" | head -c 100)"
  log "  submitted-whole=$subm message-left-in-box=$left draft-lines-in-transcript=$dsub state=$(state)"
  case "$out" in
    'sent: tmux '*)
      if [ "$subm" = 1 ] && [ "$left" = 0 ] && [ "$(state)" = pending ] \
        && { { [ "$kind" = typed ] && [ "$dsub" = 1 ] && [ "$boxnow" = "$draftmark" ]; } \
          || { [ "$kind" = paste ] && [ "$dsub" = 0 ] && printf '%s' "$boxnow" | grep -q '^\[Pasted text #[0-9]* +5 lines\]$'; }; }; then
        result "$tag" "pass (sent, submitted whole, draft back)"
      else result "$tag" "FAIL (sent but subm=$subm left=$left dsub=$dsub box=$(printf '%s' "$boxnow" | head -c 60))"; fi ;;
    *) result "$tag" "FAIL ($out)" ;;
  esac
}
lcase A 0 typed
lcase E-m850 7 typed
lcase E-m1300 13 typed
lcase E-m3200 33 typed
lcase E-m3200p 33 paste
lcase E-esc 0 typed
# C: existing stash -> mailbox, stash and new draft kept (unchanged guard)
idle; clear_box
log "== C: captain already keeps a stash, and has a new draft"
t send-keys -t primary -l 'FALCON stash the captain set aside'; sleep 0.8; t send-keys -t primary C-s; sleep 1
t send-keys -t primary -l 'WREN second draft'; sleep 1; snap C-before
out=$(send 'PLOVER short note'); log "  fm-desk-voice send -> $out"; sleep 2; snap C-after
if [[ $out == 'mailbox: '* ]] && [ "$(box)" = 'WREN second draft' ] && screen | grep -Eq '›[[:space:]]*stashed' && ! scroll | grep -q '^❯ PLOVER'; then
  result C pass; else result C "FAIL ($out box=$(box))"; fi
log "== summary"; printf '%s\n' "${RES[@]}" | tee -a "$LOG"
