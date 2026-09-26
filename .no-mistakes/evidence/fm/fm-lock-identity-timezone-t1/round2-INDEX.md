# Test round 2 evidence (target 9b63bef1)

A real fm-watch.sh watcher ran in a disposable fm-lab home. It was armed from a standalone
primary-shaped checkout (git init, not a linked worktree, so the continuity gate's primary-scope
check engages). The real bin/fm-continuity-pretool-check.sh was driven from shells in different TZ values.

- s0-baseline-bug-reproduced-base-commit.txt: base ffaef9fd code. Watcher armed in host local time
  (Europe/Athens). The gate checked from TZ=Europe/Berlin (1h off, like the hub incident) DENIES with outage wording.
- s2-upgrade-legacy-local-identity-still-allowed.txt: checkout upgraded in place with git to 9b63bef while
  the pre-fix watcher keeps running. The gate ALLOWS the legacy local-time identity.
- s3-live-watcher-identity-mismatch-deny-wording.txt: the same live watcher checked from TZ=Europe/Berlin.
  The deny names pid-identity-mismatch, drops the OUTAGE lead and holder sentence, and points to --restart
  (default, unsafe-teardown, and unsafe-sentinel shapes). wake-drain stays allowed.
- s4-restart-utc-identity-allowed-from-every-zone.txt: after bin/fm-watch-arm.sh --restart under
  TZ=America/New_York, the lock records a UTC identity. The gate allows from 7 zones.
- s5-adversarial-forged-identity-still-denied.txt: forged identities (1s off, another zone's rendering,
  another command) are all denied. Restoring the genuine identity allows again.
- s6-genuine-outage-keeps-outage-wording.txt: a stale beat, a stopped watcher, and a dead-pid lock keep
  the SUPERVISION OUTAGE wording and name the watcher-beat-fresh / watcher-pid-alive check.
- claude-live-e2e.log: FM_CLAUDE_LIVE_E2E=1 run. The credentialed Claude turn passed (Claude refused
  with the exact new guidance). Its later non-Claude lock-held assertion fails identically on base ffaef9fd (pre-existing).
