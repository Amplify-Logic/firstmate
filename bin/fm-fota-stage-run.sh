#!/usr/bin/env bash
# fm-fota-stage-run.sh - background staging runs over a fm.fota-staging-plan.v1.
#
# Turns a staged plan into a real background preparation run: it generates the
# request the browser side executes, records the run durably, and reports one
# honest state. It NEVER sends a device command and holds no approval authority.
#
# Four states, kept distinct on purpose:
#   pending  request generated and dispatched; no result yet
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
# Duplicate protection is by operation identity, not by wall time: a second
# start for an idempotency key that already has a live or ready run is refused
# with a named reason rather than quietly producing a second request.
#
# Commands:
#   start <plan.json> [--deadline <seconds>]   generate, dispatch, record pending
#   settle <run-id>                            read the result, decide the state
#   status <run-id>                            print the current state
#   show <run-id>                              print the full run record
#   list [--json]                              print all runs, newest first
#   -h|--help
#
# Environment:
#   FM_HOME / FM_STATE_OVERRIDE  - home and state roots
#   FM_FOTA_RETURN_DIR           - where the browser side writes its result
#   FM_FOTA_DEADLINE             - default deadline seconds (default 300)
#
# Exit:
#   0 on success; 1 on usage, a missing plan, a duplicate operation, or an
#   unreadable run record. `settle` exits 0 whatever state it decides - an
#   honest `unknown` is a successful determination, not a script failure.
set -eu

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-$FM_ROOT}"
STATE="${FM_STATE_OVERRIDE:-$FM_HOME/state}"
RUNS="$STATE/fota-staging"
RETURN_DIR="${FM_FOTA_RETURN_DIR:-$FM_HOME/data/desktop-companion}"
DEADLINE="${FM_FOTA_DEADLINE:-300}"

usage() {
  cat <<'EOF' >&2
usage: fm-fota-stage-run.sh start <plan.json> [--deadline <seconds>]
       fm-fota-stage-run.sh settle <run-id>
       fm-fota-stage-run.sh status <run-id>
       fm-fota-stage-run.sh show <run-id>
       fm-fota-stage-run.sh list [--json]

Background staging runs over a staged plan. Stages and verifies only:
never sends a device command, never approves, never retries a send.
States: pending | ready | error | unknown.
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
      --deadline) deadline=${2:-} ; shift 2 ;;
      *) usage ;;
    esac
  done
  [ -n "$plan" ] || usage
  [ -f "$plan" ] || die "plan not found: $plan"
  mkdir -p "$RUNS" "$RETURN_DIR"
  chmod 700 "$RUNS" 2>/dev/null || true
  RUNS="$RUNS" RETURN_DIR="$RETURN_DIR" DEADLINE="$deadline" PLAN="$plan" py - <<'PYSTART'
import json, os, sys, time

runs, return_dir = os.environ["RUNS"], os.environ["RETURN_DIR"]
plan = json.load(open(os.environ["PLAN"], encoding="utf-8"))
if plan.get("schema") != "fm.fota-staging-plan.v1":
    sys.exit("fm-fota-stage-run: not a fm.fota-staging-plan.v1 plan")

key = plan["operation"]["idempotency_key"]

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
    if existing.get("idempotency_key") == key and existing.get("state") in {"pending", "ready"}:
        sys.exit(
            "fm-fota-stage-run: operation already has a %s run (%s); "
            "raise the attempt ordinal to stage a deliberate retry"
            % (existing["state"], existing["run_id"])
        )

run_id = "%s-%d" % (key, int(time.time()))
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
with open(request_path, "w", encoding="utf-8") as handle:
    handle.write(request)

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
    "state": "pending",
    "started_at": int(time.time()),
    "deadline_seconds": int(os.environ["DEADLINE"]),
    "request_path": request_path,
    "result_path": result_path,
    "sent": False,
    "approval": "not-granted; staging does not approve or send",
}
path = os.path.join(runs, run_id + ".json")
with open(path, "w", encoding="utf-8") as handle:
    json.dump(record, handle, indent=2, sort_keys=True)
    handle.write("\n")
os.chmod(path, 0o600)
print("run_id=%s" % run_id)
print("state=pending")
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
import json, os, time

path = os.environ["RECORD"]
record = json.load(open(path, encoding="utf-8"))
if record["state"] != "pending":
    print("run_id=%s" % record["run_id"])
    print("state=%s" % record["state"])
    print("note=already settled")
    raise SystemExit(0)

def settle(state, reason, **extra):
    record["state"] = state
    record["reason"] = reason
    record["settled_at"] = int(time.time())
    record.update(extra)
    with open(path, "w", encoding="utf-8") as handle:
        json.dump(record, handle, indent=2, sort_keys=True)
        handle.write("\n")
    print("run_id=%s" % record["run_id"])
    print("state=%s" % state)
    print("reason=%s" % reason)
    raise SystemExit(0)

result_path = record["result_path"]
if not os.path.exists(result_path):
    elapsed = int(time.time()) - record["started_at"]
    if elapsed < record["deadline_seconds"]:
        print("run_id=%s" % record["run_id"])
        print("state=pending")
        print("reason=no result yet, %ss of %ss elapsed"
              % (elapsed, record["deadline_seconds"]))
        raise SystemExit(0)
    # Deadline passed with nothing written. Nothing was observed, so nothing is
    # known - which is not the same as knowing nothing happened.
    settle("unknown", "no result inside the deadline; verify at the portal")

try:
    result = json.load(open(result_path, encoding="utf-8"))
except (OSError, json.JSONDecodeError) as exc:
    settle("unknown", "result could not be read: %s" % exc)

# The result file is untrusted input written by the browser side. It is
# evidence only where it reports something it actually read back.
if result.get("request_id") != record["run_id"]:
    settle("unknown", "result does not carry this run's id; not attributable")

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
  status) cmd_status "$@" ;;
  show) cmd_show "$@" ;;
  list) cmd_list "$@" ;;
  -h|--help) usage ;;
  *) usage ;;
esac
