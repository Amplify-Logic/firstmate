#!/usr/bin/env bash
# Behavior tests for the spoken-relay freshness ledger.
#
# Every case here is a failure that actually happened in the live voice trial,
# written as the shortest sequence that reproduces it:
#   - the companion re-reading a password step after the sign-in already worked;
#   - a prior answer spoken again as if it were new;
#   - a queue receipt reported as though the work had happened;
#   - a correction arriving while a step was running;
#   - "did you send it?" turning into a second send.
# Fixture actions only: no password, no clipboard, no remote input, no Dell.
set -u

# shellcheck source=tests/lib.sh
# shellcheck disable=SC1091
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

RELAY="$ROOT/bin/fm-voice-relay.sh"
TMP_ROOT=$(fm_test_tmproot fm-voice-relay)

# Each test gets its own ledger and its own authorized directory, so no test can
# see another's state and a leak shows up as a failure rather than as luck.
new_home() {  # <name> ; echoes the shared directory
  local name=$1
  mkdir -p "$TMP_ROOT/$name/state" "$TMP_ROOT/$name/shared"
  printf '%s\n' "$TMP_ROOT/$name/shared"
}

relay() {  # <home-name> <args...>
  local name=$1
  shift
  FM_VOICE_RELAY_DIR="$TMP_ROOT/$name/state/voice-relay" "$RELAY" "$@"
}

bind_home() {  # <home-name> [companion-id]
  local name=$1 companion=${2:-COMPANION-A} shared
  shared="$TMP_ROOT/$name/shared"
  relay "$name" bind --companion "$companion" --primary PRIMARY-A \
    --home "$TMP_ROOT/$name/codex-home" --dir "$shared" >/dev/null
}

# The trial's signature failure: sign-in succeeds, and the companion then reads
# out the password step that was queued before the success.
test_success_retires_the_stale_sign_in_substeps() {
  local out code
  new_home signin >/dev/null
  bind_home signin
  relay signin open dell-signin --summary "sign in over the remote desktop" >/dev/null
  relay signin step dell-signin --step vnc-password --step clipboard-paste >/dev/null
  relay signin begin dell-signin --revision 1 --step vnc-password >/dev/null
  relay signin performed dell-signin --revision 1 --step vnc-password >/dev/null
  relay signin complete dell-signin --revision 1 --outcome "signed in" >/dev/null

  out=$(relay signin check-action dell-signin --revision 1 --step clipboard-paste) && code=0 || code=$?
  expect_code 5 "$code" "a retired substep must be refused"
  assert_contains "$out" "retired" "the refusal must name the retirement"

  out=$(relay signin present dell-signin --revision 1 --outcome "type the password now" \
    --attribution companion-observed) && code=0 || code=$?
  expect_code 5 "$code" "a stale instruction must not be spoken after success"
  pass "fm-voice-relay: success retires this topic's pending steps for action and for speech"
}

# ... and it must retire only THIS topic. The keyboard work queued alongside it
# is still pending, because a success is not a fleet-wide cancel.
test_success_leaves_unrelated_work_pending() {
  local out
  new_home scope >/dev/null
  bind_home scope
  relay scope open dell-signin --summary "sign in" >/dev/null
  relay scope open keyboard-mapping --summary "check the key mapping" >/dev/null
  relay scope step keyboard-mapping --step observe-keys >/dev/null
  relay scope complete dell-signin --revision 1 --outcome "signed in" >/dev/null

  out=$(relay scope check-action keyboard-mapping --revision 1 --step observe-keys)
  assert_contains "$out" "fresh" "unrelated work must survive another topic's success"
  out=$(relay scope pending)
  assert_contains "$out" "logical-pending: 1" "the unrelated topic must still be counted as pending"
  assert_not_contains "$out" "dell-signin" "a completed topic must not be counted as pending"
  pass "fm-voice-relay: a success retires its own topic and nothing else"
}

