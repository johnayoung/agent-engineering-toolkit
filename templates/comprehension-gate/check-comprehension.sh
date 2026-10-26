#!/usr/bin/env bash
# check-comprehension.sh: merge gate for the "## Comprehension" block in a PR body.
#
#   ./check-comprehension.sh <pr-body.md>
#   gh pr view 812 --json body -q .body | ./check-comprehension.sh -
#
# Checks that the block exists, names an owner and the owner's on-call rotation, sets a
# blast radius, and (unless the blast radius is "low") fills Contract, Invariants,
# Failure modes, Debug path, and Regenerable in something other than the template prompts.
# HTML comments are ignored, so an untouched template fails.
#
# It cannot check that the words are the owner's, or that they are true. The drill does that.
#
# Exit: 0 pass (warnings allowed), 1 gate fails, 2 usage or input error.
set -euo pipefail

usage() { sed -n '2,14p' "$0" | sed 's/^# \{0,1\}//'; }

[ $# -eq 1 ] || { usage >&2; exit 2; }
case "$1" in -h|--help) usage; exit 0 ;; esac

SRC="$1"
if [ "$SRC" = "-" ]; then
  BODY=$(cat)
  LABEL="stdin"
else
  [ -f "$SRC" ] || { echo "check-comprehension: no such file: $SRC" >&2; exit 2; }
  BODY=$(cat "$SRC")
  LABEL="$SRC"
fi

printf '%s\n' "$BODY" | tr -d '\r' | awk -v label="$LABEL" -v q="'" '
function trim(s) { sub(/^[ \t]+/, "", s); sub(/[ \t]+$/, "", s); return s }
function emit(kind, msg) {
  printf "  %-4s  %s\n", kind, msg
  if (kind == "FAIL") nfail++
  if (kind == "WARN") nwarn++
}
function placeholder(v,   l) {
  l = tolower(trim(v))
  return (l == "" || l == "tbd" || l == "todo" || l == "n/a" || l == "na" || l == "none" || \
          l == "?" || l == "-" || l == "unknown" || l ~ /^<.*>$/)
}
function is_agent(v,   l) {
  l = tolower(trim(v))
  if (index(l, "[bot]")) return 1
  return (l ~ /^(the )?(agent|ai|bot|claude|claude code|copilot|github copilot|codex|cursor|devin|aider)( |$|,|\()/)
}
function leftover(s,   l) {
  l = tolower(s)
  return (index(l, "what this code promises its callers") || index(l, "what must stay true regardless") || \
          index(l, "the specific ways this goes wrong") || index(l, "what on-call opens first") || \
          index(l, "files or functions an agent can rewrite"))
}
function is_item(line) { return (line ~ /^[ \t]*([-*+]|[0-9]+[.)])[ \t]+[^ \t]/) }

