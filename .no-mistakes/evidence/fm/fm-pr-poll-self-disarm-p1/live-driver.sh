#!/usr/bin/env bash
# drive.sh <code-root> <label>: live merged-poll re-registration scenario in a fresh lab home, real gh.
set -u
R=$1; LABEL=$2; WT=/Users/larsmusic/.no-mistakes/worktrees/f569cc43ac96/01M3EXERMX0RFHAX8YTDN08NCC
URL=https://github.com/Amplify-Logic/firstmate/pull/205
URL2=https://github.com/Amplify-Logic/firstmate/pull/204
LAB=$(mktemp -d "${TMPDIR:-/tmp}/fm-lab.XXXXXX"); rmdir "$LAB"
"$WT/bin/fm-lab-home.sh" create "$LAB" >/dev/null || exit 1
mkdir -p "$LAB/shim"
cat > "$LAB/shim/gh" <<SH
#!/usr/bin/env bash
printf '%s\n' "\$*" >> "$LAB/gh.log"
exec /opt/homebrew/bin/gh "\$@"
SH
chmod +x "$LAB/shim/gh"
P="$LAB/shim:/opt/homebrew/bin:/usr/bin:/bin:/usr/sbin:/sbin"
E() { env -u FM_GATE_REFUSE_BYPASS -u FM_ROOT_OVERRIDE -u FM_STATE_OVERRIDE -u FM_DATA_OVERRIDE -u FM_CONFIG_OVERRIDE -u FM_PROJECTS_OVERRIDE FM_HOME="$LAB" PATH="$P" "$@"; }
say() { printf '\n=== [%s] %s\n' "$LABEL" "$*"; }
printf 'window=fm-task-a\nworktree=%s\nkind=ship\nmode=no-mistakes\n' "$WT" > "$LAB/state/task-a.meta"
printf '#!/usr/bin/env bash\nprintf "stop-cycle\\n"\n' > "$LAB/state/z-stop.check.sh"; chmod 0700 "$LAB/state/z-stop.check.sh"
E "$R/bin/fm-check-register.sh" z-stop >/dev/null || { echo "register z-stop failed"; }
watch_cycle() {  # <n>
  local n=$1 out rc
  rm -f "$LAB/state/.last-check"; : > "$LAB/gh.log"
  out=$(E FM_CHECK_INTERVAL=0 FM_POLL=0.05 FM_HEARTBEAT=999999 FM_SIGNAL_GRACE=0 perl -e 'alarm 90; exec @ARGV' "$R/bin/fm-watch.sh" 2>"$LAB/watch-$n.err"); rc=$?
  say "watcher cycle $n exit=$rc"
  printf 'watcher stdout: %s\n' "$out"
  printf 'forge state reads (gh pr view <url> --json state): %s\n' "$(grep -c -- '--json state' "$LAB/gh.log")"
  sed 's/^/  gh: /' "$LAB/gh.log"
  printf 'wake-queue task-a check rows: %s\n' "$(grep -c "$(printf '\tcheck\ttask-a.check.sh\t')" "$LAB/state/.wake-queue" 2>/dev/null)"
  E "$R/bin/fm-wake-drain.sh" >"$LAB/drain.out" 2>"$LAB/drain.err"
  seq=$(sed -n 's/^WAKE_ACK_REQUIRED:.*--ack-through \([0-9][0-9]*\) --recovery-generation.*/\1/p' "$LAB/drain.err")
  gen=$(sed -n 's/^WAKE_ACK_REQUIRED:.*--recovery-generation \([A-Za-z0-9._-]*\)$/\1/p' "$LAB/drain.err")
  printf 'drained wakes: %s\n' "$(tr '\n' ' ' < "$LAB/drain.out" | cut -c1-300)"
  [ -z "$seq" ] || E "$R/bin/fm-wake-drain.sh" --ack-through "$seq" --recovery-generation "$gen" >/dev/null 2>&1
  printf 'poll artifacts left: %s\n' "$(ls "$LAB/state" | grep -E '^task-a\.(check\.sh|pr-poll)' | tr '\n' ' ')"
  printf 'merge-notified marker: %s\n' "$(tr '\n' ' ' < "$LAB/state/task-a.pr-poll-merge-notified" 2>/dev/null || echo absent)"
}
arm() {  # <url>
  say "arm: fm-pr-check.sh task-a $1"
  E "$R/bin/fm-pr-check.sh" task-a "$1" 2>&1 | tail -3; echo "arm exit=${PIPESTATUS[0]}"
}
arm "$URL"; watch_cycle 1
arm "$URL"; watch_cycle 2
arm "$URL"; watch_cycle 3
arm "$URL2"; watch_cycle 4
rm -rf "$LAB"; say "lab removed: $LAB"
