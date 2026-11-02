#!/usr/bin/env bats
# Fault injection: broken claude output, signals at bad moments, and an agent
# that damages the state the wrapper depends on.

load helpers

# --- broken claude output: the call happened, so the ledger must not record $0

@test "F01 claude crashes mid-output: exit 137 logged, call charged CALL_BUDGET" {
  export MAX_ITERATIONS=1 STUB_OUTPUTS=truncated
  run_loop
  progress_has "iteration 1: claude exited 137 (no result)"
  progress_has "iteration 1 reported no cost; charged CALL_BUDGET (\$4.00)"
  assert_stop "MAX_ITERATIONS (1)" 1 1 4.00
}

@test "F02 malformed JSON on a zero exit: no crash, call charged CALL_BUDGET" {
  export MAX_ITERATIONS=2 STUB_OUTPUTS=malformed
  run_loop
  assert_stop "MAX_ITERATIONS (2)" 1 2 8.00
}

@test "F03 empty output: call charged CALL_BUDGET" {
  export MAX_ITERATIONS=1 STUB_OUTPUTS=empty
  run_loop
  assert_stop "MAX_ITERATIONS (1)" 1 1 4.00
}

@test "F04 total_cost_usd missing: call charged CALL_BUDGET" {
  export MAX_ITERATIONS=1 STUB_COSTS=missing
  run_loop
  assert_stop "MAX_ITERATIONS (1)" 1 1 4.00
}

@test "F05 total_cost_usd null: call charged CALL_BUDGET" {
  export MAX_ITERATIONS=1 STUB_COSTS=null
  run_loop
  assert_stop "MAX_ITERATIONS (1)" 1 1 4.00
}

@test "F06 total_cost_usd a string: call charged CALL_BUDGET" {
  export MAX_ITERATIONS=1 STUB_COSTS=str
  run_loop
  assert_stop "MAX_ITERATIONS (1)" 1 1 4.00
}

@test "F07 jq produces nothing (JSON that is not an object): call charged CALL_BUDGET" {
  export MAX_ITERATIONS=1 STUB_OUTPUTS=array
  run_loop
  assert_stop "MAX_ITERATIONS (1)" 1 1 4.00
}

@test "F08 two JSON documents: the last cost is the one recorded" {
  export MAX_ITERATIONS=1 STUB_OUTPUTS=twodocs STUB_COSTS=2.00
  run_loop
  assert_stop "MAX_ITERATIONS (1)" 1 1 2.00
  [ "$(awk -F'\t' '{ print $1, $2 + 0 }' "$REPO/.loop/spend.log")" = "1 2" ]
}

# --- signals

@test "F09 SIGTERM during the wrapper's git commit: commit completes, trap commits the note" {
  shim="$TEST_TMP/shim"
  mkdir -p "$shim"
  cat > "$shim/git" <<'EOF'
#!/usr/bin/env bash
if [ "${1:-}" = commit ] && [ ! -e "$SHIM_FIRED" ]; then
  case " $* " in *" loop: iteration 1 "*) touch "$SHIM_FIRED"; kill -TERM "$PPID" ;; esac
fi
exec "$REAL_GIT" "$@"
EOF
  chmod +x "$shim/git"
  export REAL_GIT SHIM_FIRED="$TEST_TMP/fired"
  agent 'echo "step $CALL" >> work.txt'
  PATH="$shim:$PATH" start_loop
  wait_loop 10
  [ "$LOOP_RC" -eq 130 ]
  [ -e "$SHIM_FIRED" ]
  [ "$(git log --format=%s | paste -sd'|')" = "loop: iteration 1 interrupted|loop: iteration 1|loop setup" ]
  [ ! -e .git/index.lock ]
  git fsck >/dev/null 2>&1
  [ "$(calls)" -eq 1 ]
}

@test "F10 SIGINT mid-call: same trap, exit 130, child stopped" {
  export STUB_SLEEPS=30
  start_loop
  wait_for "$STUB_STATE/running-1"
  kill -INT "$LOOP_PID"
  wait_loop 10
  [ "$LOOP_RC" -eq 130 ]
  progress_has "killed during iteration 1"
  refute kill -0 "$(cat "$STUB_STATE/pid-1")"
}

@test "F11 SIGTERM while claude ignores SIGTERM: the trap still finishes inside docker's 10s grace" {
  export STUB_SLEEPS=60 STUB_IGNORE_TERM=1
  start_loop
  wait_for "$STUB_STATE/running-1"
  SECONDS=0
  kill -TERM "$LOOP_PID"
  wait_loop 15
  [ "$SECONDS" -lt 10 ]
  [ "$LOOP_RC" -eq 130 ]
  progress_has "killed during iteration 1"
  refute kill -0 "$(cat "$STUB_STATE/pid-1")"
}

@test "F12 ITER_TIMEOUT against a claude that ignores SIGTERM: the loop still moves on" {
  export MAX_ITERATIONS=2 ITER_TIMEOUT=1s STUB_SLEEPS="60 0" STUB_IGNORE_TERM=1
  HL_RUN_LIMIT=30 run_loop
  [ "$status" -ne 124 ]
  [ "$(calls)" -eq 2 ]
  progress_has "iteration 1: claude exited 137 (no result)"
  assert_stop "MAX_ITERATIONS (2)" 1 2 4.50
}

# --- repo state at start

