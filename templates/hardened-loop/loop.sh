#!/usr/bin/env bash
# loop.sh: a hardened agent loop. Run it inside a container; every call
# skips permission prompts. Every exit names the control that fired.
set -uo pipefail

MAX_ITERATIONS="${MAX_ITERATIONS:-20}"    # outer cap; a number, never 0 = unlimited
MAX_TURNS="${MAX_TURNS:-40}"              # per call: tool turns + 1 for the final response
CALL_BUDGET="${CALL_BUDGET:-4.00}"        # per call, checked after each response lands
SPEND_CEILING="${SPEND_CEILING:-40.00}"   # whole run; keep it under MAX_ITERATIONS * CALL_BUDGET
ITER_TIMEOUT="${ITER_TIMEOUT:-45m}"       # wall clock per iteration
NO_PROGRESS_LIMIT="${NO_PROGRESS_LIMIT:-3}"
GATE_CMD="${GATE_CMD:-pytest -q}"         # runs test ids from /gate/tests, mounted read-only
PROMPT_FILE="${PROMPT_FILE:-PROMPT.md}"
LOOP_DIR=.loop

for bin in claude git jq timeout awk; do
  command -v "$bin" >/dev/null || { echo "loop.sh: missing $bin" >&2; exit 2; }
done
[ "$MAX_ITERATIONS" -gt 0 ] || { echo "loop.sh: MAX_ITERATIONS must be > 0" >&2; exit 2; }
git cat-file -e HEAD:features.json 2>/dev/null || { echo "loop.sh: commit features.json first" >&2; exit 2; }
git show HEAD:features.json | jq -e 'type == "array" and all(.[]; .test | type == "string" and test("^\\S+$"))' >/dev/null 2>&1 \
  || { echo "loop.sh: every feature in features.json needs a test id without spaces" >&2; exit 2; }

mkdir -p "$LOOP_DIR/logs"
touch "$LOOP_DIR/spend.log" progress.txt
EXCLUDE="$(git rev-parse --git-path info/exclude)"
mkdir -p "$(dirname "$EXCLUDE")"
grep -qxF "$LOOP_DIR/" "$EXCLUDE" 2>/dev/null || echo "$LOOP_DIR/" >> "$EXCLUDE"

ITERATION=0
NO_PROGRESS=0
CHILD=""
SPENT=0                               # the ledger lives here; spend.log is its record
BASE=$(git rev-parse 'HEAD^{tree}')   # last tree the wrapper checked; agent commits can't move it

note()  { printf '%s [loop.sh] %s\n' "$(date -u +%FT%TZ)" "$*" >> progress.txt; }
spent() { awk -v s="$SPENT" 'BEGIN { printf "%.2f", s }'; }
over_ceiling() { awk -v s="$SPENT" -v c="$SPEND_CEILING" 'BEGIN { exit !(s + 0 >= c + 0) }'; }
stop() {
  note "stopped by $1 after $ITERATION iteration(s), spend \$$(spent)"
  echo "loop.sh: stopped by $1 after $ITERATION iteration(s), spend \$$(spent)" >&2
  exit "${2:-1}"
}

on_kill() {
  if [ -n "$CHILD" ]; then kill "$CHILD" 2>/dev/null; wait "$CHILD" 2>/dev/null; fi
  note "killed during iteration $ITERATION; partial work committed as 'loop: iteration $ITERATION interrupted'"
  git add -A && git commit -q -m "loop: iteration $ITERATION interrupted" >/dev/null
  exit 130
}
trap on_kill INT TERM HUP

only_flags_changed() {
  diff -q <(git show "$BASE:features.json" | jq -S 'map(del(.passes))') \
          <(jq -S 'map(del(.passes))' features.json 2>/dev/null) >/dev/null
}

gate_ok() {
  local ids
  ids=$(jq -r '.[] | select(.passes) | .test' features.json)
  [ -z "$ids" ] && return 0
  # shellcheck disable=SC2086
  $GATE_CMD $ids > "$LOOP_DIR/logs/gate-$ITERATION.log" 2>&1
}

while [ "$ITERATION" -lt "$MAX_ITERATIONS" ]; do
  ITERATION=$((ITERATION + 1))
  out="$LOOP_DIR/logs/iter-$ITERATION.json"
  mkdir -p "$LOOP_DIR/logs"

  timeout -k 5s "$ITER_TIMEOUT" claude -p "$(cat "$PROMPT_FILE")" \
    --dangerously-skip-permissions \
    --max-turns "$MAX_TURNS" \
    --max-budget-usd "$CALL_BUDGET" \
    --output-format json > "$out" < /dev/null &
  CHILD=$!
  wait "$CHILD"; rc=$?
  CHILD=""

  cost=$(jq -r '.total_cost_usd | numbers | select(. >= 0)' "$out" 2>/dev/null | tail -n 1)
  [ -n "$cost" ] || { cost=$CALL_BUDGET; note "iteration $ITERATION reported no cost; charged CALL_BUDGET (\$$CALL_BUDGET)"; }
  printf '%s\t%s\n' "$ITERATION" "$cost" >> "$LOOP_DIR/spend.log"
  SPENT=$(awk -v s="$SPENT" -v c="$cost" 'BEGIN { printf "%.6f", s + c }')
  subtype=$(jq -r '.subtype // empty' "$out" 2>/dev/null | tail -n 1)

  case "$rc" in
    0)   ;;
    124) note "iteration $ITERATION hit ITER_TIMEOUT ($ITER_TIMEOUT)" ;;
    *)   note "iteration $ITERATION: claude exited $rc (${subtype:-no result})" ;;
  esac

  if ! only_flags_changed; then
    git checkout -q "$BASE" -- features.json
    note "iteration $ITERATION edited features.json beyond .passes; restored from the last loop checkpoint"
  fi
  gated=1
  if ! gate_ok; then
    gated=0
    git checkout -q "$BASE" -- features.json
    note "iteration $ITERATION: gate failed, passes flips rejected (see $LOOP_DIR/logs/gate-$ITERATION.log)"
  fi

  git add -A
  if git diff --cached --quiet "$BASE" -- . ':(exclude)progress.txt' ':(exclude)features.json'; then
    NO_PROGRESS=$((NO_PROGRESS + 1))
  else
    NO_PROGRESS=0
  fi
  git commit -q -m "loop: iteration $ITERATION" >/dev/null || true
  BASE=$(git write-tree 2>/dev/null || echo "$BASE")

  [ "$gated" -eq 1 ] && jq -e 'all(.[]; .passes == true)' features.json >/dev/null && stop "done: every feature passed the gate" 0
  over_ceiling && stop "SPEND_CEILING (\$$SPEND_CEILING)"
  [ "$NO_PROGRESS" -ge "$NO_PROGRESS_LIMIT" ] && stop "no-progress breaker ($NO_PROGRESS unchanged diffs)"
done
stop "MAX_ITERATIONS ($MAX_ITERATIONS)"
