#!/usr/bin/env bash
# harness-audit.sh — the seven-question harness audit from
# "Audit Your Agent Harness: The Deterministic Layer Nobody Reviews"
# https://jyoung.dev/blog/agent-harness-audit/
#
# READ-ONLY. This script opens configuration files, prints what it finds, and
# writes nothing. It never fixes, tunes, or reformats a setting, and it does not
# grade: there is no score, no threshold, and no "recommended" number of hooks,
# rules, or MCP servers. It reports which control surfaces sit at a shipped
# default, which ones someone deliberately set, and which ones it cannot
# determine from disk.
#
# What it answers, per the post's closing checklist:
#   Q1 which permission rules exist, at which scope, and what happens to a call
#      no rule matches
#   Q2 where each visible control physically executes: model context, runtime,
#      or kernel
#   Q3 whether the sandbox can quietly not exist, and whether excludedCommands
#      has been widened at any scope
#   Q4 which hooks are registered, and which of them fail open
#   Q5 whether the tool-decision record is switched on
#   Q6 which runtime version you are auditing
#   Q7 what the audit buys (a statement, not a check)
#
# Hooks are NOT an enforcement boundary. This script lists registered hooks as
# an inventory of interception points, never as evidence that a policy holds.
#
# Usage: harness-audit.sh [target-dir]     (default: current directory)
# Requires: jq. Everything else is coreutils.

set -euo pipefail

usage() {
  cat <<'EOF'
harness-audit.sh [target-dir]

Read-only inventory of the agent-harness control surfaces in a repo plus your
user-scope config. Prints the seven answers from
https://jyoung.dev/blog/agent-harness-audit/ and names the ones it cannot
determine. Writes nothing.
EOF
}

case "${1:-}" in
  -h|--help) usage; exit 0 ;;
esac

command -v jq >/dev/null 2>&1 || { echo "error: jq is required" >&2; exit 1; }

TARGET=$(cd "${1:-.}" 2>/dev/null && pwd) || { echo "error: no such directory: ${1:-.}" >&2; exit 1; }

SCOPES=()
INVALID=()
UNDET=()
declare -A ANSWER=()

note_undet() { UNDET+=("$1"); }

add_scope() { # label file
  [ -f "$2" ] || return 0
  if jq empty "$2" >/dev/null 2>&1; then
    SCOPES+=("$1|$2")
  else
    INVALID+=("$1 $2")
  fi
}

add_scope managed "/etc/claude-code/managed-settings.json"
add_scope managed "/Library/Application Support/ClaudeCode/managed-settings.json"
add_scope user    "$HOME/.claude/settings.json"
add_scope project "$TARGET/.claude/settings.json"
add_scope local   "$TARGET/.claude/settings.local.json"

