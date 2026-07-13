---
name: isolation-gate
description: Decide whether a task should be split across multiple agents. Use when someone proposes multi-agent, parallel agents, or subagent fan-out for a piece of work, or when a single agent's output is degrading mid-task and "add more agents" is on the table. Walks the concrete task through an ordered two-gate flowchart — isolation need first (pollution diagnosis, in-session subagent fix, the ~15x token bill), then coordination readiness (single-threaded writes, file ownership, ordering, decomposability) — and reports a verdict at the first failing gate instead of defaulting to a swarm.
---

# Isolation Gate

The trigger for multi-agent is not parallel speed — it is context isolation, and the split costs about 15x the tokens of a single chat. Two ordered gates decide whether it's worth it: is one window still enough (isolation), and can writes stay single-threaded with clean coordination (readiness). Most walks end early, at the cheap fix. Full argument: https://jyoung.dev/blog/multi-agent-context-isolation/

This skill produces a verdict report. It does not spawn agents, restructure the task, or edit files unless the user explicitly asks after reading the report.

## Step 0 — Pin the concrete task

The gates only mean something against a specific "should I split THIS?". State the task in one sentence, then list what is actually accumulating in the window: files opened, searches run, logs pasted, history walked. Ask the user or inspect the conversation and repo — do not run the gates against a hypothetical.

## Step 1 — Gate 0: speed wish or isolation need (stop: don't split)

Why is a second agent on the table? "It would finish sooner" is a speed wish — not a trigger, and it does not clear a 15x bill. Continue only if one context window genuinely cannot hold the job cleanly.

## Step 2 — Gate 1: pollution, not size (diagnostic)

Diagnose *why* the window is failing before counting tokens. Look for these distractor signals in the actual window contents from Step 0:

| Signal | What it looks like |
|---|---|
| orientation noise | search results grepped once, never read again |
| stale logs | output pasted to debug one thing, resident ever since |
| dead-end files | opened, ruled out, still in the window |
| spelunking | history walked to understand a schema, mostly irrelevant to the change |

Even a single distractor degrades output (Chroma, 18 models), well before any size limit — so if you found distractors, the target is getting them out of the window, not buying a bigger one. If you found none, re-check before concluding it's raw size; either way, continue.

## Step 3 — Gate 2: in-session isolation (stop: isolate, don't split)

Would a read-only subagent — doing the side-quest in its own context window and returning only a summary — fix it? If yes, the verdict is **isolate in-session**: emit a filled-in explorer block for this task (skeleton: `scripts/isolation-gate.sh --template`) with a concrete Goal, a "Return only" list (the 3–5 files to edit, the pattern to mirror, non-inferable constraints), and a "Do not" list (no raw file contents back, no edits). Stop here; the ~15x bill is never paid. Continue only if the summary plus the real work still overruns one window.

## Step 4 — Gate 3: the ~15x token bill (stop: don't split)

Multi-agent systems use about 15x the tokens of a chat, and token usage alone explains 80% of performance variance (Anthropic). State what the isolation buys for this task and whether it is obviously worth that multiple. "One window genuinely cannot hold this and the isolation makes the output correct" clears it; nothing about speed does. If it isn't obviously worth 15x, the verdict is don't split.

## Step 5 — Gate 4: single-threaded writes (stop: don't split)

Can the split keep exactly one writer, with the extra agents contributing read-only intelligence? Check the task's writes — edits, migrations, generated files. Multi-agent works best today when writes stay single-threaded (Cognition); if the split genuinely requires two agents writing to the same tree, the verdict is don't split.

## Step 6 — Gate 5: coordination readiness (stop: keep single-agent)

Run the checklist against the task's real surface, not optimism. Any failure means keep it single-agent:

1. **File ownership** — does each agent own a disjoint set of files?
2. **Lock-file contention** — would agents run git operations against the same working tree at the same time? (Git's file-based locking makes the second one fail hard; separate worktrees remove this.)
3. **Migration ordering** — must steps apply in a fixed order? Ordered work is not parallel work.
4. **Dependency sequencing** — does one piece consume another's output?
5. **State dependence** — does each step mutate state the next step reads? Sequential work swings to −70.0% vs single-agent where decomposable work gains +80.8% (Kim et al.).

## Step 7 — Gate 6: fan-out cap

Would the planned fan-out exceed what the user can actually review and land? Verification, not generation, is the bottleneck; one significant change lands at a time. Cap at three to five — three focused agents consistently outperform five scattered ones (Osmani, Willison).

## Report format

Emit one row per gate walked, then the verdict:

```
| Gate | Question | Finding (this task) | Result |
```

Close every split-permitting verdict with: if the split backfires, debug the coordination design — conflicting implicit decisions between agents — before blaming the model; failures cluster into system design, inter-agent misalignment, and task verification, none of which is model weakness (Cemri et al.; Cognition).

## Standalone script

`scripts/isolation-gate.sh` walks the same gates without Claude: interactive prompts, or `--answers i,p,n,y,y,y,n,n,n,n,n` for a non-interactive walk (tokens in gate order; a stop short-circuits the rest). `--template` prints the explorer-subagent skeleton.

## Grounding

Canonical post: https://jyoung.dev/blog/multi-agent-context-isolation/. Documented facts this skill relies on: ~15x tokens vs chat and token usage explaining 80% of variance (Anthropic, multi-agent research system); a single distractor degrading output across 18 models (Chroma, Context Rot); subagents running in their own window and returning only a summary (Claude Code docs); single-threaded writes as the working configuration (Cognition, "Multi-Agents: What's Actually Working"); +80.8%/−70.0% swing by task structure across 260 configurations (Kim et al., arXiv 2512.08296); failure modes clustering into design/misalignment/verification (Cemri et al., arXiv 2503.13657); git lock-file contention and sequencing (Augment Code); the 3–5 fan-out sweet spot (Addy Osmani) bounded by review throughput (Simon Willison). The gates themselves are judgment calls; this skill orders them and prices the stops — it does not answer them.
