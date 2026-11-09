#!/usr/bin/env bash
# harness-promotion-gate.sh: decide whether a self-improving loop's candidate
# harness change may replace the incumbent, from evidence the loop did not write.
#
# From "Self-Improving AI Software Factory: Govern the Harness Loop"
# https://jyoung.dev/blog/self-improving-software-factory/
#
# Checks, in order (all run, so the approver sees every failure):
#   1. protected   No changed path matches the protected-paths manifest
#                  (verifier, eval data, budget, sandbox, model config, logs).
#   2. veto        Each --veto command exits 0. Runs regardless of score.
#   3. episodes    The change cites at least one failure episode, and every
#                  cited episode is on the confirmed-failures list.
#   4. splits      Self-Harness acceptance rule on per-task results:
#                  accept only if one split improves and neither degrades.
#                  --strict also rejects any task the incumbent passed and
#                  the candidate fails.
#
# Verdict:
#   PROMOTE   every check passed and a split improved. Goes to the named
#             approver; this script merges nothing.
#   REJECT    a check failed. The incumbent stays live.
#   FALLBACK  no check failed but neither split improved. The incumbent
#             stays live; ending a round on it is a legal outcome.
#
# Usage:
#   harness-promotion-gate.sh [options]
#     change (one of):
#       --git RANGE          changed paths from `git diff RANGE` (e.g. v12..HEAD)
#       --repo DIR           repo for --git (default: cwd)
#       --diff FILE          unified diff ('-' for stdin)
#       --paths FILE         one changed path per line
#     required:
#       --protected FILE     manifest: '<role> <glob>' per line, '#' comments
#       --incumbent FILE     per-task results: '<split> <task_id> <pass|fail>'
#       --candidate FILE     same format, same tasks, from the candidate run
#       --cited FILE         episode ids the change claims to fix, one per line
#       --confirmed FILE     episode ids an oracle outside the loop reproduced
#     optional:
#       --veto CMD           run via bash from the repo; nonzero = REJECT (repeatable)
#       --strict             reject any per-task regression, not just net counts
#       --id NAME            candidate label (default: head of --git range, else 'candidate')
#       --incumbent-tag TAG  the last promoted version the live harness stays on
#       --approver NAME      the named person who reads this report
#       --ledger FILE        append one TSV row per run (for `stats`)
#   harness-promotion-gate.sh stats LEDGER   accept/reject counts per ledger
#
# Results splits: 'proposer' (what the optimizer learns from) and 'gate'
# (never shown to the proposer). Any 'release' row is a REJECT: the release
# holdout is run by a person, and the automated gate should never hold it.
# Result values: pass|1|true and fail|0|false|error|timeout (case-insensitive).
#
# Manifest globs: '*' matches across '/', so 'evals/*' covers the tree; a
# trailing '/' protects a directory prefix. Broad on purpose.
#
# Exit: 0 PROMOTE, 1 REJECT, 3 FALLBACK, 2 usage or input error.
# Dependencies: bash 4+, coreutils, awk; git for --git.

set -euo pipefail

usage() { sed -n '2,57p' "$0" | sed 's/^# \{0,1\}//'; }
die() { printf 'error: %s\n' "$1" >&2; exit 2; }

# ---------------------------------------------------------------- stats mode
if [ "${1:-}" = "stats" ]; then
  [ "$#" -eq 2 ] || die "usage: harness-promotion-gate.sh stats LEDGER"
  [ -f "$2" ] || die "ledger not found: $2"
  awk -F'\t' '
    NF >= 3 { n++; v[$3]++; if ($3 == "REJECT" && $9 ~ /splits/) reg++ }
    END {
      if (n == 0) { print "ledger is empty"; exit }
      printf "candidates: %d\n", n
      printf "  PROMOTE   %d (%.1f%%)\n", v["PROMOTE"], 100 * v["PROMOTE"] / n
      printf "  REJECT    %d (%.1f%%)\n", v["REJECT"], 100 * v["REJECT"] / n
      printf "  FALLBACK  %d (%.1f%%)\n", v["FALLBACK"], 100 * v["FALLBACK"] / n
      printf "  rejected with a split regression among the reasons: %d\n", reg
      print ""
      print "Reference point, not a target: Henry Pan reported 768 of 1,231 non-baseline"
      print "candidates (about 62%) discarded because a baseline-solved task regressed."
      print "A gate that rarely says no is not gating."
    }' "$2"
  exit 0
fi

# ------------------------------------------------------------------- args
GIT_RANGE="" REPO="" DIFF="" PATHS="" PROTECTED="" INC="" CAND="" CITED="" CONFIRMED=""
STRICT=0 ID="" TAG="" APPROVER="" LEDGER=""
VETOES=()

