#!/usr/bin/env bash
# sandbox-substrate-picker.sh: route a parallel coding-agent fleet to a
# sandbox rung, then price it at your real concurrency.
#
# From "A Sandbox for AI Coding Agents at Scale Is a Warm-State Problem"
# https://jyoung.dev/blog/sandbox-parallel-coding-agents/
#
# Walks the post's six questions in its order (setup, trusted on one machine,
# unattended or untrusted, setup over budget, shared dependencies, credentials
# or network) and prints the controls each yes adds. Unless the walk stops at
# the worktree rung, it then prices one session-hour and the whole run per
# vendor plan from a dated rates file, and flags every plan whose concurrency
# cap or session-length limit binds at your session count.
#
# Usage:
#   sandbox-substrate-picker.sh --sessions N --trust LEVEL [options]
#
# Required:
#   --sessions N          sessions running at once
#   --trust LEVEL         trusted | unattended | untrusted
#
# Options:
#   --machine M           one | many: where the sessions run (default many)
#   --vcpu N              vCPU per session (default 2)
#   --gib N               GiB of memory per session (default 4)
#   --hours H             wall-clock hours each session is up (default 8)
#   --active-hours H      hours each session is doing work (default = --hours)
#   --setup-min M         measured minutes from sandbox start to first useful
#                         action (clone, install, warm build); see time-setup.sh
#   --boot-sec S          measured boot seconds (default 0.125, Firecracker's
#                         specified bound; replace with yours)
#   --setup-budget M      session-minutes of fleet setup you accept (question 4)
#   --shared-deps yes|no  sessions install the same dependency tree (question 5)
#   --network yes|no      sessions need credentials or network (question 6)
#   --rates FILE          rates file (default: rates.json next to this script)
#   -h, --help
#
# Numbers are estimates from published list rates on the date in the rates
# file. They exclude disk, plan fees, credits, transfer and the other charges
# the rates file names. Nothing is launched, billed, or edited.
#
# Exit: 0 ok, 2 usage or environment error.
# Dependencies: bash, jq, awk, coreutils.

set -euo pipefail

usage() { sed -n '2,42p' "$0" | sed 's/^# \{0,1\}//'; }
die() { printf 'sandbox-substrate-picker: %s\n' "$1" >&2; exit 2; }

HERE=$(cd "$(dirname "$0")" && pwd)
SESSIONS="" TRUST="" MACHINE=many VCPU=2 GIB=4 HOURS=8 ACTIVE="" SETUP="" BOOT=0.125
BOOT_SET=no BUDGET="" DEPS="" NET="" RATES="$HERE/rates.json"

need() { [ "$#" -ge 2 ] && [ -n "$2" ] || die "$1 needs a value"; }
while [ "$#" -gt 0 ]; do
  case "$1" in
    --sessions) need "$@"; SESSIONS="$2"; shift 2 ;;
    --trust) need "$@"; TRUST="$2"; shift 2 ;;
    --machine) need "$@"; MACHINE="$2"; shift 2 ;;
    --vcpu) need "$@"; VCPU="$2"; shift 2 ;;
    --gib) need "$@"; GIB="$2"; shift 2 ;;
    --hours) need "$@"; HOURS="$2"; shift 2 ;;
    --active-hours) need "$@"; ACTIVE="$2"; shift 2 ;;
    --setup-min) need "$@"; SETUP="$2"; shift 2 ;;
    --boot-sec) need "$@"; BOOT="$2"; BOOT_SET=yes; shift 2 ;;
    --setup-budget) need "$@"; BUDGET="$2"; shift 2 ;;
    --shared-deps) need "$@"; DEPS="$2"; shift 2 ;;
    --network) need "$@"; NET="$2"; shift 2 ;;
    --rates) need "$@"; RATES="$2"; shift 2 ;;
    -h|--help) usage; exit 0 ;;
    *) die "unknown option: $1 (see --help)" ;;
  esac
done

num() { [[ "$2" =~ ^[0-9]+([.][0-9]+)?$ ]] || die "$1 must be a non-negative number, got '$2'"; }
pos() { num "$1" "$2"; awk -v v="$2" 'BEGIN{exit !(v>0)}' || die "$1 must be greater than 0"; }

