#!/usr/bin/env bash
# eval-cadence.sh: tier each eval by cost, saturation, and stakes.
#
# From "Diff Review Can't See Your Agent Regress. A Standing Suite Can."
# https://jyoung.dev/blog/standing-agent-eval-suite/
#
# Reads an evals.yaml (or .json) manifest, prices one full run of each eval
# (cost_per_run_usd x trials), computes its tier, and compares that to the
# tier the manifest declares. Nothing is run and no file is edited.
#
# Usage:
#   eval-cadence.sh [report] [opts] <manifest>     tier table + findings (default)
#   eval-cadence.sh check    [opts] <manifest>     exit 1 on any FAIL finding
#   eval-cadence.sh charter  [opts] <manifest>     one-page charter table
#   eval-cadence.sh ci --runner CMD [opts] <manifest>   GitHub Actions workflow
#   eval-cadence.sh ids --tier TIER [opts] <manifest>   eval ids in a tier
#   eval-cadence.sh suite-version <manifest>       print suite_version
#
# Options (each overrides the manifest's top-level cadence: block):
#   --daily-budget USD       one day of eval budget (required, no default)
#   --changes-per-day N      agent-system PRs per day hitting the path
#                            filter (required, no default)
#   --saturation R           pass rate at or above which an eval counts as
#                            saturated (default 1.00)
#   --flake-threshold R      flake rate that fails an eval (default 0.01)
#   --deterministic-kinds L  comma list of kinds with no model call
#                            (default code_assertion)
#   --json                   report: print the computed JSON instead
#   ci only:
#   --runner CMD             your eval runner; called as CMD <id>... with
#                            EVAL_TIER and SUITE_VERSION in its environment
#   --script-path P          where this script lives in your repo
#                            (default ./scripts/eval-cadence.sh)
#   --manifest-path P        manifest path in your repo (default: the
#                            argument if relative, else evals.yaml)
#   --paths L                comma list for the pull_request path filter
#                            (default CLAUDE.md,.claude/**,harness/**,
#                            agent.config.yaml,evals/**; manifest added)
#   --cron EXPR              nightly schedule (default "0 3 * * *")
#
# Tiers: per_change | nightly | pre_release | harden_then_retire
#
# Exit: 0 ok, 1 check found a FAIL, 2 usage or manifest error.
# Dependencies: bash, awk, jq, coreutils.

set -euo pipefail

usage() { sed -n '2,45p' "$0" | sed 's/^# \{0,1\}//'; }
die() { printf 'eval-cadence: %s\n' "$1" >&2; exit 2; }

command -v jq >/dev/null 2>&1 || die "jq is required"

MODE="report"
case "${1:-}" in
  report|check|charter|ci|ids|suite-version) MODE="$1"; shift ;;
  -h|--help) usage; exit 0 ;;
esac

BUDGET="" CHANGES="" SATURATION="" FLAKE="" DETKINDS="" JSON_OUT=0
RUNNER="" SCRIPT_PATH="./scripts/eval-cadence.sh" MANIFEST_PATH="" PATHS=""
CRON="0 3 * * *" TIER="" FILE=""

need() { [ "$#" -ge 2 ] && [ -n "$2" ] || die "$1 needs a value"; }
while [ "$#" -gt 0 ]; do
  case "$1" in
    --daily-budget) need "$@"; BUDGET="$2"; shift 2 ;;
    --changes-per-day) need "$@"; CHANGES="$2"; shift 2 ;;
    --saturation) need "$@"; SATURATION="$2"; shift 2 ;;
    --flake-threshold) need "$@"; FLAKE="$2"; shift 2 ;;
    --deterministic-kinds) need "$@"; DETKINDS="$2"; shift 2 ;;
    --json) JSON_OUT=1; shift ;;
    --runner) need "$@"; RUNNER="$2"; shift 2 ;;
    --script-path) need "$@"; SCRIPT_PATH="$2"; shift 2 ;;
    --manifest-path) need "$@"; MANIFEST_PATH="$2"; shift 2 ;;
    --paths) need "$@"; PATHS="$2"; shift 2 ;;
    --cron) need "$@"; CRON="$2"; shift 2 ;;
    --tier) need "$@"; TIER="$2"; shift 2 ;;
    -h|--help) usage; exit 0 ;;
    -*) die "unknown option $1 (see --help)" ;;
    *) [ -z "$FILE" ] || die "one manifest at a time"; FILE="$1"; shift ;;
  esac
done

[ -n "$FILE" ] || { usage >&2; exit 2; }
[ -f "$FILE" ] || die "manifest not found: $FILE"

