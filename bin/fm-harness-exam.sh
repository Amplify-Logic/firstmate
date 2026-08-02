#!/usr/bin/env bash
# fm-harness-exam.sh - live worker-runtime re-verification against a real TUI.
#
# Usage:
#   bin/fm-harness-exam.sh <adapter> [options]
#   bin/fm-harness-exam.sh --list
#   bin/fm-harness-exam.sh --plan <adapter>
#
# The exam launches exactly one of the seven verified worker adapters in a
# throwaway git repository under a private HOME and a private tmux socket.
# It scores the eight runtime properties firstmate drives directly: autonomy,
# composer classification, busy signature, interrupt, turn-end hook, liveness
# marker, exit, and resume.
# Startup and trust dialogs are captured as unscored evidence because the
# source evaluation counted trust in its original core eight while the approved
# implementation scope replaced it with the liveness marker.
#
# Every probe is observed outside the runtime pane.
# Raw plain and ANSI pane captures, process listings, hook payloads, launch
# commands, results.json, and scorecard.md are retained in the output directory.
# Missing evidence fails its probe rather than being accepted as self-report.
#
# Options:
#   --model <id>        Override the adapter's default model.
#   --output <dir>      Artifact directory.
#                       Default: $FM_HOME/data/harness-exam/<adapter>-<UTC stamp>.
#   --timeout <secs>    Per-wait timeout, default 45.
#   --keep-lab          Keep the throwaway HOME and repository after the run.
#   --source-home <dir> Read credential bridges from this home, default $HOME.
#   --help              Print this help.
#
# Safety:
# The autonomy probes deliberately use each adapter's unattended flag, but the
# runtime is confined to a fresh repository and private HOME.
# Only credential files needed to authenticate are linked from --source-home.
# The script never updates a runtime, edits the source home, or uses the ambient
# tmux server.

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
EXPECTATIONS="$SCRIPT_DIR/fm-harness-exam-adapters.tsv"
# shellcheck source=bin/fm-backend.sh
. "$SCRIPT_DIR/fm-backend.sh"

PROBES=(autonomy composer busy interrupt turn-end liveness exit resume)
TIMEOUT=45
BUSY_SECONDS=${FM_HARNESS_EXAM_BUSY_SECONDS:-20}
KEEP_LAB=0
MODEL=""
OUTPUT=""
SOURCE_HOME=${HOME:-}
ADAPTER=""
MODE=run
RESULTS_TSV=""
ARTIFACTS=""
LAB_ROOT=""
LAB_HOME=""
WORKSPACE=""
TARGET=""
SESSION=exam
VERSION="unknown"
LAUNCH_CMD=""
RESUME_CMD=""
HOOK_MARKER=""
HOOK_RAW=""
RUN_FAILED=0
CLEANED=0

usage() {
  awk 'NR == 1 { next } /^#$/ { if (seen) print ""; next } /^# / { seen=1; sub(/^# /, ""); print; next } seen { exit }' "$0"
}

list_adapters() {
  awk -F '\t' '!/^#/ && NF { print $1 }' "$EXPECTATIONS"
}

load_expectation() {
  local adapter=$1 row
  row=$(awk -F '\t' -v a="$adapter" '!/^#/ && $1 == a { print; exit }' "$EXPECTATIONS")
  [ -n "$row" ] || return 1
  IFS=$'\t' read -r ADAPTER BINARY AUTONOMY_FLAG BUSY_REGEX INTERRUPT_KEYS \
    INTERRUPT_REGEX EXIT_COMMAND RESUME_MODE ALIVE_VERDICT COMM_REGEX ARGV_REGEX \
    HOOK_KIND DEFAULT_MODEL STARTUP_DIALOG <<< "$row"
  return 0
}

expectation_field() {
  local adapter=$1 field=$2 index
  case "$field" in
    binary) index=2 ;;
    autonomy) index=3 ;;
    busy) index=4 ;;
    interrupt) index=5 ;;
    exit) index=7 ;;
    resume) index=8 ;;
    liveness) index=9 ;;
    hook) index=12 ;;
    model) index=13 ;;
    dialog) index=14 ;;
    *) return 1 ;;
  esac
  awk -F '\t' -v a="$adapter" -v i="$index" '!/^#/ && $1 == a { print $i; exit }' "$EXPECTATIONS"
}

print_plan() {
  local adapter=$1 field
  load_expectation "$adapter" || {
    echo "error: unsupported adapter '$adapter' (expected one of: $(list_adapters | paste -sd, -))" >&2
    return 2
  }
  printf 'adapter\t%s\n' "$ADAPTER"
  for field in binary autonomy busy interrupt exit resume liveness hook model dialog; do
    printf '%s\t%s\n' "$field" "$(expectation_field "$adapter" "$field")"
  done
  printf 'probes\t%s\n' "$(IFS=,; echo "${PROBES[*]}")"
}

