---
name: lint-claude-md
description: Run every line of a CLAUDE.md through a per-line admission gate against the agent's instruction ceiling. Use when you are about to add a rule to CLAUDE.md, when Claude ignores an instruction that is plainly in the file, when the file has crossed ~200 lines, or on the periodic prune. Flags self-evident filler, negative-framed rules, vague wishes, and hook-shaped rules, then produces a keep/rewrite/cut/hook verdict per line. Complements audit-claude-md, which routes sections between loading tiers; this skill decides whether each line earns a slot at all.
---

# Lint CLAUDE.md

Frontier models follow roughly 150-200 instructions with reasonable consistency, and Claude Code's system prompt spends ~50 of that before CLAUDE.md loads. Past the ceiling, rules are not argued with or violated — they are omitted silently. And the file is advisory: it arrives as a user message after the system prompt, with no guarantee of compliance. Every line is therefore a wager drawn from a nearly-full account, and each one has to earn its slot. Full argument: https://jyoung.dev/blog/claude-md-instruction-ceiling/

This skill produces a report. It does not edit the file unless the user explicitly asks for the changes after reading the report.

## Step 1 — Mechanical lint

Run the bundled script against the target (a CLAUDE.md path or a directory containing one; default: current directory):

```bash
scripts/lint-claude-md.sh [target]
```

It reports the line budget (rule vs functional split, the over-200-lines flag), pattern-flags four decaying line classes (self-evident, hook-shaped, negative-framed, vague), and checks for a canary probe. All counts are pattern heuristics — treat every flag as a candidate, not a verdict.

## Step 2 — Judgment gates, per rule line

Read the file. For every rule line — flagged or not — run the gates the script cannot:

| Gate | Ask | If it fails |
|---|---|---|
| Earns-its-line | What real failure demanded this line? Check `git log -p` for the commit that added it, or ask the user. | No failure, no line — cut |
| Anticipatory | Was it added "just in case," before any mistake? | Cut — speculation occupying a slot |
| Runnable check | Can the agent execute it or fail visibly? | Rewrite the wish as a check ("Run `npm test` before committing", not "Test your changes") |
| Conflict | Does another line contradict it? | Resolve — Claude may pick one arbitrarily |
| Prune test | Would removing it cause Claude to make mistakes? | If not, cut it |
| Hook escalation | Can it never be dropped, even once? | Move it to a PreToolUse/Stop hook — hooks are deterministic, CLAUDE.md is advisory |

Confirm or dismiss each script flag in the same pass. The patterns produce false positives: a "never" line that is a hard safety boundary keeps its DO NOT — the prohibition itself is the point there.

## Step 3 — Emit the verdict report

One row per line that fails a gate:

```
| Line | Text (trimmed) | Gate failed | Verdict | Rewrite (if any) |
```

Verdicts: **keep** / **rewrite as check** / **rephrase positive** / **cut** / **move to hook**.

Close the report with:

- Projected file size and rule count after the verdicts, against the ~150-200 ceiling and the under-200-lines file target.
- Whether a canary probe exists at the bottom of the file; if not, recommend one — a single throwaway line whose disappearance from live sessions signals the file has breached the ceiling.
- The caveat that adherence also decays mid-session: compaction can summarize CLAUDE.md values away, so a change is tested by watching behavior in a live session, not by re-reading the file.

Then wait. Apply changes only if the user asks.

## Grounding

Canonical post: https://jyoung.dev/blog/claude-md-instruction-ceiling/

Documented facts this skill relies on: the ~150-200 instruction ceiling and the ~50 instructions Claude Code's system prompt spends first (HumanLayer, "Writing a good CLAUDE.md"); silent omission as the over-ceiling failure mode (IFScale benchmark, arXiv 2507.11538); CLAUDE.md delivered as an advisory user message, the failure-earned admission gate, the runnable-check phrasing, the under-200-lines target, and the hook-escalation test (Anthropic Claude Code memory docs); the per-line prune test and hooks-are-deterministic (Anthropic best-practices docs); negative instructions unreliable as user prompts, with the hard-safety-boundary caveat (Zhu Liang, "The Pink Elephant Problem"); a single distractor line reducing performance (Chroma, "Context Rot"); mid-session compaction decay (Albert Nahas, dev.to). All verified 2026-07-13.
