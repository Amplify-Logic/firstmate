#!/usr/bin/env bash
# End-to-end fake-Herdr-CLI coverage for single and batch fm-spawn presentation.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

command -v jq >/dev/null 2>&1 || { echo 'skip: jq not found'; exit 0; }

TMP_ROOT=$(fm_test_tmproot fm-spawn-herdr-presentation)
HOME_FIX="$TMP_ROOT/home"
FAKEBIN=$(fm_fakebin "$TMP_ROOT")
HERDR_STATE="$TMP_ROOT/herdr-state.json"
HERDR_LOG="$TMP_ROOT/herdr.log"
WT_ROOT="$TMP_ROOT/worktrees"
mkdir -p "$HOME_FIX/state" "$HOME_FIX/data" "$HOME_FIX/config" "$WT_ROOT"
printf '{"next":1,"workspaces":[],"tabs":[]}\n' > "$HERDR_STATE"
: > "$HERDR_LOG"

cat > "$FAKEBIN/treehouse" <<'SH'
#!/usr/bin/env bash
exit 0
SH

cat > "$FAKEBIN/herdr" <<'SH'
#!/usr/bin/env bash
set -u
state=${FM_FAKE_HERDR_STATE:?}
log=${FM_FAKE_HERDR_LOG:?}
{
  for arg in "$@"; do printf '<%s>' "$arg"; done
  printf '\n'
} >> "$log"

save() { local tmp="$state.tmp.$$"; cat > "$tmp" && mv "$tmp" "$state"; }
query() { jq "$@" "$state"; }
args=("$@")
cmd=${1:-}; sub=${2:-}; workspace= label= cwd=
tokens=(); clears=()
for ((i=0; i<${#args[@]}; i++)); do
  case "${args[$i]}" in
    --workspace) workspace=${args[$((i+1))]:-} ;;
    --label) label=${args[$((i+1))]:-} ;;
    --cwd) cwd=${args[$((i+1))]:-} ;;
    --token) tokens+=("${args[$((i+1))]:-}") ;;
    --clear-token) clears+=("${args[$((i+1))]:-}") ;;
  esac
done

case "$cmd $sub" in
  'status --json')
    printf '{"client":{"version":"0.7.4","protocol":16},"server":{"running":true}}\n'
    ;;
  'workspace list') query '{result:{workspaces:.workspaces}}' ;;
  'workspace create')
    n=$(query -r .next); ws="w$n"; tab="$ws:t1"; pane="$ws:p1"
    query --arg ws "$ws" --arg label "$label" --arg tab "$tab" --arg pane "$pane" --arg cwd "$cwd" '
      .next += 1 |
      .workspaces += [{workspace_id:$ws,label:$label,tokens:{}}] |
      .tabs += [{workspace_id:$ws,tab_id:$tab,pane_id:$pane,label:"1",cwd:$cwd,tokens:{}}]' | save
    jq -n --arg ws "$ws" --arg tab "$tab" --arg pane "$pane" \
      '{result:{workspace:{workspace_id:$ws},tab:{tab_id:$tab},root_pane:{pane_id:$pane}}}'
    ;;
  'workspace report-metadata')
    target=${3:-}
    for token in "${tokens[@]}"; do
      key=${token%%=*}; value=${token#*=}
      query --arg id "$target" --arg key "$key" --arg value "$value" \
        '.workspaces |= map(if .workspace_id == $id then (.tokens[$key]=$value) else . end)' | save
    done
    ;;
  'workspace rename')
    target=${3:-}; value=${4:-}
    query --arg id "$target" --arg value "$value" \
      '.workspaces |= map(if .workspace_id == $id then .label=$value else . end)' | save
    ;;
  'tab list') query --arg ws "$workspace" '{result:{tabs:[.tabs[]|select(.workspace_id==$ws)]}}' ;;
  'tab create')
    n=$(query -r .next); tab="$workspace:t$n"; pane="$workspace:p$n"
    query --arg ws "$workspace" --arg tab "$tab" --arg pane "$pane" --arg label "$label" --arg cwd "$cwd" '
      .next += 1 |
      .tabs += [{workspace_id:$ws,tab_id:$tab,pane_id:$pane,label:$label,cwd:$cwd,tokens:{}}]' | save
    jq -n --arg tab "$tab" --arg pane "$pane" '{result:{tab:{tab_id:$tab},root_pane:{pane_id:$pane}}}'
    ;;
  'tab rename')
    target=${3:-}; value=${4:-}
    query --arg id "$target" --arg value "$value" \
      '.tabs |= map(if .tab_id == $id then .label=$value else . end)' | save
    ;;
  'tab close')
    target=${3:-}
    query --arg id "$target" '.tabs |= map(select(.tab_id != $id))' | save
    ;;
  'pane list')
    query --arg ws "$workspace" '{result:{panes:[.tabs[]|select(.workspace_id==$ws)|{workspace_id,tab_id,pane_id,tokens}]}}'
    ;;
  'pane report-metadata')
    target=${3:-}
    for token in "${tokens[@]}"; do
      key=${token%%=*}; value=${token#*=}
      query --arg id "$target" --arg key "$key" --arg value "$value" \
        '.tabs |= map(if .pane_id == $id then (.tokens[$key]=$value) else . end)' | save
    done
    for key in ${clears[@]+"${clears[@]}"}; do
      query --arg id "$target" --arg key "$key" \
        '.tabs |= map(if .pane_id == $id then .tokens |= del(.[$key]) else . end)' | save
    done
    ;;
  'pane get')
    target=${3:-}
    query --arg id "$target" '{result:{pane:(.tabs[]|select(.pane_id==$id)|{pane_id,workspace_id,tab_id,foreground_cwd:.cwd,cwd:.cwd})}}'
    ;;
  'pane run')
    target=${3:-}; command=${4:-}
    if [ "$command" = 'treehouse get' ]; then
      project=$(query -r --arg id "$target" '.tabs[]|select(.pane_id==$id)|.cwd')
      safe=${target//[:\/]/_}; wt="$FM_FAKE_WT_ROOT/$safe"
      git -C "$project" worktree add -q --detach "$wt" HEAD
      query --arg id "$target" --arg wt "$wt" \
        '.tabs |= map(if .pane_id == $id then .cwd=$wt else . end)' | save
    fi
    ;;
  'pane close')
    target=${3:-}
    query --arg id "$target" '.tabs |= map(select(.pane_id != $id))' | save
    ;;
  'pane read'|'pane send-text'|'pane send-keys') : ;;
  'agent get') printf '{"result":{"agent":{"agent":"pi","agent_status":"idle"}}\n' ;;
  *) : ;;
