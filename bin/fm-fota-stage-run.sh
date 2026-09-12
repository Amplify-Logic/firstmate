#!/usr/bin/env bash
# fm-fota-stage-run.sh - background staging runs over a fm.fota-staging-plan.v1.
#
# Turns a staged plan into a real background preparation run: it generates the
# request the browser side executes, records the run durably, and reports one
# honest state. It NEVER sends a device command and holds no approval authority.
#
# Four facts are kept distinct and are never collapsed into one another:
#   prepared       the request file was generated from the plan
#   queue accepted the documented transport (`codex queue --thread`) returned a
#                  receipt; the receipt is stored on the record
#   pickup         the companion actually began - only ever inferred from a
#                  result file appearing, never from a queue receipt
#   verified       a result arrived AND its readback matched this plan
#
# Accepted is not pickup, and pickup is not completion. A queue receipt proves
# the message was enqueued and nothing more.
#
# Five states, kept distinct on purpose:
#   prepared request generated, but the transport did not take it (none
#            configured, none installed, or a non-zero queue exit). Nothing was
#            enqueued; a person has to look. Never silently re-queued.
#   pending  the transport took it, or timed out without telling us whether it
#            did; no result yet
#   ready    a result arrived AND its readback matched this plan's target and
#            payload; the draft is staged and awaiting the separate approval
#   error    the result reported a definite failure, or its readback definitely
#            contradicted the plan
#   unknown  no result inside the deadline, an unreadable result, or a result
#            that asserts success without the readback to support it
#
# `unknown` is deliberately not a failure. It means the world was not observed,
# which is different from observing that nothing happened, and the two must not
# be collapsed - a preparation whose outcome is unobserved is verified at the
# portal by a person, never retried automatically by this script.
#
# Duplicate protection is by operation identity, not by wall time, and it covers
# the queue step: a second start for an idempotency key that already has a
# prepared, live, or ready run is refused with a named reason rather than
# quietly producing - or enqueueing - a second request.
#
# Commands:
#   start <plan.json> [--deadline <seconds>]   generate, queue, record the state
#   settle <run-id>                            read the result, decide the state
#   ack <run-id> [--note <text>]               explicit captain acknowledgement
#   status <run-id>                            print the current state
#   show <run-id>                              print the full run record
#   list [--json]                              print all runs, newest first
#   -h|--help
#
# `ack` records that the captain has seen a settled preparation alert, so the
# deck can drop it from the active ask list. It never deletes a record, never
# changes an outcome, never marks a command applied, and never expires anything
# on a timer: an `unknown` stays `unknown` forever because that IS the evidence.
#
# Environment:
#   FM_HOME / FM_STATE_OVERRIDE  - home and state roots
#   FM_FOTA_RETURN_DIR           - where the browser side writes its result
#   FM_FOTA_DEADLINE             - default deadline seconds (default 300)
#   FM_FOTA_COMPANION_THREAD     - companion thread identity; otherwise read
#                                  from <return dir>/connection.json
#   FM_FOTA_QUEUE_CMD            - transport command (default `codex`), so a
#                                  test can inject an isolated stub and this
#                                  worker never reaches a shared companion
#   FM_FOTA_QUEUE_TIMEOUT        - queue call timeout seconds (default 30)
#
# Exit:
#   0 on success; 1 on usage, a missing plan, a duplicate operation, or an
#   unreadable run record. `settle` exits 0 whatever state it decides - an
#   honest `unknown` is a successful determination, not a script failure. A
#   transport that refuses is likewise a determination, not a script failure.
set -eu

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-$FM_ROOT}"
STATE="${FM_STATE_OVERRIDE:-$FM_HOME/state}"
RUNS="$STATE/fota-staging"
RETURN_DIR="${FM_FOTA_RETURN_DIR:-$FM_HOME/data/desktop-companion}"
DEADLINE="${FM_FOTA_DEADLINE:-300}"
QUEUE_CMD="${FM_FOTA_QUEUE_CMD:-codex}"
QUEUE_TIMEOUT="${FM_FOTA_QUEUE_TIMEOUT:-30}"

