#!/usr/bin/env bash
# Live drive: real Claude primary in a disposable lab home on a private fm-lab
# tmux socket. Another writer holds the per-home pane-writer lock; the real
# fm-desk-voice.sh ring must not type and send must use the mailbox. After
# release, ring must submit.
set -u
ROOT=$PWD
LAB=$(mktemp -d "${TMPDIR:-/tmp}/fm-lab.XXXXXX")
bin/fm-lab-home.sh create "$LAB" >/dev/null && mkdir -p "$LAB/tmux" "$LAB/notify-bin" "$LAB/state/desk-voice"
printf '#!/bin/sh\nexit 0\n' > "$LAB/notify-bin/osascript"; chmod +x "$LAB/notify-bin/osascript"
t() { TMUX_TMPDIR="$LAB/tmux" tmux -L fm-lab "$@"; }
cleanup() { : > "$LAB/release"; sleep 1; t kill-server >/dev/null 2>&1; rm -rf "$LAB"; }
trap cleanup EXIT
screen() { t capture-pane -p -t primary 2>/dev/null; }
composer() { TMUX="$(t display-message -p '#{socket_path}'),0,0" bash -c '. "$1/bin/fm-backend.sh"; fm_backend_composer_state tmux primary' _ "$ROOT"; }
desk() { env -u TMUX -u TMUX_PANE -u HERDR_ENV -u HERDR_PANE_ID -u HERDR_SOCKET_PATH -u FM_STATE_OVERRIDE -u NO_MISTAKES_GATE \
  PATH="$LAB/notify-bin:$PATH" FM_HOME="$LAB" "$ROOT/bin/fm-desk-voice.sh" "$@" 2>&1; }
env -u NO_MISTAKES_GATE -u FM_GATE_REFUSE_BYPASS -u FM_ROOT_OVERRIDE -u FM_STATE_OVERRIDE -u FM_DATA_OVERRIDE \
  -u FM_CONFIG_OVERRIDE -u FM_PROJECTS_OVERRIDE TMUX_TMPDIR="$LAB/tmux" tmux -L fm-lab new-session -d -s primary \
  -x 140 -y 45 -c "$ROOT" -e FM_HOME="$LAB" "claude --model haiku" || exit 1
ready=0
for _ in $(seq 1 120); do [ "$(composer)" = empty ] && { ready=1; break; }; sleep 1; done
[ "$ready" = 1 ] || { echo "FAIL: primary never ready"; exit 1; }
t display-message -p -t primary '#{pane_pid}' > "$LAB/state/.lock"
sleep 3
echo "claude $(claude --version); composer=$(composer)"
L="$LAB/state/desk-voice/.send.lock"
bash -c '. "$1/bin/fm-wake-lib.sh"; fm_lock_try_acquire "$2" || exit 1; : > "$3/held"
  while [ ! -e "$3/release" ]; do sleep 0.2; done; fm_lock_release "$2"' _ "$ROOT" "$L" "$LAB" &
for _ in $(seq 1 50); do [ -e "$LAB/held" ] && break; sleep 0.1; done
echo "== another writer holds $L: $([ -e "$LAB/held" ] && echo yes || echo NO)"
echo "ring verdict while held: $(desk ring 'Reply with only the word EGRET')"
echo "send result while held: $(desk send --source live-test 'Reply with only the word PLOVER' | tr '\n' ' ')"
sleep 4
echo "composer=$(composer)  EGRET on screen=$(screen | grep -c EGRET)  PLOVER on screen=$(screen | grep -c PLOVER)"
echo "mailbox files: $(ls "$LAB/state/desk-voice/inbox" 2>/dev/null | wc -l | tr -d ' ')"
for f in "$LAB"/state/desk-voice/inbox/*.json; do [ -f "$f" ] && jq -c '{text: .text, source: .source}' "$f" 2>/dev/null; done
: > "$LAB/release"; for _ in $(seq 1 30); do [ ! -e "$L" ] && break; sleep 0.2; done
echo "== writer lock released: $([ -e "$L" ] && echo NO || echo yes)"
echo "ring verdict after release: $(desk ring 'Reply with only the word IBIS')"
for _ in $(seq 1 40); do screen | grep -q '⏺ IBIS' && break; sleep 1; done
echo "lock left behind after ring: $([ -e "$L" ] && echo YES || echo no)"
echo "--- final screen"; screen | grep -v '^\s*$' | tail -n 8
