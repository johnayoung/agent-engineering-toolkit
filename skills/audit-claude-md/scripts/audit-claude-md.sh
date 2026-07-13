#!/usr/bin/env bash
# audit-claude-md.sh — mechanical inventory of Claude Code's instruction loading tiers.
#
# Tier mechanics per Anthropic's Claude Code memory docs (verified 2026-07-13):
#   - CLAUDE.md / CLAUDE.local.md at or above the working directory load IN FULL at launch.
#   - Files in subdirectories load on demand when Claude reads files there.
#   - @path imports expand and load AT LAUNCH (imports do not reduce context; max depth 4).
#   - Skills: name/description metadata always loaded (~100 tokens/skill), body only on trigger.
#
# Usage: audit-claude-md.sh [target-dir]      (default: current directory)
# Output: per-file inventory by tier, always-loaded token total, and flags.
# Token estimate: chars/4 (heuristic; Claude Code's own accounting will differ slightly).

set -euo pipefail

TARGET=$(cd "${1:-.}" && pwd)
LINE_TARGET=200   # memory docs: "target under 200 lines per CLAUDE.md file"

est_tokens() { # file -> approx token count
  local chars
  chars=$(wc -c < "$1")
  echo $(( chars / 4 ))
}

# --- import expansion (launch-loaded files only) -----------------------------
# Collects @path imports recursively, depth <= 4, cycle-safe.
VISITED=""
IMPORTS=""

