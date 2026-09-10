#!/usr/bin/env bash
# Canonical Firstmate status-bar contract and adapter integration regressions.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

TMP_ROOT=$(fm_test_tmproot fm-status-bar)
HOME_FIX="$TMP_ROOT/home"
FAKEBIN=$(fm_fakebin "$TMP_ROOT")
mkdir -p "$HOME_FIX/state"

cat > "$FAKEBIN/stat" <<'SH'
#!/usr/bin/env bash
printf '%s\n' "${FM_STATUS_BAR_TEST_BEAT_EPOCH:-900}"
SH
chmod +x "$FAKEBIN/stat"

strip_ansi() {
  sed $'s/\033\\[[0-9;]*m//g'
}

render() {
  PATH="$FAKEBIN:$PATH" \
    FM_HOME="$HOME_FIX" \
    FM_PRIMARY_HARNESS=pi \
    FM_STATUS_BAR_NOW=1000 \
    "$ROOT/bin/fm-status-bar.sh" \
      --adapter pi \
      --model "${1:-Opus}" \
      --effort "${2:-high}" \
      --context-used "${3:---}" \
      --quota-used "${4:---}" \
      --cost "${5:---}"
}

# The companion must never publish a frame the collector has not filled in yet.
# The probe is a fake `stat`, which the renderer calls while it is collecting:
# it snapshots the bytes already written to the pane at that exact moment, so a
# snapshot that ends with a bare row erase proves the row was blank on screen
# for the whole length of the collection.
test_companion_never_leaves_the_row_blank_while_collecting() {
  local out_file="$TMP_ROOT/blank-out.raw" snap_dir="$TMP_ROOT/blank-snaps"
  local count_file="$TMP_ROOT/blank-count" snap_count_file="$TMP_ROOT/blank-snap-count"
  local refreshes=3 snap snaps blanked=

  rm -rf "$snap_dir"
  mkdir -p "$snap_dir"
  : > "$out_file"
  rm -f "$count_file" "$snap_count_file"
  fm_install_fake_tmux_pane "$FAKEBIN" "$refreshes"
  # Snapshots are numbered from a counter file rather than a timestamp: BSD
  # `date` has no %N, so every probe call inside one second would otherwise
  # write the same name and leave a single collection to stand for all of them.
  cat > "$FAKEBIN/stat" <<'SH'
#!/usr/bin/env bash
if [ -n "${FM_STATUS_BAR_TEST_SNAPDIR:-}" ]; then
  seq=0
  [ ! -f "$FM_STATUS_BAR_TEST_SNAPCOUNT" ] || seq=$(<"$FM_STATUS_BAR_TEST_SNAPCOUNT")
  seq=$((seq + 1))
  printf '%s\n' "$seq" > "$FM_STATUS_BAR_TEST_SNAPCOUNT"
  cp "$FM_STATUS_BAR_TEST_OUT" "$FM_STATUS_BAR_TEST_SNAPDIR/$seq.snap" 2>/dev/null
fi
printf '%s\n' "${FM_STATUS_BAR_TEST_BEAT_EPOCH:-900}"
SH
  chmod +x "$FAKEBIN/stat"
  : > "$HOME_FIX/state/.last-watcher-beat"

  # shellcheck disable=SC2094 # The probe reads the pane bytes written so far
  # from the very file this run is writing; that is the measurement, not a bug.
  PATH="$FAKEBIN:$PATH" \
    FM_HOME="$HOME_FIX" \
    FM_PRIMARY_HARNESS=kimi \
    FM_STATUS_BAR_INTERVAL=0 \
    FM_STATUS_BAR_TMUX_COUNT="$count_file" \
    FM_STATUS_BAR_TEST_SNAPDIR="$snap_dir" \
    FM_STATUS_BAR_TEST_SNAPCOUNT="$snap_count_file" \
    FM_STATUS_BAR_TEST_OUT="$out_file" \
    "$ROOT/bin/fm-status-bar.sh" \
      --adapter kimi --model kimi-code/k3 --effort -- --follow-pane %42 \
    > "$out_file"

  # One snapshot per collection, or the check is narrower than it advertises.
  snaps=$(find "$snap_dir" -name '*.snap' | wc -l | tr -d ' ')
  [ "$snaps" -eq "$refreshes" ] \
    || fail "the collection probe left $snaps snapshots for $refreshes refreshes, so the blank-frame check proved less than it claims"
  for snap in "$snap_dir"/*.snap; do
    case "$(cat "$snap")" in
      *$'\033[2K') blanked=1 ;;
    esac
  done
  [ -z "$blanked" ] \
    || fail "the companion erased the row and left it blank while it collected the next frame"
  assert_contains "$(cat "$out_file")" '⚓' "the companion stopped rendering the status row"
  # The erase is what clips a shorter frame's stale tail, so it must survive -
  # it just has to reach the pane in the same write as the frame it precedes.
  assert_contains "$(cat "$out_file")" $'\033[H\033[2K\033[1m⚓' \
    "the row erase no longer arrives together with the frame it introduces"
  rm -f "$FAKEBIN/tmux"
  pass "status bar: the companion never blanks its row while collecting a frame"
}

test_companion_publishes_every_refresh_to_the_pane() {
  local out count_file="$TMP_ROOT/repeat-count" rows

  : > "$HOME_FIX/state/.last-watcher-beat"

  # A frozen clock and a frozen fleet make all three rows byte-identical, and
  # every one of them must still be published. A settled fleet with no watcher
  # beat holds every field constant, so a row published only when it changes is
  # written once and stays clipped to the width it was written at - a companion
  # widened after that would never recover the rest of the row.
  rm -f "$count_file"
  fm_install_fake_tmux_pane "$FAKEBIN" 3
  cat > "$FAKEBIN/stat" <<'SH'
#!/usr/bin/env bash
printf '%s\n' "${FM_STATUS_BAR_TEST_BEAT_EPOCH:-900}"
SH
  chmod +x "$FAKEBIN/stat"
  out=$(PATH="$FAKEBIN:$PATH" \
    FM_HOME="$HOME_FIX" \
    FM_PRIMARY_HARNESS=kimi \
    FM_STATUS_BAR_NOW=1000 \
    FM_STATUS_BAR_INTERVAL=0 \
    FM_STATUS_BAR_TMUX_COUNT="$count_file" \
    "$ROOT/bin/fm-status-bar.sh" \
      --adapter kimi --model kimi-code/k3 --effort -- --follow-pane %42)
  rows=$(printf '%s' "$out" | grep -o '⚓' | wc -l | tr -d ' ')
  [ "$rows" -eq 3 ] \
    || fail "three refreshes published $rows unchanged rows instead of one row each"

  # A clock that moves one second per refresh changes the supervision age, and
  # every one of those changes must reach the pane.
  rm -f "$count_file"
  fm_install_fake_tmux_pane "$FAKEBIN" 3
  cat > "$FAKEBIN/stat" <<'SH'
#!/usr/bin/env bash
epoch=900
[ ! -f "$FM_STATUS_BAR_TEST_BEAT_FILE" ] || epoch=$(<"$FM_STATUS_BAR_TEST_BEAT_FILE")
printf '%s\n' "$((epoch - 1))" > "$FM_STATUS_BAR_TEST_BEAT_FILE"
printf '%s\n' "$epoch"
SH
  chmod +x "$FAKEBIN/stat"
  rm -f "$TMP_ROOT/beat-epoch"
  out=$(PATH="$FAKEBIN:$PATH" \
    FM_HOME="$HOME_FIX" \
    FM_PRIMARY_HARNESS=kimi \
    FM_STATUS_BAR_NOW=1000 \
    FM_STATUS_BAR_INTERVAL=0 \
    FM_STATUS_BAR_TMUX_COUNT="$count_file" \
    FM_STATUS_BAR_TEST_BEAT_FILE="$TMP_ROOT/beat-epoch" \
    "$ROOT/bin/fm-status-bar.sh" \
      --adapter kimi --model kimi-code/k3 --effort -- --follow-pane %42 | strip_ansi)
  rows=$(printf '%s' "$out" | grep -o '⚓' | wc -l | tr -d ' ')
  [ "$rows" -eq 3 ] \
    || fail "three refreshes published $rows rows instead of one row each"
  assert_contains "$out" '👁 100s' "the first supervision age never reached the pane"
  assert_contains "$out" '👁 101s' "a changed supervision age never reached the pane"
  assert_contains "$out" '👁 102s' "a changed supervision age never reached the pane"
  rm -f "$FAKEBIN/tmux"
  cat > "$FAKEBIN/stat" <<'SH'
#!/usr/bin/env bash
printf '%s\n' "${FM_STATUS_BAR_TEST_BEAT_EPOCH:-900}"
SH
  chmod +x "$FAKEBIN/stat"
  pass "status bar: the companion publishes a row on every refresh"
}

test_contract_order_and_fleet_projection() {
  local out
  fm_write_meta "$HOME_FIX/state/working.meta" "kind=crew"
  printf 'working: implementation\n' > "$HOME_FIX/state/working.status"
  fm_write_meta "$HOME_FIX/state/paused.meta" "kind=crew"
  printf 'working: setup\n\npaused: upstream release\n' > "$HOME_FIX/state/paused.status"
  fm_write_meta "$HOME_FIX/state/attention.meta" "kind=scout"
  printf 'working: diagnosis\nblocked: missing fixture\n' > "$HOME_FIX/state/attention.status"
  fm_write_meta "$HOME_FIX/state/domain.meta" "kind=secondmate"
  printf 'blocked: must not count\n' > "$HOME_FIX/state/domain.status"
  : > "$HOME_FIX/state/.last-watcher-beat"
  : > "$HOME_FIX/state/.afk"

  out=$(render Opus high 42 73 1.235 | strip_ansi)
  [ "$out" = "⚓ Opus·high │ 🧠42% ⚡73% │ 🚢3 ⏸1 ⚠1 │ 👁 100s │ \$1.24 │ 💤AFK" ] \
    || fail "canonical fields, order, fleet counts, or formatting drifted: $out"
  pass "status bar: canonical field order and fleet projection are stable"
}

test_threshold_colors_and_placeholders() {
  local out
  # Context-used thresholds invert the prior remaining bands: green at/under 70%,
  # yellow at 71-85% (was under 30% remaining), red at 86%+ (was under 15%).
  out=$(render Opus high 70 69 0)
  assert_contains "$out" $'\033[92m🧠70%' "70% context used is not bright green"
  assert_contains "$out" $'\033[92m⚡69%' "69% quota used is not bright green"

  out=$(render Opus high 71 70 0)
  assert_contains "$out" $'\033[93m🧠71%' "71% context used is not bright yellow"
  assert_contains "$out" $'\033[93m⚡70%' "70% quota used is not bright yellow"

  out=$(render Opus high 85 70 0)
  assert_contains "$out" $'\033[93m🧠85%' "85% context used is not bright yellow"

  out=$(render Opus high 86 90 0)
  assert_contains "$out" $'\033[91m🧠86%' "86% context used is not bright red"
  assert_contains "$out" $'\033[91m⚡90%' "90% quota used is not bright red"

  out=$(render Opus high -- -- -- | strip_ansi)
  assert_contains "$out" '🧠-- ⚡--' "unavailable provider metrics do not use canonical placeholders"
  assert_contains "$out" '$--' "unavailable session cost does not use the canonical placeholder"
  pass "status bar: threshold colors and unavailable-metric placeholders are canonical"
}

test_no_watch_is_bright_red_when_missing_or_stale() {
  local out
  rm -f "$HOME_FIX/state/.last-watcher-beat"
  out=$(render Opus high 50 10 0)
  assert_contains "$out" $'\033[91;1m👁 NO-WATCH --' "missing supervision beacon is not a bright-red NO-WATCH alert"

  : > "$HOME_FIX/state/.last-watcher-beat"
  out=$(FM_STATUS_BAR_TEST_BEAT_EPOCH=800 render Opus high 50 10 0)
  assert_contains "$out" $'\033[91;1m👁 NO-WATCH 200s' "stale supervision beacon is not a bright-red NO-WATCH alert"

  out=$(PATH="$FAKEBIN:$PATH" \
    FM_HOME="$HOME_FIX" \
    FM_PRIMARY_HARNESS=pi \
    FM_STATUS_BAR_NOW=invalid \
    "$ROOT/bin/fm-status-bar.sh" \
      --adapter pi \
      --model Opus \
      --effort high)
  assert_contains "$out" $'\033[91;1m👁 NO-WATCH --' "unreadable supervision time is not a bright-red NO-WATCH alert"
  pass "status bar: missing and stale supervision are loud NO-WATCH alerts"
}

test_claude_payload_adapter_and_primary_guard() {
  local input out
  input='{"model":{"display_name":"Claude Fable"},"effort":{"level":"high"},"context_window":{"used_percentage":35.2,"remaining_percentage":64.8},"rate_limits":{"five_hour":{"used_percentage":12.9}},"cost":{"total_cost_usd":2.345}}'
  out=$(printf '%s' "$input" | \
    PATH="$FAKEBIN:$PATH" \
    FM_HOME="$HOME_FIX" \
    FM_PRIMARY_HARNESS=claude \
    FM_STATUS_BAR_NOW=1000 \
    "$ROOT/bin/fm-status-bar.sh" --adapter claude | strip_ansi)
  assert_contains "$out" '⚓ Claude Fable·high' "Claude adapter did not normalize model and effort"
  assert_contains "$out" '🧠35% ⚡12%' "Claude adapter did not prefer context used over remaining"
  assert_contains "$out" "\$2.35" "Claude adapter did not normalize session cost"

  input='{"model":{"display_name":"Claude Fable"},"effort":{"level":"high"},"context_window":{"remaining_percentage":64.8}}'
  out=$(printf '%s' "$input" | \
    PATH="$FAKEBIN:$PATH" \
    FM_HOME="$HOME_FIX" \
    FM_PRIMARY_HARNESS=claude \
    FM_STATUS_BAR_NOW=1000 \
    "$ROOT/bin/fm-status-bar.sh" --adapter claude | strip_ansi)
  assert_contains "$out" '🧠36%' "Claude adapter did not derive context used from remaining when used is absent"

  input='{"model":{"display_name":"Bad\u0007Model"},"effort":{"level":"high"}}'
  out=$(printf '%s' "$input" | \
    PATH="$FAKEBIN:$PATH" \
    FM_HOME="$HOME_FIX" \
    FM_PRIMARY_HARNESS=claude \
    FM_STATUS_BAR_NOW=1000 \
    "$ROOT/bin/fm-status-bar.sh" --adapter claude)
  assert_not_contains "$out" $'\a' "Claude model label can inject terminal control bytes"
  assert_contains "$(printf '%s' "$out" | strip_ansi)" '⚓ BadModel·high' \
    "Claude model label was not sanitized without changing its printable text"

  out=$(printf '%s' "$input" | \
    PATH="$FAKEBIN:$PATH" \
    FM_HOME="$HOME_FIX" \
    FM_PRIMARY_HARNESS='' \
    FM_STATUS_BAR_NOW=1000 \
    "$ROOT/bin/fm-status-bar.sh" --adapter claude)
  [ -z "$out" ] || fail "Claude status bar rendered outside the guarded primary launcher"
  pass "status bar: Claude payload normalization is guarded to a primary launch"
}

test_follow_mode_exits_when_primary_pane_is_gone() {
  local out count_file="$TMP_ROOT/tmux-count"
  cat > "$FAKEBIN/tmux" <<'SH'
#!/usr/bin/env bash
count=0
[ ! -f "$FM_STATUS_BAR_TMUX_COUNT" ] || count=$(<"$FM_STATUS_BAR_TMUX_COUNT")
count=$((count + 1))
printf '%s\n' "$count" > "$FM_STATUS_BAR_TMUX_COUNT"
if [ "$count" -eq 1 ]; then
  printf '\n'
  exit 0
fi
exit 1
SH
  chmod +x "$FAKEBIN/tmux"
  out=$(PATH="$FAKEBIN:$PATH" \
    FM_HOME="$HOME_FIX" \
    FM_PRIMARY_HARNESS=kimi \
    FM_STATUS_BAR_INTERVAL=0 \
    FM_STATUS_BAR_TMUX_COUNT="$count_file" \
    "$ROOT/bin/fm-status-bar.sh" \
      --adapter kimi \
      --model kimi-code/k3 \
      --effort -- \
      --follow-pane %42)
  assert_not_contains "$out" '⚓' "tmux companion rendered after its primary pane disappeared"
  pass "status bar: tmux companion exits when its exact primary pane is gone"
}

test_cursor_payload_adapter_and_primary_guard() {
  local input out
  input='{"model":{"id":"cursor-grok-4.6","display_name":"Cursor Grok 4.6","param_summary":"high"},"context_window":{"used_percentage":42.7,"remaining_percentage":57.3}}'
  out=$(printf '%s' "$input" | \
    PATH="$FAKEBIN:$PATH" \
    FM_HOME="$HOME_FIX" \
    FM_PRIMARY_HARNESS=cursor \
    FM_STATUS_BAR_NOW=1000 \
    "$ROOT/bin/fm-status-bar.sh" --adapter cursor | strip_ansi)
  assert_contains "$out" '⚓ Cursor Grok 4.6·high' "Cursor adapter did not read model and reasoning summary"
  assert_contains "$out" '🧠42%' "Cursor adapter did not read context used"
  # Cursor's statusLine payload carries no quota and no cost, so both must stay
  # visibly unknown rather than being invented or silently zeroed.
  assert_contains "$out" '⚡--' "Cursor adapter fabricated a provider quota it cannot observe"
  assert_contains "$out" '$--' "Cursor adapter fabricated a session cost it cannot observe"

  out=$(printf '%s' "$input" | \
    PATH="$FAKEBIN:$PATH" \
    FM_HOME="$HOME_FIX" \
    FM_PRIMARY_HARNESS='' \
    FM_STATUS_BAR_NOW=1000 \
    "$ROOT/bin/fm-status-bar.sh" --adapter cursor)
  [ -z "$out" ] || fail "Cursor status bar rendered outside the guarded primary launcher"
  pass "status bar: Cursor payload normalization is guarded and keeps unknown metrics unknown"
}

test_account_role_label_is_verified_and_compact() {
  local out
  out=$(PATH="$FAKEBIN:$PATH" FM_HOME="$HOME_FIX" FM_PRIMARY_HARNESS=codex \
    FM_STATUS_BAR_NOW=1000 \
    "$ROOT/bin/fm-status-bar.sh" --adapter codex --model gpt-6-astra --effort high \
      --role Plus | strip_ansi)
  assert_contains "$out" '⚓ gpt-6-astra·high [Plus]' "role label is not attached to the model identity"

  out=$(PATH="$FAKEBIN:$PATH" FM_HOME="$HOME_FIX" FM_PRIMARY_HARNESS=codex \
    FM_STATUS_BAR_NOW=1000 FM_PRIMARY_ACCOUNT_ROLE=Team \
    "$ROOT/bin/fm-status-bar.sh" --adapter codex --model m --effort e | strip_ansi)
  assert_contains "$out" '[Team]' "role label is not taken from the launcher-resolved account name"

  # The native Claude, Pi and Cursor surfaces get no companion command, so the
  # label has to reach them from the account owner's own resolved global.
  out=$(PATH="$FAKEBIN:$PATH" FM_HOME="$HOME_FIX" FM_PRIMARY_HARNESS=codex \
    FM_STATUS_BAR_NOW=1000 FM_ACCOUNT_NAME=Max \
    "$ROOT/bin/fm-status-bar.sh" --adapter codex --model m --effort e | strip_ansi)
  assert_contains "$out" '[Max]' "role label is not taken from the account owner's FM_ACCOUNT_NAME"

  # An unknown ambient account must stay unknown, and an account IDENTIFIER
  # must never reach the row even when the environment supplies one.
  out=$(PATH="$FAKEBIN:$PATH" FM_HOME="$HOME_FIX" FM_PRIMARY_HARNESS=codex \
    FM_STATUS_BAR_NOW=1000 \
    "$ROOT/bin/fm-status-bar.sh" --adapter codex --model m --effort e | strip_ansi)
  assert_not_contains "$out" '[' "unknown account rendered a role label anyway"

  # Acceptance is positive - alphabetic and compact - so identifier shapes that
  # carry no punctuation at all are rejected too, and an over-long value is
  # dropped whole rather than truncated into an identifier prefix.
  for identifier in 'a@b.com' 'acct:12345' 'team/one' 'Two Words' '1048576123' \
    '550e8400-e29b-41d4-a716-446655440000' 'ABCDEFGHIJKLMNOPQRST' 'Team2'; do
    out=$(PATH="$FAKEBIN:$PATH" FM_HOME="$HOME_FIX" FM_PRIMARY_HARNESS=codex \
      FM_STATUS_BAR_NOW=1000 FM_PRIMARY_ACCOUNT_ROLE="$identifier" \
      "$ROOT/bin/fm-status-bar.sh" --adapter codex --model m --effort e | strip_ansi)
    assert_not_contains "$out" '[' "account identifier '$identifier' leaked into the status row"

    out=$(PATH="$FAKEBIN:$PATH" FM_HOME="$HOME_FIX" FM_PRIMARY_HARNESS=codex \
      FM_STATUS_BAR_NOW=1000 FM_ACCOUNT_NAME="$identifier" \
      "$ROOT/bin/fm-status-bar.sh" --adapter codex --model m --effort e | strip_ansi)
    assert_not_contains "$out" '[' "account identifier '$identifier' leaked in through FM_ACCOUNT_NAME"
  done

  out=$(PATH="$FAKEBIN:$PATH" FM_HOME="$HOME_FIX" FM_PRIMARY_HARNESS=codex \
    FM_STATUS_BAR_NOW=1000 FM_PRIMARY_ACCOUNT_ROLE=ABCDEFGHIJKL \
    "$ROOT/bin/fm-status-bar.sh" --adapter codex --model m --effort e | strip_ansi)
  assert_contains "$out" '[ABCDEFGHIJKL]' "a role word at the compact width was rejected"
  pass "status bar: account role is compact, verified, and never an identifier"
}

test_herdr_companion_exits_when_primary_pane_is_gone() {
  local out count_file="$TMP_ROOT/herdr-count"
  cat > "$FAKEBIN/herdr" <<'SH'
#!/usr/bin/env bash
count=0
[ ! -f "$FM_STATUS_BAR_HERDR_COUNT" ] || count=$(<"$FM_STATUS_BAR_HERDR_COUNT")
count=$((count + 1))
printf '%s\n' "$count" > "$FM_STATUS_BAR_HERDR_COUNT"
# The session selector must always be present, so an unscoped call can never
# resolve against another Herdr session's pane.
case " $* " in
  *" --session "*) ;;
  *) exit 1 ;;
esac
if [ "$count" -eq 1 ]; then
  printf '{"result":{"pane":{"pane_id":"w9:p9"}}}\n'
  exit 0
fi
printf '{"result":{"pane":{}}}\n'
exit 0
SH
  chmod +x "$FAKEBIN/herdr"
  out=$(PATH="$FAKEBIN:$PATH" \
    FM_HOME="$HOME_FIX" \
    FM_PRIMARY_HARNESS=codex \
    FM_STATUS_BAR_INTERVAL=0 \
    FM_STATUS_BAR_HERDR_COUNT="$count_file" \
    FM_STATUS_HERDR_SESSION=default \
    "$ROOT/bin/fm-status-bar.sh" \
      --adapter codex \
      --model gpt-6-astra \
      --effort high \
      --follow-pane w9:p9 --follow-backend herdr | strip_ansi)
  assert_contains "$out" '⚓ gpt-6-astra·high' "Herdr companion never rendered while its pane was live"
  # One render for the live read, then the pane resolves to nothing and the
  # companion must stop rather than outliving the primary it follows.
  [ "$(printf '%s' "$out" | grep -c '⚓')" -eq 1 ] \
    || fail "Herdr companion kept rendering after its exact primary pane was gone"
  rm -f "$FAKEBIN/herdr"
  pass "status bar: herdr companion is session-scoped and exits when its pane is gone"
}

test_companion_clears_the_whole_pane_once_at_startup() {
  local out count_file="$TMP_ROOT/clear-count"
  fm_install_fake_tmux_pane "$FAKEBIN" 2
  out=$(PATH="$FAKEBIN:$PATH" \
    FM_HOME="$HOME_FIX" \
    FM_PRIMARY_HARNESS=kimi \
    FM_STATUS_BAR_INTERVAL=0 \
    FM_STATUS_BAR_TMUX_COUNT="$count_file" \
    "$ROOT/bin/fm-status-bar.sh" \
      --adapter kimi --model kimi-code/k3 --effort -- --follow-pane %42)
  # Herdr clamps the split share to 0.9, so a companion is a proportional tenth
  # of the tab - two rows on a 23-row terminal, six on a 63-row one - and `pane
  # run` echoes the launch command into the pane's shell, so everything the
  # provider left below the status row is cleared whole exactly once.
  assert_contains "$out" $'\033[2J' "the companion never cleared the pane it took over"
  [ "$(printf '%s' "$out" | grep -c $'\033\\[2J')" -eq 1 ] \
    || fail "the companion repeated the full-pane clear on every refresh"
  assert_contains "$out" $'\033[H\033[2K' "the per-refresh single-row erase was dropped"
  assert_contains "$out" $'\033[?25h\033[?7h' "the companion stopped restoring terminal state on exit"
  rm -f "$FAKEBIN/tmux"
  pass "status bar: the companion clears its pane once and keeps the per-refresh erase"
}

test_companion_backend_is_restricted_to_verified_providers() {
  local out
  out=$(PATH="$FAKEBIN:$PATH" FM_HOME="$HOME_FIX" FM_PRIMARY_HARNESS=codex \
    FM_STATUS_BAR_NOW=1000 \
    "$ROOT/bin/fm-status-bar.sh" --adapter codex --model m --effort e \
      --follow-pane p1 --follow-backend zellij)
  [ -z "$out" ] || fail "companion ran on an unverified session provider"
  pass "status bar: companion refuses an unverified session provider"
}

test_tracked_adapter_wiring_and_cursor_boundary() {
  local status_command pi_extension
  status_command=$(jq -r '.statusLine.command // ""' "$ROOT/.claude/settings.json")
  assert_contains "$status_command" "\$CLAUDE_PROJECT_DIR" "Claude status command is not anchored to the tracked project"
  assert_contains "$status_command" 'bin/fm-status-bar.sh --adapter claude' "Claude status command does not use the canonical renderer"
  assert_not_contains "$status_command" "$HOME" "Claude status command writes or depends on the operator-global home"

  pi_extension=$(cat "$ROOT/.pi/extensions/fm-primary-status-bar.ts")
  assert_contains "$pi_extension" 'ctx.ui.setFooter' "Pi adapter does not use the installed custom-footer API"
  assert_contains "$pi_extension" 'truncateToWidth' "Pi adapter is not terminal-width safe"
  assert_contains "$pi_extension" 'bin/fm-status-bar.sh' "Pi adapter does not derive output from the canonical renderer"
  assert_not_contains "$pi_extension" 'setEditorComponent' "Pi adapter replaces native interaction controls"

  assert_grep 'fm-primary-status-bar.ts' "$ROOT/bin/fm-primary.sh" \
    "the guarded primary launcher does not verify the Pi status-bar integration"
  assert_grep 'split-window' "$ROOT/bin/fm-primary.sh" \
    "the guarded primary launcher does not provide the non-native tmux companion"
  assert_grep 'pane split' "$ROOT/bin/fm-primary.sh" \
    "the guarded primary launcher does not provide the non-native herdr companion"

  # Cursor's status line is a real native command API, so the installer writes
  # exactly one key and never touches credentials.
  assert_grep 'statusLine' "$ROOT/bin/fm-cursor-statusline.sh" \
    "the Cursor installer does not install the native statusLine key"
  assert_not_contains "$(cat "$ROOT/bin/fm-cursor-statusline.sh")" 'auth.json' \
    "the Cursor installer touches credential storage"
  assert_grep 'fm-cursor-statusline.sh' "$ROOT/docs/status-bar.md" \
    "the status-bar owner does not document the Cursor activation route"
  pass "status bar: tracked adapters preserve guarded installation across native and companion surfaces"
}

# --- Codex/Astra session metric supply -------------------------------------
#
# These cases drive bin/fm-codex-session-metrics-lib.sh directly with fixture
# rollouts and fixture provider reports. Nothing here spawns a renderer, points
# at a live pane, or signals a process: the library's pane resolution is
# replaced by its documented rollout seam, so the suite can never reach the
# captain's own primary or its companion.

CODEX_FIX="$TMP_ROOT/codex"
mkdir -p "$CODEX_FIX"

# codex_token_event <input-tokens> <context-window> <limit-id> <limit-name>
#   <primary-used> <primary-minutes> <primary-resets>
# One rollout token-count line. "-" omits the rate-limit window entirely.
codex_token_event() {
  local tok=$1 win=$2 lid=$3 lname=$4 pu=$5 pm=$6 pr=$7 primary
  primary=null
  [ "$pu" = - ] || primary="{\"used_percent\":$pu,\"window_minutes\":$pm,\"resets_at\":$pr}"
  printf '{"type":"event_msg","payload":{"type":"token_count","info":{"last_token_usage":{"input_tokens":%s},"model_context_window":%s},"rate_limits":{"limit_id":"%s","limit_name":"%s","primary":%s,"secondary":null}}}\n' \
    "$tok" "$win" "$lid" "$lname" "$primary"
}

# codex_metrics <rollout-file> <model> [quota-json]
# The reading as "context|quota|window", with caching off so each case is read
# fresh and no case can observe another's cached answer.
codex_metrics() {
  local rollout=$1 model=$2 quota=${3:-} state="$CODEX_FIX/state"
  mkdir -p "$state"
  (
    # shellcheck source=bin/fm-codex-session-metrics-lib.sh
    . "$ROOT/bin/fm-codex-session-metrics-lib.sh"
    if [ -n "$quota" ]; then
      export FM_CODEX_QUOTA_JSON="$quota"
    else
      export FM_CODEX_QUOTA_DISABLE=1
    fi
    FM_CODEX_METRICS_NO_CACHE=1 \
      FM_CODEX_METRICS_NOW=1000 \
      FM_CODEX_METRICS_ROLLOUT="$rollout" \
      fm_codex_session_metrics fixture-pane herdr default "$state" "$model"
  ) | tr '\t' '|'
}

# codex_quota_report <scope-status> <remaining> <limiting-window-ids-json>
#   [stale] [semantics-status]
codex_quota_report() {
  local sstatus=$1 remaining=$2 windows=$3 stale=${4:-false} qs=${5:-known}
  printf '{"providers":[{"provider":"codex","state":{"stale":%s},"quotaSemantics":{"status":"%s","effectiveAvailability":[{"scope":"all_models","status":"%s","effectivePercentRemaining":%s,"limitingWindowIds":%s}]}}]}' \
    "$stale" "$qs" "$sstatus" "$remaining" "$windows"
}

# The measured misattribution this whole filter exists for. A gpt-6-astra
# primary's rollout carried limit_id=codex_bengalfox (GPT-5.3-Codex-Spark) at
# 0% used, while the account's real binding weekly window sat at 54% used.
# Reporting that 0% would tell the captain there is full headroom when there is
# not, so the mismatched block must be discarded and the account owner asked.
test_codex_rejects_another_models_rate_limit_identity() {
  local rollout="$CODEX_FIX/misattributed.jsonl" quota="$CODEX_FIX/weekly.json" out
  codex_token_event 129200 258400 codex_bengalfox GPT-5.3-Codex-Spark 0 300 99999 > "$rollout"
  codex_quota_report known 46 '["weekly"]' > "$quota"

  out=$(codex_metrics "$rollout" gpt-6-astra "$quota")
  assert_contains "$out" '|54|wk' \
    "a mismatched limit identity was not replaced by the account's binding window"
  assert_not_contains "$out" '|0|' \
    "another model's 0% allowance was reported as this primary's quota"

  # With no account owner to fall back to, the mismatch must read unavailable
  # rather than borrowing the foreign figure anyway.
  out=$(codex_metrics "$rollout" gpt-6-astra)
  assert_contains "$out" '|--|' \
    "a mismatched limit identity fell through to the foreign rate-limit block"
  pass "status bar: a rate-limit identity from another model is never reported as this primary's quota"
}

# The positive half of the same rule: an identity that provably belongs to the
# running model is the better source, because it is the window that model
# actually consumes.
test_codex_accepts_a_matching_rate_limit_identity() {
  local rollout="$CODEX_FIX/matched.jsonl" out
  codex_token_event 129200 258400 'model:gpt_6_astra:5h' GPT-6-Astra 37 300 99999 > "$rollout"
  out=$(codex_metrics "$rollout" gpt-6-astra)
  assert_contains "$out" '|37|5h' "a matching limit identity was discarded instead of used"

  # An empty identity proves nothing and is therefore not a match.
  codex_token_event 129200 258400 '' '' 37 300 99999 > "$rollout"
  out=$(codex_metrics "$rollout" gpt-6-astra)
  assert_contains "$out" '|--|' "an unstamped rate-limit block was trusted"
  pass "status bar: a rate-limit identity is used only when it provably matches the running model"
}

# Context is read from the newest token event, so a compacted thread reports its
# smaller post-compaction prompt rather than its pre-compaction peak. The
# context window comes from the session's own report, so no capacity is assumed.
test_codex_context_follows_the_current_session_and_compaction() {
  local rollout="$CODEX_FIX/compaction.jsonl" out
  codex_token_event 232560 258400 codex_bengalfox Spark - - - > "$rollout"
  out=$(codex_metrics "$rollout" gpt-6-astra)
  assert_contains "$out" '90|' "context did not track the session's own prompt size"

  # A later, smaller event is the current truth after compaction.
  codex_token_event 51680 258400 codex_bengalfox Spark - - - >> "$rollout"
  out=$(codex_metrics "$rollout" gpt-6-astra)
  assert_contains "$out" '20|' "context kept a pre-compaction figure after compaction"
  pass "status bar: Codex context tracks the current session across compaction"
}

# Unavailable must never be rendered as zero, on any of the ways a reading can
# fail. Each case here would be a silently wrong "0%" if the guards were missing.
test_codex_unavailable_readings_never_become_zero() {
  local rollout="$CODEX_FIX/broken.jsonl" quota="$CODEX_FIX/broken.json" out

  # Malformed: not JSON at all, but carrying the token_count marker.
  printf '%s\n' '{"type":"event_msg","payload":{"type":"token_count"' > "$rollout"
  out=$(codex_metrics "$rollout" gpt-6-astra)
  [ "$out" = '--|--|' ] || fail "a malformed token event produced '$out' instead of unavailable"

  # Absent: no token event in the rollout at all.
  printf '%s\n' '{"type":"response_item","payload":{"type":"message"}}' > "$rollout"
  out=$(codex_metrics "$rollout" gpt-6-astra)
  [ "$out" = '--|--|' ] || fail "a rollout with no token event produced '$out'"

  # Absent context window: a percentage of an unknown window is meaningless.
  printf '%s\n' '{"type":"event_msg","payload":{"type":"token_count","info":{"last_token_usage":{"input_tokens":1000}}}}' > "$rollout"
  out=$(codex_metrics "$rollout" gpt-6-astra)
  assert_contains "$out" '--|' "an unknown context window was still turned into a percentage"

  # Expired: a window whose reset time has already passed describes a spent
  # allowance, so its used share is no longer true of the current window.
  codex_token_event 51680 258400 'model:gpt_6_astra:5h' GPT-6-Astra 80 300 999 > "$rollout"
  out=$(codex_metrics "$rollout" gpt-6-astra)
  assert_contains "$out" '|--|' "an expired rate-limit window was reported as current"

  # A stale provider report is refused rather than shown.
  codex_quota_report known 46 '["weekly"]' true > "$quota"
  out=$(codex_metrics "$rollout" gpt-6-astra "$quota")
  assert_contains "$out" '|--|' "a stale provider report was reported as current quota"

  # So is an unknown one, at either level.
  codex_quota_report unknown null '["weekly"]' false known > "$quota"
  out=$(codex_metrics "$rollout" gpt-6-astra "$quota")
  assert_contains "$out" '|--|' "an unknown scope status was reported as quota"
  codex_quota_report known 46 '["weekly"]' false unknown > "$quota"
  out=$(codex_metrics "$rollout" gpt-6-astra "$quota")
  assert_contains "$out" '|--|' "an unknown semantics status was reported as quota"

  # A real zero is still a real reading and must survive all of the above.
  codex_quota_report known 100 '["weekly"]' > "$quota"
  out=$(codex_metrics "$rollout" gpt-6-astra "$quota")
  assert_contains "$out" '|0|wk' "a genuine 0% quota was suppressed as unavailable"
  pass "status bar: missing, malformed, expired, and stale Codex readings stay unavailable rather than zero"
}

# A percentage means something different against five hours than against a week,
# so the window is part of the metric. A plan exposing only a weekly limit still
# reports a labelled figure; a figure bound by two windows at once cannot be
# labelled with either and is withheld.
test_codex_quota_window_is_always_named() {
  local rollout="$CODEX_FIX/window.jsonl" quota="$CODEX_FIX/window.json" out
  codex_token_event 51680 258400 codex_bengalfox Spark - - - > "$rollout"

  codex_quota_report known 46 '["weekly"]' > "$quota"
  out=$(codex_metrics "$rollout" gpt-6-astra "$quota")
  assert_contains "$out" '|54|wk' "a weekly-only provider limit was not reported"

  codex_quota_report known 70 '["model:codex_bengalfox:5h"]' > "$quota"
  out=$(codex_metrics "$rollout" gpt-6-astra "$quota")
  assert_contains "$out" '|30|5h' "a five-hour window was not labelled as one"

  codex_quota_report known 46 '["weekly","daily"]' > "$quota"
  out=$(codex_metrics "$rollout" gpt-6-astra "$quota")
  assert_contains "$out" '|--|' "a figure bound by two windows at once was labelled with one of them"

  codex_quota_report known 46 '["something-new"]' > "$quota"
  out=$(codex_metrics "$rollout" gpt-6-astra "$quota")
  assert_contains "$out" '|--|' "an unrecognized window was reported without a usable label"
  pass "status bar: a Codex quota figure is reported only with its actual window named"
}

# The session binding is an open file descriptor, not a newest-file guess. When
# the followed pane resolves to no Codex process, or to processes holding more
# than one rollout, there is no safe choice and the row must say so rather than
# borrow a sibling session's context.
test_codex_never_borrows_a_sibling_session() {
  local state="$CODEX_FIX/sibling-state" out lsof_bin="$CODEX_FIX/lsofbin"
  mkdir -p "$state" "$lsof_bin"

  # No Codex process behind the pane: nothing to bind to.
  out=$(
    # shellcheck source=bin/fm-codex-session-metrics-lib.sh
    . "$ROOT/bin/fm-codex-session-metrics-lib.sh"
    FM_CODEX_METRICS_NO_CACHE=1 FM_CODEX_METRICS_NOW=1000 \
      FM_CODEX_QUOTA_DISABLE=1 PATH="$lsof_bin:$PATH" \
      fm_codex_session_metrics fixture-pane herdr default "$state" gpt-6-astra
  )
  [ "$out" = "$(printf '%s\t%s\t' -- --)" ] \
    || fail "an unresolvable pane produced a reading anyway: '$out'"

  # Two rollouts held open at once is ambiguous, so it is refused outright
  # rather than resolved by picking one.
  cat > "$lsof_bin/lsof" <<'SH'
#!/usr/bin/env bash
printf 'n/tmp/sessions/2026/09/09/rollout-a.jsonl\n'
printf 'n/tmp/sessions/2026/09/10/rollout-b.jsonl\n'
SH
  chmod +x "$lsof_bin/lsof"
  out=$(
    # shellcheck source=bin/fm-codex-session-metrics-lib.sh
    . "$ROOT/bin/fm-codex-session-metrics-lib.sh"
    PATH="$lsof_bin:$PATH" _fm_codex_rollout_for_pids 4242 && printf 'RESOLVED'
  )
  [ -z "$out" ] || fail "two open rollouts resolved to '$out' instead of refusing"

  # Exactly one is the only resolvable case.
  cat > "$lsof_bin/lsof" <<'SH'
#!/usr/bin/env bash
printf 'n/tmp/sessions/2026/09/09/rollout-a.jsonl\n'
SH
  chmod +x "$lsof_bin/lsof"
  out=$(
    # shellcheck source=bin/fm-codex-session-metrics-lib.sh
    . "$ROOT/bin/fm-codex-session-metrics-lib.sh"
    PATH="$lsof_bin:$PATH" _fm_codex_rollout_for_pids 4242
  )
  [ "$out" = /tmp/sessions/2026/09/09/rollout-a.jsonl ] \
    || fail "a single open rollout did not resolve, got '$out'"
  pass "status bar: Codex context binds to one open session and never borrows a sibling"
}

# The window token has to reach the rendered row, and it must not leak into the
# adapters whose payloads carry no window - Claude, Pi and Cursor keep the bare
# percentage their contracts already specify.
test_quota_window_renders_only_where_a_window_is_known() {
  local out
  out=$(render Opus high 40 55 | strip_ansi)
  assert_contains "$out" '⚡55%' "the Pi row lost its quota percentage"
  assert_not_contains "$out" '⚡55%wk' "a window label was invented for an adapter with no window"

  out=$(printf '%s' '{"model":{"display_name":"Claude"},"context_window":{"used_percentage":10},"rate_limits":{"five_hour":{"used_percentage":22}}}' |
    PATH="$FAKEBIN:$PATH" FM_HOME="$HOME_FIX" FM_PRIMARY_HARNESS=claude \
      FM_STATUS_BAR_NOW=1000 "$ROOT/bin/fm-status-bar.sh" --adapter claude | strip_ansi)
  assert_contains "$out" '⚡22%' "the Claude quota field changed shape"
  assert_not_contains "$out" '⚡22%5h' "a window label was appended to the Claude contract"
  pass "status bar: the quota window is rendered only by adapters that actually know one"
}

test_contract_order_and_fleet_projection
test_threshold_colors_and_placeholders
test_no_watch_is_bright_red_when_missing_or_stale
test_claude_payload_adapter_and_primary_guard
test_follow_mode_exits_when_primary_pane_is_gone
test_cursor_payload_adapter_and_primary_guard
test_account_role_label_is_verified_and_compact
test_herdr_companion_exits_when_primary_pane_is_gone
test_companion_clears_the_whole_pane_once_at_startup
test_companion_never_leaves_the_row_blank_while_collecting
test_companion_publishes_every_refresh_to_the_pane
test_companion_backend_is_restricted_to_verified_providers
test_tracked_adapter_wiring_and_cursor_boundary
test_codex_rejects_another_models_rate_limit_identity
test_codex_accepts_a_matching_rate_limit_identity
test_codex_context_follows_the_current_session_and_compaction
test_codex_unavailable_readings_never_become_zero
test_codex_quota_window_is_always_named
test_codex_never_borrows_a_sibling_session
test_quota_window_renders_only_where_a_window_is_known
