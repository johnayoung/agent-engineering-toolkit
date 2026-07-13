---
name: size-agent-task
description: Run a proposed AI-agent coding task through the five-gate sizing flowchart before writing the spec or starting the session. Use when scoping a task for an agent, when a previous attempt spiraled into corrections or context exhaustion, when deciding whether to split work across milestones, or retrospectively on a finished diff. Gates - one-sentence diff test, independent verifiability, layer crossing, exploration cost, decomposition floor - produce a verdict of right-sized, decompose, restructure, or bundle. Includes a standalone script that measures any git diff against the PR-sizing research thresholds (200 LOC target, 400 soft / 600 hard limit).
---

# Size Agent Task

The real constraint on agent task size is context, not lines of code: model performance degrades as the window fills, so the sizing question is whether the task completes before reasoning quality degrades. Full argument: https://jyoung.dev/blog/how-to-size-tasks-for-ai-coding-agents/

This skill produces a sizing report and, when needed, a proposed decomposition. It does not create task files, edit specs, or start implementing unless the user explicitly asks after reading the report.

Input: a task description (one or more sentences) and a target repo (default: current directory). Run the gates in order — the earlier gates are cheaper and their failures are more decisive.

## Gate 1 — The one-sentence diff test

Write the expected diff as a single sentence. "Add a nullable `phone_number` column to the users table with an up and down migration" passes. "Add phone number support across the full stack" fails.

- **Pass** — one sentence, one logical boundary. Continue.
- **Fail** — the sentence needs "and" joining changes at different layers, or you cannot write it at all. Verdict leans **DECOMPOSE**; the split points come from Gate 3.

## Gate 2 — Independent verifiability

Name the exact command or check that confirms this task worked in isolation — a test run, a lint pass, a migration up/down, an endpoint hit. Verification is part of the task definition, not an afterthought.

- **Pass** — a concrete command exists and does not require the *next* task to be done first.
- **Fail** — nothing verifies it alone. The task is either a fragment of a meaningful change (merge it into one) or too entangled with other work. Verdict: **RESTRUCTURE**.

## Gate 3 — Layer crossing

List the architectural layers the diff touches: migration/schema, model/generated code, service/business logic, handler/API, frontend/UI, docs/config. If it spans more than one layer and the total change is non-trivial, split along the boundaries — each layer is independently verifiable and produces a clean commit:

1. Migration — add the schema change, verify migrate up/down
2. Model + generated code — update structs and queries, verify no diff
3. Service + validation — business logic plus its unit tests
4. Handler + integration — wire the endpoint, integration-test the flow

If a later milestone fails, the earlier commits survive. Skip the split only when the whole change is small enough that splitting adds more overhead than it saves.

## Gate 4 — Exploration cost

Enumerate the actual read set from the repo: glob and grep for the files, interfaces, tests, and fixtures the agent would have to read before making a safe change. Count them. Expect roughly 2x the files it will change.

- **Under ~10 files** — pass.
- **Over ~10 files** — either the task is too broad, or the spec must pre-load context the agent would otherwise burn tokens discovering. If the task is otherwise coherent, do not shrink it — instead list the exact file paths, reference implementations, and architectural notes to put in the spec.

The ~10-file threshold and the 2x multiplier are the post author's heuristics, not researched numbers. Say so in the report.

## Gate 5 — The decomposition floor

If you could do the task faster manually than writing the spec, starting a session, and reviewing the output, it is too granular — a standalone "add a column to the struct" gives the agent nothing meaningful to verify. Verdict: **BUNDLE** with the next logical step in the same layer ("add the column to the struct, update the queries, regenerate the generated code" is still one coherent thing).

## Emit the report

```
| Gate | Result | Evidence |
|---|---|---|
| 1. One-sentence diff | pass/fail | <the sentence, or why none exists> |
| 2. Verifiable alone  | pass/fail | <the verification command> |
| 3. Layers touched    | N | <layer list> |
| 4. Read set          | N files | <the enumerated paths> |
| 5. Above the floor   | yes/no | <manual-effort comparison> |
```

Then the verdict: **RIGHT-SIZED** / **DECOMPOSE** / **RESTRUCTURE** / **BUNDLE**. For DECOMPOSE, list the proposed subtasks in dependency order, each with its own one-sentence diff, verification command, and estimated read set — every subtask must itself pass Gates 1–5. For a right-sized task whose read set is large, list the files to pre-load in the spec.

Target for each resulting task: a diff a human can review in one pass — around 200 changed lines, roughly 2–5 files in a layered codebase (the file counts are the author's Go-centric translation; they vary by language).

## Retrospective check

After the agent ships, measure the actual diff against the research thresholds without Claude:

```bash
scripts/check-diff-size.sh [-C repo] [ref-range | --staged]
```

Reports changed lines and files against the 200 LOC target, 400 soft / 600 hard limits, flags the largest files, and exits nonzero over the limits so it can gate a pre-PR hook.

## Grounding

Canonical post: https://jyoung.dev/blog/how-to-size-tasks-for-ai-coding-agents/

Documented facts this skill relies on: context-fill degradation across 18 LLMs (Chroma, "Context Rot", Hong et al. 2025); one-thing-per-session, the kitchen-sink antipattern, and the one-sentence diff test (Claude Code best-practices docs); review quality dropping past 200 changed lines with a 400 soft / 600 hard team limit (Google research via EM Tools; Augment Code); 200–400-line PRs showing 40% fewer defects and >1,000-line PRs 70% lower defect detection across 50,000+ PRs (Propel); verification as part of task definition (Google Cloud). The ~10-file exploration threshold, the 2–5 files-changed band, the 2x read multiplier, and the layer-boundary split rule are the post author's judgment, labeled as such there and here.
