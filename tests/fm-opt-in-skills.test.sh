#!/usr/bin/env bash
# tests/fm-opt-in-skills.test.sh - bin/fm-opt-in-skills.sh: a home's presence
# flags decide which opt-in skills are linked into a checkout's skill folder,
# the links never make the checkout read as changed, and nothing the script did
# not create is ever touched.
#
# Every case runs against a throwaway git checkout holding a copy of this
# repository's real .gitignore and .agents/opt-in-skills/, with a private
# config/ directory, so no case reads or writes this home.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

SKILLS="$ROOT/bin/fm-opt-in-skills.sh"
TMP_ROOT=$(fm_test_tmproot fm-opt-in-skills)
fm_git_identity fmtest fmtest@example.invalid

# make_checkout <name>: a committed checkout shaped like this repository's skill
# folders, plus an empty config/ for the home that owns it.
make_checkout() {
  local dir="$TMP_ROOT/$1"
  mkdir -p "$dir/checkout/.agents/skills/always-on" "$dir/config"
  git init -q "$dir/checkout"
  cp "$ROOT/.gitignore" "$dir/checkout/.gitignore"
  cp -R "$ROOT/.agents/opt-in-skills" "$dir/checkout/.agents/opt-in-skills"
  printf -- '---\nname: always-on\n---\n' > "$dir/checkout/.agents/skills/always-on/SKILL.md"
  git -C "$dir/checkout" add -A
  git -C "$dir/checkout" commit -q -m init
  printf '%s\n' "$dir"
}

run_sync() {  # <dir>
  FM_HOME="$1" FM_CONFIG_OVERRIDE="$1/config" "$SKILLS" sync "$1/checkout"
}

linked() {  # <dir> -> sorted names of the links in .agents/skills
  local entry
  for entry in "$1"/checkout/.agents/skills/*; do
    [ -L "$entry" ] && printf '%s\n' "${entry##*/}"
  done | sort | tr '\n' ' ' | sed 's/ $//'
}

test_no_switch_links_nothing() {
  local dir out
  dir=$(make_checkout none)
  out=$(run_sync "$dir" 2>&1)
  assert_equals "" "$out" "sync with no switch must print nothing"
  assert_equals "" "$(linked "$dir")" "no switch must link no skill"
  assert_equals "" "$(git -C "$dir/checkout" status --porcelain)" "the checkout must stay clean"
  pass "a home with no switch gets no opt-in skill"
}

test_switch_links_its_skills_and_checkout_stays_clean() {
  local dir out
  dir=$(make_checkout adhd)
  : > "$dir/config/adhd"
  out=$(run_sync "$dir" 2>&1)
  assert_equals "" "$out" "sync must print nothing when it only links"
  assert_equals "adhd adhd-auto-fire" "$(linked "$dir")" "config/adhd must link both ADHD skills and nothing else"
  assert_equals "../opt-in-skills/adhd" "$(readlink "$dir/checkout/.agents/skills/adhd")" "the link must be relative"
  [ -f "$dir/checkout/.agents/skills/adhd-auto-fire/SKILL.md" ] \
    || fail "the linked skill must be readable at its usual path"
  assert_equals "" "$(git -C "$dir/checkout" status --porcelain)" "a linked skill must not make the checkout read as changed"
  out=$(run_sync "$dir" 2>&1)
  assert_equals "adhd adhd-auto-fire" "$(linked "$dir")" "a second sync must keep the same links"
  assert_equals "" "$out" "a second sync must print nothing"
  pass "a switch links its skills where the harness looks, and the checkout stays clean"
}

test_every_switch_on_keeps_checkout_clean() {
  local dir flag
  dir=$(make_checkout all)
  for flag in adhd second-opinion daily-todo computer-use; do : > "$dir/config/$flag"; done
  run_sync "$dir"
  assert_equals "adhd adhd-auto-fire daily-todo-freshness macos-computer-use second-opinion-auto-fire" \
    "$(linked "$dir")" "every switch must link every opt-in skill"
  assert_equals "" "$(git -C "$dir/checkout" status --porcelain)" \
    "the tracked .gitignore must cover every link the script makes"
  pass "with every switch on, every skill is linked and the tracked .gitignore covers each link"
}

test_switch_off_removes_only_its_links() {
  local dir
  dir=$(make_checkout off)
  : > "$dir/config/adhd"
  : > "$dir/config/computer-use"
  run_sync "$dir"
  rm -f "$dir/config/adhd"
  run_sync "$dir"
  assert_equals "macos-computer-use" "$(linked "$dir")" "turning config/adhd off must remove only the ADHD links"
  [ -f "$dir/checkout/.agents/skills/always-on/SKILL.md" ] || fail "a tracked skill must never be touched"
  pass "turning a switch off removes only that switch's links"
}

