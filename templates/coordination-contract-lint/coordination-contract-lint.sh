#!/usr/bin/env bash
# coordination-contract-lint.sh: validate a JSON handoff contract against the
# schema from "Coordination Is an Architecture Layer, Not a Prompt Instruction"
# https://jyoung.dev/blog/multi-agent-coordination-layer/
#
# The post's thesis: coordination logic buried in each agent's prompt cannot be
# tested. A shared contract file can be, mechanically, in CI, the way you'd lint
# any other interface. This is that lint.
#
# Schema and promotion guards are adapted from Kate Johnson's handoff contract
# (dev.to/kgjohnson/a-small-handoff-contract-for-multiple-coding-agents-4538),
# as quoted in the post, plus the post's own promotion-guard example:
#
#   verifying -> done   requires  verification[] non-empty
#                                 every recorded command exited 0
#                                 files_changed subset of ownership.files
#   waiting   -> done   requires  approval_gates.external_action.status == approved
#
# Usage: coordination-contract-lint.sh <contract.json>
# Exit:  0 = schema valid (warnings allowed)
#        1 = schema violation (missing/malformed required field, bad state,
#            or a done/verifying contract that fails its own promotion guard)
#        2 = usage error (bad args, file missing, not valid JSON)
#
# Zero dependencies beyond coreutils + jq. JSON only: a YAML contract would
# need yq, which this script does not assume is installed.

set -euo pipefail

usage() {
  echo "usage: $(basename "$0") <contract.json>" >&2
  exit 2
}

[[ $# -eq 1 ]] || usage
contract="$1"
[[ -f "$contract" ]] || { echo "error: not a file: $contract" >&2; exit 2; }

command -v jq >/dev/null 2>&1 || { echo "error: jq is required" >&2; exit 2; }

if ! jq empty "$contract" >/dev/null 2>&1; then
  echo "Coordination contract lint: $contract"
  echo "FAIL  Not valid JSON: $(jq empty "$contract" 2>&1 | head -1)"
  echo
  echo "Result: FAIL, malformed JSON, nothing else was checked"
  exit 1
fi

echo "Coordination contract lint: $contract"
echo "Schema: https://jyoung.dev/blog/multi-agent-coordination-layer/"
echo

fail=0
warn=0

fail_msg() { printf 'FAIL  %s\n' "$1"; fail=$((fail + 1)); }
warn_msg() { printf 'WARN  %s\n' "$1"; warn=$((warn + 1)); }
pass_msg() { printf 'PASS  %s\n' "$1"; }

jqr() { jq -r "$1" "$contract" 2>/dev/null; } # raw
jqv() { jq "$1" "$contract" 2>/dev/null; }    # untouched value/type

# ---- 1. top-level shape -------------------------------------------------------

top_type="$(jqr 'type')"
if [[ "$top_type" != "object" ]]; then
  fail_msg "Contract root: must be a JSON object, found $top_type"
  echo
  echo "Result: FAIL, $fail schema violation(s)"
  exit 1
fi

# ---- 2. required fields present and non-null ----------------------------------
# The post's required set: objective, ownership, observations, mutations,
# verification, approval_gates, plus state (checked separately for its enum).

required=(objective ownership state observations mutations verification approval_gates)
for f in "${required[@]}"; do
  present="$(jqr "has(\"$f\")")"
  if [[ "$present" != "true" ]]; then
    fail_msg "$f: missing"
    continue
  fi
  val_type="$(jqr ".$f | type")"
  if [[ "$val_type" == "null" ]]; then
    fail_msg "$f: present but null"
  fi
done

if ((fail > 0)); then
  echo
  echo "Result: FAIL, $fail required field(s) missing or null"
  echo "Required: objective, ownership, state, observations, mutations, verification, approval_gates"
  exit 1
fi

# ---- 3. state enum -------------------------------------------------------------
# The post's five states: reading, editing, verifying, waiting, done.

state="$(jqr '.state')"
case "$state" in
  reading|editing|verifying|waiting|done)
    pass_msg "state: \"$state\" (valid)" ;;
  *)
    fail_msg "state: \"$state\" is not one of reading/editing/verifying/waiting/done" ;;
esac

# ---- 4. objective ---------------------------------------------------------------

objective="$(jqr '.objective')"
obj_type="$(jqr '.objective | type')"
if [[ "$obj_type" != "string" ]]; then
  fail_msg "objective: must be a string, found $obj_type"
elif [[ -z "${objective// /}" ]]; then
  fail_msg "objective: empty string"
else
  pass_msg "objective: present"
fi

# ---- 5. ownership ----------------------------------------------------------------
# Required: ownership.agent (non-empty string), ownership.files (non-empty array).

own_type="$(jqr '.ownership | type')"
if [[ "$own_type" != "object" ]]; then
  fail_msg "ownership: must be an object, found $own_type"
