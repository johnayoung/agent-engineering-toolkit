#!/usr/bin/env bash
# harness-portability-audit.sh: the portability ledger from
# "AGENTS.md vs CLAUDE.md: Swap the Agent, Keep the Harness"
# https://jyoung.dev/blog/switching-between-ai-coding-agents/
#
# READ-ONLY. Walks a repo root, finds every coding-agent harness artifact it
# knows about (instruction files, skills, slash commands, MCP client files,
# hooks, permission policies, subagents, worktrees, dev container) and prints
# the post's ledger: each artifact sorted into PORTS or VENDOR-BOUND, with the
# missing bridge named where the post documents one. It writes nothing, fixes
# nothing, and does not grade; a repo that is honestly single-vendor gets a
# ledger that says so.
#
# The sort runs on the post's one test: is this artifact read by name and
# format across vendors (Claude Code, Codex CLI, Gemini CLI, Cursor), or by
# one vendor's schema?
#
# Bridges it can name, each traced to a vendor document cited in the post:
#   - CLAUDE.md with no `@AGENTS.md` import          (Claude Code memory docs)
#   - Codex `project_doc_fallback_filenames` unset    (Codex AGENTS.md docs)
#   - Gemini `context.fileName` not listing AGENTS.md (Gemini CLI context docs)
#   - SKILL.md frontmatter keys outside the six-field Agent Skills spec
#   - `.mcp.json` entry with `url` and no `type`      (Claude Code MCP docs)
#   - hooks, permissions or MCP declared for one vendor while another vendor's
#     adapter directory is present in the same repo
#
# Usage: harness-portability-audit.sh [repo-root]     (default: current dir)
# Requires: jq. TOML files are read with grep, not a parser; the ledger says so.

set -euo pipefail

usage() {
  cat <<'EOF'
harness-portability-audit.sh [repo-root]

Read-only. Prints the portability ledger from
https://jyoung.dev/blog/switching-between-ai-coding-agents/ for one repo:
every harness artifact found on disk, sorted into PORTS or VENDOR-BOUND, with
the missing bridge named where a vendor documents one. Writes nothing.
EOF
}

case "${1:-}" in
  -h|--help) usage; exit 0 ;;
esac

command -v jq >/dev/null 2>&1 || { echo "error: jq is required" >&2; exit 1; }

TARGET=$(cd "${1:-.}" 2>/dev/null && pwd) || { echo "error: no such directory: ${1:-.}" >&2; exit 1; }

# ---------------------------------------------------------------- helpers ---

N_PORTS=0; N_BOUND=0; N_BRIDGE=0; N_UNDET=0
BRIDGES=()

rel() { printf '%s' "${1#"$TARGET"/}"; }

row() { # status  artifact  note
  printf '  %-14s %-40s %s\n' "$1" "$2" "${3:-}"
}
cont() { printf '%57s%s\n' '' "$1"; }

ports()  { N_PORTS=$((N_PORTS + 1));  row "PORTS" "$1" "${2:-}"; }
bound()  { N_BOUND=$((N_BOUND + 1));  row "VENDOR-BOUND" "$1" "${2:-}"; }
bridge() { # artifact  what-is-missing
  N_BRIDGE=$((N_BRIDGE + 1))
  BRIDGES+=("$1: $2")
  cont "bridge missing: $2"
}
undet()  { N_UNDET=$((N_UNDET + 1)); row "UNDETERMINED" "$1" "${2:-}"; }
absent() { row "absent" "$1" "${2:-}"; }

section() { # title  ledger-verdict
  printf '\n== %s\n   ledger: %s\n' "$1" "$2"
}

valid_json() { [ -f "$1" ] && jq empty "$1" >/dev/null 2>&1; }

json_keys() { # file jq-path -> keys one per line (empty if not an object)
  jq -r "$2 | if type==\"object\" then keys[] else empty end" "$1" 2>/dev/null || true
}

json_str() { # file jq-path -> string or empty
  jq -r "$2 | if . == null then empty elif (type==\"array\" or type==\"object\") then tojson else tostring end" "$1" 2>/dev/null || true
}

fm_keys() { # markdown file -> top-level YAML frontmatter keys, one per line
  awk '
    NR==1 { if ($0 !~ /^---[ \t]*$/) exit; next }
    /^---[ \t]*$/ { exit }
    /^[A-Za-z_][A-Za-z0-9_-]*[ \t]*:/ { sub(/[ \t]*:.*/, ""); print }
  ' "$1" 2>/dev/null || true
}

join_sp() { # lines on stdin -> "a, b, c"
  paste -sd, - | sed 's/,/, /g'
}

toml_value() { # file key -> raw right-hand side of first `key = ...` line, or empty
  grep -m1 -E "^[[:space:]]*$2[[:space:]]*=" "$1" 2>/dev/null | sed -E 's/^[^=]*=[[:space:]]*//' || true
}

