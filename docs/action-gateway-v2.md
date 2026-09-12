# Action gateway v2

`bin/fm-action-gateway-v2.py` owns the gateway v2 parser, resolved-plan schema, SQLite state model, and the prepare, approval, and execution channel schemas.
`bin/fm-action-safe-sink-v2.py` is the executor, `bin/fm-action-runner-v2.py` the relay that drives it, `bin/fm-action-artifact-import-v2.py` the quarantine importer, and `bin/fm-gateway-install-v2.sh` the installation lifecycle.
The landed `bin/fm-action-gateway.sh` broker is a separate program that stays stubbed: neither script references the other, so v2 adds no delegation path in either direction.
The landed broker still evolves on its own for reasons unrelated to v2, and `tests/fm-action-gateway.test.sh` owns its behaviour.

## Delivered program slice

This slice implements Step 2 sub-order items 1 through 6 of the worker-isolation plan, plus the quarantine importer and the installation lifecycle from item 7.
An approval now completes, and an execution now runs, against the deterministic safe sink.
No command in this slice performs an outward action, and the installation lifecycle installs nothing.

What item 7 still leaves open is the privileged installation itself: distinct installed macOS principals, root-owned ancestors, Secure Enclave enrollment, signed UI identity, root launch definitions, and network isolation.
Those need the physical machine and remain assigned to the captain-at-Mac Step 5 proof.

## Strict input and canonicalization

The gateway accepts UTF-8 JSON up to 64 KiB and canonicalizes the accepted integer-only data model according to RFC 8785 key ordering and encoding.
It rejects duplicate keys, unknown keys, floating-point and non-finite values, integers outside the interoperable range, unpaired surrogates, excessive nesting, excessive collections, and oversized strings.
Money is accepted only as one nonnegative integer `amount_minor` or compatibility `amount_cents` field plus one uppercase ISO 4217 currency.
Decimal numbers, numeric strings, duplicate money aliases, and currency without an amount are refused.
Attachments use canonical base64 and are bounded by count and decoded bytes.

The test adapter accepts the Step 1 ActionRequest shape so one regression pack can exercise both brokers.
The caller's `requester_id`, `nonce`, `expires_at`, provider identity, endpoint policy, and executor identity are never authority.
The broker derives requester authority from the connected peer and its per-job capability in the socket protocol.
Direct command-line prepare exists only when `FM_ACTION_GATEWAY_TEST=1` and derives the synthetic requester from the process UID.

## Closed execution plan

The broker resolves and stores one canonical immutable `fm.execution-plan.v2` object.
The plan contains the exact provider account identity, normalized endpoint and method, integer minor-unit money and currency, expanded recipient list and count, exact message and attachment bytes and hashes, the device payload, redirect policy, resource limits, policy-manifest hash, executor hash and version, request ID, nonce, and broker-selected short expiry.
Unicode recipient and host forms are retained next to their normalized punycode forms for the later trusted renderer.
The executor block names `bin/fm-action-safe-sink-v2.py` and binds its exact bytes, so an executor replaced after approval is refused at claim time rather than run under the old consent.

### Device actions

`device.config.stage` is the one registered device kind.
`device.config.read` is deliberately not registered: reading a device's request rows is held pending its own authorization, and registering the kind would read as pre-authorization for it.
Every `device.*` kind carries the non-graduatable `device` ceiling, so no device action can be graduated out of per-action approval.

A device plan carries the target identifier, the settings list, the eligibility status, and the preview hash, and refuses money and messaging parameters in the same request.
The gateway records the exact integer wire value the caller asked for and never alters it.
It selects no corrective band, applies no floor, and performs no rounding, because a value the gateway changed is a value nobody approved.
It also does not decode: `decoded_value` is carried next to the wire value for the approver to read and is recorded as `caller-declared`, so the reviewable transcript shows both the bytes that would go on the wire and the claim about what they mean, without the gateway asserting that claim is correct.

The one decoding judgement the gateway does enforce is a refusal.
A setting whose `encoding_confirmed` is not true cannot be staged at all, and each setting must name the evidence its encoding was confirmed against.
`eligibility.status` is `observed` or `unverified` and is never defaulted, so a plan whose target eligibility was never established says so rather than implying it was checked.
A measured sensor reading is not eligibility and is not a safety proof; nothing here treats it as either.

## SQLite authority and recovery

`gateway-v2.sqlite3` is the authority for requests, request-ID tombstones, nonce tombstones, idempotency tombstones, challenges, approvals, enrolled approvers, execution claims, capabilities, token consumption, rate events, and audit events.
Every mutation uses `BEGIN IMMEDIATE`, uniqueness constraints, foreign keys, full synchronous writes, and WAL journaling.
Request IDs, broker nonces, idempotency keys, request fingerprints, challenges, approvals, signature hashes, execution leases, capabilities, and consumed tokens have database uniqueness constraints.
Tombstones remain in SQLite when the JSONL evidence file rotates or disappears.

