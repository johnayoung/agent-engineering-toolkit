#!/usr/bin/env bash
# done-gate.sh: run a task's definition of done as end-state predicates.
#
# From "Your Agent's "Done" Is a Self-Report. Make It a Predicate."
# https://jyoung.dev/blog/agent-done-criteria-predicates/
#
# Reads a predicate file (.done/<task>.json) and checks the repo's final state,
# never the agent's closing message. The same file backs two wires:
#
#   --hook   Claude Code Stop / SubagentStop hook. Exit 2 with the failing
#            predicates on stderr, which blocks the stop and becomes the
#            message Claude sees. A feedback loop, not the gate.
#   --ci     Required status check from a clean checkout. Exit 1 with a
#            summary (also appended to $GITHUB_STEP_SUMMARY when set).
#            This is the gate.
#   lint     Execute nothing. Flag prose criteria, malformed predicates,
#            vague qualifiers, unassigned review items, and exit-code
#            predicates (command/test) with no unchanged_since guard.
#
# Usage:
#   done-gate.sh [--repo DIR] <predicates.json>          run, print a report
#   done-gate.sh --hook [--repo DIR] <predicates.json>   Stop hook mode
#   done-gate.sh --ci [--repo DIR] <predicates.json>     CI gate mode
#   done-gate.sh lint [--repo DIR] <predicates.json>     static checks only
#
# Predicate kinds (the first four are decompose-epic's check-task-graph.sh
# vocabulary, same JSON shape):
#   {"kind":"command","run":"make lint"}                          exit 0
#   {"kind":"test","name":"TestX","run":"go test ./pkg -run TestX"}  exit 0
#   {"kind":"file_exists","path":"docs/api.md"}
#   {"kind":"glob_count","glob":"migrations/*.sql","min":1,"max":3}
#   {"kind":"file_absent","path":"internal/auth/legacy.go"}
#   {"kind":"grep_count","pattern":"legacyAuth\\(","glob":"**/*.go",
#    "exclude":"**/*_test.go","max":0}                           ERE, lines
#   {"kind":"unchanged_since","ref":"origin/main","glob":"**/*_test.go",
#    "except":["internal/auth/legacy_test.go"]}
#
# Exit: report/--ci  0 all pass, 1 any predicate fails, 2 usage/input error
#       --hook       0 all pass, 2 any failure or input error (fails closed)
#       lint         0 clean (warnings allowed), 1 failures, 2 usage error
#
# Dependencies: bash 4+, git, jq, coreutils. The predicate file is code: its
# command and test entries run verbatim through bash from the repo root.

set -euo pipefail

MODE="report"
REPO=""
FILE=""

usage() { sed -n '2,43p' "$0" | sed 's/^# \{0,1\}//'; }

die() { # input errors: exit 2 in every mode; in --hook that blocks the stop
  if [ "$MODE" = "hook" ]; then
    printf 'done-gate: %s\nThe stop is blocked until the predicate file can be read and run.\n' "$1" >&2
  else
    printf 'error: %s\n' "$1" >&2
  fi
  exit 2
}

while [ "$#" -gt 0 ]; do
  case "$1" in
    lint) MODE="lint"; shift ;;
    --hook) MODE="hook"; shift ;;
    --ci) MODE="ci"; shift ;;
    --repo)
      [ "$#" -ge 2 ] || die "--repo needs a value"
      REPO="$2"; shift 2 ;;
    -h|--help) usage; exit 0 ;;
    -*) die "unknown argument '$1' (see --help)" ;;
    *)
      [ -z "$FILE" ] || die "more than one predicate file given"
      FILE="$1"; shift ;;
  esac
done

[ -n "$FILE" ] || { usage >&2; exit 2; }
command -v jq >/dev/null || die "jq required"
command -v git >/dev/null || die "git required"

# Repo root: --repo, else $CLAUDE_PROJECT_DIR in hook mode, else cwd; then its
# git top level when there is one.
if [ -z "$REPO" ]; then
  if [ "$MODE" = "hook" ] && [ -n "${CLAUDE_PROJECT_DIR:-}" ]; then
    REPO="$CLAUDE_PROJECT_DIR"
  else
    REPO="$PWD"
  fi