shell_quote() {
  local value=$1
  printf "'"
  printf '%s' "$value" | sed "s/'/'\\\\''/g"
  printf "'"
}

append_arg() {
  local value=$1
  if [ -n "$LAUNCH_CMD" ]; then LAUNCH_CMD+=" "; fi
  LAUNCH_CMD+=$(shell_quote "$value")
}

append_resume_arg() {
  local value=$1
  if [ -n "$RESUME_CMD" ]; then RESUME_CMD+=" "; fi
  RESUME_CMD+=$(shell_quote "$value")
}

link_if_present() {
  local source=$1 destination=$2
  [ -e "$source" ] || return 0
  mkdir -p "$(dirname "$destination")"
  [ -e "$destination" ] || ln -s "$source" "$destination"
}

copy_if_present() {
  local source=$1 destination=$2
  [ -f "$source" ] || return 0
  mkdir -p "$(dirname "$destination")"
  cp "$source" "$destination"
}

prepare_credential_bridges() {
  link_if_present "$SOURCE_HOME/.claude/.credentials.json" "$LAB_HOME/.claude/.credentials.json"
  link_if_present "$SOURCE_HOME/.codex/auth.json" "$LAB_HOME/.codex/auth.json"
  copy_if_present "$SOURCE_HOME/.codex/config.toml" "$LAB_HOME/.codex/config.toml"
  link_if_present "$SOURCE_HOME/.pi/agent/auth.json" "$LAB_HOME/.pi/agent/auth.json"
  link_if_present "$SOURCE_HOME/.local/share/opencode/auth.json" "$LAB_HOME/.local/share/opencode/auth.json"
  copy_if_present "$SOURCE_HOME/.cursor/cli-config.json" "$LAB_HOME/.cursor/cli-config.json"
  link_if_present "$SOURCE_HOME/.cursor/auth.json" "$LAB_HOME/.cursor/auth.json"
  copy_if_present "$SOURCE_HOME/.grok/config.toml" "$LAB_HOME/.grok/config.toml"
  link_if_present "$SOURCE_HOME/.grok/auth.json" "$LAB_HOME/.grok/auth.json"
  link_if_present "$SOURCE_HOME/.grok/credentials" "$LAB_HOME/.grok/credentials"
}

write_hook_recorder() {
  local recorder="$LAB_ROOT/hook-recorder.sh"
  cat > "$recorder" <<EOF
#!/usr/bin/env bash
set -uo pipefail
{
  printf 'time=%s\\n' "\$(date -u +%Y-%m-%dT%H:%M:%SZ)"
  printf 'args='
  printf '%q ' "\$@"
  printf '\\nstdin=\\n'
  cat 2>/dev/null || true
  printf '\\n---\\n'
} >> $(shell_quote "$HOOK_RAW")
touch $(shell_quote "$HOOK_MARKER")
EOF
  chmod +x "$recorder"
}

prepare_hook() {
  local recorder="$LAB_ROOT/hook-recorder.sh" command_json hook_raw_json hook_marker_json
  write_hook_recorder
  hook_raw_json=$(jq -Rn --arg value "$HOOK_RAW" '$value')
  hook_marker_json=$(jq -Rn --arg value "$HOOK_MARKER" '$value')
  case "$HOOK_KIND" in
    claude)
      mkdir -p "$WORKSPACE/.claude"
      command_json=$(jq -Rn --arg command "$recorder" '$command')
      cat > "$WORKSPACE/.claude/settings.local.json" <<EOF
{"hooks":{"Stop":[{"hooks":[{"type":"command","command":$command_json}]}]}}
EOF
      ;;
    codex)
      : # The recorder is supplied through the launch command's notify setting.
      ;;
    opencode)
      mkdir -p "$WORKSPACE/.opencode/plugins"
      cat > "$WORKSPACE/.opencode/plugins/fm-harness-exam.js" <<EOF
import { appendFileSync, closeSync, openSync } from "node:fs";
export const FmHarnessExam = async () => ({
  event: async ({ event }) => {
    if (event.type !== "session.idle") return;
    appendFileSync($hook_raw_json, JSON.stringify(event) + "\\n");
    closeSync(openSync($hook_marker_json, "w"));
  },
});
EOF
      ;;
    pi)
      cat > "$LAB_ROOT/pi-turn-end.ts" <<EOF
import { appendFileSync, closeSync, openSync } from "node:fs";
export default function (pi: any) {
  pi.on("turn_end", (event: any) => {
    appendFileSync($hook_raw_json, JSON.stringify(event) + "\\n");
    closeSync(openSync($hook_marker_json, "w"));
  });
}
EOF
      ;;
    grok)
      mkdir -p "$LAB_HOME/.grok/hooks"
      command_json=$(jq -Rn --arg command "bash $(shell_quote "$recorder")" '$command')
      printf '{"hooks":{"Stop":[{"hooks":[{"type":"command","command":%s}]}]}}\n' \
        "$command_json" > "$LAB_HOME/.grok/hooks/fm-harness-exam.json"
      ;;
    cursor)
      mkdir -p "$WORKSPACE/.cursor"
      command_json=$(jq -Rn --arg command "$recorder" '$command')
      printf '{"version":1,"hooks":{"stop":[{"type":"command","command":%s}]}}\n' \
        "$command_json" > "$WORKSPACE/.cursor/hooks.json"
      ;;
    kimi)
      prepare_kimi_home "$recorder"
      ;;
    *) return 1 ;;
  esac
}

