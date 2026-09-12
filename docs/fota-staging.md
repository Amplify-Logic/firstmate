# Device configuration staging

Staging prepares and verifies a device configuration command **without sending it**.
It is the first capability built on the action gateway's registry, and it deliberately stops one step short of any outward effect: the send is a different control, a different action kind, and a different authority.

`bin/fm-fota-stage.py` owns preparation and the staging-plan schema.
`bin/fm-fota-stage-run.sh` owns background runs and their states.
Neither holds approval authority, and neither sends.

## Why staging is its own capability

A configuration change to customer hardware is irreversible in the way that matters: there is no branch to discard.
Splitting the work at the send boundary means the expensive, error-prone part - resolving the target, encoding values correctly, rendering the exact payload, and proving the form holds what was intended - happens under review, repeatedly if necessary, with nothing at stake.
Only the final click carries risk, and it stays with a person.

This also makes a staged command reviewable as an artifact.
The operator sees the exact payload that would be sent, against the exact target, with the encoding rule that produced every number, before anyone decides anything.

## The adapter definition is local data, never code

The portal identity, field map, device rules and confirmed encodings live in an adapter definition passed with `--adapter`.
That file is **local, captain-approved data kept outside this repository**, for two reasons: this repository is public, and a customer portal's address and device identifiers are not ours to publish.

The tool accepts no command, executable, or URL from the adapter that it would run.
The adapter supplies *parameters*; the tracked code supplies *behaviour*.
`tests/fixtures/staging-portal/adapter.json` is a neutral fixture with invented names - if anything site-specific were compiled into the tool, that fixture could not exercise it.

## Encodings are per key, never per device model

A setting and a reported measurement can use different rules **on the same device**.
A value that decodes sensibly under one rule can decode to nonsense under the other, and nothing in the raw number says which applies.

So every setting declares its own encoding, and every emitted number carries the name of the rule that produced it.
A declared encoding that is not also marked confirmed is **refused, not guessed**: a wrong encoding produces a plausible number that means something else entirely, which is worse than producing nothing.

## Eligibility is an observed fact, never an inference

Three things are commonly mistaken for evidence that a device supports a setting.
Only the third is:

| Signal | Weight |
| --- | --- |
| The device model prefix | Necessary at most. Never sufficient |
| The portal offers the control | **No weight.** A control can be offered on hardware that cannot use it |
| An observed row for that setting, on that device | The only evidence that counts |

Without observed rows a plan reports `eligibility: unverified` and says so plainly.
It does not refuse - an unverified plan is still worth reviewing - but it never presents the target as writable.

## Policy validation is separate from physical safety

The tool checks what is checkable: values in range, ordered pairs correctly ordered, encodings declared and confirmed, identity well-formed.

It makes **no claim about physical behaviour**, and this separation is deliberate rather than modest.
A configured bound does not constrain what hardware actually does, and a reported measurement can differ from the condition it describes.
Choosing values is an operator judgement informed by how a specific site behaves; a preview that graded a configuration as "safe" would be inventing authority it does not have.
Every plan carries `physical_safety.claimed: false`.

## Operation identity, and why a repeated click is not a second command

The gateway's digest binds one *approval* to one exact preview - it includes a nonce and an expiry, so re-preparing the same real operation produces a different digest.
That makes the digest the wrong thing to deduplicate on: two preparations of one intent look like two different actions.

Operation identity is therefore computed separately, over what makes two requests the same operation: the action kind, the target, the setting keys and their wire values, and the environment.
No timestamp, no uuid.
A deliberate retry raises an explicit **attempt ordinal**, which is part of the key, so an intended retry is a new identity by construction while an accidental repeat is not.

`fm-fota-stage-run.sh start` refuses a second run for an operation that already has a prepared, live, or ready one, naming the existing run.
The guard covers the queue step, so a first attempt that did not land is never quietly enqueued again; a deliberate retry raises the attempt ordinal.

Run ids are claimed with `O_EXCL`, so two starts in one wall-clock second cannot share an id.
A settled record is never written over, and a run never adopts an id whose result file already exists - a stale result read as a new run's readback is exactly the evidence loss `unknown` exists to prevent.

## Delivery: four facts, never collapsed

Generating a request file is not delivering it, and delivering it is not doing it.
`start` invokes the documented supported transport - `codex queue --thread <thread> --message <text>`, per [`desktop-companion.md`](desktop-companion.md) - against the explicitly configured companion, and stores the queue receipt on the run record.

| Fact | What proves it | What it does **not** prove |
| --- | --- | --- |
| Prepared | The generated request file exists | That anything received it |
| Queue accepted | The transport exited 0 and returned a receipt, stored as `queue.receipt` | That the companion dequeued it |
| Pickup | A result file carrying this run's id appeared (`pickup_observed`) | That the preparation succeeded |
| Verified result | The readback matched this plan's target and payload | Nothing further - this is the end of staging |

The companion thread comes from `FM_FOTA_COMPANION_THREAD` or from a `fm.desktop-companion-connection.v1` record at `<return dir>/connection.json`.
With neither, nothing is enqueued at all - which is what keeps this worker away from a companion it was never pointed at.
The transport command itself is `FM_FOTA_QUEUE_CMD` (default `codex`), so tests inject an isolated stub rather than reaching a real session.

