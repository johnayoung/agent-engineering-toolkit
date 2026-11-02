# Shared setup for the loop.sh tests. Every test gets a fresh temp git repo, a
# read-only gate dir and a stub claude first on PATH, and removes them after.
# shellcheck shell=bash
# SC2016: shell code written to files literally. SC2034: variables read by the .bats files.
# SC2154: status, stderr and stderr_lines are set by bats `run`.
# shellcheck disable=SC2016,SC2034,SC2154

HL_DIR="$(cd "$BATS_TEST_DIRNAME/.." && pwd)"
LOOP_SH="${LOOP_SH:-$HL_DIR/loop.sh}"   # point at another loop.sh to test it instead
REAL_GIT="$(command -v git)"

bats_require_minimum_version 1.5.0

setup() {
  TEST_TMP="$(mktemp -d "${TMPDIR:-/tmp}/hl-test.XXXXXX")"
  REPO="$TEST_TMP/repo"
  GATE="$TEST_TMP/gate"
  STUB_STATE="$TEST_TMP/stub"
  mkdir -p "$REPO" "$GATE/tests" "$STUB_STATE"

  PATH="$HL_DIR/test/stub:$PATH"
  # never reach a real claude: the stub must be what loop.sh resolves
  [ "$(command -v claude)" = "$HL_DIR/test/stub/claude" ] || { echo "stub claude not first on PATH" >&2; return 1; }

  # isolate git from the user's config (signing, hooksPath, templates)
  export GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_NOSYSTEM=1
  export GIT_AUTHOR_NAME=loop.sh GIT_AUTHOR_EMAIL=loop@localhost
  export GIT_COMMITTER_NAME=loop.sh GIT_COMMITTER_EMAIL=loop@localhost
  export GATE STUB_STATE AGENT_LIB="$HL_DIR/test/stub/agent-lib.bash"

  # loop.sh knobs: small, fast defaults; tests override per case
  export MAX_ITERATIONS=5 MAX_TURNS=40 CALL_BUDGET=4.00 SPEND_CEILING=100
  export ITER_TIMEOUT=30s NO_PROGRESS_LIMIT=3 PROMPT_FILE=PROMPT.md
  export GATE_CMD="$GATE/run"
  unset STUB_COSTS STUB_SUBTYPES STUB_EXITS STUB_SLEEPS STUB_OUTPUTS STUB_ACTION STUB_IGNORE_TERM

  write_gate
  write_repo
}

teardown() {
  local f
  for f in "$STUB_STATE"/pid-*; do
    [ -e "$f" ] && kill -KILL "$(cat "$f")" 2>/dev/null
  done
  [ -n "${LOOP_PID:-}" ] && kill -KILL "$LOOP_PID" 2>/dev/null
  chmod -R u+w "$TEST_TMP" 2>/dev/null
  rm -rf "$TEST_TMP"
}

# The gate: a runner that executes each test id as a script, like pytest
# with node ids. An id that is not a file fails, as it would in pytest.
write_gate() {
  cat > "$GATE/run" <<'EOF'
#!/usr/bin/env bash
rc=0
for t in "$@"; do
  if [ -f "$t" ]; then bash "$t" || { echo "FAIL $t"; rc=1; }; else echo "ERROR: not found: $t"; rc=4; fi
done
exit "$rc"
EOF
  printf '[ "$(bash ./calc.sh add 2 3)" = 5 ]\n' > "$GATE/tests/test_add.sh"
  printf '[ "$(bash ./calc.sh sub 5 3)" = 2 ]\n' > "$GATE/tests/test_sub.sh"
  chmod +x "$GATE/run"
}

lock_gate() { chmod -R a-w "$GATE"; }

features_json() {
  jq -n --arg add "$GATE/tests/test_add.sh" --arg sub "$GATE/tests/test_sub.sh" '[
    {category: "functional", description: "calc adds", steps: ["run calc.sh add 2 3"], passes: false, test: $add},
    {category: "functional", description: "calc subtracts", steps: ["run calc.sh sub 5 3"], passes: false, test: $sub}
  ]'
}

