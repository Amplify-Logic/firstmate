# Action gateway

The outward-action gateway is the single choke-point for worker side effects that leave the local machine or touch real people, money, or devices.
This document owns the ActionRequest schema, the canonical digest, the transactional state machine, and the non-graduatable policy floor.
`bin/fm-action-gateway.sh` is the broker for this slice: prepare / approve / execute-stub / status / replay, with durable append-only records and **no outward action execution**.

## ActionRequest schema

JSON object with exactly these top-level fields:

| Field | Type | Meaning |
| ----- | ---- | ------- |
| `task_id` | string | Path-safe task id (1-64 chars from `[A-Za-z0-9._-]`, not dots-only) |
| `domain` | string | Logical domain (for example `aquablu`, `travel`, `music-outreach`, `app-dev`) |
| `action_kind` | string | Operation / kind of outward action (for example `http.request`, `email.send`, `purchase`) |
| `target` | string | Action target (URL, address, device id, and so on) |
| `parameters` | object | Action-specific parameters (may be empty); amount/recipient fields participate in the digest |
| `requested_consent_tier` | string | One of `confirm-first`, `autonomous`, `sandbox` |
| `environment` | string | Execution environment label bound into the digest (for example `local`, `prod`) |
| `policy_version` | string | Policy version string bound into the digest |
| `idempotency_key` | string | Caller idempotency key; reuse with a differing digest is refused |
| `expires_at` | integer | Unix epoch seconds after which approve/execute refuse |
| `nonce` | string | Fresh nonce bound into the digest (blocks blind replay of an old shape) |

Example:

```json
{
  "task_id": "book-flight-42",
  "domain": "travel",
  "action_kind": "purchase",
  "target": "https://airline.example/checkout",
  "parameters": { "amount_cents": 42000, "currency": "EUR", "recipient": "airline@example" },
  "requested_consent_tier": "confirm-first",
  "environment": "prod",
  "policy_version": "1",
  "idempotency_key": "travel-book-flight-42-v1",
  "expires_at": 1893456000,
  "nonce": "n-7f3a9c2e"
}
```

## Canonical action digest

An approval binds to a SHA-256 digest over a canonical JSON object of:

- `operation` (from `action_kind`)
- `target`
- `parameters` (sorted canonical JSON)
- `amount` (from `parameters.amount_cents` / `amount` / `price_cents` / `value_cents`, or null)
- `recipient` (from `parameters.recipient` / `to` / `email` / `phone` / `address`, or null)
- `environment`
- `policy_version`
- `idempotency_key`
- `expires_at`
- `nonce`

A differing digest is a different action.
Approve requires the one-shot token issued at prepare for **that exact digest**.
Expired digests and replayed tokens are refused.
This is the load-bearing control against "approve title X, swap the action" and token replay.

## Transactional state machine

Per ActionRequest (keyed by digest), states advance only through append-only, fsync'd events in `data/action-audit.log`:

`prepared` -> `approved` -> `executing` -> (`succeeded` | `failed` | `unknown`)

Rules:

- Audit/state events commit before any decision line is printed for mutating commands.
- A restarted broker replays the log, defaults decision posture to `confirm-first`, and treats in-flight `executing` without a terminal event as `unknown` (persisted on `replay`).
- This slice never reaches a real `succeeded` via an outward effect: `execute` is stubbed and records `executing` then `unknown` with `reason=execution-not-wired`.

## Non-graduatable hard ceilings

Spending money and outward messaging to real people are **always** `confirm-first`.
No future consent tier, watchdog graduation, or `requested_consent_tier=autonomous|sandbox` may raise this floor.

| Ceiling | Triggers |
| ------- | -------- |
| `spend` | `action_kind` in `purchase`, `payment`, `spend`, `transfer`, `checkout`, or parameters carry an amount field |
| `messaging` | `action_kind` in `email.send`, `message.send`, `sms.send`, `chat.send`, `notify.person`, `outreach.send`, or messaging-prefixed kinds with a recipient field |

The prepare record stores `ceiling` when applicable.
The broker decision remains `confirm-first` regardless of the requested tier.

## Broker commands

```
fm-action-gateway.sh prepare [--file <path>]   # default when stdin / --file only
fm-action-gateway.sh approve --digest HEX --token TOKEN
fm-action-gateway.sh execute --digest HEX      # stub only
fm-action-gateway.sh status --digest HEX
fm-action-gateway.sh replay
```

Mutating commands print `key=value` lines (at least `decision=` and `state=`) only after the durable append succeeds.

## Gateway contract

- The gateway is the single choke-point: workers emit ActionRequests; they do not fire outward side effects themselves.
- Consent tiers are watchdog-style demotion/alerting inputs layered **above** deterministic ceilings, never a privilege ladder over spend/messaging.
- Trust state lives in the append-only audit log so a restarted gateway is confirm-first until it replays history.
- Execution is not wired in this slice; proving absence of outward effects is part of the test suite.

## Future work

Real allowlists, anomaly detection, watchdog demotion signals, dry-run sandbox graduation, interrupt-priority scheduling, OS/network capability separation, and a privileged executor that performs the exact digested action (or hands a one-shot capability to an isolated executor) remain future work.
Browser isolation itself remains independent of consent tiers; see [`docs/worker-browsing.md`](worker-browsing.md).