# Pass 1: strip HTML comments (may span lines); collect the Comprehension block.
{
  line = $0; out = ""
  while (1) {
    if (incom) {
      p = index(line, "-->")
      if (!p) { line = ""; break }
      line = substr(line, p + 3); incom = 0
    }
    p = index(line, "<!--")
    if (!p) { out = out line; break }
    out = out substr(line, 1, p - 1); line = substr(line, p + 4); incom = 1
  }
  l = tolower(out)
  if (l ~ /^```/ || l ~ /^~~~/) infence = !infence
  if (!infence && l ~ /^##[ \t]+comprehension/) { inblock = 1; found = 1; next }
  if (inblock && !infence && (l ~ /^##[ \t]/ || l ~ /^#[ \t]/)) inblock = 0
  if (!inblock) next

  if (!infence && l ~ /^###[ \t]/) {
    h = trim(substr(l, 4))
    sec = ""
    if (h ~ /^contract/) sec = "contract"
    else if (h ~ /^invariant/) sec = "invariants"
    else if (h ~ /^failure mode/) sec = "failure"
    else if (h ~ /^debug path/) sec = "debug"
    else if (h ~ /^regenerable/) sec = "regen"
    if (sec != "") seen[sec] = 1
    next
  }

  if (sec == "") {
    f = out; gsub(/\*/, "", f); sub(/^[ \t]*[-+][ \t]+/, "", f)
    fl = tolower(f)
    if (fl ~ ("^owner" q "?s rotation:") || fl ~ /^owner rotation:/ || fl ~ /^rotation:/) { rotation = trim(substr(f, index(f, ":") + 1)); has_rot = 1 }
    else if (fl ~ /^owner:/)       { owner = trim(substr(f, index(f, ":") + 1)); has_owner = 1 }
    else if (fl ~ /^prompted by:/) { prompter = trim(substr(f, index(f, ":") + 1)) }
    else if (fl ~ /^blast radius:/) { blast = trim(substr(f, index(f, ":") + 1)); has_blast = 1 }
    next
  }

  t = trim(out)
  if (t == "") next
  body[sec] = body[sec] t "\n"
  nlines[sec]++
  if (is_item(out)) items[sec]++
  if (sec == "invariants" && index(tolower(t), "enforced by")) enforced++
}

END {
  print "comprehension-gate: " label
  if (!found) {
    emit("FAIL", "no \"## Comprehension\" block. Add the block from pull_request_template.md; the owner fills it before merge.")
    exit_summary()
  }

  tier = tolower(blast); sub(/[^a-z].*$/, "", tier)
  if (!has_blast || trim(blast) == "")
    emit("FAIL", "blast radius: not set (low | medium | high | critical)")
  else if (tier != "low" && tier != "medium" && tier != "high" && tier != "critical")
    emit("FAIL", "blast radius: \"" blast "\" is not one of low | medium | high | critical")

  if (tier == "low") {
    emit("PASS", "blast radius: " blast)
    emit("PASS", "low tier: owner and the five sections are not required. Confirm the tier is honest; a low label on a change to money, auth, or data is the gate being skipped.")
    exit_summary()
  }

  if (!has_owner || placeholder(owner))
    emit("FAIL", "owner: not named. Block merge until a named person owns the change; the author-of-record is not an owner.")
  else if (is_agent(owner))
    emit("FAIL", "owner: \"" owner "\" is an agent or bot. The owner is a person who can be paged.")
  else
    emit("PASS", "owner: " owner)

  if (!has_rot || placeholder(rotation))
    emit("FAIL", "owner rotation: not named. The owner must be on the rotation that gets paged for this code.")
  else
    emit("PASS", "owner rotation: " rotation)

  if (trim(prompter) == "")
    emit("WARN", "prompted by: not recorded. If the prompter sits on a different rotation than the owner, that is fine; record it so the handoff is visible.")

  if (tier != "") emit("PASS", "blast radius: " blast)

  split("contract invariants failure debug regen", order, " ")
  name["contract"] = "contract"; name["invariants"] = "invariants"; name["failure"] = "failure modes"
  name["debug"] = "debug path"; name["regen"] = "regenerable"
  for (i = 1; i <= 5; i++) {
    s = order[i]
    if (!seen[s])            { emit("FAIL", name[s] ": section missing (### " name[s] ")"); continue }
    if (nlines[s] == 0)      { emit("FAIL", name[s] ": empty"); continue }
    if (leftover(body[s]))   { emit("FAIL", name[s] ": still contains the template prompt; replace it with the owner" q "s own words"); continue }

    if (s == "invariants") {
      if (enforced == 0) { emit("FAIL", "invariants: no \"Enforced by\". If the owner cannot name what enforces an invariant, that is the finding."); continue }
      if (items[s] > 1 && enforced < items[s]) { emit("WARN", "invariants: " enforced " \"Enforced by\" for " items[s] " listed invariants"); continue }
    }
    if (s == "failure" && items[s] == 0) { emit("WARN", "failure modes: no numbered or bulleted item; list each mode separately"); continue }
    if (s == "debug") {
      d = body[s]; dl = tolower(d)
      if (d !~ /`/ && d !~ /[A-Za-z0-9][._][A-Za-z0-9]/) { emit("WARN", "debug path: no concrete identifier (trace field, log line, flag name)"); continue }
      if ((index(dl, "kill switch") || index(dl, "flag") || dl ~ /=[ ]*(false|off|0)/) && \
          !(index(dl, "not stop") || index(dl, "does not") || index(dl, "doesn" q "t") || index(dl, "won" q "t") || index(dl, "only stops"))) {
        emit("WARN", "debug path: names a flag or kill switch but not what it leaves running")
        continue
      }
    }
    if (s == "regen" && tolower(trim(body[s])) ~ /^none\.?$/) { emit("PASS", "regenerable: none (owner holds all of it)"); continue }
    emit("PASS", name[s] ": " nlines[s] " line(s)")
  }
  exit_summary()
}
function exit_summary() {
  printf "result: %s (%d fail, %d warn)\n", (nfail ? "FAIL" : "PASS"), nfail, nwarn
  print "note: this checks that the block exists and is filled. It cannot tell whether the owner wrote it or whether it is true; the post-merge drill tests that."
  exit (nfail ? 1 : 0)
}
'
