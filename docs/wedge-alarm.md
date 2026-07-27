# Supervision active alert channels

The away-mode sub-supervisor (`bin/fm-supervise-daemon.sh`) buffers escalations and injects them into firstmate's own pane.
When injection cannot confirm a submit past `FM_MAX_DEFER_SECS` (the pane is genuinely busy or wedged, or its Enter is swallowed), `inject_wedge_alarm` raises a loud, rate-limited alarm so the stall never stays invisible.

## Why an active channel beyond the status-line flash

Before this change the only ACTIVE signal `inject_wedge_alarm` sent was a tmux `display-message` status-line flash, guarded by `if [ "$backend" = tmux ]`.
That flash is a client-side OSD with no cross-backend equivalent, so on every non-tmux supervisor backend it was skipped entirely.
On 2026-07-10 a `claude`-on-`herdr` primary wedged past max-defer overnight: the tmux flash was skipped, and only the passive `state/.subsuper-inject-wedged` marker was written.
Nothing surfaces that marker until the next fleet action, so 20 escalations sat buffered for roughly 8.5 hours with no active alert.
The classifier-side half of that incident shipped separately (PR #429); this is the alarm-channel half.

`inject_wedge_alarm` now also calls `wedge_alarm_notify`, a configurable active alert that does not depend on any pane or its backend status-line.
The durable marker and the tmux flash are unchanged; the active alert is added alongside them.

The same channel owner now carries host-level watcher-outage alarms from `bin/fm-supervision-sentinel.sh`.
That sentinel is registered with macOS launchd by both watcher entry points, runs outside the harness process tree once a minute, and alerts when tasks are in flight without an identity-matched watcher lock and a fresh `state/.last-watcher-beat`.
Every report says `SUPERVISION DOWN` and carries the beacon age, the grace window, and the in-flight task count.
The outage marker is `state/.supervision-outage-alarm`.
The turn-end guard and Claude continuity gate write that marker through `note-outage`, a marker-only mode, and never fire a channel: an in-harness hook must return its blocking result immediately, so only the scheduled host check crosses this boundary.
A continuous outage repeats after five minutes by default, then backs off exponentially to a one-hour cap so a persistent failure remains visible without training the captain to ignore a fixed-cadence alarm.
The backoff is scoped to one episode: when the watcher lock or beacon evidence changes because the watcher recovered and was reaped again, the schedule resets and the new outage alerts at once rather than inheriting an hour-long delay.
A failed channel leaves delivery pending and retries on the next host check after a short claim lease; only a successful channel advances the backoff.

## Channels

`config/wedge-alarm` (local, gitignored) lists channel directives, one per non-empty, non-comment line; every listed non-`off` channel fires, best-effort.
`FM_WEDGE_ALARM_CHANNEL` overrides the file with a single directive (used by the tests).

- `off` - position-independent kill switch that disables every active alert; the marker and tmux flash remain.
- `auto` / `default` - platform default. macOS resolves to `osascript`; other platforms have no built-in OS channel, so `auto` there fires nothing and logs that the durable marker is the only signal (configure a `command:` directive instead).
- `osascript` - a macOS Notification Center banner via `osascript`.
  OS-level delivery reaches the captain even when every pane and its status-line is unreadable.
  The title identifies either `firstmate: away-mode escalations WEDGED` or `firstmate: SUPERVISION DOWN`.
- `herdr` - a herdr UI notification via `herdr notification show`. herdr's own surface, separate from the pane and its status-line.
- `command:<cmd>` - run `<cmd>` via `sh -c`, with the alarm summary passed as `$1` and on stdin. Lets the alert reach a phone or pager (ntfy, Slack, SMS) even when the captain is away from the machine entirely.

An absent `config/wedge-alarm` behaves as `auto`, i.e. default-on on macOS.
Default-on is deliberate: an away-mode injection wedge or a dead watcher must not stay silent, so the reachable OS channel fires unless the captain explicitly disables it.
The injection alarm is rate-limited to at most once per max-defer window.
The host sentinel emits once per outage episode, then repeats on an exponential five-minute-to-one-hour backoff while that same outage persists.

Each channel is best-effort: a missing binary or a non-zero exit logs a warning and the alarm falls through to the next channel, never crashing the daemon loop.
Every invocation is also process-group bounded by `FM_WEDGE_ALARM_TIMEOUT_SECS` (10 seconds by default), including `command:`, `osascript`, `herdr`, and an `FM_WEDGE_ALARM_EXEC` override.
On timeout or daemon shutdown, its watchdog terminates the notifier group, logs the timeout when applicable, and continues to the next configured channel.
The AppleScript passes the summary as an `argv` item rather than interpolating it into the script source, so summary text can never break the notification.
See `docs/examples/wedge-alarm` for a copyable starting config.

## Host fallback and recovery boundary

The launchd sentinel is intentionally an alarm, not a second supervision cycle.
It never calls `bin/fm-watch-arm.sh`, starts `bin/fm-supervise-daemon.sh`, or signals a recorded process.
A generic launchd job cannot recreate the harness-native completion notification that makes an ordinary watcher wake firstmate, and it cannot safely reconstruct the away-mode daemon's supervisor-pane target.
Starting either process from the fallback could race the existing singleton lock or violate the daemon's ownership of the watcher while `state/.afk` exists.
The fallback therefore detects and reports an outage within the 300-second grace plus the 60-second launchd interval, while the existing home-scoped recovery path remains authoritative.
There is no broad process kill anywhere in this path.

launchd registration is idempotent and home-scoped through a SHA-256 label derived from canonical `FM_HOME` and state paths.
The arm path compares the loaded manifest digest and reloads only that exact service when its script path, interval, or environment changes.
It also requires a recent `state/.supervision-sentinel-last-check`, kickstarting the exact service and refusing registration if no scheduled one-shot check completes.
In-harness guard checks use the marker-only `note-outage` entry point, never write that launchd-health proof, and never wait on an external notifier.
The job receives a fixed minimal system PATH rather than persisting the harness process PATH.
The job runs only `bin/fm-supervision-sentinel.sh scheduled-check`; its plist contains no restart command.
Registration lives in the current logged-in macOS GUI domain, which is the lifetime that also owns the interactive harness sessions; the next watcher arm re-registers after a new login.

Explicit `bin/fm-supervision-sentinel.sh disarm` removes only this home's exact service and leaves `state/.supervision-sentinel.disarmed` for every later session-start digest to surface.
No ordinary harness closure, session end, task cleanup, or watcher stop calls disarm, and automatic arm attempts respect the durable record.
Only deliberate `bin/fm-supervision-sentinel.sh enable` restores the service and clears that record after launchd health is verified.
It does not claim outage coverage across logout, reboot, system sleep, a missing state volume, or launchd failure.
Other operating systems keep the existing turn-end and continuity alarms but currently have no verified host scheduler, and watcher entry prints that limitation instead of claiming an external fallback.

## Test safety: no test posts a real notification

Every notifier channel (`osascript`, `herdr`, and `command:`) routes through a single seam, `FM_WEDGE_ALARM_EXEC`: when it is set, the daemon hands the fixed channel category and summary to that command instead of the real notifier (`wedge_alarm_emit` in `bin/fm-supervise-daemon.sh`).
This keeps tests from posting a real desktop notification:

- Whenever the daemon is sourced, its library-mode guard defaults `FM_WEDGE_ALARM_EXEC` to `discard`.
- `tests/wake-helpers.sh` upgrades that default to an on-disk recorder that logs `<channel>\t<summary>` to `$FM_WEDGE_ALARM_LOG`.
- The host-sentinel suite executes one-shot alert mode through the same recorder.
- Its title-argv test unsets the seam only after shadowing `osascript` with a file-writing fake.
- Production leaves `FM_WEDGE_ALARM_EXEC` unset, so the real channels fire.

The automated tests verify channel selection, summary propagation, and the title/body argv shape without posting a notification.
The real `osascript`/`herdr` delivery mechanism was verified once by the bounded manual run below.

## Verification (macOS, darwin)

Recorded 2026-07-10T12:41-0700 on macOS 26.5.2 (build 25F84), `osascript` at `/usr/bin/osascript`, `herdr` 0.7.3.
This is the single bounded manual verification (two invocations, one per OS channel), labelled "FIRSTMATE TEST - IGNORE" so the banners are unmistakably harmless.
These are the only verification commands that fire real notifications, and they are never run inside a test suite.

### osascript channel (manual verification of the argv-safe mechanism)

```
$ /usr/bin/osascript -e 'on run argv' \
    -e 'display notification (item 1 of argv) with title "FIRSTMATE TEST - IGNORE" sound name "Basso"' \
    -e 'end run' "FIRSTMATE TEST - IGNORE (wedge-alarm channel verification)"
$ echo $?
0
```

Exit 0; a Notification Center banner titled "FIRSTMATE TEST - IGNORE" was posted with the label as its body.
Production now passes both body and title as argv items to the same AppleScript mechanism.
The away-mode title is `firstmate: away-mode escalations WEDGED`, while the host sentinel uses `firstmate: SUPERVISION DOWN`.
`tests/fm-supervision-sentinel.test.sh` verifies the two-item argv shape against a fake `osascript` and never posts a real banner.

### herdr channel

```
$ herdr notification show "FIRSTMATE TEST - IGNORE" \
    --body "FIRSTMATE TEST - IGNORE (wedge-alarm channel verification)" --sound request
{"id":"cli:notification:show","result":{"reason":"shown","shown":true,"type":"notification_show"}}
$ echo $?
0
```

Exit 0; herdr reported `"shown":true`.
The daemon redirects this stdout to `/dev/null` and treats a zero exit as success.

### command channel dispatch (summary on $1 and stdin)

The `command:` channel runs `sh -c "<cmd>" fm-wedge-alarm "<summary>"` with the summary also piped on stdin.
`test_wedge_alarm_command_channel_receives_summary` deliberately unsets the seam for a safe file-writing command to verify this dispatch contract without a notification.