[ -n "$SESSIONS" ] || die "--sessions is required (see --help)"
[[ "$SESSIONS" =~ ^[1-9][0-9]*$ ]] || die "--sessions must be a whole number above 0"
case "$TRUST" in trusted|unattended|untrusted) ;; "") die "--trust is required: trusted, unattended or untrusted" ;; *) die "--trust must be trusted, unattended or untrusted" ;; esac
case "$MACHINE" in one|many) ;; *) die "--machine must be one or many" ;; esac
pos --vcpu "$VCPU"; pos --gib "$GIB"; pos --hours "$HOURS"
[ -n "$ACTIVE" ] || ACTIVE="$HOURS"
num --active-hours "$ACTIVE"
awk -v a="$ACTIVE" -v h="$HOURS" 'BEGIN{exit !(a<=h)}' || die "--active-hours cannot exceed --hours"
[ -z "$SETUP" ] || num --setup-min "$SETUP"
pos --boot-sec "$BOOT"
[ -z "$BUDGET" ] || num --setup-budget "$BUDGET"
case "$DEPS" in ""|yes|no) ;; *) die "--shared-deps must be yes or no" ;; esac
case "$NET" in ""|yes|no) ;; *) die "--network must be yes or no" ;; esac
command -v jq >/dev/null || die "jq is required"
[ -r "$RATES" ] || die "cannot read rates file: $RATES"
jq -e '.fetched and (.vendors|length>0)' "$RATES" >/dev/null 2>&1 || die "rates file needs .fetched and .vendors: $RATES"
FETCHED=$(jq -r '.fetched' "$RATES")

# ---- Route: the post's six questions, in the post's order ----------------
echo "sandbox-substrate-picker"
echo "Fleet: $SESSIONS sessions, $VCPU vCPU / $GIB GiB each, ${HOURS} h up, ${ACTIVE} h active, trust=$TRUST, machine=$MACHINE"
echo
echo "Route (the order is the post author's synthesis; no source prescribes it)"

FLEET_SETUP=""
if [ -n "$SETUP" ]; then
  read -r FLEET_SETUP DOMINATES BOOT_PCT < <(awk -v s="$SETUP" -v b="$BOOT" -v n="$SESSIONS" 'BEGIN{
    ss=s*60; printf "%.1f %s %.2f\n", s*n, (ss>b ? "yes" : "no"), 100*b/(b+ss) }')
  bootsrc=$([ "$BOOT_SET" = yes ] && echo "measured" || echo "Firecracker spec bound")
  printf ' 1. Setup dominates time to first action?  %s\n' "$DOMINATES"
  printf '    setup %s min vs boot %s s (%s); boot is %s%% of time to first action\n' "$SETUP" "$BOOT" "$bootsrc" "$BOOT_PCT"
  printf '    fleet pays %s session-minutes of setup before any session acts\n' "$FLEET_SETUP"
  if [ "$DOMINATES" = yes ]; then
    echo '    -> Defer provisioning until a session needs a sandbox.'
    DEFER=yes
  fi
else
  echo ' 1. Setup dominates time to first action?  unmeasured'
  echo '    Time clone, install and warm build inside a fresh sandbox on each candidate'
  echo '    (time-setup.sh does this), then pass --setup-min.'
fi

if [ "$TRUST" = trusted ] && [ "$MACHINE" = one ]; then
  echo ' 2. Trusted sessions on one machine?       yes'
  echo '    -> Worktree per session plus a prebuilt devcontainer image. Stop.'
  echo '       A worktree isolates files only. Give each session its own port range and'
  echo '       its own database or schema, budget memory per session tree, and rebuild the'
  echo '       image once per dependency change, not once per session.'
  echo
  echo "Rung: worktree per session + prebuilt devcontainer (trusted, one machine)."
  echo "Pricing skipped: this rung runs on your own machine, so the ceiling is its memory,"
  echo "not a vendor plan. If any session will run unattended or read untrusted input,"
  echo "rerun with --trust unattended or untrusted."
  exit 0
fi
echo ' 2. Trusted sessions on one machine?       no'

CONTROLS=()
[ "${DEFER:-no}" = no ] || CONTROLS+=("deferred provisioning")
if [ "$TRUST" = trusted ]; then
  echo ' 3. Unattended or untrusted input?         no'
else
  echo ' 3. Unattended or untrusted input?         yes'
  echo '    -> Per-session kernel (microVM, or gVisor). Before the run, get answers to:'
  echo '       own kernel per session; engine version pinned and lag behind upstream;'
  echo '       what runs when no runtime is named; egress default; overhead on your own'
  echo '       build and test loop (measure gVisor on its current platform).'
  CONTROLS+=("per-session kernel with an audited pin, default runtime and egress default")