fi
[ -d "$REPO" ] || die "not a directory: $REPO"
IS_GIT=0
if git -C "$REPO" rev-parse --show-toplevel >/dev/null 2>&1; then
  REPO=$(git -C "$REPO" rev-parse --show-toplevel)
  IS_GIT=1
else
  REPO=$(cd "$REPO" && pwd)
fi

# Predicate file: as given (relative to cwd), else relative to the repo root.
if [ -f "$FILE" ]; then
  FILE_ABS="$(cd "$(dirname "$FILE")" && pwd)/$(basename "$FILE")"
elif [ -f "$REPO/$FILE" ]; then
  FILE_ABS="$REPO/$FILE"
else
  die "predicate file not found: $FILE"
fi

DOC=$(cat "$FILE_ABS")
jq -e 'type == "object"' >/dev/null 2>&1 <<<"$DOC" || die "$FILE is not a JSON object"

# predicates[] (or decompose-epic's accept: object or array). Strings stay
# strings so prose is caught and fails closed.
PREDS=$(jq -c '(.predicates // .accept // null)
  | if type == "array" then . elif . == null then [] else [.] end' <<<"$DOC")
NPRED=$(jq -r 'length' <<<"$PREDS")
TASK=$(jq -r '.task // ""' <<<"$DOC")
BASE=$(jq -r '.base // ""' <<<"$DOC")
REVIEW=$(jq -c '(.review // []) | if type == "array" then . else [.] end' <<<"$DOC")

TMP=$(mktemp -d "${TMPDIR:-/tmp}/done-gate.XXXXXX")
trap 'rm -rf "$TMP"' EXIT

# ---------------------------------------------------------------- helpers ---

pid() { # $1 = predicate JSON, $2 = 1-based index
  jq -r --arg i "$2" 'if type == "object" then (.id // ((.kind // "predicate") + "#" + $i)) else "prose#" + $i end' <<<"$1"
}

list_field() { # $1 = predicate JSON, $2.. = field names; string or array, merged
  local p="$1"; shift
  local f
  for f in "$@"; do
    jq -r --arg f "$f" '(.[$f] // []) | if type == "string" then [.] else . end | .[]' <<<"$p"
  done
}

pathspecs() { # $1 = predicate JSON, $2 = default glob; prints one pathspec per line
  local p="$1" g
  g=$(jq -r '.glob // ""' <<<"$p")
  [ -n "$g" ] || g="$2"
  printf ':(glob)%s\n' "$g"
  list_field "$p" exclude except | while IFS= read -r e; do
    [ -n "$e" ] && printf ':(glob,exclude)%s\n' "$e"
  done
}

resolve_base() { # $1 = ref; prints "<commit> <description>" or nothing
  local ref="$1" c mb
  c=$(git -C "$REPO" rev-parse --verify --quiet "$ref^{commit}" 2>/dev/null || true)
  [ -n "$c" ] || return 0
  mb=$(git -C "$REPO" merge-base "$c" HEAD 2>/dev/null || true)
  if [ -n "$mb" ]; then
    printf '%s merge-base of %s and HEAD (%s)\n' "$mb" "$ref" "${mb:0:7}"
  else
    printf '%s %s (%s, no merge-base with HEAD)\n' "$c" "$ref" "${c:0:7}"
  fi
}

# ------------------------------------------------------------------ lint ---

if [ "$MODE" = "lint" ]; then
  FAILS=0; WARNS=0
  fail() { printf 'FAIL  %s\n' "$1"; FAILS=$((FAILS + 1)); }
  warn() { printf 'WARN  %s\n' "$1"; WARNS=$((WARNS + 1)); }
  pass() { printf 'PASS  %s\n' "$1"; }
  # The post's examples of vague qualifiers. Not exhaustive.
  VAGUE='(cleanly|appropriately|where reasonable)'

  echo "done-gate lint: $FILE"
  echo "Repo: $REPO$([ "$IS_GIT" -eq 1 ] || echo ' (not a git work tree)')"
  echo "Nothing is executed in lint mode."
  echo
  [ -n "$TASK" ] || warn "no 'task' line: the hook and CI messages will not say what the predicates are for"
  [ "$NPRED" -gt 0 ] || fail "no predicates: nothing a machine runs decides done"

  declare -A SEEN=()
  EXIT_CODE_IDS=(); GUARDS=(); STATE=0
  for ((i = 0; i < NPRED; i++)); do
    p=$(jq -c --argjson i "$i" '.[$i]' <<<"$PREDS")
    id=$(pid "$p" $((i + 1)))
    if [ "$(jq -r 'type' <<<"$p")" != "object" ]; then
      fail "$id is prose, not a predicate: $(jq -r 'tostring' <<<"$p"). Rewrite it as a kind a machine runs, or move it under 'review' with a named reviewer"
      continue
    fi
    if [ -z "$(jq -r '.id // ""' <<<"$p")" ]; then
      warn "$id has no 'id': failure messages will name it by position"
    elif [ -n "${SEEN[$id]:-}" ]; then
      fail "duplicate id '$id'"
    fi
    SEEN[$id]=1
    kind=$(jq -r '.kind // ""' <<<"$p")
    has() { [ -n "$(jq -r --arg f "$1" '.[$f] // "" | tostring' <<<"$p")" ]; }
    case "$kind" in
      command)
        has run && pass "$id: command exits 0" || fail "$id: command has no 'run'"
        EXIT_CODE_IDS+=("$id") ;;
      test)
        if has run && has name; then pass "$id: test $(jq -r .name <<<"$p") exits 0"
        else fail "$id: test needs both 'name' and 'run'"; fi
        EXIT_CODE_IDS+=("$id") ;;
      file_exists|file_absent)
        has path && pass "$id: $kind $(jq -r .path <<<"$p")" || fail "$id: $kind has no 'path'"
        STATE=1 ;;
      glob_count)
        has glob && pass "$id: glob_count $(jq -r .glob <<<"$p")" || fail "$id: glob_count has no 'glob'"
        STATE=1 ;;
      grep_count)
        pat=$(jq -r '.pattern // ""' <<<"$p")
        if [ -z "$pat" ]; then fail "$id: grep_count has no 'pattern'"
        elif ! has max && ! has min; then fail "$id: grep_count needs 'max' (usually 0) or 'min'"
        else
          rc=0; grep -E -e "$pat" </dev/null >/dev/null 2>&1 || rc=$?
          if [ "$rc" -ge 2 ]; then fail "$id: pattern is not a valid extended regex: $pat"
          else pass "$id: grep_count $pat"; fi
        fi
        STATE=1 ;;
      unchanged_since)
        ref=$(jq -r '.ref // ""' <<<"$p"); [ -n "$ref" ] || ref="$BASE"
        if ! has glob; then fail "$id: unchanged_since has no 'glob'"
        elif [ -z "$ref" ]; then fail "$id: unchanged_since has no 'ref' and the file has no top-level 'base'"
        else
          pass "$id: unchanged_since $ref for $(jq -r .glob <<<"$p")"
          GUARDS+=("$id")
          if [ "$IS_GIT" -eq 1 ]; then
            [ -n "$(resolve_base "$ref")" ] \
              || warn "$id: ref '$ref' does not resolve here (fetch it; in CI use fetch-depth: 0)"
            mapfile -t specs < <(pathspecs "$p" "")
            n=$(git -C "$REPO" ls-files -- "${specs[@]}" 2>/dev/null | wc -l | tr -d ' ')
            if [ "$n" -gt 0 ]; then echo "      guards $n tracked file(s)"
            else warn "$id: glob matches no tracked file, so it guards nothing today"; fi
          fi
        fi ;;
      "") fail "$id has no 'kind'" ;;
      *) fail "$id: kind '$kind' is not one of command, test, file_exists, glob_count, file_absent, grep_count, unchanged_since" ;;
    esac
  done

  echo
  echo "== Exit-code predicates"
  if [ "${#EXIT_CODE_IDS[@]}" -eq 0 ]; then
    echo "      none"
  elif [ "${#GUARDS[@]}" -eq 0 ]; then
    for id in "${EXIT_CODE_IDS[@]}"; do
      fail "$id passes on an exit code alone, with no unchanged_since guard on the tests it runs. A new TestMain that calls os.Exit(0), or an edited expected value, turns it green"
    done
  else
    pass "${#EXIT_CODE_IDS[@]} exit-code predicate(s), guarded by: ${GUARDS[*]}"
    echo "      Confirm the guard glob covers every test file those commands run; this"
    echo "      script cannot see which files a command loads."
  fi
  [ "${#EXIT_CODE_IDS[@]}" -eq 0 ] || [ "$STATE" -eq 1 ] \
    || warn "no state predicate (file_exists, file_absent, glob_count, grep_count): every check here reads an exit code, none reads the repo"

  echo
  echo "== Review (never counts toward pass)"
  nrev=$(jq -r 'length' <<<"$REVIEW")
  [ "$nrev" -gt 0 ] || echo "      none"
  for ((i = 0; i < nrev; i++)); do
    r=$(jq -c --argjson i "$i" '.[$i]' <<<"$REVIEW")
    crit=$(jq -r 'if type == "object" then (.criterion // "") else tostring end' <<<"$r")
    who=$(jq -r 'if type == "object" then (.reviewer // "") else "" end' <<<"$r")
    if grep -qiE "$VAGUE" <<<"$crit"; then
      fail "review item has a vague qualifier: \"$crit\". Rewrite it as a design judgment, a golden-file test, or an out-of-band check, or delete it"
    elif [ -z "$who" ]; then
      warn "no named reviewer: \"$crit\". Use {\"criterion\": \"...\", \"reviewer\": \"@name\"}"
    else
      pass "\"$crit\" -> $who"
    fi
  done
  for ((i = 0; i < NPRED; i++)); do
    p=$(jq -c --argjson i "$i" '.[$i]' <<<"$PREDS")
    if [ "$(jq -r 'type' <<<"$p")" = "string" ] && grep -qiE "$VAGUE" <<<"$(jq -r . <<<"$p")"; then
      warn "prose criterion also carries a vague qualifier: $(jq -r . <<<"$p")"
    fi
  done

  echo
  echo "== Not checkable here"
  case "$FILE_ABS" in
    "$REPO"/*) echo "      The predicate file is inside the worktree, so the agent can edit it unless a"
               echo "      deny rule and code-owner review guard it. CI should take it from the base branch." ;;
    *) echo "      The predicate file lives outside the worktree." ;;
  esac
  echo "      Held-out tests, read-only test files, and a clean CI checkout are wiring,"
  echo "      not file contents. See the README."
  echo
  if [ "$FAILS" -gt 0 ]; then
    echo "Verdict: NOT READY -- $FAILS failure(s), $WARNS warning(s)"
    exit 1
  fi
  echo "Verdict: READY -- $WARNS warning(s)"
  exit 0
fi

# ------------------------------------------------------------------- run ---

R_ID=(); R_KIND=(); R_OK=(); R_SUM=(); R_OUT=()

record() { # id kind ok(0/1) summary outfile-or-empty
  R_ID+=("$1"); R_KIND+=("$2"); R_OK+=("$3"); R_SUM+=("$4"); R_OUT+=("$5")
}

run_pred() { # $1 = predicate JSON, $2 = index (1-based)
  local p="$1" id kind path glob n min max pat ref base desc out rc specs
  id=$(pid "$p" "$2")
  if [ "$(jq -r 'type' <<<"$p")" != "object" ]; then
    record "$id" prose 1 "prose, not a predicate: nothing runs it, so it fails closed" ""
    return
  fi
  kind=$(jq -r '.kind // ""' <<<"$p")
  case "$kind" in
    command|test)
      local run name
      run=$(jq -r '.run // ""' <<<"$p")
      name=$(jq -r '.name // ""' <<<"$p")
      if [ -z "$run" ]; then record "$id" "$kind" 1 "no 'run' command" ""; return; fi
      out="$TMP/out.$2"
      rc=0; (cd "$REPO" && bash -c "$run") </dev/null >"$out" 2>&1 || rc=$?
      local what="$run"; [ "$kind" = "test" ] && [ -n "$name" ] && what="$name: $run"
      if [ "$rc" -eq 0 ]; then record "$id" "$kind" 0 "exit 0: $what" ""
      else record "$id" "$kind" 1 "exit $rc: $what" "$out"; fi ;;
    file_exists)
      path=$(jq -r '.path // ""' <<<"$p")
      if [ -z "$path" ]; then record "$id" "$kind" 1 "no 'path'" ""
      elif [ -e "$REPO/$path" ] || [ -L "$REPO/$path" ]; then record "$id" "$kind" 0 "$path exists" ""
      else record "$id" "$kind" 1 "$path is missing" ""; fi ;;
    file_absent)
      path=$(jq -r '.path // ""' <<<"$p")
      if [ -z "$path" ]; then record "$id" "$kind" 1 "no 'path'" ""
      elif [ -e "$REPO/$path" ] || [ -L "$REPO/$path" ]; then record "$id" "$kind" 1 "$path exists" ""
      else record "$id" "$kind" 0 "$path is absent" ""; fi ;;
    glob_count)
      glob=$(jq -r '.glob // ""' <<<"$p")
      min=$(jq -r '.min // 1' <<<"$p"); max=$(jq -r '.max // ""' <<<"$p")
      if [ -z "$glob" ]; then record "$id" "$kind" 1 "no 'glob'" ""; return; fi
      n=$(cd "$REPO" && shopt -s globstar nullglob && IFS='' && c=0 \
          && for f in $glob; do { [ -e "$f" ] || [ -L "$f" ]; } && c=$((c + 1)); done; echo "$c")
      local bound=">= $min"; [ -n "$max" ] && bound="$min..$max"
      if [ "$n" -ge "$min" ] && { [ -z "$max" ] || [ "$n" -le "$max" ]; }; then
        record "$id" "$kind" 0 "$n path(s) match $glob (want $bound)" ""
      else
        record "$id" "$kind" 1 "$n path(s) match $glob (want $bound)" ""
      fi ;;
    grep_count)
      pat=$(jq -r '.pattern // ""' <<<"$p")
      min=$(jq -r '.min // ""' <<<"$p"); max=$(jq -r '.max // ""' <<<"$p")
      if [ -z "$pat" ]; then record "$id" "$kind" 1 "no 'pattern'" ""; return; fi
      if [ -z "$min" ] && [ -z "$max" ]; then record "$id" "$kind" 1 "no 'max' or 'min' bound" ""; return; fi
      if [ "$IS_GIT" -ne 1 ]; then record "$id" "$kind" 1 "not a git work tree; grep_count needs git grep" ""; return; fi
      mapfile -t specs < <(pathspecs "$p" "**")
      out="$TMP/out.$2"
      rc=0; git -C "$REPO" grep --untracked -n -I -E -e "$pat" -- "${specs[@]}" >"$out" 2>&1 || rc=$?
      if [ "$rc" -gt 1 ]; then record "$id" "$kind" 1 "git grep failed (exit $rc)" "$out"; return; fi
      n=$(wc -l <"$out" | tr -d ' ')
      local want=""; [ -n "$min" ] && want="min $min"; [ -n "$max" ] && want="${want:+$want, }max $max"
      if { [ -z "$min" ] || [ "$n" -ge "$min" ]; } && { [ -z "$max" ] || [ "$n" -le "$max" ]; }; then
        record "$id" "$kind" 0 "$n line(s) match /$pat/ ($want)" ""
      else
        record "$id" "$kind" 1 "$n line(s) match /$pat/ ($want)" "$out"
      fi ;;
    unchanged_since)
      glob=$(jq -r '.glob // ""' <<<"$p")
      ref=$(jq -r '.ref // ""' <<<"$p"); [ -n "$ref" ] || ref="$BASE"
      if [ -z "$glob" ]; then record "$id" "$kind" 1 "no 'glob'" ""; return; fi
      if [ -z "$ref" ]; then record "$id" "$kind" 1 "no 'ref' and no top-level 'base'" ""; return; fi
      if [ "$IS_GIT" -ne 1 ]; then record "$id" "$kind" 1 "not a git work tree; unchanged_since needs git" ""; return; fi
      desc=$(resolve_base "$ref")
      if [ -z "$desc" ]; then
        record "$id" "$kind" 1 "ref '$ref' does not resolve (fetch it; in CI use fetch-depth: 0)" ""; return
      fi
      base=${desc%% *}; desc=${desc#* }
      mapfile -t specs < <(pathspecs "$p" "")
      out="$TMP/out.$2"
      rc=0
      { git -C "$REPO" diff --name-status "$base" -- "${specs[@]}"
        git -C "$REPO" ls-files --others --exclude-standard -- "${specs[@]}" | sed 's/^/?\t/'
      } >"$out" 2>&1 || rc=$?
      if [ "$rc" -ne 0 ]; then record "$id" "$kind" 1 "git diff failed" "$out"; return; fi
      n=$(wc -l <"$out" | tr -d ' ')
      if [ "$n" -eq 0 ]; then record "$id" "$kind" 0 "no $glob changed since $desc" ""
      else record "$id" "$kind" 1 "$n $glob path(s) modified, added, or deleted since $desc" "$out"; fi ;;
    "") record "$id" "?" 1 "no 'kind'" "" ;;
    *) record "$id" "$kind" 1 "unknown kind '$kind': fails closed" "" ;;
  esac
}

for ((i = 0; i < NPRED; i++)); do
  run_pred "$(jq -c --argjson i "$i" '.[$i]' <<<"$PREDS")" $((i + 1))
done

NFAIL=0
for ok in "${R_OK[@]}"; do [ "$ok" -eq 0 ] || NFAIL=$((NFAIL + 1)); done
[ "$NPRED" -gt 0 ] || NFAIL=1   # an empty definition of done is not a pass

tail_of() { [ -n "$1" ] && [ -s "$1" ] && tail -n 10 "$1" | sed 's/^/        /'; return 0; }

if [ "$MODE" = "hook" ]; then
  [ "$NFAIL" -eq 0 ] && exit 0
  {
    if [ "$NPRED" -eq 0 ]; then
      echo "done-gate: $FILE has no predicates. The stop is blocked: an empty definition of done is not a pass."
    else
      echo "done-gate: $NFAIL of $NPRED predicate(s) in $FILE fail. The stop is blocked until they pass."
    fi
    for i in "${!R_ID[@]}"; do
      [ "${R_OK[$i]}" -eq 0 ] && continue
      echo "- ${R_ID[$i]} (${R_KIND[$i]}): ${R_SUM[$i]}"
      tail_of "${R_OUT[$i]}"
    done
  } >&2
  exit 2
fi

echo "done-gate: $FILE"
[ -n "$TASK" ] && echo "Task: $TASK"
echo "Repo: $REPO"
echo
for i in "${!R_ID[@]}"; do
  if [ "${R_OK[$i]}" -eq 0 ]; then
    printf 'PASS  %s (%s): %s\n' "${R_ID[$i]}" "${R_KIND[$i]}" "${R_SUM[$i]}"
  else
    printf 'FAIL  %s (%s): %s\n' "${R_ID[$i]}" "${R_KIND[$i]}" "${R_SUM[$i]}"
    tail_of "${R_OUT[$i]}"
  fi
done
nrev=$(jq -r 'length' <<<"$REVIEW")
if [ "$nrev" -gt 0 ]; then
  echo
  echo "Review (not counted toward pass):"
  jq -r '.[] | if type == "object" then "  - " + (.criterion // "") + "  [" + (.reviewer // "no reviewer named") + "]"
               else "  - " + tostring + "  [no reviewer named]" end' <<<"$REVIEW"
fi
echo
if [ "$NFAIL" -gt 0 ]; then
  if [ "$NPRED" -eq 0 ]; then
    VERDICT="NOT DONE: no predicates, and an empty definition of done is not a pass"
  else
    VERDICT="NOT DONE: $NFAIL of $NPRED predicate(s) fail"
  fi
else
  VERDICT="DONE: $NPRED of $NPRED predicate(s) pass. Review items above still need their reviewer"
  [ "$nrev" -gt 0 ] || VERDICT="DONE: $NPRED of $NPRED predicate(s) pass"
fi
echo "Verdict: $VERDICT"

if [ "$MODE" = "ci" ] && [ -n "${GITHUB_STEP_SUMMARY:-}" ]; then
  {
    echo "### done-gate: \`$FILE\`"
    [ -n "$TASK" ] && echo "" && echo "$TASK"
    echo ""
    echo "| Result | Predicate | Kind | Detail |"
    echo "|---|---|---|---|"
    for i in "${!R_ID[@]}"; do
      res=PASS; [ "${R_OK[$i]}" -eq 0 ] || res=FAIL
      printf '| %s | `%s` | %s | %s |\n' "$res" "${R_ID[$i]}" "${R_KIND[$i]}" "$(printf '%s' "${R_SUM[$i]}" | sed 's/|/\\|/g')"
    done
    echo ""
    echo "**$VERDICT**"
  } >>"$GITHUB_STEP_SUMMARY"
fi

[ "$NFAIL" -eq 0 ] || exit 1
exit 0
