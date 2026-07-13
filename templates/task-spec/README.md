# task-spec

Copy-paste skeleton for an AI coding agent task spec, plus a lint script that checks a written spec for the required sections.

## Usage

```bash
cp task-spec-template.md my-task.md   # fill it in, delete the comments
./lint-task-spec.sh my-task.md        # exit 0 = all sections present; 1 = missing/empty sections
```

The template's nine sections cover the seven elements of a well-formed task spec: Goal (outcome, not steps), Architectural Context (only what the agent can't infer from code), Relevant Files, Reference Implementation, Constraints, Non-Goals, Edge Cases, Acceptance Criteria (observable, specific, testable), and Verification (exact commands the agent runs to self-check).

The lint script:

- **FAILs** on any required section that is missing or empty (exit 1)
- **WARNs** on vague acceptance-criteria phrases ("should work correctly", "as expected") — heuristic scan, human judges
- **WARNs** when the Verification section has prose but no runnable command
- **WARNs** past 150 content lines — a rough proxy for instruction count, not an exact measure

## When not to use this

For trivial work — a typo fix, a rename, anything the agent has no real risk of getting wrong — skip the spec and write one sentence. The sections are a maximum, not a minimum: every irrelevant detail dilutes the signal of the details that matter.

## Grounding

Canonical post: [The Anatomy of a Perfect AI Agent Task](https://jyoung.dev/blog/anatomy-of-a-perfect-ai-agent-task/)

Documented facts this artifact relies on:

- The nine-section spec shape is the post's own worked example ("Add E.164 phone validation to UserService").
- Goal/constraints/done as the core trifecta: Claude Directory, "Context Engineering for Claude Code".
- The ~150–200 instruction ceiling and fewer-focused-instructions guidance: HumanLayer, "Writing a Good CLAUDE.md"; context-length degradation: Chroma, "Context Rot" (Hong et al., 2025). The lint's line count is a rough proxy for instruction count and is labeled as such in its output.
- Vague-criteria flag ("should work correctly") is the post's own counterexample for acceptance criteria; test-based done-definitions: Google Cloud, "Five Best Practices for AI Coding Assistants".
- Verification commands as agent self-check: Claude Code docs, "Best Practices".
