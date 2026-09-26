#!/usr/bin/env bash
# Drive the tracked Codex and Claude SessionStart hook commands, exactly as
# committed in .codex/hooks.json and .claude/settings.json, inside plain
# (primary-shaped) clones of the fixed and base commits, with and without the
# FM_TASK_ID worker marker bin/fm-spawn.sh exports into ship/scout panes.
set -u
LAB=$1
clean_env() { env -u NO_MISTAKES_GATE -u FM_GATE_REFUSE_BYPASS -u FM_ROOT_OVERRIDE -u FM_STATE_OVERRIDE \
  -u FM_DATA_OVERRIDE -u FM_CONFIG_OVERRIDE -u FM_PROJECTS_OVERRIDE -u CLAUDECODE -u CLAUDE_CODE_ENTRYPOINT \
  -u FM_TASK_ID -u GROK_AGENT -u PI_CODING_AGENT -u FM_PI_HARNESS "$@"; }
drive() { # <label> <checkout> <harness> <source> [VAR=val...]
  local label=$1 root=$2 harness=$3 src=$4; shift 4
  local cmd out rc payload
  payload=$(printf '{"hook_event_name":"SessionStart","source":"%s","session_id":"lab-%s","cwd":"%s"}' "$src" "$RANDOM" "$root")
  if [ "$harness" = codex ]; then
    cmd=$(jq -r '.hooks.SessionStart[0].hooks[0].command' "$root/.codex/hooks.json")
  else
    cmd=$(jq -r '.hooks.SessionStart[0].hooks[0].command' "$root/.claude/settings.json")
  fi
  rm -f "$root/state/.lock"
  out=$(cd "$root" && printf '%s' "$payload" | clean_env FM_HOME="$root" CLAUDE_PROJECT_DIR="$root" "$@" bash -c "$cmd" 2>&1); rc=$?
  printf '=== %s\n    checkout=%s (%s)  harness=%s  source=%s  env=[%s]\n' "$label" "$(basename "$root")" \
    "$(git -C "$root" log --oneline -1 | cut -c1-8)" "$harness" "$src" "$*"
  printf '    exit=%s  lock_taken=%s\n' "$rc" "$([ -f "$root/state/.lock" ] && echo yes || echo no)"
  if [ -n "$out" ]; then printf '    stdout: %s\n' "$out"; else printf '    stdout: <silent>\n'; fi
}
echo "## BEFORE the fix (base e8d934b2): a marked worker still gets the nudge"
drive "base / codex worker resume"  "$LAB/base" codex resume FM_TASK_ID=fm-primary-opus-profile-o1
drive "base / claude worker resume" "$LAB/base" claude resume FM_TASK_ID=fm-primary-opus-profile-o1
echo
echo "## AFTER the fix (target d22419d5): a marked worker is silent on every source, no lock taken"
for h in codex claude; do for s in startup resume clear compact; do
  drive "fix / $h worker $s" "$LAB/fix" $h $s FM_TASK_ID=fm-primary-opus-profile-o1
done; done
echo
echo "## AFTER the fix: the genuine primary (no FM_TASK_ID) still gets its nudge"
drive "fix / codex primary resume"  "$LAB/fix" codex resume
drive "fix / claude primary resume" "$LAB/fix" claude resume
echo
echo "## Direct nudge wrapper call"
for c in base fix; do
  for e in "" "FM_TASK_ID=fm-primary-opus-profile-o1"; do
    out=$(cd "$LAB/$c" && clean_env FM_HOME="$LAB/$c" $e bin/fm-sessionstart-nudge.sh 2>&1); rc=$?
    printf '%-5s %-40s exit=%s stdout=%s\n' "$c" "${e:-<primary, no FM_TASK_ID>}" "$rc" "${out:-<silent>}"
  done
done
