# harness-portability-audit

Runnable version of the portability ledger that closes [AGENTS.md vs CLAUDE.md: Swap the Agent, Keep the Harness](https://jyoung.dev/blog/switching-between-ai-coding-agents/). Run it at a repo root and it finds every coding-agent harness artifact it knows about, sorts each one into the post's two piles, and names the bridge where a vendor documents one. Bash + jq, no other dependencies.

**Read-only.** It opens files and prints what it finds. It writes nothing, fixes nothing, and does not grade. A repo that is honestly single-vendor gets a ledger that says so, not a score.

**The sort is the post's one test:** is this artifact read by name and format across Claude Code, Codex CLI, Gemini CLI and Cursor, or by one vendor's schema? Every line is one of:

- `PORTS`: read across vendors as-is (AGENTS.md, a SKILL.md within the six spec fields, an MCP server process, a plain git worktree, a dev container).
- `VENDOR-BOUND`: read by one vendor's schema (CLAUDE.md without an import, hook config, permission policy, subagent frontmatter, an MCP client file). A description, not a defect; the post's point is that this pile is where the swap costs an afternoon.
- `bridge missing`: the vendor-bound artifact has a documented flip that is not in place. These are collected in the summary.
- `UNDETERMINED`: not answerable from disk (rulesets, invalid JSON, the capability row).

## Usage

```bash
./harness-portability-audit.sh                 # current directory
./harness-portability-audit.sh /path/to/repo
```

Cross-vendor bridges (hooks, permissions, MCP declared for vendor A but not vendor B) are only flagged for vendors whose artifacts already exist in the repo. A Claude-only repo is not told to write Gemini hooks.

## What it reads, ledger row by row

| Ledger row | Files inspected | Bridge it can name |
| --- | --- | --- |
| Vendor as failure domain | `CLAUDE_CODE_USE_BEDROCK`, `ANTHROPIC_BASE_URL` in `.claude/settings*.json` `env` and the current shell | None; reports whether a second serving path is configured |
| Instruction file | `AGENTS.md`, `CLAUDE.md` (import line or symlink), `GEMINI.md`, Codex fallback names, `.cursor/rules/`, `.cursorrules`, nested copies | No `@AGENTS.md` in `CLAUDE.md`; `project_doc_fallback_filenames` unset when the instructions live under another name; `context.fileName` not listing `AGENTS.md`; `.md` files where Cursor wants `.mdc` |
| Skills | `.claude/skills/*/SKILL.md`, `.agents/skills/*/SKILL.md`, `.claude/commands/*.md` | Frontmatter keys outside `name`, `description`, `license`, `compatibility`, `metadata`, `allowed-tools`; a Claude skill with no `.agents/skills/` copy when Codex is present; slash commands with argument placeholders |
| MCP | `.mcp.json`, `.codex/config.toml` `[mcp_servers.*]`, `.gemini/settings.json` `mcpServers`, `.cursor/mcp.json` | A `.mcp.json` entry with `url` and no `type`; a server declared for one vendor and not another present in the repo |
| Hooks | `.claude/settings*.json` `hooks`, `.codex/hooks.json`, `.codex/config.toml` `[hooks]`, `.gemini/settings.json` `hooks`, `.cursor/hooks.json` | Hooks for one vendor only, with the target vendor's event vocabulary named |
| Permissions | `.claude/settings*.json` `permissions`, `.codex/config.toml` `approval_policy` and `sandbox_mode`, `.gemini/policies/*.toml`, `.cursor/cli.json` `permissions` | A policy for one vendor only; `defaultMode` set to `auto` or `bypassPermissions` in a project file, which does not take effect |
| Subagents | `.claude/agents/*.md`, `.codex/agents/*.toml`, `.gemini/agents/*.md`, `.cursor/agents/*.md` | Names the vendor-specific fields present per file; notes that Cursor reads `.claude/agents/` and `.codex/agents/` |
| Worktrees, rulesets, container | `git worktree list`, `.gemini/worktrees/`, `$CODEX_HOME/worktrees`, `.devcontainer/`, the GitHub remote | None to flip. Rulesets are not readable from disk; the `gh api` command is printed, not run |
| Capability | Nothing on disk | None; the row exists so the ledger is complete |

## Limits

- TOML is read with `grep -E '^key ='`, not parsed. Quoted table names, multi-line arrays and inline tables can be missed; the ledger says so on each TOML line.
- YAML frontmatter keys are the unindented `key:` lines between the first two `---` fences. Nested keys are not inspected.
- Hooks declared inside skill or subagent frontmatter are not counted in the hooks row.
- User-scope files (`~/.claude`, `~/.codex`, `~/.gemini`, `~/.cursor`) are not read, except to note a Codex-managed worktree directory. The post's sort is about what travels with the repo.
- "Vendors with artifacts on disk" is inferred from directories and filenames, so an empty `.cursor/` counts as Cursor present.

## Grounding

Canonical post: https://jyoung.dev/blog/switching-between-ai-coding-agents/

Documented facts this script relies on, each cited in the post:

- "Claude Code reads `CLAUDE.md`, not `AGENTS.md`," with the `@AGENTS.md` import as the recommended bridge, a symlink as the alternative that needs Administrator privileges or Developer Mode on Windows, and `/import` as a one-time copy rather than a live link. Claude Code Docs: How Claude Remembers Your Project.
- Codex checks `AGENTS.override.md`, `AGENTS.md`, `TEAM_GUIDE.md`, `.agents.md` per directory, with other names configurable through `project_doc_fallback_filenames` under a 32 KiB default cap. Codex Docs: Custom Instructions With AGENTS.md.
- Gemini CLI's `context.fileName` setting, whose documented example is `["AGENTS.md", "CONTEXT.md", "GEMINI.md"]`. Gemini CLI Docs: Provide Context With GEMINI.md Files.
- Cursor reads `AGENTS.md` in the project root and subdirectories as plain markdown, and its own project rules must use the `.mdc` extension. Cursor Docs: Rules.
- The Agent Skills spec has six frontmatter fields (`name`, `description`, `license`, `compatibility`, `metadata`, `allowed-tools`), `allowed-tools` is experimental with support that "may vary between agent implementations," and `metadata` is the sanctioned place for non-spec data. Agent Skills: Specification.
- Anthropic's own packaging path fails on extra keys with `Unexpected key(s) in SKILL.md frontmatter`. Claude Code Docs: Extend Claude With Skills. The docs never say third-party agents reject extra fields, and neither does this script.
- Codex reads repo skills from `.agents/skills`, and its import maps slash commands to skills while listing "prompts dependent on arguments or file-path placeholders" for review. Codex Docs: Customization; Codex Docs: Import From Another Agent.
- "A JSON entry that has a `url` but no `type` is a configuration error, because Claude Code reads an entry with no `type` as a stdio server." Claude Code Docs: MCP. Codex uses `[mcp_servers.<server-name>]` in `config.toml` for trusted projects only; Gemini's `trust` option "bypasses all confirmation dialogs"; Cursor wants `.cursor/mcp.json`. Codex Docs: Model Context Protocol; Gemini CLI Docs: MCP Servers; Cursor Docs: MCP.
- Hook config locations and event vocabularies per vendor, with exit 2 as the blocking convention in all four and Cursor the only vendor stating compatibility in writing. Claude Code Docs: Hooks Reference; Codex Docs: Hooks Reference; Gemini CLI Docs: Hooks Reference; Cursor Docs: Agent Hooks.
- `auto` and `bypassPermissions` set in `.claude/settings.json` do not take effect. Claude Code Docs: Choose a Permission Mode. Codex crosses `approval_policy` with `sandbox_mode`, where `danger-full-access` disables sandboxing entirely. Codex Docs: Advanced Configuration. Gemini's policy engine is priority-ordered TOML under `plan` < `default` < `autoEdit` < `yolo`, with the workspace tier marked currently disabled. Gemini CLI Docs: Policy Engine. Cursor's `.cursor/cli.json` rule strings, where deny beats allow. Cursor Docs: CLI Permissions.
- Subagent fields: `permissionMode`, `hooks`, `mcpServers`, `isolation: worktree` on Claude Code; `name`, `description`, `developer_instructions` required in Codex TOML; `max_turns`, `timeout_mins`, `kind` on Gemini; `readonly`, `is_background` on Cursor, which also reads `.claude/agents/` and `.codex/agents/` for compatibility and lets `.cursor/` win on a name clash. Claude Code Docs: Create Custom Subagents; Codex Docs: Subagents; Gemini CLI Docs: Subagents; Cursor Docs: Subagents.
- Plain `git worktree add` as the manual equivalent of Gemini's experimental `.gemini/worktrees/`; Codex-managed worktrees under `$CODEX_HOME/worktrees`, most recent 15 kept, scoped to the desktop app. Gemini CLI Docs: Git Worktrees; Codex Docs: Worktrees.
- A dev container "is a convention rather than an enforcement boundary," and the Bash sandbox runs commands unsandboxed with a warning unless `sandbox.failIfUnavailable` is `true`. Claude Code Docs: Choose a Sandbox Environment; Configure the Sandboxed Bash Tool.
- Context files "do not generally improve task success rates, while increasing inference cost by over 20% on average." Gloaguen et al., Evaluating AGENTS.md (arXiv 2602.11988). Printed once so the instruction-file row is not mistaken for the valuable one.
- The same model scores differently under different harnesses. Terminal-Bench 2.1. The capability row points here and checks nothing.

## Related

`templates/harness-audit/` inventories what the Claude Code harness enforces and where. This script takes that inventory and asks a different question: which of it survives a change of vendor.