fi

if [ -z "$FLEET_SETUP" ]; then
  echo " 4. Setup over budget at $SESSIONS sessions?      unanswered (needs --setup-min and --setup-budget)"
  echo '    If yes: warm snapshot, fork, re-mint identity in the run hook.'
elif [ -z "$BUDGET" ]; then
  echo " 4. Setup over budget at $SESSIONS sessions?      unanswered: $FLEET_SETUP session-min, no --setup-budget given"
  echo '    If yes: warm snapshot, fork, re-mint identity in the run hook.'
elif awk -v f="$FLEET_SETUP" -v b="$BUDGET" 'BEGIN{exit !(f>b)}'; then
  echo " 4. Setup over budget at $SESSIONS sessions?      yes ($FLEET_SETUP > $BUDGET session-min)"
  echo '    -> Build the warm state once, snapshot it, fork every session from it.'
  echo '       Re-mint IDs, nonces, entropy and tokens after restore (in the run hook,'
  echo '       never at image build), give each clone its own branch, and time the'
  echo '       first minutes after restore, not only the restore call.'
  CONTROLS+=("warm snapshot + fork, identity re-minted after restore")
else
  echo " 4. Setup over budget at $SESSIONS sessions?      no ($FLEET_SETUP <= $BUDGET session-min)"
fi

case "$DEPS" in
  yes) echo ' 5. Sessions share dependencies?           yes'
       echo '    -> Read-only shared layer built by a trusted job, plus a private writable'
       echo '       layer per session. Never one writable cache mounted into every session.'
       CONTROLS+=("read-only shared dependency layer + private writable layer") ;;
  no)  echo ' 5. Sessions share dependencies?           no' ;;
  *)   echo ' 5. Sessions share dependencies?           unanswered (--shared-deps yes|no)' ;;
esac

case "$NET" in
  yes) echo ' 6. Sessions need credentials or network?  yes'
       echo '    -> Credentials in a proxy outside the sandbox, egress denied by default.'
       echo '       Treat every allowlisted domain (the package registry included) as a'
       echo '       capability you granted, and set time and token budgets under the'
       echo '       policy you actually enforce.'
       CONTROLS+=("credential proxy outside the sandbox, default-deny egress") ;;
  no)  echo ' 6. Sessions need credentials or network?  no' ;;
  *)   echo ' 6. Sessions need credentials or network?  unanswered (--network yes|no)' ;;
esac

echo
if [ "${#CONTROLS[@]}" -eq 0 ]; then
  echo "Rung: hosted or self-hosted sandbox with no added controls from the answered questions."
else
  echo "Rung: $(IFS=';'; echo "${CONTROLS[*]}" | sed 's/;/; /g')."
fi
echo "This tool does not rate any vendor's isolation; the kernel questions apply to whichever you pick."

# ---- Price: per session-hour at your real concurrency ---------------------
echo
echo "Price at $SESSIONS concurrent sessions (list rates fetched $FETCHED, estimates)"

