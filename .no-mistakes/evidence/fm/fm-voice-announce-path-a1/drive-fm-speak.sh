#!/usr/bin/env bash
# Drives the real bin/fm-speak.sh against disposable FM_HOMEs holding copies of
# the real starship-voice / glasses-voice clones (register owner = real announce).
set -u
LAB=/var/folders/1g/hctp3vpn27b1zrlsn4nsfg680000gn/T//fm-voice-lab.gfu6nF; WT=/Users/larsmusic/.no-mistakes/worktrees/f569cc43ac96/01M3T4T210EVTKQH1J3DZJSATS
export GLASSES_VOICE_RUNTIME="$LAB/runtime" FM_DEEPGRAM_ENV_FILE=/dev/null
unset DEEPGRAM_API_KEY FM_SPEAK_SHAPER FM_ROOT_OVERRIDE FM_STATE_OVERRIDE FM_CONFIG_OVERRIDE GLASSES_ANNOUNCE_CONFIG
mkhome() {  # <name> <projects...>
  local h="$LAB/homes/$1"; shift; rm -rf "$h"; mkdir -p "$h/config" "$h/projects"
  echo 'enabled = true' > "$h/config/speak"
  for p in "$@"; do cp -R "$LAB/pristine/$p" "$h/projects/$p"; done
  cat > "$h/speaker" <<SPK
#!/usr/bin/env bash
printf 'speaker argv: %s\n' "\$*" >> "$h/spoken.log"
SPK
  chmod +x "$h/speaker"; echo "$h"
}
run() {  # <label> <script> <home> <args...>
  local label=$1 script=$2 h=$3; shift 3
  : > "$LAB/trace.log"
  echo "### $label"
  echo "\$ ls \$FM_HOME/projects  ->  $(ls "$h/projects" | tr '\n' ' ')"
  echo "\$ $(basename "$script") $*"
  local out rc
  out=$(env FM_HOME="$h" FM_SPEAK_SAY="$h/speaker" ${EXTRA_ENV:-} "$script" "$@" 2>&1); rc=$?
  printf '%s\n' "$out" | sed 's/^/  | /'
  echo "  exit=$rc"
  echo "  register owner reached: $(cut -d' ' -f1 "$LAB/trace.log" | sort -u | tr '\n' ' ')"
  sleep 1; [ -f "$h/spoken.log" ] && sed 's/^/  speaker got: /' "$h/spoken.log"
  echo
}
NEW=$WT/bin/fm-speak.sh; OLD=$LAB/fm-speak.base.sh
h=$(mkhome retired starship-voice)
EXTRA_ENV="FM_ROOT_OVERRIDE=$WT" run "REPORTED BUG, BEFORE (base b398526): glasses-voice retired, only starship-voice cloned" "$OLD" "$h" --dry-run "The fix is green."
h=$(mkhome retired2 starship-voice)
run "AFTER (this change): glasses-voice retired, only starship-voice cloned (dry run)" "$NEW" "$h" --dry-run "The fix is green."
h=$(mkhome retired3 starship-voice)
run "AFTER: glasses-voice retired, spoken reply reaches the speaker" "$NEW" "$h" "PR 241 merged. See https://example.com/pr/241 for detail."
h=$(mkhome both starship-voice glasses-voice)
run "AFTER: both clones present -> starship-voice preferred" "$NEW" "$h" --dry-run "The fix is green."
h=$(mkhome legacy glasses-voice)
run "AFTER: only the retiring glasses-voice clone -> fallback still speaks" "$NEW" "$h" --dry-run "The fix is green."
h=$(mkhome override starship-voice glasses-voice)
cp -R "$LAB/pristine/glasses-voice" "$h/custom-owner"; sed -i '' 's/printf "%s %s\\n" glasses-voice/printf "%s %s\\n" custom-owner/' "$h/custom-owner/bin/announce"
EXTRA_ENV="FM_SPEAK_SHAPER=$h/custom-owner/bin/announce" run "AFTER: explicit FM_SPEAK_SHAPER override beats both clones" "$NEW" "$h" --dry-run "The fix is green."
h=$(mkhome none)
run "ADVERSARIAL: neither clone present -> honest failure, nothing spoken" "$NEW" "$h" "The fix is green."
h=$(mkhome refuse starship-voice)
run "ADVERSARIAL: starship-voice register refusal still enforced (exit 2, nothing spoken)" "$NEW" "$h" "Shall I merge it? Say yes to go ahead."
h=$(mkhome dangling starship-voice glasses-voice)
chmod -x "$h/projects/starship-voice/bin/announce"
run "ADVERSARIAL: starship-voice announce present but not executable (both clones)" "$NEW" "$h" --dry-run "The fix is green."
