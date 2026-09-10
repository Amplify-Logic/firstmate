# The shift loop

`bin/fm-shift.sh` arms the captain's glasses voice loop before he leaves on a delivery shift, stands it down when he is back, and tells him in his ear if it dies while he is out.

## Why it exists

The loop itself already works: the captain speaks through his glasses, a phone app posts into a mailbox on his Mac over Tailscale, firstmate answers, and the answer is spoken back.
The problem was never capability.
It was that arming the loop meant remembering four separate things at once, and when one of them was not true he found out by talking into silence three streets from home.

This command removes that.
It verifies every precondition before arming anything, refuses by name when one fails, and while a shift is armed it makes an outage reach his ear instead of staying silent.
`bin/fm-shift.sh`'s own header and `--help` own the exact commands, environment overrides, and defaults.

## What it verifies before it arms anything

A half-armed shift is worse than a refused one, because he leaves believing it works.
So `start` checks all of the following first, and a failure in any of them refuses the whole thing with the cause and the fix named:

- **Mains power and sleep.** The keep-awake agent's caffeinate assertion only holds off system sleep on AC power, so a shift on battery is a dead loop.
  A battery refusal also says the lid must stay open.
- **The mailbox.** Its LaunchAgent must be running and its loopback `/health` must answer 200.
  A sick mailbox is restarted through launchd and re-checked; a second copy is never started by hand, because it would fight launchd for the port.
- **The phone's route in.** The Tailscale Serve mapping the phone actually targets must exist.
  A Serve config reset drops it, so a missing mapping is re-armed and then verified rather than assumed.
- **A working way to speak.** The announce path is proven end to end with a dry run, which spends no credit, so the confirmation at the end is very unlikely to be the first thing that fails.
- **Supervision.** This home's session lock must be held and a watcher must be live: a question nobody is awake to hear is the same as no loop at all.
- **A host sentinel that can fire.** The launchd sentinel described in [`wedge-alarm.md`](wedge-alarm.md) is the only thing that detects a watcher outage during a shift, so it must not be deliberately disarmed, must have no failed registration on record, must have completed a recent scheduled check, and must exist on this host at all.
  Each of those is read from the sentinel's own durable records, so `status` stays read-only, and each refusal names `bin/fm-supervision-sentinel.sh enable` as the fix where that is the fix.

## What it arms

Everything here is an existing owner being started, not a new mechanism:

- Away mode through `bin/fm-afk-launch.sh start`, which is what keeps firstmate answering while he is out.
  The native background path is deliberately not used: on a memory-constrained Mac, memory pressure killed that daemon three times in one night, so the tracked-terminal launch owner is the one that survives a shift.
- The outage self-check, an ordinary watcher check registered through `bin/fm-check-register.sh`.
- The supervision alarm route: one sentinel-delimited `command:` directive appended to `config/wedge-alarm`, so the host sentinel's watcher-outage alarm is spoken instead of only raising a desktop banner he cannot see.
  `stop` removes exactly that block and leaves any directive the captain wrote himself untouched.

Then it speaks one short confirmation, so he hears that the loop is up rather than having to look at a screen.
If that line cannot be spoken even though every check passed, the command says so loudly and exits non-zero: he must never leave believing he heard a confirmation he did not.

## The self-check, and what it can and cannot say

The registered check runs on the watcher's ordinary check sweep.
It prints one line only when firstmate should wake - the moment the loop stops answering, and the moment it comes back - and prints nothing on every other sweep.
One continuing outage produces one log line and one spoken line, never one per sweep, the same way the watcher's own stale handling works.
Each edge is appended to `state/.shift-log` as one plain timestamped line (`<ISO8601-UTC> <event> <detail>`, with the events `armed`, `down`, `up` and `stood-down`), which is what the `stop` report reads.
It is deliberately not a `state/*.status` file and carries no crewmate protocol verb, because a shift is not a crew task and must not read as one to the watcher or the session start.

**A mailbox outage cannot be spoken while it lasts.**
The glasses have exactly one channel to the captain's ear and it is the mailbox, so while the mailbox is down there is nothing to speak through.
The check therefore records the outage and wakes firstmate to repair it, and speaks a single line when the loop returns, naming how long it was gone.
That recovery line is the only one that can actually reach him, which is why it exists.

