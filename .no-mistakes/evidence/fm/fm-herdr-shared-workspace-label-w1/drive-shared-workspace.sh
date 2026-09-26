#!/usr/bin/env bash
# Live driver: a real guarded Herdr lab session with one workspace shared by
# workers of two projects and one single-project workspace. Runs the base
# (pre-fix) and target fm-visible-status.sh and reads back the real labels.
set -u
ROOT=${ROOT:?}
BASE=${BASE:?}
LAB=$ROOT/bin/fm-herdr-lab.sh
S=$("$LAB" name shared-ws)
T=$(mktemp -d "${TMPDIR:-/tmp}/fm-shared-ws.XXXXXX")
cleanup() { "$LAB" teardown "$S" >/dev/null 2>&1 || true; rm -rf "$T"; }
trap cleanup EXIT
echo "lab session: $S"
"$LAB" provision "$S" >/dev/null || { echo 'provision failed'; exit 1; }

mkdir -p "$T/base" "$T/home/state"
git -C "$ROOT" archive "$BASE" bin | tar -x -C "$T/base"

mkws() { "$LAB" run "$S" workspace create --cwd "$T" --label "$1" --no-focus | jq -r '.result.workspace.workspace_id'; }
SW=$(mkws 'shared (unlabelled)')
OW=$(mkws 'artevo (unlabelled)')
mktab() {  # <ws> <label> -> "tab pane"
  "$LAB" run "$S" tab create --workspace "$1" --cwd "$T" --label "$2" --no-focus \
    | jq -r '"\(.result.tab.tab_id) \(.result.root_pane.pane_id)"'
}
mkwt() { git init -q "$T/wt/$1"; git -C "$T/wt/$1" commit -q --allow-empty -m init; git -C "$T/wt/$1" checkout -qb "$2"; }
write_task() {  # <id> <key> <name> <ws> <branch>
  local tp tab pane; tp=$(mktab "$4" "$1"); tab=${tp% *}; pane=${tp#* }
  mkwt "$1" "$5"
  printf '%s\n' "worktree=$T/wt/$1" "project=$2" harness=pi model=default kind=ship backend=herdr \
    "herdr_session=$S" "herdr_workspace_id=$4" "herdr_tab_id=$tab" "herdr_pane_id=$pane" \
    herdr_workspace_managed=1 "herdr_project_name=$3" "herdr_project_key=$2" > "$T/home/state/$1.meta"
}
write_task voice-a /projects/glasses-voice 'Glasses Voice' "$SW" fm/voice-a
write_task ymj-scout /projects/your-magical-journey 'Your Magical Journey' "$SW" fm/ymj-scout
write_task ymj-ship /projects/your-magical-journey 'Your Magical Journey' "$SW" fm/ymj-ship
write_task fm-self /projects/firstmate 'Firstmate' "$SW" fm/fm-self
write_task artevo-solo /projects/artevo Artevo "$OW" fm/artevo-solo
printf '%s\n' voice-a=working ymj-scout=parked ymj-ship=working fm-self=working artevo-solo=working > "$T/states"

labels() {  # <heading>
  echo "--- $1"
  "$LAB" run "$S" workspace list | jq -r --arg sw "$SW" --arg ow "$OW" \
    '.result.workspaces[] | select(.workspace_id==$sw or .workspace_id==$ow)
     | "\(if .workspace_id==$sw then "shared " else "single " end) \(.workspace_id): \(.label)"'
}
vs() {  # <bin-dir> <args...>
  local dir=$1; shift
  env -u FM_BACKEND_HERDR_PRESENTATION_FORCE FM_HOME="$T/home" FM_VISIBLE_STATE_FILE="$T/states" \
    "$dir/fm-visible-status.sh" "$@"
}
clear_cache() { rm -f "$T/home/state"/*.visible-label "$T/home/state"/.visible-workspace-*; }

echo "=== BEFORE FIX (base $BASE) ==="
vs "$T/base/bin" --all; labels 'base: --all pass'
vs "$T/base/bin" voice-a; labels 'base: single-task refresh of voice-a (Glasses Voice relabelled last)'
vs "$T/base/bin" ymj-scout; labels 'base: single-task refresh of ymj-scout (YMJ scout started, relabelled last)'

echo "=== AFTER FIX (target) ==="
clear_cache
vs "$ROOT/bin" --all; labels 'target: --all pass'
vs "$ROOT/bin" voice-a; labels 'target: single-task refresh of voice-a'
vs "$ROOT/bin" ymj-scout; labels 'target: single-task refresh of ymj-scout'
echo '--- target: worker rows keep their own project/branch detail'
"$LAB" run "$S" pane list --workspace "$SW" | jq -r '.result.panes[] | select(.tokens.fm_task_id) | "\(.tokens.fm_task_id): title=\(.title // "-") detail=\(.display_agent)"'
"$LAB" view "$S" --cols 160 --rows 30 --format text > "$T/view-mixed.txt" 2>&1 && cp "$T/view-mixed.txt" "$OUT/sidebar-shared-after-fix.txt"

echo "=== ADVERSARIAL: other projects leave the shared workspace ==="
rm -f "$T/home/state/ymj-scout.meta" "$T/home/state/ymj-ship.meta" "$T/home/state/fm-self.meta"
vs "$ROOT/bin" --all; labels 'target: --all after only Glasses Voice remains (cached mixed label must not stick)'
echo "=== ADVERSARIAL: state change in shared ws updates neutral counts ==="
write_task ymj-late /projects/your-magical-journey 'Your Magical Journey' "$SW" fm/ymj-late
printf '%s\n' voice-a=failed ymj-late=working artevo-solo=working > "$T/states"
vs "$ROOT/bin" --all; labels 'target: --all after a YMJ worker rejoins and voice-a fails'
"$LAB" view "$S" --cols 160 --rows 30 --format text > "$OUT/sidebar-shared-rejoin.txt" 2>&1 || true

"$LAB" teardown "$S" && echo "teardown ok (default-session tripwire unchanged)"
trap - EXIT; rm -rf "$T"
