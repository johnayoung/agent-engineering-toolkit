#!/usr/bin/env bash
# tool-contract-audit.sh: audit what an agent's tool calls mean, not only
# whether they may run.
#
# From "Agent Tool Design Belongs in Your Harness Audit, Not Prompt Tips"
# https://jyoung.dev/blog/agent-tool-contracts/
#
# Reads an MCP server's tools/list output and checks the parts of the post's
# tool contract audit that a definition can show. Everything else is printed
# as NOT VISIBLE or UNDETERMINED, never as a pass.
#
# Usage:
#   tool-contract-audit.sh capture [--out FILE] [--timeout SECS] -- CMD [ARGS...]
#       Start a stdio MCP server, run initialize + tools/list (following
#       nextCursor), write {"serverInfo":..,"tools":[..]} to FILE or stdout.
#   tool-contract-audit.sh audit [--untrusted] <tools.json>
#       Flag write tools with no idempotency-key parameter, destination
#       parameters (to, recipient, url, channel, account, ...) that are free
#       strings with no enum, const, pattern, or format, and missing or
#       contradictory annotations.
#   tool-contract-audit.sh lock <tools.json> [--out FILE] [--version SPEC]
#       Write a lockfile (default tools.lock.json): per-tool sha256, the set
#       hash, the full definitions, and the exact code pin you installed.
#   tool-contract-audit.sh diff <tools.json> [--lock FILE] [--version SPEC]
#       Compare against the lockfile and print the definition diff, labelled
#       BREAKING / WIDENING / REVIEW / CHANGE. The implementation row is always
#       UNDETERMINED: a definition hash cannot see server code.
#
# <tools.json> may be a tools/list JSON-RPC response, {"tools":[...]}, a bare
# array of tools, or a JSONL capture of several responses (pages are joined).
#
# --untrusted   ignore readOnlyHint and audit every tool as a write. MCP says
#               clients treat annotations as untrusted unless the server is.
#
# Exit: audit  0 no FAIL, 1 any FAIL, 2 usage/input error
#       diff   0 definitions and pins unchanged, 1 anything changed, 2 error
#       lock, capture  0 ok, 2 error
#
# Dependencies: bash 4+, jq 1.6+, coreutils (sha256sum, or shasum -a 256).

set -euo pipefail

usage() { sed -n '2,/^set -euo/p' "$0" | sed '$d' | sed 's/^# \{0,1\}//'; }
die() { printf 'error: %s\n' "$1" >&2; exit 2; }

command -v jq >/dev/null || die "jq required"

sha() {
  if command -v sha256sum >/dev/null; then sha256sum | cut -d' ' -f1
  elif command -v shasum >/dev/null; then shasum -a 256 | cut -d' ' -f1
  else die "sha256sum or shasum required"; fi
}

# ---------------------------------------------------------------------------
# Shared jq definitions
# ---------------------------------------------------------------------------
read -r -d '' LIB <<'JQ' || true
def one_doc:
  if type == "array" then .
  elif type == "object" and (.tools | type) == "array" then .tools
  elif type == "object" and (.result.tools | type) == "array" then .result.tools
  else error("no tools array found: expected a tools/list response, {\"tools\": [...]}, or [...]") end;

