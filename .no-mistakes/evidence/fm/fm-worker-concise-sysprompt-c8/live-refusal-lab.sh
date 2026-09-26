#!/usr/bin/env bash
# Real bin/fm-spawn.sh against marked lab homes: refusal paths and a base-commit
# comparison of the absent-file launch. Usage: live-refusal-lab.sh <outdir>
set -u
OUT=$1; mkdir -p "$OUT"
WT_ROOT=/Users/larsmusic/.no-mistakes/worktrees/f569cc43ac96/01M3FFQDSY84KX1ZR6WPRJSWFS
. "$WT_ROOT/tests/fixtures.sh"; unset FM_GATE_REFUSE_BYPASS
LAB=$(mktemp -d "${TMPDIR:-/tmp}/fm-lab.XXXXXX"); LAB=$(cd "$LAB" && pwd -P)
trap 'chmod -R u+w "$LAB" 2>/dev/null; rm -rf "$LAB"' EXIT
# Throwaway copies of the repo at base and at target (target minus the prompt file).
mkdir -p "$LAB/base-root" "$LAB/noprompt-root"
git -C "$WT_ROOT" archive d72944f2 | tar -x -C "$LAB/base-root"
git -C "$WT_ROOT" archive HEAD | tar -x -C "$LAB/noprompt-root"; rm "$LAB/noprompt-root/docs/worker-prompts/claude-concise.md"
spawn_case() {  # <name> <root> <token-or-absent>
  local name=$1 root=$2 tok=$3 H="$LAB/$1/home" ID="concise-live-x" fakebin rc
  "$WT_ROOT/bin/fm-lab-home.sh" create "$H" >/dev/null
  touch "$H/state/.last-watcher-beat"; printf 'claude\n' > "$H/config/crew-harness"
  [ "$tok" = absent ] || printf '%s\n' "$tok" > "$H/config/claude-concise-prompt"
  fm_git_worktree "$LAB/$name/project" "$LAB/$name/wt" "wt-$name" >/dev/null 2>&1
  fm_test_spawn_brief "$H" "$ID"
  fakebin=$(make_spawn_fakebin "$LAB/$name/fake"); mkdir -p "$H/user-home"; : > "$OUT/$name.launch"
  env -u FM_ROOT_OVERRIDE -u FM_STATE_OVERRIDE -u FM_DATA_OVERRIDE -u FM_CONFIG_OVERRIDE -u FM_PROJECTS_OVERRIDE \
    FM_HOME="$H" HOME="$H/user-home" CLAUDE_CONFIG_DIR= FM_SPAWN_NO_GUARD=1 FM_FAKE_PANE_PATH="$LAB/$name/wt" TMUX=fake,1,0 \
    FM_FAKE_LAUNCH_LOG="$OUT/$name.launch" FM_FAKE_WINDOW_LOG="$H/state/.fake-windows" PATH="$fakebin:$PATH" \
    "$root/bin/fm-spawn.sh" "$ID" "$LAB/$name/project" --mode no-mistakes --yolo off > "$OUT/$name.spawn.log" 2>&1
  rc=$?
  { echo "\$ config/claude-concise-prompt=$tok; fm-spawn.sh ($name) -> exit $rc"; grep -v '^warning' "$OUT/$name.spawn.log" | head -3
    echo "  state/$ID.meta exists: $([ -e "$H/state/$ID.meta" ] && echo yes || echo no)"
    echo "  launch typed into pane: $([ -s "$OUT/$name.launch" ] && echo yes || echo no)"
    echo "  fake windows created: $(cat "$H/state/.fake-windows" 2>/dev/null | wc -l | tr -d ' ')"; } >> "$OUT/refusals.txt"
  sed -E "s#$LAB/$name#<LAB>#g; s#$root#<ROOT>#g" "$OUT/$name.launch" > "$OUT/$name.launch.norm"
}
spawn_case invalid-yes "$WT_ROOT" yes
spawn_case invalid-ON "$WT_ROOT" 'ON'
spawn_case missing-prompt "$LAB/noprompt-root" on
spawn_case missing-prompt-off "$LAB/noprompt-root" off
spawn_case base-absent "$LAB/base-root" absent
spawn_case target-absent "$WT_ROOT" absent
if cmp -s "$OUT/base-absent.launch.norm" "$OUT/target-absent.launch.norm"; then
  echo "base d72944f2 vs target: absent-file claude launch IDENTICAL (lab path/root normalized)" >> "$OUT/refusals.txt"
else echo "base vs target absent launch DIFFER" >> "$OUT/refusals.txt"; diff "$OUT/base-absent.launch.norm" "$OUT/target-absent.launch.norm" >> "$OUT/refusals.txt"; fi
