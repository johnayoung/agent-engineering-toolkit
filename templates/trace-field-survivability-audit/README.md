# trace-field-survivability-audit

Runnable version of the closing ranking in [Rank Your Agent Trace Fields by What You Can Never Get Back](https://jyoung.dev/blog/agent-observability-trace-schema/). It reads exported spans and, for every LLM-shaped span, checks whether the four fields the post ranks as unrecoverable were actually written at call time. Bash + jq, no other dependencies.

**Read-only.** It opens trace/span export files and prints what it finds. It writes nothing and touches no collector, SDK, or instrumentation config.

**It checks presence, never correctness.** A `gen_ai.response.model` that silently equals `gen_ai.request.model`, because an instrumentation defaulted one from the other, looks identical on disk to a genuinely resolved snapshot. This script cannot tell the difference. Every run says so.

## Why these four fields and not more

The post's closing numbered list has five instructions. The first four name fields to capture; the fifth says to assert the first four in CI:

1. Set `gen_ai.system_instructions`, `gen_ai.input.messages`, `gen_ai.output.messages` explicitly.
2. Set `gen_ai.response.model` on every call.
3. Record the resolved prompt content or its hash, plus the pinned version.
4. Copy the retirement date into the span at call time.
5. Assert all of the above in CI, so a missing field fails the build rather than the postmortem.

This script is instruction 5, built for instructions 1 through 4. It checks nothing the post does not itself rank as unrecoverable. `openai.response.system_fingerprint` (Recommended tier in the OpenTelemetry OpenAI conventions) is reported when present or absent on OpenAI-provider spans, but it never fails the run, because the post's own gate stops at four fields, not five.

## Usage

```bash
./trace-field-survivability-audit.sh path/to/spans.json     # JSON array, JSON-Lines, or OTLP export
./trace-field-survivability-audit.sh path/to/traces/         # scans for *trace*.json, *span*.json, etc.
echo $?                                                       # 0 = every LLM span has all four fields, 1 = at least one is missing one
```

Accepted shapes, detected automatically:

- A JSON array of flat spans, `[{"name": "...", "attributes": {"gen_ai.request.model": "..."}}]`, the shape used throughout the post.
- JSON-Lines, one span object per line, the shape most collectors emit to a file exporter.
- A full OTLP JSON export, `{"resourceSpans": [{"scopeSpans": [{"spans": [...]}]}]}`, with `attributes` as the wire-format array of `{key, value}` pairs. This is the real shape the OpenTelemetry Collector's file/logging exporter writes.

A span counts as LLM-shaped if it carries `gen_ai.operation.name`, `gen_ai.provider.name`, `gen_ai.system`, `llm.model_name`, or `llm.request.model_name`. Everything else (HTTP spans, DB spans, tool spans with no model identity) is counted and skipped, not flagged.

## What it checks

| Field class | Attribute(s) checked | Source of the requirement level named in the output |
| --- | --- | --- |
| Decision content | `gen_ai.system_instructions`, `gen_ai.input.messages`, `gen_ai.output.messages` (any one present counts) | OpenTelemetry GenAI spans: all three sit at Opt-In |
| Resolved model snapshot | `gen_ai.response.model` present when `gen_ai.request.model` is present | OpenTelemetry GenAI spans: request model is Conditionally Required or Required, response model is only Recommended |
| Prompt version or content | `agent.prompt.version`, `.hash`, or `.content`, or `gen_ai.prompt.version`, or `llm.prompt_template.version` | Heuristic. Only `llm.prompt_template.version` (OpenInference) is a published attribute name; the rest are the post's own, since no convention names this field |
| Retirement date | `model.shutdown_date` | Heuristic. The post's own attribute name; the underlying value is machine-readable on OpenAI's Model object (`shutdown_date`) and published on Anthropic's deprecations page, but neither vendor documents a span attribute for it |
| System fingerprint (informational only) | `openai.response.system_fingerprint` on OpenAI-provider spans | OpenTelemetry OpenAI client operations: Recommended. Reported, never gates exit code |

The two heuristic rows are the honest limit of this script. There is no published convention for "the prompt version" or "the shutdown date" as a trace attribute, because that is the post's whole argument: nobody ranks these fields, so nobody names them either. If your instrumentation writes the same facts under different keys, edit `PROMPT_KEYS` and `SHUTDOWN_KEYS` near the top of the script to match your schema before wiring this into CI.

## Example

Against the post's own "Bad" span (`gen_ai.request.model` only, no response model, no decision content, no prompt version, no shutdown date):

```
Span: chat claude-opus-4-1
  model identity          MISSING: response model not captured (alias only: claude-opus-4-1)
      Post ranking: "No. The snapshot stops serving and the pointer stops resolving."
  decision content        MISSING: system_instructions/input.messages/output.messages all absent
  prompt version/content  MISSING: no agent.prompt.version/.hash/.content or llm.prompt_template.version
  retirement date         MISSING: model.shutdown_date not present at call time

RESULT: FAIL. At least one LLM span is missing a field the post ranks unrecoverable.
```

Against the post's own "Good" span (adds `gen_ai.response.model`, `agent.prompt.version`, `model.shutdown_date`, but the post introduces that example to illustrate only the model/prompt/retirement dimension, not decision content):

```
Span: chat claude-opus-4-1
  model identity          CAPTURED: request=claude-opus-4-1 response=claude-opus-4-1-20250805
  decision content        MISSING: system_instructions/input.messages/output.messages all absent
  prompt version/content  CAPTURED
  retirement date         CAPTURED: model.shutdown_date present

RESULT: FAIL.
```

Even the post's own worked "Good" example fails this audit, because that example was written to isolate one lesson (record the snapshot, not the alias), not to demonstrate a fully compliant span. The script does not special-case that; a span missing decision content fails regardless of which section it illustrates.

## CI gate

```yaml
- name: trace field survivability
  run: ./trace-field-survivability-audit.sh exports/traces.json
```

Non-zero exit on any missing field. Point it at whatever your collector or SDK exports as a build artifact, not at source-controlled config, since the fields it checks are written by your instrumentation at call time and only exist once a real call has been traced.

## What it does not do

- **Does not verify a value is meaningful**, only that a key exists. See the correctness caveat above.
- **Does not check retention, run caps, flush behavior, or Zero Data Retention.** Those are the post's fourth section (retention deletes the session before you need it) and they are properties of your observability platform's configuration, not of an already-exported span file. Check them by hand against your vendor's docs; the script cannot see a span that retention already deleted.
- **Does not check the statutory field list.** The post's fifth section shows the EU AI Act fixes duration and purpose, not fields, so there is nothing for a field-presence script to check there either.
- **Does not rank OpenTelemetry against OpenInference against OWASP AOS.** It checks your spans against the union of attribute names those conventions and the post itself use, not against any one spec's conformance rules.

## Grounding

Canonical post: https://jyoung.dev/blog/agent-observability-trace-schema/

Documented facts this script's checks rely on:

- `gen_ai.request.model` is Conditionally Required (generic GenAI spans) or flatly Required (OpenAI client operations); `gen_ai.response.model` is Recommended in both documents. `gen_ai.system_instructions`, `gen_ai.input.messages`, `gen_ai.output.messages` are Opt-In. `openai.response.system_fingerprint` is Recommended. All Development status, not Stable. Source: OpenTelemetry GenAI client spans and OpenAI client operations semantic conventions.
- Removing decision content from a trace "reduces origin-step accuracy to zero for all five models" tested. Source: Zhu and Pu, TelemetrySuffBench (arXiv:2608.07899), a two-author preprint whose compatibility renderers use the authors' own conservative field set, not a test of the OpenTelemetry or OpenInference registries themselves.
- `llm.prompt_template.version` ("The version of the prompt template") is a published OpenInference attribute. Source: Arize AI, OpenInference Semantic Conventions.
- OpenAI's Model object exposes `shutdown_date`, "The date when the model will shut down, or null if not announced." Source: OpenAI Models API reference. Neither this nor Anthropic's deprecations page documents a span attribute for the value, which is why `model.shutdown_date` in this script is labeled the post's own name, not a convention.

Everything this script cannot source to a published convention, it labels a heuristic in its own output rather than presenting it as a standard.

## Related

`templates/harness-audit/` answers a neighboring question at the harness layer: which permission, hook, and sandbox controls are set versus shipped at their default. This one answers it at the trace layer: which forensic fields are written versus left at whatever tier a convention assigned them.
