#!/usr/bin/env bash
# always-on-preflight.sh: static preflight for a coding agent that runs with
# nobody in the session (GitHub Actions on schedule or repo events, plus
# Claude Managed Agents scheduled-deployment frontmatter).
#
# From "Always-On Agents: What Breaks When Nobody Is in the Session"
# https://jyoung.dev/blog/always-on-agents/
#
# For every workflow that runs an agent action on a trigger nobody presses,
# it checks the lines the post fixes, then prints the post's standing-agent
# table filled in from what a static read can see:
#
#   Deduplication  concurrency: group present (and not keyed on the run id);
#                  a dedup key on event triggers when the agent can write;
#                  cron in a declared non-UTC time zone inside the 1-3 AM
#                  local DST window.
#   Identity       stored model credential (anthropic_api_key,
#                  claude_code_oauth_token) instead of OIDC federation;
#                  a stored GitHub token in place of the GitHub App;
#                  who GitHub credits for scheduled runs (last cron editor).
#   Memory         prompt that tells the agent to rewrite its own notes (heuristic).
#   Approval       fired prompt that asks for a merge, deploy or close (heuristic).
#   Watching       alerting defined inside the repo the agent can write,
#                  alerting keyed on a red run instead of a missing outcome,
#                  CODEOWNERS entry for the workflow file.
#
# Usage:
#   always-on-preflight.sh [options] [WORKFLOW_FILE...]
#     --repo DIR          repo to scan (default: cwd). Without WORKFLOW_FILE
#                         args, scans DIR/.github/workflows/*.yml|*.yaml.
#     --agent REGEX       ERE matched against step `uses:` (default:
#                         anthropics/claude-code-(base-)?action)
#     --deployment FILE   a scheduled-deployment file (YAML, or .md with YAML
#                         frontmatter). Repeatable. Without it, the repo is
#                         searched for files with a schedule.expression key.
#     --no-table          findings only
#     -h, --help
#
# Statuses:
#   FAIL    the post's "as first deployed" shape is present. Exit 1.
#   WARN    a heuristic match or a likely gap. Read the cited line.
#   REVIEW  not answerable from the file. A person answers it.
#   OK      the check passed on what is visible.
#
# It reads files and git history. It edits nothing.
# Exit: 0 no FAIL, 1 at least one FAIL, 2 usage error.
# Dependencies: bash 4+, coreutils, awk, grep; git (optional, for attribution).

set -euo pipefail

usage() { sed -n '2,47p' "$0" | sed 's/^# \{0,1\}//'; }
die() { printf 'error: %s\n' "$1" >&2; exit 2; }

REPO="" AGENT_RE='anthropics/claude-code-(base-)?action' TABLE=1
FILES=() DEPLOYS=()
need() { [ "$#" -ge 2 ] || die "$1 needs a value"; }
while [ "$#" -gt 0 ]; do
  case "$1" in
    --repo) need "$@"; REPO="$2"; shift 2 ;;
    --agent) need "$@"; AGENT_RE="$2"; shift 2 ;;
    --deployment) need "$@"; DEPLOYS+=("$2"); shift 2 ;;
    --no-table) TABLE=0; shift ;;
    -h|--help) usage; exit 0 ;;
    -*) die "unknown option '$1' (see --help)" ;;
    *) FILES+=("$1"); shift ;;
  esac
done
REPO=${REPO:-$PWD}
[ -d "$REPO" ] || die "--repo not a directory: $REPO"
REPO=$(cd "$REPO" && pwd)
for f in ${FILES[@]+"${FILES[@]}"} ${DEPLOYS[@]+"${DEPLOYS[@]}"}; do
  [ -r "$f" ] && [ -f "$f" ] || die "not a readable file: $f"
done

WORK=$(mktemp -d)
trap 'rm -f "$WORK"/*; rmdir "$WORK"' EXIT