# A correction is a new revision of the SAME request, never a second request.
test_correction_supersedes_without_duplicating_the_request() {
  local out code first second
  new_home correct >/dev/null
  bind_home correct
  first=$(relay correct open network-check --summary "check the wifi")
  second=$(relay correct revise network-check --summary "check the wired link instead" | head -1)
  [ "${first%% *}" = "${second%% *}" ] || fail "a correction must keep the same request id"
  assert_contains "$second" " 2" "a correction must advance the revision"

  out=$(relay correct open network-check --summary "check the wifi again" 2>&1) && code=0 || code=$?
  expect_code 9 "$code" "re-opening an existing topic must be refused, not duplicated"
  assert_contains "$out" "conflict" "the refusal must say why"

  out=$(relay correct check-action network-check --revision 1) && code=0 || code=$?
  expect_code 3 "$code" "the corrected revision must be superseded"
  assert_contains "$out" "superseded" "the verdict must name supersession"

  out=$(relay correct check-action network-check --revision 2)
  assert_contains "$out" "fresh" "the correction itself must be current"
  pass "fm-voice-relay: a correction updates the same request and retires the old revision"
}

# The honest boundary: a step already running cannot be recalled, and the ledger
# says so instead of implying the correction stopped it.
test_correction_during_active_work_reports_the_real_boundary() {
  local out code
  new_home active >/dev/null
  bind_home active
  relay active open panel-read --summary "read the panel" >/dev/null
  relay active step panel-read --step open-panel --step read-values >/dev/null
  relay active begin panel-read --revision 1 --step open-panel >/dev/null

  out=$(relay active revise panel-read --summary "read the other panel")
  assert_contains "$out" "in-flight: step open-panel" "a correction must report what is already running"
  assert_contains "$out" "cannot be interrupted" "the report must not imply the step was stopped"

  out=$(relay active check-action panel-read --revision 1 --step read-values) && code=0 || code=$?
  expect_code 3 "$code" "the not-yet-performed step of the old revision must be denied"

  relay active performed panel-read --revision 1 --step open-panel >/dev/null
  out=$(relay active check-action panel-read --revision 2 --step open-panel) && code=0 || code=$?
  expect_code 6 "$code" "a performed step must not be performed again under the new revision"
  assert_contains "$out" "already-performed" "the verdict must name the completed action"
  pass "fm-voice-relay: a correction denies the next stale step and keeps what already happened"
}

test_out_of_order_revision_cannot_revive_a_superseded_request() {
  local out code
  new_home order >/dev/null
  bind_home order
  relay order open sequence --summary "first" >/dev/null
  relay order revise sequence --summary "second" >/dev/null
  relay order revise sequence --summary "third" >/dev/null

  out=$(relay order check-action sequence --revision 1) && code=0 || code=$?
  expect_code 3 "$code" "an old queued item must not revive revision 1"
  out=$(relay order check-action sequence --revision 9) && code=0 || code=$?
  expect_code 4 "$code" "a revision that was never opened must be refused"
  assert_contains "$out" "unknown-revision" "the verdict must name the unknown revision"

  relay order cancel sequence --reason "captain stopped it" >/dev/null
  out=$(relay order check-action sequence --revision 3) && code=0 || code=$?
  expect_code 5 "$code" "a cancelled topic must refuse further action"
  pass "fm-voice-relay: out-of-order and post-cancel items cannot revive a request"
}

test_cancellation_is_not_a_rollback() {
  local out
  new_home cancel >/dev/null
  bind_home cancel
  relay cancel open cleanup --summary "tidy the window" >/dev/null
  relay cancel step cleanup --step close-dialog >/dev/null
  relay cancel begin cleanup --revision 1 --step close-dialog >/dev/null
  relay cancel performed cleanup --revision 1 --step close-dialog >/dev/null
  out=$(relay cancel cancel cleanup --reason "captain changed direction")
  assert_contains "$out" "performed steps are kept" "cancellation must not claim a rollback"
  out=$(relay cancel evidence cleanup)
  assert_contains "$out" "step-performed" "the performed action must stay in the evidence"
  pass "fm-voice-relay: cancelling stops what is next and never undoes what happened"
}

