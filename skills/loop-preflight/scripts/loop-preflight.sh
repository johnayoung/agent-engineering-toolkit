#!/usr/bin/env bash
# loop-preflight.sh -- preflight a Ralph-style unattended agent loop before walking away.
#
# A single prompt has two things a loop does not: a natural end, and a memory that
# lasts exactly as long as the task. An unattended loop needs both built in:
#   stop spec : (1) max-iteration ceiling  (2) no-progress detection  (3) spend/wall-clock ceiling
#   state     : (4) a progress file on disk that survives the window reset
#   verify    : (5) a check the model does not self-grade
# plus an accounting of the always-on context (CLAUDE.md, PROMPT.md) re-paid every turn.
#
# Full argument: https://jyoung.dev/blog/loop-engineering-breaks-your-playbook/
#
# Usage: loop-preflight.sh <loop-script> [repo-dir]   (repo-dir default: the loop script's dir)
# Exit:  0 = no MISSING guards recognized; 1 = at least one MISSING; 2 = usage error.
#
# Honesty note: every check is a pattern grep. MISSING means "no recognizable pattern
# found in the wrapper," not proof the guard is absent. Token figures are chars/4
# estimates; Claude's own accounting will differ.

set -euo pipefail

if [ $# -lt 1 ] || [ ! -f "${1:-}" ]; then
  echo "usage: loop-preflight.sh <loop-script> [repo-dir]" >&2
  exit 2
fi
LOOP=$(cd "$(dirname "$1")" && pwd)/$(basename "$1")
REPO=$(cd "${2:-$(dirname "$LOOP")}" && pwd)

# Full-line comments do not count as guards -- a brake in a comment is not a brake.
STRIPPED=$(mktemp /tmp/loop-preflight.XXXXXX)
trap 'rm -f "$STRIPPED"' EXIT
grep -v '^[[:space:]]*#' "$LOOP" > "$STRIPPED" || true

OK_N=0; MISS_N=0; REV_N=0
row() { # status label detail
  case "$1" in
    OK)      OK_N=$((OK_N + 1)) ;;
    MISSING) MISS_N=$((MISS_N + 1)) ;;
    REVIEW)  REV_N=$((REV_N + 1)) ;;
  esac
  printf '  [%-7s] %-26s %s\n' "$1" "$2" "$3"
}
found()  { grep -Eiq "$1" "$STRIPPED"; }
detail() { { grep -oEim1 "$1" "$STRIPPED" || true; } | head -1; }

echo "loop-preflight: $LOOP"
echo "repo:           $REPO"
echo

# --- stop spec ------------------------------------------------------------------
echo "STOP SPEC -- the three brakes an unattended loop needs"

BOUND_RE='seq[[:space:]]+[0-9]|\{1\.\.[0-9]+\}|max[-_]?(iter|turn)'
UNBOUND_RE='while[[:space:]]+(:|true)([[:space:]]*;|[[:space:]]|$)|until[[:space:]]+false'
if found "$BOUND_RE"; then
  row OK "max-iteration ceiling" "found: '$(detail "$BOUND_RE")'"
elif found "$UNBOUND_RE"; then
  row MISSING "max-iteration ceiling" "unbounded '$(detail "$UNBOUND_RE")' with no cap pattern -- give the loop an upper bound"
else
  row REVIEW "max-iteration ceiling" "no loop-bound pattern recognized -- confirm by reading the wrapper"
fi

NOPROG_RE='\|\|[[:space:]]*break|git diff --quiet|git status --porcelain|--exit-code|no[-_]?progress'
if found "$NOPROG_RE"; then
  row OK "no-progress detection" "found: '$(detail "$NOPROG_RE")'"
else
  row MISSING "no-progress detection" "no halt-on-no-change pattern -- e.g. 'git commit ... || break' stops a pass that changed nothing"
fi

SPEND_RE='timeout[[:space:]]+[0-9"$]|budget|max[-_]?cost|cost[-_]?limit|spend|SECONDS|date \+%s'
if found "$SPEND_RE"; then
  row OK "spend/wall-clock ceiling" "found: '$(detail "$SPEND_RE")'"
else
  row MISSING "spend/wall-clock ceiling" "no budget or timeout pattern -- wrap the run in 'timeout' or a token/dollar cap that kills it"
fi

# --- state ----------------------------------------------------------------------
echo
echo "STATE -- what survives the window reset"
STATE_RE='[A-Za-z0-9_./-]*(progress|state|memory|plan)[A-Za-z0-9_.-]*\.(txt|md|json|log)'
if found "$STATE_RE"; then
  row OK "externalized state file" "found: '$(detail "$STATE_RE")' -- the agent forgets; the repo doesn't"
