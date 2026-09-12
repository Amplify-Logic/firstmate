#!/usr/bin/env bash
# Behavior tests for the relay's steering transport.
#
# The question these tests answer is the captain's: can a correction actually
# reach a conversation that is already running, and does the system tell the
# truth when it cannot? Everything runs against a fake app-server, so no real
# thread, turn, daemon, or desktop session is touched.
set -u

# shellcheck source=tests/lib.sh
# shellcheck disable=SC1091
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

APPSERVER="$ROOT/bin/fm-voice-relay-appserver.sh"
TMP_ROOT=$(fm_test_tmproot fm-voice-relay-appserver)

# A fake app-server speaking the same newline-delimited JSON-RPC. It answers
# only what the real protocol defines, and it enforces the one rule that makes
# steering safe: a steer whose expectedTurnId is not the running turn is
# refused, exactly as the schema's compare-and-swap implies.
make_fake_server() {  # <wrapper-path> <script-path>
  cat > "$2" <<'PY'
import json,os,sys
turn=os.environ.get("FAKE_TURN_ID","turn-current")
turn_status=os.environ.get("FAKE_TURN_STATUS","inProgress")
thread_status=os.environ.get("FAKE_THREAD_STATUS","notLoaded")
log=os.environ.get("FAKE_SERVER_LOG")

def send(obj):
    sys.stdout.write(json.dumps(obj)+"\n")
    sys.stdout.flush()

for line in sys.stdin:
    line=line.strip()
    if not line:
        continue
    try:
        msg=json.loads(line)
    except ValueError:
        continue
    if log:
        with open(log,"a") as fh:
            fh.write(msg.get("method","?")+"\n")
    method=msg.get("method")
    params=msg.get("params") or {}
    if method=="initialize":
        send({"jsonrpc":"2.0","id":msg.get("id"),"result":{"userAgent":"fake"}})
    elif method=="thread/turns/list":
        send({"jsonrpc":"2.0","id":msg.get("id"),
              "result":{"data":[{"id":turn,"status":turn_status}]}})
    elif method=="thread/read":
        send({"jsonrpc":"2.0","id":msg.get("id"),
              "result":{"thread":{"id":params.get("threadId"),"status":thread_status,
                                  "turns":[{"id":turn}]}}})
    elif method=="turn/steer":
        if params.get("expectedTurnId")==turn:
            send({"jsonrpc":"2.0","id":msg.get("id"),"result":{"turnId":turn}})
        else:
            send({"jsonrpc":"2.0","id":msg.get("id"),
                  "error":{"code":-32002,"message":"expectedTurnId does not match the running turn"}})
    elif method=="turn/interrupt":
        send({"jsonrpc":"2.0","id":msg.get("id"),"result":{}})
    else:
        send({"jsonrpc":"2.0","id":msg.get("id"),
              "error":{"code":-32601,"message":"method not found"}})
PY
  cat > "$1" <<SH
#!/usr/bin/env bash
exec python3 "$2"
SH
  chmod +x "$1"
}

FAKE="$TMP_ROOT/fake-app-server"
make_fake_server "$FAKE" "$TMP_ROOT/fake-app-server.py"

appserver() {
  FM_VOICE_RELAY_PROXY_CMD="$FAKE" "$APPSERVER" "$@"
}

# A schema bundle shaped like the one the installed build generates.
make_schema() {  # <dir> <methods-json-fragment>
  local dir=$1 methods=$2
  mkdir -p "$dir/v2"
  printf '{"methods":[%s]}\n' "$methods" > "$dir/codex_app_server_protocol.v2.schemas.json"
  printf '{"properties":{"threadId":{},"expectedTurnId":{},"input":{}},"required":["expectedTurnId","input","threadId"]}\n' \
    > "$dir/v2/TurnSteerParams.json"
  printf '{"properties":{"threadId":{},"turnId":{}},"required":["threadId","turnId"]}\n' \
    > "$dir/v2/TurnInterruptParams.json"
}