Every command that reads or advances request state, and the service itself, run recovery once at startup.
Recovery transactionally changes each interrupted `executing` request **whose lease deadline has passed** to `unknown` and records that provider reconciliation is required.
A live lease is left alone, which is the difference between a crash default and a per-read rewrite: a concurrent caller on another socket cannot take or rewrite an execution window that is still running.
An unknown request cannot return to approval or execution through any implemented protocol, because a request whose outcome nobody observed is exactly the one that must not be retried automatically.

## Narrow protocols

The prepare socket uses schema `fm.prepare.v2` and a capability scoped to the peer UID and job ID.
The approval socket uses schema `fm.approval.v2` and a capability scoped to the UI peer UID.
The execution socket uses schema `fm.execution.v2` and a capability scoped to the executor peer UID.
Every accepted connection obtains operating-system peer credentials with `getpeereid` on Darwin or `SO_PEERCRED` on Linux.
Each protocol uses a four-byte network-order length followed by one bounded strict JSON frame.
Every connection carries a bounded read and reply deadline, so a silent or dribbling client cannot hold a channel open indefinitely.
A channel reports readiness only once its listener and its own database connection are open, and the service refuses to keep running once any channel stops serving, so it never advertises a boundary it cannot enforce.
Every failed request, including an unexpected internal failure, returns a refusal frame and leaves the channel serving.
A schema sent to the wrong socket is refused.
Capabilities are random bearer values stored only as SHA-256 hashes in the gateway database.
No approval token, requester role environment variable, caller-selected state path, shell command, executable path, adapter, or redirect is accepted by the production protocol.

## Approval signatures

The approval channel issues one challenge per request and then accepts one signed approval against it.
The signature is over the exact canonical transcript bytes the broker recomputes from stored state, never over a transcript the caller echoes back, and the recomputed digest must still match the digest recorded when the challenge was issued.
A challenge is one-shot, expires within a minute, and is consumed only by an approval that verifies.
A refused signature is recorded as its own durable audit event and leaves the request `prepared`, so a failed attempt is visible and the approver can retry against the same challenge.

An approver is enrolled with an algorithm, a key, and an assurance class, and the class is recorded on the approval row, in the audit event, and in status output:

| Class | Algorithms | What an approval proves |
|---|---|---|
| `asymmetric-enrolled-key` | `ed25519`, `ecdsa-p256-sha256` | The broker holds only a public key, so it cannot mint the approval itself. This is the production class, and `ecdsa-p256-sha256` is the Secure-Enclave-compatible one |
| `software-test-hmac` | `hmac-sha256-test` | Transcript binding, challenge binding, replay refusal, and the state machine. Nothing about approver authenticity, because the broker holds the verification key |

There is no fallback between them in either direction.
The test class is refused at enrollment and at verification outside `FM_ACTION_GATEWAY_TEST=1`, and the asymmetric path refuses by name when its verification primitive is unavailable rather than accepting an unverified approval.
Asymmetric verification needs the `cryptography` module; when it is not importable the approval is refused with that reason stated, which leaves the gateway exactly as capable as it was before this slice rather than quietly less strict.

Enrolling the production approver is a captain step at the Mac: the key is generated in the Secure Enclave by the signing UI and never leaves it, so only its public half is enrolled.
The gateway records `attestation_verified: false` because it does not verify Apple attestation - that belongs to the Step 5 proof.

## Execution, and what settles it

Execution has two operations on the execution socket.

`claim` requires an approved, unexpired request, a matching immutable idempotency key, and a safe sink whose current bytes still match the plan.
It mints a one-shot lease, records the attempt ordinal, and moves the request to `executing`.
A second claim against a live lease is refused; a claim against an expired one durably records `unknown` and refuses.

`settle` is where the executor's report stops mattering.
The broker opens the safe sink's own receipt store read-only and looks for the record that this approved plan deterministically resolves to, and settles from what it finds:

| What the broker observes in the sink | Settled state |
|---|---|
| The exact expected record | `succeeded` |
| No record for this operation | `failed` - nothing was applied |
| A record that does not match this plan | `unknown`, reconciliation required |
| The store cannot be read | `unknown`, reconciliation required |

The executor's claimed outcome is recorded in the audit event as `executor_claimed_outcome` and never decides the state.
A relay that reports success it did not achieve settles `failed` or `unknown`, whichever the store actually supports.
A settle arriving after the lease expired is refused and leaves the recorded `unknown` in place, so a late return can never resurrect a terminal state.

Status reports a `settlement` word alongside the state, because "approved", "queued", "sent" and "applied" are different facts:

| State | Settlement |
|---|---|
| `prepared` | `awaiting-approval` |
| `approved` | `approved-not-yet-queued` |
| `executing` | `queued-and-sent-outcome-not-yet-observed` |
| `succeeded` | `independently-observed-as-applied` |
| `failed` | `independently-observed-as-not-applied` |
| `unknown` | `unobserved-requires-reconciliation` |

`executing` deliberately covers queued and sent together: once a lease is out, the broker knows the attempt is in flight and does not know whether the effect landed.
`unknown` means verify at the provider before retrying; it is not a failure and must never be rendered as one.

## The deterministic safe sink

