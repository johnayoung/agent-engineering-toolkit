#!/usr/bin/env bash
# size-review-capacity.sh -- the reviewer-hours arithmetic from
# "Review Capacity Is the Real Ceiling on Your Agents"
# https://jyoung.dev/blog/review-capacity-agent-throughput/
#
# Every PR an agent opens is a claim on reviewer-hours you have not yet spent.
# This turns your numbers into the post's answer: attention per PR today, after
# the agents you want to add, and -- if you name your attention floor -- whether
# the addition clears your capacity or buys queue depth.
#
# Dependencies: coreutils + awk only.

set -euo pipefail

usage() {
  cat <<'EOF'
Usage: size-review-capacity.sh --reviewers N --prs-per-day P [options]

Required (both from your own telemetry):
  --reviewers N        people who actually review -- the fixed denominator
  --prs-per-day P      PRs/day currently arriving for review

Options:
  --hours H            focused review-hours per reviewer per day
                       (default: 3 -- the post's worked-example assumption; override)
  --add A              agents you are considering adding (default: 1; 0 = measure today only)
  --prs-per-agent Q    PRs/day each added agent opens
                       (default: 5 -- the post's worked-example assumption; override)
  --floor M            attention floor, minutes per PR: below this a reviewer cannot
                       actually reason about a change. No default -- name your own number.

Example (the post's six-reviewer scenario):
  size-review-capacity.sh --reviewers 6 --prs-per-day 30 --add 1 --floor 30
EOF
}

num_pos()    { awk -v v="$1" 'BEGIN { exit !(v ~ /^[0-9]+(\.[0-9]+)?$/ && v+0 > 0) }'; }
num_nonneg() { awk -v v="$1" 'BEGIN { exit !(v ~ /^[0-9]+(\.[0-9]+)?$/) }'; }

REVIEWERS="" PRS="" HOURS="3" ADD="1" PER_AGENT="5" FLOOR="0"
HOURS_DEFAULT=1 PER_AGENT_DEFAULT=1

need_value() {
  [ "$#" -ge 2 ] || { echo "error: $1 requires a value" >&2; usage >&2; exit 1; }
}

while [ "$#" -gt 0 ]; do
  case "$1" in
    --reviewers)     need_value "$@"; REVIEWERS="$2"; shift 2 ;;
    --prs-per-day)   need_value "$@"; PRS="$2"; shift 2 ;;
    --hours)         need_value "$@"; HOURS="$2"; HOURS_DEFAULT=0; shift 2 ;;
    --add)           need_value "$@"; ADD="$2"; shift 2 ;;
    --prs-per-agent) need_value "$@"; PER_AGENT="$2"; PER_AGENT_DEFAULT=0; shift 2 ;;
    --floor)         need_value "$@"; FLOOR="$2"; shift 2 ;;
    -h|--help)       usage; exit 0 ;;
    *)               echo "error: unknown flag: $1" >&2; usage >&2; exit 1 ;;
  esac
done

if [ -z "$REVIEWERS" ] || [ -z "$PRS" ]; then
  echo "error: --reviewers and --prs-per-day are required" >&2
  usage >&2
  exit 1
fi

num_pos "$REVIEWERS"    || { echo "error: --reviewers must be a positive number (got: $REVIEWERS)" >&2; exit 1; }
num_pos "$PRS"          || { echo "error: --prs-per-day must be a positive number (got: $PRS)" >&2; exit 1; }
num_pos "$HOURS"        || { echo "error: --hours must be a positive number (got: $HOURS)" >&2; exit 1; }
num_nonneg "$ADD"       || { echo "error: --add must be a non-negative number (got: $ADD)" >&2; exit 1; }
num_pos "$PER_AGENT"    || { echo "error: --prs-per-agent must be a positive number (got: $PER_AGENT)" >&2; exit 1; }
if [ "$FLOOR" != "0" ]; then
  num_pos "$FLOOR"      || { echo "error: --floor must be a positive number of minutes (got: $FLOOR)" >&2; exit 1; }
fi

awk -v r="$REVIEWERS" -v h="$HOURS" -v p="$PRS" -v a="$ADD" -v q="$PER_AGENT" -v f="$FLOOR" \
    -v hd="$HOURS_DEFAULT" -v qd="$PER_AGENT_DEFAULT" 'BEGIN {
  minutes   = r * h * 60
  att_now   = minutes / p
  p_after   = p + a * q
  att_after = minutes / p_after

  print "Reviewer-capacity math"
  print "(method: https://jyoung.dev/blog/review-capacity-agent-throughput/)"
  print ""
  print "  Inputs"
  printf "    reviewers                     %g\n", r
  if (hd) printf "    focused review-hours/day      %g per reviewer  (default: worked-example assumption -- override with --hours)\n", h
  else    printf "    focused review-hours/day      %g per reviewer\n", h
  printf "    incoming PRs/day              %g\n", p
  if (a > 0) {
    if (qd) printf "    proposed addition             %g agent(s) x %g PRs/day each  (rate is the default -- override with --prs-per-agent)\n", a, q
    else    printf "    proposed addition             %g agent(s) x %g PRs/day each\n", a, q
  }
  print ""
  print "  Today"
  printf "    reviewer-minutes/day          %g  (%g reviewer-hours)\n", minutes, r * h
  printf "    attention per PR              %.1f min\n", att_now
  if (a > 0) {
    print ""
    printf "  After adding %g agent(s)\n", a
    printf "    incoming PRs/day              %g\n", p_after
    printf "    attention per PR              %.1f min  (down %.1f min, -%.0f%%)\n", \
           att_after, att_now - att_after, (1 - att_after / att_now) * 100
  }
  print ""
  if (f > 0) {
    max_prs = minutes / f
    printf "  Floor check (your floor: %g min/PR)\n", f
    printf "    max absorbable                %.1f PRs/day at that floor\n", max_prs
    if (p > max_prs) {
      printf "    TODAY ALREADY EXCEEDS the floor by %.1f PRs/day. Attention per PR is below\n", p - max_prs
      print  "    the number you named before any new agent. Adding agents buys queue depth."
    } else {
      printf "    headroom today                %.1f PRs/day  (~%.1f agent(s) at %g PRs/day each)\n", \
             max_prs - p, (max_prs - p) / q, q
    }
    if (a > 0) {
      if (p_after <= max_prs) {
        printf "    verdict: the added agent(s) CLEAR the reviewer-hours math (%.1f PRs/day spare)\n", max_prs - p_after
      } else {
        printf "    verdict: the added agent(s) EXCEED capacity by %.1f PRs/day --\n", p_after - max_prs
        print  "    that is queue depth, not throughput."
      }
    }
  } else {
    print "  Floor check: skipped (no --floor). Name the minutes-per-PR below which a"
    print "  reviewer cannot actually reason about a change, then re-run with --floor M."
    print "  Past that crossover, every added agent produces queue depth, not shippable"
    print "  output."
  }
  print ""
  print "  Estimate caveats"
  print "    - Even-split heuristic: hours are divided uniformly across PRs. Risk-tiered"
  print "      triage (config bump vs payments path) changes the real draw of each PR."
  print "    - The denominator erodes: unbudgeted high-risk load burns out senior"
  print "      reviewers and shrinks reviewer-hours silently. Cap per-reviewer load."
  print ""
  print "  Next: run the six-gate scorecard in review-capacity-gates.md (same directory)."
}'
