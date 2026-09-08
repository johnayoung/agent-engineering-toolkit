#!/usr/bin/env bash
# trace-field-survivability-audit.sh: the closing ranking from
# "Rank Your Agent Trace Fields by What You Can Never Get Back"
# https://jyoung.dev/blog/agent-observability-trace-schema/
#
# READ-ONLY. This script reads exported spans and prints what it finds. It
# writes nothing, fixes nothing, and does not touch your collector, your
# instrumentation, or your traces. It answers one question per LLM-shaped
# span: which of the fields the post ranks as unrecoverable did you actually
# write at call time?
#
# It checks the four survivability fields the post's closing list names, in
# that order:
#   1. decision content:   gen_ai.system_instructions / .input.messages /
#                           .output.messages (published Opt-In; the field
#                           TelemetrySuffBench's ablation drives to zero)
#   2. resolved snapshot:  gen_ai.response.model present, not just
#                           gen_ai.request.model (the alias/snapshot split)
#   3. prompt version:     a pinned prompt version or content/hash, checked
#                          against attribute names this script defines
#                          itself, none of which is a published convention
#   4. retirement date:    the vendor's shutdown/retirement date copied
#                          into the span, same caveat as #3
#
# A fifth field, openai.response.system_fingerprint, is checked and reported
# but never fails the run: the post's own numbered list stops at four, and
# this script does not go further than the post does.
#
# Exit code: 0 if every LLM-shaped span carries all four fields, 1 if any
# span is missing one. That mirrors the post's fifth instruction directly:
# "Assert all of the above in CI, so a missing survivability field fails the
# build rather than the postmortem."
#
# Usage: trace-field-survivability-audit.sh <spans.json | spans.jsonl | dir>
# Requires: jq. Everything else is coreutils.

set -euo pipefail

usage() {
  cat <<'EOF'
trace-field-survivability-audit.sh <spans-file | spans-dir>

Read-only field-presence audit against exported trace/span JSON. Prints,
per LLM-shaped span, whether the four survivability-critical fields from
https://jyoung.dev/blog/agent-observability-trace-schema/ were captured.
Writes nothing. Exits non-zero if any LLM span is missing one of them.

Accepts:
  - a single file: a JSON array of spans, a JSON-Lines file (one span
    object per line), or a full OTLP JSON export ({"resourceSpans": [...]})
  - a directory: scanned (skipping node_modules, .git, .venv, vendor) for
    *trace*.json, *trace*.jsonl, *span*.json, *otel*.json, *otlp*.json,
    *.ndjson, up to 50 files

IMPORTANT LIMITS THIS SCRIPT DOES NOT HIDE:
  - It checks whether a key is PRESENT, never whether its value is correct.
    A gen_ai.response.model that silently equals gen_ai.request.model looks
    identical on disk to a genuinely resolved snapshot. Verify by hand.
  - agent.prompt.version, agent.prompt.hash, agent.prompt.content, and
    model.shutdown_date are this post's OWN attribute names, not published
    conventions. If your instrumentation uses different keys for the same
    facts, this script will report them MISSING even though you captured
    them. Edit PROMPT_KEYS / SHUTDOWN_KEYS below to match your schema.
EOF
}

case "${1:-}" in
  -h|--help|"") usage; exit 0 ;;
esac

command -v jq >/dev/null 2>&1 || { echo "error: jq is required" >&2; exit 1; }

TARGET="$1"

# --- gather input files ---------------------------------------------------

FILES=()
if [ -f "$TARGET" ]; then
  FILES=("$TARGET")
elif [ -d "$TARGET" ]; then
  while IFS= read -r f; do FILES+=("$f"); done < <(
    find "$TARGET" \
      \( -path '*/node_modules/*' -o -path '*/.git/*' -o -path '*/.venv/*' -o -path '*/vendor/*' \) -prune -o \
      -type f \( -iname '*trace*.json' -o -iname '*trace*.jsonl' -o -iname '*span*.json' \
                 -o -iname '*otel*.json' -o -iname '*otlp*.json' -o -iname '*.ndjson' \) -print \
      2>/dev/null | head -50
  )
