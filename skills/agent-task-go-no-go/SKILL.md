---
name: agent-task-go-no-go
description: Score a candidate task against the five-gate go/no-go pass before delegating it to a coding agent. Use when the user asks whether a task should go to an agent at all, hands over a vague cleanup ("clean this up", "make it better", "clean up old branches"), proposes a multi-hour job as a single prompt, or requests anything touching irreversible actions (force-push, branch deletion, mass delete, sending data externally). Gates, in order — a runnable check exists, human-time estimate sits under the reliability cliff, verification costs less than authorship, "done" is stateable as verifiable, blast radius is reversible. First failing gate is the verdict, and the verdict is reported before any task work starts.
---

# Agent task go/no-go

Which agent you use barely moves the outcome. What moves it is whether the task has a cheap correctness check and a working undo. This skill runs a candidate task through the five-gate pass from https://jyoung.dev/blog/what-ai-agents-are-actually-good-for/ — in order, short-circuiting at the first failure.

This skill produces a verdict report first. If the verdict is a no-go, do not start the task; present the report and wait. If the user overrides after reading it, they own the override — but a gate 5 failure means the irreversible step itself stays with the user regardless.

## The pass (order is load-bearing)

| # | Gate | Fails when | Verdict on failure |
|---|---|---|---|
| 1 | Closed loop | No check the agent can run itself (test / build / lint / diff-against-fixture) | KEEP IT — no closed loop, no delegation |
| 2 | Reliability cliff | A competent human would need more than a few hours | DECOMPOSE into sub-hour verifiable pieces, or keep it |
| 3 | Verification tax | Checking the output costs more than writing it | WRITE IT — review harder than authorship is a net loss |
| 4 | Verifiable "done" | The goal is taste, judgment, or context only the user holds | KEEP IT — measured productivity goes negative here |
| 5 | Blast radius | A wrong result is irreversible or expensive to detect | YOUR HANDS — this gate overrides all the others |

All five pass: DELEGATE, with the verification command written into the prompt and evidence required over assertion.

## What to infer vs. what to ask

- **Gate 1 — inspect, don't ask.** Look in the repo for a test suite, build, or lint that covers the area the task touches. Name the exact command in the report (e.g. `go test ./internal/user/...`). If nothing covers it, the gate fails — do not accept "I'll eyeball the diff" as a check.
- **Gate 2 — propose, user decides.** Offer a human-time estimate with one line of reasoning, then ask. The user's estimate wins; if they say "hours," the task is not one task.
- **Gate 3 — ask, but flag the signs.** Verification cost depends on the user's familiarity, which you cannot read. Flag the warning signs before asking: unfamiliar module, cross-cutting change, output with no fixture to diff against.
- **Gate 4 — test the task text.** Fail the gate on vague-cleanup phrasing ("clean up", "improve", "modernize", "make it better"), taste-heavy targets (look-and-feel UI, tone), judgment artifacts (ADRs, design docs, messages), or business logic whose why is written nowhere. The test: can you restate "done" as a check without asking the user a clarifying question? If not, the gate fails as stated.
- **Gate 5 — enumerate the actions.** List what the task would actually execute. Any action in the destructive class fails the gate: force-pushing over history, deleting branches or tags, mass file or cloud-storage deletion, irreversible migrations, sending internal data externally. The canonical example is "clean up old branches" — the agent pattern-matched "old" and issued a history-destroying delete.

## Report format

```
| Gate | Answer | How answered (inferred / user) | Result |
```

Then the verdict block: the verdict, the failing gate (if any), and the next move — the delegation prompt with the verification command embedded, the decomposition seams, or "keep it" with the reason. Then stop and wait.

## Standalone script

`scripts/go-no-go.sh` runs the same pass as an interactive terminal Q&A — no Claude required:

```bash
scripts/go-no-go.sh "add E.164 validation to ValidatePhone"     # interactive
scripts/go-no-go.sh --answers y,2,n,y,y "same task"             # non-interactive
```

Exit codes: 0 = DELEGATE, 1 = no-go verdict, 2 = usage or input error.

## Grounding

Canonical post: https://jyoung.dev/blog/what-ai-agents-are-actually-good-for/

Documented facts this skill relies on: METR's reliability cliff (near-100% success on tasks under ~4 human-minutes, <10% past ~4 hours; horizon doubling ~every 7 months); METR's field study (developers 19% slower with AI on high-context work while believing they were ~20% faster); Osmani's survey figures (only 48% consistently check AI-assisted code; 38% find reviewing it harder than human code); Anthropic's autonomy measurement (0.8% of real agent actions irreversible) and the "clean up old branches" incident from the Claude Code auto-mode write-up. These are measurements from those sources, not guarantees about any specific task.