numarg() { # validate a numeric CLI value, emit it as JSON or null
  if [ -z "$2" ]; then printf 'null'; return; fi
  [[ "$2" =~ ^[0-9]+([.][0-9]+)?$ ]] || die "$1 must be a non-negative number, got '$2'"
  printf '%s' "$2"
}

# ---------------------------------------------------------------------------
# Manifest to JSON. YAML is read as a flat subset: top-level scalars, a
# cadence: map of scalars, and an evals: list of maps of scalars. Anything
# nested deeper fails closed rather than being half-read.
# ---------------------------------------------------------------------------
parse_yaml() {
  awk '
    function err(m) { printf "eval-cadence: %s:%d: %s\n", FILENAME, NR, m > "/dev/stderr"; bad = 1; exit 2 }
    function trim(s) { sub(/^[ \t]+/, "", s); sub(/[ \t]+$/, "", s); return s }
    function js(s) { gsub(/\\/, "\\\\", s); gsub(/"/, "\\\"", s); gsub(/\t/, "\\t", s); return "\"" s "\"" }
    function scalar(v) {
      v = trim(v)
      if (v ~ /^"/) {
        if (!match(v, /^"([^"\\]|\\.)*"/)) err("unterminated double quote")
        rest = trim(substr(v, RLENGTH + 1))
        if (rest != "" && rest !~ /^#/) err("text after a quoted value")
        v = substr(v, 2, RLENGTH - 2); gsub(/\\"/, "\"", v); return v
      }
      if (v ~ /^\x27/) {
        if (!match(v, /^\x27[^\x27]*\x27/)) err("unterminated single quote")
        return substr(v, 2, RLENGTH - 2)
      }
      sub(/(^|[ \t]+)#.*$/, "", v); v = trim(v)
      if (v ~ /^[|>]/) err("block scalars are not supported")
      if (v ~ /^\{/) err("flow maps are not supported")
      if (v ~ /^\[.*\]$/) { v = substr(v, 2, length(v) - 2) }
      else if (v ~ /^\[/) err("multi-line flow lists are not supported")
      return v
    }
    function kv(s) {
      if (!match(s, /^[A-Za-z0-9_.\/-]+[ \t]*:([ \t]|$)/)) err("expected key: value, got: " s)
      k = s; sub(/[ \t]*:.*$/, "", k)
      v = s; sub(/^[^:]*:/, "", v)
      K = k; V = scalar(v)
    }
    BEGIN { section = ""; n = 0; inItem = 0; dashInd = -1 }
    {
      line = $0; sub(/\r$/, "", line)
      if (line ~ /^[ \t]*(#.*)?$/) next
      if (line ~ /^(---|\.\.\.)[ \t]*$/) next
      if (line ~ /^ *\t/) err("tab indentation")
      match(line, /^ */); ind = RLENGTH; body = substr(line, ind + 1)

      if (ind == 0 && body !~ /^-([ \t]|$)/) {
        kv(body)
        if (V == "") {
          section = K; inItem = 0
          if (section != "evals" && section != "cadence") ignored[++ni] = K
          next
        }
        section = ""
        if ((K in top)) err("duplicate top-level key " K)
        top[K] = V; topk[++nt] = K
        next
      }

      if (section == "evals") {
        if (body ~ /^-([ \t]|$)/) {
          rest = substr(body, 2); sub(/^[ \t]+/, "", rest)
          if (rest == "") err("bare - item; start each eval with - id: ...")
          n++; inItem = 1; dashInd = ind; item[n] = ""; itemLine[n] = NR
          kv(rest)
        } else {
          if (!inItem) err("eval field before the first - item")
          if (ind <= dashInd) err("unexpected indentation under evals")
          kv(body)
        }
        if (V == "" && v !~ /^[ \t]*("|\x27)/) err("nested value under eval field " K " is not supported")
        if (((n, K) in seen)) err("duplicate field " K " in one eval")
        seen[n, K] = 1
        item[n] = item[n] (item[n] == "" ? "" : ",") js(K) ":" js(V)
        next
      }
      if (section == "cadence") {
        kv(body)
        if (V == "") err("nested value under cadence." K " is not supported")
        cad = cad (cad == "" ? "" : ",") js(K) ":" js(V)
        next
      }
      if (section == "") err("indented line outside any block")
      next   # an unrecognised top-level block: skipped, listed in ignored
    }
    END {
      if (bad) exit 2
      printf "{\"top\":{"
      for (i = 1; i <= nt; i++) printf "%s%s:%s", (i > 1 ? "," : ""), js(topk[i]), js(top[topk[i]])
      printf "},\"cadence\":{%s},\"evals\":[", cad
      for (i = 1; i <= n; i++) printf "%s{%s,\"_line\":%d}", (i > 1 ? "," : ""), item[i], itemLine[i]
      printf "],\"ignored\":["
      for (i = 1; i <= ni; i++) printf "%s%s", (i > 1 ? "," : ""), js(ignored[i])
      printf "]}\n"
    }
  ' "$1"
}

parse_json() {
  jq -e '
    if type != "object" then error("manifest must be a JSON object") else . end
    | { top: (with_entries(select(.key != "evals" and .key != "cadence" and (.value | type) != "object" and (.value | type) != "array"))),
        cadence: (.cadence // {}),
        evals: ((.evals // []) | to_entries | map(.value + {_line: (.key + 1)})),
        ignored: [] }
  ' "$1" 2>/dev/null || die "could not read $1 as a JSON manifest object"
}

case "$FILE" in
  *.json) MANIFEST=$(parse_json "$FILE") ;;
  *) MANIFEST=$(parse_yaml "$FILE") || exit 2 ;;
esac

B_J=$(numarg --daily-budget "$BUDGET") || exit 2
C_J=$(numarg --changes-per-day "$CHANGES") || exit 2
S_J=$(numarg --saturation "$SATURATION") || exit 2
F_J=$(numarg --flake-threshold "$FLAKE") || exit 2
CFG=$(jq -n \
  --argjson b "$B_J" --argjson c "$C_J" --argjson s "$S_J" --argjson f "$F_J" \
  --arg d "$DETKINDS" \
  '{daily_budget_usd: $b, changes_per_day: $c, saturation: $s, flake: $f, det: (if $d == "" then null else $d end)}')

# ---------------------------------------------------------------------------
# The tiering logic. Comments name the post section each rule comes from.
# ---------------------------------------------------------------------------
COMPUTED=$(jq -c --argjson cfg "$CFG" --arg mode "$MODE" '
  def numv: if type == "number" then . elif type == "string" then (tonumber? // null) else null end;
  def boolv: if type == "boolean" then . elif . == "true" or . == "yes" then true
             elif . == "false" or . == "no" then false else null end;
  def cents: (. * 100 | round) / 100;
  def money: ((. * 100 | round) as $c | "$\(($c / 100) | floor).\(($c % 100) | tostring | if length < 2 then "0" + . else . end)");
  def splitlist: tostring | split(",") | map(gsub("^\\s+|\\s+$"; "")) | map(select(length > 0));

  . as $m
  | ($m.cadence // {}) as $cad
  | ($cfg.daily_budget_usd // ($cad.daily_budget_usd | numv)) as $B
  | ($cfg.changes_per_day // ($cad.changes_per_day | numv)) as $C
  | ($cfg.saturation // ($cad.saturation_pass_rate | numv) // 1.0) as $S
  | ($cfg.flake // ($cad.flake_threshold | numv) // 0.01) as $F
  | (($cfg.det // $cad.deterministic_kinds // "code_assertion") | splitlist) as $DET
  | ["per_change", "nightly", "pre_release", "harden_then_retire"] as $TIERS
  | ($m.top.suite_version // null) as $ver

  # ---- input validation: collected, then reported together (exit 2) ----
  | [ (if ($cad.daily_budget_usd != null and ($cad.daily_budget_usd | numv) == null) then "cadence.daily_budget_usd is not a number" else empty end),
      (if ($cad.changes_per_day != null and ($cad.changes_per_day | numv) == null) then "cadence.changes_per_day is not a number" else empty end),
      (if ($S < 0 or $S > 1) then "saturation must be between 0 and 1" else empty end),
      (if ($F < 0 or $F > 1) then "flake threshold must be between 0 and 1" else empty end),
      (if ($m.evals | length) == 0 then "manifest has no evals" else empty end),
      ($m.evals | to_entries[] | .key as $i | .value as $e | ("eval #\($i + 1)" + (if $e.id then " (\($e.id))" else "" end)) as $at
        | (if ($e.id // "" | tostring) == "" then "\($at): missing id" else empty end),
          (if ($e.id // "" | tostring | test("\\s")) then "\($at): id contains whitespace" else empty end),
          (if (["regression", "capability"] | index([$e.suite])) == null then "\($at): suite must be regression or capability, got \($e.suite // "nothing")" else empty end),
          (if (["low", "medium", "high"] | index([$e.stakes])) == null then "\($at): stakes must be low, medium, or high, got \($e.stakes // "nothing")" else empty end),
          (if ($e.cost_per_run_usd | numv) == null or ($e.cost_per_run_usd | numv) < 0 then "\($at): cost_per_run_usd must be a number >= 0" else empty end),
          (if $e.trials != null and (($e.trials | numv) == null or ($e.trials | numv) < 1 or (($e.trials | numv) | floor) != ($e.trials | numv)) then "\($at): trials must be an integer >= 1" else empty end),
          (if $e.pass_rate_30d != null and (($e.pass_rate_30d | numv) == null or ($e.pass_rate_30d | numv) < 0 or ($e.pass_rate_30d | numv) > 1) then "\($at): pass_rate_30d must be between 0 and 1" else empty end),
          (if $e.flake_rate_30d != null and (($e.flake_rate_30d | numv) == null or ($e.flake_rate_30d | numv) < 0 or ($e.flake_rate_30d | numv) > 1) then "\($at): flake_rate_30d must be between 0 and 1" else empty end),
          (if $e.saturated != null and ($e.saturated | boolv) == null then "\($at): saturated must be true or false" else empty end),
          (if $e.tier != null and ($TIERS | index([$e.tier])) == null then "\($at): tier must be one of \($TIERS | join(", ")), got \($e.tier)" else empty end)),
      ([$m.evals[].id // empty | tostring] | group_by(.) | map(select(length > 1) | "duplicate eval id \(.[0])") | .[]),
      (if $mode != "ids" and $mode != "suite-version" and $B == null then "no daily budget: pass --daily-budget USD or set cadence.daily_budget_usd. The post prices each run against your budget; there is no default." else empty end),
      (if $mode != "ids" and $mode != "suite-version" and $C == null then "no change rate: pass --changes-per-day N or set cadence.changes_per_day (agent-system PRs per day that hit the path filter)." else empty end),
      (if $mode == "ids" and $B == null and ([$m.evals[] | select(.tier == null)] | length) > 0 then "ids: some evals declare no tier, so a budget is needed to compute one (cadence.daily_budget_usd)" else empty end),
      (if $mode == "ids" and $C == null and ([$m.evals[] | select(.tier == null)] | length) > 0 then "ids: some evals declare no tier, so a change rate is needed (cadence.changes_per_day)" else empty end)
    ] as $errors
  | if ($errors | length) > 0 then {errors: $errors} else

  # ---- per-eval tiering ----
  ($m.evals | map(
    . as $e
    | ($e.cost_per_run_usd | numv) as $cost
    | (($e.trials // 1) | numv) as $trials
    | ($cost * $trials | cents) as $run
    | ($e.pass_rate_30d | numv) as $pass
    | ($e.flake_rate_30d | numv) as $flake
    | (($DET | index([$e.kind // ""])) != null) as $det
    | ((($e.saturated // false) | boolv) or ($pass != null and $pass >= $S)) as $sat
    | ($flake != null and $flake >= $F) as $flaky
    | ($e.owner // "" | tostring | gsub("^\\s+|\\s+$"; "")) as $owner

    # Tier each eval: cheap deterministic checks per change ("Favor assertions
    # or other deterministic checks"); anything that fits one day of budget
    # nightly; a full run over a day of budget waits for a release.
    | (if $B == null or $C == null then null
       elif $det and (($run * $C) | cents) <= $B and ($flaky | not) then {t: "per_change", why: "deterministic; \($run | money) x \($C) changes/day fits the budget"}
       elif $run <= $B then {t: "nightly", why: (if $det and $flaky then "deterministic but flaky, demoted off the PR gate"
                                                elif $det then "deterministic, but \($run | money) x \($C) changes/day exceeds the budget"
                                                else "\($e.kind // "model-graded"): full run of \($run | money) fits one day of budget" end)}
       else {t: "pre_release", why: "one full run (\($run | money)) exceeds a day of budget (\($B | money))"} end) as $cost_tier

    # Saturation: harden before retire; a high-stakes eval keeps running.
    | ($e.suite == "regression" and $sat and ($det | not)) as $harden
    | (if $cost_tier == null then null
       elif $harden and $e.stakes != "high" then {t: "harden_then_retire", why: "saturated, \($e.stakes) stakes, not deterministic"}
       else $cost_tier end) as $tier

    | [ (if $owner == "" then {level: "FAIL", code: "OWNER", msg: "no owner. The case owner decides what correct means inside it; an unowned case gets loosened as a flake fix (CL-7)."} else empty end),
        (if $flaky then {level: "FAIL", code: "FLAKY", msg: "flake rate \($flake) >= \($F). Google: as you approach 1% flakiness, tests begin to lose value. Fix it before it gates anything."} else empty end),
        (if $tier != null and $e.tier != null and $e.tier != $tier.t then
           {level: "FAIL", code: "TIER", msg: (
             if $e.tier == "per_change" and ($det | not) then "declared per_change but not deterministic. Keep model-graded evals and agent runs off the per-change gate; computed \($tier.t)."
             elif $tier.t == "per_change" then "declared \($e.tier), computed per_change. A cheap deterministic check outside the per-change tier delays a signal you could have per PR: promote it."
             elif $tier.t == "harden_then_retire" then "declared \($e.tier), computed harden_then_retire. You are paying for zero information."
             else "declared \($e.tier), computed \($tier.t) (\($tier.why))." end)}
         else empty end),
        (if $e.tier == null and $tier != null then {level: "NOTE", code: "UNDECLARED", msg: "no tier declared; computed \($tier.t). Declare it so CI and reviewers read the same value."} else empty end),
        (if $harden then {level: "NOTE", code: "HARDEN", msg: ("saturated (" + (if $pass != null then "pass rate \($pass * 100 | round)%" else "marked in the manifest" end) + "). An eval at 100% tracks regressions but gives no signal for improvement. Make it harder first; "
             + (if $e.stakes == "high" then "high stakes, so it keeps its cost tier meanwhile." else "if it stays saturated, retire it or run it biweekly." end))} else empty end),
        (if $e.suite == "capability" and $sat then
           (if $trials >= 2 then {level: "NOTE", code: "GRADUATE", msg: "capability eval at \(if $pass == null then "saturation" else "\($pass * 100 | round)%" end) across \($trials) trials: candidate to graduate into the regression suite once it has held across runs, not after one green week."}
            else {level: "NOTE", code: "GRADUATE", msg: "capability eval at \(if $pass == null then "saturation" else "\($pass * 100 | round)%" end) on a single trial: not yet evidence it passes reliably. Raise trials before graduating it."} end)
         else empty end),
        (if ($det | not) and $trials == 1 then {level: "NOTE", code: "TRIALS", msg: "single trial on a non-deterministic eval: you cannot tell a regression from noise. Set trials."} else empty end),
        (if $tier != null and $tier.t == "pre_release" and $e.stakes == "low" and ($det | not) then {level: "NOTE", code: "CODE", msg: "low stakes and over a day of budget per run. Use code instead if possible; otherwise retire it."} else empty end),
        (if $pass == null and ($e.saturated == null) then {level: "NOTE", code: "NO_PASS_RATE", msg: "no pass_rate_30d, so saturation was not assessed."} else empty end)
      ] as $flags
    | {id: ($e.id | tostring), suite: $e.suite, kind: ($e.kind // null), stakes: $e.stakes, owner: (if $owner == "" then null else $owner end),
       cost_per_run_usd: $cost, trials: $trials, run_cost_usd: $run, pass_rate_30d: $pass, flake_rate_30d: $flake,
       deterministic: $det, saturated: $sat, incident: ($e.incident // null),
       declared_tier: ($e.tier // null), computed_tier: (if $tier == null then null else $tier.t end),
       why: (if $tier == null then null else $tier.why end), flags: $flags}
  )) as $evals

  # ---- suite-level projection and findings ----
  | def spend($key):
      ($evals | map(select(.[$key] != null)) ) as $xs
      | { per_change_per_change: ([$xs[] | select(.[$key] == "per_change") | .run_cost_usd] | add // 0 | cents),
          nightly: ([$xs[] | select(.[$key] == "nightly") | .run_cost_usd] | add // 0 | cents),
          pre_release: ([$xs[] | select(.[$key] == "pre_release") | .run_cost_usd] | add // 0 | cents),
          harden_then_retire: ([$xs[] | select(.[$key] == "harden_then_retire") | .run_cost_usd] | add // 0 | cents) }
      | . + {daily: (if $C == null then null else ((.per_change_per_change * $C) + .nightly | cents) end)};
    (spend("computed_tier")) as $sc
  | ($evals | map(.computed_tier = (.declared_tier // .computed_tier))) as $asrun
  | ($asrun | map(select(.computed_tier != null)) | {
        per_change_per_change: ([.[] | select(.computed_tier == "per_change") | .run_cost_usd] | add // 0 | cents),
        nightly: ([.[] | select(.computed_tier == "nightly") | .run_cost_usd] | add // 0 | cents),
        pre_release: ([.[] | select(.computed_tier == "pre_release") | .run_cost_usd] | add // 0 | cents),
        harden_then_retire: ([.[] | select(.computed_tier == "harden_then_retire") | .run_cost_usd] | add // 0 | cents) }
      | . + {daily: (if $C == null then null else ((.per_change_per_change * $C) + .nightly | cents) end)}) as $sd
  | [ (if $ver == null or $ver == "" then {level: "FAIL", code: "SUITE_VERSION", msg: "no suite_version. Record it in every run so results compare like to like."} else empty end),
      (if ([$evals[] | select(.suite == "regression")] | length) == 0 then {level: "FAIL", code: "NO_REGRESSION", msg: "no regression evals. Nothing answers \"does the agent still handle all the tasks it used to?\""} else empty end),
      (if ([$evals[] | select(.suite == "capability")] | length) == 0 then {level: "NOTE", code: "NO_CAPABILITY", msg: "no capability evals. The suite shows what the agent kept, not what it is gaining."} else empty end),
      (if $B != null and $sc.daily != null and $sc.daily > $B then {level: "FAIL", code: "BUDGET", msg: "computed tiers project \($sc.daily | money)/day (per-change \($sc.per_change_per_change | money) x \($C) + nightly \($sc.nightly | money)) against a \($B | money) daily budget. Move evals out of the per-change tier or raise the budget."} else empty end),
      (if $B != null and $sd.daily != null and $sd.daily > $B and $sd != $sc then {level: "FAIL", code: "BUDGET", msg: "declared tiers project \($sd.daily | money)/day against a \($B | money) daily budget."} else empty end),
      (if ($m.ignored | length) > 0 then {level: "NOTE", code: "IGNORED", msg: "top-level blocks not read: \($m.ignored | join(", "))."} else empty end)
    ] as $suite_flags
  | {manifest: $m.top, suite_version: $ver,
     settings: {daily_budget_usd: $B, changes_per_day: $C, saturation: $S, flake_threshold: $F, deterministic_kinds: $DET},
     evals: $evals, spend_computed: $sc, spend_declared: $sd, suite_flags: $suite_flags,
     fail_count: (([$evals[].flags[] | select(.level == "FAIL")] | length) + ([$suite_flags[] | select(.level == "FAIL")] | length))}
  end
' <<<"$MANIFEST") || die "could not evaluate $FILE (jq failed; see above)"

if jq -e 'has("errors")' <<<"$COMPUTED" >/dev/null; then
  jq -r '.errors[] | "eval-cadence: " + .' <<<"$COMPUTED" >&2
  exit 2
fi

# ---------------------------------------------------------------------------
# Renderers
# ---------------------------------------------------------------------------
JQ_FMT='
  def money: ((. * 100 | round) as $c | "$\(($c / 100) | floor).\(($c % 100) | tostring | if length < 2 then "0" + . else . end)");
  def pct: if . == null then "n/a" else "\(. * 100 | round)%" end;
  def cell: tostring | gsub("\\|"; "\\|");
'

render_report() {
  jq -r --arg file "$FILE" "$JQ_FMT"'
    "# eval-cadence: \($file)",
    "",
    "suite_version \(.suite_version // "MISSING") | \(.evals | length) evals (regression \([.evals[] | select(.suite == "regression")] | length), capability \([.evals[] | select(.suite == "capability")] | length)) | budget \(.settings.daily_budget_usd | money)/day | \(.settings.changes_per_day) changes/day | saturated at >= \(.settings.saturation) | flaky at >= \(.settings.flake_threshold)",
    "",
    "## Tiers",
    "",
    "| Eval | Suite | Kind | Full run | Stakes | Pass 30d | Owner | Declared | Computed | Why |",
    "| --- | --- | --- | --- | --- | --- | --- | --- | --- | --- |",
    (.evals[] | "| `\(.id)` | \(.suite) | \(.kind // "?") | \(.cost_per_run_usd | money) x \(.trials) = \(.run_cost_usd | money) | \(.stakes) | \(.pass_rate_30d | pct) | \(.owner // "**none**") | \(.declared_tier // "-") | \(if .declared_tier != null and .declared_tier != .computed_tier then "**\(.computed_tier)**" else .computed_tier end) | \(.why | cell) |"),
    "",
    "## Projected spend (computed tiers)",
    "",
    "| Tier | Per run of the tier | Cadence |",
    "| --- | --- | --- |",
    "| per_change | \(.spend_computed.per_change_per_change | money) | x \(.settings.changes_per_day) changes/day |",
    "| nightly | \(.spend_computed.nightly | money) | once a day |",
    "| pre_release | \(.spend_computed.pre_release | money) | per release |",
    "| harden_then_retire | \(.spend_computed.harden_then_retire | money) | biweekly, if kept |",
    "",
    "Daily: \(.spend_computed.daily | money) of \(.settings.daily_budget_usd | money)." + (if .spend_declared != .spend_computed then " As declared: \(.spend_declared.daily | money)/day." else "" end),
    "",
    "## Findings",
    "",
    (([.suite_flags[] | "- **\(.level) \(.code)** (suite): \(.msg)"] + [.evals[] as $e | $e.flags[] | "- **\(.level) \(.code)** `\($e.id)`: \(.msg)"]) as $all
      | if ($all | length) == 0 then "None." else ($all | sort_by(startswith("- **NOTE")) | .[]) end),
    "",
    "Costs are the manifest'"'"'s cost_per_run_usd x trials, not measured spend. Per-change spend assumes every agent-system change runs the whole per-change tier. Thresholds are the settings line above; tune them to your budget, they are not findings from the post."
  ' <<<"$COMPUTED"
}

render_charter() {
  jq -r --arg file "$FILE" --arg cron "$CRON" "$JQ_FMT"'
    . as $r
    | ($r.evals | map(select(.suite == "regression"))) as $reg
    | ($r.evals | map(select(.suite == "capability"))) as $cap
    | def ids($t): [$r.evals[] | select(.computed_tier == $t) | "`\(.id)`"] | if length == 0 then "none" else join(", ") end;
    "# Eval suite charter: \($r.suite_version // "unversioned")",
    "",
    "Generated by eval-cadence from `\($file)`. Costs are manifest estimates (cost_per_run_usd x trials), not measured spend.",
    "",
    "| Question | This suite |",
    "| --- | --- |",
    "| **Does the agent still work?** | Regression suite of \($reg | length) evals; target pass rate near 100%. Lowest 30d pass rate: \(([$reg[] | .pass_rate_30d | select(. != null)] | min) | pct). |",
    "| **When does it run?** | per_change on PRs touching agent config, harness, and evals; nightly on cron `\($cron)`; pre_release on manual dispatch before a release. The model-alias pin check is not covered by this tool. |",
    "| **What is in it?** | Capability \($cap | length), regression \($reg | length). Graduation candidates: \([$r.evals[] | select(any(.flags[]; .code == "GRADUATE")) | "`\(.id)`"] | if length == 0 then "none" else join(", ") end). |",
    "| **How often does each eval run?** | per_change \([$r.evals[] | select(.computed_tier == "per_change")] | length), nightly \([$r.evals[] | select(.computed_tier == "nightly")] | length), pre_release \([$r.evals[] | select(.computed_tier == "pre_release")] | length), harden_then_retire \([$r.evals[] | select(.computed_tier == "harden_then_retire")] | length). Projected \($r.spend_computed.daily | money)/day against \($r.settings.daily_budget_usd | money). |",
    "| **How does it grow?** | Regression cases linked to an incident: \([$reg[] | select(.incident != null)] | length) of \($reg | length) (`incident:` field). |",
    "| **Who keeps it honest?** | Owners: \([$r.evals[] | .owner | select(. != null)] | unique | join(", ")). Unowned: \([$r.evals[] | select(.owner == null) | "`\(.id)`"] | if length == 0 then "none" else join(", ") end). Suite edits are reviewed by the case owner. |",
    "",
    "| Tier | Trigger | Evals | Cost per run of the tier | Owners |",
    "| --- | --- | --- | --- | --- |",
    (("per_change", "nightly", "pre_release", "harden_then_retire") as $t
      | "| \($t) | \({per_change: "pull_request, path-filtered", nightly: "cron `\($cron)`", pre_release: "workflow_dispatch before release", harden_then_retire: "twice monthly while hardened, then retire"}[$t]) | \(ids($t)) | \($r.spend_computed[if $t == "per_change" then "per_change_per_change" else $t end] | money) | \([$r.evals[] | select(.computed_tier == $t) | .owner // "none"] | unique | if length == 0 then "-" else join(", ") end) |"),
    "",
    "Open FAIL findings: \($r.fail_count). Run `eval-cadence.sh report` for the list."
  ' <<<"$COMPUTED"
}

render_ci() {
  [ -n "$RUNNER" ] || die "ci needs --runner CMD: the command that runs a list of eval ids. This tool tiers evals; it does not run them."
  case "$RUNNER" in *$'\n'*) die "--runner must be one line" ;; esac
  local mpath="$MANIFEST_PATH"
  if [ -z "$mpath" ]; then case "$FILE" in /*) mpath="evals.yaml" ;; *) mpath="${FILE#./}" ;; esac; fi
  local paths="${PATHS:-CLAUDE.md,.claude/**,harness/**,agent.config.yaml,evals/**}"
  local plist
  plist=$(jq -rn --arg p "$paths" --arg m "$mpath" '($p | split(",") | map(gsub("^\\s+|\\s+$"; "")) | map(select(length > 0))) as $l
    | (if ($l | index([$m])) or ($m | startswith("evals/")) then $l else $l + [$m] end) | map("\"" + . + "\"") | join(", ")')
  local extra=""
  [ -n "$BUDGET" ] && extra+=" --daily-budget $BUDGET"
  [ -n "$CHANGES" ] && extra+=" --changes-per-day $CHANGES"
  [ -n "$SATURATION" ] && extra+=" --saturation $SATURATION"
  [ -n "$FLAKE" ] && extra+=" --flake-threshold $FLAKE"
  [ -n "$DETKINDS" ] && extra+=" --deterministic-kinds $DETKINDS"
  local has_htr
  has_htr=$(jq -r '[.evals[] | select((.declared_tier // .computed_tier) == "harden_then_retire")] | length' <<<"$COMPUTED")

  job() { # name, condition, tier
    cat <<EOF
  $1:
    if: $2
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v4
      - name: Run the $3 tier
        run: |
          ids="\$($SCRIPT_PATH ids --tier $3$extra $mpath)"
          if [ -z "\$ids" ]; then echo "eval-cadence: no $3 evals"; exit 0; fi
          export EVAL_TIER=$3
          export SUITE_VERSION="\$($SCRIPT_PATH suite-version $mpath)"
          $RUNNER \$ids
EOF
  }

  cat <<EOF
# Generated by eval-cadence.sh from $mpath. Tier membership is read from the
# manifest at run time, so a tier change is a reviewed manifest edit, not a
# workflow edit. The runner receives eval ids as arguments.
name: agent-evals
on:
  pull_request:
    paths: [$plist]
  schedule:
    - cron: "$CRON"
EOF
  [ "$has_htr" -gt 0 ] && cat <<EOF
    - cron: "0 4 1,15 * *"   # harden_then_retire, twice monthly
EOF
  cat <<EOF
  workflow_dispatch:
    inputs:
      tier:
        description: "Tier to run"
        type: choice
        options: [pre_release, nightly, per_change]
        default: pre_release
jobs:
  cadence-check:
    if: github.event_name == 'pull_request'
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v4
      - name: Owners, tiers, and budget still hold
        run: $SCRIPT_PATH check$extra $mpath
EOF
  job per-change "github.event_name == 'pull_request' || (github.event_name == 'workflow_dispatch' && inputs.tier == 'per_change')" per_change
  job nightly "(github.event_name == 'schedule' && github.event.schedule == '$CRON') || (github.event_name == 'workflow_dispatch' && inputs.tier == 'nightly')" nightly
  job pre-release "github.event_name == 'workflow_dispatch' && inputs.tier == 'pre_release'" pre_release
  if [ "$has_htr" -gt 0 ]; then
    job harden-then-retire "github.event_name == 'schedule' && github.event.schedule == '0 4 1,15 * *'" harden_then_retire
  fi
}

case "$MODE" in
  report)
    if [ "$JSON_OUT" -eq 1 ]; then jq . <<<"$COMPUTED"; else render_report; fi ;;
  check)
    render_report
    fails=$(jq -r '.fail_count' <<<"$COMPUTED")
    if [ "$fails" -gt 0 ]; then printf '\neval-cadence: %s FAIL finding(s)\n' "$fails" >&2; exit 1; fi ;;
  charter) render_charter ;;
  ci) render_ci ;;
  ids)
    case "$TIER" in
      per_change|nightly|pre_release|harden_then_retire) ;;
      *) die "ids needs --tier per_change|nightly|pre_release|harden_then_retire" ;;
    esac
    jq -r --arg t "$TIER" '.evals[] | select((.declared_tier // .computed_tier) == $t) | .id' <<<"$COMPUTED" ;;
  suite-version)
    jq -r '.suite_version // empty' <<<"$COMPUTED" ;;
esac
