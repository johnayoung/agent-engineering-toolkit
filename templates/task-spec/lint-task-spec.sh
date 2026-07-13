#!/usr/bin/env bash
# lint-task-spec.sh — check a task spec against the elements from
# "The Anatomy of a Perfect AI Agent Task"
# https://jyoung.dev/blog/anatomy-of-a-perfect-ai-agent-task/
#
# Usage: lint-task-spec.sh <task-spec.md>
# Exit:  0 = all required sections present and non-empty (warnings allowed)
#        1 = one or more required sections missing or empty
#        2 = usage error
#
# Zero dependencies beyond coreutils (bash, awk, grep).

set -euo pipefail

usage() {
  echo "usage: $(basename "$0") <task-spec.md>" >&2
  exit 2
}

[[ $# -eq 1 ]] || usage
spec="$1"
[[ -f "$spec" ]] || { echo "error: not a file: $spec" >&2; exit 2; }

# ---- helpers (all fence-aware: '#' lines inside code fences are not headings)

headings_lower() {
  awk '
    /^```/ { fence = !fence; next }
    !fence && /^#{1,6}[ \t]/ { h = $0; sub(/^#+[ \t]+/, "", h); print tolower(h) }
  ' "$spec"
}

section_body() { # $1 = ERE matched against lowercased heading text; prints first match's body
  awk -v pat="$1" '
    /^```/ { fence = !fence; if (found) print; next }
    !fence && /^#{1,6}[ \t]/ {
      if (found) exit
      h = $0; sub(/^#+[ \t]+/, "", h)
      if (tolower(h) ~ pat) found = 1
      next
    }
    found { print }
  ' "$spec"
}

content_lines() { # stdin -> lines that are not blank and not single-line HTML comments
  grep -vE '^[ \t]*$' | grep -vE '^[ \t]*<!--.*-->[ \t]*$' || true
}

# ---- required sections: the post's worked example uses nine headings covering
# the seven elements (Relevant Files is part of architectural context; the
# constraints element splits into Constraints and Non-Goals).

elements=(
  'Goal|^goal|state the outcome, not the steps — agents plan better when they know the why'
  'Architectural Context|^architectural context|include only knowledge the agent cannot infer from reading code'
  'Relevant Files|^relevant files|entry points save the agent from searching blindly and burning context'
  'Reference Implementation|^reference implementation|an existing pattern to mirror beats a paragraph of description'
  'Constraints|^constraints|without boundaries, agents refactor things you did not ask them to touch'
  'Non-Goals|non-goals|an explicit out-of-scope list is what prevents scope creep'
  'Edge Cases|^edge cases|footguns and non-obvious couplings only you know about'
  'Acceptance Criteria|^acceptance criteria|if you do not define done, the agent decides for you'
  'Verification|^verification|exact commands let the agent self-check before declaring victory'
)

headings="$(headings_lower)"
fail=0
warn=0

echo "Task spec lint: $spec"
echo "Spec shape: https://jyoung.dev/blog/anatomy-of-a-perfect-ai-agent-task/"
echo

for e in "${elements[@]}"; do
  IFS='|' read -r label pat why <<<"$e"
  if grep -qE "$pat" <<<"$headings"; then
    body="$(section_body "$pat" | content_lines)"
    if [[ -n "$body" ]]; then
      printf 'PASS  %s\n' "$label"
    else
      printf 'FAIL  %s — heading present but section is empty (%s)\n' "$label" "$why"
      fail=$((fail + 1))
    fi
  else
    printf 'FAIL  %s — missing (%s)\n' "$label" "$why"
    fail=$((fail + 1))
  fi
done

# ---- heuristic scans (WARN, not FAIL — flag likely problems, human judges)

# Acceptance criteria must be observable and specific, not "should work correctly".
vague='should work|works? correctly|work correctly|as expected|properly|behaves? correctly'
ac_hits="$(section_body '^acceptance criteria' | grep -iE "$vague" || true)"
if [[ -n "$ac_hits" ]]; then
  while IFS= read -r line; do
    printf 'WARN  Acceptance Criteria — vague phrase (criteria must be observable, specific, testable): %s\n' \
      "$(echo "$line" | sed -E 's/^[ \t]+//')"
    warn=$((warn + 1))
  done <<<"$ac_hits"
fi

# Verification should contain runnable commands, not prose about testing.
ver_body="$(section_body '^verification' | content_lines)"
if [[ -n "$ver_body" ]] && ! grep -qE '(^```|^    |^\t|`[^`]+`)' <<<"$ver_body"; then
  echo 'WARN  Verification — no runnable command found (code fence, indented block, or inline code); tell the agent exactly how to confirm its own work'
  warn=$((warn + 1))
fi

# ---- size signal (rough proxy, stated as such)

size=$(awk '
  /^```/ { fence = !fence; next }
  fence { next }
  /^[ \t]*$/ { next }
  /^[ \t]*<!--.*-->[ \t]*$/ { next }
  /^#{1,6}[ \t]/ { next }
  { n++ }
  END { print n + 0 }
' "$spec")

echo
echo "Size: $size content lines outside code fences (rough proxy for instruction count)."
if ((size > 150)); then
  echo 'WARN  Size — frontier models reliably follow only ~150-200 instructions before adherence degrades; every irrelevant detail dilutes the signal of the rest'
  warn=$((warn + 1))
fi

echo
if ((fail > 0)); then
  echo "Result: FAIL — $fail required section(s) missing or empty"
  echo "Note: if this task is trivial (no real risk of the agent getting it wrong), skip the spec entirely — these sections are a maximum, not a minimum."
  exit 1
elif ((warn > 0)); then
  echo "Result: PASS with $warn warning(s)"
else
  echo "Result: PASS"
fi
