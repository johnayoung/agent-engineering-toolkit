# comprehension-gate

Two checkpoints for agent-written code, so the first person to understand a change is not whoever gets paged for it. Before merge, the owner writes an explain-back in the PR. After merge, a drill run without the agent tests whether the owner still holds it.

Both checkpoints are the post author's extensions of SRE and clinical-handoff practice. Neither has been tested in software code review. Treat them as a policy to try, not a validated intervention.

## Files

| File | Use |
| --- | --- |
| `pull_request_template.md` | The comprehension block. Copy to `.github/pull_request_template.md`, or append it to yours. |
| `check-comprehension.sh` | Merge gate: fails a PR body whose block is missing, unowned, or unfilled. |
| `drill-card.md` | Wheel of Misfortune card for one agent-written path, with the game-master steps. |
| `drill-backlog.sh` | Turns a scored card into `comprehension-debt` tickets, one per unfound item. |
| `example-webhook-pr.md`, `example-webhook-drill.md` | The post's PR #4812 block and drill card. A composite scenario, not a real PR or incident. |

## Before merge: the explain-back

```bash
./check-comprehension.sh pr-body.md
gh pr view 812 --json body -q .body | ./check-comprehension.sh -
./check-comprehension.sh example-webhook-pr.md       # composite example, passes
```

Exit 0 pass (warnings allowed), 1 the gate fails, 2 usage error. HTML comments are stripped first, so an untouched template fails.

| Check | FAIL when |
| --- | --- |
| Block | No `## Comprehension` heading outside a code fence. |
| Blast radius | Not one of `low`, `medium`, `high`, `critical`. `low` passes with the rest unchecked. |
| Owner | Empty, `TBD`, or an agent or bot name. The author-of-record is not an owner. |
| Owner's rotation | Empty. The owner must be on the rotation that gets paged for this code. |
| Contract, Invariants, Failure modes, Debug path, Regenerable | Missing, empty, or still holding the template prompt. `Regenerable: none` is accepted. |
| Invariants | No `Enforced by` anywhere. If the owner cannot name the mechanism, that is the finding. |

WARN, not FAIL: no `Prompted by`; fewer `Enforced by` than listed invariants; failure modes not listed as items; a debug path with no concrete identifier; a flag or kill switch with no statement of what it leaves running.

Scaling by blast radius: the post gives the two ends (money gets the full block, an email template copy change gets none). `medium` here gets the full block; relax that if your tiers say otherwise.

As a required check on PRs labelled `agent-written`:

```yaml {title=".github/workflows/comprehension-gate.yml"}
name: comprehension-gate
on:
  pull_request:
    types: [opened, edited, synchronize, reopened, labeled, unlabeled]
jobs:
  gate:
    if: contains(github.event.pull_request.labels.*.name, 'agent-written')
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v4
      - env:
          PR_BODY: ${{ github.event.pull_request.body }}
        run: printf '%s\n' "$PR_BODY" | ./.github/scripts/check-comprehension.sh -
```

`edited` matters: the owner fills the block after the PR opens. Put the script under CODEOWNERS so the PR cannot edit its own gate.

## After merge: the drill

1. Copy `drill-card.md` per agent-written path. Build the scenario and the "Must find" list from the merged comprehension block. Make one item the one built to fail, like a kill switch that only half-works.
2. Run it about three weeks after merge, then once a quarter. Primary is the owner, secondary is the next on-call on the same rotation. No agent and no chat assistant.
3. The game master marks each item `[found]` or `[missed]`. Anything still at `[ ]` is scored as unanswered.
4. Turn the gaps into tickets:

```bash
./drill-backlog.sh card.md         # markdown tickets
./drill-backlog.sh --gh card.md    # `gh issue create` commands, printed, not run
```

Exit 0 when every item was found, 1 when tickets were emitted, 2 when the card is unusable (no owner, no target, `Next drill` not a date, an unknown mark, no items). It also warns when the owner is not listed as a player or the rules do not say "no agent".

## Owner signals the scripts cannot see

Check these by hand, from the post's ownership table:

| When you see | Do this |
| --- | --- |
| The prompter sits on a different rotation than the code's on-call | Name an owner from the paged rotation before review starts |
| An author-of-record but no owner | Block merge until the owner is named |
| One engineer owns every agent PR in a component | Add a second owner for anything that touches its core invariant |
| Nobody can say who else knows the path | Have the owner walk a second rotation member through the four must-hold items |
| The owner is rotating off | Reassign ownership and redo the explain-back before they go |

## Limits

- The checker confirms the block exists and is filled. It cannot tell whether the owner wrote it, whether an agent drafted it, or whether it is true. A confident wrong block passes. The drill is the check on that.
- Owner, agent-name, and kill-switch detection are keyword heuristics on free text.
- `drill-backlog.sh` assigns tickets to the card's `Owner` value. `--gh` needs that to be a GitHub login.
- The studies behind the policy mostly used novices or students. Read them as a direction, not an effect size for your team.

## Grounding

Canonical post: [Comprehension Debt Is an On-Call Problem for Agent Code](https://jyoung.dev/blog/comprehension-debt-on-call-ownership/)

Documented facts this artifact relies on:

- **Approval and green tests are not comprehension.** Balepur et al. found initial task accuracy barely improves a comprehension model (adjusted R2 0.40 to 0.42); Qiao et al. found Copilot users passed more tests with no comprehension gain (p=0.59). Both are small student samples.
- **The four must-hold sections** are the post author's synthesis of Naur's theory of programs, Bacchelli and Bird's survey (91% of 873 programmers said reviewing unfamiliar files means learning their purpose, invariants, and APIs), Google SRE's playbook guidance, and Storey's intent debt. No source names these four as the set.
- **The debug path lives in the PR** because Google's SRE workbook warns that playbook details go out of date as fast as production changes.
- **The owner must be able to defend the change.** The Linux kernel's tool-generated content guidelines require submitters to understand and defend everything they submit. Storey suggests at least one human fully understand each AI-generated change; requiring that human to be on the paged rotation is the post's addition.
- **The explain-back** borrows I-PASS's "Synthesis by Receiver" step. The 23% and 30% error reductions in Starmer et al. belong to the whole I-PASS bundle, not that step, and no study tests explain-back in code review.
- **The drill format** is Google SRE's Wheel of Misfortune (a game master, a prepared realistic scenario, primary and secondary on-call) and AWS Well-Architected REL12-BP05 game days (involve the teams who handle production). The quarterly cadence follows Google's guidance that each engineer be on call at least once or twice a quarter. Running it on agent-written paths, without the agent, is the post author's extension.
- **PR #4812, Dana, and the webhook scenario** are an illustrative composite from the post. The example files are labelled as such.
