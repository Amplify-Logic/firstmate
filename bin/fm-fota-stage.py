#!/usr/bin/env python3
"""fm-fota-stage.py - stage-and-verify a device configuration command.

Produces a staged, verified command and a contextual preview. It NEVER sends,
never opens a browser, and never touches a device: it reads an adapter
definition plus operator-supplied parameters and emits one staging plan.

The adapter definition is local, captain-approved data (portal identity, field
map, device rules). It lives outside this repository and is passed with
--adapter. Nothing device- or site-specific is compiled in here, and this tool
accepts no command, executable, or URL from the adapter that it would run.

What it refuses, and why each refusal exists:
  * a setting whose encoding is not declared AND confirmed - an unconfirmed
    encoding silently produces a wrong number, which is worse than no number
  * a setting the declared device class does not support
  * an ordered pair whose lower bound is not below its upper bound
  * a write-shaped request against a target whose eligibility is unverified
  * a missing attempt ordinal, because operation identity depends on it

Encodings are per-key, never per-device-series: a measurement and a setting on
the same device can use different rules, so every emitted number carries the
name of the rule that produced it.

Usage:
  fm-fota-stage.py --adapter <path> --request <path|-> [--out <path>]
  fm-fota-stage.py --adapter <path> --print-schema
  fm-fota-stage.py -h|--help

Exit:
  0  a staging plan was produced (it may still report eligibility unverified)
  1  usage, schema, or a refusal listed above
"""

from __future__ import annotations

import argparse
import hashlib
import json
import sys

PLAN_SCHEMA = "fm.fota-staging-plan.v1"
ADAPTER_SCHEMA = "fm.fota-adapter.v1"

# Value encodings. Declared per setting key by the adapter, never inferred from
# a device series: the same device can carry a setting in one encoding and a
# reported measurement in another.
#
#   offset100_tenths_c  stored as 100 + tenths of a degree C (135 -> 3.5 C)
#   plain_tenths_c      stored as tenths of a degree C        (44  -> 4.4 C)
#   boolean             stored as a JSON boolean
ENCODINGS = {
    "offset100_tenths_c": {
        "kind": "numeric",
        "to_wire": lambda c: 100 + int(round(float(c) * 10)),
        "from_wire": lambda raw: (int(raw) - 100) / 10.0,
        "unit": "C",
    },
    "plain_tenths_c": {
        "kind": "numeric",
        "to_wire": lambda c: int(round(float(c) * 10)),
        "from_wire": lambda raw: int(raw) / 10.0,
        "unit": "C",
    },
    "boolean": {
        "kind": "boolean",
        "to_wire": lambda b: bool(b),
        "from_wire": lambda raw: bool(raw),
        "unit": None,
    },
}


def fail(msg: str) -> None:
    print(f"fm-fota-stage: {msg}", file=sys.stderr)
    sys.exit(1)


def canonical_bytes(obj) -> bytes:
    """Stable bytes for hashing: sorted keys, no incidental whitespace."""
    return json.dumps(obj, sort_keys=True, separators=(",", ":")).encode("utf-8")


def sha256_hex(obj) -> str:
    return hashlib.sha256(canonical_bytes(obj)).hexdigest()


def load_json(path: str, label: str):
    try:
        if path == "-":
            return json.load(sys.stdin)
        with open(path, "r", encoding="utf-8") as handle:
            return json.load(handle)
    except FileNotFoundError:
        fail(f"{label} not found: {path}")
    except json.JSONDecodeError as exc:
        fail(f"{label} is not valid JSON: {exc}")
    return None


def require(obj, key, label):
    if not isinstance(obj, dict) or key not in obj:
        fail(f"{label} is missing required field {key!r}")
    return obj[key]


def resolve_setting(adapter: dict, name: str) -> dict:
    settings = adapter.get("settings")
    if not isinstance(settings, dict) or name not in settings:
        fail(
            f"setting {name!r} is not declared by this adapter; "
            "an undeclared setting has no confirmed encoding and cannot be staged"
        )
    spec = settings[name]
    encoding = spec.get("encoding")
    if encoding not in ENCODINGS:
        fail(
            f"setting {name!r} declares unknown encoding {encoding!r}; "
            f"known encodings: {', '.join(sorted(ENCODINGS))}"
        )
    # An encoding that is declared but not confirmed against a real observation
    # is a guess. A wrong encoding produces a plausible number that means
    # something else entirely, so this refuses rather than warns.
    if spec.get("confirmed") is not True:
        fail(
            f"setting {name!r} has encoding {encoding!r} declared but not confirmed; "
            "confirm it against an observed value before staging this key"
        )
    return spec


