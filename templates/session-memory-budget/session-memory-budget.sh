#!/usr/bin/env bash
# session-memory-budget.sh: how many Claude Code sessions fit on this machine.
#
# From "Claude Code Memory Usage: How Many Sessions Fit on One Machine"
# https://jyoung.dev/blog/claude-code-parallel-sessions-memory/
#
# Walks every running `claude` process tree (a claude process whose parent is
# not claude; teammates count inside their lead's tree), sums RSS and PSS from
# /proc/<pid>/smaps_rollup, splits the tree into claude, MCP children, and tool
# shells, counts npm exec wrappers, flags MCP servers running once per session,
# and prints:
#
#   max parallel sessions = (ceiling - headroom) / peak tree PSS per session
#
# Nothing is killed, launched, or edited. Linux and WSL only (needs /proc).
#
# Usage:
#   session-memory-budget.sh [options]
#
# Options:
#   --samples N        take N samples and keep each session's peak (default 1)
#   --interval SECS    seconds between samples (default 300, the post's cadence)
#   --pid PID          measure only this claude session root (repeatable)
#   --ceiling SIZE     memory ceiling; default auto: the lowest cgroup
#                      memory.max above the sessions, else MemTotal (on WSL2
#                      that is the VM size .wslconfig sets)
#   --headroom PCT     share of the ceiling held back (default 25)
#   --per-session SIZE use this per-session peak instead of the measured one,
#                      e.g. your highest memory.peak or CI run.peak
#   --fence SIZE       per-session MemoryMax, prints the fenced count too
#                      (default: read from the sessions' own scopes if fenced)
#
# SIZE is MB (659), or takes a K, M, G suffix (6G).
# With --per-session and no running sessions it works as a plain calculator.
#
# Exit: 0 ok, 1 no claude sessions found, 2 usage or environment error.
# Dependencies: bash, awk, ps (procps), coreutils.

set -euo pipefail

usage() { sed -n '2,36p' "$0" | sed 's/^# \{0,1\}//'; }
die() { printf 'session-memory-budget: %s\n' "$1" >&2; exit 2; }

SAMPLES=1 INTERVAL=300 PIDS="" CEILING="" HEADROOM=25 PER_SESSION="" FENCE=""

to_mb() {
  local v=$1 n u
  [[ "$v" =~ ^([0-9]+)([KkMmGg]?)[Bb]?$ ]] || return 1
  n=${BASH_REMATCH[1]} u=${BASH_REMATCH[2]}
  case "$u" in
    K|k) echo $((n / 1024)) ;;
    G|g) echo $((n * 1024)) ;;
    *) echo "$n" ;;
  esac
}

need() { [ "$#" -ge 2 ] && [ -n "$2" ] || die "$1 needs a value"; }
while [ "$#" -gt 0 ]; do
  case "$1" in
    --samples) need "$@"; SAMPLES="$2"; shift 2 ;;
    --interval) need "$@"; INTERVAL="$2"; shift 2 ;;
    --pid) need "$@"; PIDS="$PIDS $2"; shift 2 ;;
    --ceiling) need "$@"; CEILING=$(to_mb "$2") || die "bad --ceiling '$2'"; shift 2 ;;
    --headroom) need "$@"; HEADROOM="$2"; shift 2 ;;
    --per-session) need "$@"; PER_SESSION=$(to_mb "$2") || die "bad --per-session '$2'"; shift 2 ;;
    --fence) need "$@"; FENCE=$(to_mb "$2") || die "bad --fence '$2'"; shift 2 ;;
    -h|--help) usage; exit 0 ;;
    *) die "unknown argument $1 (see --help)" ;;
  esac
done

[[ "$SAMPLES" =~ ^[1-9][0-9]*$ ]] || die "--samples must be a positive integer"
[[ "$INTERVAL" =~ ^[0-9]+$ ]] || die "--interval must be whole seconds"
[[ "$HEADROOM" =~ ^[0-9]+$ ]] && [ "$HEADROOM" -lt 100 ] || die "--headroom must be 0-99"
for p in $PIDS; do [[ "$p" =~ ^[0-9]+$ ]] || die "--pid must be numeric, got '$p'"; done
[ -z "$CEILING" ] || [ "$CEILING" -gt 0 ] || die "--ceiling must be above 0"
[ -z "$PER_SESSION" ] || [ "$PER_SESSION" -gt 0 ] || die "--per-session must be above 0"
[ -z "$FENCE" ] || [ "$FENCE" -gt 0 ] || die "--fence must be above 0"
[ -r /proc/self/smaps_rollup ] || die "needs Linux /proc/<pid>/smaps_rollup (kernel 4.14+); macOS has no PSS or cgroups"
command -v ps >/dev/null 2>&1 || die "ps is required"

