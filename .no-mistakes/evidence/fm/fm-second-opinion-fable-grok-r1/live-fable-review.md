# Second-opinion review

Date: 2026-10-02T17:59:54Z
Reviewer: fable
Subject: Decision: a nightly cron job retries a failed webhook delivery up to 5 times with a fixed 1-second delay, and marks the 

Reviewing the proposal directly, no tools needed.

**CRITICAL: Webhook 200 does not mean payment succeeded.** A 200 means the receiver accepted the message. Marking an order paid on delivery success conflates transport with settlement. Verify payment state against the payment provider, or have the receiver return an explicit paid status.

**CRITICAL: No idempotency key.** Five retries plus a nightly rerun can deliver the same webhook many times. If the receiver creates charges or ledger entries per request, you get duplicate payments. Add a per-order delivery ID and require the receiver to dedupe.

**HIGH: Timeout ambiguity.** If a call times out after the receiver has processed it, the retry resends. Treat timeouts as unknown, not failed, and reconcile before retrying.

**HIGH: Overlapping runs.** A slow night can overlap with the next cron run, or a manual trigger. Two workers retry the same order and both mark it paid. Lock per order or use a compare-and-set on state.

**MEDIUM: Fixed 1-second delay.** Five attempts over five seconds will not survive an outage lasting a minute. Use exponential backoff across runs, not seconds.

**MEDIUM: Nightly latency.** Orders stay unpaid up to 24 hours after a transient failure.

**LOW: No dead-letter path** after the fifth failure.

Sound: bounding retries at five is reasonable.

