#!/usr/bin/env bash
# check-task-graph.sh — validate a task graph before any agent opens a file.
#
# From "Task Decomposition for AI Coding Agents: Draw the Graph First"
# https://jyoung.dev/blog/task-decomposition-for-ai-coding-agents/
#
# Reads a graph JSON (nodes with owned write globs, owned/read contracts,
# dependency edges, and mechanical acceptance predicates) and checks the
# structural properties the post argues for:
#
#   1. Every node has a name on the graph, a write glob, and a predicate.
#   2. Write globs are disjoint       -- two nodes claiming one path is the
#                                        collision the post is about.
#   3. Every contract has exactly one owner.
#   4. Dependency edges are acyclic; reports depth, not just node count.
#   5. Every acceptance predicate is mechanical (command / test / file_exists /
#      glob_count), not prose a model grades itself against.
#   6. A one-node graph is reported as a stop condition: run it monolithic.
#
# This script does NOT execute your predicates. It checks that they exist and
# are machine-evaluable. `--runner` prints a shell script that runs them, so
# executing anything stays your explicit decision.
#
# Usage:
#   check-task-graph.sh <graph.json> [--repo <path>]   validate (default cwd)
#   check-task-graph.sh <graph.json> --table           print the post's
#                                                      Node/Writes/Contract/
#                                                      Done-when table
#   check-task-graph.sh <graph.json> --runner          print a sh runner for
#                                                      the acceptance predicates
#   check-task-graph.sh --skeleton                     print a blank graph
#
# Exit: 0 = graph passes (warnings allowed, may be a monolithic verdict)
#       1 = one or more structural failures
#       2 = usage or input error
#
# Dependencies: bash, git (optional), jq, coreutils.

set -euo pipefail

GRAPH_FILE=""
REPO="$PWD"
MODE="check"

usage() { sed -n '2,38p' "$0" | sed 's/^# \{0,1\}//'; }

print_skeleton() {
  cat <<'SKEL'
{
  "epic": "<the one-sentence epic, verbatim as it arrived>",
  "owner": "<the human accountable for this graph, by name>",
  "failure_rate_evidence": "<what you observed running this epic monolithic: attempts, reruns>",
  "nodes": [
    {
      "id": "n1",
      "layer": "<schema | middleware | ui | docs | ...>",
      "writes": ["<glob this node exclusively writes>"],
      "owns": ["<interface contract this node may change>"],
      "reads": ["<contract it may read but not change>"],
      "depends": [],
      "accept": { "kind": "command", "run": "<command that exits 0 when done>" }
    }
  ]
}

Predicate kinds (one object, or an array of them, per node):
  {"kind":"command","run":"go test ./..."}
  {"kind":"test","name":"TestX","run":"go test ./pkg -run TestX"}
  {"kind":"file_exists","path":"docs/api/rate-limits.md"}
  {"kind":"glob_count","glob":"migrations/*_tenant_rate_limits.sql","min":1}
SKEL
}

while [ "$#" -gt 0 ]; do
  case "$1" in
    --skeleton) print_skeleton; exit 0 ;;
    --table) MODE="table"; shift ;;
    --runner) MODE="runner"; shift ;;
    --repo)
      [ "$#" -ge 2 ] || { echo "error: --repo needs a value" >&2; exit 2; }
      REPO="$2"; shift 2 ;;
    -h|--help) usage; exit 0 ;;
    -*) echo "error: unknown argument '$1' (see --help)" >&2; exit 2 ;;
    *)
      [ -z "$GRAPH_FILE" ] || { echo "error: more than one graph file given" >&2; exit 2; }
      GRAPH_FILE="$1"; shift ;;
  esac
done

[ -n "$GRAPH_FILE" ] || { usage >&2; exit 2; }
[ -f "$GRAPH_FILE" ] || { echo "error: not a file: $GRAPH_FILE" >&2; exit 2; }
command -v jq >/dev/null || { echo "error: jq required" >&2; exit 2; }