VENDORS=""
has_vendor() { case " $VENDORS " in *" $1 "*) return 0 ;; esac; return 1; }
add_vendor() { has_vendor "$1" || VENDORS="${VENDORS:+$VENDORS }$1"; }

others_lacking() { # vendor-list-with-artifact -> detected vendors not in that list
  local v out=""
  for v in $VENDORS; do
    case " $1 " in *" $v "*) ;; *) out="${out:+$out }$v" ;; esac
  done
  printf '%s' "$out"
}

# --------------------------------------------------------- vendor detection ---

[ -f "$TARGET/CLAUDE.md" ] || [ -d "$TARGET/.claude" ] || [ -f "$TARGET/.mcp.json" ] && add_vendor claude
[ -d "$TARGET/.codex" ] || [ -d "$TARGET/.agents" ] || [ -f "$TARGET/AGENTS.override.md" ] && add_vendor codex
[ -f "$TARGET/GEMINI.md" ] || [ -d "$TARGET/.gemini" ] && add_vendor gemini
[ -d "$TARGET/.cursor" ] || [ -f "$TARGET/.cursorrules" ] && add_vendor cursor

printf 'harness-portability-audit  %s  %s\n' "$TARGET" "$(date -u +%Y-%m-%dT%H:%MZ)"
printf 'Vendors with artifacts on disk: %s\n' "${VENDORS:-none}"
printf 'Sort test: read by name and format across vendors (PORTS), or by one vendor'"'"'s schema (VENDOR-BOUND).\n'
printf 'AGENTS.md alone names no vendor; a repo with only AGENTS.md is the shape the post recommends.\n'

# ------------------------------------------------- 1. vendor as failure domain

section "Vendor as failure domain" "no flip exists; plan for two triggers, try a second serving path first"

SERVING=0
for f in "$TARGET/.claude/settings.json" "$TARGET/.claude/settings.local.json"; do
  valid_json "$f" || continue
  for k in CLAUDE_CODE_USE_BEDROCK ANTHROPIC_BASE_URL; do
    v=$(json_str "$f" ".env.\"$k\"")
    if [ -n "$v" ]; then SERVING=1; row "SET" "$(rel "$f") env.$k" "$v"; fi
  done
done
if [ -n "${CLAUDE_CODE_USE_BEDROCK:-}" ]; then SERVING=1; row "SET" "shell env CLAUDE_CODE_USE_BEDROCK" "$CLAUDE_CODE_USE_BEDROCK"; fi
if [ -n "${ANTHROPIC_BASE_URL:-}" ]; then SERVING=1; row "SET" "shell env ANTHROPIC_BASE_URL" "$ANTHROPIC_BASE_URL"; fi
if [ "$SERVING" = 0 ]; then
  row "DEFAULT" "second serving path" "CLAUDE_CODE_USE_BEDROCK / ANTHROPIC_BASE_URL not set in project settings or this shell"
fi
cont "the cheaper hedge for an API incident; hedges neither a model regression nor a capability gap"

# ---------------------------------------------------------- 2. instruction file

section "Instruction file" "ports, by convention; CLAUDE.md holding @AGENTS.md plus two config keys"

HAS_AGENTS=0; HAS_CLAUDE=0
[ -f "$TARGET/AGENTS.md" ] && HAS_AGENTS=1
[ -f "$TARGET/CLAUDE.md" ] && HAS_CLAUDE=1

HAS_ANY_INSTR=0
for f in AGENTS.md CLAUDE.md GEMINI.md .cursorrules AGENTS.override.md TEAM_GUIDE.md .agents.md; do
  [ -f "$TARGET/$f" ] && HAS_ANY_INSTR=1
done
[ -d "$TARGET/.cursor/rules" ] && HAS_ANY_INSTR=1

if [ "$HAS_AGENTS" = 1 ]; then
  ports "AGENTS.md" "read natively by Codex CLI, Gemini CLI (with context.fileName) and Cursor; the shared core"
elif [ "$HAS_ANY_INSTR" = 1 ]; then
  bound "AGENTS.md (absent)" "instructions exist only under a vendor's filename"
  bridge "AGENTS.md" "create AGENTS.md at the root as the one instruction file; vendor files reference it"
else
  absent "instruction file" "no AGENTS.md, CLAUDE.md, GEMINI.md, .cursorrules or .cursor/rules; nothing to sort"
fi

for alt in AGENTS.override.md TEAM_GUIDE.md .agents.md; do
  [ -f "$TARGET/$alt" ] && bound "$alt" "Codex fallback filename; other vendors do not look for it"
done

