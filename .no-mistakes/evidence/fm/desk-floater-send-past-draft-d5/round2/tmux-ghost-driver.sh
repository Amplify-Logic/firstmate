#!/usr/bin/env bash
# Round-2 live driver for the reported failure: the Claude box shows a grey
# suggested prompt the captain never typed, and a floater message arrives.
# Real Claude in a disposable lab home on a private fm-lab tmux socket.
# Usage: tmux-ghost-driver.sh <worktree> <evidence-dir>
set -u
ROOT=$1; EV=$2
DESK="$ROOT/bin/fm-desk-voice.sh"
LAB=$(mktemp -d "${TMPDIR:-/tmp}/fm-lab.XXXXXX"); rmdir "$LAB"
"$ROOT/bin/fm-lab-home.sh" create "$LAB" >/dev/null || { echo "lab create failed"; exit 1; }
mkdir -p "$LAB/tmux" "$LAB/project" "$LAB/notify-bin"; git -C "$LAB/project" init -q
printf '#!/bin/sh\nexit 0\n' > "$LAB/notify-bin/osascript"; chmod +x "$LAB/notify-bin/osascript"
T=fm:0.0
t() { TMUX_TMPDIR="$LAB/tmux" tmux -L fm-lab "$@"; }
LOG="$EV/tmux-ghost-transcript.txt"; : > "$LOG"
log() { printf '%s\n' "$*" | tee -a "$LOG"; }
session_dump() {
  local d f
  d=$(find "$HOME/.claude/projects" -maxdepth 1 -type d -name "*${LAB##*fm-lab.}*" 2>/dev/null | head -n1)
  f=$(ls -t "$d"/*.jsonl 2>/dev/null | head -n1)
  [ -n "$f" ] || { log "no claude session log found"; return; }
  jq -r 'select(.type=="user" or .type=="assistant")
    | [.type, (.message.content | if type=="string" then . else (map(select(.type=="text") | .text) | join(" ")) end)]
    | select(.[1] != "") | "\(.[0])\tlen=\(.[1]|length)\t\(.[1][0:160] | gsub("\n";" "))"' "$f" > "$EV/tmux-ghost-claude-session.tsv"
}
cleanup() { session_dump; t kill-server >/dev/null 2>&1; rm -rf "$LAB"; }
trap cleanup EXIT
screen() { t capture-pane -p -t "$T" 2>/dev/null; }
styled_box() { t capture-pane -e -p -t "$T" | LC_ALL=C grep -a '❯' | tail -n1; }
shot() { { echo "----- screen: $1 (state=$(state)) -----"; screen; echo "--- styled box row:"; styled_box | cat -v; echo "----- end -----"; } >> "$LOG"; }
state() { TMUX="$(t display-message -p '#{socket_path}'),0,0" bash -c '. "$1/bin/fm-backend.sh"; fm_backend_composer_state tmux fm:0.0' _ "$ROOT" 2>/dev/null; }
desk() {
  env -u NO_MISTAKES_GATE -u FM_GATE_REFUSE_BYPASS -u FM_ROOT_OVERRIDE -u FM_STATE_OVERRIDE \
    -u FM_DATA_OVERRIDE -u FM_CONFIG_OVERRIDE -u FM_PROJECTS_OVERRIDE \
    -u TMUX -u TMUX_PANE -u HERDR_ENV -u HERDR_PANE_ID -u HERDR_SOCKET_PATH -u HERDR_SESSION \
    PATH="$LAB/notify-bin:$PATH" FM_HOME="$LAB" "$DESK" send --source live-test "$@"
}
idle() { local i; for i in $(seq 1 150); do
    if ! screen | grep -q 'esc to in'; then case "$(state)" in empty|pending) return 0 ;; esac; fi; sleep 1; done; return 1; }
answered() { local i; for i in $(seq 1 120); do screen | grep -q "⏺ $1" && return 0; sleep 1; done; return 1; }
ghost_shown() { styled_box | LC_ALL=C grep -aq $'\e\\[2m[^ ]'; }
RESULTS=(); verdict() { RESULTS+=("$1: $2"); log "RESULT $1: $2"; }

t new-session -d -s fm -x 120 -y 45 -c "$LAB/project" -e FM_HOME="$LAB" claude || { echo "no claude"; exit 1; }
ready=0
for _ in $(seq 1 60); do
  case "$(screen)" in *'❯ Yes, I trust this folder'*) t send-keys -t "$T" Enter ;; *'Yes, I trust this folder'*) t send-keys -t "$T" Down ;; esac
  [ "$(state)" = empty ] && { ready=1; break; }; sleep 1
done
[ "$ready" = 1 ] || { shot never-ready; echo "claude never ready"; exit 1; }
log "claude: $(claude --version | head -n1)  worktree HEAD: $(git -C "$ROOT" rev-parse --short HEAD)"
t display-message -p -t "$T" '#{pane_pid}' > "$LAB/state/.lock"

words=(ALBATROSS CORMORANT)
for n in 1 2; do
  got_ghost=0
  for attempt in 1 2 3; do
    t send-keys -t "$T" -l 'List three fruit names, one per line, nothing else.'; sleep 0.5; t send-keys -t "$T" Enter; idle; sleep 2
    t send-keys -t "$T" -l 'I want to write hello.txt with one of those fruits in it. Propose which fruit and ask me to confirm before writing anything.'
    sleep 0.5; t send-keys -t "$T" Enter; idle
    for _ in $(seq 1 20); do ghost_shown && { got_ghost=1; break; }; sleep 1; done
    [ $got_ghost = 1 ] && break
  done
  w=${words[$((n-1))]}
  shot "G$n before send (grey suggestion shown=$got_ghost)"
  log "G$n state-before=$(state)"
  out=$(desk "Reply with only the word $w" 2>&1); log "G$n send -> $(printf '%s' "$out" | tr '\n' '|')"
  got=0; answered "$w" && got=1; idle; sleep 2; shot "G$n after send"
  mb=0; ls "$LAB/state/desk-voice/inbox"/* >/dev/null 2>&1 && mb=1
  log "G$n replied=$got mailbox-used=$mb"
  if [ $got_ghost = 1 ] && printf '%s' "$out" | grep -q '^sent: tmux' && [ $got = 1 ] && [ $mb = 0 ]; then
    verdict "G$n-suggested-prompt" pass
  elif [ $got_ghost = 0 ]; then verdict "G$n-suggested-prompt" "not-exercised (no suggestion appeared)"
  else verdict "G$n-suggested-prompt" fail; fi
  rm -f "$LAB/state/desk-voice/inbox"/*
done
log "==== SUMMARY"; for r in "${RESULTS[@]}"; do log "$r"; done
