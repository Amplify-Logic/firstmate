#!/usr/bin/env bash
# fm-action-gateway.sh - confirm-first outward-action broker (no execution).
#
# Single choke-point for ActionRequests. This slice is a REAL broker design:
# transactional state machine, canonical action digests, digest-bound one-shot
# approvals, and non-graduatable hard ceilings for spend + real-person messaging.
# Execution remains stubbed: the broker emits decisions and durable records only.
# It never performs an outward side effect (no network, mail, payment, or device
# commands). Schema and contract: docs/action-gateway.md.
#
# Commands:
#   prepare [--file <path>]     validate request, append prepared, emit confirm-first
#   approve --digest H --token T
#   execute --digest H          stub only: approved -> executing -> unknown
#   status  --digest H          replay log; print current state for digest
#   replay                      rebuild all states; crash-safe confirm-first default
#   -h|--help
#
# Default (no command, stdin or --file): prepare.
#
# Environment:
#   FM_HOME / FM_DATA_OVERRIDE - home and data roots
#   FM_ACTION_AUDIT_LOG - override append-only audit/state log path (tests)
#   FM_ACTION_GATEWAY_NOW - override unix epoch for expiry tests
#
# Exit:
#   0 on success (decision/state printed after durable append when required)
#   1 on usage, schema, policy, digest, replay, or audit failure
set -eu

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_ROOT}}"
DATA="${FM_DATA_OVERRIDE:-$FM_HOME/data}"

usage() {
  cat <<'EOF' >&2
usage: fm-action-gateway.sh prepare [--file <path>]
       fm-action-gateway.sh approve --digest <hex> --token <token>
       fm-action-gateway.sh execute --digest <hex>
       fm-action-gateway.sh status --digest <hex>
       fm-action-gateway.sh replay
       fm-action-gateway.sh -h|--help

Confirm-first action broker: validate ActionRequest, bind approvals to a
canonical digest, enforce non-graduatable spend/messaging ceilings, and record
a crash-safe transactional state machine. Never executes an outward action.
Schema and contract: docs/action-gateway.md.
EOF
}

fail() {
  printf 'fm-action-gateway: %s\n' "$*" >&2
  exit 1
}

audit_log_path() {
  if [ -n "${FM_ACTION_AUDIT_LOG:-}" ]; then
    printf '%s\n' "$FM_ACTION_AUDIT_LOG"
    return 0
  fi
  printf '%s\n' "$DATA/action-audit.log"
}

