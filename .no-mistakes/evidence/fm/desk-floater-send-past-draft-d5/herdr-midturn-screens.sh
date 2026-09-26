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
SESSION=$("$LAB_HELPER" name desk-mt)
LAB=$(mktemp -d "${TMPDIR:-/tmp}/fm-lab.XXXXXX"); rmdir "$LAB"
"$ROOT/bin/fm-lab-home.sh" create "$LAB" >/dev/null || exit 1
mkdir -p "$LAB/project" "$LAB/fakebin" "$LAB/notify-bin"
git -C "$LAB/project" init -q
printf '#!/bin/sh\nexit 0\n' > "$LAB/notify-bin/osascript"; chmod +x "$LAB/notify-bin/osascript"
LOG="$EV/herdr-midturn-screens-transcript.txt"; : > "$LOG"
log() { printf '%s\n' "$*" | tee -a "$LOG"; }
cleanup() {
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
typeit() { lab pane send-text "$PANE" "$1" >/dev/null; }
key() { lab pane send-keys "$PANE" "$@" >/dev/null; }
idle() { local i; for i in $(seq 1 120); do
  if screen | grep -q '· done'; then case "$(state)" in empty|pending) return 0;; esac; fi; sleep 1; done; return 1; }
clearbox() { local i; for i in $(seq 1 40); do [ "$(state)" = empty ] && return 0; key ctrl+u; sleep 0.3; done; return 1; }
answered() { local i; for i in $(seq 1 120); do screen | grep -q "⏺ $1" && return 0; sleep 1; done; return 1; }
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
log "shell_pid=$SHELL_PID claude_pid=$CPID ($(ps -o comm= -p "$CPID"))"


full() { { echo "----- $(date +%T) $1 state=$(state) -----"; lab pane read "$PANE" --source visible 2>&1 | tail -n 14; echo "----- end -----"; } >> "$LOG"; }
# M1: Claude's own Ctrl+S mid-turn, no script involved.
typeit "Write a numbered list of 60 different bird species, one per line, with a one-sentence fact about each."; sleep 0.5; key enter; sleep 5
typeit "CURLEW draft typed while busy"; sleep 1
full "M1 busy, draft typed"
key ctrl+s
for i in 1 2 3 4; do sleep 1; full "M1 ${i}s after a manual ctrl+s"; done
for _ in $(seq 1 90); do sleep 1; lab pane read "$PANE" --source visible 2>/dev/null | grep -q '· done' && break; done
sleep 2; full "M1 turn ended"
clearbox; key ctrl+s; sleep 2; full "M1 after ctrl+s on empty box"
clearbox
# M2: the script mid-turn, screens after.
typeit "Write a numbered list of 60 more bird species, one per line, with a one-sentence fact about each."; sleep 0.5; key enter; sleep 5
typeit "DUNLIN draft typed while busy"; sleep 1
full "M2 busy, draft typed"
out=$(desk "Reply with only the word ROBIN" 2>&1); log "M2 send -> $(printf '%s' "$out" | tr '\n' '|')"
for i in 1 2 3; do full "M2 ${i} after send"; sleep 1; done