The safe sink is the only executor the broker will claim for, and its effect is deliberately local and inert: one append-only record in its own store under the gateway state root.
It refuses any plan that claims an outward executor, and any plan whose bound executor hash is not its own exact bytes.

One approved plan resolves to exactly one record, built only from the plan's identity fields, so the broker recomputes the same bytes without asking the sink anything.
The idempotency key is the receipt store's primary key, so a repeated click, a retry, or a restart reports `already-applied` and changes nothing.
After committing, the sink re-opens its own store read-only and re-reads the appended line, and reports what it found rather than what it intended.

The sink derives its state root with the broker's rule rather than accepting one from the caller: a sink whose store the caller could relocate is a sink whose receipts the broker cannot use as evidence.

## The relay

`bin/fm-action-runner-v2.py` claims, runs the bound executor, and reports back.
It holds one per-job execution capability and one short-lived lease, and nothing else - never the approval capability, never an approver key, never the captain secret.
A relay that dies between running the executor and settling loses its lease, and the request becomes `unknown`.
That is the correct result rather than a gap: nobody observed the outcome, so nobody may assume it.

## Quarantine artifact importer

`bin/fm-action-artifact-import-v2.py` is the only sanctioned way an archive from outside the boundary becomes files inside it, and it imports in full or not at all.
Every member is validated before a byte is written, so a hostile archive cannot land its first members and leave the refused one as the only visible problem.
It refuses absolute paths, parent traversal, symlinks and hardlinks, device, fifo and socket members, duplicate names, non-portable names, and archives past its member, size, and depth ceilings, in both tar and zip containers.
The destination must exist, be a directory, and be empty, so no import ever merges into files somebody else placed.

It implements the `--artifact-adapter` argv contract in `docs/worker-boundary-regression.md`.

## Installation lifecycle

`bin/fm-gateway-install-v2.sh` produces what a privileged installation needs and shows exactly what it would do.
It never installs and never uninstalls: `apply` is present and always refuses, because creating the service principals, writing the root-owned ancestors, loading the launch definitions, and enrolling the approver key are the captain's own step at the Mac.

Two rules govern every path it names or emits.
Every privileged path is a literal constant, checked at startup for being absolute, normalized, and deep enough that a truncated or emptied constant cannot resolve to a shared ancestor.
Uninstall never deletes a directory tree: it moves each directory to a timestamped quarantine after checking the target is not a symlink, is contained in its expected parent, and is owned by the account that installed it.
The state root holds the audit record and every tombstone, and an uninstall that destroys the evidence of what the gateway did is worse than one that leaves a directory behind.

The emitted `install.sh` and `uninstall.sh` carry their own copies of those guards, because a person runs them standalone with sudo and cannot rely on the authoring script's checks.
Neither is executable and both refuse to run without an explicit confirmation flag.

## Unprivileged test commands

```sh
FM_ACTION_GATEWAY_TEST=1 TMPDIR=/temporary/root \
  bin/fm-action-gateway-v2.py prepare < request.json

FM_ACTION_GATEWAY_TEST=1 TMPDIR=/temporary/root \
  bin/fm-action-gateway-v2.py enroll-approver \
    --approver-id test-ui --algorithm hmac-sha256-test --key-material "$SECRET_B64"

FM_ACTION_GATEWAY_TEST=1 TMPDIR=/temporary/root \
  bin/fm-action-gateway-v2.py issue-capability \
    --purpose prepare --job-id synthetic-job --uid "$(id -u)"

FM_ACTION_GATEWAY_TEST=1 TMPDIR=/temporary/root \
  bin/fm-action-gateway-v2.py serve \
    --socket-root /temporary/root/run

FM_ACTION_GATEWAY_TEST=1 TMPDIR=/temporary/root \
  bin/fm-action-runner-v2.py run --socket-root /temporary/root/run \
    --capability "$EXECUTION_CAPABILITY" --request-id "$REQUEST_ID" \
    --idempotency-key "$IDEMPOTENCY_KEY"
```

`inspect-test-paths` exposes synthetic canary paths only in test mode so the Step 1 regression harness can probe the v2 database and audit boundary without assuming the removed filesystem approval inbox.
`test-mark-executing` exists only to reproduce an interrupted execution under a temporary root.
Neither command is installed as production administration.

## Evidence boundary

The tests prove parser, plan, transaction, replay, crash recovery, concurrency, protocol separation, peer credential lookup, per-job capability behavior, device-plan resolution, approval signature verification, lease-bounded execution, sink-derived settlement, exactly-once application, and importer refusals, all under an ordinary temporary-root UID.

They do not claim distinct installed macOS principals, root-owned ancestors, Secure Enclave enrollment, signed UI identity, root launch definitions, network isolation, or privileged uninstall behavior.
Every test here runs as one UID, so nothing in this suite is evidence about separated principals.
Those cases remain explicitly assigned to the captain-at-Mac Step 5 proof, and `bin/fm-worker-boundary-regression.sh` is what measures them once an installation exists.

Exactly-once is proved against the safe sink's own store, which is a local SQLite primary key.
That is a real exactly-once property for this executor and is not evidence about any outward provider's idempotency.
