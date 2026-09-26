#!/usr/bin/env bash
# Round-2 live driver: real Claude Code in a disposable lab home on a private
# tmux socket, driven through bin/fm-desk-voice.sh send exactly as the floater
# calls it. Wide (120 col) cases, then the same pane narrowed to 54 cols for the
# busy mid-turn case that failed in round 1. Usage: tmux-driver.sh <worktree> <evidence-dir>
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
LOG="$EV/tmux-transcript.txt"
: > "$LOG"
log() { printf '%s\n' "$*" | tee -a "$LOG"; }
session_dump() {
  local d f
  d=$(find "$HOME/.claude/projects" -maxdepth 1 -type d -name "*${LAB##*fm-lab.}*" 2>/dev/null | head -n1)
  f=$(ls -t "$d"/*.jsonl 2>/dev/null | head -n1)
  [ -n "$f" ] || { log "no claude session log found"; return; }
  jq -r 'select(.type=="user" or .type=="assistant")
    | [.type, (.message.content | if type=="string" then . else (map(select(.type=="text") | .text) | join(" ")) end)]
    | select(.[1] != "") | "\(.[0])\tlen=\(.[1]|length)\t\(.[1][0:160] | gsub("\n";" "))"' "$f" > "$EV/tmux-claude-session.tsv"
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

t new-session -d -s fm -x 120 -y 45 -c "$LAB/project" -e FM_HOME="$LAB" -e CLAUDE_CODE_ENABLE_PROMPT_SUGGESTION=true claude || { echo "no claude"; exit 1; }
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
log "claude: $(claude --version | head -n1)  tmux: $(tmux -V)  worktree HEAD: $(git -C "$ROOT" rev-parse --short HEAD)"
t display-message -p -t "$T" '#{pane_pid}' > "$LAB/state/.lock"

# ---- T1 the reported failure: grey suggested prompt the captain never typed.
t send-keys -t "$T" -l 'Reply with only the word LAPWING'; sleep 0.5; t send-keys -t "$T" Enter
answered LAPWING; idle; sleep 6
shot "T1 before send (grey suggested prompt?)"
{ echo "--- T1 styled box row"; t capture-pane -e -p -t "$T" | grep -a '❯' | tail -n1 | cat -v; } >> "$LOG"
out=$(desk 'Reply with only the word ALBATROSS' 2>&1); log "T1 send -> $out"
if answered ALBATROSS && printf '%s' "$out" | grep -q '^sent: tmux' && mailbox_empty; then verdict T1-suggested-prompt pass; else verdict T1-suggested-prompt fail; fi
idle; shot "T1 after send"; clearbox

long_msg() { local m="Ignore every filler word after this first sentence and reply with only the word $1."
  while [ "${#m}" -lt "$2" ]; do m="$m lorem ipsum dolor sit amet filler"; done; printf '%s' "${m:0:$2}"; }
case_draft() {  # <id> <word> <len> <draft>
  local id=$1 word=$2 len=$3 draft=$4 msg out c got=0
  if [ "$len" -lt 100 ]; then msg="Reply with only the word $word"; else msg=$(long_msg "$word" "$len"); fi
  t send-keys -t "$T" -l "$draft"; sleep 1
  log "$id draft typed; state=$(state); message length=${#msg}"
  shot "$id before send"
  out=$(desk "$msg" 2>&1); log "$id send -> $(printf '%s' "$out" | tr '\n' '|')"
  answered "$word" && got=1; idle; sleep 1; shot "$id after send"
  c=$(screen | grep -cF "$draft" || true)
  log "$id after: state=$(state) draft-occurrences-on-screen=$c claude-replied-$word=$got"
  if printf '%s' "$out" | grep -q '^sent: tmux' && [ "$(state)" = pending ] && [ "$c" = 1 ] && mailbox_empty; then
    verdict "$id" pass; else verdict "$id" fail; fi
  clearbox
}
case_draft T2-short-past-draft OSPREY 40 'KESTREL draft the captain has not sent'
case_draft T3-long-1300-past-draft HERON 1300 'MERLIN draft two the captain has not sent'
case_draft T4-long-3200-past-draft EGRET 3200 'HOBBY draft three the captain has not sent'

# ---- T5 adversarial: the captain already keeps a stash; never overwrite it.
t send-keys -t "$T" -l 'PLOVER stash the captain keeps'; sleep 0.7
t send-keys -t "$T" C-s; sleep 1.5
t send-keys -t "$T" -l 'WREN second draft in the box'; sleep 1
shot "T5 before send (footer should show stashed)"
out=$(desk 'Reply with only the word GANNET' 2>&1); log "T5 send -> $(printf '%s' "$out" | tr '\n' '|')"
sleep 3; shot "T5 after send"
box_ok=0; screen | grep -qF 'WREN second draft in the box' && box_ok=1
no_reply=1; screen | grep -q '⏺ GANNET' && no_reply=0
mb=$(ls "$LAB/state/desk-voice/inbox"/* 2>/dev/null | head -n1)
log "T5 mailbox file: ${mb:-none}"; [ -n "$mb" ] && { echo "--- T5 mailbox content"; cat "$mb"; echo; } >> "$LOG"
clearbox; t send-keys -t "$T" C-s; sleep 1.5; shot "T5 after Ctrl+S on empty box (stash must be PLOVER)"
stash_ok=0; screen | grep -qF 'PLOVER stash the captain keeps' && stash_ok=1
log "T5 box-kept=$box_ok no-reply=$no_reply stash-kept=$stash_ok"
if printf '%s' "$out" | grep -q '^mailbox: ' && [ -n "$mb" ] && [ $box_ok = 1 ] && [ $no_reply = 1 ] && [ $stash_ok = 1 ]; then
  verdict T5-existing-stash-goes-to-mailbox pass; else verdict T5-existing-stash-goes-to-mailbox fail; fi
rm -f "$LAB/state/desk-voice/inbox"/*; clearbox

# ---- T6 the draft is only a pasted-text placeholder.
printf 'SANDERLING line one\nline two\nline three\nline four\n' | t load-buffer -b p -
t paste-buffer -p -d -b p -t "$T"; sleep 1.5
shot "T6 before send (placeholder draft)"
out=$(desk 'Reply with only the word PUFFIN' 2>&1); log "T6 send -> $(printf '%s' "$out" | tr '\n' '|')"
answered PUFFIN; idle; sleep 1; shot "T6 after send"
if printf '%s' "$out" | grep -q '^sent: tmux' && screen | grep -q '⏺ PUFFIN' && [ "$(state)" = pending ] \
  && screen | grep -E '❯' | tail -n1 | grep -q 'Pasted text' && mailbox_empty; then
  verdict T6-pasted-text-draft pass; else verdict T6-pasted-text-draft fail; fi
clearbox

# ---- N narrow (54 cols) busy mid-turn: the round-1 failure.
t resize-window -t fm -x 54 -y 40; sleep 2
for run in 1 2; do
  t send-keys -t "$T" -l "Write a numbered list of 60 different bird species, one per line, with a one-sentence fact about each. Run $run."
  sleep 0.5; t send-keys -t "$T" Enter; sleep 5
  t send-keys -t "$T" -l "CURLEW$run draft typed while busy"; sleep 1
  busy=0; screen | grep -q 'esc to in' && busy=1
  log "N$run busy-before-send=$busy state=$(state)"; shot "N$run before send"
  out=$(desk "Reply with only the word ROBIN$run" 2>&1); log "N$run send -> $(printf '%s' "$out" | tr '\n' '|')"
  shot "N$run right after send"
  got=0; answered "ROBIN$run" && got=1; idle; sleep 2; shot "N$run after the queued message ran"
  c=$(screen | grep -cF "CURLEW$run draft typed while busy" || true)
  log "N$run after: replied=$got state=$(state) draft-in-box=$c stash-footer=$(screen | grep -c 'stashed' || true)"
  if [ "$busy" = 1 ] && printf '%s' "$out" | grep -q '^sent: tmux' && [ $got = 1 ] && [ "$(state)" = pending ] && [ "$c" = 1 ] && mailbox_empty; then
    verdict "N$run-narrow-mid-turn-past-draft" pass; else verdict "N$run-narrow-mid-turn-past-draft" fail; fi
  rm -f "$LAB/state/desk-voice/inbox"/*; clearbox
done

log "==== SUMMARY"; for r in "${RESULTS[@]}"; do log "$r"; done
