# eval-cadence

Gives each eval in a standing suite its own cadence from three inputs: what one full run costs, whether the eval is saturated, and what a miss costs. Reads an `evals.yaml` manifest, computes a tier per eval, checks it against the tier you declared, and emits the GitHub Actions wiring and a one-page charter. It runs no evals and edits no files.

Thresholds are yours. The post gives no bright-line numbers and neither does this script: `--daily-budget` and `--changes-per-day` are required, and every default below is a setting you can override.

## Usage

```bash
./eval-cadence.sh --daily-budget 50 --changes-per-day 20 evals.yaml    # tier table + findings
./eval-cadence.sh check evals.yaml                                     # exit 1 on any FAIL (budget from cadence:)
./eval-cadence.sh charter evals.yaml                                   # one-page charter
./eval-cadence.sh ci --runner './bin/run-evals' evals.yaml > .github/workflows/agent-evals.yml
./eval-cadence.sh ids --tier nightly evals.yaml                        # ids in a tier, one per line
```

`example-evals.yaml` is the post's manifest verbatim. With `--daily-budget 50 --changes-per-day 20` it reproduces the post's four tiers and flags the tone judge for hardening.

| Mode | Exit 0 | Exit 1 | Exit 2 |
|---|---|---|---|
| report, charter, ci, ids | output written | | bad flag or manifest |
| check | no FAIL findings | any FAIL finding | bad flag or manifest |

## Manifest

The post's fields, plus an optional `cadence:` block so CI reads the same settings you do. Flags override it.

```yaml {title="evals.yaml"}
suite_version: 2026.09.3
cadence:
  daily_budget_usd: 50        # one day of eval budget
  changes_per_day: 20         # agent-system PRs per day that hit the path filter
  saturation_pass_rate: 1.00  # default 1.00
  flake_threshold: 0.01       # default 0.01
  deterministic_kinds: code_assertion   # comma list; default code_assertion
evals:
  - id: reg/handler-error-mapping-422   # required, no whitespace
    suite: regression                   # required: regression | capability
    kind: code_assertion
    cost_per_run_usd: 0.02              # required, per trial
    trials: 1                           # default 1
    stakes: high                        # required: low | medium | high
    pass_rate_30d: 1.00
    flake_rate_30d: 0.00                # optional
    saturated: false                    # optional override
    owner: payments-api
    incident: INC-0916                  # optional, counted in the charter
    tier: per_change                    # declared tier, compared to computed
```

YAML is read as a flat subset (top-level scalars, `cadence:` scalars, `evals:` list of scalar maps). Nested values, block scalars, and flow maps fail closed with a line number. A `.json` manifest of the same shape also works.

## Tiering rules

One full run = `cost_per_run_usd x trials`. Rules apply in order.

| Condition | Tier |
|---|---|
| Regression, saturated, not deterministic, stakes low or medium | `harden_then_retire` |
| Deterministic kind, not flaky, full run x changes/day <= daily budget | `per_change` |
| Full run <= daily budget | `nightly` |
| Otherwise | `pre_release` |

A saturated high-stakes regression eval keeps its cost tier and gets a HARDEN note. Saturated cheap deterministic checks are left alone: a regression check at 100% is doing its job.

| Finding | Level | Fires when |
|---|---|---|
| OWNER | FAIL | no `owner` |
| FLAKY | FAIL | `flake_rate_30d` >= threshold (also demotes a per-change check to nightly) |
| TIER | FAIL | declared tier differs from computed, including a judge or agent run declared `per_change` and a cheap deterministic check declared anywhere else |
| BUDGET | FAIL | computed or declared tiers project more than the daily budget |
| SUITE_VERSION | FAIL | no `suite_version` |
| NO_REGRESSION | FAIL | no regression evals |
| HARDEN | NOTE | regression eval saturated and not deterministic |
| GRADUATE | NOTE | capability eval saturated; says whether trials support graduating it |
| TRIALS | NOTE | non-deterministic eval with one trial |
| CODE | NOTE | low-stakes model-graded eval over a day of budget |
| UNDECLARED, NO_PASS_RATE, NO_CAPABILITY, IGNORED | NOTE | missing inputs |

Costs are the manifest's declared figures, not measured spend, and per-change spend assumes every agent-system change runs the whole per-change tier. Treat the projection as an estimate.

## CI

`ci` writes a workflow: path-filtered `pull_request` (the post's paths plus the manifest), a nightly cron (`--cron`, default `0 3 * * *`), `workflow_dispatch` for `pre_release`, and a twice-monthly cron for `harden_then_retire` if any exist. Tier membership is read from the manifest at run time, so moving an eval is a reviewed manifest edit. Each job calls your runner as `CMD <id>...` with `EVAL_TIER` and `SUITE_VERSION` exported; a `cadence-check` job runs `check` on every PR. Copy the script to `--script-path` (default `./scripts/eval-cadence.sh`).

## What it does not do

- Run evals or measure cost. Bring a runner and real per-run figures.
- Pin-check the model alias. The post's trigger table needs that check separately.
- Decide stakes. That is the behavior owner's call, recorded in the manifest.

## Grounding

Canonical post: [Diff Review Can't See Your Agent Regress. A Standing Suite Can.](https://jyoung.dev/blog/standing-agent-eval-suite/)

- Cost, saturation, and stakes as the three inputs, harden before retire, and the cadence ladder (cheap code assertion every change, mid-cost judge nightly, expensive high-stakes judge before release, saturated retire or every two weeks): [Hamel Husain, Shreya Shankar: Q: How often should I run my evals?](https://hamel.dev/blog/posts/evals-faq/how-often-should-i-run-my-evals.html)
- Deterministic checks on the per-change tier: "Favor assertions or other deterministic checks over LLM-as-judge evaluators" ([Husain, Shankar: CI/CD vs. monitoring production](https://hamel.dev/blog/posts/evals-faq/how-are-evaluations-used-differently-in-cicd-vs-monitoring-production.html)); fast reliable tests on presubmit ([Software Engineering at Google: Continuous Integration](https://abseil.io/resources/swe-book/html/ch23.html)).
- The 0.01 flake default: "As you approach 1% flakiness, the tests begin to lose value" ([Software Engineering at Google: Testing Overview](https://abseil.io/resources/swe-book/html/ch11.html)).
- Regression evals near 100%, capability evals start low and can graduate, and "An eval at 100% tracks regressions but provides no signal for improvement" ([Anthropic Engineering: Demystifying evals for AI agents](https://www.anthropic.com/engineering/demystifying-evals-for-ai-agents)).
- Pricing the full run before scheduling it: [Kapoor et al.: AI Agents That Matter](https://arxiv.org/abs/2407.01502).
- Path filter plus nightly cron, and reviewing suite edits like schema migrations: [Autonoma: Agent Regression Testing](https://getautonoma.com/blog/agent-regression-testing). Versioning the suite: [Tian Pan](https://tianpan.co/blog/2026/05/17/eval-suite-became-spec-nobody-agreed-to).
- The rule ordering, the budget arithmetic, and the twice-monthly approximation of "every two weeks" are this tool's choices, not sourced claims.
