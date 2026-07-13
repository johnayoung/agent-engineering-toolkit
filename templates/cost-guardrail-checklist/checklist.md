<!--
  Agent cost guardrail checklist.
  Paste into the design review / PR description of any service that runs
  agent loops against a paid LLM API. Full argument:
  https://jyoung.dev/blog/per-task-cost-attribution/
-->

# Agent cost guardrails — pre-ship checklist

Every layer needs two things: the **attribution dimension** (can you name which task spent?) and the **enforcement ceiling** (does something refuse the next call?). A layer with the dimension but no ceiling is a dashboard, not a guardrail.

## 1. Control lives upstream of the dashboard

- [ ] No alert wired to the provider's cost dashboard is counted as a spend control. Anthropic's own analytics revise a given day's values for up to 30 days, and report per-user/per-org — never per-request.
- [ ] Every control checked below fires before a request is admitted, not after the invoice.

## 2. Attribution dimensions committed as a schema, on the call

- [ ] Dimensions are stamped on the API call itself, not on the infrastructure making it. Cloud tags do not propagate to LLM API calls — a tag on the instance cannot see inside the token bill.
- [ ] The "what" is emitted per call: `agent.name`, `skill.name`, `plugin.name` (Claude Code OTel attributes; map to equivalents on other stacks).
- [ ] The "who" is emitted per call: `user.email` (included when authenticated via OAuth) or your stack's equivalent.
- [ ] Telemetry export is actually on — it is opt-in (`CLAUDE_CODE_ENABLE_TELEMETRY=1` plus `OTEL_*` exporter config for Claude Code).
- [ ] Cardinality was reviewed: every custom dimension becomes a label on every metric series. Only dimensions a ceiling will key on made the cut.

      Where the schema lives (settings file / proxy config): __________

## 3. The per-task key is the prompt, not the user

- [ ] `prompt.id` (or your stack's per-task correlation id) is the attribution key. One prompt fans out into many `api_request` and `tool_result` events; user-level totals cannot tell one runaway task from forty healthy ones.
- [ ] Verified: filtering events by one `prompt.id` returns the full fanout for that task.

## 4. The ceiling assumes per-task cost grows

- [ ] Per-task cost is tracked as a trend, not a point. Autonomous task length has doubled roughly every 7 months for six years (METR); longer runs mean more calls under the same `prompt.id`.
- [ ] The ceiling is set against a projected worst case, not last quarter's mean, and has a review date: __________

## 5. Enforcement is scoped below the account

- [ ] The provider's account- or key-level cap is not the guardrail of record. It cannot distinguish a single runaway session from many well-behaved sessions on the same key.
- [ ] A cap exists on the object that actually runs away: the session.

## 6. A pre-admission budget check sits in the call path

- [ ] A budget check reads current spend and **fails** the over-budget request before it is admitted — no API call is made. (LiteLLM proxy: over-budget requests fail; they do not warn.)
- [ ] The check keys on the schema from layer 2 (key, team, user, tag), so there is something to enforce against.

## 7. The ceiling is per session, with two counters

- [ ] Dollar cap per session is set (`max_budget_per_session` in LiteLLM agent `litellm_params`).
- [ ] Iteration cap per session is set (`max_iterations`) — the dollar cap catches a few expensive calls; the iteration cap catches a tight loop of cheap ones.
- [ ] Session identity flows on every call: `x-litellm-trace-id` header or `metadata.session_id`, enforced with `require_trace_id_on_calls_by_agent: true` (without it the counters have nothing to increment on).

      Worst case per task: $ ________ or ________ calls, whichever hits first.

### Reference: per-session ceiling in LiteLLM

Syntax verified against the LiteLLM docs (a2a_iteration_budgets), 2026-07-13. Breach returns `429 Too Many Requests`; iteration counters expire after 1 hour by default (`LITELLM_MAX_ITERATIONS_TTL`).

    curl -X POST 'http://localhost:4000/v1/agents' \
      -H 'Authorization: Bearer sk-1234' \
      -H 'Content-Type: application/json' \
      -d '{
        "agent_name": "my-agent",
        "agent_card_params": { "name": "my-agent", "url": "http://my-agent:8080", "version": "1.0.0" },
        "litellm_params": {
          "require_trace_id_on_calls_by_agent": true,
          "max_iterations": 50,
          "max_budget_per_session": 5.00
        }
      }'

## Sign-off

Attribution (layers 1-4) is table stakes; enforcement (layers 5-7) is the org decision. Signing off below means the decision was made — not that a dashboard exists.

Enforcement owner: __________  Date: __________
