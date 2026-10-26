## Comprehension
<!-- comprehension-gate. The owner writes this block in their own words before merge.
     Not the agent, and not a paste of the agent's PR summary. The owner is a named person
     on the on-call rotation that gets paged for this code, which may not be the person
     who prompted the agent. -->

Owner:
Owner's rotation:
Prompted by:
Blast radius:
<!-- One of: low | medium | high | critical. Use your permission tiers.
     "low" (a copy change, a test-only change) skips the five sections below.
     Write the reason after the tier, e.g. "low: email template copy only". -->

### Contract
<!-- What this code promises its callers, and what it assumes from its dependencies. -->

### Invariants
<!-- What must stay true regardless of implementation. One per line, each with
     "Enforced by:" naming the mechanism (a unique index, a constraint, a lock, a test),
     not the code path that hopes to keep it true. -->

### Failure modes
<!-- The specific ways this goes wrong in production, numbered. For each one:
     what happens, and what stops it. -->

### Debug path
<!-- What on-call opens first at 2am: the trace field, the log line, the flag.
     If there is a kill switch, say what it does NOT stop. -->

### Regenerable
<!-- Files or functions an agent can rewrite behind the four sections above, with the
     tests and invariants checking every replacement. Write "none" if the owner holds all
     of it. Anything not listed here is something the owner holds. -->
