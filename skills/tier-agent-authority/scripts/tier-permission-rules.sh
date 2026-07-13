#!/usr/bin/env bash
# tier-permission-rules.sh — classify Claude Code permission rules into the four
# authority tiers from "Tier Your AI Agent's Production Authority by Task Risk"
# (https://jyoung.dev/blog/agent-permission-tiering/).
#
# Tiers, by reversibility and blast radius:
#   LOW      reversible read, no side effects      -> auto-execute; log it
#   MEDIUM   reversible write, contained radius    -> auto-execute inside a hard scope
#   HIGH     hard-to-reverse write, wide radius    -> human confirmation before execution
#   CRITICAL irreversible, catastrophic radius     -> deny-by-default; out-of-band grant
#   REVIEW   cannot be classified mechanically     -> classify by hand before granting
#
# Usage: tier-permission-rules.sh [target-dir]    (default: current directory)
# Reads: <target>/.claude/settings.json, <target>/.claude/settings.local.json,
#        ~/.claude/settings.json
#
# Honesty notes:
#   - Classification is a command-prefix heuristic, not a proof. An unrecognized
#     command is reported REVIEW, never assumed safe ("an unnamed need is a
#     scoping gap, not a reason to grant broadly").
#   - This scan covers the harness's permission rules only. Ambient credentials
#     (cloud CLI tokens, kubeconfigs, env secrets) are a separate, larger
#     authority surface this scan cannot see — the PocketOS deletion ran on a
#     CLI token, not a permission rule. Inventory those by hand.
# Requires: jq.

set -euo pipefail

command -v jq >/dev/null 2>&1 || { echo "error: jq is required" >&2; exit 1; }

TARGET=$(cd "${1:-.}" && pwd)

FLAGS=""
declare -A COUNT=()
DENY_CRITICAL=0

classify_bash() { # lowercased command prefix -> "TIER|reason"
  local lc="$1"
  # strip a leading timeout wrapper
  if [[ "$lc" =~ ^timeout\ +[0-9]+[smhd]?\ +(.*)$ ]]; then lc="${BASH_REMATCH[1]}"; fi

  if [ -z "$lc" ] || [ "$lc" = "*" ]; then
    echo "CRITICAL|unscoped shell — every command the environment can run is effectively allowed"
    return 0
  fi

  # CRITICAL — irreversible, catastrophic radius (the post's deny-by-default row)
  if printf '%s' "$lc" | grep -Eq \
      -e '(^| )rm +-[a-z]*r' \
      -e '^sudo( |$)' \
      -e 'terraform +destroy' \
      -e 'kubectl +delete' \
      -e 'docker +(system +prune|volume +rm)' \
      -e 'aws( +[a-z0-9-]+)+ +(delete-[a-z-]+|terminate-instances|rb)( |$)' \
      -e '(gcloud|az)( +[a-z0-9-]+)* +delete( |$)' \
      -e 'railway +(down|delete|volume +delete)' \
      -e 'drop +(table|database|schema)' \
      -e 'truncate +table' \
      -e 'gh +repo +delete'
  then
    echo "CRITICAL|irreversible, catastrophic radius — no standing grant; separate out-of-band authorization"
    return 0
  fi

  # HIGH — hard-to-reverse write, wide radius (default control: human confirmation)
  if printf '%s' "$lc" | grep -Eq \
      -e 'git +push( +[^ ]+)* +(--force(-with-lease)?|-f)( |$)' \
      -e 'git +reset +--hard' \
      -e 'git +clean +-[a-z]*f' \
      -e '^(npm|yarn|pnpm) +publish' \
      -e '^cargo +publish' \
      -e '^twine +upload' \
      -e '^gem +push' \
      -e 'docker +push' \
      -e '^gh +release' \
      -e '^gh +pr +merge' \
      -e '(^| )deploy( |$)' \
      -e 'migrat' \
      -e 'terraform +apply' \
      -e 'kubectl +(apply|rollout|scale)' \
      -e 'helm +(install|upgrade|uninstall|rollback)' \
      -e '^rm( |$)'
  then
    echo "HIGH|hard-to-reverse write, wide radius — default control is human confirmation"
    return 0
  fi

  # LOW — reversible reads and test runs, no side effects
  if printf '%s' "$lc" | grep -Eq \
      -e '^(ls|cat|head|tail|less|wc|pwd|which|whoami|date|file|stat|du|df|tree|diff)( |$)' \
      -e '^(grep|rg|find|fd|awk)( |$)' \
      -e '^sed +-n( |$)' \
      -e '^sed( +[^-])' \
      -e '^git( +-c +[^ ]+)*( +-c)? +(status|log|diff|show|blame|shortlog|remote|describe|rev-parse|ls-remote|ls-files)( |$)' \
      -e '^(npm|yarn|pnpm) +(run +)?test' \
      -e '^(pytest|jest|vitest|mocha|tox|shellcheck)( |$)' \
      -e '^go +(test|vet)( |$)' \
      -e '^cargo +(test|check)( |$)' \
      -e '^make +test( |$)' \
      -e '^echo( |$)'
  then
    echo "LOW|reversible read or test run, no side effects — auto-execute; log it"
    return 0
  fi

  # MEDIUM — reversible writes, contained radius (auto-execute inside a hard scope)
  if printf '%s' "$lc" | grep -Eq \
      -e '^git( +-c +[^ ]+)* +(add|commit|checkout|switch|restore|stash|fetch|pull|merge|rebase|cherry-pick|branch|tag|push|mv|worktree|init|clone|apply)( |$)' \
      -e '^(mkdir|touch|cp|mv|ln)( |$)' \
      -e '^sed +-i' \
      -e '^(npm|yarn|pnpm) +(ci|install|i|add|update|run)( |$)' \
      -e '^pip3? +install' \
      -e '^(poetry|uv|pipenv) +(add|install|sync|lock)( |$)' \
      -e '^cargo +(build|fmt|clippy|add)( |$)' \
      -e '^go +(build|fmt|mod|get|generate|run)( |$)' \
      -e '^make( |$)' \
      -e '^(gofmt|goimports|golangci-lint|eslint|prettier|ruff|black|flake8|mypy|tsc)( |$)' \
      -e '^gh +(pr|issue)( |$)'
  then
    echo "MEDIUM|reversible write, contained radius — the prefix/path scope is the hard boundary"
    return 0
  fi

  # REVIEW — network egress: authority is whatever the reachable API grants
  if printf '%s' "$lc" | grep -Eq '^(curl|wget|http|nc|netcat|ssh|scp|rsync|ftp)( |$)'; then
    echo "REVIEW|network egress — its authority is whatever the reachable API grants the ambient credential; name what that credential can do"
    return 0
  fi

  # REVIEW — arbitrary execution: the invoked program's reach, not the command's
  if printf '%s' "$lc" | grep -Eq \
      -e '^(npx|bunx)( |$)' \
      -e '(^|/)(python[0-9.]*|node|deno|ruby|perl|bash|sh|zsh)( |$)' \
      -e '^(uv|poetry|pipenv) +run( |$)'
  then
    echo "REVIEW|arbitrary execution — authority is whatever the invoked program can reach, not the launcher"
    return 0
  fi

  echo "REVIEW|unrecognized command — classify by reversibility and blast radius; an unnamed need is a scoping gap, not a reason to grant"
}

