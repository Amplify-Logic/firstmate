#!/usr/bin/env bash
# Behavior tests for bin/fm-screen-steps.sh: the on-screen steps card over a
# page the captain fills in, its Arc opening, and its Done and Stuck replies.
set -u

# shellcheck source=tests/lib.sh
# shellcheck disable=SC1091
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

STEPS="$ROOT/bin/fm-screen-steps.sh"
TMP_ROOT=$(fm_test_tmproot fm-screen-steps)
unset FM_STATE_OVERRIDE || true
export FM_SCREEN_STEPS_ARC_TIMEOUT=5

# A copy of the script in its own code root, with stand-ins for swift, open,
# osascript and bin/fm-desk-voice.sh, so no case reaches the real browser,
# screen or Firstmate chat. Each stand-in logs its arguments. The fake card
# app sleeps under its bundle path, so the script sees it running; open
# records its pid where the real card would. Arc counts as installed unless
# arc.absent exists; arc.refuse makes Arc refuse its Automation permission,
# and arc.unready makes that many first calls fail as a just-started Arc does
# before its window exists.
new_root() {  # <name>
  local fx="$TMP_ROOT/$1"
  mkdir -p "$fx/root/bin" "$fx/root/screen-steps/Sources" "$fx/fake" "$fx/home/state"
  fx=$(cd "$fx" && pwd -P)
  cp "$STEPS" "$fx/root/bin/fm-screen-steps.sh"
  : > "$fx/root/screen-steps/Package.swift"
  : > "$fx/root/screen-steps/Sources/ScreenSteps.swift"
  cat > "$fx/root/bin/fm-desk-voice.sh" <<EOF
#!/usr/bin/env bash
printf '%s\n' "FM_HOME=\$FM_HOME" "\$@" > "$fx/desk-voice.log"
printf 'sent: herdr 1-1\n'
EOF
  cat > "$fx/fake/swift" <<EOF
#!/usr/bin/env bash
printf 'build\n' >> "$fx/swift.log"
mkdir -p .build/release
printf '#!/bin/sh\nsleep 15\n' > .build/release/ScreenSteps
chmod +x .build/release/ScreenSteps
EOF
  cat > "$fx/fake/open" <<EOF
#!/usr/bin/env bash
printf '%s\n' "\$*" >> "$fx/open.log"
dir=""
for arg in "\$@"; do
  case "\$arg" in FM_SCREEN_STEPS_DIR=*) dir=\${arg#FM_SCREEN_STEPS_DIR=} ;; esac
done
last=\${*: -1}
case "\$last" in
  *ScreenSteps.app)
    "\$last/Contents/MacOS/ScreenSteps" >/dev/null 2>&1 &
    printf '%s\n' "\$!" > "\$dir/card.pid"
    printf '%s\n' "\$!" >> "$fx/card-pids"
    ;;
esac
EOF
  cat > "$fx/fake/osascript" <<EOF
#!/usr/bin/env bash
printf '%s\n' "\$*" >> "$fx/osascript.log"
case "\$*" in
  *URLForApplicationWithBundleIdentifier*)
    [ -e "$fx/arc.absent" ] && echo no || echo yes ;;
  *)
    [ ! -e "$fx/arc.refuse" ] || { echo 'Not authorized to send Apple events to Arc. (-1743)' >&2; exit 1; }
    left=\$(cat "$fx/arc.unready" 2>/dev/null || echo 0)
    if [ "\$left" -gt 0 ]; then
      echo \$((left - 1)) > "$fx/arc.unready"
      echo "Arc got an error: Can't get window 1. Invalid index. (-1719)" >&2
      exit 1
    fi ;;
esac
EOF
  chmod +x "$fx/fake/"* "$fx/root/bin/"*
  touch "$fx/swift.log" "$fx/open.log" "$fx/osascript.log"
  printf '%s\n' "$fx"
}

run_steps() {  # <fixture> [args...]
  local fx=$1
  shift
  PATH="$fx/fake:$PATH" FM_HOME="$fx/home" "$fx/root/bin/fm-screen-steps.sh" "$@"
}