test_binding_replacement_rejects_the_old_target() {
  local out code
  new_home rebind >/dev/null
  bind_home rebind COMPANION-OLD
  relay rebind open handover --summary "ask the companion" >/dev/null
  out=$(relay rebind check-action handover --revision 1)
  assert_contains "$out" "fresh" "the request must be current under its own binding"

  bind_home rebind COMPANION-NEW
  out=$(relay rebind check-action handover --revision 1) && code=0 || code=$?
  expect_code 7 "$code" "a request bound to a replaced session must be refused"
  assert_contains "$out" "binding-replaced" "the verdict must name the replacement"
  assert_present "$TMP_ROOT/rebind/state/voice-relay/bindings/history" "the old binding must be archived"
  pass "fm-voice-relay: replacing the enrolled session invalidates the old routing"
}

test_acceptance_deduplicates_and_refuses_conflicts() {
  local shared out code sha receipt
  shared=$(new_home accept)
  bind_home accept
  relay accept open result-return --summary "return the result" >/dev/null
  printf 'Request id: voice-result-return@r1\nresult: done\n' > "$shared/answer.md"
  sha=$(shasum -a 256 "$shared/answer.md" | awk '{print $1}')
  receipt="$shared/answer-received.md"

  out=$(relay accept accept result-return --revision 1 --answer "$shared/answer.md" \
    --sha256 "$sha" --receipt "$receipt")
  assert_contains "$out" "ok: accepted" "the first acceptance must publish the receipt"
  local before after
  before=$(shasum -a 256 "$receipt" | awk '{print $1}')

  out=$(relay accept accept result-return --revision 1 --answer "$shared/answer.md" \
    --sha256 "$sha" --receipt "$receipt")
  assert_contains "$out" "duplicate" "an exact repeat must be a duplicate"
  after=$(shasum -a 256 "$receipt" | awk '{print $1}')
  [ "$before" = "$after" ] || fail "a duplicate must leave the receipt byte-identical"

  printf 'tampered\n' > "$shared/answer.md"
  out=$(relay accept accept result-return --revision 1 --answer "$shared/answer.md" \
    --sha256 "$sha" --receipt "$shared/second-receipt.md") && code=0 || code=$?
  expect_code 9 "$code" "a hash disagreement must fail closed"
  assert_absent "$shared/second-receipt.md" "a refused acceptance must write nothing"
  pass "fm-voice-relay: acceptance is deduplicated by identity and hash, and conflicts write nothing"
}

test_unsafe_answer_paths_are_refused_before_any_read() {
  local shared out code
  shared=$(new_home paths)
  bind_home paths
  relay paths open safety --summary "return a result" >/dev/null
  printf 'x\n' > "$shared/real.md"
  printf 'secret\n' > "$TMP_ROOT/paths/outside.md"
  ln -s "$TMP_ROOT/paths/outside.md" "$shared/link.md"
  local sha
  sha=$(shasum -a 256 "$shared/real.md" | awk '{print $1}')

  for bad in "$TMP_ROOT/paths/outside.md" "relative.md" "$shared/../outside.md" "$shared"; do
    out=$(relay paths accept safety --revision 1 --answer "$bad" --sha256 "$sha" \
      --receipt "$shared/r.md" 2>&1) && code=0 || code=$?
    expect_code 9 "$code" "unsafe answer path must be refused: $bad"
  done
  out=$(relay paths accept safety --revision 1 --answer "$shared/link.md" --sha256 "$sha" \
    --receipt "$shared/r.md" 2>&1) && code=0 || code=$?
  expect_code 9 "$code" "a symlinked answer must be refused"
  assert_contains "$out" "symlink" "the refusal must name the symlink"
  assert_absent "$shared/r.md" "no receipt may be written for a refused path"
  pass "fm-voice-relay: relative, escaping, outside, directory and symlink answers are all refused"
}

