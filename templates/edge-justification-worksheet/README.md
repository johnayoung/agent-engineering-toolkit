# edge-justification-worksheet

Per-edge worksheet for a multi-agent coding topology, plus a checker that deletes any edge with an
empty or invalid cell. You start at zero edges; each one has to earn its own existence.

## Usage

```bash
cp edge-worksheet-template.md my-topology.md   # one "## Edge" block per edge you want to draw
./check-edges.sh my-topology.md                # exit 0 = every edge survived; 1 = at least one is deleted
./check-edges.sh example-thirty-agents.md      # worked example: the thirty-agent run, and one edge that survives
```

Exit 1 is the common case and not a malfunction — deleting an edge is the outcome the worksheet
exists to produce. Exit 0 with zero edges proposed is also a valid answer.

## The fourteen cells

Eight table rows from the post, expanded into the fields a checker can read:

| Cell | Enforced as |
| --- | --- |
| Single agent enough | Must start with `no` and say why. `yes` deletes the edge. |
| Coordination lives | Non-empty: the file, lock, queue, or assignment the coordination physically runs through. |
| Forcing constraint | Exactly one of `context pollution`, `parallelism`, `specialization` (`policy isolation` accepted). Anything risk-shaped is rejected by name. |
| Constraint evidence | Non-empty, plus a per-constraint warning: parallelism wants the no-shared-symbol/test/ordering evidence, specialization wants a named tool or credential, context pollution wants a number. |
| Risk tier | One of `low` / `medium` / `high` / `critical`, reused from your authority table. |
| Objective, Output format, Tools and sources, Task boundaries | Each non-empty. Output format warns when no branch name is assigned. |
| Review node | Non-empty. Warns when high- or critical-tier work names no human in the node. |
| Upstream of irreversible action | `yes` or `no`. `no` deletes the edge. |
| Token budget | Must contain a number. |
| Reviewer-minute budget | Must contain a number; the checker sums the surviving edges into a daily reviewer bill. |
| Equal-compute comparison | Non-empty; `not run` / `unknown` deletes the edge. |

## What the checker does not do

- It does not judge whether your answers are true. A cell full of confident nonsense passes; the
  worksheet forces the answer to exist and be legible, not to be correct.
- The warnings are keyword heuristics on free text. They flag likely gaps; a human decides.
- The reviewer-minute total is arithmetic on the budgets you wrote. It is an estimate of an estimate,
  not a measurement, and the script says so in its output. Measure your actual review capacity
  before you trust it.

## Grounding

Canonical post: [The Topology You Can Review Is the Topology You Can Run](https://jyoung.dev/blog/agent-architecture-review-capacity/)

Documented facts this artifact relies on:

- **The closed list of three forcing constraints** — context pollution, parallelism, specialization — is
  Anthropic's, from "Building multi-agent systems": outside those situations, coordination costs
  typically exceed the benefits. Risk is not on the list; in the post's rule, risk earns a review
  checkpoint, never another worker.
- **The single-agent default on coding work** — Kim et al., "Towards a Science of Scaling Agent Systems":
  on SWE-bench Verified every multi-agent architecture scored below the single-agent baseline (0.522),
  from −2.1% (hybrid) to −14.9% (independent). Those are 20-instance subsets, so the result is
  directional rather than decisive; the checker never scores an edge with them, it only quotes them
  as the default you are drawing against.
- **The four-field delegation spec** — objective, output format, tools and sources, task boundaries —
  is Anthropic's, from "How we built our multi-agent research system."
- **The thirty-agent branch collision** — 18 of 30 agents independently created a branch with the same
  name, and the conflicting PRs were abandoned — is Anthropic's Frontier Red Team report, "Patterns
  and problems in emerging multiagent systems." It is the worked example in
  `example-thirty-agents.md`; the second edge in that file is invented for illustration and labeled
  as such.
- **The 3-10x token multiplier** is Anthropic's own internal testing with no published methodology.
  The checker quotes it as a reason to budget, never as a computed figure — treat it as a floor, not
  a forecast.
- **The equal-compute null hypothesis** — Tran & Kiela, "Single-Agent LLMs Outperform Multi-Agent
  Systems": with reasoning tokens held constant, single-agent matched or beat multi-agent across two
  datasets, three model families, and five architectures. That preprint explicitly scopes out
  tool-using settings, so it is indirect evidence for coding work.
- **The merge-vs-review distinction** — git detects textual conflicts, not semantic ones — is from
  Augment Code's multi-agent workspace guide, cited for merge mechanics only.
- **The four risk tiers** (low / medium / high / critical, by reversibility and blast radius) come from
  this site's [permission-tiering post](https://jyoung.dev/blog/agent-permission-tiering/); the
  reviewer-minute denominator comes from
  [review capacity](https://jyoung.dev/blog/review-capacity-agent-throughput/). Treating reviewer
  bandwidth as the binding constraint on topology is the post author's framing, labeled as such in
  the post — no source argues it.
