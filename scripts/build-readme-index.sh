#!/usr/bin/env bash
# build-readme-index.sh — regenerate README.md's artifact table from */*/artifact.json.
# Idempotent; run after artifact builds land. NOT concurrency-safe — run once per batch,
# never from parallel builder agents (they write only their own artifact directories).

set -euo pipefail

ROOT=$(cd "$(dirname "$0")/.." && pwd)
README="$ROOT/README.md"
START="<!-- artifacts:start -->"
END="<!-- artifacts:end -->"

command -v jq >/dev/null || { echo "jq required" >&2; exit 1; }
grep -qF "$START" "$README" || { echo "README missing $START marker" >&2; exit 1; }

TABLE=$(mktemp)
{
  echo "| Artifact | What it does | Canonical post |"
  echo "|---|---|---|"
  find "$ROOT" -mindepth 3 -maxdepth 3 -name artifact.json -not -path '*/.git/*' | sort | while read -r j; do
    dir=$(dirname "$j")
    rel=${dir#"$ROOT"/}
    jq -r --arg rel "$rel" \
      '"| [`\(.name)`](\($rel)/) | \(.description) | [\(.post_title)](\(.post_url)) |"' "$j"
  done
} > "$TABLE"

awk -v start="$START" -v end="$END" -v table="$TABLE" '
  $0 == start { print; while ((getline line < table) > 0) print line; close(table); skip=1; next }
  $0 == end   { skip=0 }
  !skip { print }
' "$README" > "$README.tmp"
mv "$README.tmp" "$README"
rm -f "$TABLE"
echo "README index rebuilt: $(find "$ROOT" -mindepth 3 -maxdepth 3 -name artifact.json -not -path '*/.git/*' | wc -l) artifact(s)"
