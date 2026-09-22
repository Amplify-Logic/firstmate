---
name: usage-restoration
description: Rebuild and restore a dispenser's lost usage, filter and service counters after a storage-file corruption or a dispenser swap.
metadata:
  internal: true
---

# usage-restoration

Load this when a partner asks for a system's usage to be restored, when a system's totals drop to zero or to an obviously wrong value, or when a system reports `A.13 storage file corrupted`.
It is the single owner of the restoration method.
It does not authorize sending anything: the captain sends every command himself in the FOTA portal after seeing the exact payload, and that stays true however routine the restoration looks.

## What is actually lost

The dispenser keeps its lifetime counters in a storage file on the device.
When that file is corrupted or the dispenser is replaced, the counters restart from zero while the machine keeps running normally, so nothing else looks wrong.
The device raises `A.13` when it detects the corruption, which is the earliest signal available.
That code is currently invisible in AURA's Snapshot Log, so nobody is told; do not expect a partner to have reported it.

Restoration means writing the pre-loss values back, not estimating them.
Every value below comes from a real snapshot reading.

## Stage 1 - find the loss point

1. Pull the system's snapshot history: `GET /refills/<id>/snapshots?limit=500` on `https://dashboard.aquablu.com/api`.
   Only `limit` works, up to 500; `&page=N` returns empty.
2. Read `latest_snapshot_v3` fields, and walk the history backwards until a counter drops instead of rising.
   The reading immediately before the drop is the last good one, and its values are what gets restored.
3. Check for more than one reset.
   A system can lose its counters twice, and restoring only across the most recent loss silently keeps the earlier loss.
4. Snapshot timestamp strings are UTC.
   This is proven, not assumed: a twin epoch of 1790064365 carries the string `2026-09-22 08:06:05`.
   Never read `kpn_timestamp` as a guide; it is local.

## Stage 2 - tell a dispenser swap from a Fizz swap

The system ID is the IMEI of the SIM module in the dispenser, so replacing the dispenser always produces a new system ID even though nothing else changed.
`fizz_uid` is the discriminator:

- New system ID, same `fizz_uid`: only the dispenser was replaced.
  The Fizz Pro and its filters carried over, so the filters keep the original installation dates and their accumulated volume.
- New system ID, new `fizz_uid`: the Fizz was replaced too, and its filters are genuinely new.

Getting this backwards dates the filters to the swap and pushes the partner's next filter change months late.
Read `fizz_uid` on both the old and the new system before writing a single filter date.

## Stage 3 - rebuild the values

Restore the sum, not a guess at the split.

- `ambient`, `chilled` and `sparkling` totals are the three usage streams.
- `left_usage_ml` and `right_usage_ml` count water since that filter was last changed, and they reset to zero on a filter change while `left_replaced_time` restamps.
  They only balance against ambient plus chilled plus sparkling when the filters were never changed.
  When they do balance, check the invariant holds exactly; a mismatch means a filter change you have not accounted for.
- Filter allowances are `left_full_ml` 8,000,000 and `right_full_ml` 4,000,000.
  This is why the volumes matter: a filter is replaced at six or twelve months **or** at its litre limit, whichever comes first, so a zeroed counter hides an overdue filter.
- Restore the service and filter dates from the last good pre-loss reading.
  Leaving the reset stamps in place tells the partner the filters were changed on the day of the data loss.

Read-side and write-side field names differ, and this catches people out every time:

| Read as | Write as |
|---|---|
| `ambient_usage_ml` | `ambient_used_ml` |
| `left_usage_ml` | `left_used_ml` (Queco's tool) or `left_filter_used_ml` (FOTA portal) |
| `left_replaced_time` | `left_filter_timestamp` |
| flavour dates | `f1_timestamp` and siblings |

Confirm which spelling the surface the captain is using expects before drafting; do not carry one surface's names to the other.

## Stage 4 - draft the commands

Commands are SenML: `[{"n":"<field>","v":<int>}]`, integers only.
The KPN transport carries at most ten values per command, and a longer block does not partially apply, it fails.
The captain asked for at most three commands per system, so group them:

1. Volumes: the usage totals.
2. Flavour dates.
3. Service and filter dates.

Five, four and five values is the shape that fitted both machines.
Present each command as a copyable block with the system named above it, and state plainly what each command sets.

## Stage 5 - verify

After the captain sends, wait for the next hourly snapshot and read every field back one by one.
Do not report a restoration as done on the strength of the send.
A field that did not take is not a transport failure to shrug at: it means the device refused that value, and the partner is still looking at wrong numbers.

## Known open question

Keiko's position is that a filter value will be accepted by the command path but not written through to the database.
That has not been proven either way here.
Check the filter fields explicitly in Stage 5 and record what actually happened, because it decides whether filter restoration needs a different route entirely.
