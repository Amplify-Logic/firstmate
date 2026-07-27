# Watcher continuity

The watcher remains intentionally one-shot: one actionable reason closes one watcher cycle.
Must-work continuity now lives above that process boundary instead of depending on the model remembering a re-arm step.

## Ownership

Pi's `.pi/extensions/fm-primary-pi-watch.ts` and OpenCode's `.opencode/plugins/fm-primary-watch-arm.js` own continuous re-arm after an actionable child close.
Each adapter starts the next arm before delivering the wake prompt, checks current session-lock ownership at launch, preserves one child or scheduled retry at a time, and applies bounded exponential retry after an unexpected or failed close.
A failed follow-up never cancels continuity restoration.

## Actionable wake ordering

After an actionable Pi or OpenCode child close, the adapter starts and verifies one singleton successor before it delivers the original wake.
It waits at most one readiness timeout per attempt, then sends TERM and waits a bounded retirement confirmation before the next lock-verified exponential retry.
If the unready arm does not retire within that bound, the adapter keeps ownership, starts no overlapping retry, and delivers the typed fallback immediately.
When that retained arm later closes, its actual close is classified as a new supervised event without replaying the earlier fallback.
After the configured retry bound is exhausted, it delivers the original wake with a typed continuity-restoration failure even if every successor arm hung without reporting readiness.
This is deliberate Option B ordering: the fleet is protected before the model handles the wake whenever restoration succeeds, but the model is never left blind when it does not.

Claude retains its native tracked background-task completion path.
Its PreToolUse continuity gate allows wake drain, arm recovery, independently fail-closed teardown, and the literal `bin/fm-supervision-sentinel.sh enable` that the session-start disarm banner names, but refuses other fleet commands while tasks are in flight and no identity-matched live watcher with a fresh beacon holds the home lock.
Every other host-sentinel invocation — `arm`, `disarm`, `check`, a bare call, extra arguments, or any dynamically built argument — stays denied in that state, so the one command the banner instructs the owner to run is reachable without widening the gate.
The denial leads with `SUPERVISION DOWN`, the beacon age, the grace window, and the in-flight task count before the recovery instruction.
Allowing an ordinary literal teardown prevents a terminal wake from creating a recovery circle: forced or dynamically constructed teardown remains blocked, ordinary teardown itself still refuses dirty, unlanded, incomplete-scout, and unresolved-decision cases, and the turn-end guard continues to require supervision for any tasks left in flight.
Codex retains its bounded foreground checkpoint protocol.
Grok retains its tracked background-task notification protocol.
No adapter starts a replacement with shell `&`.

The turn-end guard and its adapters remain the final in-harness backstop rather than the normal continuity mechanism.
On an unhealthy result, both that guard and the Claude continuity gate call `bin/fm-supervision-sentinel.sh note-outage`, which records the shared durable outage marker with local writes alone.
Neither hook forks a notifier, backgrounds notifier work, or waits on external-channel delivery: they must return their blocking result immediately, and the scheduled host check owns delivery.

## Host-level outage sentinel

This mitigation does not identify or prevent the harness-level process reap.
It assumes the watcher or away daemon can still disappear at any time and bounds detection outside that process tree.

`bin/fm-watch-arm.sh` and `bin/fm-afk-start.sh` idempotently register `bin/fm-supervision-sentinel.sh` as a per-home macOS launchd agent before entering their long-lived foreground work.
launchd invokes its one-shot `scheduled-check` mode every 60 seconds outside the harness process tree.
Only that entry point updates `state/.supervision-sentinel-last-check`; the marker-only `note-outage` and `check` modes cannot certify that launchd is alive, and neither of them ever fires an external channel.
When launchd retains the service but no scheduled check ever lands, the arm path records `state/.supervision-sentinel.arm-failure` and skips further launchd mutation for an exponentially growing per-home cooldown instead of paying a bootout, a bootstrap, and a bounded liveness wait on every watcher and away-mode entry.
That cooldown has its own bounds (`FM_SENTINEL_ARM_RETRY_SECS`, 60 seconds, doubling to `FM_SENTINEL_ARM_RETRY_MAX_SECS`, one hour), separate from the repeat-alert schedule.
It still fails the arm and still warns that the host alarm is unavailable, and because it suppresses retries it leaves the home unmonitored — so every later session start prints a `HOST SUPERVISION SENTINEL - REGISTRATION FAILED` banner naming the remaining suppression window and the `bin/fm-supervision-sentinel.sh enable` recovery command, exactly as a deliberate disarm is surfaced.
An explicit `enable` bypasses the cooldown for one real attempt; only a verified registration clears the record, so a failed `enable` preserves the evidence and its escalating count rather than resetting to a first failure.
The arm path and the session-start banner both read that record through one shared helper (`fm_supervision_arm_failure_status` in `bin/fm-supervision-lib.sh`), which treats a deadline beyond its own recorded window as stale evidence suppressing nothing, so a clock rollback or a restored state volume neither blocks retries forever nor advertises a suppression window that is not enforced.
The in-harness turn-end and continuity guards keep blocking a blind turn end throughout, so a suppressed host registration degrades the backstop rather than removing it.
The check reuses `fm_supervision_status` plus `fm_watcher_healthy`, so it requires the existing home-scoped watcher lock, PID identity, watcher path, and fresh beacon rather than trusting a leftover file or live PID alone.
Lock home and watcher path are compared by physical target, so a checkout reached through a symlinked path component cannot make a live watcher look foreign to a host check that resolved its own root differently; two genuinely different homes still never match.
Future-dated beacon timestamps are rejected rather than remaining fresh indefinitely after wall-clock rollback or restore.
With the default 300-second grace, a stale-beacon outage becomes an active alert within at most roughly 360 seconds instead of remaining silent for hours.
A missing or dead identity-matched lock is detected on the next host check even while the beacon is still fresh.