else
  agent_type="$(jqr '.ownership.agent | type')"
  if [[ "$agent_type" != "string" || -z "$(jqr '.ownership.agent')" ]]; then
    fail_msg "ownership.agent: missing or not a non-empty string"
  else
    pass_msg "ownership.agent: $(jqr '.ownership.agent')"
  fi

  files_type="$(jqr '.ownership.files | type')"
  if [[ "$files_type" != "array" ]]; then
    fail_msg "ownership.files: missing or not an array"
  else
    files_len="$(jqr '.ownership.files | length')"
    if [[ "$files_len" -eq 0 ]]; then
      fail_msg "ownership.files: empty array. A task with no owned files has no reviewable boundary."
    else
      pass_msg "ownership.files: $files_len file(s)"
    fi
  fi

  if jqr '.ownership | has("lease_expires")' | grep -q true; then
    lease="$(jqr '.ownership.lease_expires')"
    if ! date -d "$lease" >/dev/null 2>&1 && ! [[ "$lease" =~ ^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2} ]]; then
      warn_msg "ownership.lease_expires: \"$lease\" does not look like an ISO 8601 timestamp"
    fi
  else
    warn_msg "ownership.lease_expires: absent. Without it a stale claim on these files never expires."
  fi
fi

# ---- 6. observations / mutations -------------------------------------------------
# Arrays of prose strings. Empty is legitimate early in the task (reading state);
# empty later is a signal, not a schema break, so this is a WARN not a FAIL.

for f in observations mutations; do
  t="$(jqr ".$f | type")"
  if [[ "$t" != "array" ]]; then
    fail_msg "$f: must be an array, found $t"
    continue
  fi
  len="$(jqr ".$f | length")"
  pass_msg "$f: $len entr$([[ $len == 1 ]] && echo y || echo ies)"
  if [[ "$len" -eq 0 && "$f" == "mutations" && "$state" != "reading" ]]; then
    warn_msg "mutations: empty while state is \"$state\". Expected at least one recorded change past the reading state."
  fi
done

# ---- 7. verification -------------------------------------------------------------
# Array of {command, result}. The post's promotion guard requires this non-empty
# before a task reaches done: "verifying -> done requires verification[] non-empty".

ver_type="$(jqr '.verification | type')"
if [[ "$ver_type" != "array" ]]; then
  fail_msg "verification: must be an array, found $ver_type"
else
  ver_len="$(jqr '.verification | length')"
  bad_entries="$(jqv '[.verification[] | select(((.command? // "") | type != "string") or ((.command? // "") == "") or ((.result? // "") | type != "string") or ((.result? // "") == "")) ] | length' 2>/dev/null || echo 0)"
  if [[ "$bad_entries" -gt 0 ]]; then
    fail_msg "verification: $bad_entries entr$([[ $bad_entries == 1 ]] && echo y || echo ies) missing a non-empty command or result"
  elif [[ "$ver_len" -gt 0 ]]; then
    pass_msg "verification: $ver_len entr$([[ $ver_len == 1 ]] && echo y || echo ies), all carry command + result"
  fi

  fail_hits="$(jqr '[.verification[]?.result? // "" | select(test("fail|error|fixme"; "i"))] | length' 2>/dev/null || echo 0)"
  if [[ "$fail_hits" -gt 0 ]]; then
    warn_msg "verification: $fail_hits result(s) contain fail/error/fixme text. Confirm those commands actually exited 0 before trusting this record."
  fi

  if [[ "$state" == "done" && "$ver_len" -eq 0 ]]; then
    fail_msg "verification: empty, but state is \"done\". Promotion guard: verifying -> done requires verification[] non-empty."
  fi
fi

# ---- 8. approval_gates -------------------------------------------------------------
# Object of named gates, each with a status. Empty object means no external action
# is gated, which is valid. The post's guard: waiting -> done requires the gate's
# status == approved; this script generalizes that to every gate present.

gates_type="$(jqr '.approval_gates | type')"
if [[ "$gates_type" != "object" ]]; then
  fail_msg "approval_gates: must be an object, found $gates_type (use {} if nothing is gated)"
else
  gate_names="$(jqr '.approval_gates | keys | join(",")')"
  if [[ -z "$gate_names" ]]; then
    pass_msg "approval_gates: none (no external action gated)"
  else
    pass_msg "approval_gates: $gate_names"
    missing_status="$(jqr '[.approval_gates | to_entries[] | select((.value.status? // "" ) == "")] | length' 2>/dev/null || echo 0)"
    if [[ "$missing_status" -gt 0 ]]; then
      fail_msg "approval_gates: $missing_status gate(s) missing a status field"
    fi
    if [[ "$state" == "done" ]]; then
      unapproved="$(jqr '[.approval_gates | to_entries[] | select(.value.status? != "approved")] | map(.key) | join(",")' 2>/dev/null || echo "")"
      if [[ -n "$unapproved" ]]; then
        fail_msg "approval_gates: state is \"done\" but not approved: $unapproved. Promotion guard: waiting -> done requires approval_gates.<gate>.status == approved."
      fi
    fi
  fi
fi

# ---- 9. recommended-but-not-required fields (Kate Johnson's fuller field list) ------
# task, timestamp, open_risks, next_action are in the post's quoted contract but
# outside this script's required set. Absence is a WARN, not a FAIL.

for f in task timestamp open_risks next_action; do
  present="$(jqr "has(\"$f\")")"
  if [[ "$present" != "true" ]]; then
    warn_msg "$f: absent. Recommended field from the full contract (Kate Johnson's schema), not required by this lint."
  fi
done

# ---- result -----------------------------------------------------------------------

echo
if ((fail > 0)); then
  echo "Result: FAIL, $fail schema violation(s), $warn warning(s)"
  exit 1
elif ((warn > 0)); then
  echo "Result: PASS with $warn warning(s)"
  exit 0
else
  echo "Result: PASS"
  exit 0
fi
