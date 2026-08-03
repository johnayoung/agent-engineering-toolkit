---
name: decompose-epic
description: Convert one epic into a task graph before any agent starts — nodes that each carry an exclusively owned write glob, a named interface contract, explicit dependency edges, and a mechanical acceptance predicate. Use when an epic-shaped request lands on an agent ("add tenant-scoped rate limiting", "add photo sharing to my app"), when parallel agents or worktrees are proposed against one repository, when someone asks how to split work between agents, or after two agents overwrote each other's changes. Walks the post's seven gates in order, then validates the result with a bundled script that checks the globs against the real repo for overlap, contracts for two owners or none, edges for cycles, and acceptance criteria for prose. Produces the graph and the check report; it does not start the work. If the epic is one node in one layer, it says so and recommends running it monolithic.
---

# Decompose epic

The dominant measured failure of coding agents is not misreading a vague request. It is violating a constraint the developer already stated — 38.33% of misalignment episodes across 20,574 real sessions, with 73.68% of those attributed to instruction-following failure. Sharpening the prompt aims at the wrong thing. The move is to stop encoding constraints as sentences and encode them as structure: a file the agent may not write, a contract it may not change, a check that fails loudly. Full argument: https://jyoung.dev/blog/task-decomposition-for-ai-coding-agents/

This skill produces a graph and a check report. It does not start the work, spawn agents, or write files into the user's repo unless they ask after reading the report. Draft the graph in the response and validate it from a temp path; place it in the repo only on request.

## Step 0 — Price it before you draw it (stop: run it monolithic)

Ask what the epic cost when run as one task: how many attempts, how many reruns. A workflow that lands on the first try does not need a graph. Structure buys cheap retries with an expensive first attempt — in the IBM measurements, runtime-structured decomposition cost 2,716 ± 424 tokens on its baseline run against 904 ± 17 monolithic, earning it back only in retries (436 ± 132 against 904 ± 17), at a natural failure rate of 0–2% measured under simulated failure. A decomposition that is merely fixed upfront with no runtime branching is worse than not splitting at all: 1,632 ± 145 in retries, because failure forces reruns of everything downstream.

Do not argue from cost-of-delay folklore. Across 171 projects, Menzies et al. found no evidence for the delayed issue effect. Argue from the agent failure base rates instead.

If the epic is one layer and one node, say so and stop: run it monolithic.

## Step 1 — Cut at layer boundaries

Read the repo before proposing nodes. Cut where the layers already are — migration, service, middleware, UI, docs — so each node sits inside one layer. Do not ask the model to pick the seams for you: standard LLM decomposition reaches only 34.2% category recall at the step level, and granularity is the part models are worst at. Sizing is a separate craft; if a node's expected diff blows past the reviewable ceiling, split it (see `size-agent-task` in this toolkit).

Refuse to cut where the pieces need constant back-and-forth. Planning, implementation, and testing of the same feature share too much context, and components requiring constant back-and-forth belong in the same agent.

## Step 2 — The spatial edge: one write glob per node, disjoint

Every node names a file glob it exclusively writes. Nothing else. Two agents that both look reasonable can still overlap on a shared package, and unassigned files are where agents overwrite changes they believe will merge cleanly — in CooperBench, two agents on interdependent features scored on average 30% lower than the same agents working alone, and 77.3% of tasks had conflicting ground-truth solutions.

Check the globs against the repo rather than assuming. The post's manual form:

```bash
comm -12 \
  <(git ls-files 'internal/middleware/*' 'internal/ratelimit/*' | sort) \
  <(git ls-files 'web/admin/src/settings/*' 'internal/admin/*' | sort)
```

The bundled script does this for every node pair, plus a pattern-level check for files that do not exist yet. Resolve any hit by assigning the path, not by hoping.

## Step 3 — The semantic edge: contracts with exactly one owner

A textually clean merge is not a correct merge. Merge conflicts are a spatial problem — who edits which lines — but task success needs semantic coordination: what to implement. A middleware node renaming a field on `RateLimitPolicy` while a UI node renders a form against the old shape produces zero conflicts and one broken screen.

So each node also names the contracts it **owns** (may change) and the contracts it **reads** (may not change). Answer the four questions ambiguity actually attaches to: may this node alter the public API, add a dependency, change the schema, change existing error behavior? A contract with two owners is a failure. A contract read but owned by nobody is frozen for the run — say so explicitly.

Do not plan for the agents to settle any of this at runtime. Given a messaging tool, no model achieved higher cooperation success; the with-comm and no-comm difference was not statistically significant. A channel is where assumptions get announced, not where they get prescribed.

## Step 4 — Edges and acceptance predicates

Dependency edges are explicit and acyclic. Report the depth of the longest chain, not the node count — depth sets the rerun blast radius when a middle node fails.

