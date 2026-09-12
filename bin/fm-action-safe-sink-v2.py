#!/usr/bin/env python3
"""Firstmate action gateway v2 deterministic safe sink.

This is the Step 2.6 executor: the only program bin/fm-action-gateway-v2.py will
ever claim an execution for, and the only component in the v2 boundary that holds
an effect. Its effect is deliberately local and inert - one append-only record in
its own store under the gateway state root - so the whole execution path can be
proved end to end before any outward capability exists.

Three properties matter, and each is enforced here rather than asserted:

  Deterministic  One approved plan resolves to exactly one record. The record is
                 built only from the plan's own identity fields, so the same plan
                 always produces the same bytes and the broker can recompute them
                 without asking this program anything.
  Exactly once   The idempotency key is the receipt store's primary key. A repeat
                 apply reports already-applied and changes nothing, so a repeated
                 click, a retry, or a restart cannot produce a second effect.
  Readable back  After committing, this program re-opens its own store read-only
                 and re-reads the appended line, and reports what it found rather
                 than what it intended.

It refuses any plan that claims an outward executor, and any plan whose bound
executor hash is not this file's exact bytes.

Usage:
  fm-action-safe-sink-v2.py apply < plan.jcs
  fm-action-safe-sink-v2.py verify --idempotency-key KEY
  fm-action-safe-sink-v2.py inspect-paths

The plan arrives as the exact canonical bytes the broker stored, so the plan
digest is the digest of those bytes and no second canonicalizer has to agree with
the broker's for the record to match.
"""

from __future__ import annotations

import argparse
import contextlib
import hashlib
import json
import os
import secrets
import sqlite3
import stat
import sys
import time
import urllib.parse
from pathlib import Path
from typing import Any, Dict, NoReturn, Optional, Sequence, Tuple

PRODUCTION_ROOT = Path("/var/db/firstmate/gateway")
MAX_PLAN_BYTES = 96 * 1024
PLAN_SCHEMA = "fm.execution-plan.v2"
RECORD_SCHEMA = "fm.safe-sink-record.v2"
RESULT_SCHEMA = "fm.safe-sink-result.v2"


class SinkError(Exception):
    """A refusal safe to print without leaking state."""


def fail(message: str) -> NoReturn:
    raise SinkError(message)


def sha256_bytes(value: bytes) -> str:
    return hashlib.sha256(value).hexdigest()


def test_mode() -> bool:
    return os.environ.get("FM_ACTION_GATEWAY_TEST") == "1"


def state_root() -> Path:
    """Resolve the same state root the broker resolves.

    Deliberately the broker's rule, not a caller-selected path: a sink whose
    store the caller could move is a sink whose receipts the broker cannot
    trust. tests/fm-action-safe-sink-v2.test.sh asserts both programs report the
    same root rather than asserting that the two sources look alike.
    """
    if test_mode():
        return Path(os.environ.get("TMPDIR", "/tmp")) / "fm-gateway-v2-state"
    return PRODUCTION_ROOT


def database_path() -> Path:
    return state_root() / "safe-sink-v2.sqlite3"


def journal_path() -> Path:
    return state_root() / "safe-sink-v2.jsonl"


def own_identity() -> str:
    return sha256_bytes(Path(__file__).resolve().read_bytes())


def ensure_private_directory(path: Path) -> None:
    path.mkdir(parents=True, exist_ok=True)
    path.chmod(0o700)
    mode = stat.S_IMODE(path.stat().st_mode)
    if mode != 0o700:
        fail(f"state directory mode must be 0700, got {mode:04o}")


def connect_database() -> sqlite3.Connection:
    ensure_private_directory(state_root())
    connection = sqlite3.connect(database_path(), timeout=10, isolation_level=None)
    connection.row_factory = sqlite3.Row
    connection.execute("PRAGMA journal_mode=WAL")
    connection.execute("PRAGMA synchronous=FULL")
    connection.executescript(
        """
        CREATE TABLE IF NOT EXISTS receipts (
          idempotency_key TEXT PRIMARY KEY,
          receipt_id TEXT NOT NULL UNIQUE,
          request_id TEXT NOT NULL UNIQUE,
          plan_digest TEXT NOT NULL UNIQUE,
          record_digest TEXT NOT NULL UNIQUE,
          applied_at INTEGER NOT NULL
        );
        """
    )
    with contextlib.suppress(OSError):
        database_path().chmod(0o600)
    return connection