classify_rule() { # full rule string -> "TIER|reason"
  local rule="$1" tool spec cmd
  if [[ "$rule" == *"("* ]]; then
    tool="${rule%%(*}"
    spec="${rule#*(}"; spec="${spec%)}"
  else
    tool="$rule"; spec=""
  fi
  case "$tool" in
    Read|Grep|Glob|LS|NotebookRead|WebSearch)
      echo "LOW|read-only tool, no side effects" ;;
    WebFetch)
      if [ -z "$spec" ]; then
        echo "LOW|read-only, but unscoped egress — scope to domains (WebFetch(domain:...)); reads pair with egress controls"
      else
        echo "LOW|read-only, egress scoped to the specifier"
      fi ;;
    Edit|Write|MultiEdit|NotebookEdit|TodoWrite)
      echo "MEDIUM|reversible write inside the working tree — the directory boundary is the hard scope" ;;
    Bash)
      cmd="$spec"
      case "$cmd" in *:\*) cmd="${cmd%:\*}" ;; esac
      case "$cmd" in *\*) cmd="${cmd%\*}" ;; esac
      cmd="${cmd%"${cmd##*[![:space:]]}"}"
      classify_bash "$(printf '%s' "$cmd" | tr '[:upper:]' '[:lower:]')" ;;
    mcp__*)
      echo "REVIEW|MCP tool — its authority is the server's credential, invisible to this scan; ask what that credential can do" ;;
    Task|Agent)
      echo "REVIEW|delegated authority — subagents inherit tool access; tier the tools they inherit" ;;
    *)
      echo "REVIEW|unrecognized tool — classify by reversibility and blast radius" ;;
  esac
}

add_flag() { FLAGS="$FLAGS\n  $1"; }

