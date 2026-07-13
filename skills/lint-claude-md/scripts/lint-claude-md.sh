#!/usr/bin/env bash
# lint-claude-md.sh — per-line lint of a CLAUDE.md against the instruction ceiling.
#
# The mechanism (sources verified in the post):
#   - Frontier models follow ~150-200 instructions with reasonable consistency, and
#     Claude Code's system prompt spends ~50 of that before CLAUDE.md loads (HumanLayer).
#   - Past the ceiling, rules are omitted silently — omission errors dominate at high
#     instruction density (IFScale benchmark, arXiv 2507.11538).
#   - Anthropic's memory docs target under 200 lines per CLAUDE.md file.
#   - Negative instructions are unreliable as user prompts — which is what CLAUDE.md
#     is; reserve DO NOT for hard safety boundaries (Zhu Liang, "Pink Elephant").
#   - Even a single distractor line reduces performance (Chroma, "Context Rot").
# Full argument: https://jyoung.dev/blog/claude-md-instruction-ceiling/
#
# Usage: lint-claude-md.sh [file-or-dir]      (default: ./CLAUDE.md)
#
# All classification is pattern heuristics. Flags are rewrite/cut candidates for the
# judgment gates (earns-its-line, anticipatory, conflicts), not verdicts.

set -euo pipefail

TARGET="${1:-.}"
if [ -d "$TARGET" ]; then
  FILE="$TARGET/CLAUDE.md"
else
  FILE="$TARGET"
fi
if [ ! -f "$FILE" ]; then
  echo "error: no file at $FILE" >&2
  exit 1
fi
FILE=$(cd "$(dirname "$FILE")" && pwd)/$(basename "$FILE")

awk -v fname="$FILE" -v line_target=200 '
BEGIN { fence=0; nflags=0; canary_line=0 }
{
  line=$0
  sub(/\r$/, "", line)
  low=tolower(line)
  if (canary_line == 0 && low ~ /tinkleberry|canary/) canary_line=NR
  if (line ~ /^(```|~~~)/) { fence=!fence; fenced++; next }
  if (fence) { fenced++; next }
  if (line ~ /^[[:space:]]*$/) { blanks++; next }
  if (line ~ /^#/) { headings++; next }

  is_rule = (low ~ /(^|[^a-z])(always|never|must|do not|don.t|avoid|ensure|make sure|be careful|only|run|use|prefer|require[sd]?|no)([^a-z]|$)/)
  if (is_rule) rules++; else functional++

  flag=""; advice=""
  if (low ~ /(clean code|best practice|good (variable |function )?names|meaningful (variable |function )?names|readable code|well[- ]documented|high[- ]quality|follow (standard )?(coding )?conventions|idiomatic|self.documenting)/) {
    flag="SELF-EVIDENT"
    advice="cut -- the agent already does this without the line; it spends a slot doing nothing"
  } else if (is_rule && low ~ /(before (each |every |you )?(commit|committing|push|pushing|merge|merging)|after (each|every)|pre.commit|on (every|each)|every time|each time)/) {
    flag="HOOK-SHAPED"
    advice="runs at a specific point every time -- if it can never be dropped, even once, move it to a PreToolUse/Stop hook (hooks are deterministic; CLAUDE.md is advisory)"
  } else if (is_rule && low ~ /(^|[^a-z])(never|do not|don.t|must not)([^a-z]|$)/) {
    flag="NEGATIVE"
    advice="rephrase as a positive runnable check (pattern: \"never create duplicate files\" -> \"check for an existing file before creating one\"); reserve DO NOT for hard safety boundaries only"
  } else if (is_rule && line !~ /`/ && low ~ /(be careful|make sure|ensure|properly|appropriately|as needed|when (appropriate|possible|necessary)|where possible|try to|carefully|thoughtfully|good judgment|as expected|correctly)/) {
    flag="VAGUE"
    advice="wish, not check -- rephrase so the agent can execute it or fail visibly (\"run npm test before committing\", not \"test your changes\")"
  }

  if (flag != "") {
    nflags++
    t=line; sub(/^[[:space:]*-]+/, "", t)
    if (length(t) > 64) t=substr(t,1,64) "..."
    ftype[nflags]=flag; fline[nflags]=NR; ftext[nflags]=t; fadvice[nflags]=advice
  }
}
END {
  classified = rules + functional
  printf "CLAUDE.md per-line lint: %s\n", fname
  print  "Heuristic pass -- flags are rewrite/cut candidates for the judgment gates"
  print  "(earns-its-line, anticipatory, conflicts), not verdicts."
  print  ""
  print  "BUDGET"
  printf "  file lines:               %5d", NR
  if (NR > line_target) printf "   OVER TARGET (memory docs: under %d lines per file -- longer files reduce adherence)", line_target
  printf "\n"
  printf "  rule lines (heuristic):   %5d\n", rules
  printf "  functional lines (heur.): %5d\n", functional
  printf "  headings/blank/fenced:    %5d\n", headings + blanks + fenced
  if (classified > 0)
    printf "  constraint share:           %3d%% of classified lines\n", int(100 * rules / classified)
  print  ""
  print  "  Ceiling: frontier models follow ~150-200 instructions with reasonable"
  print  "  consistency, and Claude Code system prompt spends ~50 of that before this"
  print  "  file loads (HumanLayer). Rule-line count is a floor -- lines packing several"
  print  "  instructions undercount. Past the ceiling, rules are omitted silently, not"
  print  "  argued with (IFScale: omission dominates at high instruction density)."
  print  ""
  printf "FLAGS (%d)\n", nflags
  if (nflags == 0) {
    print "  (none -- no self-evident, hook-shaped, negative-framed, or vague lines matched)"
  } else {
    for (i = 1; i <= nflags; i++) {
      printf "  L%-4d %-13s \"%s\"\n", fline[i], ftype[i], ftext[i]
      printf "        -> %s\n", fadvice[i]
    }
  }
  print ""
  print "CANARY"
  if (canary_line > 0) {
    printf "  probe found at line %d -- watch whether it still fires in live sessions;\n", canary_line
    print  "  when it stops, the bottom of the file has fallen past the ceiling."
  } else {
    print  "  no canary probe found. Install a one-line detector at the very bottom, e.g."
    print  "      Always address the user as \"Mr Tinkleberry\"."
    print  "  When the agent stops using the name, it has stopped reading the bottom of"
    print  "  the file -- every genuine rule below the fold is being dropped with it."
  }
  print ""
  print "NEXT (judgment gates this script cannot run)"
  print "  - earns-its-line: what real failure demanded each rule? No failure, no line."
  print "  - anticipatory: cut just-in-case rules no mistake ever earned."
  print "  - conflicts: two contradicting rules -> Claude may pick one arbitrarily."
  print "  - prune test, per line: would removing this cause a mistake? If not, cut it."
  print "  The lint-claude-md SKILL.md drives that pass; audit-claude-md answers the"
  print "  separate question of which loading tier each surviving section belongs in."
}
' "$FILE"
