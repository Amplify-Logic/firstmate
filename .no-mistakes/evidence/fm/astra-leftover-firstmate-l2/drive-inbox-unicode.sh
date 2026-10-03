#!/usr/bin/env bash
# Queue a captain note in a throwaway home, record a progress update containing
# U+2028, U+2029, VT and FF, then read the receipts the status surfaces consume.
set -u
ROOT=$1; LABEL=$2
home=$(mktemp -d "${TMPDIR:-/tmp}/fm-inbox-drive.XXXXXX"); mkdir -p "$home/state" "$home/data" "$home/config"
run() { FM_HOME="$home" FM_STATE_OVERRIDE="$home/state" FM_DATA_OVERRIDE="$home/data" FM_CONFIG_OVERRIDE="$home/config" "$ROOT/bin/fm-inbox.sh" "$@"; }
q=$(run note "fix the slow voice pickup"); id=${q#queued }; id=${id%%$'\n'*}
body=$(python3 -c 'print("Checked the watcher still checking the relay next\vpart\ffinal: fix pushed")')
run progress "$id" "$body" >/dev/null; echo "[$LABEL] progress exit=$?"
run receipts | python3 -c 'import json,sys
row=json.load(sys.stdin)["pending"][0]
sent=sys.argv[1]
for p in row["progress"]: print("  receipt progress body:", ascii(p["body"]))
print("  intact:", row["progress"][-1]["body"] == sent if row["progress"] else False)' "$body"
rm -rf "$home"
