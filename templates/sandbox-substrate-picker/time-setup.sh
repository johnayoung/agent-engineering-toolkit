#!/usr/bin/env bash
# time-setup.sh: time what one session spends between sandbox start and its
# first useful action (clone, install, warm build), the number
# sandbox-substrate-picker.sh takes as --setup-min.
#
# From "A Sandbox for AI Coding Agents at Scale Is a Warm-State Problem"
# https://jyoung.dev/blog/sandbox-parallel-coding-agents/
#
# Run it inside a fresh sandbox on each candidate substrate. Run on your own
# machine, it measures your machine (warm disk, warm network caches), which
# understates a cold sandbox.
#
# Usage:
#   time-setup.sh REPO [--install CMD] [--build CMD] [--depth N]
#
#   REPO           anything `git clone` accepts: URL or local path
#   --install CMD  dependency step, run in the clone, e.g.
#                  'pnpm install --frozen-lockfile'
#   --build CMD    warm build step, run in the clone, e.g.
#                  'pnpm --filter "./packages/**" build'
#   --depth N      clone depth (default 1; 0 for a full clone)
#   --sessions N   also print the fleet total for N sessions
#
# The clone goes to a new temporary directory, removed on exit. A failing
# step stops the run and exits 1; a partial setup time is not a setup time.
#
# Exit: 0 ok, 1 a step failed, 2 usage error.
# Dependencies: bash, git, coreutils (date with %N).

set -euo pipefail

usage() { sed -n '2,27p' "$0" | sed 's/^# \{0,1\}//'; }
die() { printf 'time-setup: %s\n' "$1" >&2; exit 2; }

REPO="" INSTALL="" BUILD="" DEPTH=1 SESSIONS=""
need() { [ "$#" -ge 2 ] && [ -n "$2" ] || die "$1 needs a value"; }
while [ "$#" -gt 0 ]; do
  case "$1" in
    --install) need "$@"; INSTALL="$2"; shift 2 ;;
    --build) need "$@"; BUILD="$2"; shift 2 ;;
    --depth) need "$@"; DEPTH="$2"; shift 2 ;;
    --sessions) need "$@"; SESSIONS="$2"; shift 2 ;;
    -h|--help) usage; exit 0 ;;
    -*) die "unknown option: $1 (see --help)" ;;
    *) [ -z "$REPO" ] || die "one REPO only"; REPO="$1"; shift ;;
  esac
done
[ -n "$REPO" ] || die "REPO is required (see --help)"
[[ "$DEPTH" =~ ^[0-9]+$ ]] || die "--depth must be a whole number"
[ -z "$SESSIONS" ] || [[ "$SESSIONS" =~ ^[1-9][0-9]*$ ]] || die "--sessions must be a whole number above 0"
command -v git >/dev/null || die "git is required"

WORK=$(mktemp -d "${TMPDIR:-/tmp}/time-setup.XXXXXX")
trap 'rm -rf -- "$WORK"' EXIT
DEST="$WORK/workspace"

now() { date +%s.%N; }
TOTAL=0
step() {
  local label=$1 cmd=$2 t0 t1 secs rc=0
  t0=$(now)
  if [ "$label" = clone ]; then
    if [ "$DEPTH" -gt 0 ]; then
      # --depth is ignored for plain local paths; file:// honors it.
      src=$REPO; [ -d "$REPO" ] && src="file://$(cd "$REPO" && pwd)"
      git clone --quiet --depth "$DEPTH" "$src" "$DEST" || rc=$?
    else
      git clone --quiet "$REPO" "$DEST" || rc=$?
    fi
  else
    (cd "$DEST" && bash -c "$cmd") >"$WORK/$label.log" 2>&1 || rc=$?
  fi
  t1=$(now)
  secs=$(awk -v a="$t0" -v b="$t1" 'BEGIN{printf "%.1f", b-a}')
  if [ "$rc" -ne 0 ]; then
    printf '%-8s FAILED after %ss (exit %s)\n' "$label" "$secs" "$rc"
    [ -f "$WORK/$label.log" ] && tail -n 20 "$WORK/$label.log" | sed 's/^/  | /'
    exit 1
  fi
  printf '%-8s %8ss\n' "$label" "$secs"
  TOTAL=$(awk -v t="$TOTAL" -v s="$secs" 'BEGIN{printf "%.1f", t+s}')
}

echo "time-setup: $REPO"
step clone ""
[ -z "$INSTALL" ] || step install "$INSTALL"
[ -z "$BUILD" ] || step build "$BUILD"

MIN=$(awk -v t="$TOTAL" 'BEGIN{printf "%.3f", t/60}')
printf '%-8s %8ss  (%s min)\n' "setup" "$TOTAL" "$MIN"
[ -n "$INSTALL" ] || echo "note: no --install step timed; setup excludes dependency install"
[ -n "$BUILD" ] || echo "note: no --build step timed; setup excludes the warm build"
if [ -n "$SESSIONS" ]; then
  awk -v t="$TOTAL" -v n="$SESSIONS" 'BEGIN{printf "fleet    %s sessions x %.1fs = %.1f session-minutes if every session pays it cold\n", n, t, n*t/60}'
fi
echo "next: sandbox-substrate-picker.sh --setup-min $MIN ..."
