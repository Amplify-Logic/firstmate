# Continuous channel intake

Operator procedure for the opt-in continuous intake gate.
`docs/configuration.md` owns the configuration schema and how this fits the rest of the fleet's scheduling.
`bin/fm-channel-intake.sh --help` owns the exact commands, flags and mechanics.
This document owns the install and rollback procedure, the private inventory format, the division of work between the gate and its orchestrator, and the detection limits that must be disclosed rather than glossed.

## What is implemented and what is active

Implemented means the tracked code exists and its behavior suite passes.
Active means a device has opted in, installed the schedule and armed the live check.
They are separate on purpose, and a report about this feature must state both.
Nothing in this repository activates itself: the gate is inert on every home without an `enabled = true` line, and the schedule refuses to install on a home that has not opted in.

## The division of work

The gate is local only.
It never reads a source system, never opens a network connection, never sends a message, never spawns an agent, and never takes the per-home session lock or the watcher lock.
It decides when a source is worth reading, remembers what has already been seen, and renders what the captain still owes.

An orchestrator does the authenticated connector read on its own path and reports back.
That split is what keeps a poll cheap: the incremental checkpoint read is the gate's decision, and no reasoning agent is paid for merely to discover there is no work.
If connector access itself needs an agent, that agent's cadence, work and quota are bounded and disclosed by whoever configures it; nothing here invents a webhook or a subscription, because the connectors in use expose none.

A tick therefore looks like this.

1. launchd runs `tick`. It reads no source and finds the due set from each source's own checkpoint and backoff.
2. If anything is due it records one armed cycle and appends exactly one wake.
3. The orchestrator runs `claim`, which hands back each due source's checkpoint, its coverage sentence, the bounded revision window, and the tracked thread parents with their reply markers.
4. The orchestrator reads those sources through its own authenticated connector path.
5. Each observed message becomes one `observe` call carrying a stable source id and a content digest.
6. `complete --source ID --checkpoint VALUE` advances that source's checkpoint, or `fail --source ID --reason TEXT` records the failure and backs off.

## Install

Every step is local to one device and one home.

1. Write the private, gitignored `config/channel-intake`.
   Start from the key list in `bin/fm-channel-intake.sh --help`.
   `enabled = true` is the opt-in. `notify_recipient` and `notify_recipient_verified` are covered under "Recipient verification" below.
2. Write the private, gitignored source inventory, by default `data/channel-intake/sources.tsv`.
   Its format is under "The source inventory" below.
3. Confirm the resolved configuration with `bin/fm-channel-intake.sh status`.
   It prints declared knobs only, and never the recipient identity itself.
4. Install the schedule with `bin/fm-channel-intake-schedule.sh install`.
   That writes `~/Library/LaunchAgents/<label>.plist`, loads it, and arms the live watcher check.
   Inspect the definition first with `render` if you want to read it before it is loaded.
5. Confirm with `bin/fm-channel-intake-schedule.sh status`.

Firstmate owns installing the schedule and enabling live notifications.
A worker prepares the configuration; it does not activate it.

## Rollback

1. `bin/fm-channel-intake-schedule.sh remove` unloads the LaunchAgent and disarms the live check.
2. Setting `enabled = false` in `config/channel-intake` makes every command inert again, including the read-only session-start surface.
3. Deleting `config/channel-intake` returns the home to the shipped state.

Removing the schedule deliberately leaves the ledger under `data/channel-intake/` in place.
An open obligation must survive an uninstall, and removing a schedule is not the same as discarding what the captain still owes.
Discarding the ledger is a separate, explicit deletion.

## The source inventory

Tab-separated, hand-maintained, gitignored, and the only place a channel id, mailbox or board id lives.
Tracked code reads it; tracked code never contains it.

```
<id><TAB><kind><TAB><coverage sentence>
```

`id` and `kind` must be leading-dot-free slugs of `[A-Za-z0-9._-]`, because both reach paths under `data/channel-intake/`.
The coverage sentence is free text and is rendered verbatim on the brief.

The file is also the explicit coverage statement, and that is its more important job.
A row is one enrolled source.
Enrolling the channels the daily brief and improvements intake already use does not enrol every channel in the workspace, and the brief says so in its own words on every render.
Coverage is stated, never implied.

## Recipient verification

Notifications are refused outright until `notify_recipient_verified = true`.
Set it only after the configured `notify_recipient` has been checked against the known captain account, not because the value looks right.
Standing scope covers concise private intake alerts to the captain and nobody else.
It does not authorize a public or channel reply, a message to a customer, or notifying any other user, and no command here can send one.

## Delivery surfaces

Three destinations, and they are not interchangeable.

| Class | Destination | Constraint |
|---|---|---|
| `urgent`, `outage`, `deadline` | one grouped private direct message, plus the daily to-do list | rate-limited, capped per local day, quiet hours respected |
| `routine` | the brief only | never a ping |
| `obligation` | the daily to-do list | not the Action Deck |
| `automation-candidate` | a proposal in the brief | never an executable card |

The Action Deck is for automations the captain fires directly, with preview, exact target, the existing per-action approval, and post-execution evidence.
It is not a task inbox.
This gate has no path that writes anything the deck renders, and the behavior suite asserts that.
Detecting that a device or account needs an action grants no permission to perform it; that stays with the action gateway.

