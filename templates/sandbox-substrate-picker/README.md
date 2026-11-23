# sandbox-substrate-picker

Calculator for [A Sandbox for AI Coding Agents at Scale Is a Warm-State Problem](https://jyoung.dev/blog/sandbox-parallel-coding-agents/). It walks your fleet through the post's six questions in its order and prints the control each yes adds. Then it prices one session-hour and the whole run per vendor plan at your real concurrency, and flags every plan whose cap binds. Bash, jq, awk.

**Estimates, not quotes.** Rates are published list prices fetched 2026-11-23 (`rates.json`). Disk, plan fees, credits, transfer, Cloudflare Workers and Durable Objects, and AWS snapshot charges are excluded. Nothing is launched or billed.

## Usage

```bash
# 1. Time setup inside a fresh sandbox on each candidate (clone, install, warm build)
./time-setup.sh https://github.com/acme/mono.git \
  --install 'pnpm install --frozen-lockfile' \
  --build 'pnpm --filter "./packages/**" build' --sessions 50

# 2. Route and price (the post's dep-upgrade example)
./sandbox-substrate-picker.sh --sessions 50 --trust unattended \
  --vcpu 2 --gib 4 --hours 8 --setup-min 3.5 --setup-budget 60 \
  --shared-deps yes --network yes

# Interactive fleet: up 8 h, working 2.5 h
./sandbox-substrate-picker.sh --sessions 100 --trust untrusted --active-hours 2.5

# Your own dated rates
cp rates.json my-rates.json   # edit, change "fetched"
./sandbox-substrate-picker.sh --sessions 50 --trust unattended --rates my-rates.json
```

| Exit | `sandbox-substrate-picker.sh` | `time-setup.sh` |
|---|---|---|
| 0 | report printed | setup timed |
| 1 | | a step failed (partial time is not reported as setup) |
| 2 | usage or rates-file error | usage error |

## What it answers

| Question (post order) | Input | Yes adds |
|---|---|---|
| 1. Setup dominates time to first action? | `--setup-min`, `--boot-sec` | Defer provisioning |
| 2. Trusted sessions on one machine? | `--trust trusted --machine one` | Worktree + prebuilt devcontainer. **Stop**, no pricing |
| 3. Unattended or untrusted input? | `--trust` | Per-session kernel; audit pin, default runtime, egress default, overhead |
| 4. Setup over budget at your session count? | `--setup-min` x `--sessions` vs `--setup-budget` | Warm snapshot, fork, re-mint identity after restore |
| 5. Sessions share dependencies? | `--shared-deps` | Read-only shared layer + private writable layer |
| 6. Credentials or network? | `--network` | Credential proxy outside the sandbox, default-deny egress |

Unanswered questions print as `unanswered` with the flag that answers them; they never default to yes or no.

Pricing columns: `$/sess-h` at your size; `Run, up` bills every hour a session is up; `Run, active` bills active hours only, which is the real bill only if the sandbox stops billing while it waits. `Runs at once` is concurrent sessions at your size: a session count for E2B and Modal, a pooled vCPU and GiB quota for Daytona and Cloudflare. Binding plans show the queue, waves and stretched wall time.

## What it does not do

- **Rate vendor isolation.** Question 3 applies to whichever vendor you pick; the tool does not say which are microVM, gVisor or container.
- **Price AWS Lambda MicroVM concurrency.** No default quota is published; the row shows `?`. AWS unit prices are the ones in AWS's own worked examples (US East, Graviton, per GB).
- **Model suspend or resume costs.** `Run, active` assumes idle time bills nothing.
- **Measure a cold sandbox from your laptop.** `time-setup.sh` measures wherever it runs; run it inside each candidate.
- **Model Cloudflare instance types.** Memory bills on the provisioned instance type; round your `--gib` up to one.

## Grounding

Canonical post: [A Sandbox for AI Coding Agents at Scale Is a Warm-State Problem](https://jyoung.dev/blog/sandbox-parallel-coding-agents/). The six-question order and the per-session-hour arithmetic are the author's judgment in the post, not a sourced standard.

- Boot default 0.125 s: InstanceStart to guest `/sbin/init` at `<= 125 ms` ([Firecracker: Specification](https://github.com/firecracker-microvm/firecracker/blob/main/SPECIFICATION.md)).
- Setup, not boot: 3.5 of 6 minutes went to worker setup ([BuildBuddy: Snapshot, Chunk, Clone](https://www.buildbuddy.io/blog/fast-runners-at-scale/)).
- Re-mint after restore: resuming one snapshot more than once is "insecure" without a uniqueness mechanism ([Firecracker: Snapshotting](https://github.com/firecracker-microvm/firecracker/blob/main/docs/snapshotting/snapshot-support.md)); generate unique content after start, in `/run` ([AWS: Working with snapshots](https://docs.aws.amazon.com/lambda/latest/dg/microvms-images-snapshots.html)).
- Read-only cache: "Poisoned caches can lead to code execution in trusted workflows" ([GitHub Docs: Dependency caching](https://docs.github.com/en/actions/concepts/workflows-and-actions/dependency-caching)).
- Allowlist as capability grant ([Anthropic: How we contain Claude](https://www.anthropic.com/engineering/how-we-contain-claude)).
- Rates and caps, fetched 2026-11-23:
  - E2B $0.000014/vCPU-s, $0.0000045/GiB-s; Hobby 10 concurrent and 1 h sessions, Pro 100 and 24 h ([E2B: Pricing](https://e2b.dev/pricing)).
  - Daytona $0.0504/vCPU-h, $0.0162/GiB-h ([Daytona: Pricing](https://www.daytona.io/pricing)); pooled quota, Tier 1 10 vCPU / 20 GiB ([Daytona: Limits](https://www.daytona.io/docs/en/limits/)). The page also lists Tier 1 at 10 GiB elsewhere.
  - Cloudflare $0.000020/active vCPU-s, $0.0000025/provisioned GiB-s ([Cloudflare: Containers pricing](https://developers.cloudflare.com/containers/pricing/)); 15,000 vCPU and 60 TiB account defaults, 4 vCPU / 12 GiB per instance ([Cloudflare: Containers limits](https://developers.cloudflare.com/containers/platform-details/limits/)).
  - Modal sandboxes at 3x list: $0.00003942/core-s (1 core = 2 vCPU), $0.00000667/GiB-s; Starter 100 containers, Team 5,000 ([Modal: Pricing](https://modal.com/pricing)).
  - AWS Lambda MicroVMs $0.0000276944/vCPU-s, $0.0000036667/GB-s as used in AWS's worked examples; coding-assistant example $12.41 per developer-month ([AWS: Lambda pricing](https://aws.amazon.com/lambda/pricing/)).