if [ "$HAS_CLAUDE" = 1 ]; then
  if [ -L "$TARGET/CLAUDE.md" ]; then
    link=$(readlink "$TARGET/CLAUDE.md" || true)
    if [ "$(basename "${link:-}")" = "AGENTS.md" ]; then
      ports "CLAUDE.md -> $link" "symlink to AGENTS.md; works, but Windows needs admin or Developer Mode, docs point at @AGENTS.md"
    else
      bound "CLAUDE.md -> $link" "symlink to something other than AGENTS.md"
    fi
  elif grep -qE '(^|[[:space:]])@(\./)?AGENTS\.md([[:space:]]|$)' "$TARGET/CLAUDE.md" 2>/dev/null; then
    lines=$(grep -cvE '^[[:space:]]*$' "$TARGET/CLAUDE.md" || true)
    ports "CLAUDE.md" "imports @AGENTS.md; both tools read the same instructions ($lines non-empty lines total)"
    [ "$HAS_AGENTS" = 0 ] && bridge "CLAUDE.md" "imports @AGENTS.md but AGENTS.md does not exist at the root"
  else
    lines=$(grep -cvE '^[[:space:]]*$' "$TARGET/CLAUDE.md" || true)
    bound "CLAUDE.md" "Claude Code reads CLAUDE.md, not AGENTS.md; $lines non-empty lines only Claude Code sees"
    if [ "$HAS_AGENTS" = 1 ]; then
      bridge "CLAUDE.md" "no @AGENTS.md import line; add one so Claude Code reads the shared file (prefer the import over a symlink)"
    else
      bridge "CLAUDE.md" "move the content to AGENTS.md and leave CLAUDE.md holding @AGENTS.md"
    fi
  fi
elif has_vendor claude && [ "$HAS_ANY_INSTR" = 1 ]; then
  absent "CLAUDE.md" "Claude artifacts present but no CLAUDE.md; Claude Code will not read AGENTS.md without one"
  [ "$HAS_AGENTS" = 1 ] && bridge "CLAUDE.md" "create CLAUDE.md containing @AGENTS.md"
fi

if [ -f "$TARGET/GEMINI.md" ]; then
  bound "GEMINI.md" "Gemini CLI default context filename; other vendors do not read it"
fi

# Codex: reads AGENTS.md natively. The fallback list only matters when the
# instructions live under another name.
CODEX_TOML="$TARGET/.codex/config.toml"
if [ -f "$CODEX_TOML" ]; then
  fb=$(toml_value "$CODEX_TOML" project_doc_fallback_filenames)
  if [ -n "$fb" ]; then
    bound ".codex/config.toml project_doc_fallback_filenames" "$fb"
    cont "Codex reads AGENTS.override.md, AGENTS.md, TEAM_GUIDE.md, .agents.md per directory, then these (32 KiB default cap)"
  elif [ "$HAS_AGENTS" = 0 ] && [ "$HAS_CLAUDE" = 1 ]; then
    bridge ".codex/config.toml" "project_doc_fallback_filenames unset and no AGENTS.md; Codex will not read CLAUDE.md"
  fi
elif has_vendor codex && [ "$HAS_AGENTS" = 0 ] && [ "$HAS_CLAUDE" = 1 ]; then
  bridge ".codex/config.toml" "no AGENTS.md and no project_doc_fallback_filenames; Codex will not read CLAUDE.md"
fi

# Gemini: reads GEMINI.md unless context.fileName lists other names.
GEMINI_JSON="$TARGET/.gemini/settings.json"
if valid_json "$GEMINI_JSON"; then
  cf=$(json_str "$GEMINI_JSON" '.context.fileName')
  if [ -n "$cf" ]; then
    if printf '%s' "$cf" | grep -q 'AGENTS\.md'; then
      ports ".gemini/settings.json context.fileName" "$cf (lists AGENTS.md)"
    else
      bound ".gemini/settings.json context.fileName" "$cf"
      [ "$HAS_AGENTS" = 1 ] && bridge ".gemini/settings.json" "context.fileName does not list AGENTS.md; documented example is [\"AGENTS.md\", \"CONTEXT.md\", \"GEMINI.md\"]"
    fi
  elif [ "$HAS_AGENTS" = 1 ]; then
    bridge ".gemini/settings.json" "context.fileName unset; Gemini CLI reads GEMINI.md by default, not AGENTS.md"
  fi
elif [ -f "$GEMINI_JSON" ]; then
  undet ".gemini/settings.json" "not valid JSON; cannot read context.fileName"
elif has_vendor gemini && [ "$HAS_AGENTS" = 1 ]; then
  bridge ".gemini/settings.json" "absent; set context.fileName to a list that includes AGENTS.md"
fi