test_presentation_is_deduplicated_and_filler_is_suppressed() {
  local out code
  new_home speech >/dev/null
  bind_home speech
  relay speech open speak-once --summary "report the outcome" >/dev/null

  out=$(relay speech present speak-once --revision 1 --outcome "the panel is showing 42" \
    --attribution companion-observed)
  assert_contains "$out" "Companion saw: the panel is showing 42" "the sentence must carry its attribution"

  out=$(relay speech present speak-once --revision 1 --outcome "the panel is showing 42" \
    --attribution companion-observed) && code=0 || code=$?
  expect_code 8 "$code" "the same sentence must not be spoken twice"
  assert_contains "$out" "duplicate-suppressed" "the verdict must name the suppression"

  out=$(relay speech present speak-once --revision 1 --outcome "still working on it" \
    --attribution firstmate-verified) && code=0 || code=$?
  expect_code 8 "$code" "filler must be suppressed rather than spoken"

  out=$(relay speech present speak-once --revision 1 --outcome "the panel is showing 42" \
    --attribution firstmate-verified)
  assert_contains "$out" "Firstmate confirmed" "a different attribution is a different statement"

  out=$(relay speech present speak-once --revision 1 --outcome "done" --attribution mixed \
    --question "shall I close it?" --question "or leave it?" 2>&1) && code=0 || code=$?
  expect_code 2 "$code" "more than one bundled question must be refused"
  pass "fm-voice-relay: repeats, filler and multi-question speech are suppressed at the gate"
}

test_completion_and_presentation_are_separate_records() {
  local out
  new_home terminal >/dev/null
  bind_home terminal
  relay terminal open two-states --summary "do the thing" >/dev/null
  relay terminal complete two-states --revision 1 --outcome "did the thing" >/dev/null
  out=$(relay terminal evidence two-states)
  assert_contains "$out" "completed" "completion must be recorded"
  assert_not_contains "$out" "presented" "completion alone must not imply anything was said"
  relay terminal present two-states --revision 1 --outcome "the thing is done" \
    --attribution firstmate-verified --final >/dev/null
  out=$(relay terminal evidence two-states)
  assert_contains "$out" "presented" "presentation must be its own record"
  assert_contains "$out" "audible playback are unknown" "the evidence must not imply audio was heard"
  pass "fm-voice-relay: completing work and saying it are recorded separately"
}

test_enqueue_is_not_delivery_and_status_never_resends() {
  local out
  new_home transport >/dev/null
  bind_home transport
  relay transport open handoff-topic --summary "hand it over" >/dev/null
  out=$(relay transport handoff handoff-topic --revision 1)
  assert_contains "$out" "send-now" "the first authorization must say to send now"
  out=$(relay transport handoff handoff-topic --revision 1)
  assert_contains "$out" "already-authorized" "a second ask must not prompt again"
  assert_contains "$out" "do not send a second copy" "a second ask must not cause a second send"

  out=$(relay transport phase handoff-topic --revision 1 --phase enqueued --message-id MSG-1 --queue-exit 0)
  assert_contains "$out" "proves the queue accepted the message and nothing else" \
    "an enqueue receipt must not be reported as delivery"

  out=$(relay transport sent-status handoff-topic)
  assert_contains "$out" "accepted by the queue, delivery unconfirmed" "an unconfirmed send must be reported as such"
  assert_contains "$out" "Not resent" "the status answer must refuse a blind retry"
  assert_contains "$out" "MSG-1" "the status answer must cite the real transport evidence"

  # A pickup someone typed is not evidence a turn happened. Only a record
  # carrying the transport's own turn id may be reported as confirmed.
  relay transport phase handoff-topic --revision 1 --phase picked-up --note "turn started" >/dev/null
  out=$(relay transport sent-status handoff-topic)
  assert_contains "$out" "recorded by the operator with no transport evidence" \
    "an operator claim must not be reported as a confirmed turn"
  assert_not_contains "$out" "confirmed by transport evidence" "a claim must not read as verification"

  relay transport phase handoff-topic --revision 1 --phase picked-up --turn-id TURN-5 >/dev/null
  out=$(relay transport sent-status handoff-topic)
  assert_contains "$out" "a turn was confirmed by transport evidence" "a real turn id must upgrade the verdict"
  pass "fm-voice-relay: enqueue, pickup and delivery stay distinct and a status query never resends"
}

