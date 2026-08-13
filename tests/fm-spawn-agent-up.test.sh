#!/usr/bin/env bash
# Regression tests for fm-spawn.sh's agent-up verification (bin/fm-spawn.sh,
# spawn_wait_agent_up / spawn_refuse_agent_never_started).
#
# The bug these pin: until an agent actually owns the pane, everything typed
# there is SHELL input. When the launch never started the agent, the brief - on
# the launch line for every verified adapter except kimi, typed separately for
# kimi - landed in a bare shell as continuation soup, no agent ever read it, and
# fm-spawn still reported "spawned", so the pane looked alive and a later steer
# "succeeded" into that same shell.
#
# Asserted here, with a fake tmux whose pane_current_command drives the shared
# liveness owner (fm_backend_tmux_agent_alive):
#   1. kimi's post-launch brief is typed only AFTER the agent is proven up.
#   2. A pane still proven to be a bare shell refuses loudly at the bound, in
#      both delivery shapes, without typing the brief and without tearing the
#      task down, and names the exact recovery.
#   3. The happy path is unchanged: the launch line still carries the brief and
#      the spawn still reports success.
#   4. A harness/backend pair whose liveness cannot be read (pi's generic node
#      process on tmux) neither refuses nor stalls to the bound.
#   5. The wait is bounded and its knobs are validated.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

SPAWN="$ROOT/bin/fm-spawn.sh"
TMP_ROOT=$(fm_test_tmproot fm-spawn-agent-up)

# make_case <name> <harness> <launch-binary>: a home, a real worktree, and a
# fake tmux that records an ORDERED event log so "typed before proven up" is
# directly observable:
#   probe:<command>   one pane_current_command read (what the liveness owner saw)
#   literal:<text>    one `send-keys -l` literal (the launch line, or the brief)
#   key:<name>        one special key
# The reported pane command walks FM_FAKE_COMMAND_SEQ (one per line, last line
# repeating forever), so a case can model a shell that becomes an agent, or one
# that never does.
make_case() {
  local name=$1 harness=$2 launch_binary=$3 fakebin
  CASE_DIR="$TMP_ROOT/$name"
  HOME_DIR="$CASE_DIR/home"
  PROJ_DIR="$CASE_DIR/project"
  WT_DIR="$CASE_DIR/wt"
  EVENT_LOG="$CASE_DIR/events.log"
  COMMAND_SEQ="$CASE_DIR/pane-command-seq"
  COMMAND_COUNT="$CASE_DIR/pane-command-count"
  ID="agentup-$name"
  fakebin=$(fm_fakebin "$CASE_DIR")
  FAKEBIN_DIR=$fakebin

  mkdir -p "$HOME_DIR/data/$ID" "$HOME_DIR/projects" "$HOME_DIR/config" "$HOME_DIR/state"
  printf '%s\n' "$harness" > "$HOME_DIR/config/crew-harness"
  # A multi-line brief is the shape that spills through a shell, so fixtures use
  # one rather than a single tidy line.
  printf 'brief for %s\nsecond line of the brief\n' "$ID" > "$HOME_DIR/data/$ID/brief.md"
  fm_git_worktree "$PROJ_DIR" "$WT_DIR" "wt-$name"
  touch "$HOME_DIR/state/.last-watcher-beat"
  : > "$EVENT_LOG"

  cat > "$fakebin/tmux" <<'SH'
#!/usr/bin/env bash
set -u
log=${FM_FAKE_EVENT_LOG:?}
case "$*" in
  *"#{pane_current_path}"*) printf '%s\n' "${FM_FAKE_PANE_PATH:-}"; exit 0 ;;
  *"#{pane_current_command}"*)
    countfile=${FM_FAKE_COMMAND_COUNT:?}
    n=0
    [ -f "$countfile" ] && n=$(cat "$countfile")
    n=$((n + 1))
    printf '%s\n' "$n" > "$countfile"
    line=$(sed -n "${n}p" "${FM_FAKE_COMMAND_SEQ:?}" || true)
    [ -n "$line" ] || line=$(awk 'NF{l=$0} END{print l}' "$FM_FAKE_COMMAND_SEQ")
    printf 'probe:%s\n' "$line" >> "$log"
    printf '%s\n' "$line"
    exit 0
    ;;
  *"#{pane_pid}"*) exit 0 ;;
esac
case "${1:-}" in
  display-message) printf 'firstmate\n'; exit 0 ;;
  new-window) printf '@42\n'; exit 0 ;;
  list-windows|has-session|new-session|set-window-option|kill-window) exit 0 ;;
  send-keys)
    prev=
    for arg in "$@"; do
      case "$prev" in
        -l) printf 'literal:%s\n' "$arg" >> "$log" ;;
      esac
      prev=$arg
    done
    case "$*" in
      *" Enter") printf 'key:Enter\n' >> "$log" ;;
    esac
    exit 0
    ;;