Every node's "done" is a predicate a machine evaluates, in one of four shapes: a command that exits 0, a named test that passes, a file that exists, a glob that matches at least N files. Prose the agent grades itself against does not count. The predicate is also the handoff gate: a failed node's output should never become visible downstream, which is the mechanism that cut retry cost to 436 ± 132.

## Step 5 — Name the owner

Every source that describes this artifact describes it as hand-authored, and none names the hand. Put a name on the graph the way you put one against the on-call rotation — the engineer accountable for the feature's design review, assigned before the first agent opens a file. A graph with no name in it fails the check.

## Step 6 — Validate, report, stop

Write the graph JSON (schema below; `scripts/check-task-graph.sh --skeleton` prints a blank one), run the checker against the real repo, and present:

1. The graph as the post's table — `scripts/check-task-graph.sh <graph.json> --table` renders Node / Writes / Contract / Done when.
2. The checker's output verbatim, including any FAIL or WARN.
3. The two gates the checker cannot answer: whether the observed failure rate justifies the cost, and whether these are the right seams.

Then stop. Do not begin implementing nodes, and do not write the graph into the repo, unless asked.

## Gate map

| Post gate | Enforced by |
|---|---|
| Constraints expressed as something other than a sentence | the schema itself: `writes`, `owns`, `accept` |
| Split lives in structure with a validated handoff per edge | `accept` on every node with dependents (checker reports edge gates) |
| Every node has a glob it exclusively writes | checker: materialized + pattern disjointness |
| Every node names owned and read-only contracts | checker: one owner per contract, unowned reads flagged |
| Nothing negotiated at runtime | checker: overlaps and unowned contracts are the negotiation surface |
| Failure rate justifies the cost | you — the checker prints the price and says it cannot measure this |
| A name on the graph | checker: `owner` required |

## Graph schema

```json
{
  "epic": "Add tenant-scoped rate limiting to the public API",
  "owner": "the engineer accountable for the design review",
  "failure_rate_evidence": "ran monolithic twice; both needed a full rerun",
  "nodes": [
    {
      "id": "n2",
      "layer": "middleware",
      "writes": ["internal/middleware/ratelimit.go", "internal/ratelimit/policy.go"],
      "owns": ["RateLimitPolicy"],
      "reads": ["tenant_rate_limits table shape"],
      "depends": ["n1"],
      "accept": {"kind": "command", "run": "go test ./internal/middleware/..."}
    }
  ]
}
```

Predicate kinds: `command` (`run` exits 0), `test` (`name` + `run`), `file_exists` (`path`), `glob_count` (`glob` + `min`). `example-graph.json` is the post's worked rate-limiting epic, filled in.

## Standalone script

`scripts/check-task-graph.sh` validates a graph without Claude:

```bash
scripts/check-task-graph.sh graph.json --repo /path/to/repo   # validate
scripts/check-task-graph.sh graph.json --table                # the post's table
scripts/check-task-graph.sh graph.json --runner               # sh script that runs the predicates
scripts/check-task-graph.sh --skeleton                        # blank graph
```

Exit codes: 0 = graph passes (including the monolithic verdict), 1 = structural failures, 2 = usage error. Two honest limits, both printed in its output: it never executes your predicates (`--runner` emits a script so that stays your decision), and its overlap check is exact only for tracked files — for paths that do not exist yet it compares glob patterns, which flags nesting prefixes like `internal/*/handler.go` and `internal/*/policy.go` as a possible overlap even though they can never match the same path.

## Grounding

Canonical post: https://jyoung.dev/blog/task-decomposition-for-ai-coding-agents/

Documented facts this skill relies on: Developer Constraint Violation as the most prevalent misalignment symptom at 38.33% of episodes across 20,574 sessions in 1,639 repositories, 73.68% of those attributed to instruction-following failure, against 15.36% for underspecified instructions (Tang et al., arXiv 2605.29442 — a multi-label taxonomy, so the shares do not sum to 100); constraint violations as the top real-world threat category at 40.4% of 547 confirmed failures (Hasan and Biswas, arXiv 2605.30777); retry cost of 904 ± 17 monolithic, 1,632 ± 145 static, 436 ± 132 runtime-structured, against a runtime-structured baseline of 2,716 ± 424, at natural failure rates of 0–2% under simulated failure, with decomposition policies developer-authored (Asthana et al., arXiv 2605.15425); 30% average and 25% absolute cooperation success, 77.3% conflicting ground truths, the spatial-versus-semantic split, and the non-significant communication ablation (Khatua et al., arXiv 2601.13295); 34.2% step-level category recall for standard LLM decomposition (Gao, arXiv 2606.18051); no evidence for the delayed issue effect across 171 projects (Menzies et al., arXiv 1609.04886); "components requiring constant back-and-forth belong in the same agent" (Anthropic, Building multi-agent systems).

The prescription that assigning globs and contracts *fixes* the collision is the post's stated judgment, not a measured result — CooperBench diagnoses collision under no assigned ownership but never tested an assigned-ownership arm. The checker verifies that your graph has the properties the post argues for; it cannot verify that the graph works.
