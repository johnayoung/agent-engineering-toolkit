# Edge justification worksheet — worked example

Two edges, run through the same table.

**Edge 1** reconstructs the thirty-agent run from Anthropic's Frontier Red Team report: thirty coding
agents, one repository, one goal, no assigned branch names — and eighteen agents independently created
a branch called `mvp-game-loop`. The cells below are the ones that were actually answered. The checker
deletes it, which is the whole point: nothing about this edge was ever justified.

**Edge 2** is an illustrative context-pollution edge, invented for this example — the numbers in it are
made up to show the shape of a cell that survives, not measurements of anything.

---

## Edge: orchestrator -> implementer agent #7 (of 30), same repo, same goal

- **Single agent enough:** yes — an MVP game loop is coding work one capable agent completes end to end
- **Coordination lives:** <unanswered — no assignment, no lock, no name registry, no shared plan>
- **Forcing constraint:** throughput — thirty agents finish thirty times faster than one
- **Constraint evidence:** <unanswered>
- **Risk tier:** <unanswered>
- **Objective:** Implement the MVP game loop. Open a PR when you're done.
- **Output format:** <unanswered — no branch name, no PR title, no diff ceiling>
- **Tools and sources:** <unanswered — full repo, full toolset>
- **Task boundaries:** <unanswered>
- **Review node:** <none — PRs opened straight into the repository>
- **Upstream of irreversible action:** no — branch creation is the agent's first action
- **Token budget:** <unanswered>
- **Reviewer-minute budget:** <unanswered — nobody was named as the reviewer of thirty PRs>
- **Equal-compute comparison:** not run

---

## Edge: implementer -> read-only explorer subagent (illustrative numbers)

- **Single agent enough:** no — the implementer's window is at 78% by step 12 and it still needs the auth-expiry map
- **Coordination lives:** `docs/agent/handoff/session-expiry.md`, written by the explorer and read by the implementer; nothing else crosses
- **Forcing constraint:** context pollution
- **Constraint evidence:** 31k tokens of grep output and migration history in the implementer's window, none of it re-read after step 4
- **Risk tier:** low — the explorer reads only; it holds no write tools and opens no PR
- **Objective:** a map of every place session expiry is enforced in `src/auth/`, with file and line references
- **Output format:** one markdown file, `docs/agent/handoff/session-expiry.md`, under 40 lines, one bullet per enforcement site; this edge creates no branch
- **Tools and sources:** read-only file reads and ripgrep under `src/auth/` and `migrations/`; no network, no shell writes
- **Task boundaries:** no edits, no test runs, no dependency installs, no opinions about the fix; stop at the map
- **Review node:** the human PR review on the implementer's diff, with the explorer's map quoted in the PR body so the reviewer checks the map and the diff together
- **Upstream of irreversible action:** yes — the map is reviewed before the implementer's PR can merge
- **Token budget:** ~35k tokens per run, ~3 runs/day
- **Reviewer-minute budget:** 6 min/day — 3 maps/day at 2 minutes to check each map against the diff it justified
- **Equal-compute comparison:** ran the same task single-agent at twice the budget; it re-read the same migration history and hit the window at step 15, so the summary boundary is what changed, not the compute