usage() {
  cat <<'EOF' >&2
usage: fm-fota-stage-run.sh start <plan.json> [--deadline <seconds>]
       fm-fota-stage-run.sh settle <run-id>
       fm-fota-stage-run.sh ack <run-id> [--note <text>]
       fm-fota-stage-run.sh status <run-id>
       fm-fota-stage-run.sh show <run-id>
       fm-fota-stage-run.sh list [--json]

Background staging runs over a staged plan. Stages and verifies only:
never sends a device command, never approves, never retries a send.
States: prepared | pending | ready | error | unknown.
EOF
  exit 1
}

die() { printf 'fm-fota-stage-run: %s\n' "$1" >&2; exit 1; }

py() { python3 "$@"; }

cmd_start() {
  local plan=${1:-}
  shift || true
  local deadline=$DEADLINE
  while [ $# -gt 0 ]; do
    case "$1" in
      --deadline)
        [ $# -ge 2 ] || die "--deadline needs a value"
        deadline=$2
        # Validated here so a bad value fails with this script's own message
        # rather than a Python traceback from the record writer.
        case "$deadline" in
          ''|*[!0-9]*) die "--deadline must be a non-negative integer: $deadline" ;;
        esac
        shift 2
        ;;
      *) usage ;;
    esac
  done
  [ -n "$plan" ] || usage
  [ -f "$plan" ] || die "plan not found: $plan"
  mkdir -p "$RUNS" "$RETURN_DIR"
  # The generated request carries the same target, payload and operation
  # identity the record does, so it gets the same treatment.
  chmod 700 "$RUNS" "$RETURN_DIR" 2>/dev/null || true
  RUNS="$RUNS" RETURN_DIR="$RETURN_DIR" DEADLINE="$deadline" PLAN="$plan" \
    QUEUE_CMD="$QUEUE_CMD" QUEUE_TIMEOUT="$QUEUE_TIMEOUT" py - <<'PYSTART'
import json, os, re, subprocess, sys, time

runs, return_dir = os.environ["RUNS"], os.environ["RETURN_DIR"]
plan = json.load(open(os.environ["PLAN"], encoding="utf-8"))
if plan.get("schema") != "fm.fota-staging-plan.v1":
    sys.exit("fm-fota-stage-run: not a fm.fota-staging-plan.v1 plan")

key = plan["operation"]["idempotency_key"]

# The duplicate guard covers the queue step too. `prepared` counts as live: its
# request exists and may already have reached the companion, so re-running it
# would risk a second delivery of one intent.
LIVE_STATES = {"prepared", "pending", "ready"}

# Duplicate protection by operation identity. A second start for an operation
# that already has a live or ready run would produce a second request for the
# same intent, which is how one click becomes two.
for name in sorted(os.listdir(runs)):
    if not name.endswith(".json"):
        continue
    try:
        existing = json.load(open(os.path.join(runs, name), encoding="utf-8"))
    except (OSError, json.JSONDecodeError):
        continue
    if existing.get("idempotency_key") == key and existing.get("state") in LIVE_STATES:
        sys.exit(
            "fm-fota-stage-run: operation already has a %s run (%s); "
            "raise the attempt ordinal to stage a deliberate retry"
            % (existing["state"], existing["run_id"])
        )

# A run id unique to the second is not unique: two starts of one operation in
# the same second would collide, overwrite a settled record and its evidence,
# and read the previous run's result file as this run's readback - which its own
# request_id check cannot catch, because the id would be byte-identical. The
# record file is claimed with O_EXCL, so the id a run holds is the id no other
# run can hold, and a settled record is never written over.
base = "%s-%d" % (key, int(time.time()))
run_id = record_fd = record_path = None
for ordinal in range(1, 1000):
    candidate = base if ordinal == 1 else "%s-%d" % (base, ordinal)
    path = os.path.join(runs, candidate + ".json")
    try:
        fd = os.open(path, os.O_CREAT | os.O_EXCL | os.O_WRONLY, 0o600)
    except FileExistsError:
        continue
    # A leftover result file from a deleted record must never be read back as
    # this run's evidence, so an id whose return slot is already occupied is
    # released rather than reused.
    if os.path.exists(os.path.join(return_dir, candidate + "-result.json")):
        os.close(fd)
        os.unlink(path)
        continue
    run_id, record_fd, record_path = candidate, fd, path
    break
if run_id is None:
    sys.exit("fm-fota-stage-run: could not claim a free run id for %s" % key)

result_path = os.path.join(return_dir, run_id + "-result.json")
request_path = os.path.join(return_dir, run_id + "-request.md")

