# model-swap-gate

Decision checklist for coding-agent model swaps: an entry condition (error analysis first) plus five gates — noise floor, instrument validity, harness parity, workload-weighted eval, staged rollout — each with a pass/fail predicate and the published measurement behind it. Copy `checklist.md` into the ADR or PR proposing the swap.

## Usage

1. Copy `checklist.md` into the swap proposal (ADR, design doc, or PR description).
2. Walk the entry condition first. If nobody has done error analysis on your own failed runs, the proposal is premature regardless of the leaderboard.
3. Gates 1-3 test the cited leaderboard evidence; failing them disqualifies that evidence but not the swap. Gates 4-5 are the affirmative case — the only path to sign-off runs through them.
4. The numeric anchors in the predicates (6pp infra swing, 2.0-3.4pp run-to-run SD, n≈969) are measurements of specific benchmarks under specific conditions, not universal constants. Substitute your benchmark's own published variance where it exists; where none is published, that absence is itself a Gate 1 finding.

## Grounding

This checklist operationalizes the closing decision table ("The Swap Decision, Compressed") and the eval-gate section of [Stop Picking Your Coding-Agent Model Off a Leaderboard](https://jyoung.dev/blog/coding-agent-leaderboard-noise/). Documented facts it relies on:

- Infrastructure configuration alone produced a 6pp swing on Terminal-Bench 2.0 (p < 0.01) with model, harness, and task set fixed (Anthropic, Quantifying Infrastructure Noise).
- Detecting a 3-point delta at 80% power requires n≈969 independent questions; clustered standard errors can exceed 3x naive ones (Miller, Adding Error Bars to Evals, arXiv 2411.00640). SWE-bench Verified has 500 samples (OpenAI, Introducing SWE-bench Verified).
- Run-to-run SDs of 2.0 / 2.2 / 3.4pp across five runs of three SWE-bench-family agents (Guo et al., SWE-Doctor, arXiv 2607.00990).
- With rank confidence intervals displayed, top leaderboard models can be statistically interchangeable (Neuhof & Benjamini, arXiv 2606.08679).
- OpenAI no longer evaluates SWE-bench Verified: at least 59.4% of audited problems have flawed test cases; every frontier model tested reproduced the ground-truth fix (OpenAI retraction post).
- All 8 audited agent benchmarks exploitable to near-perfect scores, 219 distinct flaws (Berkeley RDI; Wang et al., BenchJack, arXiv 2605.12673). Memorization: 76% vs 53% buggy-file accuracy inside vs outside the benchmark (Liang et al., arXiv 2506.12286); 32.67% of successful patches had the solution in the issue thread (Aleithan et al., arXiv 2410.06992).
- Harness variance 18.48 pp² vs model variance 2.37 pp² (7.80x); cross-scaffold gaps of 34-48 points on HAL (Zhang et al., arXiv 2605.23950). Same model, 80.5% whole vs 69.2% diff edit format (Aider leaderboard).
- "20-50 simple tasks drawn from real failures is a great start"; task/trial/outcome vocabulary (Anthropic, Demystifying Evals for AI Agents).
- Error analysis decides whether the model is the problem at all (Husain & Shankar, LLM Evals FAQ).
- A Claude Code quality regression traced to a reasoning-effort default and a caching bug, not weights (Anthropic postmortem). Prompt-injection resistance dropped 94% to 71% after a GPT-4o to GPT-4.1 upgrade (Promptfoo, vendor-authored).

Full source list with quotes: the References section of the post above.