def record_for(plan_digest: str, request_id: str, idempotency_key: str, operation: str) -> Dict[str, str]:
    """The deterministic record for one approved plan.

    Every member is ASCII hex or a registry slug, so compact sorted-key JSON is
    byte-identical to the canonical form the broker uses. bin/fm-action-gateway-v2.py
    builds the same object in sink_record(); tests/fm-action-safe-sink-v2.test.sh
    proves the two agree by running both rather than by comparing their sources.
    """
    return {
        "schema": RECORD_SCHEMA,
        "plan_digest": plan_digest,
        "request_id": request_id,
        "idempotency_key": idempotency_key,
        "operation": operation,
    }


def record_bytes(record: Dict[str, str]) -> bytes:
    return json.dumps(record, sort_keys=True, separators=(",", ":")).encode("utf-8")


def required_text(value: Any, label: str) -> str:
    if not isinstance(value, str) or not value or len(value) > 256:
        fail(f"plan {label} is missing or refused")
    return value


def parse_plan(raw: bytes) -> Tuple[Dict[str, Any], str]:
    if not raw:
        fail("no plan on stdin")
    if len(raw) > MAX_PLAN_BYTES:
        fail(f"plan exceeds {MAX_PLAN_BYTES} bytes")
    try:
        plan = json.loads(raw.decode("utf-8"))
    except (UnicodeDecodeError, json.JSONDecodeError) as exc:
        fail(f"plan is not valid UTF-8 JSON: {exc}")
    if not isinstance(plan, dict) or plan.get("schema") != PLAN_SCHEMA:
        fail(f"plan schema must be {PLAN_SCHEMA}")
    executor = plan.get("executor")
    if not isinstance(executor, dict):
        fail("plan has no bound executor")
    if executor.get("outward_execution") is not False:
        fail("the safe sink refuses a plan that claims an outward executor")
    if executor.get("sha256") != own_identity():
        fail("plan authorizes different executor bytes than this program")
    return plan, sha256_bytes(raw)


def readback(idempotency_key: str, record_digest: str) -> Dict[str, Optional[str]]:
    """Re-read the committed effect instead of reporting the intended one."""
    observed_receipt: Optional[str] = None
    try:
        connection = sqlite3.connect(f"file:{urllib.parse.quote(str(database_path()))}?mode=ro", uri=True, timeout=10)
    except sqlite3.Error:
        connection = None
    if connection is not None:
        try:
            connection.row_factory = sqlite3.Row
            row = connection.execute("SELECT record_digest FROM receipts WHERE idempotency_key=?", (idempotency_key,)).fetchone()
            observed_receipt = str(row["record_digest"]) if row is not None else None
        except sqlite3.Error:
            observed_receipt = None
        finally:
            connection.close()
    observed_journal: Optional[str] = None
    with contextlib.suppress(OSError):
        with journal_path().open("rb") as handle:
            for line in handle:
                stripped = line.rstrip(b"\n")
                if stripped and sha256_bytes(stripped) == record_digest:
                    observed_journal = sha256_bytes(stripped)
                    break
    verified = observed_receipt == record_digest and observed_journal == record_digest
    return {
        "readback_receipt_digest": observed_receipt,
        "readback_journal_digest": observed_journal,
        "readback_verified": verified,
    }