collect_imports() { # file depth
  local file="$1" depth="$2" dir token path
  [ "$depth" -gt 4 ] && return 0
  dir=$(dirname "$file")
  # import tokens: @ at start of line or after whitespace, then a path
  { grep -oE '(^|[[:space:]])@[A-Za-z0-9_~][A-Za-z0-9_./~-]*' "$file" 2>/dev/null || true; } \
    | sed 's/^[[:space:]]*//' | sed 's/^@//' | while read -r token; do
      case "$token" in
        "~"*) path="${HOME}${token#\~}" ;;
        /*)   path="$token" ;;
        *)    path="$dir/$token" ;;
      esac
      [ -f "$path" ] || continue
      path=$(cd "$(dirname "$path")" && pwd)/$(basename "$path")
      case " $VISITED " in *" $path "*) continue ;; esac
      VISITED="$VISITED $path"
      echo "$path $((depth))"
      collect_imports "$path" $((depth + 1))
    done
  return 0
}

# --- tier 1: launch-loaded ----------------------------------------------------
LAUNCH_FILES=""
dir="$TARGET"
while [ "$dir" != "/" ]; do
  for name in CLAUDE.md CLAUDE.local.md; do
    [ -f "$dir/$name" ] && LAUNCH_FILES="$LAUNCH_FILES $dir/$name"
  done
  dir=$(dirname "$dir")
done
[ -f "$HOME/.claude/CLAUDE.md" ] && LAUNCH_FILES="$LAUNCH_FILES $HOME/.claude/CLAUDE.md"
[ -f "/etc/claude-code/CLAUDE.md" ] && LAUNCH_FILES="$LAUNCH_FILES /etc/claude-code/CLAUDE.md"

echo "CLAUDE.md loading-tier audit: $TARGET"
echo
echo "TIER 1 — loaded in full at every session launch"
printf '  %-72s %6s %8s\n' "file" "lines" "~tokens"
T1_TOKENS=0
T1_LINES=0
FLAGS=""
for f in $LAUNCH_FILES; do
  lines=$(wc -l < "$f"); tokens=$(est_tokens "$f")
  T1_TOKENS=$((T1_TOKENS + tokens)); T1_LINES=$((T1_LINES + lines))
  printf '  %-72s %6d %8d\n' "$f" "$lines" "$tokens"
  [ "$lines" -gt "$LINE_TARGET" ] && FLAGS="$FLAGS\n  OVER TARGET: $f is $lines lines (memory docs target: under $LINE_TARGET per file — longer files reduce adherence)"
  # expand imports for this file
  VISITED="$f"
  imports=$(collect_imports "$f" 1)
  if [ -n "$imports" ]; then
    echo "$imports" | while read -r ipath idepth; do
      [ -z "$ipath" ] && continue
      il=$(wc -l < "$ipath"); it=$(est_tokens "$ipath")
      printf '  %-72s %6d %8d\n' "    @import(d$idepth): $ipath" "$il" "$it"
    done
    # re-sum import tokens (subshell above cannot mutate totals)
    isum=$(echo "$imports" | awk '{print $1}' | while read -r p; do if [ -n "$p" ]; then est_tokens "$p"; fi; done | awk '{s+=$1} END {print s+0}')
    ilines=$(echo "$imports" | awk '{print $1}' | while read -r p; do if [ -n "$p" ]; then wc -l < "$p"; fi; done | awk '{s+=$1} END {print s+0}')
    T1_TOKENS=$((T1_TOKENS + isum)); T1_LINES=$((T1_LINES + ilines))
    FLAGS="$FLAGS\n  IMPORTS LOAD AT LAUNCH: $f pulls $(echo "$imports" | grep -c .) imported file(s) into every session — splitting into @imports organizes but does not reduce context"
  fi
done
echo
printf '  TIER 1 TOTAL: %d lines, ~%d tokens paid at the start of every session\n' "$T1_LINES" "$T1_TOKENS"
[ "$T1_LINES" -gt "$LINE_TARGET" ] && FLAGS="$FLAGS\n  EFFECTIVE LOAD: always-loaded content totals $T1_LINES lines across launch files and imports — the docs' under-$LINE_TARGET-line target is per file, but the attention budget pays the total" || true

# --- tier 2: lazy (pay-per-read) ----------------------------------------------
echo
echo "TIER 2 — subdirectory files, loaded on demand when Claude reads files there"
found=0
while IFS= read -r f; do
  [ -z "$f" ] && continue
  found=1
  lines=$(wc -l < "$f"); tokens=$(est_tokens "$f")
  printf '  %-72s %6d %8d\n' "$f" "$lines" "$tokens"
done < <(find "$TARGET" -mindepth 2 \( -name CLAUDE.md -o -name CLAUDE.local.md \) -not -path '*/node_modules/*' -not -path '*/.git/*' 2>/dev/null)
if [ -d "$TARGET/.claude/rules" ]; then
  for f in "$TARGET"/.claude/rules/*.md; do
    [ -f "$f" ] || continue
    found=1
    lines=$(wc -l < "$f"); tokens=$(est_tokens "$f")
    printf '  %-72s %6d %8d\n' "$f (path-scoped rule)" "$lines" "$tokens"
  done
fi
[ "$found" -eq 0 ] && echo "  (none — no nested CLAUDE.md files or .claude/rules/)"
echo "  NOTE: lazy loading is the documented design; it has open reliability reports on"
echo "  some surfaces (VS Code extension). Verify with /memory before relying on it."

# --- tier 3: skills (pay-per-trigger) -------------------------------------------
echo
echo "TIER 3 — skills: metadata always loaded, body only on trigger"
for skdir in "$TARGET/.claude/skills" "$HOME/.claude/skills"; do
  [ -d "$skdir" ] || continue
  for sk in "$skdir"/*/SKILL.md; do
    [ -f "$sk" ] || continue
    lines=$(wc -l < "$sk"); tokens=$(est_tokens "$sk")
    printf '  %-72s %6d %8d (body, on trigger)\n' "$sk" "$lines" "$tokens"
  done
done
echo "  Metadata cost: roughly 100 tokens per skill, always loaded (per Anthropic's skills docs)."

# --- flags ----------------------------------------------------------------------
echo
echo "FLAGS"
if [ -n "$FLAGS" ]; then
  printf '%b\n' "$FLAGS"
else
  echo "  (none)"
fi
echo
echo "Next: classify every Tier 1 section with the routing rule — universal fact (keep in"
echo "root) / directory-scoped (nested file or path rule) / procedure or sometimes-relevant"
echo "(skill) / enforcement (hook) / unjustifiable (delete). The /audit-claude-md skill's"
echo "SKILL.md drives that pass."
