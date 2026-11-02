# hardened-loop

A `loop.sh` for unattended `claude -p` runs. Every control is there because a default is unlimited or because a published loop went wrong without it. Every exit prints the control that fired, to stderr and as the last line of `progress.txt`.

**Run it in a container.** Every call passes `--dangerously-skip-permissions`. `run.sh` is the container wrapper; bypass mode refuses to run as root, which is why it passes `--user`.

## Files

| File | What it is |
|---|---|
| `loop.sh` | The finished loop from the post, plus the fixes in `TESTING.md` (the post's fence is pending the same diff) |
| `run.sh` | `docker run` wrapper: non-root user, `--init` so `docker stop` reaches the trap, `../gate-tests` mounted read-only at `/gate/tests` |
| `features.example.json` | The `features.json` shape: Anthropic's `category`, `description`, `steps`, `passes`, plus `test`, the protected test id the gate runs |
| `test/` | bats suite, stub `claude`, vendored bats-core; see Tests |
| `TESTING.md` | What the suite proves, hypotheses H1 to H5, defects fixed |

## Usage

```bash
cp loop.sh run.sh /path/to/repo/
# write PROMPT.md and features.json, keep the gate tests in ../gate-tests
git add loop.sh run.sh features.json PROMPT.md && git commit -m "loop setup"
SPEND_CEILING=5 MAX_ITERATIONS=5 LOOP_IMAGE=<image with claude, git, jq, pytest> ./run.sh
tail -n 1 progress.txt     # the control that fired
```

Needs `claude`, `git`, `jq`, `timeout`, `awk`. Start from a clean tree: iteration 1 commits whatever is uncommitted.

## Controls

| Variable | Default | Control |
|---|---|---|
| `MAX_ITERATIONS` | 20 | Outer cap. 0 is refused, never unlimited |
| `MAX_TURNS` | 40 | `--max-turns` per call (tool turns + 1 for the final response) |
| `CALL_BUDGET` | 4.00 | `--max-budget-usd` per call |
| `SPEND_CEILING` | 40.00 | Sum of `total_cost_usd` across the run, kept in the wrapper's memory; `.loop/spend.log` is the record. A call that reports no cost is charged `CALL_BUDGET` |
| `ITER_TIMEOUT` | 45m | Wall clock per call (`timeout`, then `KILL` 5s later if the call ignores `TERM`) |
| `NO_PROGRESS_LIMIT` | 3 | Consecutive iterations whose staged diff, excluding `progress.txt` and `features.json`, is empty |
| `GATE_CMD` | `pytest -q` | Runs the `test` id of every feature marked passing; a failure restores `features.json` from the last loop checkpoint |
| `PROMPT_FILE` | `PROMPT.md` | Prompt sent on every fresh call |

The defaults are the post's starting numbers, not researched thresholds. Keep `SPEND_CEILING` below `MAX_ITERATIONS * CALL_BUDGET` so the ledger binds and the iteration cap is the backstop.

## Exits

| Exit | Printed control | Code |
|---|---|---|
| Every feature `passes` and survived the gate | `done: every feature passed the gate` | 0 |
| Ledger reached the ceiling | `SPEND_CEILING ($N)` | 1 |
| Diff unchanged N times in a row | `no-progress breaker (N unchanged diffs)` | 1 |
| Ran out of iterations | `MAX_ITERATIONS (N)` | 1 |
| SIGINT, SIGTERM, SIGHUP | note in `progress.txt`, partial work committed as `loop: iteration N interrupted` | 130 |
| Missing binary, `MAX_ITERATIONS=0`, `features.json` not committed, a feature without a `test` id | `loop.sh: ...` | 2 |

Not exits, but logged to `progress.txt` and the loop continues: a nonzero `claude` exit with its `subtype` (for example `error_max_turns`), an `ITER_TIMEOUT` hit, a call that reported no cost (charged `CALL_BUDGET`), an edit to `features.json` beyond `.passes` (restored from the last loop checkpoint), and a gate rejection (log in `.loop/logs/gate-N.log`).

The checkpoint is the tree the wrapper last checked: `HEAD` at start, then each `loop: iteration N` commit. Commits the agent makes itself never move it, so an agent that commits its own flip still faces the gate.

## Read the output with these caveats

- **Spend is an estimate.** `total_cost_usd` is a client-side estimate, and a session crash can zero it. The Usage page is the bill; the wrapper's sum is the brake. A call with no readable cost (timeout, crash, malformed output) is charged `CALL_BUDGET`, not zero.
- **Spend overshoots.** `--max-budget-usd` is checked after each response, and the ceiling is checked after each call, so a run can pass both by up to one call's cost. The wrapper does not cap a single call; that bound is `claude`'s own.
- **The gate is only as good as its tests.** Read-only tests stop test edits, not special-casing. Somebody still reads the diff.
- **No `--resume`.** The ledger is a plain sum because every call is fresh. Resumed sessions report cumulative totals and would double-count.
- **The breaker is a heuristic.** Keying it on the diff is the post's author's application of an offline stall definition, not a measured result.
- `set -uo pipefail` omits `-e` on purpose: the loop branches on failures and must not die on the first one.
- `GATE_CMD` and the test ids are word-split, so the loop refuses a test id with spaces. An empty `features.json` array counts as done.
- **The wrapper shares a user and a filesystem with the agent.** The agent can rewrite `PROMPT.md`, `loop.sh`, `.git/hooks` and `.loop/logs`, or leave a background process behind. `TESTING.md` (H5) lists what each one does.

## Tests

```bash
test/check.sh                  # shellcheck, then all bats tests (about 35s, no API calls, no Docker)
test/check.sh --filter H5      # one group; any bats flag passes through
LOOP_SH=/path/to/loop.sh test/bats/bin/bats test/   # run the suite against another loop.sh
```

Needs `shellcheck`, `git`, `jq`, GNU `timeout` and `env` (coreutils 8.31+). bats-core 1.11.1 is vendored in `test/bats`. A stub `claude` in `test/stub` stands in for the CLI; `setup` refuses to run if any other `claude` resolves first. Each test builds a fresh temp git repo and a `chmod a-w` gate dir, and deletes both after.

## Grounding

Post: [Loop Engineering Examples: Harden One Loop, Control by Control](https://jyoung.dev/blog/loop-engineering-practical-guide/). Facts the script relies on, all cited there:

- `--max-turns` is "No limit by default"; the Agent SDK lists max turns and max budget as "No limit" (Anthropic CLI reference; How the agent loop works).
- Budget is checked after responses arrive and "Spend can pass the cap, so leave headroom"; bypass mode "Can't be used when running as root on Unix" (same sources).
- `claude -p` exits 0 on success and non-zero on failure; `--output-format json` carries `total_cost_usd` (Anthropic: Run Claude Code programmatically).
- Sum independent calls yourself; resumed results already include earlier spend; cost fields are estimates a crash can zero (Anthropic: Track cost and usage).
- JSON feature list with `passes`, chosen because the model is less likely to overwrite JSON (Young: Effective harnesses for long-running agents).
- Session-limit kills hit the host wrapper and left no progress note (rpbaptist issue #119).
- Claude models cheat mainly by modifying tests; read-only or hidden tests recommended (Zhong et al.: ImpossibleBench).
- Stalls are test reruns without patch updates (Hu et al.); frankbria's runner opens its breaker after 3 loops with no file changes.