# Cursor: reads AGENTS.md at root and in subdirectories with no flip; .mdc rules are its own.
if [ -d "$TARGET/.cursor/rules" ]; then
  n_mdc=$(find "$TARGET/.cursor/rules" -type f -name '*.mdc' 2>/dev/null | wc -l)
  n_md=$(find "$TARGET/.cursor/rules" -type f -name '*.md' 2>/dev/null | wc -l)
  bound ".cursor/rules/" "$n_mdc .mdc project rules; metadata-driven attachment has no equivalent outside Cursor"
  [ "$n_md" -gt 0 ] && cont "$n_md plain .md file(s) here: Cursor project rules must use the .mdc extension"
fi
[ -f "$TARGET/.cursorrules" ] && bound ".cursorrules" "Cursor-only instruction file"
has_vendor cursor && [ "$HAS_AGENTS" = 1 ] && cont "Cursor needs nothing: it reads AGENTS.md at the root and in subdirectories"

nested=$(find "$TARGET" -mindepth 2 -type f \( -name AGENTS.md -o -name CLAUDE.md -o -name GEMINI.md \) \
  -not -path '*/.git/*' -not -path '*/node_modules/*' 2>/dev/null | sort || true)
if [ -n "$nested" ]; then
  n_nested=$(printf '%s\n' "$nested" | wc -l)
  row "note" "nested instruction files" "$n_nested below the root; closest file to the edited path wins in every vendor"
  printf '%s\n' "$nested" | head -10 | while read -r nf; do
    d=$(dirname "$nf"); b=$(basename "$nf")
    case "$b" in
      AGENTS.md) cont "$(rel "$nf")  ports" ;;
      CLAUDE.md)
        if [ -f "$d/AGENTS.md" ]; then cont "$(rel "$nf")  vendor-bound, sibling AGENTS.md present"
        else cont "$(rel "$nf")  vendor-bound, no sibling AGENTS.md"; fi ;;
      GEMINI.md) cont "$(rel "$nf")  vendor-bound" ;;
    esac
  done
  [ "$n_nested" -gt 10 ] && cont "... $((n_nested - 10)) more"
fi
row "note" "effect size" "the most portable layer is not the most valuable one: Gloaguen et al. found context files"
cont "do not generally improve task success rates while raising inference cost by over 20% on average"

# ------------------------------------------------------------------ 3. skills

section "Skills" "spec surface only; strip frontmatter down to the six spec fields"

SPEC_FIELDS=" name description license compatibility metadata allowed-tools "
SKILL_DIRS=""
CLAUDE_SKILLS=""; AGENTS_SKILLS=""

audit_skill() { # SKILL.md path
  local f="$1" keys nonspec="" k has_at=0
  keys=$(fm_keys "$f")
  for k in $keys; do
    case "$SPEC_FIELDS" in *" $k "*) [ "$k" = allowed-tools ] && has_at=1 ;; *) nonspec="${nonspec:+$nonspec, }$k" ;; esac
  done
  if [ -z "$keys" ]; then
    bound "$(rel "$f")" "no frontmatter found; the spec requires name and description"
  elif [ -n "$nonspec" ]; then
    bound "$(rel "$f")" "non-spec frontmatter: $nonspec"
    bridge "$(rel "$f")" "strip or move to metadata: $nonspec (Anthropic's packaging path hard-fails on extra keys)"
  else
    ports "$(rel "$f")" "frontmatter within the six spec fields"
  fi
  [ "$has_at" = 1 ] && cont "allowed-tools is experimental in the spec; support may vary between agent implementations"
  return 0
}

for base in .claude/skills .agents/skills; do
  d="$TARGET/$base"
  [ -d "$d" ] || continue
  SKILL_DIRS="${SKILL_DIRS:+$SKILL_DIRS }$base"
  while IFS= read -r sk; do
    [ -n "$sk" ] || continue
    audit_skill "$sk"
    name=$(basename "$(dirname "$sk")")
    case "$base" in
      .claude/skills) CLAUDE_SKILLS="${CLAUDE_SKILLS:+$CLAUDE_SKILLS }$name" ;;
      .agents/skills) AGENTS_SKILLS="${AGENTS_SKILLS:+$AGENTS_SKILLS }$name" ;;
    esac
  done < <(find "$d" -mindepth 2 -maxdepth 2 -type f -name SKILL.md 2>/dev/null | sort || true)
done

if [ -n "$CLAUDE_SKILLS" ]; then
  missing=""
  for s in $CLAUDE_SKILLS; do case " $AGENTS_SKILLS " in *" $s "*) ;; *) missing="${missing:+$missing, }$s" ;; esac; done
  if [ -n "$missing" ] && has_vendor codex; then
    row "note" ".claude/skills/ vs .agents/skills/" "Codex reads repo skills from .agents/skills/"
    bridge ".claude/skills/" "not mirrored under .agents/skills/: $missing"
  elif [ -n "$missing" ]; then
    row "note" ".claude/skills/" "Codex reads repo skills from .agents/skills/; these have no copy there: $missing"
  fi
fi