prepare_kimi_home() {
  local recorder=$1 source="${FM_KIMI_SOURCE_HOME:-$SOURCE_HOME/.kimi-code}"
  mkdir -p "$LAB_HOME/.kimi-code"
  if [ -f "$source/config.toml" ]; then
    awk '
      BEGIN { skip=0 }
      /^\[\[hooks\]\]/ { skip=1; next }
      skip == 1 && /^\[/ { skip=0 }
      skip == 0 { print }
    ' "$source/config.toml" > "$LAB_HOME/.kimi-code/config.toml"
  else
    : > "$LAB_HOME/.kimi-code/config.toml"
  fi
  link_if_present "$source/credentials" "$LAB_HOME/.kimi-code/credentials"
  link_if_present "$source/oauth" "$LAB_HOME/.kimi-code/oauth"
  link_if_present "$source/device_id" "$LAB_HOME/.kimi-code/device_id"
  {
    printf '\n[[hooks]]\n'
    printf 'event = "Stop"\n'
    printf 'command = "bash %s"\n' "$(shell_quote "$recorder")"
    printf 'timeout = 10\n'
  } >> "$LAB_HOME/.kimi-code/config.toml"
}

build_launch_command() {
  local resume=${1:-0} cursor_id=${2:-} model=${MODEL:-$DEFAULT_MODEL}
  LAUNCH_CMD=""
  RESUME_CMD=""
  case "$ADAPTER" in
    claude)
      append_arg env
      append_arg CLAUDE_CODE_ENABLE_PROMPT_SUGGESTION=false
      append_arg claude
      append_arg --dangerously-skip-permissions
      [ "$model" = - ] || { append_arg --model; append_arg "$model"; }
      [ "$resume" = 0 ] || append_arg --continue
      ;;
    codex)
      append_arg env
      append_arg "CODEX_HOME=$LAB_HOME/.codex"
      append_arg codex
      if [ "$resume" = 0 ]; then
        append_arg --dangerously-bypass-approvals-and-sandbox
        append_arg -c
        append_arg "notify=[\"bash\",\"$LAB_ROOT/hook-recorder.sh\"]"
      else
        append_arg resume
        append_arg --last
        append_arg --dangerously-bypass-approvals-and-sandbox
        append_arg -c
        append_arg "notify=[\"bash\",\"$LAB_ROOT/hook-recorder.sh\"]"
      fi
      [ "$model" = - ] || { append_arg --model; append_arg "$model"; }
      ;;
    opencode)
      append_arg env
      append_arg 'OPENCODE_CONFIG_CONTENT={"permission":{"*":"allow"}}'
      append_arg opencode
      [ "$model" = - ] || { append_arg --model; append_arg "$model"; }
      [ "$resume" = 0 ] || append_arg --continue
      ;;
    pi)
      append_arg pi
      append_arg --session-dir
      append_arg "$LAB_ROOT/pi-sessions"
      append_arg -e
      append_arg "$LAB_ROOT/pi-turn-end.ts"
      [ "$model" = - ] || { append_arg --model; append_arg "$model"; }
      [ "$resume" = 0 ] || append_arg --continue
      ;;
    grok)
      append_arg env
      append_arg "GROK_HOME=$LAB_HOME/.grok"
      append_arg grok
      append_arg --always-approve
      [ "$model" = - ] || { append_arg --model; append_arg "$model"; }
      [ "$resume" = 0 ] || append_arg --continue
      ;;
    cursor)
      append_arg agent
      append_arg --yolo
      append_arg --workspace
      append_arg "$WORKSPACE"
      [ "$model" = - ] || { append_arg --model; append_arg "$model"; }
      if [ "$resume" != 0 ]; then
        [ -n "$cursor_id" ] || return 1
        append_arg "--resume=$cursor_id"
      fi
      ;;
    kimi)
      append_arg env
      append_arg "KIMI_CODE_HOME=$LAB_HOME/.kimi-code"
      append_arg kimi
      append_arg --yolo
      [ "$model" = - ] || { append_arg --model; append_arg "$model"; }
      [ "$resume" = 0 ] || append_arg --continue
      ;;
    *) return 1 ;;
  esac
  if [ "$resume" = 0 ]; then
    RESUME_CMD=$LAUNCH_CMD
  else
    RESUME_CMD=$LAUNCH_CMD
  fi
}

