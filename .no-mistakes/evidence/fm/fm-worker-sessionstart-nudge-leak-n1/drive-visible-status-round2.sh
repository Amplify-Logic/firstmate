#!/usr/bin/env bash
# Round 2 live driver: real Herdr 0.7.4 in a guarded fm-lab-* session (every
# call through bin/fm-herdr-lab.sh), a disposable lab FM_HOME minted by
# bin/fm-lab-home.sh, and the real bin/fm-visible-status.sh from the target
# commit (b83198a1) plus, for contrast, the previous fix commit (ffe98730).
#
# Panes: w1:p1 = primary pane (not a task), w1:p2 = ship worker
# fm-primary-opus-profile-o1, w1:p3 = scout worker fm-worker-fresh-k2,
# w1:p4 = secondmate task pane.
# The primary marker is applied with the exact report-metadata argv that
# bin/fm-primary.sh mark_current_surface sends.
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
      | {pane_id, title, display_agent, fm_role: .tokens.fm_role, fm_state: .tokens.fm_state,
         fm_task_id: .tokens.fm_task_id, idle: .state_labels.idle}'
  done
}
tabs() { H tab list --workspace w1 | jq -c '[.result.tabs[] | {tab_id, label}]'; }
vs() { # <root> <args...>
  local root=$1; shift
  env -u FM_ROOT_OVERRIDE -u FM_STATE_OVERRIDE -u FM_VISIBLE_STATE_FILE FM_HOME="$LAB" \
    "$root/bin/fm-visible-status.sh" "$@"
  echo "exit=$?"
}

echo "## S1  primary session start: primary pane marked, then fm-visible-status.sh --all --republish (target)"
mark_primary w1:p1
vs "$TARGET_ROOT" --all --republish
show w1:p1 w1:p2 w1:p3 w1:p4
tabs
echo "cached labels: $(cd "$LAB/state" && ls *.visible-label | tr '\n' ' ')"

echo
echo "## S2  ADVERSARIAL: worker w1:p2 runs the primary launcher AFTER its label was cached"
mark_primary w1:p2
echo "-- after primary mark on worker pane:"
show w1:p2
echo "-- tab list before ordinary pass: $(tabs)"
echo "\$ fm-visible-status.sh --all      # ordinary watcher pass, cache unchanged (target b83198a1)"
vs "$TARGET_ROOT" --all
show w1:p1 w1:p2 w1:p3 w1:p4
echo "-- tab list after ordinary pass:  $(tabs)"

echo
echo "## S2-contrast  same adversarial sequence with the previous commit (ffe98730)"
mark_primary w1:p2
echo "\$ ffe98730 fm-visible-status.sh --all"
vs "$PREV_ROOT" --all
show w1:p2
echo "\$ target b83198a1 fm-visible-status.sh --all   (next ordinary pass after upgrade)"
vs "$TARGET_ROOT" --all
show w1:p2

echo
echo "## S3  single-task refresh (spawn/push-transition path) clears a marker on w1:p3"
mark_primary w1:p3
show w1:p3
echo "\$ fm-visible-status.sh fm-worker-fresh-k2"
vs "$TARGET_ROOT" fm-worker-fresh-k2
show w1:p3

echo
echo "## S4  boundary: primary pane w1:p1 and secondmate pane w1:p4 keep what they had"
mark_primary w1:p4
vs "$TARGET_ROOT" --all
vs "$TARGET_ROOT" --all --republish
show w1:p1 w1:p4