# ------------------------------------------------------------ YAML flattener
# Emits one TSV row per key or list scalar: <line> <path> <value>.
# Paths join keys with '/'; list items are '-1', '-2', ... per parent.
# Block scalars (| and >) are joined with a literal '\n'. Comments are
# stripped outside quotes and outside block scalars. This is a reader for
# workflow-shaped YAML, not a full YAML parser: anchors, flow mappings and
# multi-document files are not interpreted.
flatten() {
  awk '
  function strip_comment(s,   i, c, q, prev) {
    q = ""; prev = " "
    for (i = 1; i <= length(s); i++) {
      c = substr(s, i, 1)
      if (q == "") {
        if ((c == "\"" || c == "\047") && (prev == " " || prev == ":" || prev == "[" || prev == ",")) q = c
        else if (c == "#" && (prev == " " || prev == "\t")) return substr(s, 1, i - 1)
      } else if (c == q) q = ""
      prev = c
    }
    return s
  }
  function unq(s) {
    sub(/^[ \t]+/, "", s); sub(/[ \t]+$/, "", s)
    if (s ~ /^".*"$/ || s ~ /^\047.*\047$/) s = substr(s, 2, length(s) - 2)
    return s
  }
  function curpath(   i, p) {
    p = ""
    for (i = 1; i <= depth; i++) p = p (i > 1 ? "/" : "") key[i]
    return p
  }
  function pop_key(ind) { while (depth > 0 && ind_of[depth] >= ind) depth-- }
  function pop_item(ind) {
    while (depth > 0 && (ind_of[depth] > ind || (ind_of[depth] == ind && key[depth] ~ /^-[0-9]+$/))) depth--
  }
  function push(ind, k) { depth++; ind_of[depth] = ind; key[depth] = k }
  function emit(ln, p, v) { gsub(/\t/, " ", v); printf "%d\t%s\t%s\n", ln, p, v }
  BEGIN { depth = 0; blk = 0 }
  {
    raw = $0; sub(/\r$/, "", raw)
    if (blk) {
      if (raw ~ /^[ \t]*$/) { next }
      match(raw, /^ */)
      if (RLENGTH > blkind) {
        t = raw; sub(/^[ \t]+/, "", t)
        blkval = blkval (blkval == "" ? "" : "\\n") t
        next
      }
      emit(blkline, blkpath, blkval); blk = 0
    }
    line = strip_comment(raw)
    if (line ~ /^[ \t]*$/) next
    if (line ~ /^(---|\.\.\.)[ \t]*$/) next
    match(line, /^ */); ind = RLENGTH; rest = substr(line, ind + 1)
    while (rest ~ /^-( |$)/) {
      pop_item(ind)
      parent = curpath(); cnt[parent]++
      push(ind, "-" cnt[parent])
      rest = substr(rest, 2); match(rest, /^ */)
      ind = ind + 1 + RLENGTH; rest = substr(rest, RLENGTH + 1)
    }
    if (rest == "") next
    if (match(rest, /^("[^"]*"|\047[^\047]*\047|[^ :#"\047-][^:]*|-[^ :][^:]*):( |$)/)) {
      k = substr(rest, 1, RLENGTH); v = substr(rest, RLENGTH + 1)
      sub(/:[ ]?$/, "", k); k = unq(k)
      pop_key(ind); push(ind, k); p = curpath()
      vv = v; sub(/^[ \t]+/, "", vv); sub(/[ \t]+$/, "", vv)
      if (vv ~ /^[|>][-+0-9]*$/) { blk = 1; blkind = ind; blkpath = p; blkline = NR; blkval = ""; next }
      emit(NR, p, unq(v))
    } else {
      emit(NR, curpath(), unq(rest))
    }
  }
  END { if (blk) emit(blkline, blkpath, blkval) }
  ' "$1"
}

# Frontmatter of a .md file (between the first two --- lines), line numbers kept.
frontmatter() {
  awk 'NR == 1 && $0 !~ /^---[ \t]*$/ { exit }
       NR == 1 { next }
       /^---[ \t]*$/ { exit }
       { print; next }' "$1" >"$WORK/fm"
  # pad so flattened line numbers match the source file
  { echo; cat "$WORK/fm"; } >"$WORK/fm.pad"
  flatten "$WORK/fm.pad"
}

# ----------------------------------------------------------- cron analysis
# Prints "window" if the expression fires inside the 1-3 AM local window
# (hours 1 and 2, or exactly 3:00), "clear" if it does not, "unparsed" if
# the fields are outside plain numeric cron syntax.
cron_window() {
  awk -v e="$1" '
  function expand(f, lo, hi, out,   n, parts, i, p, step, a, b, x, slash) {
    if (f !~ /^[0-9*,\/-]+$/) return 0
    n = split(f, parts, ",")
    for (i = 1; i <= n; i++) {
      p = parts[i]; step = 1; slash = index(p, "/")
      if (slash) { step = substr(p, slash + 1) + 0; p = substr(p, 1, slash - 1); if (step < 1) return 0 }
      if (p == "*") { a = lo; b = hi }
      else if (index(p, "-")) { a = substr(p, 1, index(p, "-") - 1) + 0; b = substr(p, index(p, "-") + 1) + 0 }
      else { a = p + 0; b = slash ? hi : a }
      for (x = a; x <= b; x += step) out[x] = 1
    }
    return 1
  }
  BEGIN {
    s = e
    if (s == "@hourly") s = "0 * * * *"
    else if (s ~ /^@(daily|midnight|weekly|monthly|yearly|annually)$/) s = "0 0 * * *"
    n = split(s, f, /[ \t]+/)
    if (n != 5) { print "unparsed"; exit }
    if (!expand(f[1], 0, 59, mins) || !expand(f[2], 0, 23, hrs)) { print "unparsed"; exit }
    if ((1 in hrs) || (2 in hrs) || ((3 in hrs) && (0 in mins))) print "window"; else print "clear"
  }'
}