`notify-due` renders and does not send.
The orchestrator sends the payload and then calls `notify-sent --keys "..."`, which is what stamps the items.
An interrupted send therefore re-renders on the next pass rather than being silently swallowed.
An item the captain resolves between the render and the confirmation is skipped and named on stdout; the rest are stamped and the payload still counts against the daily cap, so a delivered alert never re-renders.

A payload that cannot go out says why.
`status` prints `notifications_state`, and `pending` and the live check name the condition in words: `blocked` when the recipient is unset or unverified, `held` when the daily cap is spent or the minimum gap has not elapsed.
Nothing is lost in either case - the items stay notifiable and re-render once the condition clears - but neither is ever reported as nothing to send, because "no alert went out" and "nothing needed an alert" are not the same fact.

`brief` and `todo` render from the same ledger every time.
A correction, a resolution and a completed obligation reconcile across both by construction rather than needing a second pass over two stores.
Both accept `--out FILE` inside the configured `report_dir` and overwrite the same path, so a background render updates the existing page instead of leaving a trail of dated files; a path with a `..` component is refused before the directory check.

Opening a rendered page is opt-in and never automatic.
A report the captain asked for is rendered with `--open`, which opens the written page as soon as it is ready; that flag is the only thing in this gate that opens anything.
A scheduled or background render omits it, writes the same path, and never takes focus - the launchd job only ever runs `tick`, so the flag cannot reach it.
`--open` without `--out` is refused, because there is no page to open.

The opener is `open_command`, defaulting to `open` on macOS and `xdg-open` elsewhere; `status` prints the one that would be used.
It fails soft on purpose: an opener that is not installed, or one that exits non-zero, is reported as `could not open <path>` and the command still succeeds with the page written.
The render is the deliverable and the open is a convenience, so a missing viewer must never turn a written report into a failed command.

## Resolution

An obligation is discharged by content, not by the fact that somebody replied.
An acknowledgement or a promise to act is not a completion.

- `resolve --item KEY --reason TEXT` archives the item. The active list loses it; the archive keeps its source, ref, link, provenance, revision count and the reason it was closed.
- `resolve --item KEY --waiting --reason TEXT` is the honest middle state for work handed to someone else. The item stays on the ledger under waiting-on-others.

A resolved ask is never reopened by a poll.
A reaction or an unchanged re-read reports `archived-unchanged` and does nothing.
Even a genuine later edit only reports `archived-changed` and annotates the archived record; reopening is a captain decision.
The brief then says the item was edited after it was closed and that it stays closed, bounded like every other row there.
The annotation is carried alongside the archived evidence rather than rewritten into it, so the source, ref, link, provenance and reason it was closed stay verbatim.
A later edit supersedes an earlier annotation, and an unchanged re-read of the same edit changes nothing.

## Disclosed detection limits

Both limits are real, bounded by design, and rendered on the brief itself so a reader is never left to assume completeness.

**The edit horizon.**
An in-place edit keeps the original source id, so a forward cursor never returns it again.
Re-detection depends entirely on the orchestrator re-reading the bounded recent window that `claim` hands over as `revision_window_from`, and re-observing what it finds; the digest comparison in the gate then updates the same item.
An edit to a message older than that window is not detected.
Widening `revision_window_seconds` costs a proportional re-read on every tick.

**Thread replies on older parents.**
A cursor read of a channel returns messages whose own id is newer than the cursor.
A reply added to a thread whose parent predates the cursor can therefore appear in no such read at all.
`observe --thread PARENT --reply-marker VALUE` records a per-parent reply marker, and `claim` prints the tracked parents back so the orchestrator re-reads only the threads whose marker advanced.
That covers parents still inside the tracked set and nothing older.
No completeness is claimed for new replies on old threads.

To reproduce the gap before relying on any coverage claim: note a parent message older than the current checkpoint, locate a reply on it, then run the same cursor read and confirm the reply does not appear.

**Latency is a target, not a bound.**
The poll interval is a target detection latency.
Real latency also absorbs sleep and offline stretches, rate limiting and backoff, quota exhaustion, agent queue delay, and the tick's own completion time.
`status` reports measured detection latency from real samples rather than projecting it from the interval, and the brief states the same caveat in place.

## Cost and quota discipline

`interval_seconds` has a hard 300-second floor, because an awake laptop multiplies the cadence by every enrolled source.
A source whose read failed backs off geometrically to `backoff_max_seconds`, so a permanently broken source settles into a cheap heartbeat instead of a retry loop.
One armed cycle produces one wake, no matter how many ticks fire inside it.

A throttle reported by a connector is a reason to call `fail` and back off.
It is never a reason to retry harder, and the request-rate ceiling is deliberately not measured by hitting it: that would spend the account's quota for every other lane and teach little.
Honour whatever `retry-after` or error backoff the connector reports.

Per-tick cost is a function of the enrolled source count and thread activity.
Measure it on the real inventory rather than projecting it from one channel.

## Session-start surface

`bin/fm-bootstrap.sh` calls `pending`, which is read-only and silent on a home that has not opted in or has nothing owed.
It reports due sources, items ready to send or blocked or held, sources reading `unknown`, and a live check that has gone absent or unregistered, naming `arm-check` as the repair.
`.agents/skills/bootstrap-diagnostics/SKILL.md` owns the response to each of those lines.
A source reading `unknown` did not complete its last read.
That is not the same as nothing new, and it must not be reported to the captain as quiet.

## Maintaining this file

Keep current operating procedure here and exact mechanics in the script's own header and `--help`.
State each contract once and cross-reference it everywhere else.
Do not copy the configuration schema from `docs/configuration.md` or the command list from the script into this file.
