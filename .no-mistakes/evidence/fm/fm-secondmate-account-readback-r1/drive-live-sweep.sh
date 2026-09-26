#!/usr/bin/env bash
# drive-live-sweep.sh <root> <scenario> - one live secondmate liveness scenario.
# Mints a disposable lab home (bin/fm-lab-home.sh), a private fm-lab tmux socket
# with a dead secondmate pane (a bare shell in firstmate:fm-sm1), then runs the
# real bin/fm-bootstrap.sh session-start sweep from a pane on that socket so the
# real bin/fm-spawn.sh respawns the mate with the real claude/codex CLI.
# Prints the transcript, the respawned meta and the endpoint, then tears down.
set -u
ROOT=$1 SC=$2
LAB=$(mktemp -d "${TMPDIR:-/tmp}/fm-lab.XXXXXX")
"$ROOT/bin/fm-lab-home.sh" create "$LAB" >/dev/null
mkdir -p "$LAB/tmux"
T() { TMUX_TMPDIR="$LAB/tmux" tmux -L fm-lab "$@"; }

touch "$LAB/state/.last-watcher-beat"
printf 'codex\n' > "$LAB/config/crew-harness"
SMROOT=$(mktemp -d "${TMPDIR:-/tmp}/fm-lab-sm.XXXXXX"); SMH="$SMROOT/sm1home"
mkdir -p "$SMH/bin" "$SMH/data" "$SMH/state" "$SMH/config" "$SMH/projects"
printf 'sm1\n' > "$SMH/.fm-secondmate-home"
printf '# Firstmate\n' > "$SMH/AGENTS.md"
printf 'charter\n' > "$SMH/data/charter.md"
printf '%s\n' 'projects/' 'state/' 'data/' 'config/' '.no-mistakes/' > "$SMH/.gitignore"
git -C "$SMH" init -q -b main

meta() {  # <harness> [extra meta lines...]
  local h=$1; shift
  { printf 'window=firstmate:fm-sm1\nkind=secondmate\nharness=%s\nhome=%s\n' "$h" "$SMH"
    for l in "$@"; do printf '%s\n' "$l"; done; } > "$LAB/state/sm1.meta"
}
registry() {  # <vendor>
  printf '{"%s":{"default":"lars","accounts":{"lars":{},"derya":{}}}}\n' "$1" > "$LAB/config/accounts.json"
  mkdir -p "$LAB/data/accounts/$1/lars" "$LAB/data/accounts/$1/derya"
}

case "$SC" in
  pinned-codex-tagged) printf 'codex\n' > "$LAB/config/secondmate-harness"; meta codex account=derya account_source=registry; registry codex ;;
  pinned-codex-legacy) printf 'codex\n' > "$LAB/config/secondmate-harness"; meta codex account=derya; registry codex ;;
  pinned-claude-tagged) printf 'claude\n' > "$LAB/config/secondmate-harness"; meta claude account=derya account_source=registry; registry claude ;;
  worker-pin-wins) printf 'claude\n' > "$LAB/config/secondmate-harness"; meta claude account=derya account_source=registry; registry claude
    printf 'ordinary\n' > "$LAB/config/claude-account" ;;
  harness-switch) printf 'claude\n' > "$LAB/config/secondmate-harness"; meta codex account=derya account_source=registry; registry codex ;;
  legacy-pin-value) printf 'claude\n' > "$LAB/config/secondmate-harness"; meta claude account=ordinary ;;
  legacy-pin-path) printf 'claude\n' > "$LAB/config/secondmate-harness"; meta claude account=/pinned/claude/root ;;
  unpinned) printf 'claude\n' > "$LAB/config/secondmate-harness"; meta claude ;;
  *) echo "unknown scenario $SC" >&2; rm -rf "$LAB"; exit 2 ;;
esac

