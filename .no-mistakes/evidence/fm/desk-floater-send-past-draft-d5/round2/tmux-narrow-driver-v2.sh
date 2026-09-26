#!/usr/bin/env bash
# Round-2 focused narrow driver: fresh 54-col Claude, busy with the footer showing
# "esc to interrupt", a draft in the box, then a floater send; the screen is sampled
# during the send to catch `› stashed` wrapped onto a row of its own (round-1 failure).
# Usage: tmux-narrow-driver.sh <worktree> <evidence-dir>
set -u
ROOT=$1
EV=$2
DESK="$ROOT/bin/fm-desk-voice.sh"
LAB=$(mktemp -d "${TMPDIR:-/tmp}/fm-lab.XXXXXX")
rmdir "$LAB"
"$ROOT/bin/fm-lab-home.sh" create "$LAB" >/dev/null || { echo "lab create failed"; exit 1; }
mkdir -p "$LAB/tmux" "$LAB/project" "$LAB/notify-bin"
git -C "$LAB/project" init -q
printf '#!/bin/sh\nexit 0\n' > "$LAB/notify-bin/osascript"; chmod +x "$LAB/notify-bin/osascript"
T=fm:0.0
t() { TMUX_TMPDIR="$LAB/tmux" tmux -L fm-lab "$@"; }
LOG="$EV/tmux-narrow-v2-transcript.txt"
: > "$LOG"
log() { printf '%s\n' "$*" | tee -a "$LOG"; }
session_dump() {
  local d f
  d=$(find "$HOME/.claude/projects" -maxdepth 1 -type d -name "*${LAB##*fm-lab.}*" 2>/dev/null | head -n1)
  f=$(ls -t "$d"/*.jsonl 2>/dev/null | head -n1)
  [ -n "$f" ] || { log "no claude session log found"; return; }
  jq -r 'select(.type=="user" or .type=="assistant")
    | [.type, (.message.content | if type=="string" then . else (map(select(.type=="text") | .text) | join(" ")) end)]
    | select(.[1] != "") | "\(.[0])\tlen=\(.[1]|length)\t\(.[1][0:160] | gsub("\n";" "))"' "$f" > "$EV/tmux-narrow-v2-claude-session.tsv"
}
cleanup() { session_dump; t kill-server >/dev/null 2>&1; rm -rf "$LAB"; }
trap cleanup EXIT
screen() { t capture-pane -p -t "$T" 2>/dev/null; }
shot() { { echo "----- screen: $1 (state=$(state)) -----"; screen; echo "----- end -----"; } >> "$LOG"; }
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
idle() { local i; for i in $(seq 1 150); do
    if ! screen | grep -q 'esc to in'; then case "$(state)" in empty|pending) return 0 ;; esac; fi
    sleep 1; done; return 1; }
clearbox() { local i; for i in $(seq 1 60); do [ "$(state)" = empty ] && return 0; t send-keys -t "$T" C-u; sleep 0.2; done; return 1; }
answered() { local i; for i in $(seq 1 120); do screen | grep -q "⏺ $1" && return 0; sleep 1; done; return 1; }
mailbox_empty() { ! ls "$LAB/state/desk-voice/inbox"/* >/dev/null 2>&1; }
RESULTS=()
verdict() { RESULTS+=("$1: $2"); log "RESULT $1: $2"; }

t new-session -d -s fm -x 54 -y 40 -c "$LAB/project" -e FM_HOME="$LAB" -e CLAUDE_CODE_ENABLE_PROMPT_SUGGESTION=true claude || { echo "no claude"; exit 1; }
ready=0
for _ in $(seq 1 60); do
  case "$(screen)" in *'❯ Yes, I trust this folder'*) t send-keys -t "$T" Enter ;; *'Yes, I trust this folder'*) t send-keys -t "$T" Down ;; esac
  [ "$(state)" = empty ] && { ready=1; break; }; sleep 1
done
[ "$ready" = 1 ] || { shot never-ready; echo "claude never ready"; exit 1; }
log "claude: $(claude --version | head -n1)  tmux: $(tmux -V)  worktree HEAD: $(git -C "$ROOT" rev-parse --short HEAD) width=54"
t display-message -p -t "$T" '#{pane_pid}' > "$LAB/state/.lock"
for run in 1 2; do
  t send-keys -t "$T" -l "Write a numbered list of 80 different bird species, one per line, with a two-sentence fact about each. Run $run."
  sleep 0.5; t send-keys -t "$T" Enter
  esc=0; for _ in $(seq 1 180); do screen | grep -av '^ *$' | tail -n 3 | grep -q 'esc to in' && { esc=1; break; }; sleep 0.5; done
  t send-keys -t "$T" -l "CURLEW$run draft"; sleep 1
  busy=0; screen | grep -av '^ *$' | tail -n 3 | grep -q 'esc to in' && busy=1
  log "N$run footer-esc-seen=$esc busy-before-send=$busy state=$(state)"; shot "N$run before send"
  frames="$EV/tmux-narrow-v2-N$run-frames.txt"; : > "$frames"
  ( while [ ! -e "$LAB/stop-sampler" ]; do { echo "=== $(date +%T.%N | cut -c1-12)"; screen | grep -av '^ *$' | tail -n 6; } >> "$frames"; sleep 0.1; done ) &
  sp=$!
  out=$(desk "Reply with only the word ROBIN$run" 2>&1); log "N$run send -> $(printf '%s' "$out" | tr '\n' '|')"
  touch "$LAB/stop-sampler"; wait "$sp"; rm -f "$LAB/stop-sampler"
  wrapped=$(LC_ALL=C grep -ac '^ *› stashed *$' "$frames" || true)
  log "N$run frames sampled=$(LC_ALL=C grep -ac '^===' "$frames") frames-with-stashed-on-own-row=$wrapped"
  shot "N$run right after send"
  got=0; answered "ROBIN$run" && got=1; idle; sleep 2; shot "N$run after the queued message ran"
  c=$(screen | grep -cF "CURLEW$run draft" || true)
  log "N$run after: replied=$got state=$(state) draft-in-box=$c"
  if [ "$busy" = 1 ] && printf '%s' "$out" | grep -q '^sent: tmux' && [ $got = 1 ] && [ "$(state)" = pending ] && [ "$c" = 1 ] && mailbox_empty; then
    verdict "N$run-narrow-busy-past-draft" "pass (stashed-own-row frames=$wrapped)"; else verdict "N$run-narrow-busy-past-draft" "fail (busy=$busy)"; fi
  rm -f "$LAB/state/desk-voice/inbox"/*; clearbox; sleep 15
done
log "==== SUMMARY"; for r in "${RESULTS[@]}"; do log "$r"; done
