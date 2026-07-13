#!/usr/bin/env bash
# ownership-cost-gate.sh — walk one build-vs-buy candidate through the five-gate
# ownership-cost flowchart from https://jyoung.dev/blog/build-vs-buy-agentic-ai/
#
# Gates, in order (cheap eliminations first):
#   1. OWNERSHIP COST   2. DIFFERENTIATION   3. CONTINUOUS VERIFICATION
#   4. COMPLIANCE-AS-PRODUCT   5. BASE RATE
# The first failing gate stops the walk with a BUY verdict; clearing all five
# is BUILD. Run it once per SLICE of the tool — the strategic core and the
# platform it runs in are different candidates and usually get opposite verdicts.
#
# Interactive when answers are not supplied as flags; fully scriptable with
# flags. Zero dependencies beyond coreutils + awk.

set -euo pipefail

usage() {
  cat <<'EOF'
Usage: ownership-cost-gate.sh [options]

Walks ONE slice of a build candidate through the five gates. Any gate answer
not supplied as a flag is asked interactively; without a terminal, missing
answers are an error.

Options:
  --candidate NAME          Label for the slice under decision (e.g. "triage rules")
  --estimate N              First-build estimate, a number (e.g. 3, or 150000)
  --unit UNIT               Unit for the estimate (default: engineer-months)
  --staff-tail yes|no       Gate 1: would you staff the maintenance tail for five years?
  --differentiating yes|no  Gate 2: is this the strategic slice competitors can't hand you?
  --verifiable yes|no       Gate 3a: can a test/log/metric confirm it's still correct on
                            every change, cheaply?
  --regression-day yes|no   Gate 3b: would you catch a silent regression within a day?
  --compliance yes|no       Gate 4: is the real deliverable audit trails, uptime,
                            regulatory evidence?
  --beats-base-rate yes|no  Gate 5: does the gate-3 verification story beat the
                            internal-build base rate (~1/3 the success rate of bought tools)?
  -h, --help                Show this help.

Example (the post's claims-triage rules slice, non-interactive):
  ownership-cost-gate.sh --candidate "triage rules" --estimate 3 \
    --staff-tail yes --differentiating yes --verifiable yes \
    --regression-day yes --compliance no --beats-base-rate yes
EOF
}

CANDIDATE="candidate slice"
ESTIMATE=""
UNIT="engineer-months"
A_STAFF="" A_DIFF="" A_VERIF="" A_REGR="" A_COMPL="" A_BASE=""

while [[ $# -gt 0 ]]; do
  case "$1" in
    --candidate)       CANDIDATE="${2:?--candidate needs a value}"; shift 2 ;;
    --estimate)        ESTIMATE="${2:?--estimate needs a value}"; shift 2 ;;
    --unit)            UNIT="${2:?--unit needs a value}"; shift 2 ;;
    --staff-tail)      A_STAFF="${2:?--staff-tail needs yes|no}"; shift 2 ;;
    --differentiating) A_DIFF="${2:?--differentiating needs yes|no}"; shift 2 ;;
    --verifiable)      A_VERIF="${2:?--verifiable needs yes|no}"; shift 2 ;;
    --regression-day)  A_REGR="${2:?--regression-day needs yes|no}"; shift 2 ;;
    --compliance)      A_COMPL="${2:?--compliance needs yes|no}"; shift 2 ;;
    --beats-base-rate) A_BASE="${2:?--beats-base-rate needs yes|no}"; shift 2 ;;
    -h|--help)         usage; exit 0 ;;
    *) echo "error: unknown option '$1' (see --help)" >&2; exit 2 ;;
  esac
done

lower() { printf '%s' "$1" | tr '[:upper:]' '[:lower:]'; }

# ask_yn <preset> <prompt> -> sets ASK_RESULT to yes|no
ASK_RESULT=""
ask_yn() {
  local preset="$1" prompt="$2" ans
  if [[ -n "$preset" ]]; then
    case "$(lower "$preset")" in
      y|yes) ASK_RESULT="yes" ;;
      n|no)  ASK_RESULT="no" ;;
      *) echo "error: expected yes|no, got '$preset'" >&2; exit 2 ;;
    esac
    printf '   Q: %s -> %s\n' "$prompt" "$ASK_RESULT"
    return
  fi
  if [[ ! -t 0 ]]; then
    echo "error: no terminal and no flag supplied for: \"$prompt\" (see --help)" >&2
    exit 2
  fi
  while true; do
    read -r -p "   Q: $prompt [y/n] " ans
    case "$(lower "$ans")" in
      y|yes) ASK_RESULT="yes"; return ;;
      n|no)  ASK_RESULT="no"; return ;;
      *) echo "      answer y or n." ;;
    esac
  done
}

# First-build estimate: needed for the gate-1 math.
if [[ -z "$ESTIMATE" ]]; then
  if [[ -t 0 ]]; then
    read -r -p "First-build estimate (a number, in $UNIT): " ESTIMATE
  else
    echo "error: --estimate is required when not running interactively" >&2
    exit 2
  fi
fi
if ! printf '%s' "$ESTIMATE" | grep -Eq '^[0-9]+([.][0-9]+)?$'; then
  echo "error: --estimate must be a plain number, got '$ESTIMATE'" >&2
  exit 2
fi