if [ -d "$TARGET/.claude/commands" ]; then
  while IFS= read -r cmd; do
    [ -n "$cmd" ] || continue
    argnote=""
    grep -qE '\$ARGUMENTS|\$[0-9]' "$cmd" 2>/dev/null && argnote="; uses argument placeholders, on Codex's post-import review list"
    bound "$(rel "$cmd")" "Claude Code slash command$argnote"
  done < <(find "$TARGET/.claude/commands" -type f -name '*.md' 2>/dev/null | sort || true)
  cont "Codex import maps slash commands to skills; Claude Code has merged commands into skills"
fi

[ -z "$SKILL_DIRS" ] && [ ! -d "$TARGET/.claude/commands" ] && absent "skills" "no .claude/skills/ or .agents/skills/"

# --------------------------------------------------------------------- 4. MCP

section "MCP" "server yes, client file no; re-emit the client file per tool"

MCP_CLAUDE=""; MCP_CODEX=""; MCP_GEMINI=""; MCP_CURSOR=""
MCP_FILE="$TARGET/.mcp.json"
if valid_json "$MCP_FILE"; then
  MCP_CLAUDE=$(json_keys "$MCP_FILE" '.mcpServers' | paste -sd' ' -)
  n=$(printf '%s\n' "$MCP_CLAUDE" | wc -w)
  bound ".mcp.json" "Claude Code client file, $n server(s): ${MCP_CLAUDE:-none}"
  bad=$(jq -r '.mcpServers // {} | to_entries[] | select(.value.url != null and .value.type == null) | .key' "$MCP_FILE" 2>/dev/null || true)
  for s in $bad; do
    bridge ".mcp.json \"$s\"" "\"$s\" has url but no type; Claude Code reads it as a stdio server and skips it. Add \"type\": \"http\" (or \"sse\" / \"ws\")"
  done
elif [ -f "$MCP_FILE" ]; then
  undet ".mcp.json" "not valid JSON"
fi

if [ -f "$CODEX_TOML" ]; then
  MCP_CODEX=$(grep -oE '^\[mcp_servers\.[^]]+\]' "$CODEX_TOML" 2>/dev/null | sed -E 's/^\[mcp_servers\.//; s/\]$//; s/^"//; s/"$//' | paste -sd' ' - || true)
  [ -n "$MCP_CODEX" ] && bound ".codex/config.toml [mcp_servers.*]" "$(printf '%s\n' "$MCP_CODEX" | wc -w) server(s): $MCP_CODEX (trusted projects only)"
fi
if valid_json "$GEMINI_JSON"; then
  MCP_GEMINI=$(json_keys "$GEMINI_JSON" '.mcpServers' | paste -sd' ' -)
  if [ -n "$MCP_GEMINI" ]; then
    bound ".gemini/settings.json mcpServers" "$(printf '%s\n' "$MCP_GEMINI" | wc -w) server(s): $MCP_GEMINI"
    trusted=$(jq -r '.mcpServers | to_entries[] | select(.value.trust == true) | .key' "$GEMINI_JSON" 2>/dev/null | paste -sd' ' - || true)
    [ -n "$trusted" ] && cont "trust: true on $trusted; bypasses all confirmation dialogs"
  fi
fi
CURSOR_MCP="$TARGET/.cursor/mcp.json"
if valid_json "$CURSOR_MCP"; then
  MCP_CURSOR=$(json_keys "$CURSOR_MCP" '.mcpServers' | paste -sd' ' -)
  bound ".cursor/mcp.json" "$(printf '%s\n' "$MCP_CURSOR" | wc -w) server(s): ${MCP_CURSOR:-none}"
elif [ -f "$CURSOR_MCP" ]; then
  undet ".cursor/mcp.json" "not valid JSON"
fi

ALL_MCP=$(printf '%s\n' $MCP_CLAUDE $MCP_CODEX $MCP_GEMINI $MCP_CURSOR | sort -u | paste -sd' ' - || true)
if [ -n "$ALL_MCP" ]; then
  for s in $ALL_MCP; do
    declared=""
    case " $MCP_CLAUDE " in *" $s "*) declared="${declared:+$declared }claude" ;; esac
    case " $MCP_CODEX "  in *" $s "*) declared="${declared:+$declared }codex" ;; esac
    case " $MCP_GEMINI " in *" $s "*) declared="${declared:+$declared }gemini" ;; esac
    case " $MCP_CURSOR " in *" $s "*) declared="${declared:+$declared }cursor" ;; esac
    ports "mcp server \"$s\"" "the server process and the mcpServers shape port; declared for: $declared"
    lacking=$(others_lacking "$declared")
    [ -n "$lacking" ] && bridge "mcp server \"$s\"" "not declared for $lacking; re-emit in that vendor's client file"
  done
else
  absent "MCP" "no client file found (.mcp.json, .codex/config.toml, .gemini/settings.json, .cursor/mcp.json)"
fi

