#!/usr/bin/env bash
# audit-tool-catalog.sh — mechanical audit of an agent's tool catalog, the
# decision surface the model routes on. This is ledger row 2 (bad/ambiguous
# tool description -> wrong tool selected, silently) of the JIT failure ledger:
# https://jyoung.dev/blog/jit-context-retrieval-failure/
#
# Where the numbers come from (verified in the post's sources):
#   - Catalog size: at 10 tools selection was measured perfect and at 107 both
#     large and small models failed completely (Speakeasy experiment, reported
#     in the AWS Heroes MCP tool design piece); Anthropic's own example is 58
#     tools consuming ~55K tokens before message 1, and 134K before optimization
#     (Anthropic, "advanced tool use").
#   - Description quality: a 2025 study of MCP tool descriptions (arXiv:2602.14878)
#     found 97.1% contain at least one quality issue and 56% have unclear purpose
#     statements; augmented descriptions improved task success by 5.85pp.
#   - Similar names: wrong tool selection and incorrect parameters are the most
#     common failures, "especially when tools have similar names" (Anthropic).
#
# Usage: audit-tool-catalog.sh <catalog.json>
#   Accepts an MCP tools/list JSON-RPC response, {"tools":[...]}, or a bare
#   array of {name, description} objects.
#
# Honesty notes: token counts are chars/4 estimates. The STUB length threshold,
# the return-shape / negative-scope keyword checks, and the word-overlap cutoff
# are lexical heuristics — they locate descriptions to read, they do not grade
# them.

set -euo pipefail

FILE="${1:-}"
if [ -z "$FILE" ] || [ ! -f "$FILE" ]; then
  echo "Usage: audit-tool-catalog.sh <catalog.json>" >&2
  echo "  catalog.json: MCP tools/list response, {\"tools\":[...]}, or bare [{name, description}, ...]" >&2
  exit 2
fi
command -v jq >/dev/null 2>&1 || { echo "ERROR: jq is required" >&2; exit 2; }