calc() { awk -v e="$ESTIMATE" -v f="$1" 'BEGIN{v=e*f; if (v>=100) printf "%.0f", v; else printf "%.1f", v}'; }
TAIL=$(calc 1.5)     # maintenance = 60% of lifecycle = 1.5x the 40% build
ENH=$(calc 0.9)      # 60% of the tail: changing-requirements enhancements
MIG=$(calc 0.345)    # 23% of the tail: migration
BUG=$(calc 0.255)    # 17% of the tail: bug fixes
TOTAL=$(calc 2.5)    # build + tail

buy() {
  local gate="$1" reason="$2"
  echo
  echo "VERDICT: BUY — stopped at gate $gate."
  echo "   $reason"
  echo
  echo "   A tool is rarely one slice. If another slice of it is strategic and"
  echo "   verifiable, run the gate again on that slice alone."
  echo
  echo "Flowchart and sources: https://jyoung.dev/blog/build-vs-buy-agentic-ai/"
  exit 0
}

echo "OWNERSHIP-COST GATE"
echo "Candidate: $CANDIDATE"
echo "(run once per slice — strategic core and surrounding platform are"
echo " different candidates and usually get opposite verdicts)"
echo

echo "GATE 1 / OWNERSHIP COST"
echo "   First-build estimate:      $ESTIMATE $UNIT  (the cheap 40% of lifecycle)"
echo "   Maintenance tail (~1.5x):  ~$TAIL $UNIT, of which:"
echo "     changing-requirements enhancements (60%): ~$ENH"
echo "     migration                          (23%): ~$MIG"
echo "     bug fixes                          (17%): ~$BUG"
echo "   Lifetime total:            ~$TOTAL $UNIT"
echo "   83% of the tail is new work, not warranty repair."
echo "   [directional: the 60/60 figures are cross-system lifecycle averages"
echo "    (Wood, O'Reilly), not a measurement of your system]"
echo "   If agents will write most of the code, budget a review-and-refactor tax"
echo "   on top: refactoring fell from 25% to under 10% of changed lines while"
echo "   clones rose 8.3% -> 12.3% (GitClear), and +25% AI adoption tracks with"
echo "   throughput -1.5% and delivery stability -7.2% (DORA 2024 via RedMonk)."
ask_yn "$A_STAFF" "Would you staff that tail for the next five years?"
[[ "$ASK_RESULT" == "no" ]] && buy 1 "You priced the demo, not the ownership. The tail exists whether or not the code was clean."
echo

echo "GATE 2 / DIFFERENTIATION"
echo "   Utility (queues, runtime, plumbing) differentiates you from no one and"
echo "   adds maintenance tail for nothing; strategic functions are the ones you"
echo "   don't want to share with competitors (Fowler). The line moves: strategic"
echo "   decays to utility over time."
ask_yn "$A_DIFF" "Is this the strategic slice competitors can't hand you?"
[[ "$ASK_RESULT" == "no" ]] && buy 2 "It's utility. Buy or rent that layer and spend the engineers on the slice that differentiates."
echo

echo "GATE 3 / CONTINUOUS VERIFICATION"
echo "   Differentiation alone doesn't earn a build. 'Done' must be expressible"
echo "   as assertions that run on every change, cheaply."
ask_yn "$A_VERIF" "Can a test, log, or metric confirm it's still correct on every change, cheaply?"
[[ "$ASK_RESULT" == "no" ]] && buy 3 "Differentiation without verification is owning it blind — the maintenance tail with no early-warning system attached."
ask_yn "$A_REGR" "Would you catch a silent regression within a day?"
[[ "$ASK_RESULT" == "no" ]] && buy 3 "If a regression only surfaces when a customer is hit in production, you cannot afford to own this."
echo

echo "GATE 4 / COMPLIANCE-AS-PRODUCT"
echo "   If the real deliverable is audit trails, uptime, and regulatory evidence,"
echo "   it's a regulated standard application: Buy is the primary option; Make"
echo "   only peripheral, low-risk modules (Klotz)."
ask_yn "$A_COMPL" "Is the real deliverable audit trails, uptime, regulatory evidence?"
[[ "$ASK_RESULT" == "yes" ]] && buy 4 "You'd be signing up to own a multi-year compliance surface, not a feature. Directionally, an internal regulated platform runs ~\$1.4M in year one, 2-3 FTEs, 12-18 months to first use case (GitLab — vendor-authored, treat as directional)."
echo

echo "GATE 5 / BASE RATE"
echo "   Bought tools and partnerships succeed ~67% of the time; internal builds"
echo "   succeed about one-third as often (MIT NANDA, via Fortune). And AI's edge"
echo "   is smallest on the mature codebase you'll own: experienced devs were 19%"
echo "   SLOWER with AI on repos they knew deeply (METR)."
ask_yn "$A_BASE" "Does your gate-3 verification story beat that base rate?"
[[ "$ASK_RESULT" == "no" ]] && buy 5 "Your build is below the market default. The demo is evidence about the easiest 40%, not the tail."
echo

echo "VERDICT: BUILD this slice."
echo "   It is strategic, continuously verifiable, not a compliance surface, and"
echo "   carries a verification story that beats the internal-build base rate."
echo "   Buy the slices that failed earlier gates: build the small strategic core"
echo "   you can verify, and buy the expensive tail you'd only own blind."
echo
echo "Flowchart and sources: https://jyoung.dev/blog/build-vs-buy-agentic-ai/"