# ------------------------------------------------------------------- 5. hooks

section "Hooks" "no; re-map the event names, exit 2 survives"

HOOK_VENDORS=""
hook_events() { # file jq-path -> "Event(n) Event(n)"
  jq -r "$2 | if type==\"object\" then to_entries[] | \"\(.key)(\(.value | if type==\"array\" then length else 1 end))\" else empty end" "$1" 2>/dev/null | paste -sd' ' - || true
}

for f in "$TARGET/.claude/settings.json" "$TARGET/.claude/settings.local.json"; do
  valid_json "$f" || continue
  ev=$(hook_events "$f" '.hooks')
  [ -n "$ev" ] || continue
  HOOK_VENDORS="claude"
  bound "$(rel "$f") hooks" "$ev"
done
CODEX_HOOKS="$TARGET/.codex/hooks.json"
if valid_json "$CODEX_HOOKS"; then
  ev=$(hook_events "$CODEX_HOOKS" '.hooks')
  [ -n "$ev" ] && { HOOK_VENDORS="${HOOK_VENDORS:+$HOOK_VENDORS }codex"; bound ".codex/hooks.json" "$ev"; }
elif [ -f "$CODEX_HOOKS" ]; then
  HOOK_VENDORS="${HOOK_VENDORS:+$HOOK_VENDORS }codex"
  undet ".codex/hooks.json" "not valid JSON"
fi
if [ -f "$CODEX_TOML" ] && grep -qE '^\[\[?hooks' "$CODEX_TOML" 2>/dev/null; then
  n=$(grep -cE '^\[\[?hooks' "$CODEX_TOML" || true)
  HOOK_VENDORS="${HOOK_VENDORS:+$HOOK_VENDORS }codex"
  bound ".codex/config.toml [hooks]" "$n hook table(s); read with grep, not a TOML parser"
fi
if valid_json "$GEMINI_JSON"; then
  ev=$(hook_events "$GEMINI_JSON" '.hooks')
  [ -n "$ev" ] && { HOOK_VENDORS="${HOOK_VENDORS:+$HOOK_VENDORS }gemini"; bound ".gemini/settings.json hooks" "$ev"; }
fi
CURSOR_HOOKS="$TARGET/.cursor/hooks.json"
if valid_json "$CURSOR_HOOKS"; then
  ev=$(hook_events "$CURSOR_HOOKS" '.hooks')
  [ -n "$ev" ] && { HOOK_VENDORS="${HOOK_VENDORS:+$HOOK_VENDORS }cursor"; bound ".cursor/hooks.json" "$ev"; }
elif [ -f "$CURSOR_HOOKS" ]; then
  HOOK_VENDORS="${HOOK_VENDORS:+$HOOK_VENDORS }cursor"
  undet ".cursor/hooks.json" "not valid JSON"
fi

if [ -n "$HOOK_VENDORS" ]; then
  lacking=$(others_lacking "$HOOK_VENDORS")
  if [ -n "$lacking" ]; then
    for v in $lacking; do
      case "$v" in
        claude) bridge "hooks" "none for Claude Code; re-map into .claude/settings.json hooks (PreToolUse, PostToolUse, ...)" ;;
        codex)  bridge "hooks" "none for Codex; re-map into .codex/hooks.json or .codex/config.toml (PreToolUse, PermissionRequest, ...)" ;;
        gemini) bridge "hooks" "none for Gemini CLI; re-map into .gemini/settings.json hooks (BeforeTool, AfterTool, ...)" ;;
        cursor) bridge "hooks" "none for Cursor; re-map into .cursor/hooks.json (beforeShellExecution, preToolUse, ...)" ;;
      esac
    done
  fi
  cont "the exit-2 blocking convention survives the trip across all four vendors; the event name does not"
  cont "hooks in skill and subagent frontmatter are counted under those layers, not here"
else
  absent "hooks" "no hook config found for any vendor"
fi

# ------------------------------------------------------------- 6. permissions

section "Permissions" "no; re-express the tier in each vendor's grammar"

PERM_VENDORS=""
for f in "$TARGET/.claude/settings.json" "$TARGET/.claude/settings.local.json"; do
  valid_json "$f" || continue
  if [ "$(json_str "$f" '.permissions')" != "" ]; then
    a=$(jq -r '.permissions.allow // [] | length' "$f"); d=$(jq -r '.permissions.deny // [] | length' "$f"); k=$(jq -r '.permissions.ask // [] | length' "$f")
    dm=$(json_str "$f" '.permissions.defaultMode')
    PERM_VENDORS="claude"
    bound "$(rel "$f") permissions" "allow $a, deny $d, ask $k, defaultMode ${dm:-unset}"
    case "$dm" in
      auto|bypassPermissions) cont "defaultMode \"$dm\" does not take effect from a project settings file; the session starts in Manual mode" ;;
    esac
  fi
