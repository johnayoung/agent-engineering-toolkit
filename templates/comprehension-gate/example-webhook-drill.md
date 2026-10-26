# Drill card

<!-- Composite scenario from the post, not a real drill. The target, players, scenario, and
     "Must find" items are the post's Wheel of Misfortune card; the dates and the [found] /
     [missed] marks are invented to show how a scored card turns into backlog tickets. -->

Target:       PR #4812, internal/payments/webhook (agent-written path)
Owner:        Dana
Last drill:   2026-11-16
Next drill:   2027-02-15
Players:      primary = Dana (owner); secondary = next payments on-call
Game master:  payments tech lead
Rules:        no agent, no chat assistant; PR #4812 comprehension block allowed

## Scenario

Provider latency spikes. The same webhook arrives twice, 1.8s apart, while the first
attempt is still writing.

Page: "charge_amount_mismatch: 14 accounts"

## Must find

1. [found] webhook.event_id on the trace for one affected account
2. [found] whether charges_applied holds one row or two for it
3. [missed] the flag that stops internal retries, and what it does not stop

## Notes

Item 3: named payments.webhook_retries_enabled and told incident command the bleeding had
stopped. The provider's re-sends were still arriving.