scan_file() { # settings file
  local f="$1" list rule cls tier why dm low_in_ask
  echo
  echo "FILE: $f"

  dm=$(jq -r '.permissions.defaultMode // empty' "$f")
  if [ -n "$dm" ]; then
    echo "  defaultMode: $dm"
    case "$dm" in
      bypassPermissions) add_flag "DEFAULT MODE bypassPermissions ($f) — every tier auto-executes; the rules below are not the effective policy" ;;
      acceptEdits)       add_flag "DEFAULT MODE acceptEdits ($f) — medium-tier file edits auto-execute; the working-directory boundary is the only scope" ;;
    esac
  fi
  if [ "$(jq -r '.skipDangerousModePermissionPrompt // false' "$f")" = "true" ]; then
    add_flag "CONFIRMATION REMOVED ($f) — skipDangerousModePermissionPrompt is true: the confirmation step on the highest-authority launch mode is disabled"
  fi
  if [ "$(jq -r '.enableAllProjectMcpServers // false' "$f")" = "true" ]; then
    add_flag "BROAD GRANT ($f) — enableAllProjectMcpServers is true: every MCP server in .mcp.json is approved as a standing grant; name what each server's credential can do"
  fi

  if [ "$(jq -r '(.permissions.allow // []) + (.permissions.ask // []) + (.permissions.deny // []) | length' "$f")" -eq 0 ]; then
    echo "  (no permission rules)"
  fi
  for list in allow ask deny; do
    local n
    n=$(jq -r ".permissions.${list} // [] | length" "$f")
    [ "$n" -eq 0 ] && continue
    echo "  ${list} (${n} rules):"
    low_in_ask=0
    while IFS= read -r rule; do
      [ -z "$rule" ] && continue
      cls=$(classify_rule "$rule")
      tier="${cls%%|*}"; why="${cls#*|}"
      printf '    %-8s %s\n' "$tier" "$rule"
      COUNT["$list:$tier"]=$(( ${COUNT["$list:$tier"]:-0} + 1 ))
      case "$list" in
        allow)
          case "$tier" in
            CRITICAL) add_flag "CRITICAL IN ALLOW: $rule ($f) — an irreversible action holds an auto-execute control. This is the PocketOS shape: a routine grant carrying delete-everything capability. The tier's control is deny-by-default with a separate out-of-band grant." ;;
            HIGH)     add_flag "HIGH IN ALLOW: $rule ($f) — a hard-to-reverse action auto-executes; the tier's default control is human confirmation. If this was promoted deliberately, record the clean-run threshold that earned it." ;;
            REVIEW)   add_flag "REVIEW IN ALLOW: $rule ($f) — $why" ;;
          esac ;;
        ask)
          case "$tier" in
            CRITICAL) add_flag "CRITICAL BEHIND A HUMAN GATE: $rule ($f) — the gate decays (Claude Code users approve 93% of permission prompts); the tier's control is deny-by-default with out-of-band authorization, not a prompt." ;;
            LOW)      low_in_ask=$((low_in_ask + 1)) ;;
          esac ;;
        deny)
          [ "$tier" = "CRITICAL" ] && DENY_CRITICAL=$((DENY_CRITICAL + 1)) ;;
      esac
    done < <(jq -r ".permissions.${list} // [] | .[]" "$f")
    if [ "$list" = "ask" ] && [ "$low_in_ask" -gt 0 ]; then
      add_flag "LOW-TIER RULES BEHIND THE GATE: $low_in_ask low-tier rule(s) in ask ($f) — every low-risk prompt spends the reviewer attention the high-tier prompts need; consider auto-execute with logging."
    fi
  done
}

# --- main ----------------------------------------------------------------------
FILES=()
for f in "$TARGET/.claude/settings.json" "$TARGET/.claude/settings.local.json" "$HOME/.claude/settings.json"; do
  [ -f "$f" ] && FILES+=("$f")
done

echo "Agent authority tier scan: $TARGET"
echo "Tiers by reversibility x blast radius: LOW auto-execute | MEDIUM bounded"
echo "auto-execute | HIGH human-approve | CRITICAL deny-by-default | REVIEW by hand."
echo "Classification is a command-prefix heuristic — REVIEW is never assumed safe."

if [ ${#FILES[@]} -eq 0 ]; then
  echo
  echo "No Claude Code settings files found for $TARGET (looked for .claude/settings.json,"
  echo ".claude/settings.local.json, ~/.claude/settings.json). The harness has no explicit"
  echo "permission rules here — the effective policy is whatever mode the session runs in."
  exit 0
fi

for f in "${FILES[@]}"; do
  scan_file "$f"
done

echo
echo "SUMMARY"
for list in allow ask deny; do
  line=""
  total=0
  for tier in LOW MEDIUM HIGH CRITICAL REVIEW; do
    c=${COUNT["$list:$tier"]:-0}
    total=$((total + c))
    [ "$c" -gt 0 ] && line="$line $tier $c,"
  done
  [ "$total" -gt 0 ] && printf '  %-6s %3d rules —%s\n' "$list" "$total" "${line%,}"
done
[ "$DENY_CRITICAL" -gt 0 ] && echo "  deny list holds $DENY_CRITICAL critical-tier rule(s) — deny-by-default correctly implemented for those."

echo
echo "FLAGS"
if [ -n "$FLAGS" ]; then
  printf '%b\n' "$FLAGS"
else
  echo "  (none — no rule holds a control looser than its tier's default)"
fi

echo
echo "NOT COVERED BY THIS SCAN: ambient credentials — cloud CLI tokens, kubeconfigs,"
echo "registry logins, env secrets the agent's commands inherit. The PocketOS deletion"
echo "ran on a CLI token no permission rule governed. Inventory those by hand: for each"
echo "credential, ask 'what could this do?' before 'why would the model do it?'"
echo
echo "Next: run every REVIEW rule and every ambient credential down the four-tier table,"
echo "and record a graduation ledger for anything held looser than its tier's default."
echo "The tier-agent-authority SKILL.md drives that pass."
echo "Full argument: https://jyoung.dev/blog/agent-permission-tiering/"