need() { [ "$#" -ge 2 ] || die "$1 needs a value"; }
while [ "$#" -gt 0 ]; do
  case "$1" in
    --git) need "$@"; GIT_RANGE="$2"; shift 2 ;;
    --repo) need "$@"; REPO="$2"; shift 2 ;;
    --diff) need "$@"; DIFF="$2"; shift 2 ;;
    --paths) need "$@"; PATHS="$2"; shift 2 ;;
    --protected) need "$@"; PROTECTED="$2"; shift 2 ;;
    --incumbent) need "$@"; INC="$2"; shift 2 ;;
    --candidate) need "$@"; CAND="$2"; shift 2 ;;
    --cited) need "$@"; CITED="$2"; shift 2 ;;
    --confirmed) need "$@"; CONFIRMED="$2"; shift 2 ;;
    --veto) need "$@"; VETOES+=("$2"); shift 2 ;;
    --strict) STRICT=1; shift ;;
    --id) need "$@"; ID="$2"; shift 2 ;;
    --incumbent-tag) need "$@"; TAG="$2"; shift 2 ;;
    --approver) need "$@"; APPROVER="$2"; shift 2 ;;
    --ledger) need "$@"; LEDGER="$2"; shift 2 ;;
    -h|--help) usage; exit 0 ;;
    *) die "unknown argument '$1' (see --help)" ;;
  esac
done