# Every one of these was reproduced against the shipped build by independent
# review: a rejected handoff reported as accepted, a phase recorded against a
# revision that never existed, and a verdict of confirmed delivery built on top
# of them. They are the ledger committing the exact confusion it exists to stop.
test_recorded_claims_never_become_transport_evidence() {
  local out code
  new_home evidence >/dev/null
  bind_home evidence
  relay evidence open example --summary "harmless fixture" >/dev/null

  out=$(relay evidence phase example --revision 1 --phase enqueued --queue-exit 1)
  assert_contains "$out" "the queue did not accept" "a non-zero queue exit must not be recorded as an acceptance"
  assert_not_contains "$out" "proves the queue accepted" "a failed handoff must never claim acceptance"

  out=$(relay evidence phase example --revision 99 --phase picked-up 2>&1) && code=0 || code=$?
  expect_code 4 "$code" "a phase against a revision that was never opened must be refused"

  out=$(relay evidence sent-status example)
  assert_contains "$out" "the handoff failed" "a failed handoff must be reported as failed"
  assert_not_contains "$out" "confirmed" "nothing may be reported as confirmed here"

  out=$(relay evidence phase example --revision 1 --phase enqueued)
  assert_contains "$out" "operator claim" "an enqueue without a receipt is a claim, not proof"
  out=$(relay evidence sent-status example)
  assert_contains "$out" "even acceptance is unconfirmed" "a receiptless handoff must not read as accepted"
  assert_contains "$out" "Not resent" "the answer must still refuse a blind retry"
  pass "fm-voice-relay: a rejected handoff, a phantom revision and an unbacked pickup are all refused their claims"
}

# sent-status answers about the instruction that is current, not the one it replaced.
test_status_reports_the_current_revision_by_default() {
  local out
  new_home scoped >/dev/null
  bind_home scoped
  relay scoped open scope-topic --summary "first" >/dev/null
  relay scoped phase scope-topic --revision 1 --phase enqueued --message-id OLD-1 --queue-exit 0 >/dev/null
  relay scoped revise scope-topic --summary "corrected" >/dev/null

  out=$(relay scoped sent-status scope-topic)
  assert_contains "$out" "revision 2 (current)" "the default answer must be about the current revision"
  assert_contains "$out" "nothing was handed off yet" "the correction has not been handed off"
  assert_not_contains "$out" "OLD-1" "the replaced instruction's transport must not answer for the current one"

  out=$(relay scoped sent-status scope-topic --revision 1)
  assert_contains "$out" "OLD-1" "an older revision's history must still be readable on request"
  assert_contains "$out" "(superseded)" "an older revision must be labelled as superseded"
  pass "fm-voice-relay: status answers for the current revision and keeps older history readable"
}

test_recorded_claims_never_become_transport_evidence
test_status_reports_the_current_revision_by_default
test_pending_count_groups_revisions_and_admits_what_is_unknown() {
  local out
  new_home counting >/dev/null
  bind_home counting
  relay counting open one --summary "first job" >/dev/null
  relay counting revise one --summary "corrected first job" >/dev/null
  relay counting revise one --summary "corrected again" >/dev/null
  relay counting open two --summary "second job" >/dev/null
  out=$(relay counting pending)
  assert_contains "$out" "logical-pending: 2" "three revisions of one request must count once"
  assert_contains "$out" "native-queue-depth: unknown" "the native queue depth must stay unknown"
  assert_contains "$out" "audio-playback: unknown" "audible playback must stay unknown"
  pass "fm-voice-relay: the pending count is logical, grouped, and honest about what it cannot see"
}

