# size-review-capacity

The reviewer-hours arithmetic and six-gate scorecard from [Review Capacity Is the Real Ceiling on Your Agents](https://jyoung.dev/blog/review-capacity-agent-throughput/). Compute whether the next agent clears your review capacity before you approve it.

## Calculator

```bash
./size-review-capacity.sh --reviewers 6 --prs-per-day 30 --add 1 --floor 30
```

Required (both from your telemetry): `--reviewers`, `--prs-per-day`. Optional: `--hours` (focused review-hours per reviewer per day, default 3), `--add` (agents under consideration, default 1; 0 = measure today only), `--prs-per-agent` (default 5), `--floor` (your attention floor in minutes/PR — no default; the post's position is that you name this number yourself).

Output: attention-per-PR today and after the added agents, and — if a floor is named — max absorbable PRs/day, headroom, and a clears/exceeds verdict. Coreutils + awk only.

## Scorecard

`review-capacity-gates.md` is the post's closing table as a copy-paste checklist: six yes/no gates, each with the signal it is being violated. The calculator answers gate 2; the other five are process questions.

## Grounding

Canonical post: https://jyoung.dev/blog/review-capacity-agent-throughput/

Documented facts this artifact relies on:

- The six-reviewer / 30 PRs-per-day scenario and review-burden externalization: Baltes, Cheong, Treude, "An Endless Stream of AI Slop" (arXiv 2603.27249v2).
- Review as the binding constraint on delivery: Monperrus, "The End of Code Review" (arXiv 2606.13175v1); Crosley, "Agents Supersede the Reviewer, Not the Review".
- Review-agent noise behind gate 3: Chowdhury et al. (arXiv 2604.03196v1) — CRA-only PRs merge at 45.20% vs 68.37% human-only.
- Telemetry behind gate 1: Faros AI Engineering Report 2026 (vendor research, commercial interest) — median time in review up 441.5%, unreviewed merges up 31.3%.

Honesty notes: the defaults (3 focused review-hours/day, 5 PRs per agent per day) are the post's worked-example assumptions, not measured constants — override them with your telemetry, and the script labels them as defaults in its output. Attention-per-PR is an even-split heuristic; risk-tiered triage changes each PR's real draw.
