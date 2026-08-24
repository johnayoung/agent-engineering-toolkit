# Edge justification worksheet — <system or repo name>

You start at zero edges. Every agent-to-agent edge below has to earn its own existence, and an empty
cell deletes it. Copy one `## Edge` block per edge you want to draw, fill every field, then run:

```bash
./check-edges.sh this-file.md
```

Field labels are parsed by the checker — keep them exactly as written. Delete the `<angle bracket>`
placeholders; the checker reads a placeholder as an empty cell, which is the same as no answer.
(A cell counts as a placeholder when the whole value sits inside brackets, or when a bracketed
phrase contains a space. Path fragments like `docs/handoff/<task-id>.md` are real answers.)

From [The Topology You Can Review Is the Topology You Can Run](https://jyoung.dev/blog/agent-architecture-review-capacity/).

---

## Edge: <upstream agent or node> -> <downstream agent>

<!-- One line: what work crosses this edge. -->

- **Single agent enough:** <no — why one agent cannot do this work; "yes" deletes the edge>
- **Coordination lives:** <the file, lock, queue, assignment, or shared artifact where this edge's coordination physically happens>
- **Forcing constraint:** <exactly one of: context pollution | parallelism | specialization>
- **Constraint evidence:** <the signal you actually observed — a filled window, two changes with no shared symbol/test/ordering, a tool the main agent must not hold>
- **Risk tier:** <low | medium | high | critical — the tier of the work crossing the edge, from your authority table>
- **Objective:** <what the downstream agent produces, stated as an outcome>
- **Output format:** <PR title, branch name, file paths, diff ceiling — every coordination-relevant field the agent would otherwise infer>
- **Tools and sources:** <what it may read and run; what it may not open>
- **Task boundaries:** <what is explicitly out of scope for this edge>
- **Review node:** <the node that adjudicates this edge's output, and who or what sits in it>
- **Upstream of irreversible action:** <yes | no — does the node block before the branch/write/deploy happens?>
- **Token budget:** <expected tokens per run for this edge>
- **Reviewer-minute budget:** <N min/day — expected diffs per day x minutes per diff at your measured review capacity>
- **Equal-compute comparison:** <what happened when you spent the same compute on one agent; "not run" deletes the edge>

---

<!--
Field notes.

Single agent enough
  On SWE-bench Verified every multi-agent architecture lost to the single-agent baseline
  (-2.1% hybrid to -14.9% independent, Kim et al.). Directional, not decisive - 20-instance
  subsets - but uniform. You are drawing against the measured default; say why.

Forcing constraint
  Closed list of three, from Anthropic: context pollution, parallelism, specialization.
  Risk is not on the list. Risk earns a review node, not another worker. So do "quality",
  "speed", "thoroughness", "separation of concerns", and every other reason that is really
  an aesthetic preference.

Risk tier
  Reuse the tiers you already assigned in your authority table (low / medium / high /
  critical by reversibility and blast radius). Do not invent a topology-specific axis. The
  tier tells you whether this edge terminates in a merge or in a checkpoint.

Objective / Output format / Tools and sources / Task boundaries
  Anthropic's four-field subagent spec. The branch name belongs in Output format: thirty
  agents inferred their own and eighteen inferred the same one.

Review node + Upstream of irreversible action
  A stage is a thing a person can skip under load; a node is a thing the runtime blocks on.
  If the node sits downstream of the irreversible action, it is documentation.

Both budgets
  Multi-agent implementations used 3-10x the tokens of single-agent for equivalent tasks in
  Anthropic's internal testing (no methodology published - a floor, not a forecast). The
  reviewer bill is the one that halts the pipeline, and almost nobody writes it down.
  Price the merge separately from the review: git detects textual conflicts, not semantic ones.

Equal-compute comparison
  Held to equal thinking tokens, single-agent matched or beat multi-agent across two datasets,
  three model families, and five architectures (Tran & Kiela) - so a reported win may be a
  compute increase wearing an architecture costume. That paper scopes out tool use, so it is
  indirect evidence for coding. Run the comparison anyway; it is cheap.
-->
