<!-- Composite scenario from the post, not a real PR or a real incident. The four sections are
     the post's PR #4812 comprehension block verbatim; Owner's rotation, Prompted by, Blast radius,
     and Regenerable are filled from the post's tables. -->

payments: rewrite webhook retry and idempotency handling

## Comprehension (owner writes this, in their own words)
Owner: Dana
Owner's rotation: payments on-call (primary next week)
Prompted by: an engineer on the growth team, via an agent session
Blast radius: critical: applies charges

### Contract
The provider re-sends any delivery we don't acknowledge with a 2xx, and it
reuses event.id. ProcessChargeEvent treats event.id as the idempotency key
and returns 200 for an event.id already applied, without re-applying it.

### Invariant
At most one charges_applied row per event.id. Enforced by the unique index
on charges_applied(event_id), not by the retry loop.

### Failure modes
1. Timeout after write, before ack: provider re-sends; the unique index
   rejects the second insert; we return 200.
2. Duplicate delivery in flight: two workers race; the loser hits the
   unique index and logs webhook_duplicate_event.
3. Partial write: charge row lands, processed-event marker does not; the
   retry attempts a re-apply and the unique index stops it.

### Debug path
Trace field: webhook.event_id. Log: webhook_retry_attempt (count > 3 is
abnormal). Kill switch: payments.webhook_retries_enabled=false stops our
internal retries. It does not stop the provider's re-sends.

### Regenerable
- The retry loop body in retry.go
- The payload parsing in parse.go
- The backoff helper