done
if [ -f "$CODEX_TOML" ]; then
  ap=$(toml_value "$CODEX_TOML" approval_policy); sm=$(toml_value "$CODEX_TOML" sandbox_mode)
  if [ -n "$ap$sm" ]; then
    PERM_VENDORS="${PERM_VENDORS:+$PERM_VENDORS }codex"
    bound ".codex/config.toml" "approval_policy ${ap:-unset} x sandbox_mode ${sm:-unset}"
    printf '%s' "$sm" | grep -q 'danger-full-access' && cont "danger-full-access disables sandboxing entirely"
  fi
fi
if [ -d "$TARGET/.gemini/policies" ]; then
  n=$(find "$TARGET/.gemini/policies" -type f -name '*.toml' 2>/dev/null | wc -l)
  if [ "$n" -gt 0 ]; then
    PERM_VENDORS="${PERM_VENDORS:+$PERM_VENDORS }gemini"
    bound ".gemini/policies/" "$n policy TOML file(s); priority-ordered rules under plan < default < autoEdit < yolo"
    cont "the Gemini docs mark the workspace policy tier as currently disabled; user and admin tiers load"
  fi
fi
CURSOR_CLI="$TARGET/.cursor/cli.json"
if valid_json "$CURSOR_CLI"; then
  a=$(jq -r '.permissions.allow // [] | length' "$CURSOR_CLI"); d=$(jq -r '.permissions.deny // [] | length' "$CURSOR_CLI")
  if [ "$((a + d))" -gt 0 ]; then
    PERM_VENDORS="${PERM_VENDORS:+$PERM_VENDORS }cursor"
    bound ".cursor/cli.json permissions" "allow $a, deny $d rule strings; deny takes precedence over allow"
  fi
elif [ -f "$CURSOR_CLI" ]; then
  PERM_VENDORS="${PERM_VENDORS:+$PERM_VENDORS }cursor"
  undet ".cursor/cli.json" "not valid JSON"
fi

if [ -n "$PERM_VENDORS" ]; then
  lacking=$(others_lacking "$PERM_VENDORS")
  for v in $lacking; do
    case "$v" in
      claude) bridge "permissions" "no Claude Code policy; re-express as permissions.allow/deny plus a permission mode in .claude/settings.json" ;;
      codex)  bridge "permissions" "no Codex policy; re-express as approval_policy x sandbox_mode in .codex/config.toml" ;;
      gemini) bridge "permissions" "no Gemini CLI policy; re-express as policy-engine TOML rules" ;;
      cursor) bridge "permissions" "no Cursor policy; re-express as Shell(...)/Read(...) rule strings in .cursor/cli.json" ;;
    esac
  done
  cont "which tier a task belongs in is a separate decision; this only checks that the tier exists per vendor"
else
  absent "permissions" "no permission policy found for any vendor"
fi

# --------------------------------------------------------------- 7. subagents

section "Subagents" "location partly, fields no; translate the frontmatter per schema"

SUB_FOUND=0
flag_fields() { # keys-lines  vendor-field-list -> comma list of matches
  local k out=""
  for k in $1; do case "$2" in *" $k "*) out="${out:+$out, }$k" ;; esac; done
  printf '%s' "$out"
}

if [ -d "$TARGET/.claude/agents" ]; then
  while IFS= read -r ag; do
    [ -n "$ag" ] || continue; SUB_FOUND=1
    keys=$(fm_keys "$ag")
    specific=$(flag_fields "$keys" " permissionMode hooks mcpServers isolation ")
    bound "$(rel "$ag")" "Claude-only fields: ${specific:-none}; location readable by Cursor (.claude/agents/ compatibility)"
    [ -z "$specific" ] && cont "keys: $(printf '%s\n' "$keys" | join_sp); tools and model values are still Claude's vocabulary"
  done < <(find "$TARGET/.claude/agents" -maxdepth 1 -type f -name '*.md' 2>/dev/null | sort || true)
fi
if [ -d "$TARGET/.codex/agents" ]; then
  while IFS= read -r ag; do
    [ -n "$ag" ] || continue; SUB_FOUND=1
    missing=""
    for req in name description developer_instructions; do
      grep -qE "^[[:space:]]*$req[[:space:]]*=" "$ag" 2>/dev/null || missing="${missing:+$missing, }$req"
    done
    bound "$(rel "$ag")" "Codex TOML agent; location readable by Cursor (.codex/agents/ compatibility)"
    [ -n "$missing" ] && cont "required keys not found by grep: $missing (Codex requires name, description, developer_instructions)"
  done < <(find "$TARGET/.codex/agents" -maxdepth 1 -type f -name '*.toml' 2>/dev/null | sort || true)
