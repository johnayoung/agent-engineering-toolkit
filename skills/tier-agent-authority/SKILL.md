---
name: tier-agent-authority
description: Classify every action an AI agent can take into four authority tiers — auto-execute, bounded, human-approve, deny-by-default — by reversibility and blast radius, then match each tier to the control it earns. Use before granting an agent new production authority, when reviewing a Claude Code permission allow list, when post-morteming an agent incident (name the credential before the model), or when deciding whether a workflow has earned promotion off a human-approval gate. Produces an authority report and a graduation ledger; edits nothing unless asked.
---

# Tier Agent Authority

A prompt is a probabilistic control with a non-zero miss rate; the boundary that holds is what the agent is *able* to reach — scoped tokens, permission rules, egress limits. This skill runs every action an agent can take down a four-tier table (reversibility x blast radius) and reports where the current control is looser than the tier's default. Full argument: https://jyoung.dev/blog/agent-permission-tiering/

This skill produces a report. It does not edit settings files or revoke anything unless the user explicitly asks after reading the report.

## Step 1 — Mechanical scan of the harness rules

Run the bundled script against the target repo (default: current directory):

```bash
scripts/tier-permission-rules.sh [target-dir]
```

It reads the Claude Code permission rules (project `settings.json`, `settings.local.json`, user-global settings), classifies each rule into a tier by command-prefix heuristic, and flags every rule holding a control looser than its tier's default: critical-tier actions in the allow list (the PocketOS shape), high-tier actions auto-executing, critical actions behind a decaying human gate, unscoped shells, and rules it cannot classify. REVIEW is never assumed safe — an unnamed need is a scoping gap, not a reason to grant.

## Step 2 — Inventory the ambient credentials

The rules are not the whole reach. The PocketOS deletion ran on a Railway CLI token with blanket API permissions — an ambient credential no permission-rule scan sees. For each credential the agent's commands would inherit, ask "what could this credential do?" before "why would the model do it?":

- **Where to look:** environment variables, `~/.aws/`, `~/.config/gh/`, `~/.kube/`, `~/.npmrc`, `~/.docker/config.json`, `.mcp.json` server configs, CI secrets the agent's jobs mount.
- **What to record per credential:** the operations it permits, the environments it reaches, the resources it touches, and whether backups/undo live inside the same grant.
- **The finding:** any credential that can do more than the task it was created for. Scope by operation, environment, and resource — a token not scoped that way is effectively root for whatever holds it.

## Step 3 — Classify every action down the table

Assign each rule, command, and credential-permitted operation exactly one tier:

| Tier | What lands here | Default control | Worked classification |
| --- | --- | --- | --- |
| **Low — auto-execute** | Reversible reads, no side effects | Run without a gate; log it | Reading a config file, listing endpoints, running a test suite |
| **Medium — bounded** | Reversible writes, contained blast radius | Auto-execute inside a hard scope (env, path, quota) | Editing a source file in a sandbox, opening a PR, writing to a staging table |
| **High — human-approve** | Hard-to-reverse writes, wide blast radius | Human confirmation before execution | A production schema migration, a config change that ships to all users |
| **Critical — deny-by-default** | Irreversible, catastrophic blast radius | No standing grant; separate out-of-band authorization | Deleting a production volume, dropping a database, revoking backups |

Classify the script's REVIEW rows by hand here. When in doubt between two tiers, take the higher one: roughly one benign agent run in five reaches past its scope (19.51% across 10,000 benign runs), and an agent uses the grant it is given — humans ignore 96% of their permissions; agents won't.

## Step 4 — Emit the authority report

One row per action, in a markdown table:

```
| Action / rule / credential | Reversibility | Blast radius | Tier | Current control | Tier's default | Verdict |
```

Verdicts:

- current control matches the tier -> **keep**
- medium-tier action without a hard scope -> **tighten** (add the env/path/prefix boundary)
- high-tier action auto-executing -> **gate** (human confirmation — and note it as a stage, not a destination)
- critical-tier action with any standing grant, gated or not -> **deny-by-default** (remove the standing grant; require a separate out-of-band authorization per use)
- unclassifiable -> **review** (do not grant until named)

Wait for the user before changing any settings file or credential.

## Step 5 — Propose the graduation ledger

A standing human gate decays: approval rates rise, scrutiny falls (30.1% -> 36.8% approval, +3.5x latency, -22% comments in the habituation study; 93% of Claude Code permission prompts get approved). So for every gated workflow, and for every "keep" the user wants loosened, record how it graduates — on evidence, not a vibe.

> The promote/revoke rule below is the post author's synthesis (from Monte Carlo's earned-trust premise and MindStudio's observed-performance thresholds); no single source states it as one procedure.

```
| Workflow / rule | Current tier | Clean runs required | Override bar | Window | Runs so far | Status |
```

- **Promote one tier** after N clean runs (MindStudio's observed range: 100–500 instances) with an override rate below the bar, inside a fixed window.
- **Revoke immediately** on regression — a bad execution, a rising override rate, a near-miss sends it back one tier.
- **Never promote more than one tier at a time, never on day one.** A new workflow starts at the tier its risk earns.
- **The critical row never graduates on run count alone** — separate out-of-band authorization every time.

## Grounding

Canonical post: https://jyoung.dev/blog/agent-permission-tiering/ — this skill mechanizes its closing decision table. Documented facts the report relies on: the PocketOS/Railway incident mechanics — an over-broad CLI token, no RBAC, no confirmation step (Zenity; ACS Information Age); "any probabilistic defense has a non-zero miss rate" and supervise-what-it-can-do containment (Anthropic); 19.51% of 10,000 benign runs trigger overeager behavior (SNARE, arXiv 2605.28122); humans ignore 96% of their permissions (Oso); gate decay — 30.1%->36.8% approval, +3.5x latency, -22% comments (arXiv 2606.22721) and 93% prompt approval (Anthropic auto mode); 100–500 clean instances as a graduation threshold (MindStudio); permission boundaries and user confirmation (AWS GENSEC05-BP01). The tier table synthesizes Galileo's proportional-control tiers with KLA's task/time/context scoping; the graduation rule is marked as author's judgment in the post.