# A long-lived app-server is entitled to answer and keep running. Waiting for it
# to exit before parsing turned a correct answer into a bogus timeout.
test_a_proxy_that_answers_and_stays_open_is_not_a_timeout() {
  local lingering out code started elapsed
  lingering="$TMP_ROOT/lingering-app-server"
  cat > "$TMP_ROOT/lingering-app-server.py" <<'LINGER'
import json,sys,time
for line in sys.stdin:
    line=line.strip()
    if not line:
        continue
    msg=json.loads(line)
    if msg.get("method")=="initialize":
        sys.stdout.write(json.dumps({"jsonrpc":"2.0","id":msg["id"],"result":{"userAgent":"fake"}})+"\n")
    elif msg.get("method")=="thread/turns/list":
        sys.stdout.write(json.dumps({"jsonrpc":"2.0","id":msg["id"],
            "result":{"data":[{"id":"turn-lingering","status":"inProgress"}]}})+"\n")
    sys.stdout.flush()
# Answered, and still running: stdin EOF is not a reason for this server to exit.
time.sleep(120)
LINGER
  cat > "$lingering" <<SH
#!/usr/bin/env bash
exec python3 "$TMP_ROOT/lingering-app-server.py"
SH
  chmod +x "$lingering"

  started=$(date -u +%s)
  out=$(FM_VOICE_RELAY_PROXY_CMD="$lingering" FM_VOICE_RELAY_RPC_TIMEOUT=20 \
    "$APPSERVER" active-turn --thread THREAD-1 --live 2>&1) && code=0 || code=$?
  elapsed=$(( $(date -u +%s) - started ))
  expect_code 0 "$code" "an answer that arrived must not be discarded because the proxy stayed open"
  assert_contains "$out" "turn turn-lingering status inProgress" "the answer the server did send must be reported"
  [ "$elapsed" -lt 15 ] || fail "the answer must be recognised as it arrives, took ${elapsed}s"
  pass "fm-voice-relay-appserver: an answer is recognised as it arrives, not when the proxy exits"
}

# The proxy is started in its own session so it never sees the terminal's SIGINT.
# That makes the driver's own cleanup the only thing standing between an
# interrupted --live call and a proxy left running unattached.
test_an_interrupted_live_call_leaves_no_proxy_running() {
  local server pidfile job kid i alive=1
  pidfile="$TMP_ROOT/interrupt-proxy.pid"
  server="$TMP_ROOT/interrupt-app-server"
  rm -f "$pidfile"
  cat > "$server" <<SH
#!/usr/bin/env bash
echo \$\$ > "$pidfile"
cat > /dev/null
sleep 120
SH
  chmod +x "$server"

  # Job control puts the call in its own process group, so the interrupt below
  # reaches the whole call the way a terminal Ctrl-C would.
  set -m
  FM_VOICE_RELAY_PROXY_CMD="$server" FM_VOICE_RELAY_RPC_TIMEOUT=60 \
    "$APPSERVER" active-turn --thread THREAD-1 --live >/dev/null 2>&1 &
  job=$!
  set +m
  for i in $(seq 1 100); do [ -s "$pidfile" ] && break; sleep 0.1; done
  if [ ! -s "$pidfile" ]; then
    kill -KILL -"$job" 2>/dev/null
    fail "the fake proxy never started"
  fi
  kid=$(cat "$pidfile")

  kill -INT -"$job" 2>/dev/null
  # Bounded well inside the RPC timeout, so a proxy that only dies when the bound
  # expires still fails this test.
  for i in $(seq 1 50); do
    if ! kill -0 "$kid" 2>/dev/null; then alive=0; break; fi
    sleep 0.1
  done
  kill -KILL -"$job" 2>/dev/null
  wait "$job" 2>/dev/null || true
  if [ "$alive" = 1 ]; then
    kill -KILL "$kid" 2>/dev/null
    fail "an interrupted live call left the proxy running"
  fi
  pass "fm-voice-relay-appserver: an interrupted live call still terminates its proxy"
}

# A command string the shell cannot parse is a usage error, not a traceback and
# not an exit status outside the documented set.
test_an_unparseable_proxy_command_is_a_usage_error() {
  local out code
  out=$(FM_VOICE_RELAY_PROXY_CMD="/bin/echo 'unbalanced" \
    "$APPSERVER" active-turn --thread THREAD-1 --live 2>&1) && code=0 || code=$?
  expect_code 2 "$code" "an unparseable proxy command must exit with the documented usage code"
  assert_contains "$out" "not a parseable command line" "the refusal must name what is wrong"
  assert_not_contains "$out" "Traceback" "a malformed command string must never surface a traceback"
  pass "fm-voice-relay-appserver: an unparseable proxy command is refused inside the exit contract"
}