echo "### scenario: $SC   (code under test: $(git -C "$ROOT" log -1 --format='%h %s' 2>/dev/null))"
echo "### meta before sweep:"; sed "s#$LAB#\$LAB#g;s#$SMROOT#\$SMROOT#g" "$LAB/state/sm1.meta"
[ -f "$LAB/config/accounts.json" ] && { echo "### config/accounts.json:"; cat "$LAB/config/accounts.json"; }
for f in secondmate-harness claude-account; do [ -f "$LAB/config/$f" ] && echo "### config/$f: $(cat "$LAB/config/$f")"; done

# The dead secondmate endpoint: a bare shell where the agent should be.
T new-session -d -s firstmate -n hold "sleep 600"
T new-window -d -t firstmate -n fm-sm1 -c "$SMH" zsh
OUT="$LAB/sweep.out"
T new-window -d -t firstmate -n driver -c "$ROOT" \
  "env -u NO_MISTAKES_GATE -u FM_GATE_REFUSE_BYPASS -u FM_ROOT_OVERRIDE -u FM_STATE_OVERRIDE -u FM_DATA_OVERRIDE -u FM_CONFIG_OVERRIDE -u FM_PROJECTS_OVERRIDE FM_HOME='$LAB' FM_BACKEND=tmux '$ROOT/bin/fm-bootstrap.sh' > '$OUT' 2>&1; echo \"bootstrap rc=\$?\" >> '$OUT'; touch '$LAB/done'"
for _ in $(seq 1 180); do [ -f "$LAB/done" ] && break; sleep 1; done
sleep 8  # let a respawned agent come up in its pane
echo "### sweep transcript (SECONDMATE_LIVENESS lines + exit):"
grep -E 'SECONDMATE|secondmate sm1|account|bootstrap rc=' "$OUT" | sed "s#$LAB#\$LAB#g;s#$SMROOT#\$SMROOT#g"
if grep -q 'respawn failed' "$OUT"; then
  # The sweep reports only the first line of fm-spawn's output; re-run the exact
  # recovery command (fm_secondmate_liveness_relaunch) from a lab pane for the full reason.
  T new-window -d -t firstmate -n driver2 -c "$ROOT" \
    "env -u NO_MISTAKES_GATE -u FM_GATE_REFUSE_BYPASS -u FM_ROOT_OVERRIDE -u FM_STATE_OVERRIDE -u FM_DATA_OVERRIDE -u FM_CONFIG_OVERRIDE -u FM_PROJECTS_OVERRIDE FM_HOME='$LAB' FM_BACKEND=tmux FM_SPAWN_NO_GUARD=1 '$ROOT/bin/fm-spawn.sh' sm1 --secondmate > '$LAB/spawn.out' 2>&1; echo \"fm-spawn rc=\$?\" >> '$LAB/spawn.out'; touch '$LAB/done2'"
  for _ in $(seq 1 120); do [ -f "$LAB/done2" ] && break; sleep 1; done
  echo "### full output of the recovery command (FM_SPAWN_NO_GUARD=1 bin/fm-spawn.sh sm1 --secondmate):"
  sed "s#$LAB#\$LAB#g;s#$SMROOT#\$SMROOT#g" "$LAB/spawn.out"
fi
echo "### relaunch ledger:"; sed 's/^[0-9]*[ |]*//' "$LAB/state/.secondmate-relaunch-sm1" 2>/dev/null | cut -c1-80
echo "### meta after sweep (account/harness lines):"
grep -E '^(harness|account|account_source)=' "$LAB/state/sm1.meta" | sed "s#$LAB#\$LAB#g;s#$SMROOT#\$SMROOT#g" || echo "(no harness/account lines)"
echo "### endpoint firstmate:fm-sm1 after sweep:"
T list-panes -t firstmate:fm-sm1 -F 'pane_current_command=#{pane_current_command} pane_dead=#{pane_dead}' 2>&1
T capture-pane -p -t firstmate:fm-sm1 2>/dev/null | grep -v '^\s*$' | head -12
cp "$OUT" "${EVID:-/dev/null}" 2>/dev/null || true
T kill-server 2>/dev/null
rm -rf "$LAB" "$SMROOT"
