# Standing-agent checklist

Fill this in before an agent runs without you: one row per job the person in the session used to do. `always-on-preflight.sh` fills what a static read of a GitHub Actions workflow can see; the rest is yours. **If any row is still blank, the agent is not ready to run without you.**

Agent: ____________  Owner (person or rotation): ____________  Re-certify by: ____________

| Job | What the session gave you | Control outside the agent | This agent |
|---|---|---|---|
| **The human in the chat** | Someone watching every step | List the five jobs below before scheduling | |
| **Deduplication** | One request at a time | Inbox keyed on the source's event ID, one worker, skip-or-double per action | |
| **Memory** | Context held in a person's head | Append-only run log; notes as a rebuildable cache | |
| **Identity** | Their own credentials | Own identity, short-lived credentials via a proxy | |
| **Approval** | A live yes | Deferred call resumed by an inbox event with an expiry | |
| **Watching and stopping** | Eyes on the screen, a hand on the machine | Page on outcomes; off switch outside its reach | |

## Deduplication

- [ ] Every trigger is written to the inbox, then acknowledged, before any agent code runs.
- [ ] The dedup key comes from the source, never the receive time:

  | Trigger source | Key |
  |---|---|
  | Kubernetes CronJob | `batch.kubernetes.io/cronjob-scheduled-timestamp` (v1.32+); `concurrencyPolicy` defaults to `Allow` |
  | Claude scheduled deployment | `trigger_context.scheduled_at` |
  | GitHub event | repo, issue or PR number, event action, object's `updated_at` (the post's construction) |
  | Stripe webhook | event ID |
  | Amazon SQS | a key the producer writes into the message body |

- [ ] The row is marked in progress before the worker starts.
- [ ] The dedup record outlives the sender's retry window (Powertools defaults to one hour; Stripe retries for up to three days).
- [ ] One worker per inbox. On GitHub Actions: a `concurrency:` group keyed on the issue or PR number.
- [ ] Any cron in a local time zone runs outside 1 AM to 3 AM local, or in UTC.
- [ ] Each action has a skip-or-double policy:

  | When the action... | Policy |
  |---|---|
  | Sends something a human reads once | Skip on doubt; fail closed |
  | Merges, deploys or closes | Skip, and route through approval |
  | Creates a new object | Skip if the key already exists |
  | Reads, labels or rebuilds a digest | Allow the double |

## Memory

- [ ] The harness writes an append-only run log the agent can only read.
- [ ] Any notes file is regenerated from that log on a gate and stamped with its source run IDs.
- [ ] Memory holds only what the agent can't look up again.

## Identity

- [ ] The agent has its own identity: no personal token, no `TRIAGE_PAT`-style secret.
- [ ] Model access is short-lived (OIDC federation on GitHub Actions: `id-token: write`, no `anthropic_api_key`).
- [ ] Third-party credentials are injected by a proxy the agent never sees.
- [ ] Revocation is known: deleting a repo secret does not revoke the credential it held.
- [ ] Scheduled GitHub runs are credited to whoever last changed the cron; that person is known and staying.

## Approval

- [ ] The fired prompt is never treated as approval.
- [ ] A step that needs a yes defers: save the session, post the ask, end the run.
- [ ] The answer arrives as a new inbox event and resumes the saved session on the same ID.
- [ ] Every ask has an expiry; on expiry, close it and take no action.
- [ ] A pending ask blocks only its own call; triage keeps running.

## Watching and stopping

- [ ] The page fires on the missing outcome (for example, no issue labeled in 26h), not on a red run. A red run opens a ticket.
- [ ] The alert lives in a system whose credentials the agent never holds, not in the agent's repo.
- [ ] You know what your pause stops. A paused scheduled deployment lets running sessions continue and still allows manual runs; archive is terminal.
- [ ] The off switch has been tested from a phone.
- [ ] One named owner or rotation receives the page, and ownership is re-certified when people move.

The 26-hour and 48-hour thresholds in the post are illustrative, not sourced. Pick your own from your cycle time.
