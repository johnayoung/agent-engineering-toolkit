#!/usr/bin/env bash
# check-edges.sh — run a filled edge-justification worksheet through the
# edge-justification table from "The Topology You Can Review Is the Topology You Can Run"
# https://jyoung.dev/blog/agent-architecture-review-capacity/
#
# Default-reject: an empty or invalid cell deletes the edge. An edge that
# survives is one you can defend; an edge that does not is one you never draw.
#
# Usage: check-edges.sh <worksheet.md>
# Exit:  0 = every proposed edge survived (warnings allowed), or no edges proposed
#        1 = at least one edge is deleted
#        2 = usage error
#
# Zero dependencies beyond coreutils (bash, awk).

set -euo pipefail

usage() {
  echo "usage: $(basename "$0") <worksheet.md>" >&2
  exit 2
}

[[ $# -eq 1 ]] || usage
sheet="$1"
[[ -f "$sheet" ]] || { echo "error: not a file: $sheet" >&2; exit 2; }

# ---- parsing -----------------------------------------------------------------

# Chunk n of the worksheet: everything from the nth "## Edge" heading to the next one.
edge_chunk() {
  awk -v want="$1" '
    /^##[ \t]+[Ee]dge/ { c++ }
    c == want { print }
    c > want  { exit }
  ' "$sheet"
}

# First "- **Label:** value" line in a chunk whose label matches (case-insensitively).
field() { # $1 = chunk, $2 = lowercased label
  printf '%s\n' "$1" | awk -v lab="$2" '
    {
      if (match($0, /^[ \t]*[-*][ \t]*\*\*[^*]+\*\*/)) {
        lbl = substr($0, RSTART, RLENGTH)
        sub(/^[ \t]*[-*][ \t]*\*\*/, "", lbl)
        sub(/\*\*$/, "", lbl)
        sub(/[ \t]*:[ \t]*$/, "", lbl)
        if (tolower(lbl) == lab) {
          val = substr($0, RSTART + RLENGTH)
          sub(/^[ \t]*:?[ \t]*/, "", val)
          sub(/[ \t]*$/, "", val)
          print val
          exit
        }
      }
    }
  '
}

# An unfilled cell: blank, an <angle bracket> placeholder, or a stand-in for an answer.
# A placeholder is a value that is entirely one bracket token, or that contains a bracketed
# phrase with a space in it. Path fragments like docs/handoff/<task-id>.md are real answers.
is_empty() { # $1 = value
  local v="${1:-}"
  local whole='^[[:space:]]*[<][^>]*[>][[:space:]]*$'
  local phrase='[<][^>]*[[:space:]][^>]*[>]'
  [[ -z "${v//[[:space:]]/}" ]] && return 0
  [[ "$v" =~ $whole ]] && return 0
  [[ "$v" =~ $phrase ]] && return 0
  case "${v,,}" in
    todo|tbd|n/a|na|none|-|--|\?|\?\?\?|xxx) return 0 ;;
  esac
  return 1
}

has_digit() { [[ "${1:-}" =~ [0-9] ]]; }

first_number() { # first integer in the string, else 0
  printf '%s\n' "${1:-}" | awk '{ if (match($0, /[0-9]+/)) { print substr($0, RSTART, RLENGTH); exit } } END { }'
}

# ---- run ---------------------------------------------------------------------

edges=$(awk '/^##[ \t]+[Ee]dge/ { n++ } END { print n + 0 }' "$sheet")

echo "Edge-justification check: $sheet"
echo "Table: https://jyoung.dev/blog/agent-architecture-review-capacity/"
echo

if ((edges == 0)); then
  echo "No edges proposed."
  echo "Zero edges is the correct starting point for coding work — on SWE-bench Verified every"
  echo "multi-agent architecture scored below the single-agent baseline. Nothing to justify."
  exit 0
fi

kept=0
deleted=0
warn_total=0
minutes_total=0

for ((i = 1; i <= edges; i++)); do
  chunk="$(edge_chunk "$i")"
  title="$(printf '%s\n' "$chunk" | awk 'NR==1 { sub(/^##[ \t]*/, ""); print }')"
  fails=()
  warns=()

  single="$(field "$chunk" "single agent enough")"
  coord="$(field "$chunk" "coordination lives")"
  constraint="$(field "$chunk" "forcing constraint")"
  evidence="$(field "$chunk" "constraint evidence")"
  tier="$(field "$chunk" "risk tier")"
  objective="$(field "$chunk" "objective")"
  outfmt="$(field "$chunk" "output format")"
  tools="$(field "$chunk" "tools and sources")"
  bounds="$(field "$chunk" "task boundaries")"
  node="$(field "$chunk" "review node")"
  upstream="$(field "$chunk" "upstream of irreversible action")"
  tokens="$(field "$chunk" "token budget")"
  minutes="$(field "$chunk" "reviewer-minute budget")"
  equal="$(field "$chunk" "equal-compute comparison")"

  # 1. Single agent enough — the measured default you are drawing against.
  if is_empty "$single"; then
    fails+=("Single agent enough — empty. You are drawing against the measured default; say why one agent cannot do this.")
  elif [[ "${single,,}" =~ ^yes ]]; then
    fails+=("Single agent enough — answered yes. One agent already covers this work, so the edge has nothing to carry.")
  elif [[ ! "${single,,}" =~ ^no ]]; then
    fails+=("Single agent enough — answer must start with yes or no.")
  fi

  # 2. Where the coordination physically lives.
  if is_empty "$coord"; then
    fails+=("Coordination lives — empty. Coordination does not arrive with better models; name the file, lock, queue, or assignment it runs through.")
  fi

  # 3. Forcing constraint — closed list of three, exactly one.
  c="${constraint,,}"
  c="${c//_/ }"
  c="${c//-/ }"
  c="${c%.}"
  if is_empty "$constraint"; then
    fails+=("Forcing constraint — empty. The edge has no reason to exist. Delete it.")
  elif [[ "$constraint" == *"|"* || "$constraint" == *","* || "$c" == *" and "* ]]; then
    fails+=("Forcing constraint — more than one named. Name the single constraint that forced this edge, not a menu.")
  else
    case "$c" in
      "context pollution"|"parallelism"|"specialization"|"policy isolation") ;;
      *risk*|*safety*|*blast*|*danger*|*correctness*|*quality*)
        fails+=("Forcing constraint — \"$constraint\" is risk, not a forcing constraint. Risk earns a review checkpoint, never another worker.") ;;
      *)
        fails+=("Forcing constraint — \"$constraint\" is off the closed list (context pollution, parallelism, specialization). Outside those, coordination costs typically exceed the benefits.") ;;
    esac
  fi

  # 4. The signal you actually observed.
  if is_empty "$evidence"; then
    fails+=("Constraint evidence — empty. Naming a constraint is not observing one.")
  else
    case "$c" in
      "parallelism")
        if [[ ! "${evidence,,}" =~ (shared|independen|ordering|disjoint|separate|no overlap) ]]; then
          warns+=("Constraint evidence — a parallelism claim needs the negative evidence: no shared symbol, no shared test, no ordering dependency. Read actions parallelize; writes force both context communication and output merging, and coding is write-heavy.")
        fi ;;
      "specialization"|"policy isolation")
        if [[ ! "${tools,,}" =~ (token|credential|key|secret|permission|scope|deploy|migration|role|account|cli|api|access) ]] && [[ ! "${evidence,,}" =~ (token|credential|key|secret|permission|scope|deploy|migration|role|account|cli|api|access) ]]; then
          warns+=("Constraint evidence — specialization means a tool or credential the main agent should not hold, not a job title. Dividing by type of work (writer / tester / reviewer) creates constant coordination overhead.")
        fi ;;
      "context pollution")
        if ! has_digit "$evidence"; then
          warns+=("Constraint evidence — context pollution is measurable. Cite the window fraction or token count you observed, not the impression.")
        fi ;;
    esac
  fi

  # 5. Risk tier — reuse the authority tiers, do not invent a topology axis.
  t="${tier,,}"
  t="${t%%[[:space:]]*}"
  t="${t%%[,.;:]*}"
  if is_empty "$tier"; then
    fails+=("Risk tier — empty. You cannot tell whether this edge terminates in a merge or a checkpoint.")
  else
    case "$t" in
      low|medium|high|critical) ;;
      *) fails+=("Risk tier — \"$tier\" is not one of low / medium / high / critical. Reuse the tiers from your authority table; do not invent a topology-specific axis.") ;;
    esac
  fi

  # 6-9. The four-field delegation spec.
  if is_empty "$objective"; then
    fails+=("Objective — empty. The agent will infer it, and correlated models infer identically.")
  fi
  if is_empty "$outfmt"; then
    fails+=("Output format — empty. This is the field the branch name lives in; thirty agents left it blank and eighteen invented the same name.")
  fi
  if is_empty "$tools"; then
    fails+=("Tools and sources — empty. Unbounded reads are how one subagent explores 2021 while two others duplicate 2025.")
  fi
  if is_empty "$bounds"; then
    fails+=("Task boundaries — empty. No spec reaches every implicit decision, but an unwritten boundary is not one of the unreachable ones.")
  fi

  if ! is_empty "$outfmt" && [[ ! "${outfmt,,}" =~ branch ]]; then
    warns+=("Output format — no branch name assigned. If this edge produces a branch, assign the name here; if it produces none, say so.")
  fi

  # 10-11. The node that adjudicates, and where it sits.
  if is_empty "$node"; then
    fails+=("Review node — empty. Your review is a stage, and stages get skipped under exactly the load that created them.")
  fi
  if is_empty "$upstream"; then
    fails+=("Upstream of irreversible action — empty. A checkpoint that has not been placed relative to the irreversible action has not been placed.")
  elif [[ "${upstream,,}" =~ ^no ]]; then
    fails+=("Upstream of irreversible action — no. The node sits after the branch/write/deploy it was supposed to gate; it is documentation, not a control.")
  elif [[ ! "${upstream,,}" =~ ^yes ]]; then
    fails+=("Upstream of irreversible action — answer must start with yes or no.")
  fi
  if [[ "$t" == "high" || "$t" == "critical" ]] && ! is_empty "$node"; then
    if [[ ! "${node,,}" =~ (human|reviewer|person|approve|approval|interrupt|sign-off|sign off|on-call|owner) ]]; then
      warns+=("Review node — $t-tier work with no human named in the node. Name who blocks, not just what blocks.")
    fi
  fi

  # 12-13. Both bills.
  if is_empty "$tokens" || ! has_digit "$tokens"; then
    fails+=("Token budget — no number. Multi-agent implementations used 3-10x the tokens of single-agent for equivalent tasks in Anthropic's internal testing; budget it before you draw it.")
  fi
  if is_empty "$minutes" || ! has_digit "$minutes"; then
    fails+=("Reviewer-minute budget — no number. This is the bill that halts the pipeline and the one almost nobody writes down.")
  fi

  # 14. The null hypothesis: the same compute spent on one agent.
  if is_empty "$equal"; then
    fails+=("Equal-compute comparison — empty. The edge may be a compute increase you have mislabeled as architecture.")
  elif [[ "${equal,,}" =~ ^(no|not[[:space:]]run|never|skip|untested|unknown) ]]; then
    fails+=("Equal-compute comparison — not run. Held to equal thinking tokens, single-agent matched or beat multi-agent across two datasets, three model families, and five architectures.")
  fi

  # ---- verdict
  if ((${#fails[@]} == 0)); then
    printf 'KEEP    %s\n' "$title"
    kept=$((kept + 1))
    m="$(first_number "$minutes")"
    minutes_total=$((minutes_total + ${m:-0}))
  else
    printf 'DELETE  %s\n' "$title"
    deleted=$((deleted + 1))
    for f in "${fails[@]}"; do printf '        FAIL  %s\n' "$f"; done
  fi
  if ((${#warns[@]} > 0)); then
    for w in "${warns[@]}"; do
      printf '        WARN  %s\n' "$w"
      warn_total=$((warn_total + 1))
    done
  fi
  echo
done

# ---- summary -----------------------------------------------------------------

echo "Edges proposed: $edges"
echo "Edges kept:     $kept"
echo "Edges deleted:  $deleted"
if ((warn_total > 0)); then
  echo "Warnings:       $warn_total (heuristic scans — a human judges these)"
fi

if ((kept > 0)); then
  hours="$(awk -v m="$minutes_total" 'BEGIN { printf "%.1f", m / 60 }')"
  echo
  echo "Reviewer bill of the kept edges: $minutes_total min/day (~$hours h/day)."
  echo "That number is the budget you wrote, not a measurement. Check it against your measured"
  echo "review capacity before you draw any of these: https://jyoung.dev/blog/review-capacity-agent-throughput/"
  echo "Price the merge separately from the review — git detects textual conflicts, not semantic ones."
fi

if ((deleted > 0)); then
  echo
  echo "Result: $deleted edge(s) deleted. Deleting an edge is the expected outcome, not a failure of the worksheet."
  exit 1
fi

echo
echo "Result: all $edges edge(s) survived. Re-run this worksheet whenever the work crossing an edge changes."