esac
SH
chmod +x "$FAKEBIN/herdr" "$FAKEBIN/treehouse"

make_project() {  # <slug>
  local dir="$TMP_ROOT/$1"
  fm_git_init_commit "$dir"
  printf '%s' "$dir"
}

JOURNEY=$(make_project your-magical-journey)
ARTEVO=$(make_project artevo)
for id in journey-single journey-batch-one journey-batch-two artevo-single; do
  mkdir -p "$HOME_FIX/data/$id"
  printf 'fake spawn instructions for %s\n' "$id" > "$HOME_FIX/data/$id/brief.md"
done
cat > "$HOME_FIX/data/projects.md" <<'EOF'
- your-magical-journey [local-only] - Journey
- artevo [local-only] - Artevo
EOF
cat > "$HOME_FIX/data/backlog.md" <<'EOF'
- [ ] journey-single - Validate GPS triggers across all seven Amsterdam stops (repo: your-magical-journey)
- [ ] journey-batch-one - Rebaseline the Your Magical Journey launch plan with a date (repo: your-magical-journey)
- [ ] journey-batch-two - Audit the Journey release checklist (repo: your-magical-journey)
- [ ] artevo-single - Align Artevo launch surfaces (repo: artevo)
EOF
cat > "$TMP_ROOT/states" <<'EOF'
journey-single=working
journey-batch-one=parked
journey-batch-two=working
artevo-single=blocked
EOF

run_spawn() {
  PATH="$FAKEBIN:$PATH" \
    FM_HOME="$HOME_FIX" \
    FM_ROOT_OVERRIDE="$ROOT" \
    FM_SPAWN_NO_GUARD=1 \
    FM_FAKE_HERDR_STATE="$HERDR_STATE" \
    FM_FAKE_HERDR_LOG="$HERDR_LOG" \
    FM_FAKE_WT_ROOT="$WT_ROOT" \
    FM_VISIBLE_STATE_FILE="$TMP_ROOT/states" \
    HERDR_SESSION=fm-lab-fake-presentation \
    "$ROOT/bin/fm-spawn.sh" "$@"
}

