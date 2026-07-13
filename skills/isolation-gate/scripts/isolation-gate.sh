#!/usr/bin/env bash
# isolation-gate.sh — walk one split-or-not decision through the two-gate flowchart.
#
# From "When One Agent Stops Being Enough: The Isolation Gate"
# https://jyoung.dev/blog/multi-agent-context-isolation/
#
# Gates, in order (each STOP is final):
#   0. Speed wish or isolation need?              speed -> DON'T SPLIT
#   1. Failing from pollution, not size?          (diagnostic; both continue)
#   2. Subagent can isolate the side-quest?       yes   -> ISOLATE IN-SESSION
#   3. Value clears ~15x token bill?              no    -> DON'T SPLIT
#   4. Writes stay single-threaded?               no    -> DON'T SPLIT
#   5. Coordination readiness + decomposability?  fail  -> KEEP SINGLE-AGENT
#   6. Fan-out exceeds review throughput?         yes   -> CAP AT THREE TO FIVE
#
# These are judgment questions. The script structures the walk and prices the
# stops with the post's sourced numbers; it cannot answer the questions for you.
#
# Usage:
#   isolation-gate.sh                       interactive
#   isolation-gate.sh --answers i,p,n,y,y,y,n,n,n,n,n
#                                           non-interactive; comma-separated
#                                           tokens in gate order, a STOP
#                                           short-circuits the rest
#   isolation-gate.sh --template            print the read-only explorer
#                                           subagent template and exit

set -euo pipefail

ANSWERS=()
MODE="interactive"
AIDX=0
REPLY_ANS=""

print_template() {
  cat <<'TPL'
## Subagent: codebase-explorer

### Goal
Locate every call site of <the flow this feature touches> and the
existing <pattern to mirror>. Return a summary, not the raw files.

### Return only
- The 3-5 files the writer agent must edit, with one-line reasons.
- The pattern to mirror (file path + shape), not its full history.
- Any constraint the writer can't infer (naming conventions, ordering).

### Do not
- Paste full file contents or log output back into the main conversation.
- Make edits. This agent reads and reports; it does not write.
TPL
}

usage() {
  sed -n '2,27p' "$0" | sed 's/^# \{0,1\}//'
}

while [ "$#" -gt 0 ]; do
  case "$1" in
    --answers)
      [ "$#" -ge 2 ] || { echo "error: --answers needs a value" >&2; exit 2; }
      IFS=',' read -r -a ANSWERS <<< "$2"
      MODE="answers"
      shift 2
      ;;
    --template) print_template; exit 0 ;;
    -h|--help) usage; exit 0 ;;
    *) echo "error: unknown argument '$1' (see --help)" >&2; exit 2 ;;
  esac
done

rule() { printf '%s\n' "----------------------------------------------------------------------"; }

ask() { # ask "prompt" allowed...
  local prompt="$1" ans a
  shift
  while true; do
    if [ "$MODE" = "answers" ]; then
      if [ "$AIDX" -ge "${#ANSWERS[@]}" ]; then
        echo "error: --answers ran out of tokens at: $prompt" >&2
        exit 2
      fi
      ans="${ANSWERS[$AIDX]}"
      AIDX=$((AIDX + 1))
      printf '%s %s\n' "$prompt" "$ans"
    else
      printf '%s ' "$prompt"
      if ! read -r ans; then
        echo
        echo "error: input ended before the walk finished" >&2
        exit 2
      fi
    fi
    ans=$(printf '%s' "$ans" | tr '[:upper:]' '[:lower:]')
    for a in "$@"; do
      if [ "$ans" = "$a" ]; then
        REPLY_ANS="$ans"
        return 0
      fi
    done
    if [ "$MODE" = "answers" ]; then
      echo "error: invalid token '$ans' for: $prompt (allowed: $*)" >&2
      exit 2
    fi
    echo "  allowed: $*"
  done
}

