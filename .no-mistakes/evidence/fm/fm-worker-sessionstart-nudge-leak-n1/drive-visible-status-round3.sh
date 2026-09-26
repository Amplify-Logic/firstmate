#!/usr/bin/env bash
# Round 3 live driver: real Herdr 0.7.4 in a guarded fm-lab-* session (every
# call through bin/fm-herdr-lab.sh), a disposable lab FM_HOME minted by
# bin/fm-lab-home.sh, and the real bin/fm-visible-status.sh from the target
# commit d22419d5 plus, for contrast, the previous round's commit b83198a1.
#
# Panes: w1:p1 = primary pane (not a task), w1:p2 = ship worker
# fm-primary-opus-profile-o1, w1:p3 = scout worker fm-worker-fresh-k2,
# w1:p4 = secondmate task pane. The primary marker is the exact
# report-metadata argv bin/fm-primary.sh mark_current_surface sends.
# Worker state comes from the real bin/fm-crew-state.sh (WAITING in this lab);
# where noted, FM_VISIBLE_STATE_FILE pins the ship worker to 'working' so its
# fm_state (WORKING) is distinguishable from the marker's fm_state=WAITING.
set -u
S=$1 LAB=$2 TARGET_ROOT=$3 PREV_ROOT=$4
H() { "$TARGET_ROOT/bin/fm-herdr-lab.sh" run "$S" "$@"; }
mark_primary() { # <pane>
  H pane report-metadata "$1" --source firstmate-primary-visible-v1 \
    --title "FIRSTMATE · WAITING" --display-agent "FIRSTMATE · WAITING" \
    --state-label "working=SUPERVISING" --state-label "blocked=NEEDS LARS" \
    --state-label "idle=WAITING" --state-label "done=WAITING" \
    --token "fm_role=FIRSTMATE" --token "fm_state=WAITING" >/dev/null
}
show() { # <pane...>
  local all p
  all=$(H pane list --workspace w1)
  for p in "$@"; do
    printf '%s' "$all" | jq -c --arg p "$p" '.result.panes[] | select(.pane_id == $p)
      | {pane_id, title, display_agent, idle: .state_labels.idle, tokens}'
  done
}
tabs() { H tab list --workspace w1 | jq -c '[.result.tabs[] | {tab_id: .tab_id, label: .label}]'; }
vs() { # <root> <args...>
  local root=$1; shift
  printf '$ %s fm-visible-status.sh %s%s\n' "$(git -C "$root" log --oneline -1 | cut -c1-8)" "$*" \
    "${PIN:+   [FM_VISIBLE_STATE_FILE pins ship=working]}"
  if [ -n "${PIN:-}" ]; then
    env -u FM_ROOT_OVERRIDE -u FM_STATE_OVERRIDE FM_VISIBLE_STATE_FILE="$PIN" FM_HOME="$LAB" \
      "$root/bin/fm-visible-status.sh" "$@"
  else
    env -u FM_ROOT_OVERRIDE -u FM_STATE_OVERRIDE -u FM_VISIBLE_STATE_FILE FM_HOME="$LAB" \
      "$root/bin/fm-visible-status.sh" "$@"
  fi
  echo "exit=$?"
}

echo "## S3  primary session start: primary pane marked, then --all --republish (target)"
mark_primary w1:p1
vs "$TARGET_ROOT" --all --republish
show w1:p1 w1:p2 w1:p3 w1:p4
echo "tabs: $(tabs)"
echo "cached labels: $(cd "$LAB/state" && ls *.visible-label | tr '\n' ' ')"

echo
echo "## S4  non-regression: ordinary cached --all pass keeps worker metadata incl. fm_state (target)"
vs "$TARGET_ROOT" --all
show w1:p2 w1:p3
echo "-- contrast, previous round b83198a1 on the same cached panes:"
vs "$PREV_ROOT" --all
show w1:p2 w1:p3
echo "-- next target pass restores it:"
vs "$TARGET_ROOT" --all
show w1:p2 w1:p3

echo
echo "## S5  ADVERSARIAL: worker w1:p2 runs the primary launcher AFTER its label was cached (state from fm-crew-state)"
mark_primary w1:p2
echo "-- after primary mark on worker pane:"; show w1:p2
vs "$TARGET_ROOT" --all
show w1:p1 w1:p2

echo
echo "## S6  ADVERSARIAL with distinct worker state: ship pinned to 'working', label cached, then marker lands"
PIN=$LAB/pin-states; printf 'fm-primary-opus-profile-o1=working\n' > "$PIN"; export PIN
vs "$TARGET_ROOT" --all          # state changed -> real republish
show w1:p2
vs "$TARGET_ROOT" --all          # now cached
show w1:p2
mark_primary w1:p2
echo "-- after primary mark on worker pane (marker fm_state=WAITING overwrote WORKING):"; show w1:p2
vs "$TARGET_ROOT" --all          # ordinary cached pass
show w1:p2
echo "-- a second cached pass is stable:"
vs "$TARGET_ROOT" --all
show w1:p2
echo "cached label record: $(cat "$LAB/state/fm-primary-opus-profile-o1.visible-label")"

echo
echo "## S7  state change after caching republishes the new state (ship -> blocked)"
printf 'fm-primary-opus-profile-o1=blocked\n' > "$PIN"
vs "$TARGET_ROOT" --all
show w1:p2
unset PIN

echo
echo "## S8  boundary: primary pane w1:p1 and secondmate pane w1:p4 keep what they had"
mark_primary w1:p4
vs "$TARGET_ROOT" --all
vs "$TARGET_ROOT" --all --republish
show w1:p1 w1:p4
echo "tabs: $(tabs)"
