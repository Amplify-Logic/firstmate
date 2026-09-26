#!/usr/bin/env bash
# Live driver: real bin/fm-desk-voice.sh send against a real Claude Code
# primary in a disposable marked lab home on a private tmux socket.
# Usage: drive-desk-floater-claude.sh <worktree> <evidence-dir>
set -u
WT=$1 EV=$2
DESK="$WT/bin/fm-desk-voice.sh"
LAB=$(mktemp -d "${TMPDIR:-/tmp}/fm-lab.XXXXXX")
"$WT/bin/fm-lab-home.sh" create "$LAB" >/dev/null || exit 1
mkdir -p "$LAB/tmux" "$LAB/project"
git -C "$LAB/project" init -q
export TMUX_TMPDIR="$LAB/tmux"
t() { tmux -L fm-lab "$@"; }
cleanup() { t kill-server >/dev/null 2>&1; rm -rf "$LAB"; }
trap cleanup EXIT
LOG="$EV/driver-transcript.txt"
: > "$LOG"
log() { printf '%s\n' "$*" | tee -a "$LOG"; }
screen() { t capture-pane -p -t primary 2>/dev/null; }
snap() {  # <name>: plain + ANSI capture of the pane
  screen > "$EV/screen-$1.txt"
  t capture-pane -e -p -t primary > "$EV/screen-$1.ansi" 2>/dev/null
  log "  [screen $1] box/footer:"
  screen | grep -v '^[[:space:]]*$' | tail -n 6 | sed 's/^/    | /' | tee -a "$LOG" >/dev/null
  screen | grep -v '^[[:space:]]*$' | tail -n 6 | sed 's/^/    | /'
}
state() {
  TMUX="$(t display-message -p '#{socket_path}'),0,0" bash -c '
    . "$1/bin/fm-backend.sh"; fm_backend_composer_state tmux primary' _ "$WT" 2>/dev/null
}
send() {  # <message>
  env -u NO_MISTAKES_GATE -u FM_GATE_REFUSE_BYPASS -u FM_ROOT_OVERRIDE -u FM_STATE_OVERRIDE \
    -u FM_DATA_OVERRIDE -u FM_CONFIG_OVERRIDE -u FM_PROJECTS_OVERRIDE \
    -u TMUX -u TMUX_PANE -u HERDR_ENV -u HERDR_PANE_ID -u HERDR_SOCKET_PATH \
    FM_HOME="$LAB" bash ${TRACE:+-x} "$DESK" send --source live-driver "$1" 2>"$LAB/send.err"
}
wait_answer() {  # <word>
  local i
  for i in $(seq 1 60); do screen | grep -q "⏺ $1" && return 0; sleep 1; done
  return 1
}
clear_box() {
  local i
  for i in $(seq 1 30); do [ "$(state)" = empty ] && return 0; t send-keys -t primary C-u; sleep 0.2; done
  return 1
}
RES=()
result() { RES+=("$1: $2"); log "RESULT $1: $2"; }

env -u NO_MISTAKES_GATE -u FM_GATE_REFUSE_BYPASS -u FM_ROOT_OVERRIDE -u FM_STATE_OVERRIDE \
  -u FM_DATA_OVERRIDE -u FM_CONFIG_OVERRIDE -u FM_PROJECTS_OVERRIDE \
  tmux -L fm-lab new-session -d -s primary -x 120 -y 45 -c "$LAB/project" -e FM_HOME="$LAB" \
  "claude --model haiku" || exit 1
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
log "claude $(claude --version | head -1), lab $LAB, lock pid $(cat "$LAB/state/.lock")"
sleep 2

# --- A: typed draft in the box -> message sent alone, draft put back ---------
log "== A: typed draft in the Claude box"
DRAFT_A='KESTREL draft the captain has not sent'
t send-keys -t primary -l "$DRAFT_A"; sleep 1
log "  state before: $(state)"; snap A-before
out=$(send 'Reply with only the word OSPREY'); log "  fm-desk-voice send -> $out"; sed 's/^/  stderr: /' "$LAB/send.err" | tee -a "$LOG"
wait_answer OSPREY && ans=1 || ans=0; sleep 1
log "  answered=$ans state after: $(state)"; snap A-after
n=$(screen | grep -cF "$DRAFT_A")
if [[ $out == 'sent: tmux '* ]] && [ "$ans" = 1 ] && [ "$(state)" = pending ] && [ "$n" = 1 ] \
  && ! screen | grep -F OSPREY | grep -q KESTREL; then result A pass; else result A "FAIL (out=$out ans=$ans draftcount=$n)"; fi
clear_box