# Two callers race for the same step and the same receipt. Exactly one may win,
# and the loser must fail closed rather than duplicate the work.
test_concurrent_claims_and_publishes_have_exactly_one_winner() {
  local shared wins=0 losses=0 code i sha
  shared=$(new_home race)
  bind_home race
  relay race open race-topic --summary "race" >/dev/null
  relay race step race-topic --step only-once >/dev/null

  for i in 1 2 3 4 5; do
    ( relay race begin race-topic --revision 1 --step only-once >"$TMP_ROOT/race/out.$i" 2>&1;
      printf '%s\n' "$?" > "$TMP_ROOT/race/code.$i" ) &
  done
  wait
  for i in 1 2 3 4 5; do
    code=$(cat "$TMP_ROOT/race/code.$i")
    if [ "$code" = 0 ]; then wins=$((wins + 1)); else losses=$((losses + 1)); fi
  done
  [ "$wins" = 1 ] || fail "exactly one caller may claim a step, got $wins winners"
  [ "$losses" = 4 ] || fail "every losing caller must be refused, got $losses"

  printf 'Request id: voice-race-topic@r1\n' > "$shared/a.md"
  sha=$(shasum -a 256 "$shared/a.md" | awk '{print $1}')
  wins=0
  for i in 1 2 3 4 5; do
    ( relay race accept race-topic --revision 1 --answer "$shared/a.md" --sha256 "$sha" \
        --receipt "$shared/a-received.md" >"$TMP_ROOT/race/acc.$i" 2>&1 ) &
  done
  wait
  for i in 1 2 3 4 5; do
    grep -q '^ok: accepted' "$TMP_ROOT/race/acc.$i" && wins=$((wins + 1))
  done
  [ "$wins" = 1 ] || fail "exactly one acceptance may publish the receipt, got $wins"
  [ "$(find "$shared" -name 'a-received.md' | wc -l | tr -d ' ')" = 1 ] || fail "one receipt must exist"
  pass "fm-voice-relay: racing claims and racing acceptances leave exactly one winner"
}

test_preferences_are_style_only_and_never_authority() {
  local out code
  new_home prefs >/dev/null
  bind_home prefs COMPANION-P1

  out=$(relay prefs pref set approvals.autoRun --value yes --source captain-confirmed 2>&1) && code=0 || code=$?
  expect_code 2 "$code" "a preference key outside the style namespace must be refused"
  assert_contains "$out" "never grant execution authority" "the refusal must say why"

  relay prefs pref set speech.routine_seconds --value 10 --source companion-proposal >/dev/null
  relay prefs pref set style.tone --value "warm and direct" --source captain-confirmed >/dev/null
  out=$(relay prefs pref render)
  assert_contains "$out" "PROPOSAL - not a captain rule until confirmed" "a proposal must be labelled as one"
  assert_contains "$out" "style.tone: warm and direct (captain-confirmed)" "a confirmed preference must be labelled"
  assert_contains "$out" "never global model settings" "the rendering must not imply a global setting"

  relay prefs pref forget style.tone >/dev/null
  out=$(relay prefs pref render)
  assert_not_contains "$out" "style.tone" "a forgotten preference must stop rendering"

  bind_home prefs COMPANION-P2
  out=$(relay prefs pref show speech.routine_seconds) && code=0 || code=$?
  expect_code 7 "$code" "a preference must not survive a replaced enrollment unchallenged"
  assert_contains "$out" "invalidated-by-binding-replacement" "the status must name the invalidation"
  pass "fm-voice-relay: preferences are scoped style records that expire with the enrollment"
}

test_steer_command_uses_the_bound_thread_and_refuses_stale_revisions() {
  local out code
  new_home steer >/dev/null
  bind_home steer COMPANION-STEER
  relay steer open steerable --summary "look at the left panel" >/dev/null
  out=$(relay steer steer-command steerable --revision 1 --turn TURN-7)
  assert_contains "$out" "fm-voice-relay-appserver.sh' steer --thread 'COMPANION-STEER' --expected-turn 'TURN-7'" \
    "the printed command must carry the bound thread and the real turn"
  assert_contains "$out" "must not be retried blindly" "the note must keep the refusal meaningful"
  assert_contains "$out" "queue it once through codex queue" "the printed command must name the supported fallback"

  relay steer revise steerable --summary "the right panel instead" >/dev/null
  out=$(relay steer steer-command steerable --revision 1 --turn TURN-7 2>&1) && code=0 || code=$?
  expect_code 3 "$code" "a superseded revision must not be steered"
  assert_contains "$out" "superseded" "a refused steer must still say why, not exit silently"
  pass "fm-voice-relay: the steer command is assembled from the binding and gated on freshness"
}

