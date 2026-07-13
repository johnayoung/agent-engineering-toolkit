---
name: verify-agent-pr
description: Fresh-grader verification of an agent-authored PR or diff before approval. Use when an AI coding agent reports a task complete, when a PR description claims "tests pass" or "feature works," or when deciding how deeply to review an agent diff. Runs the six-move per-task checklist — demand evidence for self-reports, read tests as claims against the spec, verify forward from acceptance criteria to hunt unbuilt features, flag unsolicited scope, calibrate depth to blast radius. Produces a verification report; edits nothing unless asked.
---

# Verify Agent PR

"Complete" is where the review starts, not where it ends. Structured verification has found 30-40% of a spec unimplemented after the agent reported complete, and "descriptions claim unimplemented changes" is the most common message-code inconsistency in agent PRs (45.4% of cases). Full framework: https://jyoung.dev/blog/evaluating-ai-coding-agent-output/

This skill produces a verification report. It does not edit, fix, or approve anything unless the user explicitly asks after reading the report.

## Step 0 — Be the fresh grader, or find one

The worker cannot be its own examiner. If this session (or this agent) produced the diff under review, do not grade it here — spawn a verification subagent or tell the user to open a fresh session that sees only the diff, the spec, and this skill. A fresh grader evaluates the result on its own terms instead of rationalizing the author's reasoning.

## Step 1 — Mechanical triage

Run the bundled script (works standalone, no Claude required):

```bash
git diff main...HEAD | scripts/triage-agent-diff.sh    # or: scripts/triage-agent-diff.sh --git main
```

It inventories the diff, reports whether any test files are in it, flags blast-radius signals by path/keyword heuristic (labeled as such — a match is a prompt to look, not a verdict), and emits the six-move checklist skeleton.

## Step 2 — Get the spec's acceptance criteria

Ask the user for the task spec if it isn't already in context. If no explicit criteria list exists, that is the first defect: record it in the report and stop the forward-verification pass — you cannot verify forward from a spec that doesn't exist. Do not reconstruct criteria from the diff; that grades the agent against its own interpretation.

## Step 3 — Strip the self-report

List every claim the PR description or agent message makes ("tests pass," "feature works," "refactored X"). For each, demand the evidence:

- "tests pass" → the command run and its actual output, not the assertion
- "feature works" → an artifact: the curl response body, the screenshot, the executed command
- claims with no evidence → mark **UNVERIFIED** — not failed, not passed, and never counted toward approval

A lone green build is a thin signal: benchmark pass-signals have been exploited to near-perfect scores without solving a single task, and small reported margins sit within infrastructure noise.

## Step 4 — Read the tests as a claim

For each test file in the diff, map every assertion to a spec criterion. The green suite demonstrates only the cases the agent chose to assert — its interpretation of the task, encoded as assertions. Criteria with no covering assertion are the risky path the suite dodged; list them. Test presence alone does not predict a better outcome (merge rates are similar with or without tests).

## Step 5 — Verify forward from the spec

Walk each acceptance criterion in order and mark it:

- **BUILT** — the code or test that satisfies it, cited as file:line, plus exercised evidence where a behavior can be run (run the command, hit the endpoint, read the response — never infer from the diff)
- **PARTIAL** — implemented for some inputs/paths, with the gap named
- **MISSING** — no code satisfies it; a missing feature leaves no diff to catch it, so this pass is the only one that can see it

Treat "described in the PR but not found in the code" as a defect, not an oversight.

## Step 6 — Diff the scope, not just the correctness

List every hunk not traceable to an acceptance criterion. Each is its own failure-class finding even if the code is individually correct — unrequested scope is unsanctioned debt entering under a green build, and a fifth of AI-introduced issues survive to the repository's latest version.

## Step 7 — Calibrate depth and report

Use the triage script's blast-radius section: deep review (all steps above, behavior exercised) for auth/payments/permissions/deletion and core logic — the 1.75x logic-error and 1.57x security-finding zones — shallow allowed for isolated, low-risk surfaces. Line count is not the dial.

Emit the report:

```
## Verification report — <branch/PR>
Verdict: APPROVE / REQUEST CHANGES / DO NOT MERGE

| Criterion | Status | Evidence |
|---|---|---|

Claims vs evidence: <each PR claim → VERIFIED (evidence) / UNVERIFIED>
Unasserted criteria (test gap): <list>
Unsolicited scope: <hunks not traceable to a criterion>
Depth applied: <deep/shallow + which blast-radius signals set it>
```

Then stop. Present the report and wait to be asked before touching any file.

## Grounding

Canonical post: https://jyoung.dev/blog/evaluating-ai-coding-agent-output/ — the six moves and their ordering are that post's closing checklist. Documented facts this skill relies on: 30-40% of spec unimplemented after "complete" (LoadSys); descriptions claiming unimplemented changes as the top inconsistency at 45.4%, and 51.7% lower acceptance for high-inconsistency PRs (Gong et al., arXiv 2601.04886); fresh-grader separation and evidence-over-assertion (Anthropic Claude Code best practices); benchmark pass-signals exploitable without solving tasks (Berkeley RDI) and small margins within infrastructure noise (Anthropic); similar merge rates with or without tests (Haque et al., arXiv 2601.03556); 22.7% of AI-introduced issues surviving at HEAD (Liu et al., arXiv 2603.28592); 1.75x logic and 1.57x security findings in AI-authored PRs (CodeRabbit via The Register).