GRAPH=$(cat "$GRAPH_FILE")
jq -e . >/dev/null <<<"$GRAPH" || { echo "error: $GRAPH_FILE is not valid JSON" >&2; exit 2; }

jqg() { jq "$@" <<<"$GRAPH"; }

# accept -> array of predicate objects (a bare object becomes a one-element array;
# a bare string stays a string so the prose check can catch it).
ACCEPT_FILTER='(.accept // null) | if type == "array" then . elif . == null then [] else [.] end'

# ---------------------------------------------------------------- alt modes ---

predicate_label() { # $1 = predicate JSON
  jq -r '
    if type != "object" then "PROSE: " + (tostring)
    elif .kind == "command" then "exit 0: " + (.run // "<missing run>")
    elif .kind == "test" then "test " + (.name // "<missing name>") + " passes: " + (.run // "<missing run>")
    elif .kind == "file_exists" then "file exists: " + (.path // "<missing path>")
    elif .kind == "glob_count" then "at least " + ((.min // 1) | tostring) + " file(s) match: " + (.glob // "<missing glob>")
    else "UNKNOWN KIND: " + (.kind // "<none>") end' <<<"$1"
}

if [ "$MODE" = "table" ]; then
  echo "| Node | Writes | Contract | Done when |"
  echo "|---|---|---|---|"
  while IFS= read -r id; do
    node=$(jqg -c --arg id "$id" '.nodes[] | select(.id == $id)')
    layer=$(jq -r '.layer // ""' <<<"$node")
    writes=$(jq -r '[.writes[]? | "`" + . + "`"] | join(", ")' <<<"$node")
    owns=$(jq -r '[.owns[]?] | join(", ")' <<<"$node")
    reads=$(jq -r '[.reads[]?] | join(", ")' <<<"$node")
    contract=""
    [ -n "$owns" ] && contract="Owns $owns"
    if [ -n "$reads" ]; then
      [ -n "$contract" ] && contract="$contract; reads $reads (may not change)" \
        || contract="Reads $reads, may not change it"
    fi
    [ -n "$contract" ] || contract="Owns nothing in code"
    done_when=$(jq -c "$ACCEPT_FILTER" <<<"$node" | jq -c '.[]' | while IFS= read -r p; do
      printf '%s; ' "$(predicate_label "$p")"
    done)
    done_when=${done_when%; }
    printf '| **%s %s** | %s | %s | %s |\n' "$id" "$layer" "$writes" "$contract" "$done_when"
  done < <(jqg -r '.nodes[]?.id // empty')
  exit 0
fi

if [ "$MODE" = "runner" ]; then
  echo '#!/usr/bin/env bash'
  echo '# Generated by check-task-graph.sh --runner. Review before running: these are'
  echo '# your predicates, executed verbatim as bash commands, from the repo root.'
  echo "# Graph: $GRAPH_FILE"
  echo 'fail=0'
  while IFS= read -r id; do
    node=$(jqg -c --arg id "$id" '.nodes[] | select(.id == $id)')
    echo ""
    echo "echo '--- $id'"
    while IFS= read -r p; do
      kind=$(jq -r 'if type == "object" then (.kind // "") else "" end' <<<"$p")
      case "$kind" in
        command|test)
          run=$(jq -r '.run // ""' <<<"$p")
          printf 'if %s; then echo "  PASS %s"; else echo "  FAIL %s"; fail=1; fi\n' \
            "$run" "$(printf '%s' "$run" | tr -d '"')" "$(printf '%s' "$run" | tr -d '"')" ;;
        file_exists)
          path=$(jq -r '.path // ""' <<<"$p")
          printf 'if [ -e "%s" ]; then echo "  PASS exists %s"; else echo "  FAIL missing %s"; fail=1; fi\n' \
            "$path" "$path" "$path" ;;
        glob_count)
          glob=$(jq -r '.glob // ""' <<<"$p")
          min=$(jq -r '.min // 1' <<<"$p")
          printf 'n=$(ls -1 %s 2>/dev/null | wc -l); if [ "$n" -ge %s ]; then echo "  PASS $n match %s"; else echo "  FAIL $n match %s, want >= %s"; fail=1; fi\n' \
            "$glob" "$min" "$glob" "$glob" "$min" ;;
        *)
          printf 'echo "  SKIP non-mechanical predicate on %s"; fail=1\n' "$id" ;;
      esac
    done < <(jq -c "$ACCEPT_FILTER" <<<"$node" | jq -c '.[]')
  done < <(jqg -r '.nodes[]?.id // empty')
  echo ""
  echo 'exit $fail'
  exit 0
fi

# ------------------------------------------------------------------ checks ---

FAILS=0
WARNS=0
fail() { printf 'FAIL  %s\n' "$1"; FAILS=$((FAILS + 1)); }
warn() { printf 'WARN  %s\n' "$1"; WARNS=$((WARNS + 1)); }
pass() { printf 'PASS  %s\n' "$1"; }

EPIC=$(jqg -r '.epic // ""')
OWNER=$(jqg -r '.owner // ""')
EVIDENCE=$(jqg -r '.failure_rate_evidence // ""')
NODE_COUNT=$(jqg -r '.nodes | if type == "array" then length else 0 end')

REPO_ROOT=""
if git -C "$REPO" rev-parse --show-toplevel >/dev/null 2>&1; then
  REPO_ROOT=$(git -C "$REPO" rev-parse --show-toplevel)
fi

echo "task-graph check: $GRAPH_FILE"
if [ -n "$REPO_ROOT" ]; then
  echo "Repo: $REPO_ROOT (git tracked files available)"
else
  echo "Repo: $REPO (not a git work tree -- the materialized overlap check is skipped)"
fi
echo "Epic: ${EPIC:-<missing>}"
echo "Owner: ${OWNER:-<nobody>}"
echo "Nodes: $NODE_COUNT"
echo "Graph shape and argument: https://jyoung.dev/blog/task-decomposition-for-ai-coding-agents/"
echo
echo "== Graph header"
[ -n "$EPIC" ] && pass "epic stated" || fail "epic missing -- the graph has no input statement to trace nodes back to"
[ -n "$OWNER" ] && pass "owner: $OWNER" \
  || fail "no name on this graph -- assign it before the first agent starts, or the graph gets discovered during implementation instead of planned before it"
[ "$NODE_COUNT" -ge 1 ] || { fail "no nodes"; echo; echo "Verdict: GRAPH NOT READY"; exit 1; }

mapfile -t IDS < <(jqg -r '.nodes[]? | .id // ""')
TMP=$(mktemp -d "${TMPDIR:-/tmp}/task-graph-check.XXXXXX")
trap 'rm -rf "$TMP"' EXIT

# ---- node schema -------------------------------------------------------------
echo
echo "== Node schema"
declare -A SEEN_ID=()
i=0
for id in "${IDS[@]}"; do
  i=$((i + 1))
  if [ -z "$id" ]; then fail "node #$i has no id"; continue; fi
  if [ -n "${SEEN_ID[$id]:-}" ]; then fail "duplicate node id '$id'"; continue; fi
  SEEN_ID[$id]=1
  node=$(jqg -c --arg id "$id" '.nodes[] | select(.id == $id)')
  nwrites=$(jq -r '[.writes[]?] | length' <<<"$node")
  if [ "$nwrites" -eq 0 ]; then
    fail "$id has no write glob -- a node with no owned files is not a node, it is a note"
  fi
  # depends must reference existing ids and not itself
  while IFS= read -r dep; do
    [ -n "$dep" ] || continue
    if [ "$dep" = "$id" ]; then fail "$id depends on itself"; continue; fi
    found=0
    for other in "${IDS[@]}"; do [ "$other" = "$dep" ] && { found=1; break; }; done
    [ "$found" -eq 1 ] || fail "$id depends on '$dep', which is not a node in this graph"
  done < <(jq -r '.depends[]? // empty' <<<"$node")
done
[ "$FAILS" -eq 0 ] && pass "every node has an id and at least one write glob"

# ---- write ownership ---------------------------------------------------------
echo
echo "== Write ownership (spatial edge)"

has_wild() { case "$1" in *[\*\?\[]*) return 0 ;; *) return 1 ;; esac; }

lit_prefix() { # longest literal directory prefix of a glob ("" = repo root)
  local g="$1" head
  head="${g%%[*?[]*}"
  if [ "$head" = "$g" ]; then printf '%s' "$g"; return; fi
  case "$head" in */*) printf '%s' "${head%/*}/" ;; *) printf '%s' "" ;; esac
}

is_catchall() { # a pattern whose only wildcard is a trailing */** over a literal prefix
  local g="$1" pre
  case "$g" in
    '*'|'**') return 0 ;;
    */'*'|*/'**')
      pre="${g%/*}"
      has_wild "$pre" && return 1
      return 0 ;;
    *) return 1 ;;
  esac
}

