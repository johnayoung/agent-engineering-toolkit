#!/usr/bin/env bash
# triage-agent-diff.sh — mechanical triage of an agent-authored diff before review.
# Inventories the diff, reports the test-claim signal, flags blast-radius signals
# (path/keyword heuristic), and emits the six-move per-task verification checklist.
#
# The heuristics here are prompts to look, not verdicts. A keyword match is not
# proof of risk; the absence of a match is NOT low risk. Classify unmatched files
# yourself. Framework: https://jyoung.dev/blog/evaluating-ai-coding-agent-output/
#
# Usage:
#   git diff main...HEAD | triage-agent-diff.sh        # read unified diff from stdin
#   triage-agent-diff.sh pr.diff                       # read unified diff from a file
#   triage-agent-diff.sh --git <base> [<head>]         # run git diff <base>...<head> (default head: HEAD)
#
# Dependencies: coreutils + awk (git only for --git mode).

set -euo pipefail

usage() { sed -n '2,15p' "$0" | sed 's/^# \{0,1\}//'; exit "${1:-0}"; }

SOURCE_LABEL=""
DIFF_INPUT=""

case "${1:-}" in
  -h|--help) usage 0 ;;
  --git)
    shift
    [ $# -ge 1 ] || { echo "error: --git requires a base ref" >&2; usage 1; }
    command -v git >/dev/null || { echo "error: git not found (needed for --git mode)" >&2; exit 1; }
    BASE=$1; HEAD_REF=${2:-HEAD}
    SOURCE_LABEL="git diff ${BASE}...${HEAD_REF}"
    DIFF_INPUT=$(git diff "${BASE}...${HEAD_REF}") || { echo "error: git diff failed" >&2; exit 1; }
    ;;
  "")
    if [ -t 0 ]; then
      echo "error: no diff file given and stdin is a terminal" >&2; usage 1
    fi
    SOURCE_LABEL="stdin"
    DIFF_INPUT=$(cat)
    ;;
  *)
    [ -f "$1" ] || { echo "error: diff file not found: $1" >&2; exit 1; }
    SOURCE_LABEL="file: $1"
    DIFF_INPUT=$(cat "$1")
    ;;
esac

if [ -z "$DIFF_INPUT" ]; then
  echo "error: empty diff — nothing to triage" >&2
  exit 1
fi

