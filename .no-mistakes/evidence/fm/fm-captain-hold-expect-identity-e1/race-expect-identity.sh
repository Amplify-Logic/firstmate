#!/usr/bin/env bash
# Live race: a reworded re-hold and a phone tap on the old card launched concurrently, real CLI + real tasks-axi.
set -u
WT=$1 LAB=$2 N=${3:-12} MODE=${4:-}  # MODE=--release to leave the call open for re-hold
CH() { env -u NO_MISTAKES_GATE -u FM_ROOT_OVERRIDE -u FM_STATE_OVERRIDE -u FM_DATA_OVERRIDE -u FM_CONFIG_OVERRIDE -u FM_PROJECTS_OVERRIDE FM_HOME="$LAB" "$WT/bin/fm-captain-hold.sh" "$@"; }
T() { (cd "$LAB" && tasks-axi "$@"); }
bad=0 won=0 refused=0
for i in $(seq 1 "$N"); do
  id=race${MODE:+r}-${RUN_TAG:-x}-$i
  T add "$id" "Race $i" --kind ship --repo sample >/dev/null
  CH hold "$id" --reason "question A" >/dev/null
  shown=$(CH open "$id" --identity)
  # optional stagger so both orderings occur
  ( [ $((i % 2)) = 0 ] && sleep 0.3; CH hold "$id" --reason "question B" >/dev/null 2>&1; echo $? > "$LAB/$id.hrc" ) & hp=$!
  ( [ $((i % 2)) = 1 ] && sleep 0.3; CH answer "$id" --decision-file "$LAB/go.txt" --expect-identity "$shown" $MODE >/dev/null 2>"$LAB/$id.err"; echo $? > "$LAB/$id.rc" ) & ap=$!
  wait $hp $ap
  rc=$(cat "$LAB/$id.rc"); hrc=$(cat "$LAB/$id.hrc"); full=$(T show "$id" --full)
  n=$(printf '%s\n' "$full" | grep -c 'Resolution recorded by fm-captain-hold')
  reason=$(printf '%s\n' "$full" | grep -m1 'hold_reason:' | sed 's/.*hold_reason: *//')
  now=$(CH open "$id" --identity 2>/dev/null || echo closed)
  verdict=ok
  if [ "$rc" = 0 ]; then
    won=$((won+1))
    # tap landed first, so it answered question A. Then either the reword was
    # refused on the closed call (reason stays A), or, after a --release, B was
    # held as a new call whose identity differs from the card that was tapped.
    if [ "$n" != 1 ]; then verdict=BAD
    elif [ "$hrc" != 0 ]; then [ "$reason" = "question A" ] && [ "$now" = closed ] || verdict=BAD
    else [ "$reason" = "question B" ] && [ "$now" != "$shown" ] && [ "$now" != closed ] || verdict=BAD; fi
  elif [ "$rc" = 3 ]; then
    refused=$((refused+1))
    [ "$n" = 0 ] && [ "$reason" = "question B" ] || verdict=BAD
  else verdict=BAD; fi
  [ "$verdict" = ok ] || bad=$((bad+1))
  printf 'iter %2d: hold rc=%s tap rc=%s answers=%s final_reason=%s shown=%s now=%s -> %s\n' "$i" "$hrc" "$rc" "$n" "$reason" "$shown" "$now" "$verdict"
done
printf '\ntaps landed on the shown question: %s, taps refused as changed: %s, wrong-question answers: %s\n' "$won" "$refused" "$bad"
[ "$bad" = 0 ]