n_src=0
for s in "$GIT_RANGE" "$DIFF" "$PATHS"; do [ -n "$s" ] && n_src=$((n_src + 1)); done
[ "$n_src" -eq 1 ] || die "give exactly one of --git, --diff, --paths"
for pair in "--protected:$PROTECTED" "--incumbent:$INC" "--candidate:$CAND" \
            "--cited:$CITED" "--confirmed:$CONFIRMED"; do
  flag=${pair%%:*} val=${pair#*:}
  [ -n "$val" ] || die "$flag is required"
  { [ -r "$val" ] && ! [ -d "$val" ]; } || die "$flag file not readable: $val"
done
[ -z "$PATHS" ] || { [ -r "$PATHS" ] && ! [ -d "$PATHS" ]; } || die "--paths file not readable: $PATHS"
[ -z "$DIFF" ] || [ "$DIFF" = "-" ] || { [ -r "$DIFF" ] && ! [ -d "$DIFF" ]; } || die "--diff file not readable: $DIFF"
[ -z "$REPO" ] || [ -d "$REPO" ] || die "--repo not a directory: $REPO"
REPO=${REPO:-$PWD}

WORK=$(mktemp -d)
trap 'rm -f "$WORK"/*; rmdir "$WORK"' EXIT

strip() { sed -e 's/#.*//' -e 's/^[[:space:]]*//' -e 's/[[:space:]]*$//' "$1" | awk 'NF'; }

# --------------------------------------------------------- changed paths
ADDED=0 REMOVED=0 HAVE_LINES=0
if [ -n "$GIT_RANGE" ]; then
  command -v git >/dev/null || die "git required for --git"
  git -C "$REPO" rev-parse --git-dir >/dev/null 2>&1 || die "not a git repo: $REPO"
  git -C "$REPO" diff --name-status -M "$GIT_RANGE" >"$WORK/ns" 2>"$WORK/err" \
    || die "git diff $GIT_RANGE failed: $(head -1 "$WORK/err")"
  # rename/copy rows carry old and new path; both count as touched
  awk -F'\t' '{ for (i = 2; i <= NF; i++) print $i }' "$WORK/ns" >"$WORK/paths"
  read -r ADDED REMOVED < <(git -C "$REPO" diff --numstat -M "$GIT_RANGE" \
    | awk '$1 != "-" { a += $1; r += $2 } END { print a + 0, r + 0 }')
  HAVE_LINES=1
  if [ -z "$ID" ]; then
    head_ref=${GIT_RANGE##*..}
    ID=$(git -C "$REPO" rev-parse --short "${head_ref:-HEAD}" 2>/dev/null || echo candidate)
  fi
elif [ -n "$DIFF" ]; then
  if [ "$DIFF" = "-" ]; then cat >"$WORK/diff"; else cp "$DIFF" "$WORK/diff"; fi
  # Hunk-length aware, so a removed line that starts with "--" is never read
  # as a file header, and concatenated plain `diff -u` output still parses.
  awk -v paths="$WORK/paths" -v counts="$WORK/counts" '
    function clean(p) { sub(/\t.*/, "", p); sub(/^"/, "", p); sub(/"$/, "", p); return p }
    function len(spec) { return (spec ~ /,/) ? substr(spec, index(spec, ",") + 1) + 0 : 1 }
    old > 0 || nw > 0 {
      c = substr($0, 1, 1)
      if (c == "+") { a++; nw-- } else if (c == "-") { r++; old-- }
      else if (c == "\\") { } else { old--; nw-- }
      next
    }
    /^rename (from|to) / { p = $0; sub(/^rename (from|to) /, "", p); print clean(p) > paths; next }
    /^--- / { p = clean(substr($0, 5)); if (p != "/dev/null") { sub(/^a\//, "", p); print p > paths }; next }
    /^\+\+\+ / { p = clean(substr($0, 5)); if (p != "/dev/null") { sub(/^b\//, "", p); print p > paths }; next }
    /^@@ / { old = len(substr($2, 2)); nw = len(substr($3, 2)); next }
    END { print a + 0, r + 0 > counts; close(paths) }
  ' "$WORK/diff"
  touch "$WORK/paths"
  if [ -s "$WORK/diff" ] && ! [ -s "$WORK/paths" ]; then
    die "--diff has content but no file headers parsed; is it a unified diff?"
  fi
  read -r ADDED REMOVED <"$WORK/counts"
  HAVE_LINES=1
else
  strip "$PATHS" >"$WORK/paths"
fi
sort -u "$WORK/paths" -o "$WORK/paths"
ID=${ID:-candidate}
N_CHANGED=$(wc -l <"$WORK/paths" | tr -d ' ')

# --------------------------------------------------------- manifest
strip "$PROTECTED" >"$WORK/manifest"
[ -s "$WORK/manifest" ] || die "protected manifest is empty: with nothing protected the evaluator is editable"
awk 'NF != 2 { printf "line %d: want <role> <glob>, got: %s\n", NR, $0; bad = 1 } END { exit bad }' \
  "$WORK/manifest" >"$WORK/merr" || die "malformed manifest: $(head -1 "$WORK/merr")"

# --------------------------------------------------------- results
# emits: SPLIT name n inc cand | REG split task | GAIN split task | ERR msg
awk '
  function norm(v) {
    v = tolower(v)
    if (v == "pass" || v == "1" || v == "true") return 1
    if (v == "fail" || v == "0" || v == "false" || v == "error" || v == "timeout") return 0
    return -1
  }
  FNR == 1 { f++ }
  /^[[:space:]]*(#|$)/ { next }
  {
    who = (f == 1) ? "incumbent" : "candidate"
    if (NF != 3) { printf "ERR %s line %d: want <split> <task_id> <result>\n", who, FNR; next }
    s = $1; t = $2; r = norm($3)
    if (r < 0) { printf "ERR %s line %d: result \"%s\" is not pass/fail\n", who, FNR, $3; next }
    k = s SUBSEP t
    if (f == 1) { if (k in I) printf "ERR incumbent: duplicate %s %s\n", s, t; I[k] = r }
    else        { if (k in C) printf "ERR candidate: duplicate %s %s\n", s, t; C[k] = r }
    splits[s] = 1
  }
  END {
    for (k in I) if (!(k in C)) { split(k, a, SUBSEP); printf "ERR task in incumbent only: %s %s\n", a[1], a[2] }
    for (k in C) if (!(k in I)) { split(k, a, SUBSEP); printf "ERR task in candidate only: %s %s\n", a[1], a[2] }
    for (k in I) if (k in C) {
      split(k, a, SUBSEP); s = a[1]
      n[s]++; ip[s] += I[k]; cp[s] += C[k]
      if (I[k] == 1 && C[k] == 0) printf "REG %s %s\n", s, a[2]
      if (I[k] == 0 && C[k] == 1) printf "GAIN %s %s\n", s, a[2]
    }
    for (s in n) printf "SPLIT %s %d %d %d\n", s, n[s], ip[s], cp[s]
  }
' "$INC" "$CAND" | sort >"$WORK/res"

if grep -q '^ERR ' "$WORK/res"; then
  {
    echo "error: results are malformed or do not line up (pass counts over different task sets mean nothing)"
    grep '^ERR ' "$WORK/res" | head -10 | sed 's/^ERR /  /'
  } >&2
  exit 2
fi
for s in proposer gate; do
  grep -q "^SPLIT $s " "$WORK/res" || die "no '$s' split in the results; the dual-split rule needs proposer and gate"
done

# --------------------------------------------------------- episodes
strip "$CITED" | sort -u >"$WORK/cited"
strip "$CONFIRMED" | sort -u >"$WORK/confirmed"

# ========================================================= evaluate
FAILED=()   # check names that failed
fail() { FAILED+=("$1"); }

# 1. protected paths
: >"$WORK/hits"
while IFS= read -r p; do
  while read -r role glob; do
    hit=0
    # shellcheck disable=SC2053 # unquoted glob match is the point
    case "$glob" in
      */) [[ "$p" == "$glob"* ]] && hit=1 ;;
      *) [[ "$p" == $glob ]] && hit=1 ;;
    esac
    [ "$hit" -eq 1 ] && printf '%s\t%s\t%s\n' "$p" "$role" "$glob" >>"$WORK/hits"
  done <"$WORK/manifest"
done <"$WORK/paths"
[ -s "$WORK/hits" ] && fail protected

# roles the post names as frozen; missing ones are a warning, not a verdict
WARNINGS=()
missing=""
for r in verifier eval-data budget sandbox model-config logs; do
  awk -v r="$r" '$1 == r { f = 1 } END { exit !f }' "$WORK/manifest" || missing="$missing $r"
done
[ -z "$missing" ] || WARNINGS+=("manifest has no role for:$missing (the post freezes the verifier, eval data, budget, sandbox flag, model config, and the logs the verifier reads)")

# 2. vetoes
VETO_LINES=()
for v in "${VETOES[@]+"${VETOES[@]}"}"; do
  if (cd "$REPO" && bash -c "$v") >"$WORK/veto.out" 2>&1; then
    VETO_LINES+=("PASS  $v")
  else
    VETO_LINES+=("FAIL  $v")
    while IFS= read -r l; do VETO_LINES+=("        $l"); done < <(tail -5 "$WORK/veto.out")
    fail veto
  fi
done

# 3. episodes
N_CITED=$(wc -l <"$WORK/cited" | tr -d ' ')
comm -23 "$WORK/cited" "$WORK/confirmed" >"$WORK/unconfirmed"
if [ "$N_CITED" -eq 0 ] || [ -s "$WORK/unconfirmed" ]; then fail episodes; fi

# 4. splits
read -r _ _ P_N P_INC P_CAND < <(grep '^SPLIT proposer ' "$WORK/res")
read -r _ _ G_N G_INC G_CAND < <(grep '^SPLIT gate ' "$WORK/res")
D_IN=$((P_CAND - P_INC)) D_OUT=$((G_CAND - G_INC))
N_REG=$(grep -cE '^REG (proposer|gate) ' "$WORK/res" || true)
SPLIT_FAIL=0
if [ "$D_IN" -lt 0 ] || [ "$D_OUT" -lt 0 ]; then SPLIT_FAIL=1; fi
if [ "$STRICT" -eq 1 ] && [ "$N_REG" -gt 0 ]; then SPLIT_FAIL=1; fi
[ "$SPLIT_FAIL" -eq 1 ] && fail splits
IMPROVED=0
if [ "$D_IN" -gt 0 ] || [ "$D_OUT" -gt 0 ]; then IMPROVED=1; fi

HAS_RELEASE=0
grep -q '^SPLIT release ' "$WORK/res" && { HAS_RELEASE=1; fail release-isolation; }
OTHER_SPLITS=$(awk '$1 == "SPLIT" && $2 != "proposer" && $2 != "gate" && $2 != "release" { print $2 }' "$WORK/res" | paste -sd, -)
[ -z "$OTHER_SPLITS" ] || WARNINGS+=("ignored splits not in the rule: $OTHER_SPLITS")

if [ "${#FAILED[@]}" -gt 0 ]; then VERDICT=REJECT; RC=1
elif [ "$IMPROVED" -eq 0 ]; then VERDICT=FALLBACK; RC=3
else VERDICT=PROMOTE; RC=0
fi
[ -n "$APPROVER" ] || WARNINGS+=("no --approver named; promotion is a person's decision, not this script's")

# ========================================================= report
mark() { local c; for c in "${FAILED[@]+"${FAILED[@]}"}"; do [ "$c" = "$1" ] && { echo FAIL; return; }; done; echo PASS; }
signed() { if [ "$1" -gt 0 ]; then echo "+$1"; else echo "$1"; fi; }
list_res() { { grep "^$1 $2 " "$WORK/res" || true; } | sort -V -k3 | awk -v m="$3" 'NR <= m { print $3 }' | paste -sd' ' -; }

echo "Harness promotion gate: $ID"
echo "  incumbent: ${TAG:-(no --incumbent-tag given)}"
echo "  approver:  ${APPROVER:-(none named)}"
echo "  changed paths: $N_CHANGED$( [ "$HAVE_LINES" -eq 1 ] && echo ", +$ADDED -$REMOVED lines")"
echo

echo "[$(mark protected)] protected paths: no change touches the evaluator or what it reads"
if [ -s "$WORK/hits" ]; then
  awk -F'\t' '{ printf "        %s  (role %s, matched %s)\n", $1, $2, $3 }' "$WORK/hits"
fi
echo "        manifest: $(wc -l <"$WORK/manifest" | tr -d ' ') globs, roles: $(awk '{ print $1 }' "$WORK/manifest" | sort -u | paste -sd' ' -)"

if [ "${#VETOES[@]}" -gt 0 ]; then
  echo "[$(mark veto)] veto: commands that decide regardless of score"
  printf '        %s\n' "${VETO_LINES[@]}"
else
  echo "[----] veto: none configured (--veto runs a check that ignores benchmark score)"
fi

echo "[$(mark episodes)] cited failures: each one reproduced by an oracle outside the loop"
if [ "$N_CITED" -eq 0 ]; then
  echo "        the change cites no failure episode; a change must cite the failure it fixes"
else
  echo "        cited $N_CITED, confirmed $((N_CITED - $(wc -l <"$WORK/unconfirmed" | tr -d ' ')))"
  [ -s "$WORK/unconfirmed" ] && sed 's/^/        not confirmed: /' "$WORK/unconfirmed"
fi
if [ "$HAVE_LINES" -eq 1 ] && [ "$ADDED" -gt 0 ] && [ "$REMOVED" -eq 0 ]; then
  echo "        note: add-only diff. Add-only changes are where phantom fixes accumulate,"
  echo "        because a suppression metric never penalizes a no-op guard."
fi

rule="improve one split, degrade neither"
[ "$STRICT" -eq 1 ] && rule="$rule; --strict: no task regresses"
echo "[$(mark splits)] splits: $rule"
printf '        %-9s %6s %10s %10s %7s\n' split tasks incumbent candidate delta
printf '        %-9s %6s %10s %10s %7s\n' proposer "$P_N" "$P_INC" "$P_CAND" "$(signed "$D_IN")"
printf '        %-9s %6s %10s %10s %7s\n' gate "$G_N" "$G_INC" "$G_CAND" "$(signed "$D_OUT")"
for s in gate proposer; do
  regs=$(list_res REG "$s" 20) gains=$(list_res GAIN "$s" 20)
  [ -z "$regs" ] || echo "        $s regressions: $regs"
  [ -z "$gains" ] || echo "        $s new passes:  $gains"
done
if [ "$STRICT" -eq 0 ] && [ "$SPLIT_FAIL" -eq 0 ] && [ "$N_REG" -gt 0 ]; then
  echo "        $N_REG task(s) regressed inside a non-negative net count; the count rule allows"
  echo "        it, --strict (reject any regressed solved task) does not"
fi
if [ "$D_IN" -gt 0 ] && [ "$D_OUT" -le 0 ]; then
  echo "        the gain is on the split the proposer learned from only; read it as adaptation"
fi

if [ "$HAS_RELEASE" -eq 1 ]; then
  echo "[FAIL] release isolation: results include the 'release' split"
  echo "        the release holdout is run by a person at release; the loop and its gate should never hold it"
fi

if [ "${#WARNINGS[@]}" -gt 0 ]; then
  echo
  printf 'WARN  %s\n' "${WARNINGS[@]}"
fi

echo
case "$VERDICT" in
  PROMOTE)
    echo "VERDICT: PROMOTE (recommendation for ${APPROVER:-the named approver})"
    echo "  Before it goes live: run the release holdout by hand, tag the version, and keep"
    echo "  ${TAG:-the incumbent tag} as the fallback target. This script merges nothing." ;;
  REJECT)
    echo "VERDICT: REJECT (failed: ${FAILED[*]})"
    echo "  The live harness stays on ${TAG:-the incumbent}." ;;
  FALLBACK)
    echo "VERDICT: FALLBACK (no split improved)"
    echo "  The live harness stays on ${TAG:-the incumbent}. Ending a round on the incumbent is a legal outcome." ;;
esac
echo "  Results and confirmed episodes are trusted as given: produce them from the gate's own"
echo "  run, outside the loop's process, not from the change's summary of its tests."

if [ -n "$LEDGER" ]; then
  printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n' \
    "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$ID" "$VERDICT" "$D_IN" "$D_OUT" "$N_REG" \
    "$N_CITED" "$(wc -l <"$WORK/hits" | tr -d ' ')" "$(IFS=,; echo "${FAILED[*]+"${FAILED[*]}"}")" >>"$LEDGER"
fi

exit "$RC"
