#!/usr/bin/env bash
# check-diff-size.sh — measure a git diff against the PR-sizing research thresholds.
#
# Thresholds (sources in the post: https://jyoung.dev/blog/how-to-size-tasks-for-ai-coding-agents/):
#   - <=200 changed lines: review-quality target (Google research via EM Tools)
#   - 400: soft limit / 600: hard limit used by high-performing teams (EM Tools, Augment Code)
#   - 200-400-line PRs show 40% fewer defects; >1,000-line PRs 70% lower defect
#     detection, across 50,000+ PRs (Propel)
#   - ~2-5 files changed per task: the post author's translation for a layered Go
#     codebase — a heuristic, not researched; varies by language and architecture
#
# Usage:
#   check-diff-size.sh                    # working tree vs HEAD
#   check-diff-size.sh --staged           # staged changes only
#   check-diff-size.sh main..HEAD         # any git diff range
#   check-diff-size.sh HEAD~1             # last commit's diff
#   check-diff-size.sh -C /path/to/repo [range|--staged]
#
# Exit codes: 0 at/under the 400 soft limit, 1 over soft, 2 over the 600 hard limit.

set -euo pipefail

REPO="."
RANGE=""
STAGED=0

while [ $# -gt 0 ]; do
  case "$1" in
    -C) REPO="${2:?-C requires a directory}"; shift 2 ;;
    --staged|--cached) STAGED=1; shift ;;
    -h|--help) sed -n '2,21p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
    -*) echo "unknown flag: $1" >&2; exit 64 ;;
    *) RANGE="$1"; shift ;;
  esac
done

git -C "$REPO" rev-parse --git-dir >/dev/null 2>&1 || { echo "not a git repo: $REPO" >&2; exit 64; }

if [ "$STAGED" -eq 1 ]; then
  DESC="staged changes"
  NUMSTAT=$(git -C "$REPO" diff --cached --numstat)
elif [ -n "$RANGE" ]; then
  DESC="diff $RANGE"
  NUMSTAT=$(git -C "$REPO" diff --numstat "$RANGE")
else
  DESC="working tree vs HEAD"
  NUMSTAT=$(git -C "$REPO" diff --numstat HEAD)
fi

if [ -z "$NUMSTAT" ]; then
  echo "diff size check: $DESC — empty diff, nothing to measure."
  exit 0
fi

TOTALS=$(printf '%s\n' "$NUMSTAT" | awk '
  $1 == "-" || $2 == "-" { bin++; files++; next }
  { loc += $1 + $2; files++ }
  END { printf "%d %d %d", loc+0, files+0, bin+0 }')
LOC=$(echo "$TOTALS" | cut -d' ' -f1)
FILES=$(echo "$TOTALS" | cut -d' ' -f2)
BINARY=$(echo "$TOTALS" | cut -d' ' -f3)

echo "diff size check: $DESC (repo: $(cd "$REPO" && pwd))"
echo
printf '  changed lines (added+deleted): %d\n' "$LOC"
printf '  files changed:                 %d\n' "$FILES"
[ "$BINARY" -gt 0 ] && printf '  binary files (excluded from line count): %d\n' "$BINARY" || true

echo
echo "LARGEST FILES BY CHURN"
printf '%s\n' "$NUMSTAT" | awk '$1 != "-" && $2 != "-" { printf "%8d  %s\n", $1+$2, $3 }' \
  | sort -rn | head -5 | sed 's/^/  /'
GEN=$(printf '%s\n' "$NUMSTAT" | { grep -icE '(lock|generated|\.pb\.|\.gen\.|_gen\.|package-lock|yarn.lock|go\.sum)' || true; })
[ "$GEN" -gt 0 ] && echo "  NOTE: $GEN file(s) look generated/lockfile — consider excluding them mentally; the research thresholds are about human review effort." || true

echo
echo "VERDICT (line thresholds from PR-review research; see header for sources)"
EXIT=0
if [ "$LOC" -le 200 ]; then
  echo "  WITHIN TARGET: $LOC lines <= 200. Review quality holds; ~5 minutes to review in one pass."
elif [ "$LOC" -le 400 ]; then
  echo "  ABOVE TARGET, WITHIN SOFT LIMIT: $LOC lines. The 200-400 band still shows 40% fewer"
  echo "  defects than larger PRs, but each additional 100 lines adds ~25 minutes of review time."
  EXIT=1
elif [ "$LOC" -le 600 ]; then
  echo "  OVER SOFT LIMIT (400): $LOC lines. High-performing teams split here. Next time, split"
  echo "  the task along layer boundaries before handing it to the agent."
  EXIT=1
else
  echo "  OVER HARD LIMIT (600): $LOC lines. This should be split — PRs over 1,000 lines show"
  echo "  70% lower defect detection rates. Decompose along layer boundaries."
  EXIT=2
fi

if [ "$FILES" -gt 5 ]; then
  echo "  FILES: $FILES changed — above the ~2-5 band for a single agent task. (That band is the"
  echo "  post author's translation for a layered Go codebase, not a researched number; smaller-file"
  echo "  ecosystems like React legitimately touch more files for fewer lines.)"
else
  echo "  FILES: $FILES changed — inside the ~2-5 heuristic band (author's judgment, varies by stack)."
fi

echo
echo "This script measures the mechanical half only. The judgment gates — can you describe the"
echo "diff in one sentence, can it be verified in isolation, does it cross layers, is it above"
echo "the do-it-manually floor — are in the size-agent-task SKILL.md and the post:"
echo "https://jyoung.dev/blog/how-to-size-tasks-for-ai-coding-agents/"

exit "$EXIT"
