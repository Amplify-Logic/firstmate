#!/usr/bin/env bash
# Try to get Claude to draw a dim suggested prompt, then floater-send past it.
set -u
WT=$1 EV=$2
DESK="$WT/bin/fm-desk-voice.sh"
LAB=$(mktemp -d "${TMPDIR:-/tmp}/fm-lab.XXXXXX")
"$WT/bin/fm-lab-home.sh" create "$LAB" >/dev/null || exit 1
mkdir -p "$LAB/tmux" "$LAB/project"; git -C "$LAB/project" init -q
export TMUX_TMPDIR="$LAB/tmux"
t() { tmux -L fm-lab "$@"; }
trap 't kill-server >/dev/null 2>&1; rm -rf "$LAB"' EXIT
LOG="$EV/suggestion-transcript.txt"; : > "$LOG"
log() { printf '%s\n' "$*" | tee -a "$LOG"; }
screen() { t capture-pane -p -t primary 2>/dev/null; }
state() { TMUX="$(t display-message -p '#{socket_path}'),0,0" bash -c '. "$1/bin/fm-backend.sh"; fm_backend_composer_state tmux primary' _ "$WT" 2>/dev/null; }
send() { env -u NO_MISTAKES_GATE -u FM_GATE_REFUSE_BYPASS -u FM_ROOT_OVERRIDE -u FM_STATE_OVERRIDE -u FM_DATA_OVERRIDE -u FM_CONFIG_OVERRIDE -u FM_PROJECTS_OVERRIDE -u TMUX -u TMUX_PANE -u HERDR_ENV -u HERDR_PANE_ID -u HERDR_SOCKET_PATH FM_HOME="$LAB" "$DESK" send --source live-driver "$1" 2>"$LAB/send.err"; }
env -u NO_MISTAKES_GATE -u FM_GATE_REFUSE_BYPASS -u FM_ROOT_OVERRIDE -u FM_STATE_OVERRIDE -u FM_DATA_OVERRIDE -u FM_CONFIG_OVERRIDE -u FM_PROJECTS_OVERRIDE \
  tmux -L fm-lab new-session -d -s primary -x 120 -y 45 -c "$LAB/project" -e FM_HOME="$LAB" "claude --model haiku" || exit 1
for _ in $(seq 1 60); do
  case "$(screen)" in *'❯ Yes, I trust this folder'*) t send-keys -t primary Enter ;; *'Yes, I trust this folder'*) t send-keys -t primary Down ;; esac
  [ "$(state)" = empty ] && break; sleep 1; done
t display-message -p -t primary '#{pane_pid}' > "$LAB/state/.lock"
found=0
for q in 'I have two glasses changes ready. Ask me, in one short sentence, whether I want you to land both.' \
         'Propose one next step as a yes/no question, one line.' \
         'Suggest what I should reply next. One line.'; do
  t send-keys -t primary -l "$q"; sleep 0.5; t send-keys -t primary Enter
  for _ in $(seq 1 40); do sleep 1; screen | grep -q '✻ .* for ' && break; done
  sleep 6
  row=$(t capture-pane -e -p -t primary | grep -F '❯' | tail -1)
  txt=$(screen | grep -F '❯' | tail -1)
  log "after '$q': prompt row text=[$txt] state=$(state)"
  if [ -n "$(printf '%s' "${txt#❯}" | tr -d ' ')" ]; then found=1; break; fi
done
t capture-pane -e -p -t primary > "$EV/screen-suggestion-before.ansi"; screen > "$EV/screen-suggestion-before.txt"
log "prompt row (cat -v): $(printf '%s' "$row" | cat -v)"
[ "$found" = 1 ] || { log "RESULT: Claude drew no suggested prompt in 3 turns"; exit 0; }
log "state with suggestion shown: $(state)"
out=$(send 'Reply with only the word MARTIN'); log "send -> $out"; cat "$LAB/send.err" >> "$LOG"
for _ in $(seq 1 45); do screen | grep -q '⏺ MARTIN' && break; sleep 1; done; sleep 1
screen > "$EV/screen-suggestion-after.txt"; t capture-pane -e -p -t primary > "$EV/screen-suggestion-after.ansi"
ans=0; screen | grep -q '⏺ MARTIN' && ans=1
sub=$(screen | grep -E '^❯ ' | grep -c 'MARTIN' || true)
log "answered=$ans submitted-prompt-lines-with-MARTIN=$sub"
screen | grep -E '^❯ .*MARTIN' | tee -a "$LOG"
[[ $out == 'sent: tmux '* ]] && [ "$ans" = 1 ] && log "RESULT: pass" || log "RESULT: FAIL ($out ans=$ans)"