test_intake_configs_switch_on_the_todo_skill() {
  local dir
  dir=$(make_checkout intake)
  : > "$dir/config/channel-intake"
  run_sync "$dir"
  assert_equals "daily-todo-freshness" "$(linked "$dir")" "config/channel-intake must link the to-do freshness skill"
  rm -f "$dir/config/channel-intake"
  : > "$dir/config/morning-intake"
  run_sync "$dir"
  assert_equals "daily-todo-freshness" "$(linked "$dir")" "config/morning-intake must keep the to-do freshness skill"
  pass "morning or channel intake switches on the to-do freshness skill they rely on"
}

test_foreign_path_is_left_alone() {
  local dir out code
  dir=$(make_checkout foreign)
  : > "$dir/config/second-opinion"
  : > "$dir/config/computer-use"
  mkdir -p "$dir/checkout/.agents/skills/second-opinion-auto-fire"
  printf 'mine\n' > "$dir/checkout/.agents/skills/second-opinion-auto-fire/notes"
  ln -s /tmp "$dir/checkout/.agents/skills/macos-computer-use"
  out=$(run_sync "$dir" 2>&1)
  code=$?
  expect_code 0 "$code" "sync must not fail over a path it leaves alone"
  assert_contains "$out" "second-opinion-auto-fire is not this script's link; left as it is" "a real folder must be reported"
  assert_contains "$out" "macos-computer-use is not this script's link; left as it is" "a foreign link must be reported"
  assert_equals "mine" "$(cat "$dir/checkout/.agents/skills/second-opinion-auto-fire/notes")" "a real folder must be kept"
  assert_equals "/tmp" "$(readlink "$dir/checkout/.agents/skills/macos-computer-use")" "a foreign link must be kept"
  rm -f "$dir/config/computer-use"
  run_sync "$dir" 2>/dev/null
  assert_equals "/tmp" "$(readlink "$dir/checkout/.agents/skills/macos-computer-use")" \
    "a switched-off skill must not remove a link it does not own"
  pass "a path the script did not create is never replaced or removed"
}

test_checkout_without_opt_in_folder_is_untouched() {
  local dir
  dir="$TMP_ROOT/other-project"
  mkdir -p "$dir/checkout/.agents/skills" "$dir/config"
  : > "$dir/config/adhd"
  run_sync "$dir"
  assert_equals "" "$(linked "$dir")" "a checkout without .agents/opt-in-skills must get no link"
  pass "a checkout with no opt-in skill folder is left alone"
}

test_list_names_every_opt_in_skill() {
  local dir out shipped listed entry
  dir=$(make_checkout list)
  : > "$dir/config/computer-use"
  out=$(FM_HOME="$dir" FM_CONFIG_OVERRIDE="$dir/config" "$SKILLS" list)
  assert_contains "$out" "macos-computer-use on config/computer-use" "list must show a switched-on skill"
  assert_contains "$out" "adhd off config/adhd" "list must show a switched-off skill"
  assert_contains "$out" "daily-todo-freshness off config/daily-todo config/morning-intake config/channel-intake" \
    "list must name every switch of a skill"
  shipped=$(for entry in "$ROOT"/.agents/opt-in-skills/*/; do entry=${entry%/}; printf '%s\n' "${entry##*/}"; done \
    | sort | tr '\n' ' ')
  listed=$(printf '%s\n' "$out" | cut -d' ' -f1 | sort | tr '\n' ' ')
  assert_equals "$shipped" "$listed" "every shipped opt-in skill must have a switch, and every switch a skill"
  pass "list shows each opt-in skill's state and switches, covering every shipped opt-in skill"
}

test_misuse_exits_2() {
  local code
  "$SKILLS" 2>/dev/null; code=$?
  expect_code 2 "$code" "no subcommand"
  "$SKILLS" frobnicate 2>/dev/null; code=$?
  expect_code 2 "$code" "an unknown subcommand"
  "$SKILLS" list extra 2>/dev/null; code=$?
  expect_code 2 "$code" "list with an argument"
  pass "misuse exits 2"
}

test_no_switch_links_nothing
test_switch_links_its_skills_and_checkout_stays_clean
test_every_switch_on_keeps_checkout_clean
test_switch_off_removes_only_its_links
test_intake_configs_switch_on_the_todo_skill
test_foreign_path_is_left_alone
test_checkout_without_opt_in_folder_is_untouched
test_list_names_every_opt_in_skill
test_misuse_exits_2

echo "# fm-opt-in-skills.test.sh: all assertions passed"
