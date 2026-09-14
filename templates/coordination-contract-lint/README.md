# coordination-contract-lint

Validates a JSON handoff contract, the shared record a planner, implementer, and
reviewer all read and write, against the schema from "Coordination Is an
Architecture Layer, Not a Prompt Instruction." Exits non-zero on a malformed or
incomplete contract, the same way a schema lint fails a build on any other
interface.

The post's argument is that coordination logic buried in each agent's prompt
cannot be reconfigured, tested, or swapped. A contract file can be, and this
script is that test, runnable in CI on every commit that touches a contract.

## Usage

```bash
./coordination-contract-lint.sh path/to/contract.json
```

Exit codes:

- `0`: schema valid (warnings allowed)
- `1`: schema violation. A required field is missing or null, `state` is not
  one of the five valid values, or a `done`-state contract fails its own
  promotion guard.
- `2`: usage error (bad args, missing file). Unparseable JSON gets folded into
  a FAIL at exit 1, not exit 2, since a malformed contract is exactly what this
  script exists to catch.

`example-contract.json` in this directory is the post's own worked example
(`webhook-retry`), reproduced verbatim, and passes clean.

## What it checks

**Required (FAIL if missing, null, or wrong type):**

- `objective`: non-empty string
- `ownership`: object with `agent` (non-empty string) and `files` (non-empty
  array). An owned-files list with nothing in it has no reviewable boundary.
- `state`: one of `reading`, `editing`, `verifying`, `waiting`, `done`
- `observations`, `mutations`: arrays
- `verification`: array of `{command, result}` objects; every entry must
  carry both, non-empty
- `approval_gates`: object (`{}` is valid: nothing gated)

**Promotion guards (FAIL), lifted from the post's own guard block:**

```text
verifying -> done   requires  verification[] non-empty
waiting   -> done   requires  approval_gates.<gate>.status == approved
```

If `state` is `done`, this script enforces both: `verification` must be
non-empty, and every gate in `approval_gates` must carry `status: "approved"`.

**What it does not check.** The post's guard also lists "every recorded
command exited 0" and "files_changed subset of ownership.files." The schema
has no exit-code field and no `files_changed` array, only a `result` string
and prose `mutations`, so this script cannot verify either mechanically
without inventing fields the schema doesn't define. Instead it WARNs when a
`verification[].result` string contains "fail", "error", or "fixme" as a
heuristic prompt to check by hand. If your contract adds a real exit-code
field, extend the script, don't trust the heuristic.

**Warnings (non-fatal):**

- `ownership.lease_expires` absent, or present but not a parseable timestamp
- `mutations` empty while `state` is past `reading`
- `verification[].result` containing fail/error/fixme text
- `task`, `timestamp`, `open_risks`, `next_action` absent, recommended fields
  from the fuller contract quoted in the post but not in this script's
  required set

## Wire it into CI

```yaml
- name: lint coordination contracts
  run: |
    for f in contracts/*.json; do
      ./coordination-contract-lint.sh "$f" || exit 1
    done
```

## Grounding

Canonical post: [Coordination Is an Architecture Layer, Not a Prompt Instruction](https://jyoung.dev/blog/multi-agent-coordination-layer/)

Documented facts this artifact relies on:

- The contract schema (objective, ownership, state, timestamp, observations,
  mutations, verification, approval_gates, open_risks, next_action) and the
  five-state machine (`reading`, `editing`, `verifying`, `waiting`, `done`)
  are adapted from Kate Johnson's field-tested handoff contract, quoted
  verbatim in the post: [A Small Handoff Contract for Multiple Coding Agents](https://dev.to/kgjohnson/a-small-handoff-contract-for-multiple-coding-agents-4538).
- The `example-contract.json` fixture and the promotion-guard block
  (`verifying -> done requires verification[] non-empty`, `waiting -> done
  requires approval_gates.external_action.status == approved`) are the post's
  own worked `webhook-retry` example.
- The thesis that this needs to be independently testable, not prompt text,
  is the post's synthesis of Yuan et al. (protocol-absent coordination gets
  reintroduced through prompts) and Cemri et al. (verification defects are a
  measured MAST failure category, not a model-capability problem):
  [Yuan et al.: Beyond Message Passing](https://arxiv.org/abs/2604.02369),
  [Cemri et al.: Why Do Multi-Agent LLM Systems Fail?](https://arxiv.org/abs/2503.13657).
