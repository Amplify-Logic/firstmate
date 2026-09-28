#!/usr/bin/env bash
# Scenario A: the captain approves (answers) a live call through the real
# fm-captain-hold.sh; the voice waiting count/list and Bearings agree before and after.
# Scenario B: fault injection - the canonical classifier fails; the voice status
# must refuse (non-zero, clear error) rather than guess counts.
set -u
WT=/Users/larsmusic/.no-mistakes/worktrees/f569cc43ac96/01M3M0G04ZGSZ6JHBBGYG7RKQD
LAB=$(mktemp -d "${TMPDIR:-/tmp}/fm-lab.XXXXXX"); FAULT=$(mktemp -d "${TMPDIR:-/tmp}/fm-fault.XXXXXX")
trap 'rm -rf "$LAB" "$FAULT"' EXIT
rm -rf "$LAB"; "$WT/bin/fm-lab-home.sh" create "$LAB" >/dev/null
cp "$WT/.tasks.toml" "$LAB/.tasks.toml"
printf '## In flight\n\n## Queued\n\n## Done\n' > "$LAB/data/backlog.md"; : > "$LAB/data/secondmates.md"
FB="$LAB/fakebin"; mkdir -p "$FB"
for t in tmux treehouse no-mistakes gh gh-axi; do printf '#!/bin/sh\nexit 0\n' > "$FB/$t"; chmod +x "$FB/$t"; done
clean() { env -u FM_STATE_OVERRIDE -u FM_DATA_OVERRIDE -u FM_CONFIG_OVERRIDE -u FM_ROOT_OVERRIDE -u FM_PROJECTS_OVERRIDE PATH="$FB:$PATH" FM_HOME="$LAB" "$@"; }
hold() { clean REAL_TASKS_AXI="$(command -v tasks-axi)" "$WT/bin/fm-captain-hold.sh" "$@"; }
for n in spend pricing launch; do
  hold hold "call-$n" --title "Approve the $n" --reason "approve the $n?" --repo firstmate >/dev/null || echo "hold $n failed"
done
(cd "$LAB" && tasks-axi add todo-captain "Captain's own to-do" --kind captain --repo firstmate >/dev/null) || echo "todo add failed"
report() {
  echo "--- voice status --scope full"
  clean python3 "$WT/bin/fm_voice_records.py" status --home "$LAB" --scope full \
    | jq -c '{awaiting_captain, deferred_for_captain, queued, named:[.awaiting_captain_detail[]?.id]}'
  echo "--- bearings --json"
  clean "$WT/bin/fm-bearings-snapshot.sh" --json | jq -c '{decisions_open_total, decision_ids:[.decisions_open[].id]}'
}
echo "=== backlog after three holds and one kind:captain to-do ==="; grep -E '^- \[' "$LAB/data/backlog.md"
report
printf 'Captain approved the spend.\n' > "$LAB/decision.txt"
echo "=== captain approves call-spend (fm-captain-hold.sh answer) ==="
hold answer call-spend --decision-file "$LAB/decision.txt" >/dev/null && echo "answer ok"
report
echo "=== FAULT: canonical classifier (fm-fleet-snapshot.sh --backlog) fails ==="
cp -R "$WT/bin" "$FAULT/bin"
printf '#!/bin/sh\necho "simulated classifier failure" >&2\nexit 1\n' > "$FAULT/bin/fm-fleet-snapshot.sh"
clean python3 "$FAULT/bin/fm_voice_records.py" status --home "$LAB" --scope counts; echo "exit=$?"