jq -r '
  .vendors[] as $v
  | ($v.rate_period | if . == "hour" then 3600 else 1 end) as $div
  | $v.plans[]
  | [ $v.name, .name,
      ($v.cpu_rate / $div), ($v.mem_rate / $div),
      $v.vcpu_per_unit, $v.min_units, $v.min_gib,
      $v.cpu_billing, $v.cap_kind,
      (.max_sessions // ""), (.pool_vcpu // ""), (.pool_gib // ""),
      (.max_session_hours // ""),
      ($v.instance_max_vcpu // ""), ($v.instance_max_gib // ""),
      .fee ]
  | map(tostring) | join("\t")' "$RATES" |
awk -F'\t' -v n="$SESSIONS" -v vcpu="$VCPU" -v gib="$GIB" -v hrs="$HOURS" -v act="$ACTIVE" '
function ceil(x) { return (x == int(x)) ? x : int(x) + 1 }
function floor(x) { return int(x) }
BEGIN {
  printf "%-20s %-12s %10s %11s %11s %12s  %s\n", "Vendor", "Plan", "$/sess-h", "Run, up", "Run, active", "Runs at once", "Status"
}
{
  vend=$1; plan=$2; cps=$3+0; mps=$4+0; vpu=$5+0; minu=$6+0; ming=$7+0
  cpub=$8; kind=$9; maxs=$10; pv=$11; pg=$12; maxh=$13; ivc=$14; ig=$15; fee=$16

  units = vcpu / vpu; if (units < minu) units = minu
  g = gib; if (g < ming) g = ming
  cpu_h = units * cps * 3600; mem_h = g * mps * 3600
  rate = cpu_h + mem_h
  # Up: billed for every hour the sandbox runs. Cloudflare CPU bills on active
  # use only, so its CPU term uses active hours at full use (an upper bound).
  cpu_up_h = (cpub == "active") ? act : hrs
  run_up = n * (cpu_h * cpu_up_h + mem_h * hrs)
  run_act = n * rate * act
  ub = (cpub == "active") ? "<=" : ""

  status = ""; fit = n
  if (kind == "sessions" && maxs != "") fit = maxs + 0
  else if (kind == "pool") {
    a = floor((pv + 0) / vcpu); b = floor((pg + 0) / gib); fit = (a < b) ? a : b
  }
  if (ivc != "" && (vcpu > ivc + 0 || gib > ig + 0)) {
    status = "BINDS: per-instance max " ivc " vCPU / " ig " GiB"; fit = 0
  }
  if (status == "" && kind == "unpublished") {
    status = "cap unpublished: account memory quota, check Service Quotas"; fitshow = "?"
  } else {
    if (fit > n) fit = n
    fitshow = fit
    if (status == "" && fit < n) {
      if (fit == 0) status = "BINDS: one session does not fit the pool"
      else status = sprintf("BINDS: %d queue, ~%d waves, ~%g h wall", n - fit, ceil(n / fit), ceil(n / fit) * hrs)
    }
  }
  if (maxh != "" && hrs > maxh + 0) status = status (status == "" ? "" : "; ") "BINDS: sessions capped at " maxh " h"
  if (status == "") { status = "fits"; fits[vend] = 1 }
  if (status == "fits") {
    if (!(vend in best) || run_up < bestrun[vend]) { best[vend] = plan; bestrun[vend] = run_up; bestfee[vend] = fee }
  }
  if (!(vend in seen)) { order[++nv] = vend; seen[vend] = 1 }

  printf "%-20s %-12s %10s %11s %11s %12s  %s\n", vend, plan, sprintf("%s$%.3f", ub, rate), sprintf("%s$%.0f", ub, run_up), sprintf("%s$%.0f", ub, run_act), fitshow, status
}
END {
  print ""
  print "Lowest-tier plan per vendor that runs every session at once:"
  lo = -1; hi = -1
  for (i = 1; i <= nv; i++) {
    v = order[i]
    if (v in best) {
      printf "  %-20s %-12s ~$%.0f usage (plan: %s)\n", v, best[v], bestrun[v], bestfee[v]
      if (lo < 0 || bestrun[v] < lo) lo = bestrun[v]
      if (hi < 0 || bestrun[v] > hi) hi = bestrun[v]
    } else printf "  %-20s no plan confirmed to fit (cap binds or is unpublished)\n", v
  }
  if (lo >= 0) printf "Usage spread across those: ~$%.0f to ~$%.0f. If that spread is small, the cap column decides the run.\n", lo, hi
}'

cat <<EOF

How to read this:
  \$/sess-h     one session for one hour at your vCPU and GiB.
  Run, up      every session billed for all ${HOURS} h it is up. "<=" marks Cloudflare,
               whose CPU bills on active use only; its CPU term assumes full use in
               every active hour, so its figures are upper bounds.
  Run, active  billed only for the ${ACTIVE} active hours. That is the real bill only if
               the sandbox stops billing while it waits (suspend, pause or stop); check
               how your vendor does that and what resume costs. An unattended batch is
               mostly active: price it on active hours. Price an interactive fleet on
               its suspend behavior.
  Runs at once sessions the plan runs concurrently at your size; the rest queue.
EOF
echo
echo "Excluded (from the rates file): $(jq -r '.note' "$RATES" | sed 's/ Recheck.*//')"
CAVEATS=$(jq -r '.vendors[] | select((.cap_note // "") != "") | "  \(.name): \(.cap_note)"' "$RATES")
[ -z "$CAVEATS" ] || printf 'Per-vendor caveats:\n%s\n' "$CAVEATS"
echo "Sources:"
jq -r '.vendors[] | "  \(.name): \(.sources | join(" "))"' "$RATES"