# --- B: only a dim suggested prompt / placeholder -> reads empty, straight in -
log "== B: box shows only Claude's dim suggestion"
sleep 3
log "  state before: $(state)"; snap B-before
dim=$(t capture-pane -e -p -t primary | grep -F '❯' | tail -1 | cat -v)
log "  prompt row (ANSI via cat -v): $dim"
out=$(send 'Reply with only the word HERON'); log "  fm-desk-voice send -> $out"; sed 's/^/  stderr: /' "$LAB/send.err" | tee -a "$LOG"
wait_answer HERON && ans=1 || ans=0; sleep 1; snap B-after
if [[ $out == 'sent: tmux '* ]] && [ "$ans" = 1 ]; then result B pass; else result B "FAIL (out=$out ans=$ans)"; fi
clear_box

# --- C: adversarial: footer already shows a stash -> mailbox, stash kept ------
log "== C: captain already keeps a stash, and has a new draft"
t send-keys -t primary -l 'FALCON stash the captain set aside'; sleep 0.8
t send-keys -t primary C-s; sleep 1
t send-keys -t primary -l 'WREN second draft'; sleep 1
log "  state before: $(state)"; snap C-before
before_inbox=$(ls "$LAB/state/desk-voice/inbox" 2>/dev/null | wc -l | tr -d ' ')
out=$(send 'Reply with only the word PLOVER'); log "  fm-desk-voice send -> $out"; sed 's/^/  stderr: /' "$LAB/send.err" | tee -a "$LOG"
sleep 4; snap C-after
mb=${out#mailbox: }
[ -f "$mb" ] && log "  mailbox file: $(cat "$mb")"
submitted=0; screen | grep -q 'PLOVER' && submitted=1
wren=$(screen | grep -cF 'WREN second draft')
stashed=0; screen | grep -Eq '›[[:space:]]*stashed' && stashed=1
clear_box; t send-keys -t primary C-s; sleep 1; snap C-unstash
falcon=$(screen | grep -cF 'FALCON stash the captain set aside')
if [[ $out == 'mailbox: '* ]] && [ -f "$mb" ] && [ "$submitted" = 0 ] && [ "$wren" = 1 ] && [ "$stashed" = 1 ] && [ "$falcon" = 1 ]; then
  result C pass; else result C "FAIL (out=$out submitted=$submitted wren=$wren stashed=$stashed falcon=$falcon)"; fi
clear_box

# --- D: draft is only a collapsed paste placeholder -> reported sent ----------
log "== D: the draft is only a [Pasted text] placeholder"
printf 'line one of a pasted log\nline two of a pasted log\nline three of a pasted log\nline four\nline five\n' > "$LAB/paste.txt"
t load-buffer -b pb "$LAB/paste.txt"; t paste-buffer -p -b pb -t primary; sleep 1.5
log "  state before: $(state)"; snap D-before
out=$(TRACE=1 send 'Reply with only the word EGRET'); cp "$LAB/send.err" "$EV/trace-D.txt"; LC_ALL=C grep -a '^fm-desk-voice:' "$LAB/send.err" > "$LAB/send.err2"; mv "$LAB/send.err2" "$LAB/send.err"; log "  fm-desk-voice send -> $out"; sed 's/^/  stderr: /' "$LAB/send.err" | tee -a "$LOG"
wait_answer EGRET && ans=1 || ans=0; sleep 1; snap D-after
ph=$(screen | grep -c 'Pasted text')
if [[ $out == 'sent: tmux '* ]] && [ "$ans" = 1 ] && [ "$(state)" = pending ] && [ "$ph" -ge 1 ] \
  && ! screen | grep -q 'line one of a pasted log'; then result D pass; else result D "FAIL (out=$out ans=$ans placeholder=$ph)"; fi
clear_box

# --- E: long message that wraps many rows, past a draft -> sent, draft back --
log "== E: a long voice message past a draft"
t send-keys -t primary -l 'SWIFT draft kept aside'; sleep 1
long='Reply with only the word IBIS and nothing else. Ignore this filler, which stands in for a long voice transcript:'
for i in $(seq 1 60); do long="$long words number $i of a long dictated floater message,"; done
log "  message length ${#long} chars"
log "  state before: $(state)"; snap E-before
out=$(TRACE=1 send "$long"); cp "$LAB/send.err" "$EV/trace-E.txt"; LC_ALL=C grep -a '^fm-desk-voice:' "$LAB/send.err" > "$LAB/send.err2"; mv "$LAB/send.err2" "$LAB/send.err"; log "  fm-desk-voice send -> $out"; sed 's/^/  stderr: /' "$LAB/send.err" | tee -a "$LOG"
wait_answer IBIS && ans=1 || ans=0; sleep 1; snap E-after
n=$(screen | grep -cF 'SWIFT draft kept aside')
if [[ $out == 'sent: tmux '* ]] && [ "$ans" = 1 ] && [ "$(state)" = pending ] && [ "$n" = 1 ]; then result E pass; else result E "FAIL (out=$out ans=$ans draft=$n)"; fi

log "== summary"; printf '%s\n' "${RES[@]}" | tee -a "$LOG"
