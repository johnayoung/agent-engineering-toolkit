---
name: audit-claude-md
description: Audit a repository's CLAUDE.md loading tiers and produce a line-by-line routing report. Use when a CLAUDE.md has grown past ~200 lines, when Claude ignores instructions that are plainly in the file, when someone proposes splitting CLAUDE.md into @imports to save context, or whenever the periodic "prune the CLAUDE.md" ritual comes around again. Inventories the always-loaded, lazy, and skill tiers with token estimates, then routes every section to the tier that should own it.
---

# Audit CLAUDE.md

A CLAUDE.md is a loading policy, not a document. Files at or above the working directory load in full at every session launch; subdirectory files load on demand when Claude reads files there; skills load metadata always (~100 tokens each) and their body only on trigger. `@path` imports do NOT reduce context — imported files expand at launch. Full argument: https://jyoung.dev/blog/claude-md-context-hierarchy/

This skill produces a report. It does not edit any file unless the user explicitly asks for the changes after reading the report.

## Step 1 — Mechanical inventory

Run the bundled script against the target repo (default: current directory):

```bash
scripts/audit-claude-md.sh [target-dir]
```

It prints the three tiers with line counts and token estimates, expands `@` imports recursively (depth 4, matching Claude Code's limit), and flags files over the 200-line adherence target plus any imports masquerading as savings.

## Step 2 — Read every always-loaded file

Read each Tier 1 file the script listed, including every expanded import. These lines are paid at the start of every session regardless of task — they are the audit's subject. Do not classify from the filenames; read the content.

## Step 3 — Classify every section

For each section (or standalone entry) in the always-loaded content, assign exactly one class:

| Class | Test |
|---|---|
| universal fact | Needed in every session: build commands, layout, always-do-X rules, critical gotchas |
| directory-scoped | Only matters when working in one part of the codebase |
| procedure | A multi-step workflow, checklist, or reference doc — used sometimes, not always |
| enforcement | A rule that must never be violated (formatting, forbidden actions) |
| unjustifiable | Removing it would not cause Claude to make mistakes |

## Step 4 — Emit the routing report

One row per section, in a markdown table:

```
| Section (file:lines) | Class | Verdict | Destination | Why |
```

Verdicts, per class:

- universal fact -> **keep in root** (it competes for the adherence budget — keep the root pointers-and-gotchas tight)
- directory-scoped -> **move** to `<dir>/CLAUDE.md` or a path-scoped rule next to the code it governs
- procedure -> **move to a skill** (propose the skill name; note the body loads on trigger but persists for the rest of the session once invoked)
- enforcement -> **convert to a hook** (hooks are deterministic; CLAUDE.md is advisory context, not enforcement)
- unjustifiable -> **delete** (agents generally follow what context files say — a useless line is obeyed at cost, not ignored for free)

Close the report with: the projected Tier 1 total after routing (lines and ~tokens), and the caveat that nested lazy loading is documented design with open reliability reports on some surfaces — verify with `/memory` on your surface before relying on it.

## Grounding

The tier mechanics, the 200-line target, the imports-load-at-launch behavior, and the routing rule are Anthropic's documented guidance (Claude Code memory and best-practices docs, verified 2026-07-13). The compliance-cost framing (misplaced lines are obeyed, not ignored) is from Gloaguen et al., "Evaluating AGENTS.md" (arXiv 2602.11988). Sources and the full argument: https://jyoung.dev/blog/claude-md-context-hierarchy/