@test "F13 a dirty tree at start is committed by iteration 1 and counts as progress" {
  echo "uncommitted" > stray.txt
  echo "# edited" >> calc.sh
  run_loop
  # documented: iteration 1 commits the dirt, so the breaker needs one extra iteration
  assert_stop "no-progress breaker (3 unchanged diffs)" 1 4
  git show "$(git rev-list --reverse HEAD | sed -n 2p)":stray.txt | grep -q uncommitted
}

# --- the agent damages the wrapper's state

@test "F14 spend.log deleted between iterations: the ceiling still binds" {
  export SPEND_CEILING=10 STUB_COSTS=3.00
  agent 'echo "step $CALL" >> work.txt' '[ "$CALL" -eq 3 ] && rm -f .loop/spend.log'
  run_loop
  assert_stop "SPEND_CEILING (\$10)" 1 4 12.00
}

@test "F15 the agent runs git clean -fdx and wipes .loop: ledger intact, calls still launch" {
  export SPEND_CEILING=10 STUB_COSTS=3.00
  agent 'echo "step $CALL" >> work.txt' '[ "$CALL" -eq 2 ] && git clean -q -fdx'
  run_loop
  # the clean also deleted call 2's own output, so call 2 is charged CALL_BUDGET: 3 + 4 + 3
  assert_stop "SPEND_CEILING (\$10)" 1 3 10.00
  [ "$(calls)" -eq 3 ]
  progress_has "iteration 2 reported no cost; charged CALL_BUDGET"
}

@test "F16 features.json made invalid JSON: restored" {
  export MAX_ITERATIONS=1
  agent 'echo "{ not json" > features.json'
  run_loop
  progress_has "iteration 1 edited features.json beyond .passes; restored"
  [ "$(passes)" = "[false,false]" ]
  git diff --quiet HEAD~1 HEAD -- features.json
}

@test "F17 features.json deleted: restored" {
  export MAX_ITERATIONS=1
  agent 'rm features.json'
  run_loop
  progress_has "iteration 1 edited features.json beyond .passes; restored"
  [ "$(passes)" = "[false,false]" ]
}

@test "F18 the agent adds its own passing feature entry: restored, not done" {
  export MAX_ITERATIONS=1
  agent 'jq ". + [{category: \"x\", description: \"free\", steps: [], passes: true, test: \"$GATE/run\"}] | map(.passes = true)" features.json > f && mv f features.json'
  run_loop
  progress_has "iteration 1 edited features.json beyond .passes; restored"
  assert_stop "MAX_ITERATIONS (1)" 1 1
  [ "$(jq length features.json)" -eq 2 ]
}

@test "F19 the agent commits its own unearned flip: the gate still rejects it" {
  export MAX_ITERATIONS=2
  agent 'flip add sub' 'git add -A && git commit -q -m "all features pass"'
  run_loop
  assert_stop "MAX_ITERATIONS (2)" 1 2
  progress_has "iteration 1: gate failed, passes flips rejected"
  [ "$(passes)" = "[false,false]" ]
  [ "$(head_passes)" = "[false,false]" ]
}

@test "F20 the agent commits its own edit beyond .passes: still restored" {
  export MAX_ITERATIONS=1
  agent 'jq "[.[0]] | map(.passes = true)" features.json > f && mv f features.json' 'git commit -qam "drop sub"'
  run_loop
  progress_has "iteration 1 edited features.json beyond .passes; restored"
  [ "$(jq length features.json)" -eq 2 ]
  [ "$(head_passes)" = "[false,false]" ]
}

@test "F21 the agent commits real work every iteration: the breaker does not misfire" {
  export MAX_ITERATIONS=4
  agent 'echo "step $CALL" >> work.txt' 'git add -A && git commit -q -m "agent step $CALL"'
  run_loop
  assert_stop "MAX_ITERATIONS (4)" 1 4
}

@test "F22 the agent runs git reset --hard over the last iteration: no crash, state stays consistent" {
  export MAX_ITERATIONS=2
  agent '[ "$CALL" -eq 1 ] && implement add && flip add' '[ "$CALL" -eq 2 ] && git reset -q --hard HEAD~1'
  run_loop
  assert_stop "MAX_ITERATIONS (2)" 1 2
  # iteration 2 rolled back iteration 1; the wrapper records that, and add is no longer passing
  [ "$(head_passes)" = "[false,false]" ]
  refute grep -q 'add)' <(git show HEAD:calc.sh)
}

@test "F23 the agent runs git checkout and writes on the gate path: both fail, gate unchanged" {
  export MAX_ITERATIONS=1
  before="$(cat "$GATE/tests/test_add.sh" | sha256sum)"
  agent 'flip add' \
    'git checkout HEAD -- "$GATE/tests/test_add.sh" && echo "checkout worked"' \
    'echo "exit 0" > "$GATE/tests/test_add.sh" && echo "write worked"' \
    'git -C "$GATE" init -q && echo "git init worked"'
  run_loop
  [ "$(cat "$GATE/tests/test_add.sh" | sha256sum)" = "$before" ]
  refute grep -q worked "$STUB_STATE/action-1.log"
  progress_has "iteration 1: gate failed, passes flips rejected"
  [ "$(passes)" = "[false,false]" ]
}

@test "F24 the agent deletes .git and flips everything: never reported done" {
  export MAX_ITERATIONS=2
  agent 'flip add sub' 'rm -rf .git'
  run_loop
  assert_stop "MAX_ITERATIONS (2)" 1 2
}