# Broker core (validate, digest, ceilings, state machine, crash replay).
# Args: <audit_path> <now_override_or_empty> <command_json>
# Prints key=value result lines on stdout; non-zero + stderr on failure.
broker_py() {
  local audit_path=$1
  local now_override=${2:-}
  local cmd_json=$3
  python3 - "$audit_path" "$now_override" "$cmd_json" <<'PY'
import hashlib
import json
import os
import re
import secrets
import sys
import time
import uuid

AUDIT_PATH = sys.argv[1]
NOW_OVERRIDE = sys.argv[2] if len(sys.argv) > 2 else ""
CMD_JSON = sys.argv[3] if len(sys.argv) > 3 else ""

# Non-graduatable hard ceilings. Consent tiers / watchdog MUST NOT raise these.
SPEND_KINDS = frozenset({
    "purchase",
    "payment",
    "spend",
    "transfer",
    "checkout",
})
MESSAGING_KINDS = frozenset({
    "email.send",
    "message.send",
    "sms.send",
    "chat.send",
    "notify.person",
    "outreach.send",
})
ALLOWED_TIERS = frozenset({"confirm-first", "autonomous", "sandbox"})
REQUIRED = (
    "task_id",
    "domain",
    "action_kind",
    "target",
    "parameters",
    "requested_consent_tier",
    "environment",
    "policy_version",
    "idempotency_key",
    "expires_at",
    "nonce",
)
TERMINAL = frozenset({"succeeded", "failed", "unknown"})
VALID_STATES = frozenset(
    {"prepared", "approved", "executing", "succeeded", "failed", "unknown"}
)


def fail(msg: str, code: int = 1) -> None:
    print(f"fm-action-gateway: {msg}", file=sys.stderr)
    sys.exit(code)


def now_ts() -> int:
    if NOW_OVERRIDE not in ("", None):
        return int(NOW_OVERRIDE)
    env = os.environ.get("FM_ACTION_GATEWAY_NOW", "").strip()
    if env:
        return int(env)
    return int(time.time())


def canonical_json(obj) -> str:
    return json.dumps(obj, separators=(",", ":"), sort_keys=True, ensure_ascii=False)


def extract_amount(params: dict):
    for key in ("amount_cents", "amount", "price_cents", "value_cents"):
        if key in params:
            return params[key]
    return None


def extract_recipient(params: dict):
    for key in ("recipient", "to", "email", "phone", "address"):
        if key in params:
            return params[key]
    return None


def classify_ceiling(action_kind: str, params: dict):
    """Return 'spend', 'messaging', or None. Floor cannot be raised later."""
    if action_kind in SPEND_KINDS or extract_amount(params) is not None:
        return "spend"
    if action_kind in MESSAGING_KINDS or (
        extract_recipient(params) is not None
        and action_kind.startswith(("email.", "message.", "sms.", "chat.", "notify.", "outreach."))
    ):
        return "messaging"
    return None


def digest_payload(req: dict) -> dict:
    params = req["parameters"]
    return {
        "amount": extract_amount(params),
        "environment": req["environment"],
        "expires_at": req["expires_at"],
        "idempotency_key": req["idempotency_key"],
        "nonce": req["nonce"],
        "operation": req["action_kind"],
        "parameters": params,
        "policy_version": req["policy_version"],
        "recipient": extract_recipient(params),
        "target": req["target"],
    }


def action_digest(req: dict) -> str:
    raw = canonical_json(digest_payload(req)).encode("utf-8")
    return hashlib.sha256(raw).hexdigest()


def validate_request(obj):
    if not isinstance(obj, dict):
        fail("ActionRequest must be a JSON object")
    missing = [k for k in REQUIRED if k not in obj]
    if missing:
        fail("missing fields: " + ", ".join(missing))
    unknown = sorted(set(obj) - set(REQUIRED))
    if unknown:
        fail("unknown fields: " + ", ".join(unknown))

    task_id = obj["task_id"]
    if (
        not isinstance(task_id, str)
        or not re.fullmatch(r"[A-Za-z0-9._-]{1,64}", task_id)
        or re.fullmatch(r"\.+", task_id)
    ):
        fail("task_id must be 1-64 chars from [A-Za-z0-9._-] and not dots-only")

    for key in (
        "domain",
        "action_kind",
        "target",
        "requested_consent_tier",
        "environment",
        "policy_version",
        "idempotency_key",
        "nonce",
    ):
        val = obj[key]
        if not isinstance(val, str) or not val.strip():
            fail(f"{key} must be a non-empty string")

    if not isinstance(obj["parameters"], dict):
        fail("parameters must be a JSON object")

    if obj["requested_consent_tier"] not in ALLOWED_TIERS:
        fail(
            "requested_consent_tier must be one of: "
            + ", ".join(sorted(ALLOWED_TIERS))
        )

    exp = obj["expires_at"]
    if not isinstance(exp, int) or isinstance(exp, bool) or exp <= 0:
        fail("expires_at must be a positive unix timestamp integer")

    return obj


def read_events(path: str):
    if not os.path.isfile(path):
        return []
    events = []
    with open(path, "r", encoding="utf-8") as fh:
        for line_no, line in enumerate(fh, 1):
            line = line.strip()
            if not line:
                continue
            try:
                ev = json.loads(line)
            except json.JSONDecodeError as exc:
                fail(f"corrupt audit log at line {line_no}: {exc}")
            if not isinstance(ev, dict) or "event" not in ev:
                fail(f"corrupt audit log at line {line_no}: missing event")
            events.append(ev)
    return events


def replay_states(events):
    """Rebuild per-digest state. Crash-safe: executing without terminal -> unknown."""
    by_digest = {}
    by_idem = {}
    used_tokens = set()
    for ev in events:
        digest = ev.get("digest")
        if not digest:
            continue
        st = by_digest.get(digest)
        if st is None:
            st = {
                "digest": digest,
                "state": None,
                "request_id": ev.get("request_id"),
                "request": ev.get("request"),
                "decision": "confirm-first",
                "ceiling": ev.get("ceiling"),
                "idempotency_key": ev.get("idempotency_key"),
                "expires_at": ev.get("expires_at"),
                "approval_token_hash": ev.get("approval_token_hash"),
                "token_consumed": False,
                "events": [],
            }
            by_digest[digest] = st
        et = ev["event"]
        st["events"].append(ev)
        if et == "prepared":
            st["state"] = "prepared"
            st["request"] = ev.get("request", st["request"])
            st["request_id"] = ev.get("request_id", st["request_id"])
            st["decision"] = ev.get("decision", "confirm-first")
            st["ceiling"] = ev.get("ceiling")
            st["idempotency_key"] = ev.get("idempotency_key")
            st["expires_at"] = ev.get("expires_at")
            st["approval_token_hash"] = ev.get("approval_token_hash")
            if st["idempotency_key"]:
                by_idem[st["idempotency_key"]] = digest
        elif et == "approved":
            st["state"] = "approved"
            st["token_consumed"] = True
            if ev.get("approval_token_hash"):
                used_tokens.add(ev["approval_token_hash"])
        elif et == "executing":
            st["state"] = "executing"
        elif et in TERMINAL:
            st["state"] = et
        elif et == "refused":
            # Refusal does not advance the machine; keep prior state.
            pass
        if st["state"] not in VALID_STATES and st["state"] is not None:
            fail(f"invalid state {st['state']!r} for digest {digest}")

    # Crash recovery: in-flight executing with no terminal becomes unknown
    # in the reconstructed view. Caller may persist that transition.
    crash_unknown = []
    for digest, st in by_digest.items():
        if st["state"] == "executing":
            st["state"] = "unknown"
            st["decision"] = "confirm-first"
            crash_unknown.append(digest)
        # Restarted broker never inherits autonomy: posture is confirm-first.
        st["decision"] = "confirm-first"
    return by_digest, by_idem, used_tokens, crash_unknown


def emit_kv(result: dict) -> None:
    """Stable key=value stdout for shell callers; JSON on FM_ACTION_GATEWAY_JSON=1."""
    if os.environ.get("FM_ACTION_GATEWAY_JSON", "") == "1":
        print(canonical_json(result))
        return
    order = (
        "decision",
        "state",
        "digest",
        "request_id",
        "approval_token",
        "ceiling",
        "expires_at",
        "reason",
        "idempotency_key",
        "event",
    )
    for key in order:
        if key in result and result[key] is not None:
            print(f"{key}={result[key]}")


def append_event(path: str, event: dict) -> None:
    line = canonical_json(event) + "\n"
    data = line.encode("utf-8")
    parent = os.path.dirname(path) or "."
    os.makedirs(parent, exist_ok=True)
    fd = os.open(path, os.O_WRONLY | os.O_APPEND | os.O_CREAT, 0o644)
    try:
        written = 0
        while written < len(data):
            n = os.write(fd, data[written:])
            if n <= 0:
                raise OSError("short write to audit log")
            written += n
        os.fsync(fd)
    finally:
        os.close(fd)
    dir_fd = os.open(parent, os.O_RDONLY)
    try:
        os.fsync(dir_fd)
    finally:
        os.close(dir_fd)


def cmd_prepare(cmd: dict, by_digest, by_idem):
    req = validate_request(cmd["request"])
    digest = action_digest(req)
    ceiling = classify_ceiling(req["action_kind"], req["parameters"])
    # Hard floor: spend/messaging ALWAYS confirm-first; tiers cannot raise it.
    decision = "confirm-first"
    if ceiling is not None and req["requested_consent_tier"] != "confirm-first":
        # Record that the ceiling suppressed a higher requested tier.
        pass

    idem = req["idempotency_key"]
    if idem in by_idem:
        existing_digest = by_idem[idem]
        if existing_digest != digest:
            fail(
                "idempotency_key reuse with differing digest "
                f"(existing={existing_digest}, new={digest})"
            )
        st = by_digest[existing_digest]
        emit_kv(
            {
                "decision": "confirm-first",
                "state": st["state"],
                "digest": existing_digest,
                "request_id": st["request_id"],
                "ceiling": st.get("ceiling"),
                "expires_at": st.get("expires_at"),
                "idempotency_key": idem,
                "reason": "idempotent-replay",
                "event": "prepared",
            }
        )
        return

    if digest in by_digest:
        st = by_digest[digest]
        emit_kv(
            {
                "decision": "confirm-first",
                "state": st["state"],
                "digest": digest,
                "request_id": st["request_id"],
                "ceiling": st.get("ceiling"),
                "expires_at": st.get("expires_at"),
                "idempotency_key": idem,
                "reason": "digest-already-prepared",
                "event": "prepared",
            }
        )
        return

    if req["expires_at"] <= now_ts():
        fail("request already expired at prepare")

    token = secrets.token_hex(32)
    token_hash = hashlib.sha256(token.encode("utf-8")).hexdigest()
    request_id = str(uuid.uuid4())
    event = {
        "ts": now_ts(),
        "event": "prepared",
        "state": "prepared",
        "request_id": request_id,
        "digest": digest,
        "decision": decision,
        "ceiling": ceiling,
        "idempotency_key": idem,
        "expires_at": req["expires_at"],
        "approval_token_hash": token_hash,
        "request": req,
        # Explicit marker: this broker never executes outward effects.
        "execution": "stubbed",
    }
    append_event(AUDIT_PATH, event)
    emit_kv(
        {
            "decision": decision,
            "state": "prepared",
            "digest": digest,
            "request_id": request_id,
            "approval_token": token,
            "ceiling": ceiling,
            "expires_at": req["expires_at"],
            "idempotency_key": idem,
            "event": "prepared",
        }
    )


def cmd_approve(cmd: dict, by_digest):
    digest = cmd.get("digest")
    token = cmd.get("token")
    if not isinstance(digest, str) or not re.fullmatch(r"[0-9a-f]{64}", digest):
        fail("approve requires --digest <sha256-hex>")
    if not isinstance(token, str) or not token.strip():
        fail("approve requires --token <one-shot-token>")

    st = by_digest.get(digest)
    if st is None:
        fail("unknown digest: not prepared")
    if st["state"] in TERMINAL:
        fail(f"digest already terminal: {st['state']}")
    if st["state"] == "approved":
        fail("approval token already consumed for this digest")
    if st["state"] == "executing":
        fail("digest is executing; cannot approve")
    if st["state"] != "prepared":
        fail(f"digest not in prepared state (state={st['state']})")

    if st.get("expires_at") is not None and int(st["expires_at"]) <= now_ts():
        refuse = {
            "ts": now_ts(),
            "event": "refused",
            "state": st["state"],
            "digest": digest,
            "request_id": st["request_id"],
            "reason": "expired",
            "decision": "confirm-first",
        }
        append_event(AUDIT_PATH, refuse)
        fail("approval refused: digest expired")

    token_hash = hashlib.sha256(token.encode("utf-8")).hexdigest()
    if token_hash != st.get("approval_token_hash"):
        refuse = {
            "ts": now_ts(),
            "event": "refused",
            "state": st["state"],
            "digest": digest,
            "request_id": st["request_id"],
            "reason": "token-mismatch-or-digest-swap",
            "decision": "confirm-first",
        }
        append_event(AUDIT_PATH, refuse)
        fail("approval refused: token does not bind to this digest")

    if st.get("token_consumed"):
        fail("approval refused: token replay")

    event = {
        "ts": now_ts(),
        "event": "approved",
        "state": "approved",
        "digest": digest,
        "request_id": st["request_id"],
        "approval_token_hash": token_hash,
        "decision": "confirm-first",
        "ceiling": st.get("ceiling"),
        "execution": "stubbed",
    }
    append_event(AUDIT_PATH, event)
    emit_kv(
        {
            "decision": "confirm-first",
            "state": "approved",
            "digest": digest,
            "request_id": st["request_id"],
            "ceiling": st.get("ceiling"),
            "event": "approved",
            "reason": "digest-bound-approval",
        }
    )


def cmd_execute(cmd: dict, by_digest):
    """Stub executor: record executing -> unknown. NEVER performs an action."""
    digest = cmd.get("digest")
    if not isinstance(digest, str) or not re.fullmatch(r"[0-9a-f]{64}", digest):
        fail("execute requires --digest <sha256-hex>")
    st = by_digest.get(digest)
    if st is None:
        fail("unknown digest: not prepared")
    if st["state"] in TERMINAL:
        fail(f"digest already terminal: {st['state']}")
    if st["state"] != "approved":
        fail(f"execute requires approved state (state={st['state']})")
    if st.get("expires_at") is not None and int(st["expires_at"]) <= now_ts():
        fail("execute refused: digest expired")

    # Hard ceiling still blocks any future auto-exec path; stub records unknown.
    ceiling = st.get("ceiling")
    exec_ev = {
        "ts": now_ts(),
        "event": "executing",
        "state": "executing",
        "digest": digest,
        "request_id": st["request_id"],
        "decision": "confirm-first",
        "ceiling": ceiling,
        "execution": "stubbed",
    }
    append_event(AUDIT_PATH, exec_ev)
    # No outward effect. Terminal unknown: executor not wired.
    term = {
        "ts": now_ts(),
        "event": "unknown",
        "state": "unknown",
        "digest": digest,
        "request_id": st["request_id"],
        "decision": "confirm-first",
        "ceiling": ceiling,
        "reason": "execution-not-wired",
        "execution": "stubbed",
    }
    append_event(AUDIT_PATH, term)
    emit_kv(
        {
            "decision": "confirm-first",
            "state": "unknown",
            "digest": digest,
            "request_id": st["request_id"],
            "ceiling": ceiling,
            "event": "unknown",
            "reason": "execution-not-wired",
        }
    )


def cmd_status(cmd: dict, by_digest):
    digest = cmd.get("digest")
    if not isinstance(digest, str) or not re.fullmatch(r"[0-9a-f]{64}", digest):
        fail("status requires --digest <sha256-hex>")
    st = by_digest.get(digest)
    if st is None:
        fail("unknown digest")
    emit_kv(
        {
            "decision": "confirm-first",
            "state": st["state"],
            "digest": digest,
            "request_id": st["request_id"],
            "ceiling": st.get("ceiling"),
            "expires_at": st.get("expires_at"),
            "idempotency_key": st.get("idempotency_key"),
            "event": "status",
        }
    )


def cmd_replay(by_digest, crash_unknown):
    # Persist crash-recovery unknown transitions so a restarted broker converges.
    for digest in crash_unknown:
        st = by_digest[digest]
        append_event(
            AUDIT_PATH,
            {
                "ts": now_ts(),
                "event": "unknown",
                "state": "unknown",
                "digest": digest,
                "request_id": st["request_id"],
                "decision": "confirm-first",
                "ceiling": st.get("ceiling"),
                "reason": "crash-replay-default-confirm-first",
                "execution": "stubbed",
            },
        )
        st["state"] = "unknown"
    emit_kv(
        {
            "decision": "confirm-first",
            "state": "replayed",
            "reason": "crash-safe-confirm-first",
            "event": "replay",
            "digest": None,
            "request_id": None,
            "ceiling": None,
            "expires_at": None,
            "idempotency_key": None,
            "approval_token": None,
        }
    )
    # Also print a count line for operators/tests.
    print(f"actions={len(by_digest)}")
    print(f"crash_unknown_recovered={len(crash_unknown)}")


def main():
    try:
        cmd = json.loads(CMD_JSON)
    except json.JSONDecodeError as exc:
        fail(f"invalid broker command JSON: {exc}")
    if not isinstance(cmd, dict) or "op" not in cmd:
        fail("broker command must be a JSON object with op")

    events = read_events(AUDIT_PATH)
    by_digest, by_idem, _used, crash_unknown = replay_states(events)
    op = cmd["op"]
    if op == "prepare":
        if "request" not in cmd:
            fail("prepare requires request object")
        cmd_prepare(cmd, by_digest, by_idem)
    elif op == "approve":
        cmd_approve(cmd, by_digest)
    elif op == "execute":
        cmd_execute(cmd, by_digest)
    elif op == "status":
        cmd_status(cmd, by_digest)
    elif op == "replay":
        cmd_replay(by_digest, crash_unknown)
    else:
        fail(f"unknown op: {op}")


if __name__ == "__main__":
    main()
PY
}

