#!/usr/bin/env bash
# Throwaway FM_HOME. A synthetic lock holder (sleep) stands in for the primary.
# The real status bar writes the context sample, and the real
# `fm-primary-handoff.sh status` reports what the supervisor would use.
set -u
ROOT=$1; LABEL=$2
H=$(mktemp -d "${TMPDIR:-/tmp}/fm-handoff-drive.XXXXXX"); mkdir -p "$H/state" "$H/config" "$H/data"
env_run() { env -u FM_STATE_OVERRIDE -u FM_DATA_OVERRIDE -u FM_CONFIG_OVERRIDE -u FM_ROOT_OVERRIDE FM_HOME="$H" "$@"; }
holder() { sleep 600 & HP=$!; printf '%s\n' "$HP" > "$H/state/.lock"; }
status() { env_run "$ROOT/bin/fm-primary-handoff.sh" status 2>&1 | grep context_used_percent; }
bar() { printf '%s' '{"model":{"display_name":"Claude Fable"},"effort":{"level":"high"},"context_window":{"remaining_percentage":48.2},"rate_limits":{"five_hour":{"used_percentage":12.9}},"cost":{"total_cost_usd":1.0}}' \
  | env_run FM_PRIMARY_HARNESS=claude "$ROOT/bin/fm-status-bar.sh" --adapter claude >/dev/null; }
echo "=== [$LABEL] ==="
holder; printf 'conv-A\n' > "$H/state/.lock-session"; bar
echo "1. primary A (pid $HP, conv-A) sample written by status bar:"; sed 's/^/     /' "$H/state/.primary-context"
echo "   status for A:            $(status)"
cp "$H/state/.primary-context" "$H/old"; kill $HP; wait $HP 2>/dev/null
holder; printf 'conv-B\n' > "$H/state/.lock-session"
echo "2. incoming primary B (pid $HP, conv-B), old sample still on disk:"
echo "   status for B:            $(status)"
bar; echo "3. B's own status-bar sample: $(status)"
printf 'conv-C\n' > "$H/state/.lock-session"
echo "4. same pid, new conversation conv-C: $(status)"
printf 'conv-B\n' > "$H/state/.lock-session"; bar
echo "5. B sample read 301s later (FM_HANDOFF_NOW): $(FM_HANDOFF_NOW=$(( $(date +%s) + 301 )) status)"
echo "6. B sample read with the clock at epoch 1 (sample dated in the future): $(FM_HANDOFF_NOW=1 status)"
kill $HP; wait $HP 2>/dev/null; rm -rf "$H"
