#!/usr/bin/env bash
# check.sh: shellcheck, then the bats suite. Free: no API calls, no Docker.
# Usage: test/check.sh [bats args...]    e.g. test/check.sh --filter H5
set -euo pipefail

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$here/.."

command -v shellcheck >/dev/null || { echo "check.sh: shellcheck not found (https://github.com/koalaman/shellcheck#installing)" >&2; exit 2; }

# SC2317 (unreachable command) and SC2329 (never invoked, shellcheck 0.11+) are false
# positives on on_kill: it only runs from the trap.
shellcheck -e SC2317,SC2329 loop.sh
shellcheck run.sh test/check.sh test/stub/claude test/stub/agent-lib.bash test/helpers.bash
echo "shellcheck: clean"

"$here/bats/bin/bats" "$@" "$here"