run_broker() {
  local audit_path=$1
  local cmd_json=$2
  local err_file out
  err_file=$(mktemp "${TMPDIR:-/tmp}/fm-action-gateway.XXXXXX")
  if ! out=$(broker_py "$audit_path" "${FM_ACTION_GATEWAY_NOW:-}" "$cmd_json" 2>"$err_file"); then
    cat "$err_file" >&2 || true
    rm -f "$err_file"
    return 1
  fi
  rm -f "$err_file"
  printf '%s\n' "$out"
}

read_request_input() {
  local file=$1
  if [ -n "$file" ]; then
    [ -f "$file" ] || fail "request file not found: $file"
    cat "$file"
  else
    cat
  fi
}

cmd_prepare() {
  local file='' input request_json audit_path cmd_json
  while [ "$#" -gt 0 ]; do
    case "$1" in
      --file)
        [ "$#" -ge 2 ] || fail "--file requires a path"
        file=$2
        shift 2
        ;;
      -*)
        fail "unknown flag: $1"
        ;;
      *)
        fail "unexpected argument: $1"
        ;;
    esac
  done
  input=$(read_request_input "$file")
  # Minimal JSON check before handing to broker (broker owns full schema).
  printf '%s' "$input" | python3 -c 'import json,sys; json.loads(sys.stdin.read())' \
    >/dev/null 2>&1 || fail "schema validation failed"
  request_json=$(printf '%s' "$input" | python3 -c 'import json,sys; json.dump(json.loads(sys.stdin.read()), sys.stdout, separators=(",",":"))')
  audit_path=$(audit_log_path)
  cmd_json=$(python3 -c 'import json,sys; print(json.dumps({"op":"prepare","request":json.loads(sys.argv[1])}))' "$request_json")
  run_broker "$audit_path" "$cmd_json" || fail "prepare failed"
}