def apply_plan(raw: bytes) -> Dict[str, Any]:
    plan, plan_digest = parse_plan(raw)
    request_id = required_text(plan.get("request_id"), "request_id")
    idempotency_key = required_text(plan.get("idempotency_key"), "idempotency_key")
    operation = required_text(plan.get("operation"), "operation")
    record = record_for(plan_digest, request_id, idempotency_key, operation)
    encoded = record_bytes(record)
    digest = sha256_bytes(encoded)
    connection = connect_database()
    try:
        connection.execute("BEGIN IMMEDIATE")
        existing = connection.execute(
            "SELECT receipt_id,record_digest FROM receipts WHERE idempotency_key=?",
            (idempotency_key,),
        ).fetchone()
        if existing is not None:
            connection.execute("COMMIT")
            outcome = "already-applied"
            receipt_id = str(existing["receipt_id"])
            stored_digest = str(existing["record_digest"])
        else:
            receipt_id = secrets.token_hex(16)
            try:
                connection.execute(
                    "INSERT INTO receipts(idempotency_key,receipt_id,request_id,plan_digest,record_digest,applied_at) VALUES(?,?,?,?,?,?)",
                    (idempotency_key, receipt_id, request_id, plan_digest, digest, int(time.time())),
                )
            except sqlite3.IntegrityError as exc:
                connection.execute("ROLLBACK")
                fail(f"safe sink refused a conflicting identity: {exc}")
            # The journal is written inside the transaction so a crash between
            # the two leaves the receipt uncommitted rather than leaving a
            # record nothing accounts for.
            descriptor = os.open(journal_path(), os.O_WRONLY | os.O_APPEND | os.O_CREAT, 0o600)
            try:
                os.write(descriptor, encoded + b"\n")
                os.fsync(descriptor)
            finally:
                os.close(descriptor)
            connection.execute("COMMIT")
            outcome = "applied"
            stored_digest = digest
    except SinkError:
        raise
    except Exception:
        with contextlib.suppress(sqlite3.Error):
            connection.execute("ROLLBACK")
        raise
    finally:
        connection.close()
    result = {
        "schema": RESULT_SCHEMA,
        "outcome": outcome,
        "receipt_id": receipt_id,
        "request_id": request_id,
        "idempotency_key": idempotency_key,
        "plan_digest": plan_digest,
        "record_digest": stored_digest,
        "outward_execution": False,
    }
    result.update(readback(idempotency_key, stored_digest))
    return result


def verify(idempotency_key: str) -> Dict[str, Any]:
    presence = "absent"
    digest: Optional[str] = None
    if database_path().exists():
        connection = connect_database()
        try:
            row = connection.execute(
                "SELECT record_digest FROM receipts WHERE idempotency_key=?",
                (idempotency_key,),
            ).fetchone()
        finally:
            connection.close()
        if row is not None:
            presence = "present"
            digest = str(row["record_digest"])
    return {"schema": RESULT_SCHEMA, "outcome": presence, "idempotency_key": idempotency_key, "record_digest": digest}


def parse_args(argv: Sequence[str]) -> argparse.Namespace:
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    subparsers = parser.add_subparsers(dest="command", required=True)
    subparsers.add_parser("apply")
    verify_parser = subparsers.add_parser("verify")
    verify_parser.add_argument("--idempotency-key", required=True)
    subparsers.add_parser("inspect-paths")
    return parser.parse_args(argv)


def main(argv: Sequence[str]) -> int:
    args = parse_args(argv)
    if args.command == "apply":
        raw = sys.stdin.buffer.read(MAX_PLAN_BYTES + 1)
        print(json.dumps(apply_plan(raw), sort_keys=True, separators=(",", ":")))
        return 0
    if args.command == "verify":
        print(json.dumps(verify(args.idempotency_key), sort_keys=True, separators=(",", ":")))
        return 0
    if args.command == "inspect-paths":
        paths = {
            "schema": "fm.safe-sink-paths.v2",
            "state_root": str(state_root()),
            "database": str(database_path()),
            "journal": str(journal_path()),
            "executor_sha256": own_identity(),
        }
        print(json.dumps(paths, sort_keys=True, separators=(",", ":")))
        return 0
    fail("unknown command")


if __name__ == "__main__":
    try:
        raise SystemExit(main(sys.argv[1:]))
    except (SinkError, sqlite3.Error, OSError) as exc:
        print(f"fm-action-safe-sink-v2: {exc}", file=sys.stderr)
        raise SystemExit(1)