The sentinel writes `state/.supervision-outage-alarm`, posts through the channels owned by [`wedge-alarm.md`](wedge-alarm.md), and deduplicates one continuous outage.
The first repeat waits five minutes by default, then repeats back off exponentially to a one-hour cap instead of firing at one unchanging cadence forever.
That backoff belongs to one episode, keyed on the watcher lock pid and beacon evidence.
When the key changes — the watcher was re-armed and reaped again between two host checks — the outage is genuinely new, so the repeat schedule resets and the alert fires on the next check instead of inheriting a delay of up to an hour.
Only an unchanged, continuous outage keeps backing off.
The marker distinguishes pending delivery from a successful alert, so a failed channel retries on the next host check after a short claim lease without consuming the repeat schedule.
That short lease applies to a new episode too, which keeps a delivery still in flight from being duplicated while deferring the new alert by at most the lease.
The launchd label is derived from `FM_HOME`, so sibling firstmate homes never share a service identity.
Its plist runs only `fm-supervision-sentinel.sh scheduled-check`.
It contains no watcher arm, daemon launch, signal, process sweep, or restart command.

`bin/fm-supervision-sentinel.sh disarm` is the only supported uninstall path.
It boots out only the exact home-scoped launchd service and writes `state/.supervision-sentinel.disarmed`; ordinary harness closure, session end, task cleanup, and watcher shutdown never invoke it.
While that record exists, automatic watcher and away-mode entry does not silently re-enable the service, and every session-start digest prints a loud disabled-state notice.
The session owner must deliberately run `bin/fm-supervision-sentinel.sh enable` to restore and verify the service before the durable record is removed.

No automatic recovery is attempted.
A launchd process cannot recreate the harness completion notification that wakes firstmate after an ordinary watcher reason, and it cannot safely infer the away-mode daemon's supervisor target.
Starting either owner from launchd could race the existing singleton or create a second supervision cycle while `state/.afk` assigns ownership to the daemon.
The sentinel therefore makes the outage bounded and loud while leaving recovery to the existing home-scoped, identity-checked paths.
Linux and other hosts retain the hook alarms but do not yet have a verified host scheduler; watcher entry reports that limitation in a genuine primary home, and stays silent in a child task worktree or non-primary home exactly as macOS does.
On such a host the marker-only guard modes are the only writers of `state/.supervision-outage-alarm`, so they refresh unclaimed evidence whenever the outage episode or in-flight count moves rather than freezing on the first outage ever observed; a claim or committed delivery owned by a scheduled host check is never overwritten.
The launchd transport itself is covered by an opt-in real-`launchctl` smoke rather than the default suite; see [`wedge-alarm.md`](wedge-alarm.md) for how to run it and what remains transport-unverified until it is.

## Arm-layer cycle contract

`bin/fm-watch-arm.sh` never returns a clean empty success.
An actionable child output returns that reason normally.
A zero/empty child return rechecks the home lock and beacon, attaches to a verified healthy successor when one exists, or emits `watcher: FAILED - cycle ended without an actionable reason` and exits nonzero.
An attached arm follows verified identity-matched successors and reports the same typed failure if that chain ends without one.

The arm layer appends one tab-separated record per observed cycle to `state/.watch-cycle-exits.log`.
Each record includes arm and watcher PIDs, start and end timestamps, exit code and signal, classified reason, beacon age, lock identity before and after close, and successor disposition.
The file is size-capped through `FM_WATCH_CYCLE_LOG_MAX_BYTES` and `FM_WATCH_CYCLE_LOG_KEEP_LINES`.
`state/.watch-triage.log` remains only the watcher's bounded absorbed-wake debug log and carries no lifecycle semantics.

The default 300-second grace is unchanged.
Only the watcher process touches `state/.last-watcher-beat`; the sentinel reads it but never touches it, so no helper process can make a wedged watcher appear healthy.

## Regression coverage