# A clean repo: loop.sh, PROMPT.md, features.json and an unimplemented calc.sh, all committed.
write_repo() {
  cd "$REPO" || return 1
  git init -q -b main
  cp "$LOOP_SH" loop.sh
  chmod +x loop.sh
  echo "Implement the next failing feature in features.json." > PROMPT.md
  features_json > features.json
  printf '#!/usr/bin/env bash\necho "not implemented: $1" >&2\nexit 1\n' > calc.sh
  git add -A
  git commit -q -m "loop setup"
  lock_gate
}

# agent <bash line>...: what the stub does on each call (CALL holds the call number)
agent() {
  { echo "source '$AGENT_LIB'"; printf '%s\n' "$@"; } > "$TEST_TMP/action.sh"
  export STUB_ACTION="$TEST_TMP/action.sh"
}

# run the loop in the foreground with a hard outer limit so a hang fails the test
run_loop() {
  cd "$REPO" || return 1
  run --separate-stderr timeout -k 5 "${HL_RUN_LIMIT:-60}" ./loop.sh
}

# start the loop in the background; LOOP_PID holds its pid
start_loop() {
  cd "$REPO" || return 1
  # a script's background jobs inherit SIGINT ignored, which bash cannot trap; reset it
  # so the loop sees signals as it would launched from a terminal or under tini
  env --default-signal=INT,QUIT ./loop.sh > "$TEST_TMP/loop.out" 2> "$TEST_TMP/loop.err" &
  LOOP_PID=$!
}

# wait_for <file> [seconds]: poll until the file exists
wait_for() {
  local i
  for ((i = 0; i < ${2:-10} * 20; i++)); do
    [ -e "$1" ] && return 0
    sleep 0.05
  done
  echo "timed out waiting for $1" >&2
  return 1
}

# wait_loop: wait for the background loop, set LOOP_RC, fail if it outlives the limit
wait_loop() {
  local i
  for ((i = 0; i < ${1:-15} * 20; i++)); do
    kill -0 "$LOOP_PID" 2>/dev/null || break
    sleep 0.05
  done
  if kill -0 "$LOOP_PID" 2>/dev/null; then
    echo "loop.sh still running after ${1:-15}s" >&2
    return 1
  fi
  LOOP_RC=0
  wait "$LOOP_PID" || LOOP_RC=$?
  LOOP_PID=""
}

# assert_stop <control text> <exit code> [iterations] [spend]
# checks the exit code, the stderr line and the last line of progress.txt
assert_stop() {
  local expected="loop.sh: stopped by $1"
  [ -n "${3:-}" ] && expected+=" after $3 iteration(s)"
  [ -n "${4:-}" ] && expected+=", spend \$$4"
  if [ "$status" -ne "$2" ]; then
    echo "exit $status, expected $2; stderr: $stderr" >&2
    return 1
  fi
  local last="${stderr_lines[${#stderr_lines[@]} - 1]}"
  case "$last" in
    "$expected"*) ;;
    *) echo "last stderr line: '$last'; expected prefix '$expected'" >&2; return 1 ;;
  esac
  case "$(tail -n 1 "$REPO/progress.txt")" in
    *"[loop.sh] ${expected#loop.sh: }"*) ;;
    *) echo "progress.txt last line: $(tail -n 1 "$REPO/progress.txt")" >&2; return 1 ;;
  esac
}

calls() { cat "$STUB_STATE/calls" 2>/dev/null || echo 0; }
passes() { jq -c '[.[].passes]' "$REPO/features.json"; }
head_passes() { git -C "$REPO" show HEAD:features.json | jq -c '[.[].passes]'; }
progress_has() { grep -qF -- "$1" "$REPO/progress.txt" || { echo "progress.txt lacks: $1" >&2; cat "$REPO/progress.txt" >&2; return 1; }; }
# refute <cmd>...: fail if the command succeeds (bats does not fail on a bare `! cmd`)
refute() { if "$@"; then echo "expected failure: $*" >&2; return 1; fi; }