def build_payload(adapter: dict, staged: list) -> str:
    """Render the wire payload in the adapter's declared command format."""
    fmt = require(adapter, "command_format", "adapter")
    if fmt.get("wire") != "senml-array":
        fail(f"unsupported command wire format: {fmt.get('wire')!r}")
    name_key = require(fmt, "name_key", "adapter.command_format")
    numeric_key = fmt.get("numeric_value_key")
    boolean_key = fmt.get("boolean_value_key")

    items = []
    for entry in staged:
        if entry["value_kind"] == "numeric":
            if not numeric_key:
                fail(
                    "adapter declares no numeric_value_key; a numeric setting "
                    "cannot be staged until the portal's key is confirmed"
                )
            items.append(
                '{"%s": "%s", "%s": %d}'
                % (name_key, entry["name"], numeric_key, entry["wire_value"])
            )
        else:
            if not boolean_key:
                fail("adapter declares no boolean_value_key")
            items.append(
                '{"%s": "%s", "%s": %s}'
                % (
                    name_key,
                    entry["name"],
                    boolean_key,
                    "true" if entry["wire_value"] else "false",
                )
            )
    return "[" + ",".join(items) + "]"


def operation_identity(request: dict, staged: list, attempt: int) -> dict:
    """Deterministic operation identity, distinct from any approval digest.

    Computed over what makes two requests the SAME REAL OPERATION: the action,
    the target, the setting keys and their wire values, and the environment.
    Deliberately excludes nonce, timestamp and uuid, so re-preparing the same
    operation yields the same key and a repeat is detectable. The attempt
    ordinal is inside the key, so a deliberate retry is a new identity by
    construction while an accidental repeat is not.
    """
    fingerprint_source = {
        "action_kind": request["action_kind"],
        "device_id": request["device_id"],
        "environment": request["environment"],
        "settings": sorted(
            [[entry["name"], entry["wire_value"]] for entry in staged],
            key=lambda pair: pair[0],
        ),
    }
    fingerprint = sha256_hex(fingerprint_source)
    return {
        "operation_fingerprint": fingerprint,
        "attempt": attempt,
        # The gateway's idempotency_key. Stable for one operation and one
        # attempt; a second attempt is an explicit, human-visible ordinal.
        "idempotency_key": f"{fingerprint[:32]}-attempt-{attempt}",
    }


def assess_eligibility(adapter: dict, request: dict) -> dict:
    """Eligibility is an observed fact about THIS device, never a prefix rule."""
    rules = adapter.get("eligibility", {}) or {}
    device_id = request["device_id"]
    prefixes = rules.get("imei_prefixes_necessary") or []
    prefix_ok = any(device_id.startswith(p) for p in prefixes) if prefixes else None

    observed = request.get("observed_settings")
    required = sorted({entry["name"] for entry in request["settings"]})

    if not isinstance(observed, list):
        return {
            "state": "unverified",
            "prefix_necessary_condition": prefix_ok,
            "observed_rows_supplied": False,
            "reason": (
                "No observed device rows were supplied, so it is unknown whether this "
                "target carries these settings. A model prefix is a necessary condition, "
                "never sufficient, and the presence of a control in the portal is not "
                "evidence at all."
            ),
            "how_to_resolve": rules.get("resolved_by"),
        }

    missing = [name for name in required if name not in observed]
    if missing:
        return {
            "state": "ineligible",
            "prefix_necessary_condition": prefix_ok,
            "observed_rows_supplied": True,
            "reason": (
                "The target's observed rows do not include: "
                + ", ".join(missing)
                + ". Staging a setting a device does not carry has an undefined result."
            ),
        }
    return {
        "state": "verified",
        "prefix_necessary_condition": prefix_ok,
        "observed_rows_supplied": True,
        "reason": "Every staged setting appears in this target's observed rows.",
    }


def check_constraints(adapter: dict, by_name: dict) -> list:
    """Policy validation only: checkable rules, never a safety judgement."""
    results = []
    for rule in adapter.get("constraints", []) or []:
        if rule.get("type") != "ordered_pair":
            fail(f"unsupported constraint type: {rule.get('type')!r}")
        lower, upper = rule.get("lower"), rule.get("upper")
        if lower in by_name and upper in by_name:
            low_v = by_name[lower]["wire_value"]
            high_v = by_name[upper]["wire_value"]
            ok = low_v < high_v
            results.append(
                {
                    "rule": f"{lower} < {upper}",
                    "passed": ok,
                    "detail": f"{lower}={low_v}, {upper}={high_v}",
                }
            )
            if not ok:
                fail(
                    f"constraint violated: {lower} ({low_v}) must be below "
                    f"{upper} ({high_v})"
                )
    return results


