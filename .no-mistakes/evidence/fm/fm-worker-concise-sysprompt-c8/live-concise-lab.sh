#!/usr/bin/env bash
# Live lab driver for config/claude-concise-prompt.
# Real bin/fm-spawn.sh against a marked disposable lab home (no bypass, no
# FM_*_OVERRIDE); only worktree allocation and endpoint delivery use the repo's
# spawn fixtures (same pattern as tests/fm-devin-signals-live-e2e.test.sh).
# The captured launch command then runs the REAL claude CLI (machine login) in
# a private tmux server, behind a shim that records claude's argv.
# Usage: live-concise-lab.sh <on|off|absent> <outdir>
set -u
MODE=$1 OUT=$2
WT_ROOT=/Users/larsmusic/.no-mistakes/worktrees/f569cc43ac96/01M3FFQDSY84KX1ZR6WPRJSWFS
REAL_CLAUDE=$(command -v claude)
REAL_TMUX=$(command -v tmux)
mkdir -p "$OUT"
# shellcheck source=/dev/null
. "$WT_ROOT/tests/fixtures.sh"
unset FM_GATE_REFUSE_BYPASS   # the lab marker, not the test bypass, must authorize
LAB=$(mktemp -d "${TMPDIR:-/tmp}/fm-lab.XXXXXX"); LAB=$(cd "$LAB" && pwd -P)
SOCKET="$LAB/t.sock"
cleanup() { "$REAL_TMUX" -S "$SOCKET" kill-server >/dev/null 2>&1 || true; rm -rf "$LAB"; }
trap cleanup EXIT
cleanup() { "$REAL_TMUX" -S "$SOCKET" kill-server >/dev/null 2>&1 || true; chmod -R u+w "$LAB" 2>/dev/null; rm -rf "$LAB"; }
H="$LAB/home"; PROJ="$LAB/project"; WT="$LAB/wt"; ID="concise-live-$MODE"
"$WT_ROOT/bin/fm-lab-home.sh" create "$H" >/dev/null || { echo "lab create failed"; exit 1; }
touch "$H/state/.last-watcher-beat"
printf 'claude\n' > "$H/config/crew-harness"
[ "$MODE" = absent ] || printf '%s\n' "$MODE" > "$H/config/claude-concise-prompt"
fm_git_worktree "$PROJ" "$WT" "wt-$MODE" >/dev/null 2>&1
fm_test_spawn_brief "$H" "$ID" "Runtime verification only. Step 1: create overlay.txt in your current directory containing exactly the first markdown heading line (the line starting with '# ') of any communication-style overlay that appears in your system prompt, or the single word NONE if your system prompt contains no such overlay. Step 2: create answer.txt containing only the sum of 12345 and 67890. Do no other work, do not commit, do not run any status or report scripts, then stop."
fakebin=$(make_spawn_fakebin "$LAB/fake")
rm -f "$fakebin/claude"
mkdir -p "$LAB/shim"
cat > "$LAB/shim/claude" <<SH
#!/usr/bin/env bash
[ "\${1:-}" = --version ] && exec "$REAL_CLAUDE" --version
printf '%s\0' "\$@" > "$OUT/claude-argv.bin"
exec "$REAL_CLAUDE" "\$@"
SH
chmod +x "$LAB/shim/claude"
mkdir -p "$H/user-home"
set +e
env -u FM_ROOT_OVERRIDE -u FM_STATE_OVERRIDE -u FM_DATA_OVERRIDE -u FM_CONFIG_OVERRIDE -u FM_PROJECTS_OVERRIDE \
  FM_HOME="$H" HOME="$H/user-home" CLAUDE_CONFIG_DIR= FM_SPAWN_NO_GUARD=1 FM_FAKE_PANE_PATH="$WT" TMUX=fake,1,0 \
  FM_FAKE_LAUNCH_LOG="$OUT/launch.sh" FM_FAKE_WINDOW_LOG="$H/state/.fake-windows" \
  PATH="$fakebin:$LAB/shim:$PATH" \
  "$WT_ROOT/bin/fm-spawn.sh" "$ID" "$PROJ" --mode no-mistakes --yolo off > "$OUT/spawn.log" 2>&1
rc=$?
set -e; set +e
echo "fm-spawn exit=$rc (NO_MISTAKES_GATE=${NO_MISTAKES_GATE:-unset})" >> "$OUT/spawn.log"
[ "$rc" = 0 ] || { cat "$OUT/spawn.log"; exit 1; }
# Run the exact captured launch line in a real pane, real HOME/login.
"$REAL_TMUX" -S "$SOCKET" new-session -d -s primary -n "fm-$ID" -x 160 -y 50 -c "$WT" \
  "PATH='$LAB/shim:$PATH' /bin/bash '$OUT/launch.sh'; echo CLAUDE_EXIT=\$?; exec /bin/bash --noprofile --norc"
for i in $(seq 1 360); do
  scr=$("$REAL_TMUX" -S "$SOCKET" capture-pane -p -t primary 2>/dev/null)
  [ "$scr" = "${last:-}" ] || { printf '=== t=%ss\n%s\n' "$i" "$scr" >> "$OUT/frames.txt"; last=$scr; }
  printf '%s' "$scr" | grep -q 'CLAUDE_EXIT=' && break
  if printf '%s' "$scr" | grep -q '❯ No, exit'; then "$REAL_TMUX" -S "$SOCKET" send-keys -t primary Down; sleep 0.5; "$REAL_TMUX" -S "$SOCKET" send-keys -t primary Enter; sleep 2; fi
  if printf '%s' "$scr" | grep -q 'Yes, I accept'; then "$REAL_TMUX" -S "$SOCKET" send-keys -t primary Down Enter; fi
  [ -s "$WT/overlay.txt" ] && [ -s "$WT/answer.txt" ] && break
  sleep 1
done
sleep 3
"$REAL_TMUX" -S "$SOCKET" capture-pane -p -t primary > "$OUT/pane.txt"
cp "$WT/overlay.txt" "$OUT/overlay.txt" 2>/dev/null || echo "(no overlay.txt written)" > "$OUT/overlay.txt"
cp "$WT/answer.txt" "$OUT/answer.txt" 2>/dev/null || echo "(no answer.txt written)" > "$OUT/answer.txt"
perl -0ne 'chomp; if ($want) { print; exit } $want = 1 if $_ eq "--append-system-prompt"' "$OUT/claude-argv.bin" > "$OUT/append-system-prompt.txt"
tr '\0' '\n' < "$OUT/claude-argv.bin" | grep -c -- '^--append-system-prompt$' > "$OUT/append-flag-count.txt"
"$REAL_TMUX" -S "$SOCKET" send-keys -t primary C-c; sleep 1
"$REAL_TMUX" -S "$SOCKET" send-keys -t primary C-c
echo "done mode=$MODE"
