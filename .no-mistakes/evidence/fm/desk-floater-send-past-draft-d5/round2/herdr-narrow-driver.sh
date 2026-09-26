#!/usr/bin/env bash
# Live driver: real Claude Code in a guarded fm-lab-* Herdr session, driven
# through bin/fm-desk-voice.sh send. Every herdr call, the desk script's
# included, is routed through bin/fm-herdr-lab.sh by a PATH wrapper.
# Usage: herdr-driver.sh <worktree> <evidence-dir>
set -u
ROOT=$1
EV=$2
DESK="$ROOT/bin/fm-desk-voice.sh"
LAB_HELPER="$ROOT/bin/fm-herdr-lab.sh"
. "$ROOT/tests/herdr-test-safety.sh"
herdr_forget_inherited_pane
ORIGINAL_PATH=$PATH
SESSION=$("$LAB_HELPER" name desk-r2n)
LAB=$(mktemp -d "${TMPDIR:-/tmp}/fm-lab.XXXXXX"); rmdir "$LAB"
"$ROOT/bin/fm-lab-home.sh" create "$LAB" >/dev/null || exit 1
mkdir -p "$LAB/project" "$LAB/fakebin" "$LAB/notify-bin"
git -C "$LAB/project" init -q
printf '#!/bin/sh\nexit 0\n' > "$LAB/notify-bin/osascript"; chmod +x "$LAB/notify-bin/osascript"
LOG="$EV/round2/herdr-narrow-transcript.txt"; : > "$LOG"
log() { printf '%s\n' "$*" | tee -a "$LOG"; }
cleanup() {
  session_dump
  PATH="$ORIGINAL_PATH" "$LAB_HELPER" teardown "$SESSION" >>"$LOG" 2>&1 && log "teardown ok: $SESSION" || log "TEARDOWN FAILED: $SESSION"
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
else
  echo "wrapper requires trailing --session $SESSION" >&2; exit 98
fi
exec env PATH="$ORIGINAL_PATH" "$LAB_HELPER" run "$SESSION" "\${args[@]}"
EOF
chmod +x "$LAB/fakebin/herdr"
"$LAB_HELPER" provision "$SESSION" >>"$LOG" 2>&1 || { log "provision failed"; exit 1; }
lab() { env PATH="$ORIGINAL_PATH" "$LAB_HELPER" run "$SESSION" "$@"; }
WS=$(lab workspace create --cwd "$LAB/project" --label fm-deskdraft --no-focus) || { log "ws create failed"; exit 1; }
PANE=$(printf '%s' "$WS" | jq -er '.result.root_pane.pane_id')
log "session=$SESSION pane=$PANE claude=$(claude --version | head -n1) herdr=$(herdr --version | head -n1)"
lab pane run "$PANE" "FM_HOME=$LAB claude" >/dev/null || { log "pane run failed"; exit 1; }

screen() { lab pane read "$PANE" --source visible 2>/dev/null; }
shot() { { echo "----- screen: $1 -----"; screen; echo "----- end -----"; } >> "$LOG"; }
state() {
  PATH="$LAB/fakebin:$ORIGINAL_PATH" bash -c '. "$1/bin/fm-backend.sh"; fm_backend_composer_state herdr "$2"' _ "$ROOT" "$SESSION:$PANE" 2>/dev/null
}
desk() {
  env -u NO_MISTAKES_GATE -u FM_GATE_REFUSE_BYPASS -u FM_ROOT_OVERRIDE -u FM_STATE_OVERRIDE \
    -u FM_DATA_OVERRIDE -u FM_CONFIG_OVERRIDE -u FM_PROJECTS_OVERRIDE \
    -u TMUX -u TMUX_PANE -u HERDR_ENV -u HERDR_PANE_ID -u HERDR_SOCKET_PATH -u HERDR_SESSION \
    PATH="$LAB/fakebin:$LAB/notify-bin:$ORIGINAL_PATH" FM_HOME="$LAB" "$DESK" send --source live-test "$@"
}
session_dump() {
  local d f
  d=$(find "$HOME/.claude/projects" -maxdepth 1 -type d -name "*${LAB##*fm-lab.}*" 2>/dev/null | head -n1)
  f=$(ls -t "$d"/*.jsonl 2>/dev/null | head -n1)
  [ -n "$f" ] || { log "no claude session log found"; return; }
  jq -r 'select(.type=="user" or .type=="assistant")
    | [.type, (.message.content | if type=="string" then . else (map(select(.type=="text") | .text) | join(" ")) end)]
    | select(.[1] != "") | "\(.[0])\tlen=\(.[1]|length)\t\(.[1][0:160] | gsub("\n";" "))"' "$f" > "$EV/round2/herdr-narrow-claude-session.tsv"
}
typeit() { lab pane send-text "$PANE" "$1" >/dev/null; }
key() { lab pane send-keys "$PANE" "$@" >/dev/null; }
idle() { local i; for i in $(seq 1 150); do
  if screen | grep -q '· done' || ! screen | grep -q 'esc to in'; then case "$(state)" in empty|pending) return 0;; esac; fi; sleep 1; done; return 1; }
clearbox() { local i; for i in $(seq 1 60); do [ "$(state)" = empty ] && return 0; key ctrl+u; sleep 0.3; done; return 1; }
answered() { local i; for i in $(seq 1 120); do screen | grep -q "⏺ $1" && return 0; sleep 1; done; return 1; }
mailbox_empty() { ! ls "$LAB/state/desk-voice/inbox"/* >/dev/null 2>&1; }
RESULTS=(); verdict() { RESULTS+=("$1: $2"); log "RESULT $1: $2"; }

ready=0
for _ in $(seq 1 60); do
  case "$(screen)" in *'Yes, I trust this folder'*) key down enter; sleep 2 ;; esac
  [ "$(state)" = empty ] && { ready=1; break; }
  sleep 1
done
[ "$ready" = 1 ] || { shot never-ready; log "claude never ready"; exit 1; }
SHELL_PID=$(lab pane process-info --pane "$PANE" | jq -r '.result.process_info.shell_pid')
CPID=$(pgrep -P "$SHELL_PID" -x claude | head -n1); [ -n "$CPID" ] || CPID=$(pgrep -P "$SHELL_PID" | head -n1)
printf '%s\n' "$CPID" > "$LAB/state/.lock"
log "shell_pid=$SHELL_PID claude_pid=$CPID ($(ps -o comm= -p "$CPID")) worktree HEAD=$(git -C "$ROOT" rev-parse --short HEAD) pane-width=$(screen | awk '{ if (length($0)>m) m=length($0) } END {print m}')"

styled_box() { lab pane read "$PANE" --source recent --lines 60 --format ansi 2>/dev/null | LC_ALL=C grep -a '❯' | tail -n1; }

# G: the reported failure on Herdr: a grey suggested prompt in the box.
ghost=0
for attempt in 1 2 3; do
  typeit 'List three fruit names, one per line, nothing else.'; sleep 0.5; key enter; sleep 3; idle; sleep 2
  typeit 'I want to write hello.txt with one of those fruits in it. Propose which fruit and ask me to confirm before writing anything.'
  sleep 0.5; key enter; sleep 3; idle
  for _ in $(seq 1 20); do styled_box | LC_ALL=C grep -aq $'\e\\[2m[^ ]' && { ghost=1; break; }; sleep 1; done
  [ $ghost = 1 ] && break
done
shot "G before send (grey suggestion shown=$ghost)"; { echo "--- G styled box row:"; styled_box | cat -v; } >> "$LOG"
out=$(desk 'Reply with only the word ALBATROSS' 2>&1); log "G send -> $(printf '%s' "$out" | tr '\n' '|')"
got=0; answered ALBATROSS && got=1; idle; sleep 2; shot "G after send"
log "G replied=$got mailbox-used=$(mailbox_empty && echo 0 || echo 1)"
if [ $ghost = 1 ] && printf '%s' "$out" | grep -q '^sent: herdr' && [ $got = 1 ] && mailbox_empty; then verdict G-herdr-suggested-prompt pass
elif [ $ghost = 0 ]; then verdict G-herdr-suggested-prompt "not-exercised (no suggestion appeared)"; else verdict G-herdr-suggested-prompt fail; fi
rm -f "$LAB/state/desk-voice/inbox"/*; clearbox; sleep 15

for run in 1 2 3; do
  typeit "Write a numbered list of 80 different bird species, one per line, with a two-sentence fact about each. Run $run."; sleep 0.5; key enter
  esc=0; for _ in $(seq 1 40); do screen | tail -n 4 | grep -q 'esc to in' && { esc=1; break; }; sleep 0.5; done
  typeit "CURLEW$run draft"; sleep 1
  busy=0; screen | grep -q '^ *[0-9][0-9]*\.' && ! screen | tail -n 8 | grep -q '· done' && busy=1
  log "H$run footer-esc-seen=$esc busy-before-send=$busy state=$(state)"; shot "H$run before send"
  frames="$EV/round2/herdr-narrow-H$run-frames.txt"; : > "$frames"
  ( while [ ! -e "$LAB/stop-sampler" ]; do { echo "=== $(date +%T)"; screen | tail -n 6; } >> "$frames"; sleep 0.1; done ) &
  sp=$!
  out=$(desk "Reply with only the word ROBIN$run" 2>&1); log "H$run send -> $(printf '%s' "$out" | tr '\n' '|')"
  touch "$LAB/stop-sampler"; wait "$sp"; rm -f "$LAB/stop-sampler"
  wrapped=$(LC_ALL=C grep -ac '^ *› stashed *$' "$frames" || true)
  log "H$run frames sampled=$(LC_ALL=C grep -ac '^===' "$frames") frames-with-stashed-on-own-row=$wrapped"
  shot "H$run right after send"
  got=0; answered "ROBIN$run" && got=1; idle; sleep 2; shot "H$run after the queued message ran"
  c=$(screen | grep -cF "CURLEW$run draft" || true)
  log "H$run after: replied=$got state=$(state) draft-in-box=$c"
  if [ "$busy" = 1 ] && printf '%s' "$out" | grep -q '^sent: herdr' && [ $got = 1 ] && [ "$(state)" = pending ] && [ "$c" = 1 ] && mailbox_empty; then
    verdict "H$run-narrow-busy-past-draft" "pass (esc-footer=$esc stashed-own-row frames=$wrapped)"; else verdict "H$run-narrow-busy-past-draft" "fail (busy=$busy)"; fi
  rm -f "$LAB/state/desk-voice/inbox"/*; clearbox; sleep 15
done
log "==== SUMMARY"; for r in "${RESULTS[@]}"; do log "$r"; done
