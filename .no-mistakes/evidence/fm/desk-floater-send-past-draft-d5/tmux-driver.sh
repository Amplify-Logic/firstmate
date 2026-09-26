#!/usr/bin/env bash
# Live driver: real Claude Code in a disposable lab home on a private tmux
# socket, driven through bin/fm-desk-voice.sh send exactly as the floater
# calls it. Usage: tmux-driver.sh <worktree> <evidence-dir>
set -u
ROOT=$1
EV=$2
DESK="$ROOT/bin/fm-desk-voice.sh"
LAB=$(mktemp -d "${TMPDIR:-/tmp}/fm-lab.XXXXXX")
rmdir "$LAB"
"$ROOT/bin/fm-lab-home.sh" create "$LAB" >/dev/null || { echo "lab create failed"; exit 1; }
mkdir -p "$LAB/tmux" "$LAB/project" "$LAB/notify-bin"
git -C "$LAB/project" init -q
# A mailbox send raises a macOS notification; keep it off the captain's screen.
printf '#!/bin/sh\nexit 0\n' > "$LAB/notify-bin/osascript"; chmod +x "$LAB/notify-bin/osascript"
T=fm:0.0
t() { TMUX_TMPDIR="$LAB/tmux" tmux -L fm-lab "$@"; }
cleanup() { t kill-server >/dev/null 2>&1; rm -rf "$LAB"; }
trap cleanup EXIT
LOG="$EV/tmux-driver-transcript.txt"
: > "$LOG"
log() { printf '%s\n' "$*" | tee -a "$LOG"; }
screen() { t capture-pane -p -t "$T" 2>/dev/null; }
shot() { { echo "----- screen: $1 -----"; screen; echo "----- end -----"; } >> "$LOG"; }
state() {
  TMUX="$(t display-message -p '#{socket_path}'),0,0" bash -c '
    . "$1/bin/fm-backend.sh"; fm_backend_composer_state tmux fm:0.0' _ "$ROOT" 2>/dev/null
}
desk() {
  env -u NO_MISTAKES_GATE -u FM_GATE_REFUSE_BYPASS -u FM_ROOT_OVERRIDE -u FM_STATE_OVERRIDE \
    -u FM_DATA_OVERRIDE -u FM_CONFIG_OVERRIDE -u FM_PROJECTS_OVERRIDE \
    -u TMUX -u TMUX_PANE -u HERDR_ENV -u HERDR_PANE_ID -u HERDR_SOCKET_PATH -u HERDR_SESSION \
    PATH="$LAB/notify-bin:$PATH" FM_HOME="$LAB" "$DESK" send --source live-test "$@"
}
idle() {  # wait for the turn to end and the box to be readable
  local i
  for i in $(seq 1 120); do
    if ! screen | grep -q 'esc to interrupt'; then
      case "$(state)" in empty|pending) return 0 ;; esac
    fi
    sleep 1
  done
  return 1
}
clearbox() {
  local i
  for i in $(seq 1 40); do
    [ "$(state)" = empty ] && return 0
    t send-keys -t "$T" C-u; sleep 0.2
  done
  return 1
}
answered() {  # <word>
  local i
  for i in $(seq 1 120); do
    screen | grep -q "⏺ $1" && return 0
    sleep 1
  done
  return 1
}
RESULTS=()
verdict() { RESULTS+=("$1: $2"); log "RESULT $1: $2"; }

t new-session -d -s fm -x 120 -y 45 -c "$LAB/project" -e FM_HOME="$LAB" claude || { echo "no claude"; exit 1; }
ready=0
for _ in $(seq 1 60); do
  case "$(screen)" in
    *'❯ Yes, I trust this folder'*) t send-keys -t "$T" Enter ;;
    *'Yes, I trust this folder'*) t send-keys -t "$T" Down ;;
  esac
  [ "$(state)" = empty ] && { ready=1; break; }
  sleep 1
done
[ "$ready" = 1 ] || { shot never-ready; echo "claude never ready"; exit 1; }
log "claude: $(claude --version | head -n1)"
t display-message -p -t "$T" '#{pane_pid}' > "$LAB/state/.lock"

# ---- S1 warm-up turn, then the grey suggested prompt (the reported failure).
t send-keys -t "$T" -l 'Reply with only the word LAPWING'; sleep 0.5; t send-keys -t "$T" Enter
answered LAPWING; idle; sleep 3
shot "S1 after warm-up (look for a grey suggested prompt in the box)"
ghost=$(t capture-pane -e -p -t "$T" | grep -E '❯' | tail -n1)
log "S1 box line with styles: $(printf '%q' "$ghost")"
log "S1 composer state: $(state)"
out=$(desk 'Reply with only the word ALBATROSS' 2>&1); log "S1 send -> $out"
if answered ALBATROSS && printf '%s' "$out" | grep -q '^sent: tmux'; then verdict S1-suggested-prompt pass; else verdict S1-suggested-prompt fail; fi
idle; shot "S1 after send"; clearbox

