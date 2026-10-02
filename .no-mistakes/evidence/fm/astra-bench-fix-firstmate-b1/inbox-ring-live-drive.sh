#!/usr/bin/env bash
# Live drive: real Claude firstmate primary in a disposable lab home on a private
# fm-lab tmux socket; real bin/fm-inbox.sh note -> real ring_primary -> real
# fm-desk-voice.sh ring. Phases: .afk-contract only (ring must be suppressed),
# present with a half-typed captain draft (ring must refuse), present+empty
# (ring must submit).
set -u
ROOT=$PWD
SNAP=${SNAP:-/dev/null}
LAB=$(mktemp -d "${TMPDIR:-/tmp}/fm-lab.XXXXXX")
bin/fm-lab-home.sh create "$LAB" >/dev/null && mkdir -p "$LAB/tmux"
t() { TMUX_TMPDIR="$LAB/tmux" tmux -L fm-lab "$@"; }
cleanup() { t kill-server >/dev/null 2>&1; rm -rf "$LAB"; }
trap cleanup EXIT
screen() { t capture-pane -p -t primary 2>/dev/null; }
composer() {
  TMUX="$(t display-message -p '#{socket_path}'),0,0" bash -c '. "$1/bin/fm-backend.sh"; fm_backend_composer_state tmux primary' _ "$ROOT"
}
note() {
  env -u TMUX -u TMUX_PANE -u HERDR_ENV -u HERDR_PANE_ID -u HERDR_SOCKET_PATH -u NO_MISTAKES_GATE \
    -u FM_STATE_OVERRIDE -u FM_ROOT_OVERRIDE -u FM_DATA_OVERRIDE -u FM_CONFIG_OVERRIDE -u FM_PROJECTS_OVERRIDE \
    FM_HOME="$LAB" "$ROOT/bin/fm-inbox.sh" note "$1"
}
ringcount() { screen | grep -c '\[firstmate inbox\]' || true; }
env -u NO_MISTAKES_GATE -u FM_GATE_REFUSE_BYPASS -u FM_ROOT_OVERRIDE -u FM_STATE_OVERRIDE -u FM_DATA_OVERRIDE \
  -u FM_CONFIG_OVERRIDE -u FM_PROJECTS_OVERRIDE TMUX_TMPDIR="$LAB/tmux" tmux -L fm-lab new-session -d -s primary \
  -x 140 -y 45 -c "$ROOT" -e FM_HOME="$LAB" "claude --model haiku" || { echo "FAIL: could not start claude"; exit 1; }
ready=0
for _ in $(seq 1 180); do
  case "$(screen)" in
    *'❯ Yes, I trust this folder'*|*'❯ 1. Yes'*) t send-keys -t primary Enter ;;
  esac
  if [ "$(composer)" = empty ]; then ready=1; break; fi
  sleep 1
done
# The primary's first turn would take state/.lock via bootstrap; record the
# harness pid the same way (as tests/fm-desk-voice-claude-draft-live-e2e does).
[ "$ready" != 1 ] || t display-message -p -t primary '#{pane_pid}' > "$LAB/state/.lock"
echo "claude: $(claude --version)  ready=$ready lock=$(head -n1 "$LAB/state/.lock" 2>/dev/null)"
[ "$ready" = 1 ] || { echo "FAIL: primary never ready"; screen | tail -n 20; exit 1; }
echo "lock holder process: $(ps -o comm= -p "$(head -n1 "$LAB/state/.lock")")"
sleep 3

echo "== Phase A: .afk-contract only (Pi away), composer empty"
printf '{}\n' > "$LAB/state/.afk-contract"
out=$(note "contract posture status note"); echo "note -> $(printf '%s' "$out" | head -c 200)"
sleep 10
echo "ring lines on primary screen: $(ringcount)   composer: $(composer)"
echo "notes on disk: $(find "$LAB/state/inbox" -name '*.note' | wc -l | tr -d ' ')"
rm -f "$LAB/state/.afk-contract"

echo "== Phase B: present, captain half-typed draft in the box"
t send-keys -t primary -l 'PELICAN half typed captain draft'
sleep 1
echo "composer before note: $(composer)"
out=$(note "present with draft note"); echo "note -> $(printf '%s' "$out" | head -c 200)"
sleep 10
echo "ring lines on primary screen: $(ringcount)   composer: $(composer)"
echo "draft still in box: $(screen | grep -c 'PELICAN half typed captain draft')"
echo "notes on disk: $(find "$LAB/state/inbox" -name '*.note' | wc -l | tr -d ' ')"
echo "--- screen tail (phase B)"; screen | grep -v '^\s*$' | tail -n 6

echo "== Phase C: present, empty box"
t send-keys -t primary C-u; sleep 1
echo "composer before note: $(composer)"
out=$(note "present empty note"); echo "note -> $(printf '%s' "$out" | head -c 200)"
seen=0
for i in $(seq 1 25); do
  { echo "### t=${i}s composer=$(composer)"; screen | grep -v '^\s*$' | tail -n 8; } >> "$SNAP"
  [ "$(ringcount)" -ge 1 ] && seen=1
  sleep 1
done
echo "ring reached primary: $seen"
echo "draft submitted anywhere: $(screen | grep -c 'PELICAN')"
echo "notes on disk: $(find "$LAB/state/inbox" -name '*.note' | wc -l | tr -d ' ')"
echo "--- screen (phase C)"; screen | grep -v '^\s*$' | tail -n 20
echo "submitted ring prompt in history: $(screen | grep -c '^❯ \[firstmate inbox\]')"
echo "== Phase D: direct ring on the same empty primary, verdict printed"
t send-keys -t primary Escape; sleep 2
echo "composer: $(composer)"
v=$(env -u TMUX -u TMUX_PANE -u HERDR_ENV -u HERDR_PANE_ID -u HERDR_SOCKET_PATH -u FM_STATE_OVERRIDE FM_HOME="$LAB" \
  "$ROOT/bin/fm-desk-voice.sh" ring 'Reply with only the word HERON' 2>&1); echo "ring verdict: $v"
for _ in $(seq 1 40); do screen | grep -q 'HERON' && screen | grep -q '⏺' && break; sleep 1; done
sleep 5
echo "--- final screen"; screen | grep -v '^\s*$' | tail -n 25
