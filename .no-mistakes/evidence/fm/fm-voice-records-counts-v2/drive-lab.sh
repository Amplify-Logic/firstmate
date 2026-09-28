#!/usr/bin/env bash
# Drives the real fm_voice_records.py status and fm-bearings-snapshot.sh --json
# against a disposable lab home reproducing the audit's three causes, once with
# the base commit's bin/ and once with the target commit's bin/.
set -u
WT=/Users/larsmusic/.no-mistakes/worktrees/f569cc43ac96/01M3M0G04ZGSZ6JHBBGYG7RKQD
BASE=bc7349c4702b783c96cfd8a8743cad82278f2559
LAB=$(mktemp -d "${TMPDIR:-/tmp}/fm-lab.XXXXXX")
BASEBIN=$(mktemp -d "${TMPDIR:-/tmp}/fm-base.XXXXXX")
trap 'rm -rf "$LAB" "$BASEBIN"' EXIT
rm -rf "$LAB"; "$WT/bin/fm-lab-home.sh" create "$LAB" >/dev/null
git -C "$WT" archive "$BASE" bin | tar -x -C "$BASEBIN"
# Offline stubs for external network/terminal tools only (not the product).
FB="$LAB/fakebin"; mkdir -p "$FB"
printf '#!/bin/sh\necho "[]"\n' > "$FB/gh"; printf '#!/bin/sh\nexit 0\n' > "$FB/gh-axi"
printf '#!/bin/sh\nexit 0\n' > "$FB/no-mistakes"; printf '#!/bin/sh\nexit 1\n' > "$FB/tmux"
chmod +x "$FB"/*
{
echo "# Backlog"; echo; echo "## In flight"
echo "- [ ] live-ship - Ship the importer (repo: firstmate) (kind: ship) (since 2026-09-27)"
echo "- [ ] held-run - Ship the exporter (repo: firstmate) (kind: ship) (since 2026-09-27) (hold: land it?) (hold-kind: captain)"
echo "  Captain hold set: 2026-09-27T00:00:00Z"
echo; echo "## Queued"
echo "- [ ] call-desk-trigger-wake-t1 - Wake the call desk (repo: firstmate) (kind: ship)"
echo "- [ ] krisp-call-notes-inbox-k1 - Krisp call notes into the inbox (repo: firstmate) (kind: ship)"
for i in $(seq -w 1 22); do
  echo "- [ ] call-$i - Live captain call $i (repo: firstmate) (kind: ship) (since 2026-09-27) (hold: approve $i?) (hold-kind: captain)"
  echo "  Captain hold set: 2026-09-27T00:00:00Z"
done
for i in $(seq -w 1 10); do echo "- [ ] todo-$i - Captain to-do $i (repo: firstmate) (kind: captain)"; done
for i in $(seq -w 1 5); do
  echo "- [ ] later-$i - Dated hold $i (repo: firstmate) (kind: ship) (hold: later $i) (hold-kind: captain) (hold-until: 2999-01-01)"; done
for i in $(seq -w 1 4); do
  echo "- [ ] old-$i - Aged hold $i (repo: firstmate) (kind: ship) (since 2000-01-01) (hold: which $i) (hold-kind: captain)"; done
for i in $(seq -w 1 3); do
  echo "- [ ] blocked-$i - Blocked hold $i blocked-by: live-ship (repo: firstmate) (kind: ship) (hold: launch $i?) (hold-kind: captain)"; done
echo; echo "## Done"
echo "- [x] finished-ship - Finished, cleanup pending (repo: firstmate) (kind: ship) (done 2026-09-27)"
} > "$LAB/data/backlog.md"
: > "$LAB/data/secondmates.md"
for id in live-ship held-run call-desk-trigger-wake-t1 krisp-call-notes-inbox-k1 finished-ship unlisted-task; do
  { echo "window=firstmate:fm-$id"; echo "worktree=$LAB/projects/$id"; echo "project=firstmate"
    echo "harness=codex"; echo "kind=ship"; echo "mode=no-mistakes"
    echo "pr=https://github.com/example/firstmate/pull/${#id}"; } > "$LAB/state/$id.meta"
done
mkdir -p "$LAB/projects/live-ship" "$LAB/projects/held-run" "$LAB/projects/unlisted-task"  # requeued ones: worktree gone
echo 'working: importing' > "$LAB/state/live-ship.status"
echo 'blocked: waiting on captain' > "$LAB/state/held-run.status"
echo 'torn-down: worktree removed' > "$LAB/state/call-desk-trigger-wake-t1.status"
echo 'torn-down: worktree removed' > "$LAB/state/krisp-call-notes-inbox-k1.status"
echo 'done: shipped' > "$LAB/state/finished-ship.status"

run_side() { # <label> <bindir>
  local label=$1 bin=$2
  echo "=================== $label ==================="
  echo "--- voice status --scope counts"
  env -u FM_STATE_OVERRIDE -u FM_DATA_OVERRIDE -u FM_CONFIG_OVERRIDE -u FM_ROOT_OVERRIDE \
    FM_HOME="$LAB" python3 "$bin/fm_voice_records.py" status --home "$LAB" --scope counts 2>&1
  echo "--- voice status --scope full (selected fields)"
  env -u FM_STATE_OVERRIDE -u FM_DATA_OVERRIDE -u FM_CONFIG_OVERRIDE -u FM_ROOT_OVERRIDE \
    FM_HOME="$LAB" python3 "$bin/fm_voice_records.py" status --home "$LAB" --scope full 2>&1 \
    | jq '{workers_on_deck, worker_states, in_flight, in_flight_held, awaiting_captain, deferred_for_captain, queued, open_pull_requests,
           in_flight_detail, pull_request_ids: [.pull_request_detail[]?.id], awaiting_captain_named: [.awaiting_captain_detail[]?.id]}' 2>&1
  echo "--- bearings --json (selected fields)"
  env -u FM_STATE_OVERRIDE -u FM_DATA_OVERRIDE -u FM_CONFIG_OVERRIDE -u FM_ROOT_OVERRIDE \
    PATH="$FB:$PATH" FM_HOME="$LAB" "$bin/fm-bearings-snapshot.sh" --json 2>&1 \
    | jq '{in_flight_ids: [.in_flight[].id], decisions_open_shown: (.decisions_open|length), decisions_open_total, omitted,
           queued_gate_ids_present: ([.gates[].id] | map(select(. == "call-desk-trigger-wake-t1" or . == "krisp-call-notes-inbox-k1")))}' 2>&1
}
run_side "BASE bc7349c4" "$BASEBIN/bin"
run_side "TARGET 3c6d2a07" "$WT/bin"
echo "=================== ADVERSARIAL: classifier failure (TARGET) ==================="
chmod 000 "$LAB/data/backlog.md"
env -u FM_STATE_OVERRIDE -u FM_DATA_OVERRIDE FM_HOME="$LAB" python3 "$WT/bin/fm_voice_records.py" status --home "$LAB" --scope counts; echo "exit=$?"
chmod 644 "$LAB/data/backlog.md"
echo "--- fm-fleet-snapshot.sh --backlog (TARGET) record count / sample"
FM_HOME="$LAB" "$WT/bin/fm-fleet-snapshot.sh" --backlog | jq '{n:(.records|length), live:([.records[]|select(.hold_bucket=="live")]|length), sample:(.records[0]|{id,state,current_role,hold_bucket})}'
