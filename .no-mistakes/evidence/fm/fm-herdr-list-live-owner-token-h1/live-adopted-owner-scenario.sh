#!/usr/bin/env bash
# Live scenario driver for fm/fm-herdr-list-live-owner-token-h1.
# Usage: live-adopted-owner-scenario.sh <code-root> <lab-label>
# Runs the REAL bin/fm-spawn.sh from <code-root> inside an isolated fm-lab-*
# Herdr session provisioned through <worktree>/bin/fm-herdr-lab.sh, from:
#   - no launcher (outside Herdr)            -> created project workspace
#   - a captain pane in an untokened space   -> adopted, must be bound + listed
#   - a pane in another home's tokened space -> adopted, must NOT be claimed
#   - a pane in a 2ndmate-<id> labeled space -> adopted, must NOT be claimed
#   - no launcher again                      -> must reuse the created workspace
# then prints fm_backend_herdr_list_live and every workspace's tokens.
set -u
CODE=$1
LABEL=$2
WT=/Users/larsmusic/.no-mistakes/worktrees/f569cc43ac96/01M3FHQC7WM337C2ZENX6639PD
HELPER="$WT/bin/fm-herdr-lab.sh"
. "$WT/tests/herdr-test-safety.sh"
herdr_forget_inherited_pane

TMP_ROOT=$(mktemp -d "$(cd "${TMPDIR:-/tmp}" && pwd -P)/fm-live-adopt.XXXXXX")
SESSION=$("$HELPER" name "$LABEL") || exit 1
export HERDR_SESSION="$SESSION"
WORKTREES=()
cleanup() {
  local wt
  for wt in ${WORKTREES[@]+"${WORKTREES[@]}"}; do treehouse return --force "$wt" >/dev/null 2>&1; done
  echo "== teardown =="
  "$HELPER" teardown "$SESSION"; echo "teardown rc=$?"
  find "$TMP_ROOT" -type d -exec chmod u+rwx {} + 2>/dev/null
  rm -rf "$TMP_ROOT"
}
trap cleanup EXIT
"$HELPER" provision "$SESSION" || { echo "provision failed"; exit 1; }
echo "lab session: $SESSION   code root: $CODE"
lab() { "$HELPER" run "$SESSION" "$@"; }
LAB_SOCKET=$(lab session list --json | jq -r --arg s "$SESSION" '.sessions[]|select(.name==$s)|.socket_path')

. "$CODE/bin/fm-backend.sh"; fm_backend_source herdr

HOME_DIR="$TMP_ROOT/primary-home"; OTHER_HOME="$TMP_ROOT/other-home"
mkdir -p "$HOME_DIR/state" "$HOME_DIR/config" "$OTHER_HOME"
printf 'off\n' > "$HOME_DIR/config/herdr-presentation-spaces"
PROJ="$TMP_ROOT/scratch-project"
mkdir -p "$PROJ"; git -C "$PROJ" init -q; echo '# s' > "$PROJ/README.md"; git -C "$PROJ" add README.md
git -C "$PROJ" -c user.name=t -c user.email=t@example.invalid commit -qm init
git clone -q --bare "$PROJ" "$PROJ.origin.git"; git -C "$PROJ" remote add origin "file://$PROJ.origin.git"

mkws() { lab workspace create --cwd "$TMP_ROOT" --label "$1" --no-focus | jq -r '[.result.workspace.workspace_id,.result.root_pane.pane_id]|@tsv'; }
read -r CAP_WS CAP_PANE < <(mkws captain-shell)
read -r FOR_WS FOR_PANE < <(mkws their-shell)
read -r SIB_WS SIB_PANE < <(mkws 2ndmate-sib)
OTHER_TOKEN=$(fm_backend_herdr_identity_token "$OTHER_HOME")
lab workspace report-metadata "$FOR_WS" --source firstmate-project-identity-v1 --token "fm_owner=$OTHER_TOKEN" >/dev/null
echo "captain=$CAP_WS($CAP_PANE) foreign=$FOR_WS($FOR_PANE) sibling=$SIB_WS($SIB_PANE)"

spawn() {  # <pane|""> <id>
  local pane=$1 id=$2 rc
  mkdir -p "$HOME_DIR/data/$id"
  printf '# Task\n## Captain'"'"'s intent\nLive lab placement check.\n\n## Firstmate spec\nNothing to do.\n' > "$HOME_DIR/data/$id/brief.md"
  if [ -n "$pane" ]; then
    env HERDR_ENV=1 HERDR_PANE_ID="$pane" HERDR_SESSION="$SESSION" HERDR_SOCKET_PATH="$LAB_SOCKET" \
      FM_SPAWN_NO_GUARD=1 FM_HOME="$HOME_DIR" FM_ROOT_OVERRIDE="$CODE" \
      "$CODE/bin/fm-spawn.sh" "$id" "$PROJ" "sh -c 'echo $id-ok; exec sleep 600'" --mode local-only --yolo off --backend herdr \
      >"$TMP_ROOT/$id.out" 2>"$TMP_ROOT/$id.err"
  else
    env -u HERDR_ENV -u HERDR_PANE_ID -u HERDR_SOCKET_PATH HERDR_SESSION="$SESSION" \
      FM_SPAWN_NO_GUARD=1 FM_HOME="$HOME_DIR" FM_ROOT_OVERRIDE="$CODE" \
      "$CODE/bin/fm-spawn.sh" "$id" "$PROJ" "sh -c 'echo $id-ok; exec sleep 600'" --mode local-only --yolo off --backend herdr \
      >"$TMP_ROOT/$id.out" 2>"$TMP_ROOT/$id.err"
  fi
  rc=$?
  local wt pane_id ws
  wt=$(grep '^worktree=' "$HOME_DIR/state/$id.meta" 2>/dev/null | cut -d= -f2-); [ -n "$wt" ] && WORKTREES+=("$wt")
  pane_id=$(grep '^herdr_pane_id=' "$HOME_DIR/state/$id.meta" 2>/dev/null | cut -d= -f2-)
  ws=$(lab pane get "$pane_id" 2>/dev/null | jq -r '.result.pane.workspace_id // empty')
  echo "spawn $id from launcher '${pane:-<none>}': rc=$rc pane=$pane_id workspace=$ws"
  grep -i 'warning\|error' "$TMP_ROOT/$id.err" | sed 's/^/    stderr: /'
}

spawn "" created-task
spawn "$CAP_PANE" adopted-task
spawn "$FOR_PANE" foreign-placed-task
spawn "$SIB_PANE" sibling-placed-task
spawn "" created-again-task

echo "== workspace list (label + tokens) =="
lab workspace list | jq -r '.result.workspaces[]|"\(.workspace_id)\t\(.label)\t\(.tokens|tojson)"'
echo "== home owner token: $(fm_backend_herdr_identity_token "$HOME_DIR")"
echo "== fm_backend_herdr_list_live $SESSION (FM_HOME=primary-home) =="
FM_HOME="$HOME_DIR" fm_backend_herdr_list_live "$SESSION"
echo "== end list_live =="