fi
if [ -d "$TARGET/.gemini/agents" ]; then
  while IFS= read -r ag; do
    [ -n "$ag" ] || continue; SUB_FOUND=1
    keys=$(fm_keys "$ag")
    specific=$(flag_fields "$keys" " max_turns timeout_mins kind temperature ")
    bound "$(rel "$ag")" "Gemini-only fields: ${specific:-none}; body becomes the system prompt"
  done < <(find "$TARGET/.gemini/agents" -maxdepth 1 -type f -name '*.md' 2>/dev/null | sort || true)
fi
if [ -d "$TARGET/.cursor/agents" ]; then
  while IFS= read -r ag; do
    [ -n "$ag" ] || continue; SUB_FOUND=1
    keys=$(fm_keys "$ag")
    specific=$(flag_fields "$keys" " readonly is_background ")
    bound "$(rel "$ag")" "Cursor-only fields: ${specific:-none}; .cursor/ wins over .claude/ or .codex/ on a name clash"
  done < <(find "$TARGET/.cursor/agents" -maxdepth 1 -type f -name '*.md' 2>/dev/null | sort || true)
fi
[ "$SUB_FOUND" = 1 ] || absent "subagents" "no .claude/agents, .codex/agents, .gemini/agents or .cursor/agents"

# ------------------------------------------- 8. worktrees, rulesets, container

section "Worktrees, rulesets, container" "ports; no vendor owns them, nothing to flip"

if git -C "$TARGET" rev-parse --is-inside-work-tree >/dev/null 2>&1; then
  wt=$(git -C "$TARGET" worktree list --porcelain 2>/dev/null | awk '/^worktree /{print substr($0,10)}' || true)
  n_wt=$(printf '%s\n' "$wt" | grep -c . || true)
  main_wt=$(printf '%s\n' "$wt" | head -1)
  if [ "$n_wt" -le 1 ]; then
    ports "git worktrees" "1 (the main checkout only); a plain sibling worktree per task costs nothing to standardize on"
  else
    ports "git worktrees" "$n_wt checkouts"
    printf '%s\n' "$wt" | tail -n +2 | while read -r w; do
      case "$w" in
        "$main_wt"/*) cont "$w  nested inside the main checkout" ;;
        *)            cont "$w  sibling directory" ;;
      esac
    done
  fi
  [ -d "$TARGET/.gemini/worktrees" ] && bound ".gemini/worktrees/" "Gemini-managed (experimental flag); the plain git worktree add is the vendor's own manual equivalent"
  codex_home="${CODEX_HOME:-$HOME/.codex}"
  [ -d "$codex_home/worktrees" ] && bound "$codex_home/worktrees/" "Codex-managed, scoped to the desktop app running parallel chats; keeps the most recent 15"
  remote=$(git -C "$TARGET" remote get-url origin 2>/dev/null || true)
  if printf '%s' "$remote" | grep -qE 'github\.com'; then
    slug=$(printf '%s' "$remote" | sed -E 's#.*github\.com[:/]##; s#\.git$##')
    undet "GitHub rulesets on main" "not readable from disk; check with: gh api repos/$slug/rulesets"
    cont "close the admin bypass and pin the required check to the app that sets it"
  else
    undet "branch rulesets" "not readable from disk; no GitHub remote detected"
  fi
else
  undet "git worktrees" "not a git repository"
fi

if [ -d "$TARGET/.devcontainer" ]; then
  ports ".devcontainer/" "a convention rather than an enforcement boundary; Claude Code does not require a container"
  cont "enforce with device management or software allowlisting if agents must not run outside it"
else
  absent ".devcontainer/" "no dev container; the vendor sandbox is not a substitute (it degrades to unsandboxed with a warning unless sandbox.failIfUnavailable is true)"
fi

# --------------------------------------------------------------- 9. capability

section "Capability" "not portable, but measurable; run your own task set in advance"
undet "second-agent task set" "not a file; the same model scores differently under different harnesses (Terminal-Bench 2.1)"
cont "pick the second agent on your own repo and task specs, not a two-point leaderboard gap"

# ----------------------------------------------------------------- summary ---

printf '\n== Summary\n'
printf '  PORTS %d   VENDOR-BOUND %d   UNDETERMINED %d   bridges missing %d\n' "$N_PORTS" "$N_BOUND" "$N_UNDET" "$N_BRIDGE"
if [ "$N_BRIDGE" -gt 0 ]; then
  for b in "${BRIDGES[@]}"; do printf '  - %s\n' "$b"; done
fi
printf '\n  Vendor-bound is a description, not a defect. The post'"'"'s point is that the adapter pile is\n'
printf '  expensive to move and the instruction file is cheap and light in effect; the swap is free only\n'
printf '  in the enforcement pile, and only if the enforcement was put there first.\n'
printf '  Cross-vendor bridges are only flagged for vendors whose artifacts already exist in this repo.\n'
printf '  TOML is read with grep. Nothing here was modified.\n'
