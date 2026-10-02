# Second-opinion review

Date: 2026-10-02T18:02:03Z
Reviewer: grok
Subject: Decision: a nightly cron job retries a failed webhook delivery up to 5 times with a fixed 1-second delay, and marks the 

**CRITICAL — 200 is treated as payment.** Any HTTP 200 (proxy, wrong URL, replay, attacker-controlled endpoint) marks the order paid. Transition `unpaid → paid` only after a verified, order-bound confirmation, and only once.

**CRITICAL — Timeout vs work that continues.** A timed-out call can still succeed on the peer. The job counts that as failure and retries. A late 200 and the retry’s 200 can both mark paid if the write is not conditional. Record timeout as *unknown* and reconcile; do not blind-retry it as a failure.

**HIGH — Overlap and retry double-apply.** Nothing stops two cron runs (overrun, duplicate scheduler) or a retry after a crash between “got 200” and “mark paid.” Both POST, both see 200, both mark paid. Take a single-flight lease per event and send a stable idempotency key so the receiver and the paid-transition are safe under duplicates.

**HIGH — Budget and schedule.** Five tries at a fixed 1s is a burst, then up to 24h of silence. “Up to 5” is not defined across nights, so it can be five per night forever. Persist a global attempt count, backoff with jitter, retry within minutes, and treat 4xx as terminal.

**MEDIUM — Status taxonomy.** 204/409 (already applied) never marks paid; only 200 does.

Capping retries off the request path is sound. The cap must be global, and success must mean payment confirmed, not “someone returned 200.”