printf '%s\n' "$DIFF_INPUT" | awk -v src="$SOURCE_LABEL" '
BEGIN {
  nfiles = 0
  # Blast-radius keywords per the post: auth, payments, permissions, data deletion.
  high_re  = "auth|login|session|oauth|sso|password|credential|payment|billing|checkout|charge|refund|invoice|permission|rbac|acl|privilege|migration|truncate|drop[ _]table"
  # Config surfaces: low blast radius UNLESS a secret, feature flag, or infra setting.
  conf_re  = "\\.(ya?ml|toml|ini|cfg|conf|json|env|tf|tfvars|properties)$|(^|/)(dockerfile|makefile|\\.env[^/]*)$|\\.github/workflows|(^|/)(terraform|helm|k8s|deploy|infra)(/|$)"
  confkey_re = "secret|api[_-]?key|password|credential|feature[_-]?flag|private[_-]?key"
  test_re  = "(^|/)(tests?|__tests__|spec|testdata|fixtures)(/|$)|_test\\.|\\.test\\.|\\.spec\\.|(^|/)test_|_spec\\."
}
/^diff --git / {
  # path = b-side of "diff --git a/X b/X" (git repeats the path on deletions)
  path = $0
  sub(/^diff --git a\/.* b\//, "", path)
  cur = path
  if (!(cur in seen)) { seen[cur] = 1; order[++nfiles] = cur; adds[cur] = 0; dels[cur] = 0 }
  next
}
/^\+\+\+ / || /^--- / { next }
/^\+/ {
  if (cur != "") {
    adds[cur]++
    line = tolower($0)
    if (match(line, high_re) && highhit[cur] == "")
      highhit[cur] = substr(line, RSTART, RLENGTH)
    if (match(line, confkey_re) && confhit[cur] == "")
      confhit[cur] = substr(line, RSTART, RLENGTH)
  }
  next
}
/^-/ { if (cur != "") dels[cur]++; next }
END {
  if (nfiles == 0) {
    print "error: no file entries found — is this a unified git diff?" > "/dev/stderr"
    exit 1
  }

  tot_a = 0; tot_d = 0
  n_test = 0; n_high = 0; n_conf = 0; n_unclass = 0
  for (i = 1; i <= nfiles; i++) {
    f = order[i]; lf = tolower(f)
    tot_a += adds[f]; tot_d += dels[f]
    cls = ""
    if (match(lf, test_re))      { cls = "TEST";   tests[++n_test] = f }
    if (match(lf, high_re))      { cls = cls "HIGH"; highs[++n_high] = f; if (highhit[f] == "") highhit[f] = "path"; else highhit[f] = "path, added line: " highhit[f] }
    else if (highhit[f] != "")   { cls = cls "HIGH"; highs[++n_high] = f; highhit[f] = "added line: " highhit[f] }
    if (match(lf, conf_re))      { cls = cls "CONFIG"; confs[++n_conf] = f }
    if (cls == "")               { n_unclass++ }
    class[f] = cls
  }

  print "== Agent diff triage =="
  print "Source: " src
  print ""
  print "-- Inventory --"
  printf "%-6s %-6s %s\n", "+", "-", "file"
  for (i = 1; i <= nfiles; i++) {
    f = order[i]
    tag = ""
    if (index(class[f], "HIGH"))   tag = tag " [HIGH]"
    if (index(class[f], "CONFIG")) tag = tag " [CONFIG]"
    if (index(class[f], "TEST"))   tag = tag " [TEST]"
    printf "%-6d %-6d %s%s\n", adds[f], dels[f], f, tag
  }
  printf "Total: %d file(s), +%d/-%d lines\n", nfiles, tot_a, tot_d
  print ""

  print "-- Test signal (move 3: tests are a claim, not proof) --"
  if (n_test == 0) {
    print "NO test files in this diff. The PR carries no test claim to read;"
    print "every acceptance criterion must be exercised manually."
  } else {
    print "Test files touched (" n_test "):"
    for (i = 1; i <= n_test; i++) print "  " tests[i]
    print "Read each assertion against the spec. A green suite demonstrates only"
    print "the cases the agent chose to assert — criteria with no assertion are"
    print "the risky path the suite dodged. Test presence alone does not predict"
    print "a better outcome (merge rates are similar with or without tests)."
  }
  print ""

  print "-- Blast-radius signals (move 6) — path/keyword HEURISTIC --"
  print "A match is a prompt to look, not a verdict. No match is NOT low risk."
  if (n_high > 0) {
    print "HIGH (auth/payments/permissions/deletion zone):"
    for (i = 1; i <= n_high; i++) { f = highs[i]; print "  " f "  (matched: " highhit[f] ")" }
  } else {
    print "HIGH: none matched."
  }
  if (n_conf > 0) {
    print "CONFIG (low blast radius UNLESS a secret, feature flag, or infra setting):"
    for (i = 1; i <= n_conf; i++) {
      f = confs[i]
      if (confhit[f] != "") print "  " f "  (added line matched: " confhit[f] " — check it)"
      else                  print "  " f
    }
  } else {
    print "CONFIG: none matched."
  }
  if (n_unclass > 0) print "UNCLASSIFIED: " n_unclass " file(s) — classify these yourself."
  print ""

  print "-- Suggested depth (heuristic) --"
  if (n_high > 0) {
    print "DEEP: high-blast-radius signals present. Verify forward from the spec,"
    print "run the code, adversarial fresh-context review. AI-authored code"
    print "concentrates failures in logic (1.75x) and security (1.57x) findings."
  } else {
    print "SHALLOW-eligible: no high-risk keywords matched. Confirm the change is"
    print "actually isolated/internal before going shallow — this is a keyword"
    print "scan, not a dependency analysis."
  }
  print ""

  print "-- Per-task verification checklist (paste into your review) --"
  print "- [ ] 1. Bottleneck moved: review budgeted as the throughput ceiling (releases-per-week, not diffs-per-week)"
  print "- [ ] 2. Self-report rejected: every \"done/passes/works\" claim has a command + output or artifact behind it, checked by a fresh grader"
  if (n_test == 0)
    print "- [ ] 3. Tests as claim: NO tests in diff — every criterion exercised manually"
  else
    print "- [ ] 3. Tests as claim: each assertion in the " n_test " test file(s) mapped to a spec criterion; unasserted criteria listed"
  print "- [ ] 4. Forward from spec: every acceptance criterion marked BUILT / PARTIAL / MISSING with evidence"
  print "- [ ] 5. Scope diff: every hunk not traceable to a criterion flagged as unsolicited scope"
  if (n_high > 0)
    print "- [ ] 6. Blast radius: DEEP review applied — " n_high " high-signal file(s) in this diff"
  else
    print "- [ ] 6. Blast radius: depth set by what the diff touches, not its size"
  print ""
  print "Heuristic notice: classifications above are path/keyword matches, not"
  print "analysis. Framework and sources:"
  print "https://jyoung.dev/blog/evaluating-ai-coding-agent-output/"
}
'