esac
exit 0
SH
  chmod +x "$fakebin/tmux"
  fm_fake_exit0 "$fakebin" treehouse
  cat > "$fakebin/$launch_binary" <<'SH'
#!/usr/bin/env bash
set -u
[ "$#" -eq 1 ] && [ "$1" = "--version" ]
SH
  chmod +x "$fakebin/$launch_binary"
}

# set_command_sequence <line...>: what pane_current_command reports, in order.
set_command_sequence() {
  printf '%s\n' "$@" > "$COMMAND_SEQ"
  rm -f "$COMMAND_COUNT"
}

run_spawn() {
  env \
    FM_ROOT_OVERRIDE='' \
    FM_HOME="$HOME_DIR" \
    FM_STATE_OVERRIDE="$HOME_DIR/state" \
    FM_DATA_OVERRIDE="$HOME_DIR/data" \
    FM_PROJECTS_OVERRIDE="$HOME_DIR/projects" \
    FM_CONFIG_OVERRIDE="$HOME_DIR/config" \
    FM_SPAWN_NO_GUARD=1 \
    TMUX="fake,1,0" \
    FM_FAKE_PANE_PATH="$WT_DIR" \
    FM_FAKE_EVENT_LOG="$EVENT_LOG" \
    FM_FAKE_COMMAND_SEQ="$COMMAND_SEQ" \
    FM_FAKE_COMMAND_COUNT="$COMMAND_COUNT" \
    FM_KIMI_BRIEF_SETTLE_SECS=0 \
    FM_SPAWN_AGENT_UP_SLEEP=0 \
    GROK_HOME="$HOME_DIR/grok-home" \
    PATH="$FAKEBIN_DIR:/usr/bin:/bin" \
    "$@" \
    "$SPAWN" "$ID" "$PROJ_DIR" 2>&1
}

cleanup_task_tmp() { rm -rf "/tmp/fm-$1"; }

# Line number of the first event log entry matching <pattern>, or empty.
event_line() {  # <pattern>
  grep -n -- "$1" "$EVENT_LOG" | head -1 | cut -d: -f1
}

# kimi is the one adapter whose brief firstmate types itself, after the launch.
# It must not be typed while the pane is still a shell: here the pane reports a
# shell for the first reads and only then the agent.
test_kimi_brief_is_typed_only_after_the_agent_is_up() {
  local out status brief_at up_at
  make_case kimi-waits kimi kimi
  set_command_sequence zsh zsh kimi

  out=$(run_spawn)
  status=$?

  expect_code 0 "$status" "kimi spawn should succeed once the agent comes up"
  assert_contains "$out" "spawned $ID harness=kimi" "kimi spawn did not reach the healthy path"
  # kimi's launch line carries no brief, so the launch-brief literal IS the
  # separate post-launch delivery being ordered against the liveness proof.
  brief_at=$(event_line 'literal:.*launch-brief:')
  up_at=$(event_line 'probe:kimi')
  [ -n "$brief_at" ] || fail "kimi brief was never delivered"
  [ -n "$up_at" ] || fail "the agent was never observed up"
  [ "$brief_at" -gt "$up_at" ] \
    || fail "kimi brief was typed at event $brief_at, before the agent was proven up at event $up_at"
  cleanup_task_tmp "$ID"
  pass "kimi's post-launch brief is typed only after the agent is proven up"
}

# The spill itself, in the shape where firstmate does the typing: the pane never
# stops being a bare shell, so the brief must never be typed into it.
test_dead_shell_refuses_before_typing_the_brief() {
  local out status
  make_case kimi-dead kimi kimi
  set_command_sequence zsh

  out=$(run_spawn FM_SPAWN_AGENT_UP_MAX_POLLS=4)
  status=$?

  expect_code 1 "$status" "a pane still sitting at a bare shell should refuse"
  assert_contains "$out" "no agent is running" "refusal did not say the agent never started"
  assert_contains "$out" "4 poll(s) x 0s" "refusal did not report the bound it waited out"
  assert_contains "$out" "The brief was NOT delivered" "refusal did not say the brief was withheld"
  assert_not_contains "$out" "spawned $ID" "refused spawn still reported success"
  assert_no_grep 'launch-brief:' "$EVENT_LOG" \
    "the brief was typed into a pane that was still a bare shell"
  cleanup_task_tmp "$ID"
  pass "a bare shell refuses loudly at the bound instead of receiving the brief"
}