# The request is GENERATED from the approved plan, never hand-written prose.
# It carries the operation identity, the exact target, an origin allowlist the
# browser side is told to stay inside, and the readback this run will verify.
origin = (plan.get("adapter") or {}).get("origin") or plan.get("origin") or ""
request = """# Generated staging request - form preparation only

Run id: {run_id}
Operation: {key}
Target device: {device}
Allowed origin: {origin}

Prepare ONLY. Do not press the send control. Do not press any other preset,
apply, or refresh control. Do not navigate outside the allowed origin.

1. Open the target device page and read back its identifier from the page.
   The page supplies the target, so a page that is not this device is the
   wrong target: stop and report the mismatch rather than staging into it.
2. Stage this exact payload into the command field:

{payload}

3. Read the field back once, authoritatively, and report exactly what it holds.
   Do not add a second redundant check: a redundant check that times out turns
   a completed preparation into a misleading failure.
4. Clear the draft and close only your own tab.

Write {result_name} containing: request_id set to the run id above, the
observed device identifier, the exact staged payload you read back, whether the
send control was pressed (it must be false), and any exact error.
""".format(
    run_id=run_id, key=key, device=plan["target"]["device_id"],
    origin=origin or "(declared by the local adapter)",
    payload=plan["payload"], result_name=os.path.basename(result_path),
)
fd = os.open(request_path, os.O_CREAT | os.O_TRUNC | os.O_WRONLY, 0o600)
with os.fdopen(fd, "w", encoding="utf-8") as handle:
    handle.write(request)
os.chmod(request_path, 0o600)


def companion_thread():
    """The explicitly configured companion, or nothing.

    Nothing is an honest answer: with no configured thread this worker queues
    into no session at all, which is what keeps it away from a shared companion
    it was never pointed at.
    """
    explicit = (os.environ.get("FM_FOTA_COMPANION_THREAD") or "").strip()
    if explicit:
        return explicit, "FM_FOTA_COMPANION_THREAD"
    path = os.path.join(return_dir, "connection.json")
    try:
        with open(path, encoding="utf-8") as handle:
            connection = json.load(handle)
    except (OSError, json.JSONDecodeError):
        return "", ""
    if not isinstance(connection, dict):
        return "", ""
    if connection.get("schema") != "fm.desktop-companion-connection.v1":
        return "", ""
    thread = str(connection.get("thread") or "").strip()
    return (thread, path) if thread else ("", "")


def queue_receipt(text):
    """The receipt the transport printed, correlated to this run by its id."""
    output = (text or "").strip()
    if not output:
        return None
    match = re.search(
        r"(?:message[_-]?id|msg[_-]?id|\bid)\s*[=:]\s*([A-Za-z0-9._:-]+)", output
    )
    if match:
        return match.group(1)
    return output.splitlines()[-1].strip()[:200]


# The documented supported transport, and only it: `codex queue --thread` per
# docs/desktop-companion.md. A receipt proves the message was ENQUEUED. It does
# not prove pickup and it certainly does not prove the work happened, so it is
# recorded as its own fact rather than folded into the run's state.
thread, thread_source = companion_thread()
message = (
    "Request {run_id}: read {request} and follow it. Prepare only - do not press "
    "the send control. When done, write {result} including request_id {run_id}, "
    "the real timestamp, the observed device identifier, the exact payload you "
    "read back, and whether the send control was pressed (it must be false). "
    "Then read that file back."
).format(run_id=run_id, request=request_path, result=result_path)

queue = {
    "transport": "codex queue --thread",
    "command": os.environ["QUEUE_CMD"],
    "thread": thread,
    "thread_source": thread_source,
    "correlation_id": run_id,
    "attempted": False,
    "accepted": False,
    "receipt": None,
    "queued_at": None,
    "outcome": "not-configured",
    "reason": (
        "no companion thread is configured; set FM_FOTA_COMPANION_THREAD or write "
        "%s. The request was generated but nothing was enqueued."
        % os.path.join(return_dir, "connection.json")
    ),
}