`tests/fm-pi-watch-extension.test.sh` simulates actionable and empty child closes against the actual Pi and OpenCode close handlers, blocks prompt delivery to prove the successor launches first, verifies single-flight behavior, changes the session lock before close to prove ownership is rechecked, and hangs each successor arm to prove bounded fallback delivery includes the typed restoration failure.
`tests/fm-watcher-lock.test.sh` covers verified-successor attach, the typed self-eviction failure, bounded and successor-linked lifecycle rows, and a SIGSTOP counterfactual that distinguishes a live PID from a stale beacon before classifying termination.
`tests/fm-continuity-pretool-check.test.sh` proves the Claude gate rejects only non-recovery fleet execution in the precise unhealthy state, treats a stale beacon as unhealthy even with a live identity-matched lock, admits only the literal host-sentinel `enable` while denying its other subcommands, and preserves the existing Stop registration.
`tests/fm-supervision-sentinel.test.sh` proves six-task stale-beacon detection with a live identity-matched lock, active-alert content, failed-delivery retry, exponential repeat backoff for one continuous outage, an immediate reset when the episode evidence changes, recovery re-arming, marker-only guard notes that never reach a notifier, `check` staying marker-only while still reporting a verdict and exiting non-zero on a detected outage, every mode honoring a durable disarm, unclaimed evidence refreshing on a moved episode without disturbing a live claim, symlinked-versus-foreign home identity, host-only liveness proof, one-per-home launchd registration, manifest reconciliation, per-home backoff instead of churn when a retained service never completes a check, a registration-retry schedule independent of the repeat-alert tunables, a failed `enable` preserving the escalating failure record, a retry deadline beyond its own recorded window reading as stale evidence that suppresses nothing, a generated manifest never carrying a notifier override, explicit durable disarm/re-enable, a one-minute cadence, an unambiguous OS title, and the absence of every automatic recovery command.
`tests/fm-session-start.test.sh` proves both the deliberate disarm and the suppressed-registration cooldown reach every session-start digest with their timing and recovery command.
`tests/fm-turnend-guard.test.sh` additionally runs the Stop hook with the sentinel enabled and every channel pointed at a recorder, proving the block still renders fast, the marker lands unclaimed, and no channel fires.

## Sanitized live evidence, 2026-07-17

All five harnesses ran against git-initialized scratch projects and isolated `FM_HOME` state.
Existing harness-managed credentials remained in place, no credential bytes were copied into a fixture or transcript, and no account was created.
Pi used the existing shared Pi auth store with the explicit `openai-codex/gpt-5.6-sol` provider/model pin and low thinking.
Each run used the smallest prompt needed to exercise the harness-native path.

Harness versions:

```text
Claude Code 2.1.214
codex-cli 0.144.4
OpenCode 1.17.18
Pi 0.80.10
grok 0.2.103 (89c3d36fb6f1) [stable]
```

Claude ran an arm fixture through its native tracked background option, observed background completion, allowed the wake drain, and refused the next unrelated fleet command before its body executed.
The captured system message exactly named `[watcher-continuity]`, `bin/fm-wake-drain.sh`, tracked Claude re-arm through `bin/fm-watch-arm.sh`, and the blocked `fm-crew-state.sh` command.
Command: `FM_CLAUDE_LIVE_E2E=1 tests/fm-claude-continuity-live-e2e.test.sh`.
Observed result: `ok - Claude 2.1.214 (Claude Code) live E2E refused only the post-completion fleet command with exact re-arm guidance`.

Codex ran the real one-second foreground watcher checkpoint and returned `checkpoint: no actionable wake within 1s` without switching to the arm wrapper.
Command: `FM_CODEX_LIVE_E2E=1 tests/fm-codex-continuity-live-e2e.test.sh`.
Observed result: `ok - codex-cli 0.144.4 live E2E preserved the one-second foreground checkpoint path`.

OpenCode ran its persistent TUI plugin, established the first watcher from `session.idle`, received an actionable close, and ledger-linked a live successor before the model handled the wake.
The model executed no watcher-arm command and the turn-end backstop did not fire.
Command: `FM_OPENCODE_LIVE_E2E=1 tests/fm-opencode-primary-live-e2e.test.sh`.
Observed result: `ok - OpenCode 1.17.18 live E2E auto-started one successor before prompt handling without a model re-arm`.

Pi loaded the tracked extensions in its interactive TUI, called `fm_watch_arm_pi` once, received an actionable close, and ledger-linked a successor before the handling turn ended.
The turn-end backstop did not fire, and `/quit` removed both the watcher and arm child.
Command: `FM_PI_LIVE_E2E=1 tests/fm-pi-primary-live-e2e.test.sh`.
Observed result: `ok - Pi 0.80.10 live E2E used shared Codex auth, auto-started one successor before turn end, and cleaned up`.

Grok ran the real arm wrapper through `run_terminal_command` with its tracked background option, surfaced its native task-completion notification after the actionable close, and recorded `reason=actionable-signal` in the cycle ledger.
No shell ampersand was used.
Command: `FM_GROK_LIVE_E2E=1 tests/fm-grok-continuity-live-e2e.test.sh`.
Observed result: `ok - grok 0.2.103 (89c3d36fb6f1) [stable] live E2E preserved tracked background completion and shared ledger classification`.

The goal is continuity with fewer supervision tokens and no Pi/OpenCode model-memory re-arm step.
No zero-latency guarantee is claimed; lock verification, watcher startup, and bounded retry delays remain deliberate safety work.