else
  echo "error: no such file or directory: $TARGET" >&2
  exit 1
fi

echo "TRACE FIELD SURVIVABILITY AUDIT"
echo "Read-only: this script reads exported spans and changes nothing."
echo "Checks field PRESENCE only, never field correctness."
echo

if [ ${#FILES[@]} -eq 0 ]; then
  echo "No trace/span export files found under $TARGET"
  echo "(looked for *trace*.json, *trace*.jsonl, *span*.json, *otel*.json,"
  echo " *otlp*.json, *.ndjson, skipping node_modules, .git, .venv, vendor)"
  echo
  echo "Point this script at an exported span file directly:"
  echo "  trace-field-survivability-audit.sh path/to/spans.json"
  echo
  echo "Nothing to audit is not a pass. It means no exported evidence exists"
  echo "here for this script to check."
  exit 0
fi

echo "Files read:"
for f in "${FILES[@]}"; do printf '  %s\n' "$f"; done
echo

# --- attribute names this script checks (edit to match your schema) -------
# None of PROMPT_KEYS or SHUTDOWN_KEYS is a published OpenTelemetry,
# OpenInference, or OWASP AOS attribute. They are the post's own names.
PROMPT_KEYS='.["agent.prompt.version"] // .["agent.prompt.hash"] // .["agent.prompt.content"] // .["gen_ai.prompt.version"] // .["llm.prompt_template.version"]'
SHUTDOWN_KEYS='.["model.shutdown_date"]'

NORM_ATTRS_FN='
  def norm_attrs:
    if (.attributes|type) == "object" then .attributes
    elif (.attributes|type) == "array" then
      (.attributes
        | map({key: .key,
               value: (.value.stringValue // .value.intValue // .value.doubleValue // .value.boolValue // null)})
        | from_entries)
    else {} end;
'

SPANS_FILE=$(mktemp)
trap 'rm -f "$SPANS_FILE" "${REPORT_FILE:-}"' EXIT

for f in "${FILES[@]}"; do
  if jq -e 'type=="object" and has("resourceSpans")' "$f" >/dev/null 2>&1; then
    jq -c "$NORM_ATTRS_FN"'
      .resourceSpans[]? | .scopeSpans[]? | .spans[]?
      | {name: (.name // "unknown"), attributes: norm_attrs}
    ' "$f" >> "$SPANS_FILE" 2>/dev/null || echo "warning: could not parse OTLP shape in $f" >&2
  elif jq -e 'type=="array"' "$f" >/dev/null 2>&1; then
    jq -c "$NORM_ATTRS_FN"'
      .[] | {name: (.name // "unknown"), attributes: norm_attrs}
    ' "$f" >> "$SPANS_FILE" 2>/dev/null || echo "warning: could not parse array shape in $f" >&2
  elif jq -e 'type=="object"' "$f" >/dev/null 2>&1; then
    jq -c "$NORM_ATTRS_FN"'
      {name: (.name // "unknown"), attributes: norm_attrs}
    ' "$f" >> "$SPANS_FILE" 2>/dev/null || echo "warning: could not parse $f as JSON-Lines" >&2
  else
    echo "warning: $f is not valid JSON (array, object, OTLP export, or JSON-Lines), skipped" >&2
  fi
done

TOTAL_SPANS=$(wc -l < "$SPANS_FILE" | tr -d ' ')
if [ "$TOTAL_SPANS" -eq 0 ]; then
  echo "No spans parsed out of ${#FILES[@]} file(s). Nothing to audit."
  exit 0
fi

# --- per-span analysis ------------------------------------------------------

REPORT_FILE=$(mktemp)
jq -c --arg promptexpr "$PROMPT_KEYS" '
  .attributes as $a
  | (($a["gen_ai.operation.name"] != null) or ($a["gen_ai.provider.name"] != null)
     or ($a["gen_ai.system"] != null) or ($a["llm.model_name"] != null)
     or ($a["llm.request.model_name"] != null)) as $is_llm
  | if ($is_llm | not) then
      {name, is_llm: false}
    else
      ($a["gen_ai.request.model"] // $a["llm.request.model_name"] // $a["llm.model_name"]) as $req
    | ($a["gen_ai.response.model"] // $a["llm.response.model_name"]) as $resp
    | (($a["gen_ai.system_instructions"] != null)) as $has_sys
    | (($a["gen_ai.input.messages"] != null)) as $has_in
    | (($a["gen_ai.output.messages"] != null)) as $has_out
    | (($a["agent.prompt.version"] != null) or ($a["agent.prompt.hash"] != null)
       or ($a["agent.prompt.content"] != null) or ($a["gen_ai.prompt.version"] != null)
       or ($a["llm.prompt_template.version"] != null)) as $has_prompt
    | (($a["model.shutdown_date"] != null)) as $has_shutdown
    | ((($a["gen_ai.provider.name"] // $a["gen_ai.system"] // "") | ascii_downcase | contains("openai"))) as $is_openai
    | (($a["openai.response.system_fingerprint"] != null)) as $has_fp
    | {
        name, is_llm: true,
        request_model: $req, response_model: $resp,
        alias_only: (($req != null) and ($resp == null)),
        has_decision: ($has_sys or $has_in or $has_out),
        has_sys: $has_sys, has_in: $has_in, has_out: $has_out,
        has_prompt: $has_prompt, has_shutdown: $has_shutdown,
        is_openai: $is_openai, has_fp: $has_fp
      }
    end
' "$SPANS_FILE" > "$REPORT_FILE"

LLM_COUNT=0
SKIP_COUNT=0
MISS_DECISION=0
MISS_RESP=0
MISS_PROMPT=0
MISS_SHUTDOWN=0
MISS_FP=0
FAIL=0

hr() { printf '%s\n' "------------------------------------------------------------------------"; }

hr
echo "PER-SPAN FINDINGS"
hr

while IFS=$'\x1f' read -r name is_llm req resp alias_only has_decision has_sys has_in has_out has_prompt has_shutdown is_openai has_fp; do
  if [ "$is_llm" != "true" ]; then
    SKIP_COUNT=$((SKIP_COUNT + 1))
    continue
  fi
  LLM_COUNT=$((LLM_COUNT + 1))
  echo
  echo "Span: $name"

  if [ -z "$req" ] && [ -z "$resp" ]; then
    echo "  model identity          UNDETERMINED: no gen_ai.request.model / llm.*model_name found"
  elif [ "$alias_only" = "true" ]; then
    printf '  model identity          MISSING: response model not captured (alias only: %s)\n' "$req"
    echo "      Post ranking: \"No. The snapshot stops serving and the pointer stops resolving.\""
    MISS_RESP=$((MISS_RESP + 1)); FAIL=1
  else
    printf '  model identity          CAPTURED: request=%s response=%s\n' "${req:-?}" "${resp:-?}"
  fi

  if [ "$has_decision" = "true" ]; then
    printf '  decision content        CAPTURED: sys=%s in=%s out=%s\n' "$has_sys" "$has_in" "$has_out"
  else
    echo "  decision content        MISSING: system_instructions/input.messages/output.messages all absent"
    echo "      Opt-In by default in the OpenTelemetry GenAI conventions. TelemetrySuffBench's"
    echo "      ablation: removing this field \"reduces origin-step accuracy to zero for all five models.\""
    MISS_DECISION=$((MISS_DECISION + 1)); FAIL=1
  fi

  if [ "$has_prompt" = "true" ]; then
    echo "  prompt version/content  CAPTURED"
  else
    echo "  prompt version/content  MISSING: no agent.prompt.version/.hash/.content or llm.prompt_template.version"
    echo "      Heuristic check against this script's own attribute names, not a published convention."
    MISS_PROMPT=$((MISS_PROMPT + 1)); FAIL=1
  fi

  if [ "$has_shutdown" = "true" ]; then
    echo "  retirement date         CAPTURED: model.shutdown_date present"
  else
    echo "  retirement date         MISSING: model.shutdown_date not present at call time"
    echo "      Heuristic check against this script's own attribute name, not a published convention."
    MISS_SHUTDOWN=$((MISS_SHUTDOWN + 1)); FAIL=1
  fi

  if [ "$is_openai" = "true" ]; then
    if [ "$has_fp" = "true" ]; then
      echo "  system_fingerprint      CAPTURED (Recommended tier; informational, does not gate CI)"
    else
      echo "  system_fingerprint      MISSING (Recommended tier; informational, does not gate CI)"
      MISS_FP=$((MISS_FP + 1))
    fi
  fi
done < <(jq -r '
  [((.name // "unknown") | gsub(""; "_") | gsub("\n"; " ")),
   (.is_llm | tostring), (.request_model // ""), (.response_model // ""),
   (.alias_only | tostring), (.has_decision | tostring), (.has_sys | tostring),
   (.has_in | tostring), (.has_out | tostring), (.has_prompt | tostring),
   (.has_shutdown | tostring), (.is_openai | tostring), (.has_fp | tostring)]
  | join("")
' "$REPORT_FILE")

# --- summary -----------------------------------------------------------------

echo
hr
echo "SUMMARY"
hr
echo "  spans parsed:              $TOTAL_SPANS"
echo "  LLM-shaped spans checked:  $LLM_COUNT"
echo "  non-LLM spans skipped:     $SKIP_COUNT"
echo
echo "  missing decision content:        $MISS_DECISION"
echo "  missing resolved response model: $MISS_RESP"
echo "  missing prompt version/content:  $MISS_PROMPT"
echo "  missing retirement date:         $MISS_SHUTDOWN"
echo "  missing system_fingerprint (info only, non-blocking): $MISS_FP"

echo
hr
echo "THE POST'S RANKING, FOR REFERENCE"
hr
cat <<'EOF'
  Field class                               What destroys it                    Recovered by re-running?
  Decision content                          Opt-In defaults, plus the measured   No: the run is non-
                                             zero-accuracy ablation               deterministic between runs
  Resolved model snapshot + prompt version  Vendor retirement clock, plus the    No: snapshot stops serving,
                                             prompt service's scheduled shutdown  pointer stops resolving
  Fields your menu leaves optional          Spec optionality, plus defaults      No: nothing writes it
  (response model, tool schema version)     that expect the field unset          retroactively
  The span itself                           Retention ceilings, run caps,        No: client-side deletion
                                             unflushed exits, ZDR                 is not reversible
  The field list                            Nothing external: the law fixes      N/A: no authority
                                             duration, not fields                 specifies it for you
EOF

if [ "$LLM_COUNT" -eq 0 ]; then
  echo
  echo "No LLM-shaped spans found (no gen_ai.* or llm.* identity attribute on any"
  echo "span read). Nothing to gate on. Check that these are the right export files."
  exit 0
fi

echo
hr
if [ "$FAIL" -eq 1 ]; then
  echo "RESULT: FAIL. At least one LLM span is missing a field the post ranks unrecoverable."
  echo "\"Assert all of the above in CI, so a missing survivability field fails the build"
  echo "rather than the postmortem.\""
else
  echo "RESULT: PASS. Every LLM-shaped span carries all four survivability fields checked."
  echo "This does not confirm the values are correct, only that the keys are present."
fi
hr

echo
echo "Full argument: https://jyoung.dev/blog/agent-observability-trace-schema/"

[ "$FAIL" -eq 0 ]