is_utc() {
  printf '%s' "$1" | grep -qiE '^(utc|etc/utc|etc/uct|uct|gmt|etc/gmt|etc/gmt[+-][0-9]+|z|zulu|universal|etc/universal|etc/zulu)$'
}

# ---------------------------------------------------------------- output
FAILS=0
declare -A OPEN=()
finding() {  # status row message [detail...]
  local st=$1 row=$2 msg=$3; shift 3
  if [ "$st" = FAIL ]; then FAILS=$((FAILS + 1)); fi
  if [ "$st" = FAIL ] || [ "$st" = WARN ]; then OPEN[$row]=1; fi
  printf '  %-6s %-9s %s\n' "$st" "$row" "$msg"
  local d; for d in "$@"; do printf '                   %s\n' "$d"; done
}

# kv helpers over the flattened file $KV
kv_val() { awk -F'\t' -v p="$1" '$2 == p { print $3; exit }' "$KV"; }

ALERT_RE='slack|pagerduty|opsgenie|discord|msteams|teams-notify|webhook|sendgrid|send-mail|mail-action|statuspage|healthchecks[.]io|cronitor|deadmanssnitch|betteruptime'
EVENT_IGNORE='^(workflow_dispatch|workflow_call|repository_dispatch)$'

# CODEOWNERS: last matching rule wins. Supports *, a/b, /a/b, a/ and a/* forms.
codeowner_for() {
  local rel=$1 co=""
  for c in "$REPO/.github/CODEOWNERS" "$REPO/CODEOWNERS" "$REPO/docs/CODEOWNERS"; do
    [ -f "$c" ] && { co=$c; break; }
  done
  [ -n "$co" ] || return 0
  awk -v path="$rel" '
    /^[ \t]*(#|$)/ { next }
    {
      pat = $1; owners = ""
      for (i = 2; i <= NF; i++) owners = owners (i > 2 ? " " : "") $i
      sub(/^\//, "", pat)
      if (pat == "*" || pat == "**") hit = 1
      else {
        gsub(/\/\*\*?$/, "/", pat)
        if (pat ~ /\/$/) hit = (index(path, pat) == 1)
        else if (pat ~ /^\*\./) { ext = substr(pat, 2); hit = (substr(path, length(path) - length(ext) + 1) == ext) }
        else hit = (path == pat || index(path, pat "/") == 1)
      }
      if (hit) last = (owners == "" ? "(rule with no owner)" : owners)
    }
    END { if (last != "") print last }' "$co"
}

# ------------------------------------------------------- workflow discovery
if [ "${#FILES[@]}" -eq 0 ]; then
  if [ -d "$REPO/.github/workflows" ]; then
    while IFS= read -r f; do FILES+=("$f"); done < <(
      find "$REPO/.github/workflows" -maxdepth 1 -type f \( -name '*.yml' -o -name '*.yaml' \) | sort)
  fi
fi

# Flatten every workflow once; alerting anywhere in the repo is in reach.
declare -A KVOF
i=0
for f in ${FILES[@]+"${FILES[@]}"}; do
  i=$((i + 1)); flatten "$f" >"$WORK/kv.$i"; KVOF["$f"]="$WORK/kv.$i"
done

relpath() { case "$1" in "$REPO"/*) printf '%s' "${1#"$REPO"/}" ;; *) printf '%s' "$1" ;; esac; }

AGENT_WF=0
printf 'always-on-preflight: %s\n' "$REPO"
printf 'Agent steps matched by: %s\n' "$AGENT_RE"

for f in ${FILES[@]+"${FILES[@]}"}; do
  KV=${KVOF["$f"]}
  rel=$(relpath "$f")
  agent_rows=$(awk -F'\t' -v re="$AGENT_RE" '$2 ~ /^jobs\/[^\/]+\/steps\/-[0-9]+\/uses$/ && $3 ~ re' "$KV")
  [ -n "$agent_rows" ] || continue

  # triggers
  triggers=$(awk -F'\t' '
    $2 ~ /^(on|true)$/ && $3 != "" { v = $3; gsub(/[\[\]]/, "", v); n = split(v, a, /[ ,]+/); for (i = 1; i <= n; i++) if (a[i] != "") print a[i] }
    $2 ~ /^(on|true)\/[^\/]+$/ { sub(/^(on|true)\//, "", $2); print $2 }
    $2 ~ /^(on|true)\/-[0-9]+$/ { print $3 }' "$KV" | awk '!seen[$0]++')
  standing=$(printf '%s\n' "$triggers" | grep -vE "$EVENT_IGNORE" | awk 'NF' || true)
  events=$(printf '%s\n' "$standing" | grep -v '^schedule$' | awk 'NF' || true)
  has_sched=0; printf '%s\n' "$standing" | grep -qx 'schedule' && has_sched=1

  printf '\n== %s\n' "$rel"
  printf '   agent: %s\n' "$(printf '%s\n' "$agent_rows" | awk -F'\t' '{ printf "%s%s (line %s)", (NR > 1 ? ", " : ""), $3, $1 }')"
  printf '   triggers: %s\n' "$(printf '%s\n' "$triggers" | awk 'NF' | paste -sd, - | sed 's/,/, /g')"
  if [ -z "$standing" ]; then
    printf '   skipped: every trigger is a manual or caller-driven dispatch, so a person starts each run.\n'
    continue
  fi
  AGENT_WF=$((AGENT_WF + 1))

  agent_jobs=$(printf '%s\n' "$agent_rows" | awk -F'\t' '{ split($2, a, "/"); print a[2] }' | sort -u)
  agent_steps=$(printf '%s\n' "$agent_rows" | awk -F'\t' '{ sub(/\/uses$/, "", $2); print $2 }')

  # inputs on the agent steps
  with_rows=""
  while IFS= read -r sp; do
    with_rows+=$(awk -F'\t' -v p="$sp/with/" 'index($2, p) == 1 { k = substr($2, length(p) + 1); print $1 "\t" k "\t" $3 }' "$KV")$'\n'
  done <<<"$agent_steps"
  wv() { printf '%s' "$with_rows" | awk -F'\t' -v k="$1" '$2 == k { print $3; exit }'; }
  wl() { printf '%s' "$with_rows" | awk -F'\t' -v k="$1" '$2 == k { print $1; exit }'; }
  prompt=$(printf '%s' "$with_rows" | awk -F'\t' '$2 == "prompt" || $2 == "direct_prompt" || $2 == "override_prompt" { print $3 }')
  prompt_line=$(printf '%s' "$with_rows" | awk -F'\t' '$2 == "prompt" || $2 == "direct_prompt" || $2 == "override_prompt" { print $1; exit }')
  prompt_file=$(wv prompt_file)

  # permissions: workflow level and each agent job
  perm_rows=$(awk -F'\t' '$2 ~ /^permissions(\/[^\/]+)?$/' "$KV")
  for j in $agent_jobs; do
    perm_rows+=$'\n'$(awk -F'\t' -v j="$j" '$2 ~ ("^jobs/" j "/permissions(/[^/]+)?$")' "$KV")
  done
  write_perms=$(printf '%s\n' "$perm_rows" | awk -F'\t' '
    $3 == "write-all" { print "write-all"; next }
    $2 ~ /\/[^\/]+$/ && $3 == "write" { n = split($2, a, "/"); if (a[n] != "id-token") print a[n] }' | sort -u | paste -sd, -)
  id_token=$(printf '%s\n' "$perm_rows" | awk -F'\t' '$2 ~ /id-token$/ && $3 == "write" { print $1; exit }')
  has_perm_block=$(printf '%s\n' "$perm_rows" | awk 'NF { print 1; exit }')

  gh_token=$(wv github_token); gh_token_line=$(wl github_token)
  # Only claude-code-action falls back to the Claude GitHub App; the base action
  # and other agents get GitHub access from whatever the job hands their tools.
  writer="job"
  printf '%s\n' "$agent_rows" | awk -F'\t' '$3 ~ /anthropics\/claude-code-action/ { f = 1 } END { exit !f }' && writer="app"
  if [ -n "$gh_token" ]; then
    if printf '%s' "$gh_token" | grep -qE 'secrets\.GITHUB_TOKEN|github\.token'; then writer="workflow-token"; else writer="stored-token"; fi
  fi
  can_write=""
  [ -n "$write_perms" ] && can_write="workflow grants write: $write_perms"
  [ "$writer" = app ] && can_write="${can_write:+$can_write; }the action authenticates as the Claude GitHub App, whose permission set includes Workflows read and write"
  [ "$writer" = stored-token ] && can_write="${can_write:+$can_write; }a stored token with whatever scopes its owner gave it"
  [ -z "$can_write" ] && [ -z "$has_perm_block" ] && can_write="no permissions: block, so the repo's default token scope applies"

  # Table cells, built as findings land.
  T_DEDUP=() T_MEM=() T_ID=() T_APPR=() T_WATCH=()
  OPEN=()

  echo
  # ---- Deduplication
  conc=$(awk -F'\t' '$2 == "concurrency" && $3 != "" || $2 == "concurrency/group" { print $1 "\t" $3; exit }' "$KV")
  if [ -z "$conc" ]; then
    for j in $agent_jobs; do
      conc=$(awk -F'\t' -v j="$j" '($2 == "jobs/" j "/concurrency" && $3 != "") || $2 == "jobs/" j "/concurrency/group" { print $1 "\t" $3; exit }' "$KV")
      [ -n "$conc" ] && break
    done
  fi
  conc_line=${conc%%$'\t'*}; conc_group=${conc#*$'\t'}
  if [ -z "$conc" ]; then
    finding FAIL dedup "no concurrency: group on the workflow or the agent job" \
      "Two triggers can start competing runs; one worker per inbox is the control." \
      "fix: add a concurrency group; for issue or PR events, key it on the issue or PR number."
    T_DEDUP+=("no concurrency group")
  elif printf '%s' "$conc_group" | grep -qE 'github\.run_(id|number|attempt)'; then
    finding FAIL dedup "concurrency group keyed on the run id (line $conc_line): every run gets its own group" \
      "group: $conc_group"
    T_DEDUP+=("concurrency group per run, so no serialization")
  else
    keyed=""
    printf '%s' "$conc_group" | grep -qE 'issue\.number|pull_request\.number|event\.number|head_ref|github\.ref' && keyed=1
    if [ -n "$events" ] && [ -z "$keyed" ]; then
      finding OK dedup "concurrency group (line $conc_line): $conc_group" \
        "Not keyed on the event object, so all events share one worker. The post keys it on the issue number."
    else
      finding OK dedup "concurrency group (line $conc_line): $conc_group"
    fi
    T_DEDUP+=("concurrency: $conc_group")
  fi

  if [ -n "$events" ]; then
    marker=$(awk -F'\t' '$2 !~ /\/(prompt|direct_prompt|override_prompt)$/ && tolower($3 " " $2) ~ /inbox|idempot|dedup/ { print $1; exit }' "$KV")
    ev_list=$(printf '%s\n' "$events" | paste -sd, - | sed 's/,/, /g')
    if [ -n "$marker" ]; then
      finding REVIEW dedup "possible dedup step at line $marker; confirm it writes a keyed row before the agent runs and exits when the key is taken"
      T_DEDUP+=("dedup marker at line $marker (confirm)")
    elif [ -n "$can_write" ]; then
      finding WARN dedup "event triggers ($ev_list) with write access and no dedup key visible in this file" \
        "Write access: $can_write." \
        "Two edits in one minute are two events and two sessions racing on one object." \
        "fix: write an inbox row keyed on repo, number, event action and the object's updated_at" \
        "(the post's construction, not a sourced standard); a run that finds its key taken exits."
      T_DEDUP+=("no dedup key visible for $ev_list")
    else
      finding REVIEW dedup "event triggers ($ev_list), no write access visible; duplicates only re-read"
      T_DEDUP+=("read-only on events")
    fi
  fi

  if [ "$has_sched" = 1 ]; then
    while IFS=$'\t' read -r cl cidx cexpr; do
      [ -n "$cl" ] || continue
      tz=$(kv_val "on/schedule/$cidx/timezone")
      if [ -z "$tz" ]; then
        finding OK dedup "cron '$cexpr' (line $cl): no time zone declared on the trigger" \
          "GitHub Actions schedule cron is UTC, so no DST window to avoid. Key the inbox row on the scheduled slot."
        T_DEDUP+=("cron $cexpr UTC")
      elif is_utc "$tz"; then
        finding OK dedup "cron '$cexpr' in $tz (line $cl)"
        T_DEDUP+=("cron $cexpr $tz")
      else
        w=$(cron_window "$cexpr")
        if [ "$w" = window ]; then
          finding FAIL dedup "cron '$cexpr' in $tz (line $cl) fires inside the 1-3 AM local window" \
            "Spring-forward skips times that do not exist; fall-back fires repeated times twice." \
            "fix: schedule outside 1-3 AM local, or use UTC."
          T_DEDUP+=("cron $cexpr $tz in DST window")
        elif [ "$w" = unparsed ]; then
          finding REVIEW dedup "cron '$cexpr' in $tz (line $cl): not plain numeric cron; check the 1-3 AM local window by hand"
          T_DEDUP+=("cron $cexpr $tz (check DST by hand)")
        else
          finding OK dedup "cron '$cexpr' in $tz (line $cl) is outside the 1-3 AM local window"
          T_DEDUP+=("cron $cexpr $tz")
        fi
      fi
    done < <(awk -F'\t' '$2 ~ /^on\/schedule\/-[0-9]+\/cron$/ { split($2, a, "/"); print $1 "\t" a[3] "\t" $3 }' "$KV")
  fi

  # ---- Identity
  for k in anthropic_api_key claude_code_oauth_token; do
    v=$(wv "$k")
    [ -n "$v" ] || continue
    extra="fix: id-token: write plus anthropic_federation_rule_id and anthropic_organization_id (OIDC, no stored key)."
    [ -n "$id_token" ] && extra="id-token: write is already granted (line $id_token); the federation inputs would retire the stored key."
    finding FAIL identity "stored model credential: $k (line $(wl "$k"))" \
      "Deleting the secret does not revoke it; retiring it is a second step in the Claude Console." \
      "$extra"
    T_ID+=("stored $k")
  done
  if [ -n "$(wv anthropic_federation_rule_id)" ]; then
    if [ -n "$id_token" ]; then
      finding OK identity "OIDC federation (anthropic_federation_rule_id, id-token: write)"
    else
      finding FAIL identity "anthropic_federation_rule_id set but no id-token: write in permissions"
    fi
    T_ID+=("OIDC federation")
  fi
  case "$writer" in
    app) finding OK identity "no github_token input: repository writes go through the Claude GitHub App"
         T_ID+=("GitHub App") ;;
    job) finding REVIEW identity "agent action has no Claude GitHub App path: its GitHub access is whatever token the job hands its tools" \
         "Confirm that token is not a person's."
         T_ID+=("GitHub access via job tokens") ;;
    workflow-token) finding OK identity "github_token is the workflow token (line $gh_token_line), not a stored personal token"
         T_ID+=("workflow token") ;;
    stored-token) finding FAIL identity "github_token is a stored secret (line $gh_token_line): $gh_token" \
         "Every label, comment and PR carries the name of whoever owns that token." \
         "fix: drop github_token and let the action authenticate as the Claude GitHub App."
         T_ID+=("stored GitHub token") ;;
  esac
  env_tokens=$(for j in $agent_jobs; do
    awk -F'\t' -v j="$j" '
      index($2, "jobs/" j "/") == 1 && $2 ~ /\/(GH_TOKEN|GITHUB_TOKEN|GITHUB_PERSONAL_ACCESS_TOKEN)$/ && $3 ~ /secrets\./ && $3 !~ /secrets\.GITHUB_TOKEN/ { print $1 "\t" $3 }' "$KV"
  done)
  while IFS=$'\t' read -r l v; do
    [ -n "$l" ] || continue
    finding WARN identity "stored GitHub credential in the agent job env (line $l): $v" \
      "The agent's tools act as that token's owner."
    T_ID+=("stored GitHub token in env")
  done <<<"$env_tokens"
  if [ "$has_sched" = 1 ]; then
    who=""
    if git -C "$REPO" rev-parse --git-dir >/dev/null 2>&1; then
      first_cron=$(awk -F'\t' '$2 ~ /^on\/schedule\/-[0-9]+\/cron$/ { print $3; exit }' "$KV")
      who=$(git -C "$REPO" log -1 --format='%an <%ae>, %ad' --date=short -S"$first_cron" -- "$f" 2>/dev/null || true)
    fi
    finding REVIEW identity "scheduled runs are attributed to whoever last changed the cron" \
      "last change to '$(awk -F'\t' '$2 ~ /^on\/schedule\/-[0-9]+\/cron$/ { print $3; exit }' "$KV")' in git: ${who:-unknown (not a git repo, or the line is uncommitted)}" \
      "If that person leaves, the runs still carry their name."
    T_ID+=("schedule credited to ${who%%,*}"); OPEN[identity]=1
  fi
  [ "${#T_ID[@]}" -gt 0 ] || T_ID+=("no credential inputs found on the agent step")

  # ---- Memory (heuristic)
  ptext=$(printf '%s' "$prompt" | sed 's/\\n/ /g')
  if [ -n "$ptext" ] && printf '%s' "$ptext" | grep -qiE '(rewrite|overwrite|update|maintain|edit)[^.]{0,40}(notes|memory|\.md\b)'; then
    finding WARN memory "prompt (line $prompt_line) tells the agent to rewrite a file it reads back (heuristic)" \
      "A notes file the agent rewrites drifts and then overrides fresh facts." \
      "fix: harness-written append-only run log; regenerate the notes from it on a gate."
    T_MEM+=("agent rewrites its own notes")
  else
    finding REVIEW memory "not visible statically: is the run log append-only and written by the harness, not the agent?"
    T_MEM+=("not visible"); OPEN[memory]=1
  fi

  # ---- Approval (heuristic)
  if [ -n "$ptext" ] && printf '%s' "$ptext" | grep -qiE '\b(merge|deploy|close|approve|release|publish)\b'; then
    finding WARN approval "prompt (line $prompt_line) asks for a merge, deploy, close or release (heuristic)" \
      "The fired prompt is not approval. Defer the call and resume on an approval event with an expiry."
    T_APPR+=("prompt asks for a gated action")
  else
    [ -n "$prompt_file" ] && note=" (prompt is read from $prompt_file; not scanned)" || note=""
    finding REVIEW approval "not visible statically$note: does any step need a human yes, and does it arrive as a new event?"
    T_APPR+=("not visible"); OPEN[approval]=1
  fi

  # ---- Watching and stopping
  own_alerts=$(awk -F'\t' -v re="$ALERT_RE" '
    $2 ~ /^jobs\// && $2 !~ /\/(prompt|direct_prompt|override_prompt)$/ && tolower($2 " " $3) ~ re { print $1 "\t" $2 }' "$KV")
  if [ -n "$own_alerts" ]; then
    lines=$(printf '%s\n' "$own_alerts" | cut -f1 | paste -sd, -)
    case "$writer" in
      app) reach="the Claude GitHub App's permission set includes Workflows read and write" ;;
      stored-token) reach="a stored token's reach depends on its scopes; treat this file as editable" ;;
      *) reach="it is defined in the repo the agent works in" ;;
    esac
    finding FAIL watching "alerting in the same workflow as the agent (lines $lines)" \
      "It sits within reach of the identity the agent writes with: $reach." \
      "fix: move the page to a monitoring system whose credentials the agent never holds."
    T_WATCH+=("alert inside the agent's workflow")
    on_fail=$(printf '%s\n' "$own_alerts" | while IFS=$'\t' read -r l p; do
      step=$(printf '%s' "$p" | sed -E 's#^(jobs/[^/]+/steps/-[0-9]+)/.*#\1#')
      job=$(printf '%s' "$p" | sed -E 's#^(jobs/[^/]+)/.*#\1#')
      if awk -F'\t' -v a="$step/if" -v b="$job/if" '($2 == a || $2 == b) && $3 ~ /failure\(\)/ { f = 1 } END { exit !f }' "$KV"; then echo "$l"; fi
    done | paste -sd, -)
    if [ -n "$on_fail" ]; then
      finding WARN watching "alert fires on failure() (lines $on_fail): it pages on a red run, a cause" \
        "A run can end green and do nothing. Page when the outcome the agent exists to produce goes missing."
    fi
  fi
  other_alerts=""
  for g in ${FILES[@]+"${FILES[@]}"}; do
    [ "$g" = "$f" ] && continue
    hit=$(awk -F'\t' -v re="$ALERT_RE" '$2 ~ /^jobs\// && tolower($2 " " $3) ~ re { print $1; exit }' "${KVOF["$g"]}")
    [ -n "$hit" ] && other_alerts+="$(relpath "$g"):$hit "
  done
  if [ -n "$other_alerts" ]; then
    finding WARN watching "alerting elsewhere in this repo's workflows: $other_alerts" \
      "Same repo, same reach: if it watches this agent, move it out of the repo."
    T_WATCH+=("alert in repo workflows")
  fi
  if [ -z "$own_alerts" ] && [ -z "$other_alerts" ]; then
    finding REVIEW watching "no alerting in this repo's workflows: where does the missing-outcome page live, and who holds its credentials?"
    T_WATCH+=("outcome page not visible here"); OPEN[watching]=1
  fi
  owner=$(codeowner_for "$rel")
  if [ -n "$owner" ]; then
    finding REVIEW watching "CODEOWNERS for $rel: $owner" \
      "That is a reviewer on record. Confirm it is also the paged owner for this agent."
    T_WATCH+=("CODEOWNERS $owner")
  else
    finding REVIEW watching "no CODEOWNERS entry for $rel: name one owner or rotation for this agent"
    T_WATCH+=("no owner on record"); OPEN[watching]=1
  fi
  finding REVIEW watching "off switch: can you stop a run already in flight from your phone? Test it before you need it."

  if [ "$TABLE" = 1 ]; then
    join() { local IFS=';'; printf '%s' "$*" | sed 's/;/; /g'; }
    cell() {  # row-key text
      if [ -n "${OPEN[$1]:-}" ]; then printf '[open] %s' "$2"; else printf '[confirm] %s' "$2"; fi
    }
    echo
    echo "   Standing-agent table, as far as a static read can fill it:"
    echo
    echo "   | Job | Control outside the agent | This workflow |"
    echo "   |---|---|---|"
    echo "   | The human in the chat | List the five jobs before scheduling | runs on: $(printf '%s\n' "$standing" | paste -sd, - | sed 's/,/, /g') |"
    echo "   | Deduplication | Inbox keyed on the source's event ID, one worker, skip-or-double per action | $(cell dedup "$(join "${T_DEDUP[@]}")") |"
    echo "   | Memory | Append-only run log; notes as a rebuildable cache | $(cell memory "$(join "${T_MEM[@]}")") |"
    echo "   | Identity | Own identity, short-lived credentials via a proxy | $(cell identity "$(join "${T_ID[@]}")") |"
    echo "   | Approval | Deferred call resumed by an inbox event with an expiry | $(cell approval "$(join "${T_APPR[@]}")") |"
    echo "   | Watching and stopping | Page on outcomes; off switch outside its reach | $(cell watching "$(join "${T_WATCH[@]}")") |"
    echo
    echo "   [open] is a gap or something this check cannot see. [confirm] means the visible part passed;"
    echo "   a person still confirms the rest. If any row is still blank, the agent is not ready to run without you."
  fi
done

# ------------------------------------------------- scheduled deployments
if [ "${#DEPLOYS[@]}" -eq 0 ]; then
  while IFS= read -r d; do DEPLOYS+=("$d"); done < <(
    grep -rlE '^[[:space:]]*expression:' "$REPO" \
      --include='*.md' --include='*.yml' --include='*.yaml' \
      --exclude-dir=.git --exclude-dir=node_modules --exclude-dir=vendor --exclude-dir=.github 2>/dev/null | sort || true)
fi
DEP_SEEN=0
for d in ${DEPLOYS[@]+"${DEPLOYS[@]}"}; do
  case "$d" in *.md) frontmatter "$d" >"$WORK/dep" ;; *) flatten "$d" >"$WORK/dep" ;; esac
  KV="$WORK/dep"
  expr_row=$(awk -F'\t' '$2 ~ /(^|\/)schedule\/expression$/ { print $1 "\t" $2 "\t" $3; exit }' "$KV")
  [ -n "$expr_row" ] || continue
  IFS=$'\t' read -r el ep ev <<<"$expr_row"
  base=${ep%/expression}
  styp=$(kv_val "$base/type")
  [ -z "$styp" ] || [ "$styp" = cron ] || continue
  [ "$DEP_SEEN" = 0 ] && printf '\n== Scheduled deployments\n'
  DEP_SEEN=1
  tz=$(kv_val "$base/timezone")
  printf '   %s\n' "$(relpath "$d")"
  if [ -z "$tz" ]; then
    finding REVIEW dedup "cron '$ev' (line $el): no timezone key; confirm which zone the scheduler applies"
  elif is_utc "$tz"; then
    finding OK dedup "cron '$ev' in $tz (line $el)"
  else
    w=$(cron_window "$ev")
    case "$w" in
      window) finding FAIL dedup "cron '$ev' in $tz (line $el) fires inside the 1-3 AM local window" \
                "Spring-forward times that do not exist are not triggered; fall-back times fire twice." \
                "fix: schedule outside 1-3 AM local, or use UTC." ;;
      unparsed) finding REVIEW dedup "cron '$ev' in $tz (line $el): not plain numeric cron; check the 1-3 AM local window by hand" ;;
      *) finding OK dedup "cron '$ev' in $tz (line $el) is outside the 1-3 AM local window" ;;
    esac
  fi
  finding REVIEW dedup "key the inbox row on trigger_context.scheduled_at; a successful run only means a session was created"
done

echo
if [ "$AGENT_WF" -eq 0 ] && [ "$DEP_SEEN" -eq 0 ]; then
  echo "No standing agent found: no workflow runs a step matching the agent pattern on a schedule or repo event, and no scheduled-deployment file was found."
  exit 0
fi
printf 'Summary: %d standing agent workflow(s), %d FAIL.\n' "$AGENT_WF" "$FAILS"
echo "WARN on memory and approval rows comes from keyword matches on the prompt text. Read the cited line before acting on it."
[ "$FAILS" -eq 0 ] || exit 1
exit 0