scope_values() { # jq-filter -> lines "scope<TAB>file<TAB>value"
  local filter="$1" s label file val
  [ ${#SCOPES[@]} -eq 0 ] && return 0
  for s in "${SCOPES[@]}"; do
    label="${s%%|*}"; file="${s#*|}"
    val=$(jq -r "$filter | if . == null then empty else (if (type==\"array\" or type==\"object\") then tojson else tostring end) end" "$file" 2>/dev/null || true)
    [ -n "$val" ] && printf '%s\t%s\t%s\n' "$label" "$file" "$val"
  done
  return 0
}

report_key() { # jq-filter  display-name  documented-note
  local filter="$1" name="$2" note="${3:-}" vals distinct line
  vals=$(scope_values "$filter")
  if [ -z "$vals" ]; then
    printf '  %-32s DEFAULT — not set at any scope\n' "$name"
    [ -n "$note" ] && printf '      %s\n' "$note"
    return 0
  fi
  distinct=$(printf '%s\n' "$vals" | cut -f3 | sort -u | wc -l)
  if [ "$distinct" -gt 1 ]; then
    printf '  %-32s UNDETERMINED — scopes disagree\n' "$name"
    note_undet "$name is set to different values at different scopes; this script does not resolve scope precedence"
  else
    printf '  %-32s SET\n' "$name"
  fi
  while IFS=$'\t' read -r sl _sf sv; do
    [ -z "$sl" ] && continue
    printf '      %-8s %s\n' "$sl" "$sv"
  done <<<"$vals"
  [ -n "$note" ] && printf '      %s\n' "$note"
  return 0
}

rule_total() { # list-name -> integer across all scopes
  local list="$1" s file n total=0
  [ ${#SCOPES[@]} -eq 0 ] && { echo 0; return 0; }
  for s in "${SCOPES[@]}"; do
    file="${s#*|}"
    n=$(jq -r --arg l "$list" '(.permissions[$l] // []) | length' "$file" 2>/dev/null || echo 0)
    total=$((total + n))
  done
  echo "$total"
}

hook_rows() { # -> lines "scope<TAB>event<TAB>matcher<TAB>type<TAB>command"
  local s label file
  [ ${#SCOPES[@]} -eq 0 ] && return 0
  for s in "${SCOPES[@]}"; do
    label="${s%%|*}"; file="${s#*|}"
    jq -r --arg sc "$label" '
      (.hooks // {}) | to_entries[] as $e
      | ($e.value // []) []
      | . as $grp
      | (($grp.hooks // [$grp])[])
      | [$sc, $e.key, ($grp.matcher // "-"), (.type // "command"),
         ((.command // .prompt // ($grp | tojson)) | tostring)]
      | @tsv
    ' "$file" 2>/dev/null || true
  done
  return 0
}

resolve_script() { # command-string -> path or empty
  local cmd="$1" tok
  tok=$(printf '%s' "$cmd" | awk '{print $1}')
  tok="${tok%\"}"; tok="${tok#\"}"
  tok="${tok//\$CLAUDE_PROJECT_DIR/$TARGET}"
  tok="${tok//\$\{CLAUDE_PROJECT_DIR\}/$TARGET}"
  case "$tok" in
    "~"/*) tok="$HOME/${tok#\~/}" ;;
  esac
  case "$tok" in
    /*) : ;;
    ./*|../*) tok="$TARGET/${tok#./}" ;;
    *) [ -f "$TARGET/$tok" ] && tok="$TARGET/$tok" ;;
  esac
  [ -f "$tok" ] && [ -r "$tok" ] && printf '%s' "$tok"
  return 0
}

hr() { printf '%s\n' "------------------------------------------------------------------------"; }

# --- header -------------------------------------------------------------------
echo "HARNESS AUDIT — $TARGET"
echo "Read-only: this script inspects configuration and changes nothing."
echo "No scores, no thresholds. DEFAULT = nobody chose it. SET = somebody did."
echo "UNDETERMINED = not answerable from disk; that is a finding, not a pass."

CC_VERSION=""
if command -v claude >/dev/null 2>&1; then
  CC_VERSION=$(claude --version 2>/dev/null | head -1 || true)
fi

if [ ${#SCOPES[@]} -eq 0 ]; then
  echo
  echo "No Claude Code settings files found (looked at managed, ~/.claude/settings.json,"
  echo "$TARGET/.claude/settings.json, $TARGET/.claude/settings.local.json)."
  echo "Every control surface below is therefore at whatever the install shipped."
else
  echo
  echo "Settings files read:"
  for s in "${SCOPES[@]}"; do printf '  %-8s %s\n' "${s%%|*}" "${s#*|}"; done
fi
if [ ${#INVALID[@]} -gt 0 ]; then
  echo "Unparseable settings files (skipped):"
  for s in "${INVALID[@]}"; do printf '  %s\n' "$s"; done
  note_undet "one or more settings files are not valid JSON and were skipped"
fi

# --- Q1 -----------------------------------------------------------------------
echo
hr
echo "Q1  NAME THE SOFTWARE THAT DECIDES — permission rules by scope"
hr
if [ ${#SCOPES[@]} -gt 0 ]; then
  for s in "${SCOPES[@]}"; do
    label="${s%%|*}"; file="${s#*|}"
    a=$(jq -r '(.permissions.allow // []) | length' "$file")
    k=$(jq -r '(.permissions.ask   // []) | length' "$file")
    d=$(jq -r '(.permissions.deny  // []) | length' "$file")
    dm=$(jq -r '.permissions.defaultMode // "-"' "$file")
    printf '  %-8s allow %-3s ask %-3s deny %-3s  defaultMode %s\n' "$label" "$a" "$k" "$d" "$dm"
  done
fi
A_TOT=$(rule_total allow); K_TOT=$(rule_total ask); D_TOT=$(rule_total deny)
echo "  total across scopes: allow $A_TOT, ask $K_TOT, deny $D_TOT"

RM_RULES=$(
  if [ ${#SCOPES[@]} -gt 0 ]; then
    for s in "${SCOPES[@]}"; do
      label="${s%%|*}"; file="${s#*|}"
      jq -r --arg sc "$label" '
        ["allow","ask","deny"][] as $l
        | (.permissions[$l] // [])[]
        | "    \($sc) \($l): \(.)"
      ' "$file" 2>/dev/null || true
    done | grep -Ei '(^|[(| ])rm(dir)?([ )*:]|$)' || true
  fi
)
echo
if [ -n "$RM_RULES" ]; then
  echo "  Rules naming rm/rmdir (the post's rm -rf ./build test case):"
  printf '%s\n' "$RM_RULES"
  echo "    A rule matching rm is not the same as a rule matching this call — the"
  echo "    specifier is compared against the command string, so check the match by hand."
else
  echo "  Rules naming rm/rmdir: none. The post's rm -rf ./build matches no rule you"
  echo "  wrote, so it falls through to the shipped default."
fi
echo "  Shipped default for an unmatched command: \"Fail-closed matching: Unmatched"
echo "  commands default to requiring manual approval\" (Claude Code Docs: Security)."
echo "  Note what is not special-cased: rm/rmdir targeting /, your home directory, or"
echo "  other critical system paths trigger a prompt on their own. ./build is none of"
echo "  those, and a rule matches the command string, not where a symlink resolves."

echo
echo "  MCP servers — tool paths the permission rules above may not name:"
MCP_ANY=0
if [ -f "$TARGET/.mcp.json" ]; then
  mcp_p=$(jq -r '(.mcpServers // {}) | keys | join(", ")' "$TARGET/.mcp.json" 2>/dev/null || true)
  [ -n "$mcp_p" ] && { printf '    project .mcp.json: %s\n' "$mcp_p"; MCP_ANY=1; }
fi
if [ -f "$HOME/.claude.json" ]; then
  mcp_u=$(jq -r '(.mcpServers // {}) | keys | join(", ")' "$HOME/.claude.json" 2>/dev/null || true)
  [ -n "$mcp_u" ] && { printf '    user ~/.claude.json: %s\n' "$mcp_u"; MCP_ANY=1; }
  mcp_pu=$(jq -r --arg t "$TARGET" '((.projects[$t].mcpServers // {}) | keys | join(", "))' "$HOME/.claude.json" 2>/dev/null || true)
  [ -n "$mcp_pu" ] && { printf '    user config, this project: %s\n' "$mcp_pu"; MCP_ANY=1; }
fi
[ "$MCP_ANY" -eq 0 ] && echo "    none declared in .mcp.json or ~/.claude.json"
eamps=$(scope_values '.enableAllProjectMcpServers')
if [ -n "$eamps" ]; then
  while IFS=$'\t' read -r sl _sf sv; do
    printf '    enableAllProjectMcpServers=%s (%s) — every server in .mcp.json is approved by standing grant\n' "$sv" "$sl"
  done <<<"$eamps"
fi
echo "    Tool count per server: UNDETERMINED — counting tools means starting each"
echo "    server and listing them, and this script executes nothing."
note_undet "MCP tool counts (and therefore the context each server costs) — requires starting the servers"
ANSWER[1]="allow $A_TOT / ask $K_TOT / deny $D_TOT across ${#SCOPES[@]} scope file(s); unmatched commands prompt"

# --- Q2 -----------------------------------------------------------------------
echo
hr
echo "Q2  WHERE EACH CHECK PHYSICALLY EXECUTES — three buckets"
hr
echo "  Bucket 1 — the model's context (a guide, not a gate):"
CTX_N=0
for f in "$TARGET/CLAUDE.md" "$TARGET/.claude/CLAUDE.md" "$TARGET/AGENTS.md" "$HOME/.claude/CLAUDE.md"; do
  if [ -f "$f" ]; then
    printf '    %-58s %s bytes\n' "$f" "$(wc -c <"$f" | tr -d ' ')"
    CTX_N=$((CTX_N + 1))
  fi
done
[ "$CTX_N" -eq 0 ] && echo "    none found at the standard paths"
echo "    Anything written here is a request the model can reinterpret. Nested"
echo "    per-directory files and skills are not enumerated by this scan."

echo
echo "  Bucket 2 — the runtime, before dispatch:"
HOOK_ROWS=$(hook_rows)
HOOK_N=0
[ -n "$HOOK_ROWS" ] && HOOK_N=$(printf '%s\n' "$HOOK_ROWS" | grep -c . || true)
printf '    permission rules: %s   registered hook entries: %s\n' "$((A_TOT + K_TOT + D_TOT))" "$HOOK_N"
echo "    These judge the command string. A string cannot tell you where a symlink"
echo "    resolves. Hook entries are interception points, not enforcement (see Q4)."

echo
echo "  Bucket 3 — the kernel:"
SB_SET=$(scope_values '.sandbox')
if [ -n "$SB_SET" ]; then
  echo "    sandbox keys are configured — see Q3 for the per-key values"
else
  echo "    no sandbox block at any scope — see Q3"
fi
echo "    Built-in file tools are outside this bucket either way: \"Read, Edit, and"
echo "    Write use the permission system directly rather than running through the"
echo "    sandbox\" (Claude Code Docs: Sandboxing)."
ANSWER[2]="context $CTX_N file(s) / runtime $((A_TOT + K_TOT + D_TOT)) rules + $HOOK_N hook entries / kernel: see Q3"

# --- Q3 -----------------------------------------------------------------------
echo
hr
echo "Q3  CAN YOUR SANDBOX QUIETLY NOT EXIST"
hr
report_key '.sandbox.enabled' 'sandbox.enabled' \
  "This script does not assert the unset default: sandbox behavior is version-gated (see Q6). If it is unset here, you have not chosen it."
report_key '.sandbox.failIfUnavailable' 'sandbox.failIfUnavailable' \
  "Documented default: \"if the sandbox cannot start because dependencies are missing or the platform is unsupported, Claude Code shows a warning and runs commands without sandboxing.\""
report_key '.sandbox.allowUnsandboxedCommands' 'sandbox.allowUnsandboxedCommands' \
  "Governs the model-driven escape hatch: \"when a command fails because of sandbox restrictions, Claude analyzes the failure and may retry the command with the dangerouslyDisableSandbox parameter.\""

EXCL=$(scope_values '.sandbox.excludedCommands')
echo
if [ -z "$EXCL" ]; then
  printf '  %-32s DEFAULT — not widened at any scope\n' 'sandbox.excludedCommands'
else
  printf '  %-32s SET — each entry runs outside the sandbox\n' 'sandbox.excludedCommands'
  while IFS=$'\t' read -r sl _sf sv; do
    [ -z "$sl" ] && continue
    printf '      %-8s %s\n' "$sl" "$sv"
  done <<<"$EXCL"
  if [ "$(printf '%s\n' "$EXCL" | cut -f3 | sort -u | wc -l)" -gt 1 ]; then
    echo "      The lists differ by scope — someone widened this somewhere. Which list"
    echo "      applies at runtime is not resolved by this script."
    note_undet "sandbox.excludedCommands differs by scope; the effective list was not resolved"
  fi
fi
echo "      \"excludedCommands has no equivalent managed-only lockdown, so a developer"
echo "      can always append entries that run additional commands outside the sandbox.\""

OTHER_SB=$(scope_values '(.sandbox // {}) | del(.enabled, .failIfUnavailable, .allowUnsandboxedCommands, .excludedCommands) | if length == 0 then null else (keys | join(", ")) end')
if [ -n "$OTHER_SB" ]; then
  echo
  echo "  Other sandbox keys present (reported, not interpreted):"
  while IFS=$'\t' read -r sl _sf sv; do
    [ -z "$sl" ] && continue
    printf '      %-8s %s\n' "$sl" "$sv"
  done <<<"$OTHER_SB"
fi
echo
echo "  Ceiling on all of the above, from the same reference page: \"Sandboxing reduces"
echo "  risk but is not a complete isolation boundary.\" The vendor's engineering blog"
echo "  says the opposite; only one of those two is the thing that runs."
if [ -z "$SB_SET" ]; then
  ANSWER[3]="no sandbox block at any scope — every sandbox key is at its shipped default"
  note_undet "whether a sandbox is active at all: no sandbox block at any scope, and the unset default is version-gated"
else
  ANSWER[3]="sandbox block present — see the per-key values above"
fi

# --- Q4 -----------------------------------------------------------------------
echo
hr
echo "Q4  YOUR HOOK LAYER IS NOT AN ENFORCEMENT BOUNDARY"
hr
if [ "$HOOK_N" -eq 0 ]; then
  echo "  No hooks registered in any settings file read above."
else
  echo "  Registered hook entries (an inventory of interception points):"
  echo
  while IFS=$'\t' read -r sc ev matcher htype cmd; do
    [ -z "$sc" ] && continue
    printf '  [%s] %s  matcher=%s  type=%s\n' "$sc" "$ev" "$matcher" "$htype"
    printf '      %s\n' "$cmd"
    case "$ev" in
      PreToolUse|PermissionRequest)
        echo "      event: documented to return a permission decision (allow/deny/ask/defer)" ;;
      WorktreeCreate)
        echo "      event: the documented exception — any non-zero exit code aborts worktree creation" ;;
      *)
        echo "      event: blocking status not asserted here — 14 of the 30 documented events"
        echo "             can block on exit code 2 and 15 cannot; check the hooks reference" ;;
    esac
    if [ "$htype" != "command" ]; then
      echo "      TYPE: $htype — a model evaluates this condition. Inferential control, not a gate."
      echo
      continue
    fi
    sp=$(resolve_script "$cmd")
    if [ -z "$sp" ]; then
      e2=$(printf '%s' "$cmd" | grep -cE 'exit[[:space:](]+2([^0-9]|$)' || true)
      e1=$(printf '%s' "$cmd" | grep -cE 'exit[[:space:](]+1([^0-9]|$)' || true)
      echo "      script: not resolvable to a readable file (inline command, or a wrapper)"
      printf '      inline string: exit 2 x%s, exit 1 x%s — read it by hand\n' "$e2" "$e1"
      note_undet "hook $ev ($sc) does not resolve to a readable script; its exit behavior was not inspected"
    else
      e2=$(grep -cE 'exit[[:space:](]+2([^0-9]|$)' "$sp" || true)
      e1=$(grep -cE 'exit[[:space:](]+1([^0-9]|$)' "$sp" || true)
      printf '      script: %s (exit 2 x%s, exit 1 x%s)\n' "$sp" "$e2" "$e1"
      if [ "$e1" -gt 0 ]; then
        echo "      FAILS OPEN: \"Claude Code treats exit code 1 as a non-blocking error and"
        echo "      proceeds with the action.\" Every exit 1 in a policy hook is a policy that"
        echo "      does not hold. Convert to exit 2, or move the rule to the permission system."
      fi
      if [ "$e2" -eq 0 ]; then
        echo "      No exit 2 anywhere in the script: nothing in it can block, including a crash"
        echo "      (an unhandled error exits non-zero and non-2, which proceeds)."
      fi
    fi
    echo
  done <<<"$HOOK_ROWS"
fi
echo "  Standing fact, independent of what is listed above: this layer is not where a"
echo "  rule you cannot tolerate failing belongs. The vendor redirects you off it —"
echo "  \"use the permission system rather than a hook to enforce a hard allow or deny\""
echo "  — and OpenAI's Codex docs say \"treat tool hooks as a useful guardrail, not a"
echo "  complete enforcement boundary.\" Registered != enforced."

if [ -f "$TARGET/.cursor/hooks.json" ]; then
  echo
  echo "  Cursor hooks found at $TARGET/.cursor/hooks.json:"
  jq -r '
    (.hooks // {}) | to_entries[] as $e | ($e.value // [])[]
    | [$e.key, ((.command // .) | tostring), ((.failClosed // "unset") | tostring)] | @tsv
  ' "$TARGET/.cursor/hooks.json" 2>/dev/null | while IFS=$'\t' read -r ev cmd fc; do
    printf '    %s  failClosed=%s\n      %s\n' "$ev" "$fc" "$cmd"
    if [ "$fc" != "true" ]; then
      echo "      Cursor default: \"Other exit codes - Hook failed, action proceeds (fail-open"
      echo "      by default)\". failClosed ships false; the vendor calls it \"Useful for"
      echo "      security-critical hooks\"."
    fi
  done || true
fi
ANSWER[4]="$HOOK_N hook entr(ies) registered; hooks are not an enforcement boundary at any count"

# --- Q5 -----------------------------------------------------------------------
echo
hr
echo "Q5  THE TOOL-DECISION RECORD"
hr
TEL_FOUND=0
for var in CLAUDE_CODE_ENABLE_TELEMETRY OTEL_LOG_TOOL_DETAILS; do
  live="${!var:-}"
  if [ -n "$live" ]; then
    printf '  %-32s SET in this shell: %s\n' "$var" "$live"
    TEL_FOUND=1
  else
    printf '  %-32s not set in this shell\n' "$var"
  fi
  vals=$(scope_values ".env.${var}")
  if [ -n "$vals" ]; then
    while IFS=$'\t' read -r sl _sf sv; do
      [ -z "$sl" ] && continue
      printf '      settings env (%s): %s\n' "$sl" "$sv"
    done <<<"$vals"
    TEL_FOUND=1
  fi
  rc_hit=$(grep -ls "$var" "$HOME/.bashrc" "$HOME/.zshrc" "$HOME/.profile" "$HOME/.bash_profile" 2>/dev/null || true)
  if [ -n "$rc_hit" ]; then
    printf '      named in: %s (whether the agent process inherits it is undetermined)\n' "$(printf '%s' "$rc_hit" | tr '\n' ' ')"
  fi
done
OTEL_OTHER=$(scope_values '(.env // {}) | with_entries(select(.key | startswith("OTEL_"))) | if length == 0 then null else (keys | join(", ")) end')
if [ -n "$OTEL_OTHER" ]; then
  echo "  Other OTEL_* keys in settings env blocks:"
  while IFS=$'\t' read -r sl _sf sv; do
    [ -z "$sl" ] && continue
    printf '      %-8s %s\n' "$sl" "$sv"
  done <<<"$OTEL_OTHER"
fi
echo
if [ "$TEL_FOUND" -eq 0 ]; then
  echo "  DEFAULT — nothing is being recorded. Telemetry is off until"
  echo "  CLAUDE_CODE_ENABLE_TELEMETRY is set (the docs mark it \"required\"), and the"
  echo "  command string (tool_parameters) is emitted only when OTEL_LOG_TOOL_DETAILS=1."
  echo "  This is not a buffer waiting to be enabled: at defaults it was never written,"
  echo "  so there is nothing to recover after an incident."
  ANSWER[5]="off — no tool_decision record is being written"
else
  echo "  At least one switch is set. Verify a claude_code.tool_decision event actually"
  echo "  lands with a populated source and tool_parameters — the variables being set is"
  echo "  not the same as an event arriving at a collector."
  ANSWER[5]="at least one telemetry switch set — verify an event actually lands"
fi
echo
echo "  Blind spot you are buying either way: the source attribute names the surface"
echo "  (config, hook, user_permanent, user_temporary, user_abort, user_reject), but"
echo "  \"The event doesn't indicate which of these sources matched\" for config. You"
echo "  learn the decision was automatic; you do not learn which rule made it."
echo "  Upstream, the OpenTelemetry GenAI conventions make gen_ai.tool.name Required"
echo "  and gen_ai.tool.call.arguments Opt-In — a compliant trace records that a tool"
echo "  ran and not what it ran. That is a privacy tradeoff, not a bug to upgrade past."
note_undet "whether a tool_decision event reaches a collector — this script reads config, not your telemetry backend"

# --- Q6 -----------------------------------------------------------------------
echo
hr
echo "Q6  THE VERSION YOU AUDITED"
hr
if [ -n "$CC_VERSION" ]; then
  echo "  claude --version: $CC_VERSION"
  ANSWER[6]="audited against $CC_VERSION — record it and re-run on the next release notes"
else
  echo "  claude not on PATH — record your runtime version by hand before filing this run."
  ANSWER[6]="runtime version unknown from this shell — record it by hand"
  note_undet "the runtime version this audit describes (claude not on PATH)"
fi
echo "  Re-run this against release notes, not the calendar. The sandboxing reference"
echo "  alone carries version-gated behavior notes at seven separate point releases"
echo "  between v2.1.187 and v2.1.218 — credential protection, network session grants,"
echo "  TLS termination, symlink resolution on protected settings paths, plan-mode"
echo "  approval scope, filesystem-layer disabling, and classifier routing for rm."
echo "  This script does not fetch changelogs; diffing them is your move."

# --- Q7 -----------------------------------------------------------------------
echo
hr
echo "Q7  SAY OUT LOUD WHAT THIS BUYS"
hr
echo "  Not a check — a sentence to say before anyone starts. This audit bounds blast"
echo "  radius. It does not improve code quality, and no arrangement of permission"
echo "  rules, sandboxes, or decision logs detects a design that will be expensive in"
echo "  eighteen months. Agent failures are predominantly model-side (57.9% epistemic"
echo "  against 9.4% environment across 1,794 annotated trajectories), so the case for"
echo "  this work is leverage, not causation. If anyone in the room expects the audit"
echo "  to improve the agent's architecture, correct them now."
ANSWER[7]="blast radius, not code quality — state it before the work starts"

# --- recap --------------------------------------------------------------------
echo
hr
echo "THE SEVEN ANSWERS"
hr
for i in 1 2 3 4 5 6 7; do
  printf '  %s. %s\n' "$i" "${ANSWER[$i]}"
done

echo
hr
echo "YOUR FINDING — what this run could not answer"
hr
if [ ${#UNDET[@]} -eq 0 ]; then
  echo "  Nothing above came back undetermined. Confirm by hand anyway that the"
  echo "  session's CLI flags and permission mode match what these files say."
else
  for u in "${UNDET[@]}"; do printf '  - %s\n' "$u"; done
fi
echo
echo "  \"The one question you can't answer is your finding.\""

echo
hr
echo "NOT COVERED BY THIS SCAN"
hr
cat <<'EOF'
  - CLI flags, permission mode, and session-scoped grants. The effective policy at
    runtime is the files above plus how the session was launched; this scan reads
    only the files.
  - Plugin-supplied and managed-policy hooks outside the settings files read above.
  - Codex and Gemini CLI configuration. The post's Codex row (hosted tools such as
    WebSearch skip the local hook path entirely) and the Gemini policy-engine row
    still apply to those runtimes; check them by hand.
  - Ambient credentials — cloud CLI tokens, kubeconfigs, registry logins, env
    secrets the agent's commands inherit. No permission rule governs them.
  - Which of the 30 documented hook events block on exit code 2. The count (14 do,
    15 do not, WorktreeCreate aborts on any non-zero) is documented; the per-event
    mapping is not asserted here.

Full argument: https://jyoung.dev/blog/agent-harness-audit/
EOF