capture_pane() {
  local stem=$1 lines=${2:-200}
  fm_backend_capture tmux "$TARGET" "$lines" > "$ARTIFACTS/$stem.txt" 2>&1 || true
  tmux capture-pane -ep -t "$TARGET" -S "-$lines" > "$ARTIFACTS/$stem.ansi" 2>&1 || true
}

capture_processes() {
  local stem=$1 tty
  tty=$(tmux display-message -p -t "$TARGET" '#{pane_tty}' 2>/dev/null || true)
  {
    tmux display-message -p -t "$TARGET" \
      'pane_pid=#{pane_pid} pane_current_command=#{pane_current_command} pane_tty=#{pane_tty}' 2>/dev/null || true
    if [ -n "$tty" ]; then
      ps -t "${tty#/dev/}" -o pid=,ppid=,pgid=,comm=,args= 2>/dev/null || true
    fi
  } > "$ARTIFACTS/$stem.processes.txt"
}

record_result() {
  local probe=$1 status=$2 summary=$3 evidence=$4
  [ -n "$RESULTS_TSV" ] || return 1
  if awk -F '\t' -v p="$probe" '$1 == p { found=1 } END { exit !found }' "$RESULTS_TSV" 2>/dev/null; then
    return 1
  fi
  summary=${summary//$'\t'/ }
  summary=${summary//$'\n'/ }
  evidence=${evidence//$'\t'/ }
  printf '%s\t%s\t%s\t%s\n' "$probe" "$status" "$summary" "$evidence" >> "$RESULTS_TSV"
  [ "$status" = pass ] || RUN_FAILED=1
}

record_missing_results() {
  local probe evidence=""
  if [ -f "$ARTIFACTS/00-startup-failed.ansi" ]; then
    evidence="evidence/00-startup-failed.ansi,evidence/00-startup-failed.processes.txt"
  fi
  for probe in "${PROBES[@]}"; do
    if ! awk -F '\t' -v p="$probe" '$1 == p { found=1 } END { exit !found }' "$RESULTS_TSV"; then
      record_result "$probe" fail "probe could not run after an earlier failure" "$evidence"
    fi
  done
}

render_results() {
  local jsonl="$OUTPUT/.results.jsonl" probe status summary evidence passed total
  : > "$jsonl"
  while IFS=$'\t' read -r probe status summary evidence; do
    jq -cn --arg probe "$probe" --arg status "$status" --arg summary "$summary" --arg evidence "$evidence" \
      '{probe:$probe,status:$status,pass:($status == "pass"),summary:$summary,evidence:$evidence}' >> "$jsonl"
  done < "$RESULTS_TSV"
  passed=$(awk -F '\t' '$2 == "pass" { n++ } END { print n+0 }' "$RESULTS_TSV")
  total=${#PROBES[@]}
  jq -n \
    --arg adapter "$ADAPTER" \
    --arg version "$VERSION" \
    --arg generated_at "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
    --arg workspace "$WORKSPACE" \
    --argjson passed "$passed" \
    --argjson total "$total" \
    --slurpfile probes "$jsonl" \
    '{schema_version:1,adapter:$adapter,version:$version,generated_at:$generated_at,workspace:$workspace,score:{passed:$passed,total:$total},probes:$probes}' \
    > "$OUTPUT/results.json"
  {
    printf "# Worker runtime exam: \`%s\`\n\n" "$ADAPTER"
    printf -- "- Version: \`%s\`\n" "$VERSION"
    printf -- '- Score: **%s/%s**\n' "$passed" "$total"
    printf -- "- Generated: \`%s\`\n\n" "$(date -u +%Y-%m-%dT%H:%M:%SZ)"
    printf '| Probe | Result | Evidence | Summary |\n'
    printf '|---|---|---|---|\n'
    while IFS=$'\t' read -r probe status summary evidence; do
      summary=${summary//|/\\|}
      printf "| \`%s\` | **%s** | \`%s\` | %s |\n" "$probe" "$status" "$evidence" "$summary"
    done < "$RESULTS_TSV"
    printf "\nStartup and trust handling is captured in \`evidence/00-startup-dialogs.txt\` but is not part of the eight-point score.\n"
  } > "$OUTPUT/scorecard.md"
  rm -f "$jsonl"
}

cleanup_lab() {
  [ "$CLEANED" = 0 ] || return 0
  CLEANED=1
  if [ -n "$LAB_ROOT" ]; then
    TMUX_TMPDIR="$LAB_ROOT/tmux" tmux kill-server >/dev/null 2>&1 || true
    if [ "$KEEP_LAB" = 0 ]; then rm -rf "$LAB_ROOT"; fi
  fi
}

on_exit() {
  cleanup_lab
}

pane_exists() {
  fm_backend_target_exists tmux "$TARGET"
}

pane_text_matches() {
  local regex=$1
  fm_backend_capture tmux "$TARGET" 120 2>/dev/null | grep -qiE "$regex"
}

handle_startup_dialog() {
  local text=$1
  case "$ADAPTER:$text" in
    claude:*Bypass*|claude:*bypass*)
      fm_backend_send_key tmux "$TARGET" Down >/dev/null 2>&1 || true
      fm_backend_send_key tmux "$TARGET" Enter >/dev/null 2>&1 || true
      ;;
    *) fm_backend_send_key tmux "$TARGET" Enter >/dev/null 2>&1 || true ;;
  esac
}

wait_for_composer() {
  local deadline=$((SECONDS + TIMEOUT)) state text handled_hash="" hash
  [ -e "$ARTIFACTS/00-startup-dialogs.txt" ] || : > "$ARTIFACTS/00-startup-dialogs.txt"
  while [ "$SECONDS" -lt "$deadline" ]; do
    pane_exists || { sleep 1; continue; }
    state=$(fm_backend_composer_state tmux "$TARGET" 2>/dev/null || printf unknown)
    [ "$state" = empty ] && return 0
    text=$(fm_backend_capture tmux "$TARGET" 80 2>/dev/null || true)
    if printf '%s' "$text" | grep -qiE 'trust|workspace trust|required|bypass permissions|dangerously|approval mode'; then
      hash=$(printf '%s' "$text" | shasum -a 256 | awk '{print $1}')
      if [ "$hash" != "$handled_hash" ]; then
        printf '%s\n---\n' "$text" >> "$ARTIFACTS/00-startup-dialogs.txt"
        handle_startup_dialog "$text"
        handled_hash=$hash
      fi
    fi
    sleep 1
  done
  return 1
}

wait_for_regex() {
  local regex=$1 deadline=$((SECONDS + TIMEOUT))
  while [ "$SECONDS" -lt "$deadline" ]; do
    pane_text_matches "$regex" && return 0
    pane_exists || return 1
    sleep 1
  done
  return 1
}

wait_for_file() {
  local file=$1 deadline=$((SECONDS + TIMEOUT))
  while [ "$SECONDS" -lt "$deadline" ]; do
    [ -s "$file" ] && return 0
    pane_exists || return 1
    sleep 1
  done
  return 1
}

wait_for_marker() {
  local file=$1 deadline=$((SECONDS + TIMEOUT))
  while [ "$SECONDS" -lt "$deadline" ]; do
    [ -e "$file" ] && return 0
    pane_exists || return 1
    sleep 1
  done
  return 1
}

wait_until_not_busy() {
  local deadline=$((SECONDS + TIMEOUT))
  while [ "$SECONDS" -lt "$deadline" ]; do
    if ! pane_text_matches "$BUSY_REGEX"; then return 0; fi
    pane_exists || return 1
    sleep 1
  done
  return 1
}

submit_text() {
  local text=$1 verdict
  verdict=$(fm_backend_send_text_submit tmux "$TARGET" "$text" 3 0.4 1 2>/dev/null || true)
  [ "$verdict" != send-failed ] && [ "$verdict" != pending ]
}

send_key_list() {
  local list=$1 key
  IFS=',' read -r -a keys <<< "$list"
  for key in "${keys[@]}"; do
    fm_backend_send_key tmux "$TARGET" "$key" >/dev/null 2>&1 || return 1
    sleep 0.25
  done
}

agent_marker_matches() {
  local file=$1
  grep -qiE "$COMM_REGEX" "$file" && grep -qiE "$ARGV_REGEX" "$file"
}

launch_runtime() {
  local target_name=$1 command=$2 window_id
  if [ "$target_name" = main ]; then
    window_id=$(HOME="$LAB_HOME" tmux new-session -dP -F '#{window_id}' -s "$SESSION" -n main -c "$WORKSPACE" \
      "env HOME=$(shell_quote "$LAB_HOME") bash --noprofile --norc") || return 1
  else
    window_id=$(HOME="$LAB_HOME" tmux new-window -dP -F '#{window_id}' -t "$SESSION:" -n "$target_name" -c "$WORKSPACE" \
      "env HOME=$(shell_quote "$LAB_HOME") bash --noprofile --norc") || return 1
  fi
  TARGET=$window_id
  tmux set-window-option -t "$TARGET" automatic-rename off >/dev/null 2>&1 || true
  tmux set-window-option -t "$TARGET" allow-rename off >/dev/null 2>&1 || true
  sleep 0.5
  tmux send-keys -t "$TARGET" -l "$command"
  tmux send-keys -t "$TARGET" Enter
}

probe_composer() {
  local idle pending
  idle=$(fm_backend_composer_state tmux "$TARGET" 2>/dev/null || printf unknown)
  capture_pane 02-composer-idle 80
  tmux send-keys -t "$TARGET" -l FM_EXAM_PENDING
  sleep 1
  pending=$(fm_backend_composer_state tmux "$TARGET" 2>/dev/null || printf unknown)
  capture_pane 02-composer-pending 80
  tmux send-keys -t "$TARGET" C-u
  sleep 0.5
  if [ "$idle" = empty ] && [ "$pending" = pending ]; then
    record_result composer pass "idle classified empty and real unsubmitted text classified pending" \
      "evidence/02-composer-idle.ansi,evidence/02-composer-pending.ansi"
  else
    record_result composer fail "expected empty then pending, got $idle then $pending" \
      "evidence/02-composer-idle.ansi,evidence/02-composer-pending.ansi"
  fi
}

probe_busy_interrupt_liveness() {
  local prompt alive_after interrupt_text
  capture_pane 03-idle-negative 100
  capture_processes 06-liveness-before
  if pane_text_matches "$BUSY_REGEX"; then
    record_result busy fail "recorded busy regex also matched the settled idle pane" "evidence/03-idle-negative.txt"
  fi
  prompt="Use the shell tool to run exactly: sleep $BUSY_SECONDS; printf 'FM_EXAM_BUSY_DONE\\n'. Do not run it in the background and do not do anything else."
  submit_text "$prompt" || true
  if wait_for_regex "$BUSY_REGEX"; then
    capture_pane 03-busy 160
    record_result busy pass "recorded signature appeared during a real tool turn and not while idle" \
      "evidence/03-busy.ansi,evidence/03-idle-negative.txt"
  else
    capture_pane 03-busy-missing 160
    record_result busy fail "recorded signature did not appear during the deterministic long tool turn" \
      "evidence/03-busy-missing.ansi,evidence/03-idle-negative.txt"
  fi
  capture_processes 06-liveness-busy
  alive_before=$(fm_backend_agent_alive tmux "$TARGET" 2>/dev/null || printf unknown)
  if [ "$alive_before" = "$ALIVE_VERDICT" ] && agent_marker_matches "$ARTIFACTS/06-liveness-busy.processes.txt"; then
    record_result liveness pass "backend verdict and raw process markers matched the adapter record" \
      "evidence/06-liveness-busy.processes.txt"
  else
    record_result liveness fail "expected backend=$ALIVE_VERDICT plus comm=$COMM_REGEX and argv=$ARGV_REGEX, got backend=$alive_before" \
      "evidence/06-liveness-busy.processes.txt"
  fi
  send_key_list "$INTERRUPT_KEYS" || true
  sleep 1
  wait_until_not_busy || true
  capture_pane 04-interrupt 180
  capture_processes 04-interrupt
  alive_after=$(fm_backend_agent_alive tmux "$TARGET" 2>/dev/null || printf unknown)
  interrupt_text=$(cat "$ARTIFACTS/04-interrupt.txt")
  if [ "$alive_after" = "$ALIVE_VERDICT" ] && agent_marker_matches "$ARTIFACTS/04-interrupt.processes.txt" \
     && { [ "$INTERRUPT_REGEX" = - ] || printf '%s' "$interrupt_text" | grep -qiE "$INTERRUPT_REGEX" || ! pane_text_matches "$BUSY_REGEX"; }; then
    record_result interrupt pass "recorded key ended the turn while the runtime process survived" \
      "evidence/04-interrupt.ansi,evidence/04-interrupt.processes.txt"
  else
    record_result interrupt fail "interrupt did not leave the expected live runtime process" \
      "evidence/04-interrupt.ansi,evidence/04-interrupt.processes.txt"
  fi
}

probe_autonomy_turnend() {
  local proof="$WORKSPACE/.fm-exam-autonomy" token="FM_EXAM_AUTONOMY_${RANDOM}_${RANDOM}" prompt mode_present=0
  rm -f "$HOOK_MARKER" "$HOOK_RAW" "$proof"
  if [ "$ADAPTER" = pi ] || printf '%s' "$LAUNCH_CMD" | grep -qE -- "$AUTONOMY_FLAG"; then
    mode_present=1
  fi
  printf '%s\n' "$token" > "$ARTIFACTS/resume-token.txt"
  prompt="Use the shell tool without asking for approval to run exactly: printf '%s\\n' '$token' > '$proof'. Then reply exactly $token and remember that token for this session."
  submit_text "$prompt" || true
  if [ "$mode_present" = 1 ] && wait_for_file "$proof" && [ "$(cat "$proof" 2>/dev/null)" = "$token" ]; then
    capture_pane 01-autonomy 180
    printf 'launch=%s\nautonomy=%s\nproof=%s\n' "$LAUNCH_CMD" "$AUTONOMY_FLAG" "$(cat "$proof")" \
      > "$ARTIFACTS/01-autonomy-command.txt"
    record_result autonomy pass "the recorded unattended mode executed a real tool without an approval response" \
      "evidence/01-autonomy-command.txt,evidence/01-autonomy.ansi"
  else
    capture_pane 01-autonomy-failed 180
    record_result autonomy fail "the recorded unattended mode was absent or its tool proof was not created" \
      "evidence/01-autonomy-failed.ansi"
  fi
  if wait_for_marker "$HOOK_MARKER" && [ -s "$HOOK_RAW" ]; then
    cp "$HOOK_RAW" "$ARTIFACTS/05-turn-end-payload.txt"
    record_result turn-end pass "the native per-turn hook produced an external marker and raw payload" \
      "evidence/05-turn-end-payload.txt"
  else
    capture_pane 05-turn-end-missing 180
    [ -e "$HOOK_RAW" ] && cp "$HOOK_RAW" "$ARTIFACTS/05-turn-end-payload.txt"
    record_result turn-end fail "the completed turn produced no independently recorded hook evidence" \
      "evidence/05-turn-end-payload.txt,evidence/05-turn-end-missing.ansi"
  fi
}

probe_exit() {
  local deadline=$((SECONDS + TIMEOUT)) verdict
  capture_pane 07-before-exit 100
  tmux send-keys -t "$TARGET" -l "$EXIT_COMMAND"
  sleep 1.2
  tmux send-keys -t "$TARGET" Enter
  sleep 1.5
  verdict=$(fm_backend_agent_alive tmux "$TARGET" 2>/dev/null || printf unknown)
  if [ "$verdict" != dead ]; then
    tmux send-keys -t "$TARGET" Enter >/dev/null 2>&1 || true
  fi
  while [ "$SECONDS" -lt "$deadline" ]; do
    verdict=$(fm_backend_agent_alive tmux "$TARGET" 2>/dev/null || printf unknown)
    [ "$verdict" = dead ] && break
    sleep 1
  done
  capture_pane 07-exit 200
  if [ "$verdict" = dead ]; then
    record_result exit pass "the recorded exit command returned the pane to its shell" "evidence/07-exit.ansi"
  else
    record_result exit fail "the runtime remained live after the recorded exit command" "evidence/07-exit.ansi"
  fi
}

cursor_resume_id() {
  grep -Eo 'agent --resume[= ][0-9a-fA-F-]{20,}' "$ARTIFACTS/07-exit.txt" 2>/dev/null \
    | tail -1 | sed -E 's/.*--resume[= ]//' || true
}

probe_resume() {
  local token cursor_id="" restored=0
  token=$(cat "$ARTIFACTS/resume-token.txt" 2>/dev/null || true)
  if [ "$RESUME_MODE" = cursor-id ]; then
    cursor_id=$(cursor_resume_id)
    if [ -z "$cursor_id" ]; then
      record_result resume fail "the exit evidence did not contain Cursor's resume id" "evidence/07-exit.txt"
      return 0
    fi
  fi
  build_launch_command 1 "$cursor_id" || {
    record_result resume fail "could not construct the recorded resume command" ""
    return 0
  }
  printf '%s\n' "$RESUME_CMD" > "$ARTIFACTS/08-resume-command.txt"
  launch_runtime resume "$RESUME_CMD" || {
    record_result resume fail "could not launch the resume command" "evidence/08-resume-command.txt"
    return 0
  }
  if wait_for_composer; then
    capture_pane 08-resume-initial 220
    if grep -qF "$token" "$ARTIFACTS/08-resume-initial.txt"; then
      restored=1
    else
      submit_text "Reply with exactly the resume token I asked you to remember in the previous turn." || true
      if wait_for_regex "$token"; then restored=1; fi
      capture_pane 08-resume-recall 220
    fi
  fi
  if [ "$restored" = 1 ]; then
    record_result resume pass "the recorded resume path restored evidence from the prior conversation" \
      "evidence/08-resume-command.txt,evidence/08-resume-initial.ansi,evidence/08-resume-recall.ansi"
  else
    capture_pane 08-resume-failed 220
    record_result resume fail "the resumed runtime did not restore or recall the prior conversation token" \
      "evidence/08-resume-command.txt,evidence/08-resume-failed.ansi"
  fi
}

prepare_run() {
  local stamp base
  command -v tmux >/dev/null 2>&1 || { echo "error: tmux is required" >&2; return 1; }
  command -v jq >/dev/null 2>&1 || { echo "error: jq is required" >&2; return 1; }
  command -v "$BINARY" >/dev/null 2>&1 || { echo "error: adapter binary '$BINARY' is not installed" >&2; return 1; }
  stamp=$(date -u +%Y%m%dT%H%M%SZ)
  base=${FM_HOME:-$ROOT}
  [ -n "$OUTPUT" ] || OUTPUT="$base/data/harness-exam/$ADAPTER-$stamp"
  [ ! -e "$OUTPUT" ] || { echo "error: output already exists: $OUTPUT" >&2; return 1; }
  mkdir -p "$OUTPUT/evidence"
  OUTPUT=$(cd "$OUTPUT" && pwd -P)
  ARTIFACTS="$OUTPUT/evidence"
  RESULTS_TSV="$OUTPUT/.results.tsv"
  : > "$RESULTS_TSV"
  LAB_ROOT=$(mktemp -d "${TMPDIR:-/tmp}/fm-harness-exam.$ADAPTER.XXXXXX")
  LAB_HOME="$LAB_ROOT/home"
  WORKSPACE="$LAB_ROOT/workspace"
  HOOK_MARKER="$LAB_ROOT/turn-ended"
  HOOK_RAW="$LAB_ROOT/turn-end.raw"
  mkdir -p "$LAB_HOME" "$WORKSPACE" "$LAB_ROOT/tmux"
  trap on_exit EXIT INT TERM
  git -C "$WORKSPACE" init -q
  printf '# Firstmate worker-runtime exam lab\n' > "$WORKSPACE/README.md"
  git -C "$WORKSPACE" add README.md
  git -C "$WORKSPACE" -c user.name='Firstmate Exam' -c user.email='exam@example.invalid' commit -qm initial
  prepare_credential_bridges || return 1
  prepare_hook || return 1
  VERSION=$("$BINARY" --version 2>&1 | head -1 || true)
  [ -n "$VERSION" ] || VERSION=unknown
  printf '%s\n' "$VERSION" > "$ARTIFACTS/runtime-version.txt"
  printf 'adapter=%s\nversion=%s\nlab=%s\nworkspace=%s\nstartup_dialog=%s\n' \
    "$ADAPTER" "$VERSION" "$LAB_ROOT" "$WORKSPACE" "$STARTUP_DIALOG" \
    > "$ARTIFACTS/run-context.txt"
  export TMUX_TMPDIR="$LAB_ROOT/tmux"
  unset TMUX
}

run_exam() {
  if ! prepare_run; then return 2; fi
  build_launch_command 0 || return 2
  printf '%s\n' "$LAUNCH_CMD" > "$ARTIFACTS/00-launch-command.txt"
  if ! launch_runtime main "$LAUNCH_CMD"; then
    record_missing_results
    render_results
    return 1
  fi
  if ! wait_for_composer; then
    capture_pane 00-startup-failed 200
    capture_processes 00-startup-failed
    record_missing_results
    render_results
    return 1
  fi
  capture_pane 00-startup 120
  probe_composer
  probe_busy_interrupt_liveness
  probe_autonomy_turnend
  probe_exit
  probe_resume
  record_missing_results
  render_results
  cleanup_lab
  if [ "$RUN_FAILED" = 0 ]; then
    printf 'PASS %s %s: %s/results.json\n' "$ADAPTER" "$VERSION" "$OUTPUT"
    return 0
  fi
  printf 'FAIL %s %s: %s/scorecard.md\n' "$ADAPTER" "$VERSION" "$OUTPUT" >&2
  return 1
}

parse_args() {
  while [ "$#" -gt 0 ]; do
    case "$1" in
      --help|-h) usage; exit 0 ;;
      --list) MODE=list; shift ;;
      --plan)
        [ "$#" -ge 2 ] || { echo "error: --plan requires an adapter" >&2; return 2; }
        MODE=plan
        ADAPTER=$2
        shift 2
        ;;
      --model)
        [ "$#" -ge 2 ] || { echo "error: --model requires a value" >&2; return 2; }
        MODEL=$2
        shift 2
        ;;
      --output)
        [ "$#" -ge 2 ] || { echo "error: --output requires a directory" >&2; return 2; }
        OUTPUT=$2
        shift 2
        ;;
      --timeout)
        [ "$#" -ge 2 ] || { echo "error: --timeout requires seconds" >&2; return 2; }
        TIMEOUT=$2
        case "$TIMEOUT" in ''|*[!0-9]*|0) echo "error: --timeout must be a positive integer" >&2; return 2 ;; esac
        shift 2
        ;;
      --keep-lab) KEEP_LAB=1; shift ;;
      --source-home)
        [ "$#" -ge 2 ] || { echo "error: --source-home requires a directory" >&2; return 2; }
        SOURCE_HOME=$2
        shift 2
        ;;
      --*) echo "error: unknown option '$1'" >&2; return 2 ;;
      *)
        [ -z "$ADAPTER" ] || { echo "error: unexpected argument '$1'" >&2; return 2; }
        ADAPTER=$1
        shift
        ;;
    esac
  done
}

main() {
  parse_args "$@" || return $?
  case "$MODE" in
    list) list_adapters; return 0 ;;
    plan) print_plan "$ADAPTER"; return $? ;;
  esac
  [ -n "$ADAPTER" ] || { usage >&2; return 2; }
  load_expectation "$ADAPTER" || {
    echo "error: unsupported adapter '$ADAPTER' (expected one of: $(list_adapters | paste -sd, -))" >&2
    return 2
  }
  run_exam
}

if [ "${FM_HARNESS_EXAM_SOURCE_ONLY:-0}" != 1 ]; then
  main "$@"
fi
