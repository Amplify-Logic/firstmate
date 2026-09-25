#!/usr/bin/env bash
# Live driver for bin/fm-speak.sh reply history / replay, in an isolated FM_HOME.
# Deepgram synthesis is simulated with a 2 s network delay; the player logs
# a timestamp when it starts so the replay latency is observable.
set -u
REPO=$1          # checkout whose bin/fm-speak.sh is driven
LABEL=$2
W=$(mktemp -d "${TMPDIR:-/tmp}/fm-speak-live.XXXXXX")
home=$W/home; mkdir -p "$home/config"
printf 'enabled = true\n' > "$home/config/speak"
printf 'DEEPGRAM_API_KEY=fake-live-drive\n' > "$home/.env"
cat > "$home/shaper" <<'S'
#!/usr/bin/env bash
shift; printf '%s\n' "$*"
S
cat > "$home/deepgram-tts" <<S
#!/usr/bin/env bash
out=
while [ "\$#" -gt 0 ]; do case "\$1" in --to) out=\$2; shift 2;; --) shift; break;; *) shift;; esac; done
sleep 2   # simulated network synthesis
printf 'synth: %s\n' "\$*" >> "$home/deepgram.log"
printf 'audio of %s' "\$*" > "\$out"
S
cat > "$home/afplay" <<S
#!/usr/bin/env bash
printf '%s start: %s\n' "\$(python3 -c 'import time;print(f"{time.time():.3f}")')" "\$(cat "\$1")" >> "$home/played.log"
sleep 0.3
S
cat > "$home/say" <<S
#!/usr/bin/env bash
printf 'say: %s\n' "\$*" >> "$home/say.log"
S
chmod +x "$home"/shaper "$home"/deepgram-tts "$home"/afplay "$home"/say
sp() { FM_HOME="$home" FM_SPEAK_SHAPER="$home/shaper" FM_SPEAK_SAY="$home/say" \
  FM_DEEPGRAM_ENV_FILE="$home/.env" FM_SPEAK_DEEPGRAM_TTS="$home/deepgram-tts" \
  FM_DEEPGRAM_AFPLAY="$home/afplay" "$REPO/bin/fm-speak.sh" "$@"; }
now() { python3 -c 'import time;print(f"{time.time():.3f}")'; }
waitplays() { local n=$1 i=0; while [ "$(wc -l < "$home/played.log" 2>/dev/null || echo 0)" -lt "$n" ] && [ $i -lt 100 ]; do sleep 0.1; i=$((i+1)); done; }
echo "=== [$LABEL] speak three replies while the captain is away ==="
n=0
for line in "First: the build is green." "Second: PR 196 is open for review." "Third: the scout finished the audit."; do
  sp "$line"; n=$((n+1)); waitplays $n
done
echo "synth calls so far: $(wc -l < "$home/deepgram.log")"
echo
echo "=== [$LABEL] time a --repeat ==="
t0=$(now); out=$(sp --repeat 2>&1); rc=$?; n=$((n+1)); waitplays $n
t1=$(tail -n1 "$home/played.log" | cut -d' ' -f1)
echo "exit $rc, printed: $out"
python3 -c "print(f'repeat click -> player start: {($t1-$t0):.2f} s')"
echo "synth calls after repeat: $(wc -l < "$home/deepgram.log")"
echo
if [ "$LABEL" = after ]; then
  echo "=== [$LABEL] fm-speak.sh --history ==="
  sp --history | cat -A 2>/dev/null || sp --history
  echo
  third=$(sp --history | sed -n 3p | cut -f1)
  echo "=== [$LABEL] replay the third-newest (number $third) ==="
  t0=$(now); out=$(sp --replay "$third" 2>&1); rc=$?; n=$((n+1)); waitplays $n
  t1=$(tail -n1 "$home/played.log" | cut -d' ' -f1)
  echo "exit $rc, printed: $out"
  python3 -c "print(f'replay click -> player start: {($t1-$t0):.2f} s')"
  echo "last played: $(tail -n1 "$home/played.log" | cut -d' ' -f2-)"
  echo "synth calls after replay: $(wc -l < "$home/deepgram.log")"
  echo
  echo "=== [$LABEL] adversarial inputs ==="
  for a in 999 0 abc 01 ""; do out=$(sp --replay "$a" 2>&1); echo "--replay '$a' -> exit $? : $out"; done
  out=$(sp --replay 2>&1); echo "--replay (no number) -> exit $? : $out"
  out=$(sp --history --replay 1 2>&1); echo "--history --replay 1 -> exit $? : $out"
  echo
  echo "=== [$LABEL] muted replay stays silent ==="
  sp --mute; before=$(wc -l < "$home/played.log")
  out=$(sp --replay "$third" 2>&1); echo "muted --replay $third -> exit $? : $out"; sleep 1
  echo "plays before/after: $before/$(wc -l < "$home/played.log")"; sp --unmute
  echo
  echo "=== [$LABEL] pruning to 10: speak 9 more ==="
  for i in $(seq 4 12); do sp "Reply $i."; n=$((n+1)); waitplays $n; done
  sp --history | cut -f1,3 | tr '\t' ' '
  echo "kept entries: $(ls "$home/state/speak-history" | sort -n | tr '\n' ' ')"
  out=$(sp --replay 1 2>&1); echo "--replay 1 (pruned) -> exit $? : $out"
  echo
  echo "=== [$LABEL] permissions ==="
  stat -f '%Sp %N' "$home/state/speak-history" "$home/state/speak-history/12" "$home/state/speak-history/12"/*
  echo
  echo "=== [$LABEL] empty history ==="
  e=$W/empty; mkdir -p "$e/config"; printf 'enabled = true\n' > "$e/config/speak"
  out=$(FM_HOME="$e" "$REPO/bin/fm-speak.sh" --history); echo "--history on fresh home -> exit $? : '$out'"
  out=$(FM_HOME="$e" FM_SPEAK_SAY="$home/say" "$REPO/bin/fm-speak.sh" --repeat 2>&1); echo "--repeat on fresh home -> exit $? : $out"
fi
rm -rf "$W"
