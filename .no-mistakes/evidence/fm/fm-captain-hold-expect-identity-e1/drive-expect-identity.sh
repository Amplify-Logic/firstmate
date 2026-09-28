#!/usr/bin/env bash
# Live driver: real bin/fm-captain-hold.sh + real tasks-axi against a disposable lab FM_HOME.
set -u
WT=$1
LAB=$(mktemp -d "${TMPDIR:-/tmp}/fm-lab.XXXXXX"); rmdir "$LAB"
"$WT/bin/fm-lab-home.sh" create "$LAB" >/dev/null
cp "$WT/.tasks.toml" "$LAB/.tasks.toml"
printf '## In flight\n\n## Queued\n\n## Done\n' > "$LAB/data/backlog.md"
CH() { env -u NO_MISTAKES_GATE -u FM_ROOT_OVERRIDE -u FM_STATE_OVERRIDE -u FM_DATA_OVERRIDE -u FM_CONFIG_OVERRIDE -u FM_PROJECTS_OVERRIDE FM_HOME="$LAB" "$WT/bin/fm-captain-hold.sh" "$@"; }
T() { (cd "$LAB" && tasks-axi "$@"); }
step() { printf '\n### %s\n' "$*"; }
run() { printf '$ fm-captain-hold.sh %s\n' "$*"; CH "$@" 2>&1; printf '[exit %s]\n' "$?"; }
printf 'Go.\n' > "$LAB/go.txt"
echo "lab home: $LAB"

step "S1 matching identity answers the card"
T add card-a "Approve card A" --kind ship --repo sample >/dev/null
run hold card-a --reason "ship build 33 to TestFlight?"
ID=$(CH open card-a --identity); echo "card shows identity: $ID"
run answer card-a --decision-file "$LAB/go.txt" --release --expect-identity "$ID"
T show card-a --full | grep -E '^(held|hold_kind|state):|Resolution mode'

step "S2 mismatched identity is refused and records nothing"
T add card-b "Approve card B" --kind ship --repo sample >/dev/null
run hold card-b --reason "merge the voice PR?"
IDB=$(CH open card-b --identity); echo "real identity: $IDB"
run answer card-b --decision-file "$LAB/go.txt" --release --expect-identity "${IDB%#*}#7"
T show card-b --full | grep -E '^held:'; T show card-b --full | grep -c 'Resolution recorded by' || true

step "S3 same-worded re-hold of released work: old card refused, new card accepted"
OLD=$ID
FM_CAPTAIN_HOLD_NOW=$(date -u +%Y-%m-%dT%H:%M:%SZ) run hold card-a --reason "ship build 33 to TestFlight?"
NEW=$(CH open card-a --identity); echo "old card: $OLD  new card: $NEW"
run answer card-a --decision-file "$LAB/go.txt" --release --expect-identity "$OLD"
T show card-a --full | grep -E '^held:'
run answer card-a --decision-file "$LAB/go.txt" --release --expect-identity "$NEW"
step "S4 replaying the landed tap is refused (call not open)"
run answer card-a --decision-file "$LAB/go.txt" --release --expect-identity "$NEW"
echo "resolutions recorded: $(T show card-a --full | grep -c 'Resolution recorded by fm-captain-hold')"

step "S5 reworded live call (same clock second, twice) never reuses an earlier identity"
T add card-c "Approve card C" --kind ship --repo sample >/dev/null
FM_CAPTAIN_HOLD_NOW=2026-09-28T12:00:00Z run hold card-c --reason "wording A"
A=$(CH open card-c --identity)
FM_CAPTAIN_HOLD_NOW=2026-09-28T12:00:00Z run hold card-c --reason "wording B"
B=$(CH open card-c --identity)
FM_CAPTAIN_HOLD_NOW=2026-09-28T12:00:00Z run hold card-c --reason "wording C"
C=$(CH open card-c --identity)
echo "A=$A B=$B C=$C"
[ "$A" != "$B" ] && [ "$B" != "$C" ] && [ "$A" != "$C" ] && echo "identities all distinct: yes" || echo "identities all distinct: NO"
run answer card-c --decision-file "$LAB/go.txt" --expect-identity "$A"
run answer card-c --decision-file "$LAB/go.txt" --expect-identity "$B"
T show card-c --full | grep -E '^(held|hold_reason):'

step "S6 identical-reason re-hold (new --until only) keeps the identity, tap still lands"
FM_CAPTAIN_HOLD_NOW=2026-09-28T12:30:00Z run hold card-c --reason "wording C" --until 2099-01-01
C2=$(CH open card-c --identity); echo "before=$C after=$C2"
run answer card-c --decision-file "$LAB/go.txt" --expect-identity "$C"
T show card-c --full | grep -E 'Resolution mode'

step "S7 absent task with an expectation is refused with exit 3"
run answer no-such-card --decision-file "$LAB/go.txt" --expect-identity "$C"

step "S8 without --expect-identity the answer behaves as before"
run answer card-b --decision-file "$LAB/go.txt"
T show card-b --full | grep -E '^held:|Resolution mode'
run answer card-b --decision-file "$LAB/go.txt"
step "S8b empty --expect-identity is rejected as usage"
run answer card-b --decision-file "$LAB/go.txt" --expect-identity ""

step "S9 read failure with expectation keeps the ordinary failure exit (not 3)"
T add card-d "Approve card D" --kind ship --repo sample >/dev/null
run hold card-d --reason "read failure probe"
IDD=$(CH open card-d --identity)
mv "$LAB/.tasks.toml" "$LAB/.tasks.toml.off"; printf 'backend = "nonsense"\n' > "$LAB/.tasks.toml"
run answer card-d --decision-file "$LAB/go.txt" --expect-identity "$IDD"
mv "$LAB/.tasks.toml.off" "$LAB/.tasks.toml"
T show card-d --full | grep -E '^held:'

echo; echo "RACE_LAB=$LAB"
