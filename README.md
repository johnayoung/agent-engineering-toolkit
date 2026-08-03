# agent-engineering-toolkit

Immediately usable artifacts from [jyoung.dev](https://jyoung.dev) essays on engineering practices for AI coding agents. Each tool operationalizes one post's framework — the essay is the argument, the artifact is the move.

## Install

Copy a skill directory into your repo's `.claude/skills/` (project-wide) or `~/.claude/skills/` (all your projects):

```bash
cp -r skills/audit-claude-md /path/to/your-repo/.claude/skills/
```

Each skill's script also runs standalone without Claude Code.

## Artifacts

<!-- artifacts:start -->
| Artifact | What it does | Canonical post |
|---|---|---|
| [`agent-task-go-no-go`](skills/agent-task-go-no-go/) | Runs a candidate task through the five-gate go/no-go pass — runnable check, human-time estimate, verification cost, verifiable done, blast radius — and returns the delegate/decompose/keep verdict at the first failing gate | [What AI Coding Agents Are Actually Good For (And When to Skip)](https://jyoung.dev/blog/what-ai-agents-are-actually-good-for/) |
| [`audit-claude-md`](skills/audit-claude-md/) | Inventories your CLAUDE.md loading tiers — always-loaded vs lazy vs skills, @imports expanded, token estimates — then routes every section to the tier that should own it | [How to Structure CLAUDE.md: It's a Loading Policy, Not a Document](https://jyoung.dev/blog/claude-md-context-hierarchy/) |
| [`audit-jit-retrieval`](skills/audit-jit-retrieval/) | Audits an agent's JIT retrieval surface against the five-row failure ledger — dead references, tool-description routing, empty semantic results, uncapped loops, fallback re-injection — reporting which failures are loud and which are silent; bundles a standalone tool-catalog audit script | [Where Just-in-Time Context Retrieval Silently Breaks](https://jyoung.dev/blog/jit-context-retrieval-failure/) |
| [`decompose-epic`](skills/decompose-epic/) | Converts one epic into a task graph whose nodes each carry an exclusively owned write glob, a single-owner interface contract, explicit acyclic edges, and a mechanical acceptance predicate — with a standalone checker that tests the globs against the real repo for overlap, contracts for two owners or none, edges for cycles, and acceptance criteria for prose, and calls a one-node graph what it is: run it monolithic | [Task Decomposition for AI Coding Agents: Draw the Graph First](https://jyoung.dev/blog/task-decomposition-for-ai-coding-agents/) |
| [`isolation-gate`](skills/isolation-gate/) | Walks a proposed multi-agent split through the two-gate flowchart — isolation need first, coordination readiness second — and returns a verdict at the first failing gate | [When One Agent Stops Being Enough: The Isolation Gate](https://jyoung.dev/blog/multi-agent-context-isolation/) |
| [`lint-claude-md`](skills/lint-claude-md/) | Runs every line of a CLAUDE.md through the post's per-line decision table — instruction-ceiling budget, self-evident/negative/vague/hook-shaped flags, canary probe check — and emits a keep/rewrite/cut/hook verdict report | [CLAUDE.md Instruction Ceiling: Maintained Config, Not a README](https://jyoung.dev/blog/claude-md-instruction-ceiling/) |
| [`loop-preflight`](skills/loop-preflight/) | Preflights an unattended agent loop before you walk away: checks the wrapper for the max-iteration, no-progress, and spend brakes plus externalized state and a non-self-graded check, and prices the always-on context re-paid every iteration | [Loop Engineering Breaks Your Single-Shot Context Playbook](https://jyoung.dev/blog/loop-engineering-breaks-your-playbook/) |
| [`size-agent-task`](skills/size-agent-task/) | Runs a proposed agent task through the five-gate sizing flowchart (one-sentence diff, independent verifiability, layer crossing, exploration cost, decomposition floor) and bundles a standalone script that measures any git diff against the PR-sizing research thresholds | [How to Size Tasks for AI Coding Agents](https://jyoung.dev/blog/how-to-size-tasks-for-ai-coding-agents/) |
| [`tier-agent-authority`](skills/tier-agent-authority/) | Classifies every action an agent can take — Claude Code permission rules mechanically, ambient credentials by inventory — into four authority tiers by reversibility and blast radius, flags any action holding a control looser than its tier's default, and proposes a measured graduation ledger | [Tier Your AI Agent's Production Authority by Task Risk](https://jyoung.dev/blog/agent-permission-tiering/) |
| [`verify-agent-pr`](skills/verify-agent-pr/) | Runs an agent-authored PR through the six-move verification checklist as a fresh grader — evidence over self-report, tests read as claims, spec-forward verification, scope diff, blast-radius depth — with a standalone diff-triage script | [How to Verify AI Coding Agent Output: A Reviewer's Framework](https://jyoung.dev/blog/evaluating-ai-coding-agent-output/) |
| [`cost-guardrail-checklist`](templates/cost-guardrail-checklist/) | Pre-ship checklist for agent spend controls: seven layers, each requiring both an attribution dimension (which task spent) and an enforcement ceiling (what refuses the next call), with a verified LiteLLM per-session config | [You Can't Cap What You Can't Attribute: Per-Task Cost](https://jyoung.dev/blog/per-task-cost-attribution/) |
| [`harness-audit`](templates/harness-audit/) | Read-only scan that answers the post's seven harness questions against a repo plus your user-scope config — permission rules by scope, the three enforcement buckets, sandbox keys including excludedCommands, registered hooks with their exit-1 fail-open paths, telemetry switches, and runtime version — marking every control DEFAULT, SET, or UNDETERMINED without grading any of them | [Audit Your Agent Harness: The Deterministic Layer Nobody Reviews](https://jyoung.dev/blog/agent-harness-audit/) |
| [`ownership-cost-gate`](templates/ownership-cost-gate/) | Walks one build-vs-buy candidate through the five-gate ownership-cost flowchart — prices the 60/60 maintenance tail from your first-build estimate, then gates on differentiation, continuous verification, compliance-as-product, and the internal-build base rate | [Build vs. Buy Agentic AI: Ownership Is the New Decision](https://jyoung.dev/blog/build-vs-buy-agentic-ai/) |
| [`size-review-capacity`](templates/size-review-capacity/) | Turns your reviewer count, focused review-hours, and PR volume into attention-per-PR and a clears/exceeds verdict for the next agent you want to add, with the post's six-gate scorecard as a copy-paste checklist | [Review Capacity Is the Real Ceiling on Your Agents](https://jyoung.dev/blog/review-capacity-agent-throughput/) |
| [`task-spec`](templates/task-spec/) | Copy-paste task-spec skeleton with the post's nine sections (goal, context, constraints, non-goals, acceptance criteria, verification), plus a lint script that fails on missing sections and flags vague acceptance criteria | [The Anatomy of a Perfect AI Agent Task](https://jyoung.dev/blog/anatomy-of-a-perfect-ai-agent-task/) |
<!-- artifacts:end -->

Each artifact directory carries an `artifact.json` (name, form, canonical post) and a Grounding section citing its sources. Skills with a `scripts/` directory also run standalone, for example:

```bash
skills/audit-claude-md/scripts/audit-claude-md.sh [target-dir]
```

## License

MIT