globs_overlap() { # 0 = certain overlap, 3 = possible overlap, 1 = disjoint
  local a="$1" b="$2" la lb t
  [ "$a" = "$b" ] && return 0
  if ! has_wild "$a" && ! has_wild "$b"; then
    [ "$a" = "$b" ] && return 0
    case "$a" in "$b"/*) return 0 ;; esac
    case "$b" in "$a"/*) return 0 ;; esac
    return 1
  fi
  if has_wild "$a" && ! has_wild "$b"; then t="$a"; a="$b"; b="$t"; fi
  if ! has_wild "$a"; then          # a is literal, b is a pattern
    # shellcheck disable=SC2053
    [[ "$a" == $b ]] && return 0
    lb=$(lit_prefix "$b")
    [ -n "$lb" ] && case "$lb" in "$a"/*) return 0 ;; esac
    return 1
  fi
  la=$(lit_prefix "$a"); lb=$(lit_prefix "$b")
  # A catch-all claims everything under its prefix, so anything rooted there collides.
  if is_catchall "$a"; then case "$lb" in "$la"*) return 0 ;; esac; fi
  if is_catchall "$b"; then case "$la" in "$lb"*) return 0 ;; esac; fi
  case "$la" in "$lb"*) return 3 ;; esac
  case "$lb" in "$la"*) return 3 ;; esac
  return 1
}

# materialized sets: tracked files each node's globs actually claim today
if [ -n "$REPO_ROOT" ]; then
  for id in "${IDS[@]}"; do
    [ -n "$id" ] || continue
    mapfile -t globs < <(jqg -r --arg id "$id" '.nodes[] | select(.id == $id) | .writes[]? // empty')
    if [ "${#globs[@]}" -gt 0 ]; then
      git -C "$REPO_ROOT" ls-files -- "${globs[@]}" 2>/dev/null | sort -u > "$TMP/files.$id" || : > "$TMP/files.$id"
    else
      : > "$TMP/files.$id"
    fi
  done
fi

overlap_found=0
for a_idx in "${!IDS[@]}"; do
  for b_idx in "${!IDS[@]}"; do
    [ "$b_idx" -gt "$a_idx" ] || continue
    a_id="${IDS[$a_idx]}"; b_id="${IDS[$b_idx]}"
    [ -n "$a_id" ] && [ -n "$b_id" ] || continue

    if [ -n "$REPO_ROOT" ]; then
      shared=$(comm -12 "$TMP/files.$a_id" "$TMP/files.$b_id" || true)
      if [ -n "$shared" ]; then
        overlap_found=1
        count=$(printf '%s\n' "$shared" | wc -l | tr -d ' ')
        head3=$(printf '%s\n' "$shared" | head -3 | awk '{printf "%s%s", sep, $0; sep=", "} END {print ""}')
        extra=""
        [ "$count" -gt 3 ] && extra=" (+$((count - 3)) more)"
        fail "$a_id and $b_id both claim $count tracked file(s): $head3$extra -- assign each path to exactly one node"
      fi
    fi

    mapfile -t aglobs < <(jqg -r --arg id "$a_id" '.nodes[] | select(.id == $id) | .writes[]? // empty')
    mapfile -t bglobs < <(jqg -r --arg id "$b_id" '.nodes[] | select(.id == $id) | .writes[]? // empty')
    for ga in "${aglobs[@]}"; do
      for gb in "${bglobs[@]}"; do
        set +e; globs_overlap "$ga" "$gb"; rc=$?; set -e
        case "$rc" in
          0) overlap_found=1
             fail "$a_id '$ga' overlaps $b_id '$gb' -- one path, two writers" ;;
          3) overlap_found=1
             warn "$a_id '$ga' may overlap $b_id '$gb' (their literal prefixes nest; no tracked file matches both today). Confirm the tails cannot match the same new file, or split the prefix." ;;
        esac
      done
    done
  done
done
if [ "$overlap_found" -eq 0 ]; then
  if [ -n "$REPO_ROOT" ]; then
    pass "write globs are disjoint -- no tracked file is claimed twice, no pattern pair overlaps"
  else
    pass "write globs show no pattern overlap (tracked-file check skipped: not a git work tree)"
  fi
fi

# ---- contracts ---------------------------------------------------------------
echo
echo "== Contract ownership (semantic edge)"
owners_tsv="$TMP/owners.tsv"
jqg -r '.nodes[]? | .id as $id | (.owns[]? // empty) | [., $id] | @tsv' > "$owners_tsv" || :
dupes=$(awk -F'\t' '{c[$1]=c[$1]" "$2; n[$1]++} END {for (k in n) if (n[k] > 1) printf "%s|%s\n", k, c[k]}' "$owners_tsv" | sort || true)
if [ -n "$dupes" ]; then
  while IFS='|' read -r contract who; do
    fail "contract '$contract' is owned by more than one node:$who -- a contract needs exactly one owner"
  done <<<"$dupes"
fi
unowned=$(jqg -r '
  ([.nodes[]? | .owns[]? // empty] | unique) as $owned
  | [.nodes[]? | .id as $id | (.reads[]? // empty) | select(. as $c | $owned | index($c) | not) | [$id, .] | @tsv]
  | .[]' || true)
if [ -n "$unowned" ]; then
  while IFS=$'\t' read -r nid contract; do
    warn "$nid reads '$contract', which no node in this graph owns -- freeze it for the run, or add the node that owns it"
  done <<<"$unowned"
fi
both=$(jqg -r '.nodes[]? | .id as $id | (.owns // []) as $o | (.reads[]? // empty) | select(. as $c | $o | index($c)) | [$id, .] | @tsv' || true)
if [ -n "$both" ]; then
  while IFS=$'\t' read -r nid contract; do
    warn "$nid both owns and reads '$contract' -- drop it from reads; the owner may already change it"
  done <<<"$both"
fi
total_owned=$(wc -l < "$owners_tsv" | tr -d ' ')
if [ -z "$dupes" ] && [ "$total_owned" -gt 0 ]; then
  pass "$total_owned contract(s) named, each with exactly one owner"
elif [ "$total_owned" -eq 0 ]; then
  warn "no contracts named on any node -- the spatial edge is set but the semantic one is open: a textually clean merge is not a correct merge"
fi

# ---- edges -------------------------------------------------------------------
echo
echo "== Dependency edges"
edges_in="$TMP/edges.txt"
{
  for id in "${IDS[@]}"; do [ -n "$id" ] && printf 'N\t%s\n' "$id"; done
  jqg -r '.nodes[]? | .id as $to | (.depends[]? // empty) | ["E", ., $to] | @tsv' || :
} > "$edges_in"

topo=$(awk -F'\t' '
  $1 == "N" { if (!($2 in nodes)) { nodes[$2] = 1; order[++n] = $2; indeg[$2] = 0; level[$2] = 1 } }
  $1 == "E" {
    from = $2; to = $3
    if (!(from in nodes) || !(to in nodes)) next
    key = from SUBSEP to
    if (key in seen) next
    seen[key] = 1
    adj[from] = adj[from] " " to
    indeg[to]++
  }
  END {
    qh = 0; qt = 0
    for (i = 1; i <= n; i++) if (indeg[order[i]] == 0) q[++qt] = order[i]
    processed = 0; maxlevel = 0; seq = ""
    while (qh < qt) {
      u = q[++qh]; processed++
      seq = seq (seq == "" ? "" : " ") u
      if (level[u] > maxlevel) maxlevel = level[u]
      m = split(adj[u], vs, " ")
      for (i = 1; i <= m; i++) {
        v = vs[i]; if (v == "") continue
        if (level[v] < level[u] + 1) level[v] = level[u] + 1
        if (--indeg[v] == 0) q[++qt] = v
      }
    }
    if (processed < n) {
      stuck = ""
      for (i = 1; i <= n; i++) if (indeg[order[i]] > 0) stuck = stuck (stuck == "" ? "" : ", ") order[i]
      printf "CYCLE\t%s\n", stuck
    } else {
      printf "DEPTH\t%d\n", maxlevel
      printf "ORDER\t%s\n", seq
    }
  }
' "$edges_in")

if grep -q '^CYCLE' <<<"$topo"; then
  fail "dependency cycle among: $(sed -n 's/^CYCLE\t//p' <<<"$topo") -- edges must be acyclic or nothing can start"
else
  DEPTH=$(sed -n 's/^DEPTH\t//p' <<<"$topo")
  ORDER=$(sed -n 's/^ORDER\t//p' <<<"$topo")
  pass "acyclic; topological order: $ORDER"
  echo "      Longest dependency chain: depth $DEPTH across $NODE_COUNT node(s). Depth, not node"
  echo "      count, sets the rerun blast radius when a middle node fails."
fi

# ---- acceptance predicates ---------------------------------------------------
echo
echo "== Acceptance predicates"
for id in "${IDS[@]}"; do
  [ -n "$id" ] || continue
  node=$(jqg -c --arg id "$id" '.nodes[] | select(.id == $id)')
  preds=$(jq -c "$ACCEPT_FILTER" <<<"$node")
  npred=$(jq -r 'length' <<<"$preds")
  if [ "$npred" -eq 0 ]; then
    fail "$id has no acceptance predicate -- without one, the node's output is graded by whoever is looking"
    continue
  fi
  while IFS= read -r p; do
    ptype=$(jq -r 'type' <<<"$p")
    if [ "$ptype" != "object" ]; then
      fail "$id acceptance is prose, not a predicate: $(jq -r 'tostring' <<<"$p") -- convert it to a command, a named test, a file check, or a glob count"
      continue
    fi
    kind=$(jq -r '.kind // ""' <<<"$p")
    case "$kind" in
      command|test)
        run=$(jq -r '.run // ""' <<<"$p")
        [ -n "$run" ] || { fail "$id predicate kind '$kind' has no 'run' command"; continue; }
        if [ "$kind" = "test" ] && [ -z "$(jq -r '.name // ""' <<<"$p")" ]; then
          fail "$id predicate kind 'test' has no test name"; continue
        fi
        pass "$id -- $(predicate_label "$p")" ;;
      file_exists)
        [ -n "$(jq -r '.path // ""' <<<"$p")" ] || { fail "$id predicate kind 'file_exists' has no 'path'"; continue; }
        pass "$id -- $(predicate_label "$p")" ;;
      glob_count)
        [ -n "$(jq -r '.glob // ""' <<<"$p")" ] || { fail "$id predicate kind 'glob_count' has no 'glob'"; continue; }
        pass "$id -- $(predicate_label "$p")" ;;
      *)
        fail "$id predicate kind '$kind' is not mechanical -- use command, test, file_exists, or glob_count" ;;
    esac
  done < <(jq -c '.[]' <<<"$preds")
done
echo "      This script checks that predicates exist and are machine-evaluable. It does not"
echo "      run them -- \`--runner\` prints a shell script that does, so execution stays your call."

# ---- handoff gates -----------------------------------------------------------
edge_lines=$(jqg -r '.nodes[]? | .id as $to | (.depends[]? // empty) | [., $to] | @tsv' || true)
if [ -n "$edge_lines" ]; then
  echo
  echo "== Handoff gates (what must pass before the downstream node sees anything)"
  while IFS=$'\t' read -r from to; do
    first=$(jqg -c --arg id "$from" '.nodes[] | select(.id == $id) | '"$ACCEPT_FILTER"' | .[0] // empty')
    if [ -n "$first" ]; then
      printf '      %s -> %s gated by: %s\n' "$from" "$to" "$(predicate_label "$first")"
    else
      printf '      %s -> %s ungated -- %s has no predicate, so a bad result flows downstream\n' "$from" "$to" "$from"
    fi
  done <<<"$edge_lines"
fi

# ---- stop condition + pricing ------------------------------------------------
echo
echo "== Stop condition"
layers=$(jqg -r '[.nodes[]? | .layer // ""] | unique | length')
if [ "$NODE_COUNT" -eq 1 ]; then
  echo "      One node, one layer. This epic does not need a graph -- run it monolithic."
  echo "      Structure buys cheap retries with an expensive first attempt; with nothing"
  echo "      downstream to protect, there is nothing to buy."
elif [ "$layers" -eq 1 ]; then
  warn "all $NODE_COUNT nodes share one layer -- layer boundaries are the most reliable seams, so check these are real seams and not one job cut in half"
fi
if [ -n "$EVIDENCE" ]; then
  echo "      Observed failure rate (yours, as recorded in the graph): $EVIDENCE"
else
  warn "no 'failure_rate_evidence' recorded -- run the epic once monolithic and count the attempts before paying for structure"
fi
cat <<'PRICE'
      This script cannot measure your failure rate, and it is the number that decides
      whether the graph is worth drawing. In the IBM measurements, runtime-structured
      decomposition cost 2,716 +/- 424 tokens on its baseline run against 904 +/- 17
      monolithic, and earned it back only in retries (436 +/- 132 against 904 +/- 17) --
      at a natural failure rate of 0-2%, measured under simulated failure.
PRICE

# ---- verdict -----------------------------------------------------------------
echo
if [ "$FAILS" -gt 0 ]; then
  echo "Verdict: GRAPH NOT READY -- $FAILS failure(s), $WARNS warning(s)"
  echo "Fix the failures before an agent opens a file. Every one of them is a decision"
  echo "that otherwise gets negotiated at runtime, and a chat channel is not a structure."
  exit 1
fi
if [ "$NODE_COUNT" -eq 1 ]; then
  echo "Verdict: RUN IT MONOLITHIC -- structurally valid, but a one-node graph is not a graph ($WARNS warning(s))"
  exit 0
fi
echo "Verdict: GRAPH READY -- $WARNS warning(s)"
echo "Structural checks pass: disjoint write globs, single-owner contracts, acyclic edges,"
echo "mechanical predicates, a named owner. What it cannot check is whether the seams are"
echo "the right seams -- granularity is the part models are worst at, and it stays yours."