if ! NORM=$(jq -ce '
      (if type == "object" then (.result.tools // .tools) else . end)
      | if (. | type) == "array" then . else error("no tools array") end' "$FILE" 2>/dev/null); then
  echo "ERROR: $FILE is not valid JSON containing a tools array" >&2
  echo "  (expected an MCP tools/list response, {\"tools\":[...]}, or a bare array)" >&2
  exit 2
fi

COUNT=$(jq 'length' <<<"$NORM")
CHARS=$(printf '%s' "$NORM" | wc -c)
TOKENS=$(( CHARS / 4 ))

echo "JIT tool-catalog audit: $FILE"
echo "Ledger row 2: bad/ambiguous tool description -> wrong tool selected, silently."
echo "Rows 1, 3, 4, 5 are code-reading checks — the audit-jit-retrieval SKILL.md drives those."
echo
echo "CATALOG SIZE"
printf '  tools: %d\n' "$COUNT"
printf '  serialized catalog: ~%d tokens (chars/4 estimate; includes whatever schemas are in the dump)\n' "$TOKENS"
echo "  measured reference points:"
echo "    10 tools  -> selection measured perfect (Speakeasy experiment)"
echo "    58 tools  -> ~55K tokens before message 1 (Anthropic's own example)"
echo "    107 tools -> both large and small models failed completely (Speakeasy)"
if [ "$COUNT" -ge 107 ]; then
  echo "  FLAG: catalog is at or beyond 107 tools — the size where the measured experiment"
  echo "        saw complete failure for both large and small models. Cut or defer the catalog."
elif [ "$COUNT" -ge 58 ]; then
  echo "  FLAG: catalog is at or beyond the 58-tool example that consumed ~55K tokens before"
  echo "        message 1. Defer or search the long tail instead of loading it upfront."
elif [ "$COUNT" -gt 10 ]; then
  echo "  note: above the 10-tool size where selection was measured perfect — accuracy climbs"
  echo "        as the set shrinks; consider deferring rarely-used tools behind a search tool."
fi

if [ "$COUNT" -eq 0 ]; then
  echo
  echo "  (empty catalog — nothing to audit)"
  exit 0
fi

jq -r '.[] | [(.name // "unnamed"), ((.description // "") | gsub("[\t\n\r]+"; " "))] | @tsv' <<<"$NORM" \
| awk -F '\t' '
function cplen(a, b,   m, i) {
  m = (length(a) < length(b)) ? length(a) : length(b)
  for (i = 1; i <= m; i++) if (substr(a, i, 1) != substr(b, i, 1)) return i - 1
  return m
}
function minlen(a, b) { return (length(a) < length(b)) ? length(a) : length(b) }
function wordset(s, set,   raw, cnt, i, w, k) {
  gsub(/[^a-z0-9]+/, " ", s)
  cnt = split(s, raw, " ")
  k = 0
  for (i = 1; i <= cnt; i++) {
    w = raw[i]
    if (length(w) < 3) continue
    if (w ~ /^(the|and|for|with|from|that|this|are|was|were|has|have|its|use|via|but|can|will|when|each|any|all|into|over)$/) continue
    if (!(w in set)) { set[w] = 1; k++ }
  }
  return k
}
function jaccard(d1, d2,   s1, s2, n1, n2, inter, w) {
  n1 = wordset(tolower(d1), s1)
  n2 = wordset(tolower(d2), s2)
  if (n1 == 0 || n2 == 0) return 0
  inter = 0
  for (w in s1) if (w in s2) inter++
  return inter / (n1 + n2 - inter)
}
{
  n++
  name[n] = $1
  desc[n] = $2
}
END {
  print ""
  print "PER-TOOL DESCRIPTION AUDIT"
  printf "  %-40s %6s  %s\n", "tool", "chars", "flags"
  flagged = 0
  for (i = 1; i <= n; i++) {
    d = desc[i]; L = length(d); ld = tolower(d); f = ""
    if (L == 0)      f = f " MISSING-DESCRIPTION"
    else if (L < 80) f = f " STUB(<80-chars,heuristic)"
    if (L > 0 && ld !~ /return/) f = f " no-return-shape?"
    if (L > 0 && ld !~ /(^|[^a-z])(not|no|only|never|instead|except|excludes?|omit|without)([^a-z]|$)/)
      f = f " no-negative-scope?"
    if (f == "") f = "  ok"
    else flagged++
    printf "  %-40s %6d %s\n", substr(name[i], 1, 40), L, f
  }
  print ""
  print "ROUTING-COLLISION CHECKS (lexical heuristics)"
  hits = 0; MAXPAIRS = 25
  for (i = 1; i <= n; i++) for (j = i + 1; j <= n; j++) {
    if (name[i] == name[j]) {
      hits++
      if (hits <= MAXPAIRS) printf "  DUPLICATE NAME: %s appears more than once\n", name[i]
      continue
    }
    cp = cplen(tolower(name[i]), tolower(name[j]))
    if (cp >= 5 && cp * 2 >= minlen(name[i], name[j])) {
      hits++
      if (hits <= MAXPAIRS) printf "  similar names: %s / %s (shared prefix %d chars) — verify each description states what the tool does NOT cover\n", name[i], name[j], cp
    }
    jac = jaccard(desc[i], desc[j])
    if (jac >= 0.5) {
      hits++
      if (hits <= MAXPAIRS) printf "  overlapping descriptions: %s / %s (word overlap %.2f) — the model routes on these; overlapping one-liners select silently\n", name[i], name[j], jac
    }
  }
  if (hits == 0) print "  (none)"
  if (hits > MAXPAIRS) printf "  ... and %d more collision pairs (suppressed — this much overlap needs a catalog cut, not a longer list)\n", hits - MAXPAIRS
  print ""
  print "SUMMARY"
  printf "  %d of %d descriptions carry at least one flag.\n", flagged, n
  print "  Context: a 2025 study of MCP tool descriptions (arXiv:2602.14878) found 97.1%"
  print "  contain at least one quality issue and 56% have unclear purpose statements;"
  print "  augmented descriptions improved task success by 5.85 percentage points."
  print "  Caveat: the STUB threshold, keyword checks, and word-overlap cutoff are lexical"
  print "  heuristics — they locate descriptions to read, they do not grade them."
}'

echo
echo "Next: this covers ledger row 2 only. Rows 1 (dead references), 3 (empty semantic"
echo "results), 4 (loop caps), and 5 (fallback re-injection) are code-reading checks —"
echo "the audit-jit-retrieval SKILL.md drives that pass."