if thread:
    queue["attempted"] = True
    try:
        completed = subprocess.run(
            [queue["command"], "queue", "--thread", thread, "--message", message],
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            timeout=float(os.environ["QUEUE_TIMEOUT"]),
        )
    except FileNotFoundError:
        queue["outcome"] = "not-installed"
        queue["reason"] = "transport %r is not installed" % queue["command"]
    except subprocess.TimeoutExpired:
        # The one genuinely ambiguous case: the message may or may not have been
        # enqueued. It is never sent again on that doubt.
        queue["outcome"] = "timeout"
        queue["reason"] = (
            "queue timed out after %ss; whether it was enqueued is unobserved, so "
            "this run is never queued again" % os.environ["QUEUE_TIMEOUT"]
        )
    else:
        stdout = completed.stdout.decode("utf-8", "replace")
        stderr = completed.stderr.decode("utf-8", "replace")
        if completed.returncode != 0:
            queue["outcome"] = "refused"
            queue["reason"] = "queue exited %d: %s" % (
                completed.returncode,
                (stderr.strip() or stdout.strip() or "no output")[:400],
            )
        else:
            queue["accepted"] = True
            queue["outcome"] = "accepted"
            queue["receipt"] = queue_receipt(stdout)
            queue["queued_at"] = int(time.time())
            queue["reason"] = (
                "enqueued; a receipt is not pickup and pickup is not completion"
            )

# `pending` means the transport has it, or timed out holding it. `prepared`
# means it plainly does not: the request exists and a person has to carry it.
state = "pending" if queue["outcome"] in {"accepted", "timeout"} else "prepared"

record = {
    "schema": "fm.fota-staging-run.v1",
    "run_id": run_id,
    "idempotency_key": key,
    "operation_fingerprint": plan["operation"]["operation_fingerprint"],
    "attempt": plan["operation"]["attempt"],
    "action_kind": plan["operation"]["action_kind"],
    "device_id": plan["target"]["device_id"],
    "expected_payload": plan["payload"],
    "preview_hash": plan["preview_hash"],
    "eligibility": plan["eligibility"]["state"],
    "state": state,
    "started_at": int(time.time()),
    "deadline_seconds": int(os.environ["DEADLINE"]),
    "request_path": request_path,
    "result_path": result_path,
    "queue": queue,
    # Pickup is never inferred from a receipt. Only a result file appearing is
    # evidence the companion actually began a turn on this request.
    "pickup_observed": False,
    "sent": False,
    "approval": "not-granted; staging does not approve or send",
}
with os.fdopen(record_fd, "w", encoding="utf-8") as handle:
    json.dump(record, handle, indent=2, sort_keys=True)
    handle.write("\n")
os.chmod(record_path, 0o600)
print("run_id=%s" % run_id)
print("state=%s" % state)
print("queue=%s" % queue["outcome"])
if queue["receipt"]:
    print("receipt=%s" % queue["receipt"])
else:
    print("queue_reason=%s" % queue["reason"])
print("request=%s" % request_path)
print("awaiting=%s" % result_path)
PYSTART
}

