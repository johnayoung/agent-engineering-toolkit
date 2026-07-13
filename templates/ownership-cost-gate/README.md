# ownership-cost-gate

Runnable version of the ownership-cost flowchart from [Build vs. Buy Agentic AI: Ownership Is the New Decision](https://jyoung.dev/blog/build-vs-buy-agentic-ai/). Give it your first-build estimate and it prices the maintenance tail, then walks the five gates in order — ownership cost, differentiation, continuous verification, compliance-as-product, base rate — stopping at the first BUY. Bash + awk, no other dependencies.

Run it once **per slice** of the tool. The strategic core and the platform it runs in are different candidates and usually get opposite verdicts.

## Usage

Interactive (prompts for anything not flagged):

```bash
./ownership-cost-gate.sh --candidate "triage rules" --estimate 3
```

Non-interactive (all gates as flags — the post's claims-triage worked example):

```bash
# The rules slice -> BUILD
./ownership-cost-gate.sh --candidate "triage rules" --estimate 3 \
  --staff-tail yes --differentiating yes --verifiable yes \
  --regression-day yes --compliance no --beats-base-rate yes

# The platform slice -> BUY at gate 2
./ownership-cost-gate.sh --candidate "triage platform" --estimate 12 \
  --staff-tail yes --differentiating no
```

`--unit` relabels the estimate (default `engineer-months`; use `dollars`, `weeks`, whatever your estimate is in — the math is a multiplier, so the unit passes through).

## What the numbers are

- **Maintenance tail = 1.5x the first build** — from the 60/60 rule: development is ~40% of lifecycle cost, maintenance ~60%. The tail breakdown (60% changing-requirements enhancements, 23% migration, 17% bug fixes) means 83% of it is new work, not warranty repair.
- These are **cross-system lifecycle averages, not measurements of your system** — the script marks them as directional in its output. The GitLab platform-cost figure quoted at gate 4 is vendor-authored and marked the same way.

## Grounding

Canonical post: https://jyoung.dev/blog/build-vs-buy-agentic-ai/

Documented facts this calculator relies on:

- 60/40 lifecycle split and the 60/23/17 maintenance breakdown — David Wood, "The 60/60 Rule" (O'Reilly, *97 Things Every Project Manager Should Know*).
- Refactoring fell from 25% to under 10% of changed lines while clones rose 8.3% to 12.3% — GitClear, AI Copilot Code Quality 2025.
- +25% AI adoption tracks with throughput −1.5% and delivery stability −7.2% — DORA 2024, magnitudes via Rachel Stephens (RedMonk).
- Strategic/utility split and its drift over time — Martin Fowler, "Utility Vs Strategic Dichotomy".
- Regulated standard applications: Buy primary, Make only peripheral modules — David Klotz, "The Buy-or-Build Decision, Revisited" (arXiv).
- ~$1.4M year-one, 2–3 FTEs, 12–18 months for an internal regulated platform — Bryan Ross (GitLab); vendor-authored, treated as directional.
- Bought tools/partnerships succeed ~67% of the time, internal builds one-third as often — MIT NANDA, via Fortune.
- Experienced developers 19% slower with AI on repos they know deeply — METR, early-2025 study.

The combined gate itself (build only when differentiating AND cheaply, continuously verifiable) is the post author's synthesis from those premises, flagged as such in the post.
