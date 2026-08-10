<!--
  Model-swap decision gate.
  Paste into the swap proposal (ADR, design doc, or PR description) before
  approving a change to your default coding-agent model. Full argument:
  https://jyoung.dev/blog/coding-agent-leaderboard-noise/
-->

# Model swap gate — decision checklist

A leaderboard gap nominates a shortlist; it cannot approve a swap. Each gate below has a pass predicate and the published measurement that justifies it. Gates 1-3 test the cited evidence; Gates 4-5 are the affirmative case. A proposal that fails Gates 1-3 may still proceed — but only by dropping the leaderboard claim and earning approval through Gates 4-5.

    Proposal:       __________ -> __________   (incumbent -> candidate)
    Evidence line:  __________                 (benchmark, gap in points, source URL)

## Entry condition — is the model even the bottleneck?

- [ ] Someone has read the last month of failed agent runs, and the failures implicate raw model capability rather than task design, context, or harness. ("Does error analysis suggest that your model is the problem?" — Husain & Shankar. The prior runs against you: controlled decomposition puts harness variance at ~7.8x model variance.)
- [ ] The leaderboard line has been rewritten as "candidate for the shortlist," and the proposal still contains independent evidence after the rewrite.

If either box is unchecked, this is not a swap proposal yet — it is an error-analysis task.

## Gate 1 — Noise floor

**Pass predicate:** the cited gap is larger than every published variance source of the benchmark that produced it.

- [ ] Gap exceeds the benchmark's measured infrastructure swing. (Anthropic measured a 6pp swing on Terminal-Bench 2.0, p < 0.01, from compute configuration alone — model, harness, and task set held fixed.)
- [ ] Gap exceeds one run-to-run standard deviation. (Five-run stability study of three SWE-bench-family agents: SDs of 2.0, 2.2, and 3.4pp.)
- [ ] The benchmark has enough samples to resolve the gap. (Detecting a 3-point delta at 80% power requires n≈969 independent questions; SWE-bench Verified has 500. Clustered standard errors can run over 3x naive ones — Miller.)
- [ ] If the leaderboard publishes rank confidence intervals, the two rows' intervals do not overlap. If it publishes none, the ordering is unquantified. (Neuhof & Benjamini: with rank CIs displayed, top models can be statistically interchangeable.)

      Cited gap: ______ pp    Largest published variance source for this benchmark: ______ pp

Fail here means the cited evidence shows a statistical tie, not an advantage.

## Gate 2 — Instrument

**Pass predicate:** the benchmark has not been retracted by its own publisher, and no published audit shows it exploitable or contaminated.

- [ ] The benchmark's publisher still evaluates on it. (OpenAI no longer evaluates SWE-bench Verified: at least 59.4% of audited problems have flawed test cases, and every frontier model tested could reproduce the ground-truth human fix.)
- [ ] No published exploit reaches near-perfect scores without solving tasks. (Berkeley RDI: all 8 audited agent benchmarks are exploitable, including a ten-line conftest.py that resolves every SWE-bench Verified instance; 219 distinct flaws catalogued.)
- [ ] No published contamination or leakage finding. (Models hit 76% buggy-file-path accuracy from issue text alone inside SWE-bench versus 53% outside it; 32.67% of successful patches had the solution present in the issue thread.)

Fail here means the cited score is a reading from a retracted or gameable gauge — treat it as an unaudited vendor claim, not a measurement.

## Gate 3 — Harness parity

**Pass predicate:** both leaderboard rows disclose their harness, the harnesses match, and that harness is the agent runtime you operate.

Fill this block for both rows. Every line you cannot fill is a variable that moved the score for reasons unrelated to the model (harness variance 18.48 pp² vs model variance 2.37 pp², a 7.80x ratio — Zhang et al.):

    model:                ____   # exact version string, not family name
    scaffold / agent:     ____   # SWE-agent, mini-SWE-agent, vendor-internal, ...
    edit format:          ____   # whole | diff | udiff | tool-call
    tool set:             ____   # shell only, or file viewer + search + linter
    retry / trial policy: ____   # pass@1, pass@5, best-of-n
    max turns:            ____
    compute per task:     ____   # CPU/memory ceiling of the eval container

- [ ] Both rows disclose the block above. (If not, the comparison is unreadable — stop citing it; do not merely discount it.)
- [ ] Both rows ran the same scaffold. (Cross-scaffold gaps reach 34-48 points on the HAL leaderboard; edit format alone moves the same model 80.5% to 69.2% on Aider's board.)
- [ ] That scaffold is the agent runtime you deploy. (If it is not, the delta transfers to your stack with unknown sign.)

## Gate 4 — Workload-weighted eval

**Pass predicate:** the candidate beats the incumbent on your own tasks, through your own harness, against a bar written down before the run.

- [ ] 20-50 tasks pulled from your own agents' real failures over the last quarter — not from the benchmark's task list. (Anthropic: "20-50 simple tasks drawn from real failures is a great start.")
- [ ] Tasks weighted by workload frequency. A model that wins on the tasks you rarely run is not a win.
- [ ] Harness held fixed: same scaffold, tools, edit format, retry policy, and resource ceiling. Only the model varies.
- [ ] Multiple trials per task — 3 to 5. (A single trial reproduces the 2.0-3.4pp run-to-run noise the leaderboard has.)
- [ ] Pass threshold and per-task regression limits written down before looking at results. A bar set after the results is not a bar.
- [ ] Safety and format-compliance checks included alongside resolution rate. (A GPT-4o to GPT-4.1 upgrade dropped one agent's prompt-injection resistance from 94% to 71% on the operator's own harness — Promptfoo, vendor-authored.)

      Suite size: ____ tasks    Trials per task: ____    Bar, written before the run: __________

## Gate 5 — Staged rollout

**Pass predicate:** the swap ships like any other production change — bounded blast radius, revert path, regression watch.

- [ ] Scope bounded: one team, one repo, one week before the default flips.
- [ ] Revert path: the old model is one config flag away.
- [ ] Regression watch covers runtime configuration, not just model weights. (Anthropic traced a Claude Code quality regression to a reasoning-effort default and a caching bug — configuration, not weights — and now runs per-model evals on every system prompt change.)

## Sign-off

Signing off means the proposal's evidence line no longer references the leaderboard. It reads: *on N workload-weighted tasks drawn from our own failed runs, T trials each, harness held fixed, the candidate resolved X% against the incumbent's Y%, with no per-task regressions above the bar.*

    Approver: __________    Date: __________    Revert flag: __________
