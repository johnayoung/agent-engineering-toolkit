#!/usr/bin/env bash
# go-no-go.sh — the five-gate pre-delegation pass for AI coding agent tasks.
# From: "What AI Coding Agents Are Actually Good For (And When to Skip)"
# https://jyoung.dev/blog/what-ai-agents-are-actually-good-for/
#
# The pass short-circuits: the first failing gate is the verdict.
#
# Usage:
#   go-no-go.sh ["task description"]                      interactive
#   go-no-go.sh --answers y,2,n,y,y ["task description"]  non-interactive
#
# Answer order (trailing answers may be omitted once a gate fails):
#   1. y/n    a check the agent can run itself exists
#   2. 1|2|3  human estimate: 1 = under ~4 min, 2 = minutes to a few hours,
#             3 = more than a few hours
#   3. y/n    checking the output would cost more than writing it yourself
#   4. y/n    "done" is stateable as something verifiable
#   5. y/n    a wrong result is reversible AND cheap to detect
#
# Exit codes: 0 = DELEGATE, 1 = any no-go verdict, 2 = usage or input error.

set -euo pipefail

POST_URL="https://jyoung.dev/blog/what-ai-agents-are-actually-good-for/"

usage() {
  cat <<'EOF'
go-no-go.sh — five-gate pre-delegation pass for AI coding agent tasks.

Usage:
  go-no-go.sh ["task description"]                      interactive
  go-no-go.sh --answers y,2,n,y,y ["task description"]  non-interactive

Answer order (trailing answers may be omitted once a gate fails):
  1. y/n    a check the agent can run itself exists
  2. 1|2|3  human estimate: 1 = under ~4 min, 2 = minutes to a few hours,
            3 = more than a few hours
  3. y/n    checking the output would cost more than writing it yourself
  4. y/n    "done" is stateable as something verifiable
  5. y/n    a wrong result is reversible AND cheap to detect

Exit codes: 0 = DELEGATE, 1 = any no-go verdict, 2 = usage or input error.
EOF
}

TASK=""
NONINT=0
ANSWERS=()
AIDX=0

while [ $# -gt 0 ]; do
  case "$1" in
    --answers)
      [ $# -ge 2 ] || { echo "error: --answers needs a comma-separated value" >&2; exit 2; }
      IFS=',' read -r -a ANSWERS <<< "$2"
      NONINT=1
      shift 2
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    -*)
      echo "error: unknown flag: $1" >&2
      usage >&2
      exit 2
      ;;
    *)
      TASK="$1"
      shift
      ;;
  esac
done

get_answer() { # $1 = prompt; sets RAW (lowercased, whitespace-stripped)
  local ans
  if [ "$NONINT" -eq 1 ]; then
    if [ "$AIDX" -ge "${#ANSWERS[@]}" ]; then
      echo "error: --answers exhausted before a verdict was reached" >&2
      exit 2
    fi
    ans="${ANSWERS[$AIDX]}"
    AIDX=$((AIDX + 1))
    printf '%s %s\n' "$1" "$ans"
  else
    printf '%s ' "$1"
    if ! IFS= read -r ans; then
      printf '\n'
      echo "error: input ended before a verdict was reached" >&2
      exit 2
    fi
  fi
  RAW=$(printf '%s' "$ans" | tr '[:upper:]' '[:lower:]' | tr -d '[:space:]')
}

ask_yn() { # $1 = prompt; sets YN to y or n
  while :; do
    get_answer "$1 [y/n]"
    case "$RAW" in
      y|yes) YN=y; return 0 ;;
      n|no)  YN=n; return 0 ;;
    esac
    if [ "$NONINT" -eq 1 ]; then
      echo "error: invalid answer '$RAW' (expected y or n)" >&2
      exit 2
    fi
    echo "  expected y or n."
  done
}

ask_band() { # $1 = prompt; sets BAND to 1, 2, or 3
  while :; do
    get_answer "$1 [1/2/3]"
    case "$RAW" in
      1|2|3) BAND="$RAW"; return 0 ;;
    esac
    if [ "$NONINT" -eq 1 ]; then
      echo "error: invalid answer '$RAW' (expected 1, 2, or 3)" >&2
      exit 2
    fi
    echo "  expected 1, 2, or 3."
  done
}

footer() {
  cat <<EOF

The percentages above are measured findings from the post's cited
sources (METR, Anthropic, Osmani), not guarantees about your task.
Grounding: $POST_URL
EOF
}