stop_cards() {  # <fixture>
  local pid
  [ -f "$1/card-pids" ] || return 0
  while IFS= read -r pid; do
    kill "$pid" 2>/dev/null || true
  done < "$1/card-pids"
}

card_field() {  # <fixture> <python expression over card>
  python3 -c 'import json,sys; card=json.load(open(sys.argv[1])); print(eval(sys.argv[2]))' \
    "$1/home/state/screen-steps/card.json" "$2"
}

write_steps() {  # <file>
  cat > "$1" <<'EOF'
# Create the app
Open My Apps first.

1. Click + and choose New App.
2. Platform: tick `iOS`.
3) Name: `Happiness Compass` and SKU `compass-1`
   Keep the capital letters, **exactly**.
- Bundle ID: `com.example.compass`, again `iOS`
EOF
}

test_show_builds_the_card_and_opens_the_page_in_arc() {
  local fx out
  fx=$(new_root show)
  write_steps "$fx/steps.md"
  out=$(run_steps "$fx" show --url https://appstoreconnect.apple.com/apps --steps-file "$fx/steps.md" 2>"$fx/err") \
    || fail "show failed: $out $(cat "$fx/err")"
  assert_contains "$out" "opened: arc https://appstoreconnect.apple.com/apps" "the page opens in Arc"
  assert_contains "$out" "card: $fx/home/state/screen-steps/card.json" "show names the card it wrote"
  assert_equals "Create the app" "$(card_field "$fx" 'card["title"]')" "the first heading is the title"
  assert_equals "Open My Apps first." "$(card_field "$fx" 'card["note"]')" "lines before the first step are the note"
  assert_equals 4 "$(card_field "$fx" 'len(card["steps"])')" "numbered and bulleted lines are steps"
  assert_equals "[]" "$(card_field "$fx" 'card["steps"][0]["values"]')" "a step without code has nothing to copy"
  assert_equals "['Happiness Compass', 'compass-1']" "$(card_field "$fx" 'card["steps"][2]["values"]')" "every code span is a value to copy"
  assert_equals "Name: \`Happiness Compass\` and SKU \`compass-1\`|Keep the capital letters, **exactly**." \
    "$(card_field "$fx" '"|".join(card["steps"][2]["text"].splitlines())')" "an indented line joins its step"
  assert_equals "['com.example.compass', 'iOS']" "$(card_field "$fx" 'card["steps"][3]["values"]')" "values are kept per step"
  assert_equals 600 "$(stat -f %Lp "$fx/home/state/screen-steps/card.json" 2>/dev/null || stat -c %a "$fx/home/state/screen-steps/card.json")" "the card file is private"
  assert_equals 1 "$(grep -c build "$fx/swift.log")" "the card app is built on first use"
  assert_grep "make new tab with properties {URL:item 1 of argv}" "$fx/osascript.log" "Arc opens the page as a tab of its main window"
  assert_grep "https://appstoreconnect.apple.com/apps" "$fx/osascript.log" "the URL is handed to Arc as an argument"
  assert_no_grep "appstoreconnect" "$fx/open.log" "the page is never opened with plain open, which Arc shows as a Little Arc popup"
  assert_grep "-n -g --env FM_HOME=$fx/home --env FM_SCREEN_STEPS_ROOT=$fx/root --env FM_SCREEN_STEPS_DIR=$fx/home/state/screen-steps $fx/root/screen-steps/.build/ScreenSteps.app" \
    "$fx/open.log" "the card starts in the background for this home, so the page keeps the keyboard"
  stop_cards "$fx"
  pass "fm-screen-steps: show writes the card from the Markdown steps and opens the page in Arc's main window"
}

test_second_show_replaces_the_running_card() {
  local fx out first
  fx=$(new_root replace)
  write_steps "$fx/steps.md"
  run_steps "$fx" show --steps-file "$fx/steps.md" >/dev/null 2>&1 || fail "first show failed"
  first=$(card_field "$fx" 'card["revision"]')
  printf '# Second\n1. Only step\n' > "$fx/steps2.md"
  out=$(run_steps "$fx" show --steps-file "$fx/steps2.md" 2>&1) || fail "second show failed: $out"
  assert_equals "Second" "$(card_field "$fx" 'card["title"]')" "the second show replaces the steps"
  assert_not_equals "$first" "$(card_field "$fx" 'card["revision"]')" "a replaced card gets a new revision, so its ticks reset"
  assert_equals 1 "$(grep -c ScreenSteps.app "$fx/open.log")" "the running card is reused, not started twice"
  assert_equals 1 "$(grep -c build "$fx/swift.log")" "an unchanged card app is not rebuilt"
  assert_equals 0 "$(grep -c . "$fx/osascript.log")" "without --url nothing is opened"
  run_steps "$fx" hide || fail "hide failed"
  assert_absent "$fx/home/state/screen-steps/card.json" "hide removes the card file the card closes on"
  stop_cards "$fx"
  pass "fm-screen-steps: a second show replaces the running card's steps and hide closes it"
}

test_show_falls_back_without_arc() {
  local fx out
  fx=$(new_root no-arc)
  write_steps "$fx/steps.md"
  touch "$fx/arc.absent"
  out=$(run_steps "$fx" show --url https://example.com/form --steps-file "$fx/steps.md" 2>"$fx/err") \
    || fail "show without Arc failed: $out"
  assert_contains "$out" "opened: default-browser https://example.com/form" "without Arc the default browser opens the page"
  assert_grep "Arc is not installed" "$fx/err" "the fallback says why"
  assert_grep "https://example.com/form" "$fx/open.log" "the page opens with the default browser"
  stop_cards "$fx"

  fx=$(new_root arc-refuses)
  write_steps "$fx/steps.md"
  touch "$fx/arc.refuse"
  out=$(run_steps "$fx" show --url https://example.com/form --steps-file "$fx/steps.md" 2>"$fx/err") \
    || fail "show with Arc refusing failed: $out"
  assert_contains "$out" "opened: default-browser https://example.com/form" "a refused Arc falls back to the default browser"
  assert_grep "no Automation permission for Arc" "$fx/err" "the refusal is named"
  assert_equals 1 "$(grep -c 'make new tab' "$fx/osascript.log")" "a refused permission is not retried"
  stop_cards "$fx"

  pass "fm-screen-steps: without Arc, or when Arc refuses, show still opens the page and the card"
}

# The captain's own Arc window keeps its place and size: show only adds a tab
# and brings the window forward, including while a just-started Arc has no
# window yet. Every call the script makes to osascript is checked for a
# window-geometry command.
test_show_never_moves_or_resizes_an_arc_window() {
  local fx out
  fx=$(new_root geometry)
  write_steps "$fx/steps.md"
  echo 2 > "$fx/arc.unready"
  out=$(run_steps "$fx" show --url https://example.com/form --steps-file "$fx/steps.md" 2>&1) \
    || fail "show with a just-started Arc failed: $out"
  assert_contains "$out" "opened: arc https://example.com/form" "the page opens once Arc's window exists"
  assert_equals 3 "$(grep -c 'make new tab' "$fx/osascript.log")" "a just-started Arc is asked again until its window exists"
  run_steps "$fx" show --url https://example.com/next --steps-file "$fx/steps.md" >/dev/null 2>&1 \
    || fail "a second show with a URL failed"
  assert_no_grep "System Events" "$fx/osascript.log" "no other app is asked to touch Arc's windows"
  for word in position size bounds zoomed "full screen" AXFullScreen; do
    assert_no_grep "$word" "$fx/osascript.log" "show never sends Arc a window $word change"
  done
  stop_cards "$fx"
  pass "fm-screen-steps: show never moves or resizes the captain's Arc window"
}

test_show_refuses_bad_input() {
  local fx rc
  fx=$(new_root refuse)
  write_steps "$fx/steps.md"
  rc=0
  run_steps "$fx" show --url "file:///etc/passwd" --steps-file "$fx/steps.md" >/dev/null 2>&1 || rc=$?
  expect_code 2 "$rc" "a non-web URL"
  printf '# Only a title\nand a note\n' > "$fx/empty.md"
  rc=0
  run_steps "$fx" show --steps-file "$fx/empty.md" >/dev/null 2>"$fx/err" || rc=$?
  expect_code 2 "$rc" "a steps file with no step"
  assert_grep "no steps in" "$fx/err" "the empty file is named"
  rc=0
  run_steps "$fx" show --steps-file "$fx/missing.md" >/dev/null 2>&1 || rc=$?
  expect_code 2 "$rc" "a missing steps file"
  rc=0
  run_steps "$fx" show >/dev/null 2>&1 || rc=$?
  expect_code 2 "$rc" "show without steps"
  assert_absent "$fx/home/state/screen-steps/card.json" "nothing is shown after a refusal"
  assert_equals 0 "$(grep -c . "$fx/open.log")" "nothing is opened after a refusal"
  pass "fm-screen-steps: show refuses non-web URLs and files without steps, opening nothing"
}

test_reply_sends_through_the_desk_voice_path() {
  local fx out rc
  fx=$(new_root reply)
  write_steps "$fx/steps.md"
  rc=0
  run_steps "$fx" reply "done" >/dev/null 2>&1 || rc=$?
  expect_code 1 "$rc" "a reply with no card showing"
  run_steps "$fx" show --steps-file "$fx/steps.md" >/dev/null 2>&1 || fail "show failed"

  out=$(run_steps "$fx" reply "done" 2>&1) || fail "reply done failed: $out"
  assert_equals "sent: herdr 1-1" "$out" "reply prints the delivery outcome"
  assert_equals "FM_HOME=$fx/home|send|--source|screen-steps|--|Done with the on-screen steps: Create the app" \
    "$(paste -sd '|' "$fx/desk-voice.log")" "Done goes into the primary chat through the desk-voice send path"

  run_steps "$fx" reply stuck >/dev/null 2>&1 || fail "reply stuck failed"
  assert_equals "Stuck on the on-screen steps: Create the app" "$(tail -n 1 "$fx/desk-voice.log")" "Stuck with nothing ticked names the card"

  run_steps "$fx" reply stuck --step 3 >/dev/null 2>&1 || fail "reply stuck --step failed"
  assert_equals "Stuck at step 3 of the on-screen steps: Create the app (Name: Happiness Compass and SKU compass-1 Keep the capital letters, exactly.)" \
    "$(tail -n 1 "$fx/desk-voice.log")" "Stuck names the step on one line"

  rc=0
  run_steps "$fx" reply stuck --step x >/dev/null 2>&1 || rc=$?
  expect_code 2 "$rc" "a step that is not a number"
  rc=0
  run_steps "$fx" reply maybe >/dev/null 2>&1 || rc=$?
  expect_code 2 "$rc" "an unknown reply"
  stop_cards "$fx"
  pass "fm-screen-steps: Done and Stuck send one line into the Firstmate chat through bin/fm-desk-voice.sh send"
}

# The card itself is a Swift package, so compiling it needs macOS and swift.
test_card_app_compiles() {
  local out
  if [ "$(uname)" != Darwin ] || ! command -v swift >/dev/null 2>&1; then
    pass "fm-screen-steps: card build skipped (needs macOS and swift)"
    return
  fi
  out=$(swift build -c release --product ScreenSteps --package-path "$ROOT/screen-steps" \
    --scratch-path "$TMP_ROOT/swift-build" 2>&1) || fail "the card app does not build: $out"
  pass "fm-screen-steps: the card app builds"
}

test_show_builds_the_card_and_opens_the_page_in_arc
test_second_show_replaces_the_running_card
test_show_falls_back_without_arc
test_show_never_moves_or_resizes_an_arc_window
test_show_refuses_bad_input
test_reply_sends_through_the_desk_voice_path
test_card_app_compiles
