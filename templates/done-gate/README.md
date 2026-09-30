# done-gate

Runs a task's definition of done as predicates on the repo's final state, so the agent's closing message decides nothing. One predicate file, two wires: a Claude Code Stop hook that keeps the agent working (feedback), and a required CI check from a clean checkout (the gate).

The file is code. `command` and `test` entries run verbatim through `bash` from the repo root, so keep it where the agent cannot write (see [Wiring](#wiring)).

## Usage

```bash
./done-gate.sh lint .done/legacy-auth.json     # static checks, runs nothing
./done-gate.sh .done/legacy-auth.json          # run, print a report
./done-gate.sh --hook .done/legacy-auth.json   # Stop / SubagentStop hook
./done-gate.sh --ci .done/legacy-auth.json     # required status check
```

`--repo DIR` sets the repo root (default: `$CLAUDE_PROJECT_DIR` in `--hook`, else the cwd's git top level). A relative predicate path resolves against the cwd first, then the repo root, so the file can live outside the worktree.

| Mode | Pass | Fail | Input error |
|---|---|---|---|
| report, `--ci` | 0 | 1, report on stdout | 2 |
| `--hook` | 0, silent | 2, failing predicates on stderr | 2 (blocks: fails closed) |
| `lint` | 0 (warnings allowed) | 1 | 2 |

`--ci` also appends a markdown table to `$GITHUB_STEP_SUMMARY` when it is set.

## Predicate file

`example-legacy-auth.json` is the post's `.done/legacy-auth.json`, verbatim.

```json
{
  "task": "one line, printed in every report",
  "base": "origin/main",
  "predicates": [ ... ],
  "review": ["criterion", { "criterion": "new call sites are idiomatic", "reviewer": "@acme/platform-leads" }]
}
```

| Kind | Fields | Passes when |
|---|---|---|
| `command` | `run` | exits 0 |
| `test` | `name`, `run` | exits 0 |
| `file_exists` | `path` | path exists |
| `glob_count` | `glob`, `min` (default 1), `max` | match count in range (bash globstar, filesystem) |
| `file_absent` | `path` | path does not exist |
| `grep_count` | `pattern` (ERE), `glob`, `exclude`, `max` and/or `min` | matching line count in range (`git grep --untracked`, respects `.gitignore`) |
| `unchanged_since` | `glob`, `ref` (default `base`), `except` | no matching path modified, added, deleted, or untracked since the merge-base of `ref` and HEAD |

The first four are `decompose-epic`'s `check-task-graph.sh` vocabulary in the same JSON shape; a top-level `accept` (object or array) is read in place of `predicates`. `grep_count` and `unchanged_since` globs are git pathspec globs: `*` stays inside one directory, `**/` spans them. `exclude` and `except` take a string or an array.

Failing `command`, `test`, `grep_count`, and `unchanged_since` results print the last 10 lines of output, which is what the agent sees in hook mode.

Fails closed: a prose string, an unknown kind (an `llm_judge`, say), a missing field, an unresolvable ref, a non-git repo for the git kinds, and an empty `predicates` list all count as FAIL. `review` items are printed and never count toward pass.

## Lint

Runs nothing. FAIL on: prose criteria, unknown kinds, missing fields, duplicate ids, invalid `grep_count` regex, `grep_count` with no bound, `unchanged_since` with no ref, review items carrying the post's example vague qualifiers ("cleanly", "appropriately", "where reasonable"; a starting list, not a complete one), and any `command` or `test` predicate in a file with no `unchanged_since` guard. WARN on: a review item with no named reviewer, an `unchanged_since` glob that matches no tracked file, no state predicate at all.

The guard check is a heuristic. Lint cannot see which test files a command loads, so it confirms a guard exists and matches tracked files; whether its glob covers the tests the command runs is yours to confirm.

## Wiring

**Stop hook (feedback, not the gate).** It runs in the agent's workspace, from the agent's checkout. It keeps the agent working until the predicates pass; a predicate the agent cannot satisfy keeps it working until you interrupt.

```json {title=".claude/settings.json"}
{
  "hooks": {
    "Stop": [
      { "hooks": [ { "type": "command",
          "command": "\"$CLAUDE_PROJECT_DIR\"/.claude/hooks/done-gate.sh --hook .done/legacy-auth.json" } ] }
    ],
    "SubagentStop": [
      { "hooks": [ { "type": "command",
          "command": "\"$CLAUDE_PROJECT_DIR\"/.claude/hooks/done-gate.sh --hook .done/legacy-auth.json" } ] }
    ]
  }
}
```

Pair it with the post's PreToolUse deny rules on `Edit`/`Write` of `*_test.go` and `.done/*`. Those do not cover a `sed` through `Bash`, which is why the hook is not the gate.

**CI (the gate).** Take the script, the predicate file, and the tests from the base branch so the PR cannot weaken its own check, then make `done-gate` a required status check and put `.done/`, the hook, and the test paths under CODEOWNERS with "Require review from Code Owners."

```yaml {title=".github/workflows/done-gate.yml"}
name: done-gate
on: pull_request
jobs:
  done-gate:
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v4
        with: { fetch-depth: 0 }
      - uses: actions/setup-go@v5
        with: { go-version-file: go.mod }
      - name: Take the definition of done from the base branch, not the PR
        run: >
          git checkout origin/${{ github.base_ref }} --
          .claude/hooks/done-gate.sh .done/ '*_test.go' ':!internal/auth/legacy_test.go'
      - run: .claude/hooks/done-gate.sh lint .done/legacy-auth.json
      - run: .claude/hooks/done-gate.sh --ci .done/legacy-auth.json
```

Held-out tests belong in this job too, fetched from somewhere the agent's session never mounts. This script cannot check that they exist.

## What it does not do

- Decide design questions. `review` items go to a named person.
- Score transcripts. Put a judge or detector after the gate, ordering the review queue for runs that already passed.
- Know which predicates your task needs. Split the closing message into claims and write one predicate per claim.

## Grounding

Canonical post: [Your Agent's "Done" Is a Self-Report. Make It a Predicate.](https://jyoung.dev/blog/agent-done-criteria-predicates/)

- Stop hook exit code 2: "Prevents Claude from stopping, continues the conversation," with the hook's stderr as the blocking message; SubagentStop exit 2 "Prevents the subagent from stopping" ([Anthropic: Hooks Reference](https://code.claude.com/docs/en/hooks), re-verified 2026-09-30). The script does not rely on a JSON `decision` for Stop.
- Required status checks must all pass before merge ([GitHub Docs: About Protected Branches](https://docs.github.com/en/repositories/configuring-branches-and-merges-in-your-repository/managing-protected-branches/about-protected-branches)); code owners are requested on PRs touching their paths ([GitHub Docs: About Code Owners](https://docs.github.com/en/repositories/managing-your-repositorys-settings-and-features/customizing-your-repository/about-code-owners)).
- Grading the end state rather than the claim follows SWE-bench's FAIL_TO_PASS / PASS_TO_PASS rule and Terminal-Bench's "tests pass if and only if the container ends in an acceptable state," as cited in the post.
- The `unchanged_since` guard answers the fakes table: an `os.Exit(0)` harness exit ([Anthropic: From Shortcuts to Sabotage](https://www.anthropic.com/research/emergent-misalignment-reward-hacking)) and the Modify Test Cases category ([ImpossibleBench](https://arxiv.org/html/2510.20270)).
- Failing closed: rule-based checks' errors show up red and get fixed, as with the CORE-Bench grader-bug correction ([Anthropic: Demystifying Evals for AI Agents](https://www.anthropic.com/engineering/demystifying-evals-for-ai-agents)).
- Hook as feedback and CI as the gate is the author's judgment in the post, not a sourced claim.