cmd_approve() {
  local digest='' token='' audit_path cmd_json
  while [ "$#" -gt 0 ]; do
    case "$1" in
      --digest)
        [ "$#" -ge 2 ] || fail "--digest requires a value"
        digest=$2
        shift 2
        ;;
      --token)
        [ "$#" -ge 2 ] || fail "--token requires a value"
        token=$2
        shift 2
        ;;
      -*)
        fail "unknown flag: $1"
        ;;
      *)
        fail "unexpected argument: $1"
        ;;
    esac
  done
  [ -n "$digest" ] || fail "approve requires --digest"
  [ -n "$token" ] || fail "approve requires --token"
  audit_path=$(audit_log_path)
  cmd_json=$(python3 -c 'import json,sys; print(json.dumps({"op":"approve","digest":sys.argv[1],"token":sys.argv[2]}))' "$digest" "$token")
  run_broker "$audit_path" "$cmd_json" || fail "approve failed"
}

cmd_execute() {
  local digest='' audit_path cmd_json
  while [ "$#" -gt 0 ]; do
    case "$1" in
      --digest)
        [ "$#" -ge 2 ] || fail "--digest requires a value"
        digest=$2
        shift 2
        ;;
      -*)
        fail "unknown flag: $1"
        ;;
      *)
        fail "unexpected argument: $1"
        ;;
    esac
  done
  [ -n "$digest" ] || fail "execute requires --digest"
  audit_path=$(audit_log_path)
  cmd_json=$(python3 -c 'import json,sys; print(json.dumps({"op":"execute","digest":sys.argv[1]}))' "$digest")
  run_broker "$audit_path" "$cmd_json" || fail "execute failed"
}

