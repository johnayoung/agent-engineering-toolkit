# session-memory-budget

How many Claude Code sessions fit on one machine. It walks every running `claude` process tree, measures it in PSS, shows what the MCP servers cost, and divides:

```text
max parallel sessions = (ceiling - headroom) / peak tree PSS per session
```

Read-only: nothing is killed, launched, or edited. Linux and WSL only, because PSS comes from `/proc/<pid>/smaps_rollup`; macOS has neither PSS nor cgroups.

## Usage

```bash
./session-memory-budget.sh                                  # one sample of every session
./session-memory-budget.sh --samples 12 --interval 300      # an hour at the post's 5-minute cadence, keeps each peak
./session-memory-budget.sh --pid 11645                      # one session only
./session-memory-budget.sh --fence 6G                       # also print the count if every session hits MemoryMax=6G
./session-memory-budget.sh --ceiling 8G --per-session 659 --fence 3G   # calculator mode, e.g. a private CI runner
```

| Option | Default |
|---|---|
| `--samples N`, `--interval SECS` | 1 sample; 300 s between samples |
| `--ceiling SIZE` | lowest cgroup `memory.max` above the sessions, else `MemTotal` (on WSL2, the VM size `.wslconfig` sets) |
| `--headroom PCT` | 25 |
| `--per-session SIZE` | worst tree PSS seen, or a session scope's `memory.peak` if higher |
| `--fence SIZE` | `memory.max` of the sessions' own scopes, if they have one |

SIZE is MB, or takes a K/M/G suffix. Exit 0 ok, 1 no sessions found, 2 usage or environment error.

## What it reports

- **Per session:** process count, teammates, PSS of `claude` (plus teammates) against MCP children, MCP share, npm exec wrappers, tree RSS, tree PSS, and the peak across samples.
- **RSS vs PSS:** how far summed RSS overstates the footprint on your host.
- **Per server:** instances across sessions, flagged `DUPLICATED` when a stdio server runs once per session, and the PSS held by `npm exec` wrappers that do no MCP work.
- **Own cgroup:** when a session runs alone in a scope (`systemd-run --user --scope`), its `memory.peak` and `memory.max`. The kernel keeps that peak even while you are not sampling.
- **Sizing:** ceiling, headroom, usable, per session, the on-paper count, and the fenced count.

## How it classifies

- A session root is a `claude` process whose parent is not `claude`. A `claude` under another `claude` is a teammate and counts in its lead's tree. A `claude` launched from a tool shell is reported as its own session, not double-counted.
- Children of `claude` that are shells (`bash`, `sh`, ...) or Bash-tool snapshots count as tool load: in the tree total, not in MCP.
- Every other child subtree counts as MCP. Language servers, plugins, and other helpers land there too, so treat MCP% as an upper bound.
- Server names come from the launch line (`npm exec @playwright/mcp@latest` becomes `@playwright/mcp`; a binary keeps its basename).
- The script excludes its own process tree.

## Caveats it prints, and why

- **One sample is a floor.** The post's 20-minute log showed flat trees; the issue tracker shows sessions growing to 7.6 GiB and 12.6 GB. Sample longer, or fence each session and read `memory.peak`.
- **Headroom is judgment.** The 25% default is the post author's rule, not a sourced number.
- **No fence means shared fate.** Without a per-session cgroup, one runaway session can take the host down.
- **PSS needs readable `/proc`.** Processes you cannot read (another user's) are counted but not measured, and the report says how many.

## Grounding

Operationalizes the Max-Sessions Sizing Table in [Claude Code Memory Usage: How Many Sessions Fit on One Machine](https://jyoung.dev/blog/claude-code-parallel-sessions-memory/). Facts it relies on, all cited there:

- Stdio MCP servers run as local subprocesses of each client, so N sessions times M servers is the process count (Claude Code MCP docs, MCP transports spec, issues #28860, #45880, #99831).
- PSS divides each shared page among the processes sharing it, and `smaps_rollup` sums a process's mappings (Linux kernel `/proc` docs). Summed RSS overstates; VSZ and VmPeak are address space, not memory (#11315).
- `memory.peak` is the max usage recorded for a cgroup and its descendants; `memory.max` is the hard limit (cgroup v2 docs).
- npx-launched servers carry a resident `npm exec` wrapper process (#28860, Shyam Verma's readybytes write-up, and the post's own process counts).
- Teammates are full sessions that load their own MCP servers (Claude Code agent teams docs).
- The WSL2 VM gets 50% of Windows memory unless `.wslconfig` sets `memory=` (Microsoft Learn WSL config).
- Long sessions have grown to 7.6 GiB and 12.6 GB (#18011, #4953), which is why a single sample is reported as a floor.
- The 25% headroom is the author's judgment, as the post labels it.