test_probe_reports_the_installed_steering_contract() {
  local out code
  make_schema "$TMP_ROOT/schema-ok" '"turn/steer","turn/interrupt","thread/turns/list","thread/read"'
  out=$(appserver probe --schema-dir "$TMP_ROOT/schema-ok") && code=0 || code=$?
  expect_code 0 "$code" "a complete schema must probe clean"
  assert_contains "$out" "turn/steer           supported" "the probe must name each method it found"
  assert_contains "$out" "required=expectedTurnId,input,threadId" "the probe must show the compare-and-swap parameter"
  assert_contains "$out" "not live proof" "the probe must not be mistaken for live reachability"
  pass "fm-voice-relay-appserver: the probe proves steering support against the installed schema"
}

test_probe_fails_when_the_build_cannot_steer() {
  local out code
  make_schema "$TMP_ROOT/schema-old" '"thread/turns/list","thread/read"'
  out=$(appserver probe --schema-dir "$TMP_ROOT/schema-old") && code=0 || code=$?
  expect_code 4 "$code" "a build without turn/steer must fail the probe"
  assert_contains "$out" "turn/steer           missing" "the probe must name the missing method"
  pass "fm-voice-relay-appserver: a build without the steering methods fails the probe loudly"
}

test_dry_run_prints_the_frames_and_contacts_nothing() {
  local out log
  log="$TMP_ROOT/dry.log"
  out=$(FAKE_SERVER_LOG="$log" appserver steer --thread THREAD-1 --expected-turn TURN-1 --text "left panel instead")
  assert_contains "$out" '"method":"turn/steer"' "a dry run must show the exact method"
  assert_contains "$out" '"expectedTurnId":"TURN-1"' "a dry run must show the turn it would target"
  assert_contains "$out" '"text":"left panel instead"' "a dry run must show the correction text"
  assert_absent "$log" "a dry run must not reach any server"
  pass "fm-voice-relay-appserver: a dry run shows exactly what would be sent and sends nothing"
}

test_steering_requires_the_expected_turn() {
  local out code
  out=$(appserver steer --thread THREAD-1 --text "no target" 2>&1) && code=0 || code=$?
  expect_code 2 "$code" "steering without a target turn must be refused"
  assert_contains "$out" "would land the correction on whatever turn happens to be running" \
    "the refusal must explain the hazard"
  pass "fm-voice-relay-appserver: a steer without an expected turn is refused, not guessed"
}

test_live_steer_lands_on_the_running_turn() {
  local out code
  out=$(FAKE_TURN_ID=turn-42 appserver steer --thread THREAD-1 --expected-turn turn-42 \
    --text "check the right panel instead" --live) && code=0 || code=$?
  expect_code 0 "$code" "a steer at the running turn must succeed"
  assert_contains "$out" "turn-42" "the server's answer must be reported"
  pass "fm-voice-relay-appserver: a correction reaches the turn that is actually running"
}

test_stale_steer_is_refused_by_the_server() {
  local out code
  out=$(FAKE_TURN_ID=turn-99 appserver steer --thread THREAD-1 --expected-turn turn-42 \
    --text "too late" --live 2>&1) && code=0 || code=$?
  expect_code 3 "$code" "a steer at a finished turn must be refused"
  assert_contains "$out" "expectedTurnId does not match" "the server's refusal must be reported verbatim enough to act on"
  pass "fm-voice-relay-appserver: steering a turn that already moved on fails instead of landing elsewhere"
}

test_thread_status_tells_the_truth_about_reachability() {
  local out
  out=$(FAKE_THREAD_STATUS=notLoaded appserver thread-status --thread THREAD-1 --live)
  assert_contains "$out" "steerable: no" "a server without the thread loaded must not look steerable"
  assert_contains "$out" "can read history but does not own the live turn" "the reason must be explicit"

  out=$(FAKE_THREAD_STATUS=active appserver thread-status --thread THREAD-1 --live)
  assert_contains "$out" "reports the thread loaded" "a loaded thread must be reported as possibly steerable"
  assert_contains "$out" "still has to be confirmed on a real turn" "even a loaded thread is not a guarantee"
  pass "fm-voice-relay-appserver: reachability is reported separately from schema support"
}

test_active_turn_reads_the_current_turn() {
  local out
  out=$(FAKE_TURN_ID=turn-7 FAKE_TURN_STATUS=inProgress appserver active-turn --thread THREAD-1 --live)
  assert_contains "$out" "turn turn-7 status inProgress" "the current turn and its status must be reported"
  pass "fm-voice-relay-appserver: the turn to steer can be read before steering it"
}

