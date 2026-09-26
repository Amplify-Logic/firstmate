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
LOG="$EV/tmux-narrow-transcript.txt"
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

t new-session -d -s fm -x 54 -y 40 -c "$LAB/project" -e FM_HOME="$LAB" -e CLAUDE_CODE_ENABLE_PROMPT_SUGGESTION=true claude || { echo "no claude"; exit 1; }
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


full() { { echo "----- $(date +%T) $1 state=$(state) -----"; screen | tail -n 12; echo "----- end -----"; } >> "$LOG"; }
# G: suggested prompt, suggestions explicitly enabled.
t send-keys -t "$T" -l 'Reply with only the word LAPWING'; sleep 0.5; t send-keys -t "$T" Enter
answered LAPWING; sleep 6
{ echo "--- G styled box rows"; t capture-pane -e -p -t "$T" | grep -a '❯' | tail -n 2 | cat -v; } >> "$LOG"
full "G after reply"
out=$(desk 'Reply with only the word ALBATROSS' 2>&1); log "G send -> $out"; answered ALBATROSS; sleep 6; full "G after send"
{ echo "--- G styled box rows after"; t capture-pane -e -p -t "$T" | grep -a '❯' | tail -n 2 | cat -v; } >> "$LOG"
clearbox
# N: narrow tmux pane, mid-turn, draft, send.
t send-keys -t "$T" -l 'Write a numbered list of 60 different bird species, one per line, with a one-sentence fact about each.'
sleep 0.5; t send-keys -t "$T" Enter; sleep 5
t send-keys -t "$T" -l 'CURLEW draft typed while busy'; sleep 1
full "N busy, draft typed"
out=$(desk 'Reply with only the word ROBIN' 2>&1); log "N send -> $(printf '%s' "$out" | tr '\n' '|')"
for i in 1 2 3; do full "N ${i} after send"; sleep 1; done
answered ROBIN; sleep 3; full "N end"