cmd_settle() {
  local run_id=${1:-}
  [ -n "$run_id" ] || usage
  local path="$RUNS/$run_id.json"
  [ -f "$path" ] || die "unknown run: $run_id"
  RECORD="$path" py - <<'PYSETTLE'
import json, os, tempfile, time

path = os.environ["RECORD"]
record = json.load(open(path, encoding="utf-8"))
result_path = record["result_path"]
result_present = os.path.exists(result_path)

# `prepared` is not settled - the transport never took the request - but a
# result that arrives anyway (a person carried the request over) is still
# evidence, and reading it is pure observation.
if record["state"] not in {"pending", "prepared"}:
    print("run_id=%s" % record["run_id"])
    print("state=%s" % record["state"])
    print("note=already settled")
    raise SystemExit(0)
if record["state"] == "prepared" and not result_present:
    print("run_id=%s" % record["run_id"])
    print("state=prepared")
    print("reason=%s" % (record.get("queue") or {}).get("reason", "never queued"))
    raise SystemExit(0)

def write_record():
    # Written whole and moved into place: a crash partway through a truncating
    # rewrite would leave JSON the deck's parser skips, and an unresolved ask
    # would vanish from the pane rather than showing up as unreadable.
    directory = os.path.dirname(path) or "."
    handle = tempfile.NamedTemporaryFile(
        mode="w", encoding="utf-8", dir=directory, prefix=".settle-",
        suffix=".json", delete=False,
    )
    try:
        with handle:
            json.dump(record, handle, indent=2, sort_keys=True)
            handle.write("\n")
            handle.flush()
            os.fsync(handle.fileno())
        os.chmod(handle.name, 0o600)
        os.replace(handle.name, path)
    except BaseException:
        if os.path.exists(handle.name):
            os.unlink(handle.name)
        raise

def settle(state, reason, **extra):
    record["state"] = state
    record["reason"] = reason
    record["settled_at"] = int(time.time())
    record.update(extra)
    write_record()
    print("run_id=%s" % record["run_id"])
    print("state=%s" % state)
    print("reason=%s" % reason)
    raise SystemExit(0)

if not result_present:
    elapsed = int(time.time()) - record["started_at"]
    if elapsed < record["deadline_seconds"]:
        print("run_id=%s" % record["run_id"])
        print("state=pending")
        print("reason=no result yet, %ss of %ss elapsed"
              % (elapsed, record["deadline_seconds"]))
        raise SystemExit(0)
    # Deadline passed with nothing written. Nothing was observed, so nothing is
    # known - which is not the same as knowing nothing happened. A queue receipt
    # does not soften that: accepted was never pickup.
    settle("unknown", "no result inside the deadline; verify at the portal")

try:
    result = json.load(open(result_path, encoding="utf-8"))
except (OSError, json.JSONDecodeError) as exc:
    settle("unknown", "result could not be read: %s" % exc)

# The result file is untrusted input written by the browser side. It is
# evidence only where it reports something it actually read back.
if result.get("request_id") != record["run_id"]:
    settle("unknown", "result does not carry this run's id; not attributable")

# A result carrying this run's id means the companion did begin a turn on this
# request. That is pickup, and it is a different fact from what the result says.
record["pickup_observed"] = True

if result.get("sent") is True or result.get("command_sent") is True:
    # Staging must never send. If a result says it did, that is a definite
    # contradiction of the contract and is never quietly accepted.
    settle("error", "result reports a command was sent; staging must not send",
           contract_violation=True)

if result.get("error"):
    settle("error", "browser side reported: %s" % result["error"])

observed_device = result.get("observed_device_id") or result.get("observed_device_heading")
observed_payload = result.get("observed_payload") or result.get("exact_draft_payload")

# `ready` requires an independent readback that matches this plan. A result that
# asserts success without the readback to support it settles unknown, never ready.
if not observed_device or not observed_payload:
    settle("unknown",
           "result asserts an outcome without a readback of the target and payload")

if observed_device != record["device_id"]:
    settle("error",
           "readback target %r is not this plan's target %r"
           % (observed_device, record["device_id"]),
           observed_device_id=observed_device)

def normalize(text):
    # Compare what the payload MEANS, not how the field spaced it.
    try:
        return json.dumps(json.loads(text), sort_keys=True, separators=(",", ":"))
    except (TypeError, ValueError):
        return None

want, got = normalize(record["expected_payload"]), normalize(observed_payload)
if got is None:
    settle("unknown", "readback payload was not parseable; staged content unconfirmed")
if want != got:
    settle("error", "readback payload does not match the staged plan",
           observed_payload=observed_payload)

settle("ready", "readback matched the staged target and payload",
       observed_device_id=observed_device, observed_payload=observed_payload)
PYSETTLE
}

cmd_ack() {
  local run_id=${1:-}
  shift || true
  local note=""
  while [ $# -gt 0 ]; do
    case "$1" in
      --note)
        [ $# -ge 2 ] || die "--note needs a value"
        note=$2
        shift 2
        ;;
      *) usage ;;
    esac
  done
  [ -n "$run_id" ] || usage
  local path="$RUNS/$run_id.json"
  [ -f "$path" ] || die "unknown run: $run_id"
  RECORD="$path" NOTE="$note" py - <<'PYACK'
import json, os, tempfile, time

path = os.environ["RECORD"]
record = json.load(open(path, encoding="utf-8"))

# Acknowledgement is the captain saying "I have seen this", nothing more. It is
# refused on a run that is still live or still awaiting his approval, because
# those are not alerts he can be finished with.
if record["state"] in {"pending", "ready"}:
    raise SystemExit(
        "fm-fota-stage-run: run %s is %s; only a settled preparation alert can "
        "be acknowledged" % (record["run_id"], record["state"])
    )

if record.get("acknowledged_at"):
    print("run_id=%s" % record["run_id"])
    print("state=%s" % record["state"])
    print("note=already acknowledged")
    raise SystemExit(0)

# The outcome, the reason, the evidence paths and the queue receipt are left
# exactly as they were. Nothing is deleted, nothing is marked applied, and an
# `unknown` stays `unknown` - it exists to preserve that nothing was observed.
record["acknowledged_at"] = int(time.time())
record["acknowledged_note"] = os.environ.get("NOTE") or ""

directory = os.path.dirname(path) or "."
handle = tempfile.NamedTemporaryFile(
    mode="w", encoding="utf-8", dir=directory, prefix=".ack-", suffix=".json",
    delete=False,
)
try:
    with handle:
        json.dump(record, handle, indent=2, sort_keys=True)
        handle.write("\n")
        handle.flush()
        os.fsync(handle.fileno())
    os.chmod(handle.name, 0o600)
    os.replace(handle.name, path)
except BaseException:
    if os.path.exists(handle.name):
        os.unlink(handle.name)
    raise

print("run_id=%s" % record["run_id"])
print("state=%s" % record["state"])
print("acknowledged=true")
print("record=%s" % path)
PYACK
}