test_interrupt_is_sent_as_the_protocol_defines_it() {
  local out code
  out=$(appserver interrupt --thread THREAD-1 --turn turn-7 --live) && code=0 || code=$?
  expect_code 0 "$code" "an interrupt must be accepted by the server"
  out=$(appserver interrupt --thread THREAD-1 2>&1) && code=0 || code=$?
  expect_code 2 "$code" "an interrupt without a turn must be refused"
  pass "fm-voice-relay-appserver: interrupting names the exact turn or refuses"
}

# A proxy that accepts the frames and then says nothing used to hang the caller
# for ever, while the header promised a bound. The documented bound has to be a
# real one, and a timeout has to be reported as the transport failure it is.
test_a_silent_server_fails_at_the_documented_bound() {
  local silent out code started elapsed
  silent="$TMP_ROOT/silent-app-server"
  cat > "$silent" <<'SH'
#!/usr/bin/env bash
cat > /dev/null
sleep 120
SH
  chmod +x "$silent"

  started=$(date -u +%s)
  out=$(FM_VOICE_RELAY_PROXY_CMD="$silent" FM_VOICE_RELAY_RPC_TIMEOUT=2 \
    "$APPSERVER" active-turn --thread THREAD-1 --live 2>&1) && code=0 || code=$?
  elapsed=$(( $(date -u +%s) - started ))
  expect_code 5 "$code" "a server that never answers must end as a transport failure"
  assert_contains "$out" "no answer within 2s" "the failure must name the bound it hit"
  [ "$elapsed" -lt 30 ] || fail "the call must be bounded, took ${elapsed}s"

  out=$(FM_VOICE_RELAY_RPC_TIMEOUT=nonsense appserver active-turn --thread THREAD-1 --live 2>&1) && code=0 || code=$?
  expect_code 2 "$code" "an unusable bound must be refused rather than ignored"
  assert_contains "$out" "positive whole number of seconds" "the refusal must say what the value has to be"
  pass "fm-voice-relay-appserver: a live call is bounded and a silent proxy fails instead of hanging"
}

# The limitation is only useful next to the thing to do instead.
test_an_unsteerable_thread_names_the_supported_fallback() {
  local out
  out=$(FAKE_THREAD_STATUS=notLoaded appserver thread-status --thread THREAD-1 --live)
  assert_contains "$out" "fm-voice-relay.sh revise" "the fallback must start by revising the shared request record"
  assert_contains "$out" "queue that correction once through codex queue" "the fallback must name the supported queue path"
  assert_contains "$out" "check-action before acting, present before speaking" \
    "the fallback must name the gates that actually refuse the stale step"
  assert_contains "$out" "queueing alone kills nothing" "the fallback must not imply the queue cancels anything"
  assert_contains "$out" "cannot interrupt an external action already in flight" "the fallback must keep its limits"
  assert_contains "$out" "cannot make the companion pick the correction up promptly" "prompt pickup must not be promised"
  assert_contains "$out" "terminal session or through Herdr" "the human fallback must be named"
  pass "fm-voice-relay-appserver: an unsteerable thread is reported with the fallback to use instead"
}

# Help that stops mid-sentence teaches the caller the wrong exit contract.
test_help_prints_the_whole_exit_code_list() {
  local out last
  out=$(appserver --help)
  assert_contains "$out" "5 transport failure" "--help must reach the end of the exit-code list"
  last=$(printf '%s\n' "$out" | tail -1)
  assert_contains "$last" "transport failure" "--help must not stop part-way through the exit codes"
  pass "fm-voice-relay-appserver: --help prints the complete exit-code list"
}

test_help_prints_the_whole_exit_code_list
test_probe_reports_the_installed_steering_contract
test_probe_fails_when_the_build_cannot_steer
test_dry_run_prints_the_frames_and_contacts_nothing
test_steering_requires_the_expected_turn
test_live_steer_lands_on_the_running_turn
test_stale_steer_is_refused_by_the_server
test_thread_status_tells_the_truth_about_reachability
test_active_turn_reads_the_current_turn
test_interrupt_is_sent_as_the_protocol_defines_it
test_a_silent_server_fails_at_the_documented_bound
test_a_proxy_that_answers_and_stays_open_is_not_a_timeout
test_an_interrupted_live_call_leaves_no_proxy_running
test_an_unparseable_proxy_command_is_a_usage_error
test_an_unsteerable_thread_names_the_supported_fallback
