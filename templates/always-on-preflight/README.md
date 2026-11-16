# always-on-preflight

Static preflight for a coding agent that runs with nobody in the session: a GitHub Actions workflow that fires an agent on `schedule` or repo events, plus Claude Managed Agents scheduled-deployment frontmatter. It checks the lines [Always-On Agents: What Breaks When Nobody Is in the Session](https://jyoung.dev/blog/always-on-agents/) fixes in its 2 AM triage agent, then prints the post's standing-agent table filled in for each workflow. `checklist.md` covers the rows a static read cannot answer. Bash, awk, grep; git optional.

**Read-only.** It reads workflow files and git history. It edits nothing.

## Usage

```bash
./always-on-preflight.sh                          # cwd: .github/workflows/*.y{a,}ml + deployment files
./always-on-preflight.sh --repo /path/to/repo
./always-on-preflight.sh --deployment agents/triage/deployment.md .github/workflows/triage.yml
./always-on-preflight.sh --agent 'anthropics/claude-code-action|my-org/agent-action' --no-table
```

| Exit | Meaning |
|---|---|
| 0 | no FAIL |
| 1 | at least one FAIL |
| 2 | usage error |

Statuses: `FAIL` is the post's "as first deployed" shape. `WARN` is a heuristic or likely gap; read the cited line. `REVIEW` is not answerable from the file. Table cells read `[open]` (a gap, or nothing visible) or `[confirm]` (the visible part passed; a person confirms the rest).

Workflows whose only triggers are `workflow_dispatch`, `workflow_call` or `repository_dispatch` are skipped: a person or a caller starts each run.

## Checks

| Row | Check | Status |
|---|---|---|
| Deduplication | No `concurrency:` on the workflow or agent job | FAIL |
| | Concurrency group keyed on `github.run_id` (one group per run) | FAIL |
| | Event triggers, write access, no dedup marker (`inbox`, `idempot`, `dedup`) in the file | WARN |
| | Cron with a declared non-UTC time zone that fires in hours 1 or 2, or at 3:00 | FAIL |
| | Scheduled-deployment file with no `timezone:` | REVIEW |
| Identity | `anthropic_api_key` or `claude_code_oauth_token` on the agent step | FAIL |
| | `github_token` from a stored secret other than `GITHUB_TOKEN` | FAIL |
| | `GH_TOKEN` / `GITHUB_TOKEN` / `GITHUB_PERSONAL_ACCESS_TOKEN` env from a stored secret in the agent job | WARN |
| | `schedule` trigger: prints the git author who last changed the cron line | REVIEW |
| Memory | Prompt tells the agent to rewrite a notes, memory or `.md` file (keyword match) | WARN |
| Approval | Prompt asks for merge, deploy, close, approve, release or publish (keyword match) | WARN |
| Watching | Alerting (Slack, PagerDuty, webhook, and similar) inside the agent's workflow | FAIL |
| | That alert gated on `failure()`: pages on a red run, a cause | WARN |
| | Alerting in another workflow in the same repo | WARN |
| | CODEOWNERS entry for the workflow file, or none | REVIEW |

## What it does not do

- **Check on-the-hour drift on GitHub Actions.** The post sources "can start several minutes late" to Claude Code scheduled tasks, which are not configured in repo files. It does not claim it for Actions.
- **Apply the DST check to GitHub Actions cron with no time zone.** Actions schedule cron runs in UTC; the 1-3 AM rule applies where a scheduler takes a local zone. A `timezone:` key on a schedule entry is checked.
- **See your inbox, run log, approval flow, or outcome page.** Those live outside the workflow. The memory and approval findings are keyword matches on the prompt text; `prompt_file` contents are not scanned.
- **Lint Kubernetes CronJobs.** Use the checklist's dedup table for them.
- **Parse all of YAML.** It reads workflow-shaped YAML; anchors, flow mappings and multi-document files are not interpreted.

## Grounding

Canonical post: [Always-On Agents: What Breaks When Nobody Is in the Session](https://jyoung.dev/blog/always-on-agents/)

- One worker per inbox: "An inbox should only have one active worker at a time" ([William Hu: Building always-on agents](https://claude.com/resources/articles/building-always-on-agents)); "Use GitHub's concurrency controls to limit parallel runs" ([Claude Code: GitHub Actions](https://code.claude.com/docs/en/github-actions)).
- DST window: spring-forward times "are not triggered," fall-back times "fire twice"; schedule outside the 1-3 AM local window or use UTC ([Claude Platform: Scheduled deployments](https://platform.claude.com/docs/en/managed-agents/scheduled-deployments)).
- Two events, two sessions: "two PR updates produce two independent sessions" ([Claude Code: Scheduled tasks](https://code.claude.com/docs/en/routines)). The GitHub-event dedup key (repo, number, action, `updated_at`) is the post's construction, not a sourced standard.
- Stored keys: "If you delete a secret, the credential it held stays valid"; OIDC federation avoids storing one; scheduled runs are attributed to whoever "last changed the workflow's `cron` schedule" ([Claude Code: GitHub Actions](https://code.claude.com/docs/en/github-actions)).
- Approval: the fired prompt "can't act as approval or consent for actions during the run" ([Claude Code: Scheduled tasks](https://code.claude.com/docs/en/routines)).
- Rewritten memory: consolidation "can fall below the no-memory baseline" ([Zhang et al.: Useful Memories Become Faulty](https://arxiv.org/abs/2605.12978)).
- Alerts within reach: the Claude GitHub App's permission set includes Workflows read and write ([Claude Code: GitHub Actions](https://code.claude.com/docs/en/github-actions)); coding agents disabled human alerts in OpenAI's internal deployments ([OpenAI: Suppressing misalignment monitoring](https://alignment.openai.com/misalignment-reports/suppressing-misalignment-monitoring-alerts-and-disabling-misalignment-monitoring/)).
- Page on symptoms, not causes ([Google SRE: Monitoring Distributed Systems](https://sre.google/sre-book/monitoring-distributed-systems/)).
- Named owner: author's judgment in the post, from OWASP's recertification guidance ([OWASP: NHI1 Improper Offboarding](https://owasp.org/www-project-non-human-identities-top-10/2025/1-improper-offboarding/)). CODEOWNERS is a reviewer on record, not proof of a paged owner.
