# cost-guardrail-checklist

Pre-ship checklist for agent spend controls: seven layers, each requiring both an attribution dimension (which task spent) and an enforcement ceiling (what refuses the next call). Copy `checklist.md` into the design review or PR description of any service that runs agent loops against a paid LLM API.

## Usage

1. Copy `checklist.md` into the PR/design doc.
2. Walk the layers in order — attribution (1-4) before enforcement (5-7), because a ceiling needs a key to scope to.
3. An unchecked enforcement box is a decision the org has not made yet, not a tooling gap to wait out. Ship anyway and you are shipping unbounded spend.

The LiteLLM snippet in layer 7 is one verified implementation of the per-session ceiling, not a requirement — any proxy that fails over-budget requests pre-admission satisfies layers 6-7.

## Grounding

This checklist operationalizes the closing decision table of [You Can't Cap What You Can't Attribute: Per-Task Cost](https://jyoung.dev/blog/per-task-cost-attribution/). Documented facts it relies on:

- Anthropic Analytics API values "can be revised for up to 30 days" and report per-user/per-org, never per-request (Anthropic, Analytics APIs).
- `agent.name`/`skill.name`/`plugin.name`, `user.email`, and the `prompt.id` correlation key are Claude Code OTel telemetry attributes; export is opt-in via `CLAUDE_CODE_ENABLE_TELEMETRY` (Anthropic, Monitoring — verified 2026-07-13).
- Cloud tags do not propagate to LLM API calls (LeanOps Technologies, FinOps for AI Workloads in 2026).
- Autonomous task length doubles roughly every 7 months (METR, Measuring AI Ability to Complete Long Tasks; arXiv 2503.14499).
- Provider caps operate at key/account level and cannot isolate a runaway session (Waxell, The $400M AI FinOps Gap).
- LiteLLM validates spend before admitting a request; over-budget requests fail. `max_iterations` / `max_budget_per_session` / `require_trace_id_on_calls_by_agent` syntax verified against docs.litellm.ai 2026-07-13.

Full source list with quotes: the References section of the post above.