else
  row MISSING "externalized state file" "no progress/state file referenced -- write one and reload it each turn; it is what survives a window reset"
fi

# --- verification -----------------------------------------------------------------
echo
echo "VERIFICATION -- the check the model doesn't self-grade"
VERIFY_RE='run_checks|[A-Za-z0-9_./-]*check[A-Za-z0-9_.-]*\.sh|npm (run )?test|pnpm test|yarn test|pytest|go test|cargo (test|check|clippy)|make (test|check|lint|ci)|mix test|tox|rspec|mvn (test|verify)|gradle test|ci\.sh'
if found "$VERIFY_RE"; then
  row OK "programmatic check in loop" "found: '$(detail "$VERIFY_RE")'"
else
  row REVIEW "programmatic check in loop" "no check runner recognized in the wrapper -- if verification lives only in the prompt, the model grades its own work"
fi

# --- per-iteration context tax -----------------------------------------------------
echo
echo "PER-ITERATION CONTEXT TAX -- always-on files re-paid every turn"

ITERS=""
n=$( { grep -oEim1 'seq[[:space:]]+1[[:space:]]+[0-9]+' "$STRIPPED" || true; } | { grep -oE '[0-9]+$' || true; } )
if [ -n "$n" ]; then ITERS="$n"; fi
if [ -z "$ITERS" ]; then
  n=$( { grep -oEm1 '\{1\.\.[0-9]+\}' "$STRIPPED" || true; } | { grep -oE '[0-9]+' || true; } | tail -1 )
  if [ -n "$n" ]; then ITERS="$n"; fi
fi
if [ -z "$ITERS" ]; then
  n=$( { grep -oEim1 'max[-_]?(iters?|turns?)[^0-9]{0,6}[0-9]+' "$STRIPPED" || true; } | { grep -oE '[0-9]+$' || true; } )
  if [ -n "$n" ]; then ITERS="$n"; fi
fi
ITER_NOTE="detected cap"
if [ -z "$ITERS" ]; then
  ITERS=50
  ITER_NOTE="no literal cap found; 50 is the post's illustrative turn count"
fi

CANDS=$( { printf 'CLAUDE.md\n'; grep -oE '[A-Za-z0-9_./~-]+\.(md|txt)' "$STRIPPED" || true; } | sort -u)
FOUND_ANY=0
printf '  %-40s %8s %10s %16s\n' "file" "lines" "~tokens" "~tokens x $ITERS"
while IFS= read -r c; do
  [ -z "$c" ] && continue
  case "$c" in
    /*)   path="$c" ;;
    "~"*) path="${HOME}${c#\~}" ;;
    *)    path="$REPO/$c" ;;
  esac
  [ -f "$path" ] || continue
  FOUND_ANY=1
  lines=$(wc -l < "$path"); chars=$(wc -c < "$path"); tokens=$((chars / 4))
  printf '  %-40s %8d %10d %16d\n' "$c" "$lines" "$tokens" "$((tokens * ITERS))"
done <<EOF
$CANDS
EOF
if [ "$FOUND_ANY" -eq 0 ]; then
  echo "  (no CLAUDE.md or referenced .md/.txt files found under $REPO)"
fi
echo "  Iterations = $ITERS ($ITER_NOTE). Tokens are chars/4 estimates. CLAUDE.md is"
echo "  loaded implicitly by Claude Code-style agents; state files grow during the run,"
echo "  so their figure is size-now, a floor. A single invocation pays this once; the"
echo "  loop re-pays it every turn with its own output stacking on top (context rot"
echo "  compounds). No hard line target here -- the rule is presentation over presence:"
echo "  cut and order for how the file reads on turn $ITERS, not for turn 1."

# --- summary -----------------------------------------------------------------------
echo
if [ "$MISS_N" -gt 0 ]; then
  VERDICT="not ready to run unattended"
else
  VERDICT="no missing guards recognized"
fi
echo "SUMMARY: $OK_N ok, $MISS_N missing, $REV_N review -- $VERDICT."
echo "Every check is a pattern grep: MISSING means no recognizable pattern was found,"
echo "not proof the guard is absent. Confirm by reading the wrapper."
echo "Fix reference (the hardened loop): https://jyoung.dev/blog/loop-engineering-breaks-your-playbook/"
if [ "$MISS_N" -gt 0 ]; then
  exit 1
fi
exit 0