run_spawn journey-single "$JOURNEY" --harness pi --backend herdr >/dev/null \
  || fail 'single Journey Herdr spawn failed'
run_spawn \
  "journey-batch-one=$JOURNEY" \
  "journey-batch-two=$JOURNEY" \
  --scout --harness codex --backend herdr >/dev/null \
  || fail 'batch Journey Herdr spawn failed'
run_spawn artevo-single "$ARTEVO" --harness codex --backend herdr --outcome 'Align Artevo launch surfaces' >/dev/null \
  || fail 'concurrent Artevo Herdr spawn failed'

journey_path=$(cd "$JOURNEY" && pwd -P)
artevo_path=$(cd "$ARTEVO" && pwd -P)
home_path=$(cd "$HOME_FIX" && pwd -P)
journey_key="path-v1:$(printf '%s' "$journey_path" | git -C "$ROOT" hash-object --stdin)"
artevo_key="path-v1:$(printf '%s' "$artevo_path" | git -C "$ROOT" hash-object --stdin)"
home_key="path-v1:$(printf '%s' "$home_path" | git -C "$ROOT" hash-object --stdin)"
workspace_count=$(jq '.workspaces|length' "$HERDR_STATE")
[ "$workspace_count" -eq 2 ] || fail "expected one workspace per project, got $workspace_count"
journey_ws=$(jq -r --arg owner "$home_key" --arg project "$journey_key" \
  '.workspaces[]|select(.tokens.fm_owner==$owner and .tokens.fm_project==$project)|.workspace_id' "$HERDR_STATE")
artevo_ws=$(jq -r --arg owner "$home_key" --arg project "$artevo_key" \
  '.workspaces[]|select(.tokens.fm_owner==$owner and .tokens.fm_project==$project)|.workspace_id' "$HERDR_STATE")
[ -n "$journey_ws" ] && [ -n "$artevo_ws" ] && [ "$journey_ws" != "$artevo_ws" ] \
  || fail 'concurrent project workspaces did not get distinct hidden identities'
[ "$(jq --arg ws "$journey_ws" '[.tabs[]|select(.workspace_id==$ws)]|length' "$HERDR_STATE")" -eq 3 ] \
  || fail 'single and batch Journey spawns did not converge on one project workspace'
assert_contains "$(jq -r --arg ws "$journey_ws" '.workspaces[]|select(.workspace_id==$ws)|.label' "$HERDR_STATE")" \
  'Your Magical Journey' 'Journey workspace lost its human project name'
assert_contains "$(jq -r --arg ws "$artevo_ws" '.workspaces[]|select(.workspace_id==$ws)|.label' "$HERDR_STATE")" \
  'Artevo' 'Artevo workspace lost its human project name'

labels=$(jq -r '.tabs[].label' "$HERDR_STATE")
assert_contains "$labels" 'WORKER · Validate GPS triggers across all seven Amsterdam stops · 🔵 WORKING' \
  'single spawn did not render backlog outcome and authoritative state'
assert_contains "$labels" 'WORKER · Rebaseline the Your Magical Journey launch plan with a date · 🟣 NEEDS LARS' \
  'first batch scout did not render its distinct outcome'
assert_contains "$labels" 'WORKER · Audit the Journey release checklist · 🔵 WORKING' \
  'second batch scout did not render its distinct outcome'
assert_contains "$labels" 'WORKER · Align Artevo launch surfaces · 🟠 BLOCKED' \
  'concurrent project explicit outcome did not render'
for id in journey-single journey-batch-one journey-batch-two artevo-single; do
  [ "$(jq -r --arg id "$id" '.tabs[]|select(.tokens.fm_task_id==$id)|.tokens.fm_task_id' "$HERDR_STATE")" = "$id" ] \
    || fail "spawned pane missing hidden fm_task_id=$id"
done
assert_contains "$(cat "$HOME_FIX/state/journey-single.meta")" 'harness=pi' 'Pi runtime was not preserved'
assert_contains "$(cat "$HOME_FIX/state/journey-batch-one.meta")" 'harness=codex' 'Codex runtime was not preserved'
assert_contains "$(cat "$HOME_FIX/state/journey-single.meta")" 'kind=ship' 'ship kind was not preserved'
assert_contains "$(cat "$HOME_FIX/state/journey-batch-one.meta")" 'kind=scout' 'scout kind was not preserved'
pass 'fm-spawn fake Herdr E2E: single, batch, projects, axes, human labels, outcomes, states, and hidden ids converge'