# The printed steer is meant to be pasted into a shell, so every field it
# interpolates has to survive as data. A natural apostrophe broke the line, and
# a crafted correction appended a second command to it.
test_steer_command_quotes_free_text_and_the_bound_target() {
  local line parsed sentinel summary
  new_home quoting >/dev/null
  bind_home quoting "COMPANION'Q"
  sentinel="$TMP_ROOT/quoting/INJECTED"
  summary="don't touch the left panel'; touch $sentinel; echo '"
  relay quoting open quoting-topic --summary "$summary" >/dev/null

  line=$(relay quoting steer-command quoting-topic --revision 1 --turn "TURN'7" | head -1)
  # Parsing the line the way a shell would: each argument on its own line, and
  # nothing else may run while doing it.
  parsed=$(eval "printf '%s\n' $line" 2>/dev/null) || true
  assert_absent "$sentinel" "a crafted correction must not smuggle a second command into the pasted line"
  assert_contains "$parsed" "$summary" "the correction must survive quoting byte for byte"
  assert_contains "$parsed" "TURN'7" "the turn id must survive quoting"
  assert_contains "$parsed" "COMPANION'Q" "the bound thread must survive quoting"
  pass "fm-voice-relay: the pasted steer quotes free text instead of splicing it into a command"
}

# A topic ends once. Cancelling after a success used to publish a second
# terminal record that outranked the first, so a completed sign-in reported
# itself as cancelled for ever afterwards.
test_a_finished_topic_cannot_be_ended_a_second_time() {
  local out code
  new_home once >/dev/null
  bind_home once
  relay once open finish-once --summary "sign in" >/dev/null
  relay once complete finish-once --revision 1 --outcome "signed in" >/dev/null

  out=$(relay once cancel finish-once --reason "changed my mind" 2>&1) && code=0 || code=$?
  expect_code 5 "$code" "cancelling a completed topic must be refused"
  assert_contains "$out" "retired" "the refusal must name the existing terminal record"

  out=$(relay once evidence finish-once)
  assert_contains "$out" "state: completed 1" "the success must survive the attempted cancellation"
  out=$(relay once present finish-once --revision 1 --outcome "the sign-in worked" \
    --attribution firstmate-verified --final)
  assert_contains "$out" "the sign-in worked" "the final announcement must still describe the real ending"

  new_home once-c >/dev/null
  bind_home once-c
  relay once-c open stop-once --summary "do it" >/dev/null
  relay once-c cancel stop-once --reason "captain stopped it" >/dev/null
  out=$(relay once-c complete stop-once --revision 1 --outcome "done anyway" 2>&1) && code=0 || code=$?
  expect_code 5 "$code" "completing a cancelled topic must stay refused"
  pass "fm-voice-relay: the terminal record is published once per topic and never overwritten"
}

# A second bind retires the old enrollment. A correction must not re-adopt that
# request onto the newly bound session just by minting a newer revision.
test_a_correction_cannot_readopt_a_replaced_binding() {
  local out code
  new_home readopt >/dev/null
  bind_home readopt COMPANION-OLD
  relay readopt open carryover --summary "ask the old session" >/dev/null

  bind_home readopt COMPANION-NEW
  out=$(relay readopt revise carryover --summary "ask again" 2>&1) && code=0 || code=$?
  expect_code 7 "$code" "a correction on a replaced binding must fail closed"
  assert_contains "$out" "binding-replaced" "the refusal must name the replacement"

  out=$(relay readopt check-action carryover --revision 1) && code=0 || code=$?
  expect_code 7 "$code" "the original revision must stay refused"
  [ "$(relay readopt pending | grep -c '^pending: carryover')" = 1 ] \
    || fail "the refused correction must not have created a second revision"
  pass "fm-voice-relay: a replaced enrollment cannot be re-adopted by revising its pending work"
}