# ---- S2..S3 long messages past a typed draft.
long_msg() {  # <word> <length>
  local m="Ignore every filler word after this first sentence and reply with only the word $1."
  while [ "${#m}" -lt "$2" ]; do m="$m lorem ipsum dolor sit amet filler"; done
  printf '%s' "${m:0:$2}"
}
long_case() {  # <id> <word> <len> <draft>
  local id=$1 word=$2 len=$3 draft=$4 msg out c
  msg=$(long_msg "$word" "$len")
  t send-keys -t "$T" -l "$draft"; sleep 1
  log "$id draft typed; state=$(state); message length=${#msg}"
  out=$(desk "$msg" 2>&1); log "$id send -> $out"
  answered "$word"; idle; sleep 1; shot "$id after send"
  c=$(screen | grep -cF "$draft" || true)
  log "$id after: state=$(state) draft-occurrences=$c"
  if printf '%s' "$out" | grep -q '^sent: tmux' && screen | grep -q "⏺ $word" \
    && [ "$(state)" = pending ] && [ "$c" = 1 ] && ! ls "$LAB/state/desk-voice/inbox"/* >/dev/null 2>&1; then
    verdict "$id" pass
  else verdict "$id" fail; fi
  clearbox
}
long_case S2-long-1300-past-draft HERON 1300 'KESTREL draft one the captain has not sent'
long_case S3-long-3200-past-draft EGRET 3200 'MERLIN draft two the captain has not sent'
long_case S3b-short-past-draft OSPREY 40 'HOBBY draft three the captain has not sent'

# ---- S4 adversarial: the captain already keeps a stash; never overwrite it.
t send-keys -t "$T" -l 'PLOVER stash the captain keeps'; sleep 0.7
t send-keys -t "$T" C-s; sleep 1.5
t send-keys -t "$T" -l 'WREN second draft in the box'; sleep 1
shot "S4 before send (footer should show stashed)"
out=$(desk 'Reply with only the word GANNET' 2>&1); log "S4 send -> $out"
sleep 3; shot "S4 after send"
box_ok=0; screen | grep -qF 'WREN second draft in the box' && box_ok=1
no_reply=1; screen | grep -q '⏺ GANNET' && no_reply=0
mb=$(ls "$LAB/state/desk-voice/inbox"/* 2>/dev/null | head -n1)
log "S4 mailbox file: ${mb:-none}"; [ -n "$mb" ] && { echo "--- S4 mailbox content"; cat "$mb"; } >> "$LOG"
clearbox; t send-keys -t "$T" C-s; sleep 1.5; shot "S4 after Ctrl+S on empty box (stash must be PLOVER)"
stash_ok=0; screen | grep -qF 'PLOVER stash the captain keeps' && stash_ok=1
log "S4 box-kept=$box_ok no-reply=$no_reply stash-kept=$stash_ok"
if printf '%s' "$out" | grep -q '^mailbox: ' && [ -n "$mb" ] && [ $box_ok = 1 ] && [ $no_reply = 1 ] && [ $stash_ok = 1 ]; then
  verdict S4-existing-stash-goes-to-mailbox pass; else verdict S4-existing-stash-goes-to-mailbox fail; fi
rm -f "$LAB/state/desk-voice/inbox"/*
clearbox

# ---- S5 the draft is only a pasted-text placeholder.
printf 'SANDERLING line one\nline two\nline three\nline four\n' | t load-buffer -b p -
t paste-buffer -p -d -b p -t "$T"; sleep 1.5
shot "S5 before send (box should show a [Pasted text #N] placeholder)"
out=$(desk 'Reply with only the word PUFFIN' 2>&1); log "S5 send -> $out"
answered PUFFIN; idle; sleep 1; shot "S5 after send"
if printf '%s' "$out" | grep -q '^sent: tmux' && screen | grep -q '⏺ PUFFIN' && [ "$(state)" = pending ] \
  && screen | grep -E '❯' | tail -n1 | grep -q 'Pasted text'; then
  verdict S5-pasted-text-draft pass; else verdict S5-pasted-text-draft fail; fi
clearbox

# ---- S6 mid-turn: Claude is busy, the captain types a draft, a message arrives.
t send-keys -t "$T" -l 'Write a numbered list of 60 different bird species, one per line, with a one-sentence fact about each.'
sleep 0.5; t send-keys -t "$T" Enter; sleep 4
t send-keys -t "$T" -l 'CURLEW draft typed while busy'; sleep 1
busy=0; screen | grep -q 'esc to interrupt' && busy=1
log "S6 busy-before-send=$busy state=$(state)"
shot "S6 before send (mid-turn)"
out=$(desk 'Reply with only the word ROBIN' 2>&1); log "S6 send -> $out"
shot "S6 right after send"
answered ROBIN; idle; sleep 1; shot "S6 after the queued message ran"
c=$(screen | grep -cF 'CURLEW draft typed while busy' || true)
if [ "$busy" = 1 ] && printf '%s' "$out" | grep -q '^sent: tmux' && screen | grep -q '⏺ ROBIN' && [ "$(state)" = pending ] && [ "$c" = 1 ]; then
  verdict S6-mid-turn-past-draft pass; else verdict S6-mid-turn-past-draft fail; fi

log "==== SUMMARY"; for r in "${RESULTS[@]}"; do log "$r"; done