# Input is slurped (jq -s): one document, or a JSONL capture of several pages.
def tools_of:
  (if length == 1 then .[0] | one_doc
   else [ .[] | objects | (.result.tools // .tools // [])[] ] end) as $t
  | if ($t | length) == 0 then error("tools array is empty")
    elif ($t | all(.[]; type == "object" and (.name | type) == "string") | not)
      then error("every tool needs a string name")
    elif ($t | map(.name) | length) != ($t | map(.name) | unique | length)
      then error("duplicate tool names")
    else $t end;

def server_info_of:
  [ .[] | objects | (.serverInfo // .result.serverInfo // empty) ] | first // null;

def snake: gsub("(?<a>[a-z0-9])(?<b>[A-Z])"; "\(.a)_\(.b)") | ascii_downcase | gsub("[^a-z0-9]+"; "_");
def toks: snake | split("_") | map(select(length > 0));

def dest_words: ["recipient","recipients","url","urls","uri","uris","webhook","webhooks",
  "endpoint","endpoints","channel","channels","account","accounts","destination",
  "destinations","dest","payee","owner","email","emails","address","addresses","phone",
  "callback","redirect"];

# A parameter that chooses where data or money goes. Name heuristic.
def is_dest:
  snake as $n | toks as $t |
  if ($n | test("^(to|cc|bcc|reply_to)$")) then true
  elif ($t | length) == 0 then false
  elif ($t[-1] | IN(dest_words[])) then true
  elif ($t[-1] | IN("id","ids","address","addresses","email","url","number","handle"))
       and any($t[:-1][]; IN(dest_words[], "to", "cc", "bcc")) then true
  else false end;

def is_key: snake | test("idempoten|dedup|^(client_)?request_id$|^client_token$|^operation_id$");

def write_verbs: ["send","create","delete","remove","update","write","post","put","patch",
  "set","add","insert","upsert","publish","transfer","pay","move","merge","push","exec",
  "execute","deploy","cancel","approve","invite","share","upload","edit","modify","drop",
  "archive","close","submit","charge","refund","install","kill","rename","reset","revoke",
  "grant","assign","commit","forward","reply","notify"];
def read_verbs: ["get","list","read","search","find","fetch","query","describe","preview",
  "show","view","lookup","check","count","inspect","validate","diff","plan","dry"];

# Every property schema, depth-first, with its dotted path and requiredness.
def props($p):
  ((.required // []) as $req
   | (.properties // {}) | to_entries[]
   | (if $p == "" then .key else "\($p).\(.key)" end) as $path
   | {path: $path, name: .key, req: (.key | IN($req[])), schema: .value},
     (.value | objects | props($path))),
  ((.items? // empty) | objects | props("\($p)[]")),
  (((.anyOf // [])[], (.oneOf // [])[], (.allOf // [])[]) | objects | props($p));

# How constrained is each string-accepting branch of a schema?
def str_classes:
  if has("$ref") then "ref"
  elif (.anyOf // .oneOf) then (.anyOf // .oneOf)[] | objects | str_classes
  else
    ([.type] | flatten) as $tys
    | if any($tys[]; . == "array") then
        (if has("items") then (.items | objects | select(has("properties") | not) | str_classes)
         else "free" end)
      elif (.type == null) or any($tys[]; . == "string") then
        if has("enum") or has("const") then "allowlist"
        elif has("pattern") or has("format") then "shape"
        elif .type == null and has("properties") then empty
        else "free" end
      else empty end
  end;

def f($l; $c; $m): {level: $l, check: $c, msg: $m};

def audit_tool($untrusted):
  (.annotations // null) as $a
  | (.name | toks) as $nt
  | (first($nt[] | select(IN(write_verbs[], read_verbs[]))) // "" | IN(write_verbs[])) as $verbish
  | ($a != null and $a.readOnlyHint == true) as $ro
  | ((($ro | not) or $untrusted or $verbish)) as $write
  | [ (.inputSchema // {}) | props("") ] as $props
  | [ $props[] | select(.name | is_key) | .path ] as $keys
  | [ $props[] | select(.name | is_dest) ] as $dests
  | (((.inputSchema.properties // {}) | keys) == ["plan_id"]) as $planbound
  | { name: .name,
      write: $write,
      basis: (if $a == null then "no annotations"
              elif $ro and $verbish then "readOnlyHint true, overridden by name"
              elif $ro and $untrusted then "readOnlyHint true, ignored (--untrusted)"
              elif $ro then "readOnlyHint true"
              elif ($a | has("readOnlyHint")) then "readOnlyHint false"
              else "readOnlyHint absent" end),
      findings: (
        [ (if $a == null then f("WARN"; "annotations";
              "none declared; MCP defaults apply (readOnlyHint false, destructiveHint true, idempotentHint false, openWorldHint true)")
           else empty end),
          (if $ro and $verbish then f("WARN"; "annotations";
              "readOnlyHint is true but the name reads as a write; annotations are untrusted hints, audited as a write")
           else empty end) ]
        + (if $write | not then [] else
          [ (if ((.inputSchema // {}) | has("properties") or has("anyOf") or has("oneOf") or has("$ref") or .additionalProperties == false) | not
             then f("WARN"; "schema"; "inputSchema declares no properties and does not forbid extra ones: any arguments are accepted and nothing below can be checked")
             else empty end),
            (if ($keys | length) > 0 then f("PASS"; "idempotency";
                "key parameter: \($keys | join(", ")). A schema cannot show whether it is derived from the operation or minted per retry")
             elif $planbound then f("WARN"; "idempotency";
                "commit takes only plan_id; confirm the server makes each plan single-use, or a retried commit sends twice")
             elif ($a != null and $a.idempotentHint == true) then f("WARN"; "idempotency";
                "no key parameter; idempotentHint true is the server's claim, not enforcement")
             else f("FAIL"; "idempotency";
                "no idempotency-key parameter; a call that times out and is retried becomes a second effect")
             end),
            ( $dests[] | .path as $p | [ .schema | objects | str_classes ] as $c
              | if ($c | length) == 0 then empty
                elif any($c[]; . == "free") then f("FAIL"; "destination";
                  "`\($p)` is a free string: no enum, const, pattern, or format")
                elif any($c[]; . == "ref") then f("WARN"; "destination";
                  "`\($p)` uses $ref, not resolved here; check it by hand")
                elif any($c[]; . == "shape") then f("PASS"; "destination";
                  "`\($p)` is shape-checked (pattern/format). The schema cannot check it against your account data; the server must")
                else f("PASS"; "destination"; "`\($p)` is allowlisted (enum/const)") end ),
            ( $props[] | select(.name | snake == "bcc")
              | f("WARN"; "destination"; "`\(.path)` field: a recipient nobody on the To line sees") )
          ] end)
      ) };

# --- diff helpers ----------------------------------------------------------
def pstr: map(if type == "number" then "[\(.)]" else ".\(.)" end) | join("") | ltrimstr(".");
def short: tojson | if length > 72 then .[0:69] + "..." else . end;
def leafmap: [ tostream | select(length == 2) | {key: (.[0] | tojson), value: {path: .[0], v: .[1]}} ] | from_entries;
def propmap: [ (.inputSchema // {}) | props("") | {key: .path, value: .} ] | from_entries;
def c($l; $m): {label: $l, msg: $m};

def classify($o; $n):
  ($o | propmap) as $op | ($n | propmap) as $np
  | [ ( ($np | keys) - ($op | keys) | .[] | $np[.] as $x
        | if ($x.name | is_dest) then c("WIDENING"; "new destination field `\(.)`")
          elif $x.req then c("BREAKING"; "new required field `\(.)`")
          else c("CHANGE"; "new optional field `\(.)`") end ),
      ( ($op | keys) - ($np | keys) | .[] | c("BREAKING"; "field `\(.)` removed") ),
      ( ($op | keys) - (($op | keys) - ($np | keys)) | .[]
        | . as $k | $op[$k] as $a | $np[$k] as $b | ($a.schema // {}) as $os | ($b.schema // {}) as $ns
        | (if $a.req != $b.req then c("BREAKING"; "`\($k)` \(if $a.req then "required -> optional" else "optional -> required" end)") else empty end),
          (if ($os.type) != ($ns.type) then c("BREAKING"; "`\($k)` type \($os.type | short) -> \($ns.type | short)") else empty end),
          (if ($os | has("default")) != ($ns | has("default")) or $os.default != $ns.default
             then c("BREAKING"; "`\($k)` default \($os.default | short) -> \($ns.default | short): an omitted `\($k)` now means something else") else empty end),
          (if ($os | has("enum")) and ($ns | has("enum") | not) then c("WIDENING"; "constraint removed from `\($k)`: enum")
           elif ($os | has("enum")) then
             (($os.enum - $ns.enum) as $gone | ($ns.enum - $os.enum) as $new
              | (if ($gone | length) > 0 then c("BREAKING"; "enum value(s) removed from `\($k)`: \($gone | short)") else empty end),
                (if ($new | length) > 0 then c("WIDENING"; "enum value(s) added to `\($k)`: \($new | short)") else empty end))
           elif ($ns | has("enum")) then c("CHANGE"; "constraint added to `\($k)`: enum")
           else empty end),
          ( ("const","pattern","format","maxLength","minLength","maximum","minimum","maxItems") as $kw
            | if ($os | has($kw)) and ($ns | has($kw) | not) then c("WIDENING"; "constraint removed from `\($k)`: \($kw)")
              elif ($os | has($kw)) and $os[$kw] != $ns[$kw] then c("REVIEW"; "`\($k)` \($kw) \($os[$kw] | short) -> \($ns[$kw] | short); check whether it loosened")
              elif ($ns | has($kw)) and ($os | has($kw) | not) then c("CHANGE"; "constraint added to `\($k)`: \($kw)")
              else empty end ),
          (if $os.description != $ns.description then c("REVIEW"; "description of `\($k)` changed") else empty end) ),
      (if ($o.inputSchema.additionalProperties == false) and ($n.inputSchema.additionalProperties != false)
         then c("WIDENING"; "inputSchema.additionalProperties no longer false: undeclared arguments accepted") else empty end),
      (if $o.description != $n.description
         then c("REVIEW"; "tool description changed: this is the text the model reads (rug-pull surface)") else empty end),
      ( (($o.annotations // {}) | keys) + (($n.annotations // {}) | keys) | unique | .[]
        | select($o.annotations[.] != $n.annotations[.])
        | c("REVIEW"; "annotation \(.): \($o.annotations[.] | short) -> \($n.annotations[.] | short)") ),
      (if $o.outputSchema != $n.outputSchema then c("CHANGE"; "outputSchema changed") else empty end)
    ];

def leafdiff($o; $n):
  ($o | leafmap) as $a | ($n | leafmap) as $b
  | [ ($a | keys) + ($b | keys) | unique | .[] as $k
      | ($a | has($k)) as $ina | ($b | has($k)) as $inb
      | select($ina != $inb or $a[$k].v != $b[$k].v)
      | ($a[$k] // $b[$k]).path as $p
      | "\($p | pstr): \(if $ina then $a[$k].v | short else "(absent)" end) -> \(if $inb then $b[$k].v | short else "(absent)" end)" ];
JQ

load_tools() { # file -> normalized tools array on stdout
  [ -f "$1" ] || die "no such file: $1"
  jq -s "$LIB tools_of" "$1" 2>/dev/null || die "$1: $(jq -s "$LIB tools_of" "$1" 2>&1 >/dev/null | sed -e 's/^jq: error (at [^)]*): //' -e 's/^jq: error[^:]*: //' | head -1)"
}

# ---------------------------------------------------------------------------
# capture
# ---------------------------------------------------------------------------
cmd_capture() {
  local out="" timeout=30
  while [ "$#" -gt 0 ]; do
    case "$1" in
      --out) [ "$#" -ge 2 ] || die "--out needs a value"; out="$2"; shift 2 ;;
      --timeout) [ "$#" -ge 2 ] || die "--timeout needs a value"; timeout="$2"; shift 2 ;;
      --) shift; break ;;
      *) die "capture: expected -- before the server command (got '$1')" ;;
    esac
  done
  [ "$#" -gt 0 ] || die "capture: no server command after --"

  coproc SRV { "$@" 2>/dev/null; }
  CAP_PID=$SRV_PID
  local in_fd=${SRV[0]} out_fd=${SRV[1]}
  # shellcheck disable=SC2317
  cleanup() { kill "${CAP_PID:-}" 2>/dev/null || true; wait "${CAP_PID:-}" 2>/dev/null || true; }
  trap cleanup EXIT

  send() { printf '%s\n' "$1" >&"$out_fd"; }
  await() { # id -> the matching response line
    local line
    while IFS= read -r -t "$timeout" line <&"$in_fd"; do
      if jq -e --argjson id "$1" 'type == "object" and .id == $id' <<<"$line" >/dev/null 2>&1; then
        printf '%s' "$line"; return 0
      fi
    done
    return 1
  }

  send '{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2025-06-18","capabilities":{},"clientInfo":{"name":"tool-contract-audit","version":"1"}}}'
  local init; init=$(await 1) || die "capture: no initialize response (server exited, or nothing within ${timeout}s)"
  jq -e '.result' <<<"$init" >/dev/null || die "capture: initialize failed: $(jq -c '.error // "response had no result"' <<<"$init")"
  send '{"jsonrpc":"2.0","method":"notifications/initialized"}'

  local id=2 cursor="" resp all='[]'
  while :; do
    if [ -n "$cursor" ]; then
      send "$(jq -cn --argjson id "$id" --arg c "$cursor" '{jsonrpc:"2.0",id:$id,method:"tools/list",params:{cursor:$c}}')"
    else
      send "$(jq -cn --argjson id "$id" '{jsonrpc:"2.0",id:$id,method:"tools/list",params:{}}')"
    fi
    resp=$(await "$id") || die "capture: no tools/list response (server exited, or nothing within ${timeout}s)"
    jq -e '.result.tools | type == "array"' <<<"$resp" >/dev/null || die "capture: tools/list failed: $(jq -c '.error // "response had no tools array"' <<<"$resp")"
    all=$(jq -c --argjson r "$resp" '. + $r.result.tools' <<<"$all")
    cursor=$(jq -r '.result.nextCursor // empty' <<<"$resp")
    [ -n "$cursor" ] || break
    id=$((id + 1))
    [ "$id" -lt 200 ] || die "capture: more than 200 pages; stopping"
  done

  local doc
  doc=$(jq -n --argjson init "$init" --argjson tools "$all" \
    '{protocolVersion: $init.result.protocolVersion, serverInfo: ($init.result.serverInfo // null), tools: $tools}')
  if [ -n "$out" ]; then printf '%s\n' "$doc" > "$out"; printf 'captured %s tools to %s\n' "$(jq 'length' <<<"$all")" "$out" >&2
  else printf '%s\n' "$doc"; fi
}

# ---------------------------------------------------------------------------
# audit
# ---------------------------------------------------------------------------
cmd_audit() {
  local untrusted=false file=""
  while [ "$#" -gt 0 ]; do
    case "$1" in
      --untrusted) untrusted=true; shift ;;
      -*) die "audit: unknown argument '$1'" ;;
      *) [ -z "$file" ] || die "audit: more than one file"; file="$1"; shift ;;
    esac
  done
  [ -n "$file" ] || die "audit: no tools file"
  local tools; tools=$(load_tools "$file")

  local report
  report=$(jq -r --arg file "$file" --argjson untrusted "$untrusted" "$LIB"'
    [ .[] | audit_tool($untrusted) ] as $r
    | [ $r[] | select(.write) ] as $w
    | [ $r[] | select(.write | not) ] as $ro
    | [ $w[].findings[] ] as $all
    | ([ $all[] | select(.level == "FAIL") ] | length) as $nf
    | ([ $all[] | select(.level == "WARN") ] | length) as $nw
    | ([ $w[] | select(any(.findings[]; .check == "idempotency" and .level == "FAIL")) ] | length) as $nkey
    | ([ $w[].findings[] | select(.check == "destination" and .level == "FAIL") ] | length) as $ndest
    | ([ $w[] | select(any(.findings[]; .check == "idempotency" and (.msg | startswith("commit takes only plan_id")))) ] | length) as $nplan
    | "tool-contract-audit: \($file)",
      "\($r | length) tools: \($w | length) audited as writes, \($ro | length) read-only by annotation",
      "Heuristic: reads tool names, input schemas, and annotations only. Parameter roles are guessed from names.",
      "",
      ( $w[] | "\(.name)  [write: \(.basis)]",
               (.findings[] | "  \(.level)  \(.check | . + (" " * (13 - length)))\(.msg)"),
               "" ),
      (if ($ro | length) > 0 then
         "Read-only by annotation, not audited (an untrusted hint; --untrusted audits them): \($ro | map(.name) | join(", "))", ""
       else empty end),
      "Audit rows from the post:",
      "  1 derived idempotency key on writes   \(if ($w | length) == 0 then "no write tools audited" elif $nkey == 0 then "every write takes a key or a plan_id" else "\($nkey) write tool(s) with no key" end); derivation NOT VISIBLE",
      "  2 destinations constrained + checked  schema half: \($ndest) free-string destination(s); server-side business check NOT VISIBLE",
      "  3 failures as tool execution errors   NOT VISIBLE: send a bad call, expect isError true naming the fix",
      "  4 commit executes the preview         \($nplan) plan_id-only commit tool(s); plan binding NOT VISIBLE",
      "  5 pinned by code version + def hash   run lock, then diff on upgrade; implementation change UNDETERMINED",
      "  6 named owner + version               NOT VISIBLE: CODEOWNERS on the tool definitions",
      "",
      "Summary: \($nf) FAIL, \($nw) WARN",
      "EXIT \(if $nf > 0 then 1 else 0 end)"
  ' <<<"$tools") || die "audit: jq failed on $file"
  printf '%s\n' "$report" | sed '$d'
  [ "$(printf '%s\n' "$report" | tail -1)" = "EXIT 0" ]
}

# ---------------------------------------------------------------------------
# lock
# ---------------------------------------------------------------------------
tool_hashes() { # tools array -> {"name": "sha"} object
  jq -c '.[]' <<<"$1" | while IFS= read -r t; do
    printf '%s\t%s\n' "$(jq -r '.name' <<<"$t")" "$(jq -S -c '.' <<<"$t" | sha)"
  done | jq -R -s 'split("\n") | map(select(length > 0) | split("\t") | {key: .[0], value: .[1]}) | from_entries'
}

cmd_lock() {
  local file="" out="tools.lock.json" version=""
  while [ "$#" -gt 0 ]; do
    case "$1" in
      --out) [ "$#" -ge 2 ] || die "--out needs a value"; out="$2"; shift 2 ;;
      --version) [ "$#" -ge 2 ] || die "--version needs a value"; version="$2"; shift 2 ;;
      -*) die "lock: unknown argument '$1'" ;;
      *) [ -z "$file" ] || die "lock: more than one file"; file="$1"; shift ;;
    esac
  done
  [ -n "$file" ] || die "lock: no tools file"
  local tools hashes setsha info
  tools=$(load_tools "$file")
  hashes=$(tool_hashes "$tools")
  # Same bytes as the post's one-liner: jq -S '.tools' tools-list.json | sha256sum
  setsha=$(jq -S '.' <<<"$tools" | sha)
  info=$(jq -s "$LIB server_info_of" "$file")
  jq -n --argjson tools "$tools" --argjson h "$hashes" --arg set "$setsha" \
    --arg src "$file" --arg ver "$version" --argjson info "$info" \
    --arg now "$(date -u +%Y-%m-%dT%H:%M:%SZ)" '{
      tool_contract_lock: 1,
      created_utc: $now,
      source: $src,
      code_pin: (if $ver == "" then null else $ver end),
      server_info_self_reported: $info,
      set_sha256: $set,
      tools: ($tools | sort_by(.name) | map({name, sha256: $h[.name], definition: .}))
    }' > "$out"
  printf 'locked %s tools to %s (set sha256 %s)\n' "$(jq 'length' <<<"$tools")" "$out" "${setsha:0:12}"
  [ -n "$version" ] || printf 'no --version given: the code pin is not recorded, so diff cannot tell an upgrade happened\n'
}

# ---------------------------------------------------------------------------
# diff
# ---------------------------------------------------------------------------
cmd_diff() {
  local file="" lock="tools.lock.json" version=""
  while [ "$#" -gt 0 ]; do
    case "$1" in
      --lock) [ "$#" -ge 2 ] || die "--lock needs a value"; lock="$2"; shift 2 ;;
      --version) [ "$#" -ge 2 ] || die "--version needs a value"; version="$2"; shift 2 ;;
      -*) die "diff: unknown argument '$1'" ;;
      *) [ -z "$file" ] || die "diff: more than one file"; file="$1"; shift ;;
    esac
  done
  [ -n "$file" ] || die "diff: no tools file"
  [ -f "$lock" ] || die "no lockfile: $lock (run lock first)"
  jq -e '.tool_contract_lock == 1 and (.tools | type) == "array"' "$lock" >/dev/null 2>&1 || die "$lock is not a tool-contract-audit lockfile"
  local tools hashes setsha info
  tools=$(load_tools "$file")
  hashes=$(tool_hashes "$tools")
  setsha=$(jq -S '.' <<<"$tools" | sha)
  info=$(jq -s "$LIB server_info_of" "$file")

  local report
  report=$(jq -r -n --slurpfile L "$lock" --argjson new "$tools" --argjson h "$hashes" \
    --arg set "$setsha" --arg ver "$version" --argjson info "$info" \
    --arg file "$file" --arg lockf "$lock" "$LIB"'
    $L[0] as $lk
    | ($lk.tools | map({key: .name, value: .definition}) | from_entries) as $old
    | ($new | map({key: .name, value: .}) | from_entries) as $nw
    | (($nw | keys) - ($old | keys)) as $added
    | (($old | keys) - ($nw | keys)) as $removed
    | [ ($old | keys)[] | select($nw[.] != null and $old[.] != $nw[.]) ] as $changed
    | ([ $lk.tools[] | select($h[.name] != null and $h[.name] != .sha256 and $old[.name] == $nw[.name]) | .name ]) as $hashonly
    | (($added + $removed + $changed) | length > 0) as $defchg
    | ($lk.code_pin) as $oldpin
    | ($ver != "" and $oldpin != null and $ver != $oldpin) as $pinchg
    | ($info.version) as $iv | ($lk.server_info_self_reported.version) as $ov
    | ($iv != null and $ov != null and $iv != $ov) as $infochg
    | "tool-contract-audit diff: \($file) against \($lockf) (locked \($lk.created_utc))",
      (if $defchg then "Definitions: CHANGED (set sha256 \($lk.set_sha256[0:12]) -> \($set[0:12]))"
       else "Definitions: UNCHANGED (\($new | length) tools)" end),
      (if ($defchg | not) and $set != $lk.set_sha256 then "  note: set sha256 differs only by tool order (\($lk.set_sha256[0:12]) -> \($set[0:12])); per-tool definitions match" else empty end),
      ($hashonly[] | "  note: \(.) sha256 differs but definition is equal; lockfile hashed with a different jq number/key rendering"),
      ($added[] | "  + added tool \(.)  [REVIEW: a new capability the model can call]"),
      ($removed[] | "  - removed tool \(.)  [BREAKING]"),
      ( $changed[] | . as $n
        | "  ~ changed tool \($n)",
          ( classify($old[$n]; $nw[$n])[] | "      \(.label + (" " * (10 - (.label | length))))\(.msg)" ),
          "      definition diff:",
          ( leafdiff($old[$n]; $nw[$n])[] | "        \(.)" ) ),
      "",
      (if $ver == "" and $oldpin == null then "Code pin: not recorded (lock and diff with --version SPEC, the exact package@version installed)"
       elif $ver == "" then "Code pin: locked \($oldpin); not checked (pass --version with the spec now installed)"
       elif $oldpin == null then "Code pin: now \($ver); none recorded in the lockfile"
       elif $pinchg then "Code pin: CHANGED \($oldpin) -> \($ver)"
       else "Code pin: unchanged (\($ver))" end),
      (if $infochg then "Server self-reported version: CHANGED \($ov) -> \($iv)"
       elif $iv != null then "Server self-reported version: \($iv) (self-reported, not a pin)"
       else empty end),
      "Implementation: UNDETERMINED. A definition hash cannot see server code or behavior behind an unchanged definition (OWASP); postmark-mcp 1.0.16 added its BCC in the send path. Only an exact code pin and a re-run of the tool evals before upgrading cover it.",
      (if ($defchg | not) and ($pinchg or $infochg) then "The version moved and the definitions did not: this is the case a hash misses. Re-run the tool evals before accepting." else empty end),
      "EXIT \(if $defchg or $pinchg or $infochg then 1 else 0 end)"
  ') || die "diff: jq failed on $file"
  printf '%s\n' "$report" | sed '$d'
  [ "$(printf '%s\n' "$report" | tail -1)" = "EXIT 0" ]
}

# ---------------------------------------------------------------------------
[ "$#" -gt 0 ] || { usage >&2; exit 2; }
sub="$1"; shift
case "$sub" in
  capture) cmd_capture "$@" ;;
  audit) cmd_audit "$@" ;;
  lock) cmd_lock "$@" ;;
  diff) cmd_diff "$@" ;;
  -h|--help|help) usage ;;
  *) die "unknown command '$sub' (capture, audit, lock, diff; see --help)" ;;
esac