# The same spill in the shape where the brief rides the launch line: it is
# already gone into the shell, so the refusal's job is to stop the silence - and
# to leave the task recoverable with the exact recovery spelled out.
test_dead_shell_refusal_is_recoverable_and_actionable() {
  local out status
  make_case claude-dead claude claude
  set_command_sequence zsh

  out=$(run_spawn FM_SPAWN_AGENT_UP_MAX_POLLS=3)
  status=$?

  expect_code 1 "$status" "a launch that never started its agent should refuse"
  assert_contains "$out" "3 poll(s) x 0s" "refusal did not report the bound it waited out"
  assert_contains "$out" "Nothing was torn down" "refusal did not state the task survived"
  assert_present "$HOME_DIR/state/$ID.meta" "refusal removed the task's durable record"
  assert_grep "worktree=$WT_DIR" "$HOME_DIR/state/$ID.meta" "refusal dropped the task's worktree"
  assert_contains "$out" "--key C-c" "refusal did not say to interrupt the pane"
  assert_contains "$out" "Read $HOME_DIR/data/$ID/brief.md and execute it fully" \
    "refusal did not offer the file-pointer relaunch"
  assert_contains "$out" "cd '$WT_DIR' && CLAUDE_CODE_ENABLE_PROMPT_SUGGESTION=false claude --dangerously-skip-permissions" \
    "recovery relaunch was not rendered from this task's own launch template"
  assert_not_contains "$out" "second line of the brief" \
    "the recovery relaunch pastes the brief inline instead of pointing at its file"
  cleanup_task_tmp "$ID"
  pass "a refusal leaves the task recoverable and prints the exact one-line file-pointer relaunch"
}

# The happy path must not change: the launch line still carries the brief inline
# and the spawn still reports success.
test_happy_path_launch_is_unchanged() {
  local out status deliveries
  make_case claude-ok claude claude
  set_command_sequence zsh claude

  out=$(run_spawn)
  status=$?

  expect_code 0 "$status" "a healthy claude spawn should succeed"
  assert_contains "$out" "spawned $ID harness=claude" "healthy spawn did not report success"
  assert_grep 'literal:CLAUDE_CODE_ENABLE_PROMPT_SUGGESTION=false claude --dangerously-skip-permissions' \
    "$EVENT_LOG" "the launch line was not sent unchanged"
  assert_grep 'second line of the brief' "$EVENT_LOG" \
    "the launch line no longer carries the brief"
  deliveries=$(grep -c '^literal:.*launch-brief:' "$EVENT_LOG" || true)
  [ "$deliveries" = 1 ] \
    || fail "expected the brief to ride the launch line exactly once, saw $deliveries deliveries"
  assert_present "$HOME_DIR/state/$ID.meta" "healthy spawn did not write task meta"
  cleanup_task_tmp "$ID"
  pass "the healthy launch path is unchanged and still carries the brief on the launch line"
}

# pi execs into a generic node process that cannot be attributed back to pi from
# outside the pane, so liveness is genuinely unavailable. That must not become a
# refusal, and must not burn the whole bound waiting for an answer that will
# never come.
test_unreadable_liveness_neither_refuses_nor_burns_the_bound() {
  local out status probes
  make_case pi-node pi pi
  set_command_sequence zsh node

  out=$(run_spawn FM_SPAWN_AGENT_UP_MAX_POLLS=40)
  status=$?

  expect_code 0 "$status" "an unreadable-liveness harness should still spawn"
  assert_contains "$out" "spawned $ID harness=pi" "pi spawn did not reach the healthy path"
  # Each inconclusive read costs a few pane queries (the node case also asks
  # whether the process is cursor or prime-agent), so this bounds the number of
  # WAIT ROUNDS loosely rather than exactly: running the 40-poll bound out would
  # cost an order of magnitude more queries than this.
  probes=$(grep -c '^probe:' "$EVENT_LOG" || true)
  [ "$probes" -le 12 ] \
    || fail "unreadable liveness polled $probes times - it should settle in a few reads, not run to the bound"
  cleanup_task_tmp "$ID"
  pass "an unreadable liveness answer neither refuses the spawn nor waits out the bound"
}

# A wait that cannot be trusted to terminate is the thing being removed, so a
# malformed bound is refused rather than silently defaulted.
test_invalid_bound_knobs_are_refused() {
  local out status
  make_case knobs claude claude
  set_command_sequence zsh claude

  out=$(run_spawn FM_SPAWN_AGENT_UP_MAX_POLLS=0)
  status=$?
  expect_code 1 "$status" "a zero poll bound should be refused"
  assert_contains "$out" "FM_SPAWN_AGENT_UP_MAX_POLLS must be a positive integer" \
    "zero poll bound was not refused by name"

  out=$(run_spawn FM_SPAWN_AGENT_UP_SLEEP=half)
  status=$?
  expect_code 1 "$status" "a non-numeric sleep should be refused"
  assert_contains "$out" "FM_SPAWN_AGENT_UP_SLEEP must be a non-negative integer" \
    "non-numeric sleep was not refused by name"
  cleanup_task_tmp "$ID"
  pass "malformed agent-up bound knobs are refused instead of silently defaulted"
}

test_kimi_brief_is_typed_only_after_the_agent_is_up
test_dead_shell_refuses_before_typing_the_brief
test_dead_shell_refusal_is_recoverable_and_actionable
test_happy_path_launch_is_unchanged
test_unreadable_liveness_neither_refuses_nor_burns_the_bound
test_invalid_bound_knobs_are_refused

echo "# all fm-spawn-agent-up tests passed"