verdict() { # verdict "TITLE" "line" ...
  local title="$1"
  shift
  echo
  rule
  printf 'VERDICT: %s\n' "$title"
  rule
  local line
  for line in "$@"; do
    printf '%s\n' "$line"
  done
  rule
  echo "Judgment stays yours: the script orders the questions and prices the"
  echo "stops; it cannot see your task. Full argument and sources:"
  echo "https://jyoung.dev/blog/multi-agent-context-isolation/"
}

backfire_note() {
  echo
  echo "If the split backfires anyway, debug the coordination design before you"
  echo "blame the model: failures cluster into system design, inter-agent"
  echo "misalignment, and task verification -- none is 'the model is too weak'"
  echo "(Cemri et al., arXiv 2503.13657; Cognition, 'Don't Build Multi-Agents')."
}

echo "isolation-gate: the two-gate split decision"
echo "One concrete task per walk. Answer for THIS task, not in general."
echo

# --- Gate 0 (post section 1): speed wish or isolation need -------------------
echo "Gate 0 -- Why do you want a second agent?"
echo "  [s] speed: it would finish sooner if parallelized"
echo "  [i] isolation: one context window can't hold this job cleanly"
ask "> " s i
if [ "$REPLY_ANS" = "s" ]; then
  verdict "DON'T SPLIT -- speed is a wish, not a trigger" \
    "Parallelism is the payoff you hope for; context isolation is the reason" \
    "to split. In Anthropic's multi-agent system the extra windows exist so" \
    "exploration is compressed before it reaches the lead agent -- the" \
    "parallelism is incidental. 'It would finish sooner' does not clear a" \
    "~15x token bill (Anthropic, multi-agent research system)."
  exit 0
fi
echo

# --- Gate 1 (post section 2): pollution, not size (diagnostic) ---------------
echo "Gate 1 -- What is actually filling the window?"
echo "  [p] pollution: distractors -- grep results read once, stale log output,"
echo "      dead-end files, migration spelunking"
echo "  [s] size: the irreducible work itself, with no distractors left to cut"
ask "> " p s
if [ "$REPLY_ANS" = "p" ]; then
  echo "  -> Pollution. The target is to get the distractors OUT of the window,"
  echo "     not to buy a bigger one. Even a single distractor degrades output"
  echo "     (Chroma, Context Rot, 18 models). Continue."
else
  echo "  -> Caveat: irrelevant content degrades output well before any size"
  echo "     limit (Chroma, Context Rot). Re-check for distractors before"
  echo "     concluding it's raw size. Continuing either way."
fi
echo

# --- Gate 2 (post section 3): in-session isolation ---------------------------
echo "Gate 2 -- Would a read-only subagent fix it? One that does the side-quest"
echo "(exploration, log-digging, spelunking) in its own context window and"
echo "returns only a summary to the main agent."
ask "> [y/n]" y n
if [ "$REPLY_ANS" = "y" ]; then
  verdict "ISOLATE IN-SESSION -- stop here, don't pay for a full split" \
    "Hand the polluting side-quest to a subagent: it runs in its own context" \
    "window and returns only the summary (Claude Code docs, subagents). The" \
    "main window holds the code and the conclusion -- not the grep transcript." \
    "You avoid the ~15x multi-agent token bill entirely." \
    "" \
    "Starter template (also: isolation-gate.sh --template):" \
    ""
  print_template
  exit 0
fi
echo "  -> Even the summary plus the real work overruns one window. Continue."
echo

# --- Gate 3 (post section 4): the ~15x token bill -----------------------------
echo "Gate 3 -- Multi-agent systems use about 15x the tokens of a single chat,"
echo "and token usage alone explains 80% of performance variance (Anthropic)."
echo "Is the isolation benefit -- clean windows, compressed hand-backs --"
echo "obviously worth that bill for this task?"
ask "> [y/n]" y n
if [ "$REPLY_ANS" = "n" ]; then
  verdict "DON'T SPLIT -- the value doesn't clear the bill" \
    "If the value isn't obvious at ~15x, that is your answer. 'One window" \
    "genuinely cannot hold this and the isolation makes the output correct'" \
    "clears the bar; 'it would finish sooner' does not (Anthropic," \
    "multi-agent research system)."
  exit 0