MEMTOTAL_KB=$(awk '/^MemTotal:/{print $2}' /proc/meminfo)
WSL=0
grep -qi microsoft /proc/sys/kernel/osrelease 2>/dev/null && WSL=1 || true

TMP=$(mktemp -d "${TMPDIR:-/tmp}/session-memory-budget.XXXXXX")
trap 'rm -f "$TMP"/comm "$TMP"/args "$TMP"/records; rmdir "$TMP" 2>/dev/null || true' EXIT
: > "$TMP/records"

SAMPLE_AWK='
function base(s) { sub(/.*\//, "", s); return s }
function isshell(h,   c) {
  c = comm[h]
  return (c ~ /^(bash|sh|zsh|dash|fish|ksh)$/ || args[h] ~ /shell-snapshots/)
}
function iswrap(p,   t, n, b) {
  n = split(args[p], t, " "); b = base(t[1])
  if (b == "npm" && t[2] == "exec") return 1
  if (b == "npx") return 1
  if (b == "node" && n >= 2 && base(t[2]) ~ /^(npx|npx-cli\.js|npm-cli\.js)$/) return 1
  return 0
}
function serverkey(h,   t, n, b, i, mode, k, rest, j) {
  n = split(args[h], t, " "); b = base(t[1]); i = 2; mode = ""
  if (b == "node" && n >= 2 && base(t[2]) ~ /^(npx|npx-cli\.js)$/) { mode = "pkg"; i = 3 }
  else if (b == "npm" && t[2] == "exec") { mode = "pkg"; i = 3 }
  else if (b ~ /^(npx|pnpx|bunx|uvx)$/) mode = "pkg"
  else if (b ~ /^(node|bun|deno|python[0-9.]*|uv|ruby|java)$/) mode = "script"
  else return b
  for (; i <= n; i++) {
    if (t[i] ~ /^-/ || t[i] == "run" || t[i] == "--") continue
    k = t[i]; break
  }
  if (k == "") return b
  if (mode == "script") return base(k)
  if (substr(k, 1, 1) == "@") {
    rest = substr(k, 2); j = index(rest, "@")
    if (j) k = "@" substr(rest, 1, j - 1)
  } else { j = index(k, "@"); if (j > 1) k = substr(k, 1, j - 1) }
  return k
}
function markx(p,   ks, n, i) {
  excl[p] = 1
  n = split(kids[p], ks, " ")
  for (i = 1; i <= n; i++) markx(ks[i])
}
function readmem(p,   f, l, x, r, s) {
  f = "/proc/" p "/smaps_rollup"; r = -1; s = -1
  while ((getline l < f) > 0) {
    if (l ~ /^Rss:/) { split(l, x, " "); r = x[2] }
    else if (l ~ /^Pss:/) { split(l, x, " "); s = x[2] }
  }
  close(f)
  MR = r; MP = s
  return (r >= 0 && s >= 0)
}
function walk(p, root, head,   ks, n, i, cat, h) {
  if (p in excl) return
  if (p != root && (p in isroot)) return
  member[p] = root
  h = head
  if (p == root) cat = "claude"
  else if (comm[p] == "claude") { cat = "claude"; team[root]++ }
  else {
    if (comm[ppid[p]] == "claude") h = p
    cat = isshell(h) ? "tool" : "mcp"
  }
  procs[root]++
  ok = readmem(p)
  if (!ok) unread[root]++
  else {
    rss[root, cat] += MR; pss[root, cat] += MP
    trss[root] += MR; tpss[root] += MP
  }
  if (cat == "mcp") {
    sk = root SUBSEP h
    if (!(sk in skey)) { skey[sk] = serverkey(h); slist[root] = slist[root] " " h }
    sprocs[sk]++
    if (ok) { srss[sk] += MR; spss[sk] += MP }
    if (iswrap(p)) {
      snpm[sk] = 1; wraps[root]++
      if (ok) { spwrap[sk] += MP; wpss[root] += MP }
    }
  }
  n = split(kids[p], ks, " ")
  for (i = 1; i <= n; i++) walk(ks[i], root, (cat == "claude") ? "" : h)
}
function readline1(f,   l) { l = ""; if ((getline l < f) <= 0) l = ""; close(f); return l }
function parentpath(p) { sub(/\/[^\/]*$/, "", p); return p }
FNR == NR {
  c = $0; sub(/^[ \t]*[0-9]+[ \t]/, "", c); comm[$1] = c; next
}
{
  p = $1; ppid[p] = $2; et[p] = $3
  a = $0; sub(/^[ \t]*[0-9]+[ \t]+[0-9]+[ \t]+[0-9]+[ \t]*/, "", a); args[p] = a
  kids[$2] = kids[$2] " " p; all[p] = 1
}
END {
  OFS = "\t"
  if (self in all) markx(self)
  for (p in all)
    if (comm[p] == "claude" && comm[ppid[p]] != "claude" && !(p in excl))
      if (want == "" || index(" " want " ", " " p " ")) roots[p] = 1
  # a claude launched from a tool shell is its own session, not part of this tree
  for (p in all)
    if (comm[p] == "claude" && comm[ppid[p]] != "claude") isroot[p] = 1
  for (r in roots) walk(r, r, "")
  for (r in roots) {
    # cgroup: is the session in a scope of its own? then memory.peak is its tree.
    cg = ""; f = "/proc/" r "/cgroup"
    while ((getline l < f) > 0) if (l ~ /^0::/) cg = substr(l, 4)
    close(f)
    dedicated = 0; cgpeak = "-"; cgmax = "-"
    if (cg != "" && cg != "/") {
      dir = "/sys/fs/cgroup" cg; f = dir "/cgroup.procs"; seen = 0; foreign = 0
      while ((getline l < f) > 0) { seen++; if (!((l in member) && member[l] == r) && !(l in excl)) foreign = 1 }
      close(f)
      if (seen > 0 && !foreign) {
        dedicated = 1
        v = readline1(dir "/memory.peak"); if (v ~ /^[0-9]+$/) cgpeak = v
        v = readline1(dir "/memory.max");  if (v ~ /^[0-9]+$/) cgmax = v
      }
    }
    # ceiling: lowest memory.max on the cgroups that hold this session (its own
    # scope excluded, that is a per-session fence, not a ceiling)
    ceil = "-"; ceilpath = "-"; q = dedicated ? parentpath(cg) : cg
    while (q != "") {
      v = readline1("/sys/fs/cgroup" q "/memory.max")
      if (v ~ /^[0-9]+$/ && (ceil == "-" || v + 0 < ceil + 0)) { ceil = v; ceilpath = q }
      q = parentpath(q)
    }
    print "S", idx, ts, r, et[r], procs[r], team[r] + 0, \
      rss[r, "claude"] + 0, pss[r, "claude"] + 0, rss[r, "mcp"] + 0, pss[r, "mcp"] + 0, \
      rss[r, "tool"] + 0, pss[r, "tool"] + 0, trss[r] + 0, tpss[r] + 0, \
      wraps[r] + 0, wpss[r] + 0, unread[r] + 0, (cg == "" ? "-" : cg), cgpeak, cgmax, ceil, ceilpath
    n = split(slist[r], hs, " ")
    for (i = 1; i <= n; i++) {
      sk = r SUBSEP hs[i]
      print "V", idx, ts, r, skey[sk], sprocs[sk], srss[sk] + 0, spss[sk] + 0, snpm[sk] + 0, spwrap[sk] + 0
    }
  }
}
'

for ((i = 1; i <= SAMPLES; i++)); do
  ps -eo pid=,comm= > "$TMP/comm"
  ps -eo pid=,ppid=,etimes=,args= > "$TMP/args"
  awk -v self="$$" -v idx="$i" -v ts="$(date '+%Y-%m-%d %H:%M:%S')" -v want="${PIDS# }" \
    "$SAMPLE_AWK" "$TMP/comm" "$TMP/args" >> "$TMP/records"
  if [ "$i" -lt "$SAMPLES" ]; then
    printf 'sample %d/%d taken, next in %ss\n' "$i" "$SAMPLES" "$INTERVAL" >&2
    sleep "$INTERVAL"
  fi
done

awk -F '\t' -v samples="$SAMPLES" -v memtotal="$MEMTOTAL_KB" -v wsl="$WSL" \
  -v ceiling_opt="$CEILING" -v headroom="$HEADROOM" -v per_opt="$PER_SESSION" \
  -v fence_opt="$FENCE" '
function mb(kb) { return int(kb / 1024 + 0.5) }
function commas(n,   s, o) {
  s = sprintf("%d", n); o = ""
  while (length(s) > 3) { o = "," substr(s, length(s) - 2) o; s = substr(s, 1, length(s) - 3) }
  return s o
}
function age(s) {
  if (s < 3600) return int(s / 60) "m"
  if (s < 86400) return int(s / 3600) "h" int((s % 3600) / 60) "m"
  return int(s / 86400) "d" int((s % 86400) / 3600) "h"
}
function hm(t) { return substr(t, 12, 5) }
$1 == "S" {
  r = $4; if ($2 + 0 > last) last = $2 + 0
  if (!(r in first)) { first[r] = $3; order[++nr] = r }
  lastidx[r] = $2 + 0
  if ($15 + 0 > peak[r]) { peak[r] = $15 + 0; peakts[r] = $3 }
  if ($20 != "-" && $20 + 0 > cgpeak[r]) cgpeak[r] = $20 + 0
  if ($21 != "-") cgmax[r] = $21 + 0
  if ($22 != "-" && (ceilb == "" || $22 + 0 < ceilb + 0)) { ceilb = $22; ceilpath = $23 }
  row[r] = $0; tsof[$2 + 0] = $3
  next
}
$1 == "V" { v[++nv] = $0 }
END {
  printf "session-memory-budget: %d sample%s", samples, (samples > 1 ? "s" : "")
  if (last > 1) printf ", %s to %s", tsof[1], tsof[last]
  else if (last == 1) printf ", %s", tsof[1]
  printf "\n\n"

  live = 0
  if (nr > 0) {
    printf "%-8s %-6s %5s %4s %10s %8s %6s %8s %9s %9s %9s %s\n", \
      "SESSION", "AGE", "PROCS", "TEAM", "CLAUDE_PSS", "MCP_PSS", "MCP%", "NPM_WRAP", \
      "TREE_RSS", "TREE_PSS", "PEAK_PSS", "PEAK_AT"
    for (k = 1; k <= nr; k++) {
      r = order[k]; split(row[r], f, "\t")
      ag = (f[7] + 0 > 0) ? f[7] : 0
      share = (f[9] + f[11] > 0) ? int(100 * f[11] / (f[9] + f[11]) + 0.5) "%" : "-"
      status = (lastidx[r] < last) ? "  (exited before last sample)" : ""
      if (lastidx[r] == last) { live++; sumrss += f[14]; sumpss += f[15]; unread += f[18] }
      printf "%-8s %-6s %5d %4d %7s MB %5s MB %6s %8d %6s MB %6s MB %6s MB %s%s\n", \
        r, age(f[5]), f[6], f[7], commas(mb(f[9])), commas(mb(f[11])), share, f[16], \
        commas(mb(f[14])), commas(mb(f[15])), commas(mb(peak[r])), hm(peakts[r]), status
      if (r in cgpeak) printf "%-8s   own cgroup %s: memory.peak %s MB%s\n", "", f[19], \
        commas(int(cgpeak[r] / 1048576 + 0.5)), (r in cgmax ? ", memory.max " commas(int(cgmax[r] / 1048576 + 0.5)) " MB" : "")
    }
    printf "\nCLAUDE_PSS is the claude process plus any teammates (TEAM). MCP%% is MCP PSS over\n"
    printf "CLAUDE_PSS + MCP_PSS. Tool shells (Bash tool, hooks run via sh) count in the tree only.\n"
    if (sumpss > 0)
      printf "\nRSS vs PSS: summed tree RSS %s MB against %s MB PSS; RSS overstates by %d%%.\n", \
        commas(mb(sumrss)), commas(mb(sumpss)), int(100 * (sumrss - sumpss) / sumpss + 0.5)
    if (unread > 0) printf "%d process%s unreadable (another user?); their memory is not counted.\n", unread, (unread > 1 ? "es" : "")

    # servers in the last sample
    ns = 0
    for (k = 1; k <= nv; k++) {
      split(v[k], f, "\t"); if (f[2] + 0 != last) continue
      key = f[5]
      if (!(key in inst)) skeys[++ns] = key
      inst[key]++; sp[key] += f[6]; spss[key] += f[8]; npm[key] += f[9]; wpss[key] += f[10]
      if (!((key, f[4]) in sess)) { sess[key, f[4]] = 1; nsess[key]++ }
    }
    if (ns > 0) {
      printf "\n%-34s %9s %8s %5s %9s  %s\n", "MCP SERVER", "INSTANCES", "SESSIONS", "PROCS", "PSS", "FLAGS"
      dup = 0; wtot = 0
      for (k = 1; k <= ns; k++) {
        key = skeys[k]; fl = ""
        if (inst[key] > 1) { fl = "DUPLICATED x" inst[key]; dup++ }
        if (npm[key] > 0) {
          fl = fl (fl == "" ? "" : "; ") "npm exec wrapper x" npm[key] ", " commas(mb(wpss[key])) " MB PSS doing no MCP work"
          wtot += wpss[key]
        }
        printf "%-34s %9d %8d %5d %6s MB  %s\n", substr(key, 1, 34), inst[key], nsess[key], sp[key], commas(mb(spss[key])), fl
      }
      if (dup > 0) printf "\n%d server%s run once per session. Stdio servers are per-client subprocesses, so N sessions\nx M servers is the count; trim M, or share stateless ones over HTTP.\n", dup, (dup > 1 ? "s" : "")
      if (wtot > 0) printf "npm exec wrappers hold %s MB PSS in total. Install the package globally and launch its\nbin directly, then re-check with: ps --ppid <claude-pid> -o pid,rss,args\n", commas(mb(wtot))
    }
  } else {
    printf "No claude sessions found.\n"
  }

  # sizing
  if (per_opt != "") { per = per_opt + 0; persrc = "--per-session" }
  else if (nr > 0) {
    per = 0
    for (k = 1; k <= nr; k++) {
      r = order[k]
      if (mb(peak[r]) > per) { per = mb(peak[r]); persrc = "worst tree PSS observed (session " r " at " hm(peakts[r]) ")" }
      if ((r in cgpeak) && int(cgpeak[r] / 1048576 + 0.5) > per) { per = int(cgpeak[r] / 1048576 + 0.5); persrc = "memory.peak, own cgroup of session " r }
    }
  } else exit 1
  if (per <= 0) { printf "\nNo readable memory for any session; cannot size.\n"; exit 1 }

  if (ceiling_opt != "") { ceil = ceiling_opt + 0; csrc = "--ceiling" }
  else {
    ceil = mb(memtotal)
    csrc = wsl ? "MemTotal inside the WSL2 VM (.wslconfig memory=, default 50% of Windows RAM)" : "MemTotal"
    if (ceilb != "" && int(ceilb / 1048576) < ceil) { ceil = int(ceilb / 1048576); csrc = "memory.max on cgroup " ceilpath }
  }
  fence = 0
  if (fence_opt != "") { fence = fence_opt + 0; fsrc = "--fence" }
  else for (k = 1; k <= nr; k++) {
    r = order[k]
    if ((r in cgmax) && int(cgmax[r] / 1048576) > fence) { fence = int(cgmax[r] / 1048576); fsrc = "memory.max on session scopes" }
  }
  hr = int(ceil * headroom / 100 + 0.5); usable = ceil - hr

  printf "\nMax parallel sessions = (ceiling - headroom) / peak tree PSS per session\n\n"
  printf "%-12s %10s MB   %s\n", "ceiling", commas(ceil), csrc
  printf "%-12s %10s MB   %d%% (author judgment from the post, not a sourced number)\n", "headroom", commas(hr), headroom
  printf "%-12s %10s MB\n", "usable", commas(usable)
  printf "%-12s %10s MB   %s\n", "per session", commas(per), persrc
  printf "%-12s %10s      %s / %s\n", "on paper", commas(int(usable / per)), commas(usable), commas(per)
  if (fence > 0) printf "%-12s %10s      %s / %s, every session at MemoryMax at once (%s)\n", "fenced", commas(int(usable / fence)), commas(usable), commas(fence), fsrc
  if (live > 0 && per_opt == "") printf "%-12s %10d      sessions running now\n", "running", live

  printf "\nCaveats:\n"
  if (per_opt == "") {
    if (samples == 1) printf "- One sample is a floor, not a peak. Re-run with --samples N --interval SECS, or fence each\n  session in its own cgroup and let memory.peak remember the worst moment.\n"
    else printf "- The peak covers only this sampling window. It says nothing about hour four of a session.\n"
  }
  printf "- PSS divides shared pages among the processes sharing them; budget in PSS, never summed RSS\n  or VSZ. Children of claude that are not shells are counted as MCP: language servers,\n  plugins and other helpers land there too.\n"
  printf "- Re-measure after any change to the MCP set or the CLI version; both move the denominator.\n"
  if (fence == 0) printf "- No fence detected. Without one, a single runaway session can take the host with it.\n"
}
' "$TMP/records"
