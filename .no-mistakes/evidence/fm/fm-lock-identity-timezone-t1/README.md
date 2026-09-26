# Live validation: watcher lock identity timezone fix (0dd67090 vs base 2dd858a2)
Host: macOS (no /proc, so the ps lstart identity path is the one in use), /etc/localtime = Europe/Athens.
Lab: a disposable lab home (bin/fm-lab-home.sh), real `git clone`s of the base and target commits acting as primary checkouts, real bin/fm-watch-arm.sh watchers, and the real bin/fm-continuity-pretool-check.sh fed Claude PreToolUse JSON. The lab was removed and its launchd sentinel disarmed afterwards.
- s1-cross-tz-healthy-watcher.txt: new code; watcher armed under Amsterdam, lock records UTC, hook allows under London/New York/Amsterdam.
- s2-base-reproduces-incident.txt: base code; the same setup denies as "SUPERVISION OUTAGE" when the hook runs 1h off (the Aquablu incident).
- s3-upgrade-legacy-identity.txt: the base-started watcher keeps running while its checkout updates in place to the new commit; the legacy local-time lock is accepted in the writer's zone. In another zone it denies with the new live-watcher/--restart wording.
- s3b-recovered-watcher-all-zones.txt: after --restart, the lock is UTC and the hook allows from 5 zones.
- s4-identity-mismatch-deny-wording.txt: adversarial tampered identity; default/unsafe-teardown/unsafe-sentinel deny shapes name the check and point to --restart; wake-drain still allowed.
- s5-genuine-outage-after-restart-cycle-ended.txt: a genuine outage (no watcher pid) keeps the SUPERVISION OUTAGE wording plus "Failed watcher check: watcher-pid-alive".
- s6a/s6b: a real `claude -p` primary (Claude Code 2.1.283) in the upgraded clone under TZ=America/New_York; allowed when healthy, and it surfaces the new deny text on a mismatch.
- t-*.log: targeted test files tests/fm-continuity-pretool-check.test.sh and tests/fm-supervision-host.test.sh.