cmd_status() {
  local run_id=${1:-}
  [ -n "$run_id" ] || usage
  local path="$RUNS/$run_id.json"
  [ -f "$path" ] || die "unknown run: $run_id"
  RECORD="$path" py -c '
import json, os
r = json.load(open(os.environ["RECORD"], encoding="utf-8"))
print("run_id=%s" % r["run_id"])
print("state=%s" % r["state"])
print("device=%s" % r["device_id"])
print("eligibility=%s" % r["eligibility"])
print("sent=%s" % ("true" if r.get("sent") else "false"))
queue = r.get("queue") or {}
print("queue=%s" % queue.get("outcome", "unrecorded"))
if queue.get("receipt"):
    print("receipt=%s" % queue["receipt"])
print("pickup_observed=%s" % ("true" if r.get("pickup_observed") else "false"))
if r.get("acknowledged_at"):
    print("acknowledged=true")
if r.get("reason"):
    print("reason=%s" % r["reason"])
'
}

cmd_show() {
  local run_id=${1:-}
  [ -n "$run_id" ] || usage
  local path="$RUNS/$run_id.json"
  [ -f "$path" ] || die "unknown run: $run_id"
  cat "$path"
}

cmd_list() {
  local as_json=0
  [ "${1:-}" = "--json" ] && as_json=1
  if [ ! -d "$RUNS" ]; then
    [ "$as_json" = 1 ] && printf '%s\n' '[]' || echo "no staging runs"
    return 0
  fi
  RUNS_DIR="$RUNS" AS_JSON="$as_json" py -c '
import json, os
runs = os.environ["RUNS_DIR"]
rows = []
for name in os.listdir(runs):
    if name.endswith(".json"):
        try:
            rows.append(json.load(open(os.path.join(runs, name), encoding="utf-8")))
        except (OSError, json.JSONDecodeError):
            # A record this parser cannot read is skipped, never guessed at:
            # the deck would rather show one run fewer than invent its state.
            continue
rows.sort(key=lambda x: x.get("started_at", 0), reverse=True)
if os.environ["AS_JSON"] == "1":
    print(json.dumps([
        {
            "run_id": r.get("run_id"),
            "state": r.get("state"),
            "device_id": r.get("device_id"),
            "attempt": r.get("attempt"),
            "eligibility": r.get("eligibility"),
            "started_at": r.get("started_at"),
            "reason": r.get("reason"),
            "sent": bool(r.get("sent")),
            "queue": (r.get("queue") or {}).get("outcome"),
            "pickup_observed": bool(r.get("pickup_observed")),
            # An acknowledged alert is still a record and still evidence; this
            # only tells a surface it is no longer an open ask.
            "acknowledged": bool(r.get("acknowledged_at")),
        }
        for r in rows
    ]))
else:
    for r in rows:
        print("%s\t%s\t%s\tattempt %s" % (r["run_id"], r["state"], r["device_id"], r.get("attempt")))
'
}

[ $# -ge 1 ] || usage
command=$1
shift
case "$command" in
  start) cmd_start "$@" ;;
  settle) cmd_settle "$@" ;;
  ack) cmd_ack "$@" ;;
  status) cmd_status "$@" ;;
  show) cmd_show "$@" ;;
  list) cmd_list "$@" ;;
  -h|--help) usage ;;
  *) usage ;;
esac
