#!/usr/bin/env bash
# Live lab driver: runs the real Stop hook bin/fm-claude-reply-speak.sh from a
# plain (non-worktree) checkout of a given commit, as a child of a process named
# "claude" holding the lab home's session lock, through the real bin/fm-speak.sh,
# the real glasses-voice register owner, and real macOS say rendering to .aiff
# files (nothing played aloud, Deepgram disabled).
# Usage: drive-reply-speak.sh <commit> <label> <scenario-name> <reply-file> [register-toml]
set -u
WT=/Users/larstolhurst/.no-mistakes/worktrees/9957e108f4d7/01M3T3S04XWBNE27HYAFNXC1ZD
EV=/Users/larstolhurst/.no-mistakes/evidence/01M3T3S04XWBNE27HYAFNXC1ZD
COMMIT=$1 LABEL=$2 NAME=$3 REPLY_FILE=$4 REG=${5:-}
LAB=$(mktemp -d "${TMPDIR:-/tmp}/fm-lab.XXXXXX")
rmdir "$LAB"; "$WT/bin/fm-lab-home.sh" create "$LAB" >/dev/null || exit 1
mkdir -p "$LAB/root" "$LAB/fakebin"
git -C "$WT" archive "$COMMIT" | tar -x -C "$LAB/root"
git -C "$LAB/root" init -q && git -C "$LAB/root" -c user.name=lab -c user.email=lab@invalid commit -q --allow-empty -m lab
printf 'enabled = true\n' > "$LAB/config/speak"
ln -s /bin/bash "$LAB/fakebin/claude"
# Speaker: real /usr/bin/say rendering to a file in the evidence dir instead of the speaker.
cat > "$LAB/fakebin/say-to-file" <<SAY
#!/bin/bash
tf=""; while [ \$# -gt 0 ]; do case "\$1" in -f) tf=\$2; shift 2;; -o) shift 2;; *) shift;; esac; done
cp "\$tf" "$EV/$LABEL-$NAME.spoken.txt"
/usr/bin/say -o "$EV/$LABEL-$NAME.aiff" -f "\$tf"
SAY
chmod +x "$LAB/fakebin/say-to-file"
envs=(FM_HOME="$LAB" FM_SPEAK_SHAPER=/Users/larstolhurst/starship/projects/glasses-voice/bin/announce
  FM_SPEAK_SAY="$LAB/fakebin/say-to-file" FM_DEEPGRAM_ENV_FILE=/dev/null FM_REPLY_SPEAK_SETTLE_MS=0)
[ -z "$REG" ] || envs+=(FM_SPEAK_DEEPGRAM_REGISTER="$REG")
rm -f "$EV/$LABEL-$NAME.spoken.txt" "$EV/$LABEL-$NAME.aiff"
jq -cn --rawfile m "$REPLY_FILE" '{session_id:"lab",hook_event_name:"Stop",stop_hook_active:false,last_assistant_message:$m}' \
 | env -u NO_MISTAKES_GATE -u FM_GATE_REFUSE_BYPASS -u FM_ROOT_OVERRIDE -u FM_STATE_OVERRIDE -u FM_DATA_OVERRIDE \
     -u FM_CONFIG_OVERRIDE -u FM_PROJECTS_OVERRIDE -u DEEPGRAM_API_KEY -u GLASSES_ANNOUNCE_CONFIG "${envs[@]}" \
   "$LAB/fakebin/claude" -c 'printf "%s\n" "$$" > "$FM_HOME/state/.lock"; "$FM_HOME/root/bin/fm-claude-reply-speak.sh"; echo "hook exit=$? stdout-bytes-above=none"'
# wait for the detached speaker to finish rendering
for _ in $(seq 1 60); do [ -e "$LAB/state/.speak.lock" ] || [ -s "$EV/$LABEL-$NAME.aiff" ] && break; sleep 0.5; done
for _ in $(seq 1 60); do [ -e "$LAB/state/.speak.lock" ] || break; sleep 0.5; done
echo "--- [$LABEL] $NAME"
echo "reply lead (first paragraph):"; awk 'NF==0{exit} {print "  " $0}' "$REPLY_FILE"
if [ -s "$EV/$LABEL-$NAME.spoken.txt" ]; then
  echo "SPOKEN: $(cat "$EV/$LABEL-$NAME.spoken.txt")"
  echo "spoken words: $(wc -w < "$EV/$LABEL-$NAME.spoken.txt" | tr -d ' ')"
  echo "audio: $EV/$LABEL-$NAME.aiff ($(afinfo "$EV/$LABEL-$NAME.aiff" 2>/dev/null | awk '/estimated duration/{print $3 " s"}'))"
else
  echo "SPOKEN: <nothing>"
fi
echo "speak-history entries: $(ls "$LAB/state/speak-history" 2>/dev/null | tr '\n' ' ')"
rm -rf "$LAB"
