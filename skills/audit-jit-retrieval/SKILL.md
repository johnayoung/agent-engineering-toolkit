---
name: audit-jit-retrieval
description: Audit an agent's just-in-time retrieval surface against the five-row JIT failure ledger and report which failures are loud and which are silent. Use before shipping any agent that resolves references at runtime (file paths, IDs, stored queries, vector search, MCP tools), when an agent confidently answers from data it never actually fetched, when retrieval loop counts or costs spike, or when the wrong tool keeps getting selected. Checks that dead references raise loop-visible errors, tool descriptions route correctly, retrieval can report nothing-found, the loop has a hard cap, and the fallback never re-injects raw low-confidence payloads.
---

# Audit JIT Retrieval

JIT context retrieval does not make retrieval free — it makes retrieval late, and late retrieval fails silently unless the failure is engineered to be loud. The default behavior of a broken resolution is not an error; it is a fabrication: the model does not see the miss, so it invents the payload. Full argument and sources: https://jyoung.dev/blog/jit-context-retrieval-failure/

This skill produces a report. It does not edit any file unless the user explicitly asks for the changes after reading the report.

## Step 1 — Locate the retrieval surface

Find and note `file:line` anchors for three things:

- **Resolvers** — code that turns a pointer (file path, ticket ID, stored query, URL, embedding query) into a payload that re-enters context.
- **Tool catalog** — the tool definitions the model routes on, and how they are loaded (all upfront vs deferred/searchable).
- **The retrieval loop** — the code that decides whether to fetch again, and its exit condition.

## Step 2 — Mechanical catalog audit (ledger row 2)

Dump the tool catalog as JSON and run the bundled script:

```bash
scripts/audit-tool-catalog.sh tools.json
```

It accepts an MCP `tools/list` JSON-RPC response, `{"tools":[...]}`, or a bare `[{name, description}, ...]` array. For a stdio MCP server, this dump works (verified against a live server):

```bash
( printf '%s\n' \
    '{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2025-06-18","capabilities":{},"clientInfo":{"name":"catalog-audit","version":"0.0.0"}}}' \
    '{"jsonrpc":"2.0","method":"notifications/initialized"}' \
    '{"jsonrpc":"2.0","id":2,"method":"tools/list","params":{}}'; sleep 2 ) \
  | <server command> 2>/dev/null | jq -c 'select(.id==2)' > tools.json
```

If there is no dumpable catalog, build the array by hand from the definitions found in Step 1. The script reports catalog size against measured reference points, per-description quality flags, and name/description collisions. Its thresholds are marked heuristics — they locate descriptions to read, not grade them.

## Step 3 — Walk the ledger

For each row, collect evidence (`file:line`) and assign a verdict: **loud** (an honest, loop-visible error surfaces), **silent** (fabrication, misroute, thrash, or rot goes unreported), or **n/a** (the surface does not exist — say why).

**Row 1 — Dead / unresolvable reference.** Trace three outcomes through each resolver to what re-enters context: null/404, 401/403 (auth rot — a token that refreshed an hour ago is exactly the reference that silently dies), and timeout. Loud only if each surfaces as a typed error the loop can catch. Silent if any path returns an empty string, empty list, or partial payload — to the model that looks like a fetch that succeeded and found nothing worth quoting, and it fills the gap from parametric memory.

**Row 2 — Bad / ambiguous tool description.** Take the script's flags, then read each flagged description as the routing input it is: does it state scope, return shape, and what the tool does NOT cover? Is the long tail deferred or searchable rather than loaded upfront? Wrong-tool selection is silent — the model never reports the ambiguity.

**Row 3 — Empty / no-match semantic result.** Embedding search always returns something; the nearest semantic neighbor of an absent answer arrives ranked and confident. Loud only if some path lets retrieval report "no supporting evidence": a lexical/logical constraint that can visibly fail, a score threshold that triggers abstention, or repeated-off-topic detection. Silent if the top-k list always flows downstream regardless of score.

**Row 4 — No stop rule on the retrieval loop.** Look for: a hard numeric cap on retrieval cycles (the post's source disciplines it at three passes); a failed pass defined as "added no new supporting evidence," not merely "errored"; deduplication across passes; and a disclaimed best-effort answer at the cap. Silent if the exit condition is model confidence — a locally-optimizing loop answers "do I have enough?" with "get more" and spirals.

**Row 5 — Low-confidence resolution (the fallback).** When a resolution comes back failed or low-confidence, does the raw payload get re-injected into context "just in case"? Silent if yes: a single irrelevant distractor measurably degrades performance, so dumping the blob back trades a loud miss for a quiet degradation.

## Step 4 — Emit the ledger report

One row per failure mode:

```
| # | What breaks | Evidence (file:lines) | Verdict | Fix (if silent) |
```

Close the report with the post's shipping rule: **any row whose verdict is "silent" is a failure that will be silent in production.** For silent rows, the hardened fallback runs in this order — cap the loop, check whether real evidence came back, prefer honest abstention (error or disclaimed best-effort, never a confident fabrication), and withhold the raw resolved payload from context.

## Grounding

Canonical post: https://jyoung.dev/blog/jit-context-retrieval-failure/ — all figures below are verified there against primary sources.

- The runtime-exploration tradeoff (slower, tooling-dependent) and pointers-over-preloading JIT definition: Anthropic, "Effective context engineering for AI agents."
- "An unresolvable reference must surface as an honest error, not a hallucinated payload": TrueFoundry, "JIT Context."
- 58 tools ~= 55K tokens upfront (134K before optimization); wrong tool selection as the most common failure, especially with similar names: Anthropic, "Advanced tool use."
- 97.1% of MCP tool descriptions have at least one quality issue, 56% unclear purpose, +5.85pp task success from augmented descriptions (arXiv:2602.14878); 107 tools -> complete failure vs 10 -> perfect (Speakeasy): both reported in Guy / AWS Heroes, "MCP Tool Design."
- Lexical-constraint legibility; refusal 0.767 -> 0.828 and hallucination 0.128 -> 0.083 on answer-unavailable questions: Zeng et al., "Rethinking Agentic RAG" (arXiv:2605.27123).
- The "get more" spiral, the three-cycle cap with disclaimed best-effort, and the 200-calls/$50-200 and 1,700% cost incidents: Ibrahim, Towards Data Science.
- Single-distractor degradation across 18 models: Chroma, "Context Rot" (Hong et al., 2025).
- Silent retrieval failure has no flag; auth/token rot fails silently: Perrone, "Why AI Agents Keep Failing in Production."
- Tool invocation (not reasoning) as the primary reliability bottleneck for smaller models: Huang et al. (arXiv:2601.16280).
