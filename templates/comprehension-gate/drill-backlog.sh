#!/usr/bin/env bash
# drill-backlog.sh: turn a scored drill card into comprehension-debt backlog tickets.
#
#   ./drill-backlog.sh <drill-card.md>         # print the tickets as markdown
#   ./drill-backlog.sh --gh <drill-card.md>    # print `gh issue create` commands instead (not run)
#
# Rule: every "Must find" item marked [missed], or still at [ ] when the drill ended, becomes
# one ticket labelled comprehension-debt, assigned to the card's Owner, due before Next drill.
# Nothing is filed for you; review the output, then file it or paste the commands.
#
# Exit: 0 every item found (no tickets), 1 tickets emitted, 2 usage or card error.
set -euo pipefail

usage() { sed -n '2,11p' "$0" | sed 's/^# \{0,1\}//'; }

GH=false
case "${1:-}" in
  -h|--help) usage; exit 0 ;;
  --gh) GH=true; shift ;;
esac
[ $# -eq 1 ] || { usage >&2; exit 2; }
CARD="$1"
[ -f "$CARD" ] || { echo "drill-backlog: no such file: $CARD" >&2; exit 2; }

# awk emits tab-separated records:
#   F <field> <value>     header fields
#   I <n> <mark> <text>   must-find items
#   E <message>           card errors
PARSED=$(tr -d '\r' < "$CARD" | awk '
function trim(s) { sub(/^[ \t]+/, "", s); sub(/[ \t]+$/, "", s); return s }
{
  line = $0; out = ""
  while (1) {
    if (incom) { p = index(line, "-->"); if (!p) { line = ""; break }; line = substr(line, p + 3); incom = 0 }
    p = index(line, "<!--"); if (!p) { out = out line; break }
    out = out substr(line, 1, p - 1); line = substr(line, p + 4); incom = 1
  }
  l = tolower(out)
  if (l ~ /^##[ \t]/) { inmust = (l ~ /^##[ \t]+must find/); next }
  if (inmust) {
    if (out ~ /^[ \t]*[0-9]+[.)][ \t]*\[/) {
      n++
      rest = out; sub(/^[ \t]*[0-9]+[.)][ \t]*\[/, "", rest)
      p = index(rest, "]")
      if (!p) { printf "E\titem %d: unclosed [ mark\n", n; next }
      mark = tolower(trim(substr(rest, 1, p - 1)))
      text = trim(substr(rest, p + 1))
      if (mark == "") mark = "unanswered"
      else if (mark != "found" && mark != "missed") { printf "E\titem %d: mark \"%s\" is not found, missed, or blank\n", n, mark; next }
      if (text == "") { printf "E\titem %d: no text; write what the players must find\n", n; next }
      printf "I\t%d\t%s\t%s\n", n, mark, text
    }
    next
  }
  f = out; gsub(/\*/, "", f)
  if (match(tolower(f), /^(target|owner|last drill|next drill|players|game master|rules):/)) {
    key = tolower(substr(f, 1, index(f, ":") - 1))
    printf "F\t%s\t%s\n", key, trim(substr(f, index(f, ":") + 1))
  }
}
END { if (n == 0) print "E\tno numbered items under \"## Must find\"" }
')

field() { printf '%s\n' "$PARSED" | awk -F '\t' -v k="$1" '$1 == "F" && $2 == k { print $3; exit }'; }

TARGET=$(field target)
OWNER=$(field owner)
NEXT=$(field "next drill")
LAST=$(field "last drill")
PLAYERS=$(field players)
RULES=$(field rules)

ERRORS=$(printf '%s\n' "$PARSED" | awk -F '\t' '$1 == "E" { print "  " $2 }')
[ -n "$TARGET" ] || ERRORS="${ERRORS:+$ERRORS$'\n'}  Target: empty"
[ -n "$OWNER" ] || ERRORS="${ERRORS:+$ERRORS$'\n'}  Owner: empty (tickets need an assignee)"
printf '%s' "$NEXT" | grep -Eq '^[0-9]{4}-[0-9]{2}-[0-9]{2}' || ERRORS="${ERRORS:+$ERRORS$'\n'}  Next drill: \"$NEXT\" is not a YYYY-MM-DD date (tickets are due before it)"
if [ -n "$ERRORS" ]; then
  printf 'drill-backlog: %s is not a usable card\n%s\n' "$CARD" "$ERRORS" >&2
  exit 2
fi
NEXT=${NEXT:0:10}

WARNINGS=""
case "$PLAYERS" in
  *"$OWNER"*) ;;
  *) WARNINGS="${WARNINGS}  WARN  players: owner \"$OWNER\" is not listed; the drill tests the owner, so the owner plays primary"$'\n' ;;
esac
lc_rules=$(printf '%s' "$RULES" | tr '[:upper:]' '[:lower:]')
case "$lc_rules" in
  *"no agent"*) ;;
  *) WARNINGS="${WARNINGS}  WARN  rules: no \"no agent\". A drill run with the agent measures the agent, not the owner"$'\n' ;;
esac

ITEMS=$(printf '%s\n' "$PARSED" | awk -F '\t' '$1 == "I"' || true)
TOTAL=$(printf '%s\n' "$ITEMS" | grep -c . || true)
FOUND=$(printf '%s\n' "$ITEMS" | awk -F '\t' '$3 == "found"' | grep -c . || true)
DEBT=$(printf '%s\n' "$ITEMS" | awk -F '\t' '$3 != "found"' || true)
NDEBT=$(printf '%s\n' "$DEBT" | grep -c . || true)

echo "drill-backlog: $CARD"
echo "  target: $TARGET"
echo "  owner: $OWNER | last drill: ${LAST:-not recorded} | next drill: $NEXT"
echo "  must-find: $FOUND of $TOTAL found unaided; $NDEBT backlog ticket(s)"
[ -z "$WARNINGS" ] || printf '%s' "$WARNINGS"

if [ "$NDEBT" -eq 0 ]; then
  echo "result: no comprehension debt found on this path. Schedule the next drill for $NEXT."
  exit 0
fi

echo
while IFS=$'\t' read -r _ n mark text; do
  title="comprehension-debt: $TARGET: $text"
  body="Drill item $n: $mark (last drill: ${LAST:-not recorded}; card: $CARD).
Owner: $OWNER. Due before the next drill on $NEXT.
Done when the owner can find this unaided, and the comprehension block for the path says it correctly."
  if $GH; then
    printf 'gh issue create --label comprehension-debt --title %q --assignee %q --body %q\n' "$title" "$OWNER" "$body"
  else
    printf '### %s\n- label: comprehension-debt\n- assignee: %s\n- due: before %s\n- drill result: %s\n\n%s\n\n' \
      "$title" "$OWNER" "$NEXT" "$mark" "$body"
  fi
done <<< "$DEBT"

if $GH; then
  echo "# --assignee takes a GitHub login. If Owner is a display name, edit it before running."
fi
exit 1