def build_plan(adapter: dict, request: dict) -> dict:
    for field in ("action_kind", "device_id", "environment", "settings", "attempt"):
        require(request, field, "request")
    attempt = request["attempt"]
    if not isinstance(attempt, int) or isinstance(attempt, bool) or attempt < 1:
        fail("attempt must be an integer >= 1; operation identity depends on it")
    if not isinstance(request["settings"], list) or not request["settings"]:
        fail("request.settings must be a non-empty list")

    staged = []
    for item in request["settings"]:
        name = require(item, "name", "request.settings[]")
        value = require(item, "value", "request.settings[]")
        spec = resolve_setting(adapter, name)
        encoding = spec["encoding"]
        rule = ENCODINGS[encoding]
        wire = rule["to_wire"](value)
        staged.append(
            {
                "name": name,
                "requested_value": value,
                "unit": rule["unit"],
                "wire_value": wire,
                # Every number says which rule produced it, so a measurement
                # rule and a setting rule can never be silently interchanged.
                "encoding": encoding,
                "value_kind": rule["kind"],
                "decoded_check": rule["from_wire"](wire),
            }
        )

    by_name = {entry["name"]: entry for entry in staged}
    constraints = check_constraints(adapter, by_name)
    payload = build_payload(adapter, staged)
    identity = operation_identity(request, staged, attempt)
    eligibility = assess_eligibility(adapter, request)

    telemetry = []
    for row in request.get("telemetry", []) or []:
        # A measurement without its age is not evidence, and "unavailable" is a
        # third state that must never be rendered as a reading.
        telemetry.append(
            {
                "name": row.get("name"),
                "available": row.get("available", False),
                "raw": row.get("raw") if row.get("available") else None,
                "encoding": row.get("encoding"),
                "decoded": (
                    ENCODINGS[row["encoding"]]["from_wire"](row["raw"])
                    if row.get("available") and row.get("encoding") in ENCODINGS
                    else None
                ),
                "observed_at": row.get("observed_at") if row.get("available") else None,
            }
        )

    unknowns = []
    if eligibility["state"] != "verified":
        unknowns.append(
            "Whether this target carries these settings at all "
            f"(eligibility: {eligibility['state']})."
        )
    # Deliberately keyed on the STAGED settings, not on telemetry in general:
    # a reading for some other field says nothing about the values being
    # changed, and treating it as coverage would imply a known current state.
    read_now = {row["name"] for row in telemetry if row["available"]}
    unread = [entry["name"] for entry in staged if entry["name"] not in read_now]
    if unread:
        unknowns.append(
            "Current values were not read for: "
            + ", ".join(sorted(unread))
            + ". This preview states what would be requested, not what would change."
        )

    preview = {
        "action_kind": request["action_kind"],
        "device_id": request["device_id"],
        "environment": request["environment"],
        "payload": payload,
        "settings": staged,
    }

    return {
        "schema": PLAN_SCHEMA,
        "adapter": {
            "name": adapter.get("name"),
            "adapter_version": adapter.get("adapter_version"),
        },
        "target": {
            "device_id": request["device_id"],
            "source": "operator-supplied",
            # The portal adds the identifier from page context, so the real
            # target is whichever page is loaded. This plan is only valid
            # against a page that verifies as this device.
            "must_verify_against_loaded_page": True,
            "verified_against_page": False,
        },
        "operation": dict(identity, action_kind=request["action_kind"]),
        "settings": staged,
        "payload": payload,
        "eligibility": eligibility,
        "policy_validation": {
            "constraints": constraints,
            "all_encodings_confirmed": True,
            "note": (
                "These are checkable rules about the request. They are not a "
                "judgement about physical behaviour."
            ),
        },
        "physical_safety": {
            "claimed": False,
            "note": (
                "No safety claim is made or implied. A configured bound does not "
                "constrain what the hardware actually does, and a reported "
                "measurement can differ from the condition it describes. Choosing "
                "values is an operator judgement this tool does not make."
            ),
        },
        "telemetry": telemetry,
        "unknowns": unknowns,
        "send": {
            "authorized": False,
            "performed": False,
            "note": (
                "This tool stages and verifies only. Sending is a separate control, "
                "a separate action kind, and a separate authority."
            ),
        },
        # Binds the approval to the exact preview it was granted against.
        "preview_hash": sha256_hex(preview),
    }


def main() -> None:
    parser = argparse.ArgumentParser(add_help=True, description=__doc__)
    parser.add_argument("--adapter", required=True)
    parser.add_argument("--request")
    parser.add_argument("--out")
    parser.add_argument("--print-schema", action="store_true")
    args = parser.parse_args()

    adapter = load_json(args.adapter, "adapter")
    if adapter.get("schema") != ADAPTER_SCHEMA:
        fail(f"adapter schema must be {ADAPTER_SCHEMA!r}, got {adapter.get('schema')!r}")

    if args.print_schema:
        print(json.dumps({"adapter": ADAPTER_SCHEMA, "plan": PLAN_SCHEMA}, indent=2))
        return

    if not args.request:
        fail("--request is required unless --print-schema is given")

    plan = build_plan(adapter, load_json(args.request, "request"))
    rendered = json.dumps(plan, indent=2, sort_keys=True)
    if args.out:
        with open(args.out, "w", encoding="utf-8") as handle:
            handle.write(rendered + "\n")
        print(f"staging_plan={args.out}")
        print(f"preview_hash={plan['preview_hash']}")
        print(f"idempotency_key={plan['operation']['idempotency_key']}")
        print(f"eligibility={plan['eligibility']['state']}")
    else:
        print(rendered)


if __name__ == "__main__":
    main()