A missing transport, a non-zero queue exit, and a queue timeout are each an honest state, and **none of them ever re-queues**.
A timeout is the one genuinely ambiguous case - the message may or may not have been enqueued - so the run stays live and the duplicate guard keeps it from being sent a second time on that doubt.

## The five run states

| State | Meaning |
| --- | --- |
| `prepared` | Request generated, but no transport took it: none configured, none installed, or a non-zero queue exit. Nothing was enqueued |
| `pending` | The transport took it, or timed out without saying whether it did; no result yet |
| `ready` | A result arrived **and** its readback matched this plan's target and payload |
| `error` | The result reported a definite failure, or its readback definitely contradicted the plan |
| `unknown` | No result inside the deadline, an unreadable result, or a result asserting success without the readback to support it |

**`unknown` is not a failure**, and collapsing the two is the mistake this design exists to prevent.
It means the world was not observed - which is different from having observed that nothing happened.
An unobserved outcome is verified at the portal by a person.
It is never retried automatically.

`ready` requires an **independent readback**.
A result file is untrusted input written by the browser side; it is evidence only where it reports something it actually read.
A claim of success with nothing read back settles `unknown`.

## One authoritative readback

The generated request asks for the staged field to be read back **once**.

This is a deliberate constraint rather than an oversight.
A redundant second check is not free: it is another operation that can time out on its own, and a timeout in a verification step turns a completed preparation into a misleading failure.
Worse, in any phase that can carry an effect, spurious ambiguity is indistinguishable from real ambiguity - so an extra check can manufacture the exact uncertainty the design works to avoid.

One authoritative readback, trusted or not trusted on its own terms.

## Navigation ambiguity is not effect ambiguity

A timeout says nothing about whether the underlying action happened, so the contract separates phases rather than error text:

| Phase | Effect | On ambiguity | Retry |
| --- | --- | --- | --- |
| Open target | none | Resolve by inspection | Never a second navigation |
| Verify target | none | Re-read; abort on mismatch | Safe |
| Stage draft | none | Re-read the field | Safe, after re-verifying the target |
| Send | **yes** | Terminal `unknown` | **Never, by any path** |

Navigation ambiguity resolves by inspection because a tab at a URL is the same artifact however many navigations produced it.
A send leaves no such artifact.
A command history is not the equivalent: where delivery is asynchronous, absence from history does not prove non-delivery, so history is evidence and never authorization to resend.

## The target is the page, not the payload

Where a portal adds the device identifier from page context, the effective target is whichever page is loaded - so a correct-looking payload staged on the wrong page reaches the wrong machine while every local record still names the right one.

A plan therefore carries `must_verify_against_loaded_page: true` and starts at `verified_against_page: false`.
A run settles `error` when the readback target is not the plan's target.

## Registry and ceiling

`device.config.stage` is registered `external`, and every `device.*` kind carries the non-graduatable `device` ceiling - so no configuration or standing order can graduate a device action out of per-change approval, at any severity.
The send, `device.config.push`, remains `irreversible` and is not wired.
See [`action-gateway.md`](action-gateway.md).

## Local activation and rollback

Activation is opt-in and consists entirely of supplying a local adapter definition; there is no daemon, no launch agent, no server, and no configuration change:

1. Write an adapter definition matching `fm.fota-adapter.v1` (see the fixture for shape). Keep it outside this repository.
2. `bin/fm-fota-stage.py --adapter <path> --request <path> --out <plan>` - produces a plan and prints its preview hash, operation identity, and eligibility state.
3. `bin/fm-fota-stage-run.sh start <plan>` - generates the request, queues it to the configured companion, and records the run with its queue receipt.
4. `bin/fm-fota-stage-run.sh settle <run-id>` - reads the result and decides one state.

5. `bin/fm-fota-stage-run.sh ack <run-id>` - records that the captain has seen a settled preparation alert, so the deck stops listing it as an open ask.

Acknowledgement is the only way a settled run leaves the active ask list.
It is refused on every live state (`prepared`, `pending`, `ready`), never deletes a record, never changes an outcome, never marks a command applied, and expires nothing on a timer: an `unknown` stays `unknown` forever, because that is the evidence.
The acknowledgement is bound to the exact outcome it was given for, so if that outcome ever changes the old acknowledgement does not carry over and the run returns to the ask list.
`list` and `show` keep the full history either way; only the active ask list is affected.

Acknowledgement lives on the run record rather than through `bin/fm-decision-hold.sh`, because that owner holds backlog decisions with dependent tasks routed to them, which is a different thing from an operational result someone has now looked at.
Records and requests are written `0600` under `0700` directories, and settle rewrites a record whole and moves it into place, so a crash cannot leave a half-written record that quietly drops a run off the pane.

**Rollback** is deleting the adapter definition: with no adapter, nothing can be staged.
Run records live under `state/fota-staging/` and may be removed freely - they are evidence, not state anything depends on.
Nothing in this capability writes to a device, a production database, or the gateway's audit log.

## What this is not

This is not the full execution layer.
It prepares and verifies; it does not send, and wiring a send is explicitly **not** part of it.
Execution belongs to the v2 broker, whose prerequisites and pointers are recorded in the delivering task's report rather than duplicated here.
