---
name: loop-preflight
description: Preflight an unattended agent loop (a Ralph-style wrapper around an agent) before walking away from it. Use when someone is about to run an agent loop overnight or unattended, when hardening a "while :; do cat PROMPT.md | agent; done" wrapper, or when a clean one-shot demo is being offered as evidence the loop is safe. Checks the wrapper for the three stopping conditions (max-iteration ceiling, no-progress detection, spend ceiling), externalized state, and a programmatic check, prices the always-on context re-paid every iteration, then walks the single-shot-assumption migration checklist.
---

# Loop Preflight

A loop is many invocations, not one. A single prompt came with a natural end and a
memory that lasted exactly as long as the task; an unattended loop inherits neither,
and a clean one-shot demo is the weakest evidence that it will hold on turn fifty.
Full argument: https://jyoung.dev/blog/loop-engineering-breaks-your-playbook/

This skill produces a preflight report. It does not edit the wrapper, the CLAUDE.md,
or anything else unless the user explicitly asks after reading the report.

## Step 1 — Mechanical preflight

Run the bundled script against the loop wrapper (repo defaults to the wrapper's dir):

```bash
scripts/loop-preflight.sh <loop-script> [repo-dir]
```

It greps the wrapper (full-line comments stripped — a brake in a comment is not a
brake) for the three stops, a state file, and a check runner, then prices every
always-on file (CLAUDE.md plus each .md/.txt the wrapper feeds the agent) as
tokens-per-iteration times the iteration cap. Statuses:

- **OK** — a recognizable pattern for the guard was found.
- **MISSING** — no recognizable pattern. This is a heuristic: confirm by reading the wrapper, but treat it as missing until shown otherwise. Exit code 1.
- **REVIEW** — the guard may legitimately live elsewhere (e.g. the check runner); a human or agent must look.

## Step 2 — Fix what is MISSING

The reference shape is the post's hardened loop — every added line is a brake:

```bash
for i in $(seq 1 "$MAX_ITERS"); do          # (1) max-iteration ceiling
  cat PROMPT.md progress.txt | agent        # externalized state, reloaded each turn
  ./run_checks.sh || true                   # the verification the model doesn't self-grade
  git add -A
  git commit -m "iter $i" || break          # (2) nothing to commit -> no progress -> stop
done
# (3) the spend ceiling lives on the wrapper: timeout, or a token/dollar budget that kills the run.
```

Propose the minimal diff that adds each missing guard. Present it; do not apply it
unasked.

## Step 3 — Walk the migration table

The mechanical checks cover rows three and four. Walk all four with the user —
each assumption was safe when the unit of work was one invocation:

| Single-shot assumption | What changes across many invocations | Check before walking away |
| --- | --- | --- |
| Loop engineering is a new skill to learn | It is the gather/act/verify primitive already in use, now unattended | Migrate existing single-invocation habits; do not start from a blank slate |
| CLAUDE.md is a one-time cost paid at load | It reloads every turn and the loop's own output stacks on top, so context rot compounds | Is the file cut for how it reads on turn 50, with every real constraint above the fold? |
| A clean demo predicts reliability | Per-step accuracy decays and the model conditions on its own earlier mistakes, quietly | Is there a plan for the run that builds on a 2 a.m. error, not just the demo run? |
| "Done" ends the task and the window clears it | Nothing terminates the loop and nothing survives the reset | Max-iteration cap, no-progress detection, spend ceiling, and a progress file — all four present? |

For row two, the per-iteration tax table from Step 1 gives the price; the
`audit-claude-md` skill in this toolkit does the line-by-line routing pass. The
loop-specific rule is presentation over presence: a rule that is technically in the
file on turn 1 can be illegible under the run's own output by turn 50.

For row three, the failure to plan for is self-conditioning: a bad edit at iteration
12 is read by every later iteration as established fact and built on, while the
terminal shows steady progress. The counter is the wrapper-side check (Step 2, line
3) — verification the model does not self-grade — plus reviewing the run's commits,
not its final message.

## Step 4 — Report and wait

Emit: the script output, the four table answers, and a go/no-go with the reason.
Keep the run's progress file separate from durable skills and rules — they answer
different questions (what did this run do vs. what should every run know). If the
user wants the wrapper or CLAUDE.md changed, make the edits only after they ask.

## Grounding

Canonical post: https://jyoung.dev/blog/loop-engineering-breaks-your-playbook/

Documented facts this skill relies on: stopping conditions such as a max-iteration
cap are Anthropic's baseline for loops (Building Effective AI Agents); the
three-stop set (max iterations, no-progress detection, token/dollar budget) and
"the agent forgets; the repo doesn't" are from Truong Phung's agentic-loop field
guide; externalized state reconstructed from a progress file alongside git history
is Anthropic's long-running-harness guidance, with the caveat that newer models'
compaction softens the memoryless framing (the discipline holds regardless);
context rot — reliability degrading as input grows, presentation mattering more
than presence — is Chroma's result across 18 models and 194,480 calls, corroborated
in Anthropic's context-windows docs; self-conditioning on prior errors is Sinha et
al. (arXiv 2509.09677), measured on a synthetic task, mitigated by thinking, and
stronger in larger models; programmatic verification over model self-assessment is
Geoffrey Huntley's Ralph guidance. Token figures are chars/4 estimates. The claim
that a loop fails quieter than the demo is the post author's inference, marked as
such in the post.
