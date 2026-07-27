# harness-audit

Runnable version of the seven questions that close [Audit Your Agent Harness: The Deterministic Layer Nobody Reviews](https://jyoung.dev/blog/agent-harness-audit/). It walks a repo plus your user-scope config and prints the seven answers you should be able to give about the software that decides whether the agent's next `rm -rf ./build` runs. Bash + jq, no other dependencies.

**Read-only.** It opens configuration files and prints what it finds. It writes nothing, fixes nothing, and reformats nothing — including the settings that look wrong.

**It does not grade.** There is no score, no threshold, and no recommended number of hooks, permission rules, or MCP servers, because the post makes no claim about what a good number is. Every line is one of three things:

- `DEFAULT` — the key is not set at any scope. Somebody else picked the behavior.
- `SET` — somebody configured it. The value and its scope are printed.
- `UNDETERMINED` — not answerable from disk. Scopes disagree, the value lives outside the files, or answering would require executing something.

The undetermined list is the output that matters. The post's closing line is the script's: "The one question you can't answer is your finding."

## Usage

```bash
./harness-audit.sh                    # current directory
./harness-audit.sh /path/to/repo
```

Scopes read: `/etc/claude-code/managed-settings.json`, macOS managed settings, `~/.claude/settings.json`, `<repo>/.claude/settings.json`, `<repo>/.claude/settings.local.json`. Also `<repo>/.mcp.json`, `~/.claude.json` (server names only), `<repo>/.cursor/hooks.json` when present, and any hook script the settings point at.

## What it reports, question by question

| Question | What the script answers | What it cannot |
| --- | --- | --- |
| 1. Name the software that decides | Permission rule counts and `defaultMode` per scope; every rule naming `rm`/`rmdir` with its list and scope; MCP servers declared | Whether a given rule actually matches a given command — a specifier is compared against the command string |
| 2. Where each check physically executes | The three buckets: `CLAUDE.md`/`AGENTS.md` files (context), rules and hooks (runtime), sandbox (kernel) | Nested per-directory context files, skills, and plugin-supplied controls |
| 3. Can the sandbox quietly not exist | `sandbox.enabled`, `failIfUnavailable`, `allowUnsandboxedCommands`, `excludedCommands` per scope, plus any other `sandbox.*` keys listed but not interpreted | The unset default for `enabled` — sandbox behavior is version-gated, so the script refuses to assert it |
| 4. Hooks that fail open | Every registered hook: event, matcher, type, resolved script, and the count of `exit 1` / `exit 2` in it; `type: prompt`/`agent` flagged as inferential; Cursor scripts without `failClosed: true` | Which of the 30 documented events block on exit 2 (14 do, 15 do not) — the count is documented, the per-event mapping is not asserted here |
| 5. The decision record | `CLAUDE_CODE_ENABLE_TELEMETRY` and `OTEL_LOG_TOOL_DETAILS` in this shell, in each settings `env` block, and named in your shell rc files | Whether a `claude_code.tool_decision` event reaches a collector |
| 6. The version you audited | `claude --version`, stamped so the run has a baseline | Changelog diffs — the script fetches nothing |
| 7. What this buys | Prints the framing to say out loud before anyone starts | Nothing to check; it is a sentence, not a gate |

## Reading the hook section correctly

Registered hooks are an inventory of interception points, not evidence that a policy holds. The script says so on every run, because inverting that is the post's central correction:

- Claude Code "treats exit code 1 as a non-blocking error and proceeds with the action." A hook script that crashes exits non-zero and non-2, so the action goes through.
- The same reference redirects you off the layer: "use the permission system rather than a hook to enforce a hard allow or deny."
- Codex: "Treat tool hooks as a useful guardrail, not a complete enforcement boundary."
- Cursor's `failClosed` reverses the fail-open default and ships set to `false`, described by the vendor as "Useful for security-critical hooks."

A hook with `exit 2` in it is not thereby an enforcement boundary. It is a hook that can block when it runs and does not crash first.

## Grounding

Canonical post: https://jyoung.dev/blog/agent-harness-audit/

Documented facts this script relies on, all vendor reference documentation rather than inference:

- Unmatched commands default to requiring manual approval ("Fail-closed matching") — Claude Code Docs: Security.
- Exit code 2 blocks for most hook events, exit code 1 is a non-blocking error and the action proceeds, `WorktreeCreate` aborts on any non-zero exit, and the docs redirect hard allow/deny to the permission system — Claude Code Docs: Hooks Reference (30 documented events; 14 can block on exit 2, 15 cannot).
- Prompt-based and agent-based hooks "use a Claude model to evaluate conditions" — Claude Code Docs: Automate Actions with Hooks. Hence the inferential-control flag on any non-`command` hook type.
- Fail-open hook default and the `failClosed` per-script override defaulting to `false` — Cursor Docs: Hooks.
- "Treat tool hooks as a useful guardrail, not a complete enforcement boundary" — OpenAI Codex Docs: Hooks.
- Unsandboxed fallback when the sandbox cannot start, the `dangerouslyDisableSandbox` retry, `excludedCommands` having no managed-only lockdown, Read/Edit/Write bypassing the sandbox, "not a complete isolation boundary," and version-gated behavior notes at seven point releases between v2.1.187 and v2.1.218 — Claude Code Docs: Sandboxing.
- Telemetry off until `CLAUDE_CODE_ENABLE_TELEMETRY` is set, `tool_parameters` gated behind `OTEL_LOG_TOOL_DETAILS=1`, the `tool_decision` `source` enum, and "The event doesn't indicate which of these sources matched" — Claude Code Docs: Monitoring.
- `gen_ai.tool.name` Required while `gen_ai.tool.call.arguments` is Opt-In — OpenTelemetry GenAI spans.
- 57.9% epistemic against 9.4% environment across 1,794 annotated trajectories — Zhao et al., "Failure as a Process" (arXiv 2607.09510). Printed under question 7 to keep the claim as leverage, not causation.

Everything the script cannot source, it marks `UNDETERMINED` instead of guessing.

## Related

`skills/tier-agent-authority/` answers a different question: which authority tier a task class deserves. This one reports what the harness enforces today, at whatever tier you assigned.
