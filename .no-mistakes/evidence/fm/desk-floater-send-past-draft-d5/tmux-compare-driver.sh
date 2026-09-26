#!/usr/bin/env bash
# Comparison + suggested-prompt driver on a real Claude in a private tmux lab.
# C1: a 1300-char floater message into an EMPTY box (the pre-existing typed
#     path, unchanged by this branch): how does it reach Claude?
# C2: a 1300-char message past a draft whose instruction the captain would
#     plausibly speak (not a "reply with X" test token): does Claude act on it?
# G1: try to make Claude show a grey suggested prompt, then send.
# Usage: tmux-compare-driver.sh <worktree> <evidence-dir>
set -u
ROOT=$1; EV=$2; DESK="$ROOT/bin/fm-desk-voice.sh"
LAB=$(mktemp -d "${TMPDIR:-/tmp}/fm-lab.XXXXXX"); rmdir "$LAB"
"$ROOT/bin/fm-lab-home.sh" create "$LAB" >/dev/null || exit 1
mkdir -p "$LAB/tmux" "$LAB/project" "$LAB/notify-bin"; git -C "$LAB/project" init -q
printf '#!/bin/sh\nexit 0\n' > "$LAB/notify-bin/osascript"; chmod +x "$LAB/notify-bin/osascript"
T=fm:0.0
t() { TMUX_TMPDIR="$LAB/tmux" tmux -L fm-lab "$@"; }
LOG="$EV/tmux-compare-transcript.txt"; : > "$LOG"
log() { printf '%s\n' "$*" | tee -a "$LOG"; }
cleanup() {
  local f; f=$(ls -t "$HOME"/.claude/projects/*"$(basename "$LAB")"*/*.jsonl 2>/dev/null | head -n1)
  [ -n "$f" ] && jq -r 'select(.type=="user" or .type=="assistant") | [.type, (.message.content|if type=="string" then .[0:240] else (map(.type + ":" + ((.text // "")|tostring|.[0:240]))|join(" | ")) end)] | @tsv' "$f" > "$EV/tmux-compare-claude-session.tsv" 2>/dev/null
  t kill-server >/dev/null 2>&1; rm -rf "$LAB"; }
trap cleanup EXIT
screen() { t capture-pane -p -t "$T" 2>/dev/null; }
shot() { { echo "----- screen: $1 -----"; screen; echo "----- end -----"; } >> "$LOG"; }
state() { TMUX="$(t display-message -p '#{socket_path}'),0,0" bash -c '. "$1/bin/fm-backend.sh"; fm_backend_composer_state tmux fm:0.0' _ "$ROOT" 2>/dev/null; }
desk() { env -u NO_MISTAKES_GATE -u FM_GATE_REFUSE_BYPASS -u FM_ROOT_OVERRIDE -u FM_STATE_OVERRIDE -u FM_DATA_OVERRIDE \
  -u FM_CONFIG_OVERRIDE -u FM_PROJECTS_OVERRIDE -u TMUX -u TMUX_PANE -u HERDR_ENV -u HERDR_PANE_ID -u HERDR_SOCKET_PATH -u HERDR_SESSION \
  PATH="$LAB/notify-bin:$PATH" FM_HOME="$LAB" "$DESK" send --source live-test "$@"; }
settle() { local i; for i in $(seq 1 90); do sleep 1; screen | grep -q '✻ .* for .*· done' && [ "$(screen | grep -c '✻ .* for .*· done')" -ge "$1" ] && return 0; done; return 1; }
clearbox() { local i; for i in $(seq 1 40); do [ "$(state)" = empty ] && return 0; t send-keys -t "$T" C-u; sleep 0.2; done; }
filler() { local m=$1; while [ "${#m}" -lt "$2" ]; do m="$m and please also keep in mind that the glasses changes are both small"; done; printf '%s' "${m:0:$2}"; }

t new-session -d -s fm -x 120 -y 45 -c "$LAB/project" -e FM_HOME="$LAB" claude || exit 1
for _ in $(seq 1 60); do
  case "$(screen)" in *'❯ Yes, I trust this folder'*) t send-keys -t "$T" Enter ;; *'Yes, I trust this folder'*) t send-keys -t "$T" Down ;; esac
  [ "$(state)" = empty ] && break; sleep 1
done
log "claude: $(claude --version | head -n1)"
t display-message -p -t "$T" '#{pane_pid}' > "$LAB/state/.lock"

# G1: ask something whose natural follow-up Claude tends to suggest.
t send-keys -t "$T" -l 'I have two small glasses changes ready to land. Should I land both? Answer in one short sentence and end by asking me whether to go ahead.'
sleep 0.5; t send-keys -t "$T" Enter; settle 1; sleep 4
shot "G1 after reply (grey suggested prompt?)"
log "G1 box (styled): $(t capture-pane -e -p -t "$T" | grep '❯' | tail -n1 | cat -v)"
log "G1 composer state: $(state)"
out=$(desk 'Reply with only the word ALBATROSS' 2>&1); log "G1 send -> $out"
sleep 12; shot "G1 after send"

# C1: long message into an empty box, the unchanged typed path.
clearbox
msg=$(filler 'Captain here. Please reply with only the word HERON so I know you got this long voice note' 1300)
log "C1 state before=$(state) len=${#msg}"
out=$(desk "$msg" 2>&1); log "C1 send (empty box) -> $out"
sleep 20; shot "C1 after send"

# C2: same shape, past a typed draft (this branch's paste path).
clearbox
t send-keys -t "$T" -l 'KESTREL draft the captain has not sent'; sleep 1
msg=$(filler 'Captain here. Please reply with only the word EGRET so I know you got this long voice note' 1300)
log "C2 state before=$(state) len=${#msg}"
out=$(desk "$msg" 2>&1); log "C2 send (past draft) -> $out"
sleep 20; shot "C2 after send"
log "C2 state after=$(state)"