A supervision outage is different: the mailbox is still up, so it can be spoken.
Detection belongs to the host launchd sentinel described in [`wedge-alarm.md`](wedge-alarm.md), which checks the home once a minute from outside the harness process tree.
While `state/.shift` exists it treats the home as worth supervising even with no crew task in flight, because shift questions arrive as mailbox events and never as tasks.
That matters most when the away daemon dies, since the watcher is its child and no registered check runs at all after that; the host sentinel is then the only thing left that can speak.
Its alarm goes out through the `command:` directive `start` installed, which runs `fm-shift.sh alarm`, so a dead watcher is spoken once the beacon grace has passed plus one check interval, not instantly.
That alarm is spoken as one plain line; the raw outage summary carries task ids and durations and is read only to tell the two alarm kinds apart, never relayed.

## What it deliberately does not do

- It adds no daemon, no wrapper, no control plane, and no LaunchAgent of its own.
- It reimplements neither away mode, nor the watcher, nor the mailbox; it orchestrates their existing owners and adds only the preflight and the self-check.
- `stop` leaves the mailbox, the keep-awake agent, and the Tailscale mapping running.
  Those are standing services the captain also uses at his desk; tearing them down would break that too.
- `status` exits non-zero only when a shift is armed and one of its components is down.
  With no shift armed it still prints an honest line per component, but claims no failure, because nothing is claiming to be armed.

## Verification (macOS, darwin, 2026-09-09)

`status` never mutates anything, so it is the one command that can be run against the live loop as evidence.
Recorded on the captain Mac with the real power state, the real LaunchAgents, the real Tailscale Serve config, and a real announce dry run, which spends no credit and queues nothing:

```
$ FM_HOME=~/starship bin/fm-shift.sh status
shift: not armed
  power: ok - on mains power, system sleep held off (keep the lid open)
  keep-awake: ok - com.firstmate.glasses-keepawake is running
  mailbox: ok - the service is running and answering its health check
  voice out: ok - firstmate can speak into the glasses
  phone route: ok - Tailscale Serve maps :8443 to the mailbox
  supervision: DOWN - the session is live but nothing is watching for questions
      fix: resume the session supervision cycle in the firstmate session for this home before leaving
  away mode: ok - firstmate keeps answering while you are out
  outage self-check: DOWN - not registered
      fix: fm-shift.sh start registers it
  supervision alarm: DOWN - a supervision outage would not reach your ear
      fix: fm-shift.sh start routes it through the announce path
$ echo $?
0
```

The output was first recorded on 2026-09-08 and re-captured unchanged on 2026-09-09 against the code that ships on this branch.
This establishes that these probes read the real system correctly: mains power and the live sleep assertion, both LaunchAgent labels, the loopback health endpoint, the announce path end to end through its dry run, the `:8443` Serve mapping, this home's session lock and watcher state, the away-mode marker, the self-check registration, and the presence of the alarm-route block in `config/wedge-alarm`.
It does not exercise the host-sentinel precondition: with no shift armed the alarm-route check short-circuits on the missing block before the sentinel probe runs, so this transcript says nothing about whether the sentinel could fire.
That precondition is covered by `tests/fm-shift.test.sh` and `tests/fm-supervision-sentinel.test.sh` against fakes rather than by this transcript.
It also shows the documented exit rule: nothing was armed, so an unarmed component is reported honestly and the command still exits 0.
`start` and `stop` are not exercised here, because arming a real shift would start away mode and speak into the captain's glasses; `tests/fm-shift.test.sh` covers them against fakes.

## Related

- [`wedge-alarm.md`](wedge-alarm.md) owns the alarm channels this command routes through.
- [`configuration.md`](configuration.md#supervision-active-alert-channels-configwedge-alarm) owns the `config/wedge-alarm` schema.
- `tests/fm-shift.test.sh` fakes power state, launchd, Tailscale, the health endpoint, the announce path, and the away-mode owners, so no test reads real power state, mutates real launchd or Tailscale, touches the live mailbox, or speaks a real line.