cmd_status() {
  local digest='' audit_path cmd_json
  while [ "$#" -gt 0 ]; do
    case "$1" in
      --digest)
        [ "$#" -ge 2 ] || fail "--digest requires a value"
        digest=$2
        shift 2
        ;;
      -*)
        fail "unknown flag: $1"
        ;;
      *)
        fail "unexpected argument: $1"
        ;;
    esac
  done
  [ -n "$digest" ] || fail "status requires --digest"
  audit_path=$(audit_log_path)
  cmd_json=$(python3 -c 'import json,sys; print(json.dumps({"op":"status","digest":sys.argv[1]}))' "$digest")
  run_broker "$audit_path" "$cmd_json" || fail "status failed"
}

cmd_replay() {
  local audit_path cmd_json
  [ "$#" -eq 0 ] || fail "replay takes no arguments"
  audit_path=$(audit_log_path)
  cmd_json='{"op":"replay"}'
  run_broker "$audit_path" "$cmd_json" || fail "replay failed"
}

main() {
  local op=''

  if [ "$#" -eq 0 ]; then
    cmd_prepare
    return 0
  fi

  case "$1" in
    -h|--help)
      usage
      exit 0
      ;;
    prepare|approve|execute|status|replay)
      op=$1
      shift
      ;;
    --file)
      # Backward-compatible: flags without explicit prepare => prepare.
      cmd_prepare "$@"
      return 0
      ;;
    -*)
      fail "unknown flag: $1"
      ;;
    *)
      fail "unknown command: $1"
      ;;
  esac

  case "$op" in
    prepare) cmd_prepare "$@" ;;
    approve) cmd_approve "$@" ;;
    execute) cmd_execute "$@" ;;
    status) cmd_status "$@" ;;
    replay) cmd_replay "$@" ;;
  esac
}

main "$@"