# A gate that refuses silently is a gate a companion cannot report on.
test_a_refused_gate_always_says_why() {
  local out code
  new_home loud >/dev/null
  bind_home loud
  relay loud open speak-up --summary "first" >/dev/null
  relay loud step speak-up --step only-step >/dev/null
  relay loud revise speak-up --summary "second" >/dev/null

  out=$(relay loud begin speak-up --revision 1 --step only-step 2>&1) && code=0 || code=$?
  expect_code 3 "$code" "a superseded claim must be refused"
  assert_contains "$out" "superseded" "begin must print the verdict it refused on, not exit silently"

  out=$(relay loud handoff speak-up --revision 1 2>&1) && code=0 || code=$?
  expect_code 3 "$code" "a superseded handoff must be refused"
  assert_contains "$out" "superseded" "handoff must print the verdict it refused on"
  pass "fm-voice-relay: every gated command prints the refusal a companion has to speak or log"
}

# "A record already exists, do not retry" and "nothing was stored, the work
# still has to happen" fail closed in the same direction but demand opposite
# responses from the caller, so they must never share an exit code.
test_a_failed_write_is_not_reported_as_a_settled_conflict() {
  local out code topics
  if [ "$(id -u)" = 0 ]; then
    pass "fm-voice-relay: write-failure coverage skipped for a root test run"
    return 0
  fi
  new_home diskfull >/dev/null
  bind_home diskfull
  relay diskfull open write-me --summary "record something" >/dev/null

  out=$(relay diskfull open write-me --summary "again" 2>&1) && code=0 || code=$?
  expect_code 9 "$code" "a record that already exists must refuse as a conflict"
  assert_contains "$out" "conflict:" "the conflict verdict word must lead the line"

  topics="$TMP_ROOT/diskfull/state/voice-relay/topics/write-me"
  chmod 0500 "$topics"
  out=$(relay diskfull cancel write-me --reason "stop it" 2>&1) && code=0 || code=$?
  chmod 0700 "$topics"
  expect_code 10 "$code" "a write that never happened must not share the conflict code"
  assert_contains "$out" "write-failed:" "the write-failure verdict word must lead the line"
  assert_contains "$out" "nothing was recorded" "the refusal must say the work still has to happen"

  out=$(relay diskfull evidence write-me)
  assert_contains "$out" "state: open" "a failed write must leave the topic exactly as it was"
  pass "fm-voice-relay: a failed write and a settled conflict carry different exit codes"
}

test_a_request_without_a_binding_is_refused() {
  local out code
  new_home unbound >/dev/null
  out=$(relay unbound open orphan --summary "no binding yet" 2>&1) && code=0 || code=$?
  expect_code 2 "$code" "a request must not be created without an enrolled session"
  assert_contains "$out" "bind a session first" "the refusal must say what is missing"
  pass "fm-voice-relay: nothing can be routed before an enrollment is recorded"
}

test_success_retires_the_stale_sign_in_substeps
test_success_leaves_unrelated_work_pending
test_correction_supersedes_without_duplicating_the_request
test_correction_during_active_work_reports_the_real_boundary
test_out_of_order_revision_cannot_revive_a_superseded_request
test_cancellation_is_not_a_rollback
test_binding_replacement_rejects_the_old_target
test_acceptance_deduplicates_and_refuses_conflicts
test_unsafe_answer_paths_are_refused_before_any_read
test_presentation_is_deduplicated_and_filler_is_suppressed
test_completion_and_presentation_are_separate_records
test_enqueue_is_not_delivery_and_status_never_resends
test_pending_count_groups_revisions_and_admits_what_is_unknown
test_concurrent_claims_and_publishes_have_exactly_one_winner
test_preferences_are_style_only_and_never_authority
test_steer_command_uses_the_bound_thread_and_refuses_stale_revisions
test_steer_command_quotes_free_text_and_the_bound_target
test_a_finished_topic_cannot_be_ended_a_second_time
test_a_correction_cannot_readopt_a_replaced_binding
test_a_refused_gate_always_says_why
test_a_failed_write_is_not_reported_as_a_settled_conflict
test_a_request_without_a_binding_is_refused