fi
echo

# --- Gate 4 (post section 5): single-threaded writes --------------------------
echo "Gate 4 -- Can writes stay single-threaded? Extra agents contribute"
echo "read-only intelligence; exactly one agent writes (edits, migrations,"
echo "generated files)."
ask "> [y/n]" y n
if [ "$REPLY_ANS" = "n" ]; then
  verdict "DON'T SPLIT -- parallel writers to shared state" \
    "Multi-agent works best today when writes stay single-threaded and the" \
    "additional agents contribute intelligence rather than actions; most real" \
    "setups are limited to read-only subagents (Cognition, 'Multi-Agents:" \
    "What's Actually Working'). If the split requires two agents writing to" \
    "the same tree, the second gate fails."
  exit 0
fi
echo

# --- Gate 5 (post section 6): coordination readiness checklist ----------------
echo "Gate 5 -- Coordination readiness. A test, not a vibe: five checks."
FAILS=()

ask "  5a. Does each agent own a DISJOINT set of files? [y/n]" y n
[ "$REPLY_ANS" = "n" ] && FAILS+=("file ownership overlaps -- two agents touching one file is a merge conflict you'll pay for later")

ask "  5b. Would agents run git operations against the SAME working tree at the same time? [y/n]" y n
[ "$REPLY_ANS" = "y" ] && FAILS+=("lock-file contention -- git's file-based locking (.git/index.lock) makes the second agent's concurrent operation fail hard (Augment Code); separate working trees, e.g. git worktrees, remove this")

ask "  5c. Must migrations or steps apply in a FIXED ORDER across agents? [y/n]" y n
[ "$REPLY_ANS" = "y" ] && FAILS+=("migration ordering -- ordered work is not parallel work")

ask "  5d. Does one piece CONSUME another's output (API before its client)? [y/n]" y n
[ "$REPLY_ANS" = "y" ] && FAILS+=("dependency sequencing -- these tasks need to be sequenced, not parallelized (Augment Code)")

ask "  5e. Does each step MUTATE STATE the next step reads? [y/n]" y n
[ "$REPLY_ANS" = "y" ] && FAILS+=("state-dependent work -- sequential planning swings to -70.0% vs single-agent, where decomposable work gains +80.8% (Kim et al., arXiv 2512.08296)")

if [ "${#FAILS[@]}" -gt 0 ]; then
  LINES=("The checklist failed on:" "")
  for f in "${FAILS[@]}"; do
    LINES+=("  - $f")
  done
  LINES+=("" \
    "Whether the split pays off is a property of the task's structure, not" \
    "the enthusiasm behind it. Sequential, state-dependent work belongs on" \
    "one writer.")
  verdict "KEEP IT SINGLE-AGENT -- coordination readiness failed" "${LINES[@]}"
  exit 0
fi
echo "  -> Decomposable, coordination clean. Continue."
echo

# --- Gate 6 (post section 8): fan-out vs review throughput --------------------
echo "Gate 6 -- Would the planned fan-out exceed what you can actually review"
echo "and land? Verification, not generation, is the bottleneck; you land one"
echo "significant change at a time no matter how many agents ran."
ask "> [y/n]" y n
if [ "$REPLY_ANS" = "y" ]; then
  verdict "SPLIT, CAPPED -- size the fan-out to your review throughput" \
    "Cap at three to five: token costs scale linearly and three focused" \
    "agents consistently outperform five scattered ones (Addy Osmani). Past" \
    "your review throughput, extra agents buy unreviewed diffs, not output" \
    "(Simon Willison)."
  backfire_note
  exit 0
fi

verdict "SPLIT -- both gates clear" \
  "A real isolation need, priced against the ~15x bill; writes stay" \
  "single-threaded with read-only intelligence feeding one writer; the" \
  "coordination checklist passes; fan-out fits your review throughput." \
  "Keep the added agents read-only and the fan-out at three to five" \
  "(Cognition; Addy Osmani)."
backfire_note