echo "THE GO / NO-GO PASS — run before you write the prompt"
if [ -n "$TASK" ]; then
  echo "Task: $TASK"
fi
echo

BAND_NOTE=""

# --- Gate 1: closed loop -----------------------------------------------------
echo "Gate 1 — closed loop (bounded, verifiable work)"
ask_yn "  Is there a check the agent can run itself (test suite / build / lint / diff-against-fixture)?"
if [ "$YN" = n ]; then
  cat <<'EOF'

VERDICT: KEEP IT — failed gate 1 (no closed loop).
No runnable check means no closed loop: the agent cannot iterate on a
result it cannot read, and every mistake waits for you to notice it.
Without a check you are not delegating bounded work — you are handing
yourself an unreviewed diff.
EOF
  footer
  exit 1
fi
echo

# --- Gate 2: the reliability cliff -------------------------------------------
echo "Gate 2 — the reliability cliff (human-time estimate)"
echo "  How long would this take a competent human?"
echo "    1 = under ~4 minutes   2 = minutes to a few hours   3 = more than a few hours"
ask_band "  Estimate:"
if [ "$BAND" = 3 ]; then
  cat <<'EOF'

VERDICT: DECOMPOSE OR KEEP IT — failed gate 2 (the reliability cliff).
METR measured near-100% agent success on tasks taking humans under
~4 minutes and <10% on tasks past ~4 hours. Handing a multi-hour task
over whole is betting against a <10% success rate. Split it into
sub-hour, independently verifiable pieces, or keep it yourself.
EOF
  footer
  exit 1
fi
case "$BAND" in
  1) BAND_NOTE="Band note: under ~4 minutes of human time is the near-100% success band (METR)." ;;
  2) BAND_NOTE="Band note: minutes-to-hours is the reliability downslope — keep the verification check tight (METR)." ;;
esac
echo

# --- Gate 3: the verification tax --------------------------------------------
echo "Gate 3 — the verification tax"
ask_yn "  Would checking the output cost more than writing it yourself (e.g. you'd have to reconstruct the context to verify it)?"
if [ "$YN" = y ]; then
  cat <<'EOF'

VERDICT: WRITE IT YOURSELF — failed gate 3 (the verification tax).
When proving the diff correct costs more than authoring it, delegation
is not a shortcut — it is a detour with a review bill at the end. In
survey data Osmani cites, 38% of developers already find reviewing
AI-generated logic harder than reviewing human-written code.
EOF
  footer
  exit 1
fi
echo

# --- Gate 4: verifiable "done" -----------------------------------------------
echo "Gate 4 — verifiable \"done\" (vague / taste / hidden context)"
ask_yn "  Can you state \"done\" as something verifiable — not taste, not judgment, not context that lives only in your head?"
if [ "$YN" = n ]; then
  cat <<'EOF'

VERDICT: KEEP IT — failed gate 4 (no verifiable "done").
A goal you can't verify is a goal the agent will complete in a
direction you didn't mean. On real high-context work, METR measured
developers taking 19% LONGER with AI while believing they were ~20%
faster — so this call has to be made by rule, not by feel.
EOF
  footer
  exit 1
fi
echo

# --- Gate 5: blast radius ----------------------------------------------------
echo "Gate 5 — blast radius (irreversible, hard to catch)"
ask_yn "  If a wrong result slips through uncaught, is the action reversible AND cheap to detect?"
if [ "$YN" = n ]; then
  cat <<'EOF'

VERDICT: YOUR HANDS — failed gate 5 (blast radius).
Irreversible plus hard-to-catch overrides every gate above. Anthropic
measured only 0.8% of real agent actions as irreversible — and that
rarity is exactly why this gate needs its own stop: the base rate lulls
you, and the consequences of the single error can still be significant.
Do the irreversible step yourself, however clean the task scored above.
EOF
  footer
  exit 1
fi

# --- All gates passed ----------------------------------------------------------
cat <<'EOF'

VERDICT: DELEGATE — all five gates passed.
This task sits in the cheap-to-verify, easy-to-undo quadrant. Put the
verification command in the prompt and require evidence over assertion:
the test output, the command run and what it returned.
EOF
if [ -n "$BAND_NOTE" ]; then
  echo "$BAND_NOTE"
fi
cat <<'EOF'
The gates decide what you delegate. Judgment still decides what you
accept — expect to reject weak attempts before taking one.
EOF
footer
exit 0
