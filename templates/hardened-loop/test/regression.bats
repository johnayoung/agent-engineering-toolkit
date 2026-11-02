#!/usr/bin/env bats
# Regression: every exit path the artifact record says was dogfooded.

load helpers

@test "R01 MAX_ITERATIONS stops a loop that keeps making progress" {
  export MAX_ITERATIONS=2
  agent 'echo "step $CALL" >> work.txt'
  run_loop
  assert_stop "MAX_ITERATIONS (2)" 1 2 1.00
  [ "$(calls)" -eq 2 ]
}

@test "R02 every call carries the per-call caps, the permission flag and JSON output" {
  export MAX_ITERATIONS=1 MAX_TURNS=7 CALL_BUDGET=2.50
  run_loop
  args="$(cat "$STUB_STATE/args-1")"
  [ "$(sed -n 1p "$STUB_STATE/args-1")" = "-p" ]
  [ "$(sed -n 2p "$STUB_STATE/args-1")" = "$(cat "$REPO/PROMPT.md")" ]
  [[ "$args" == *$'--dangerously-skip-permissions\n'* ]]
  [[ "$args" == *$'--max-turns\n7\n'* ]]
  [[ "$args" == *$'--max-budget-usd\n2.50\n'* ]]
  [[ "$args" == *$'--output-format\njson'* ]]
  [[ "$args" != *--resume* && "$args" != *--continue* ]]
}

@test "R03 SPEND_CEILING stops the run, overshooting by at most the last call" {
  export SPEND_CEILING=10 STUB_COSTS=3.50
  agent 'echo "step $CALL" >> work.txt'
  run_loop
  assert_stop "SPEND_CEILING (\$10)" 1 3 10.50
  [ "$(wc -l < "$REPO/.loop/spend.log")" -eq 3 ]
  [ "$(cut -f2 "$REPO/.loop/spend.log" | paste -sd' ')" = "3.5 3.5 3.5" ]
}

@test "R04 done: every feature passed the gate, exit 0" {
  agent 'implement add sub' 'flip add sub'
  run_loop
  assert_stop "done: every feature passed the gate" 0 1 0.50
  [ "$(head_passes)" = "[true,true]" ]
  [ -e "$REPO/.loop/logs/gate-1.log" ]
  [ "$(git -C "$REPO" log -1 --format=%s)" = "loop: iteration 1" ]
}

@test "R05 the gate rejects an unearned flip and restores features.json" {
  export MAX_ITERATIONS=1
  agent 'implement sub' 'flip add sub'   # add is flipped but not implemented
  run_loop
  assert_stop "MAX_ITERATIONS (1)" 1 1
  progress_has "iteration 1: gate failed, passes flips rejected (see .loop/logs/gate-1.log)"
  grep -q "FAIL .*test_add.sh" "$REPO/.loop/logs/gate-1.log"
  [ "$(passes)" = "[false,false]" ]
  [ "$(head_passes)" = "[false,false]" ]
  # the code still lands; only the flags are rejected
  git -C "$REPO" show HEAD:calc.sh | grep -q 'sub)'
}

@test "R06 no-progress breaker fires after NO_PROGRESS_LIMIT unchanged diffs" {
  run_loop
  assert_stop "no-progress breaker (3 unchanged diffs)" 1 3 1.50
}

@test "R07 progress.txt notes and a gated flag flip do not count as progress" {
  agent '[ "$CALL" -eq 1 ] && implement sub' 'flip sub' 'echo "agent note $CALL" >> progress.txt'
  run_loop
  # iteration 1 changes calc.sh (progress), 2-4 only append notes and re-flip
  assert_stop "no-progress breaker (3 unchanged diffs)" 1 4
  [ "$(head_passes)" = "[false,true]" ]
}

@test "R08 SIGTERM mid-call: the trap writes the note and commits partial work" {
  export STUB_SLEEPS=30
  agent 'echo partial > partial.txt'
  start_loop
  wait_for "$STUB_STATE/running-1"
  kill -TERM "$LOOP_PID"
  wait_loop 10
  [ "$LOOP_RC" -eq 130 ]
  progress_has "killed during iteration 1; partial work committed as 'loop: iteration 1 interrupted'"
  [ "$(git -C "$REPO" log -1 --format=%s)" = "loop: iteration 1 interrupted" ]
  git -C "$REPO" show HEAD:partial.txt | grep -q partial
  git -C "$REPO" show HEAD:progress.txt | grep -q "killed during iteration 1"
  refute kill -0 "$(cat "$STUB_STATE/pid-1")"
  [ "$(calls)" -eq 1 ]
}

@test "R09 an edit to features.json beyond .passes is restored" {
  export MAX_ITERATIONS=1
  agent 'jq ".[0].description = \"anything\"" features.json > f && mv f features.json'
  run_loop
  progress_has "iteration 1 edited features.json beyond .passes; restored"
  [ "$(jq -r '.[0].description' "$REPO/features.json")" = "calc adds" ]
  git -C "$REPO" diff --quiet HEAD~1 HEAD -- features.json
}

@test "R10 a nonzero claude exit is logged with its subtype and its spend still counts" {
  export MAX_ITERATIONS=1 STUB_EXITS=1 STUB_SUBTYPES=error_max_turns STUB_COSTS=1.25
  run_loop
  assert_stop "MAX_ITERATIONS (1)" 1 1 1.25
  progress_has "iteration 1: claude exited 1 (error_max_turns)"
  [ "$(cat "$REPO/.loop/spend.log")" = "$(printf '1\t1.25')" ]
}

@test "R11 ITER_TIMEOUT ends a long call and the loop moves on" {
  export MAX_ITERATIONS=2 ITER_TIMEOUT=1s STUB_SLEEPS="20 0"
  agent 'echo "step $CALL" >> work.txt'
  SECONDS=0
  run_loop
  [ "$SECONDS" -lt 10 ]
  progress_has "iteration 1 hit ITER_TIMEOUT (1s)"
  [ "$(calls)" -eq 2 ]
  # the timed-out call left no cost, so it is charged CALL_BUDGET (see H3)
  assert_stop "MAX_ITERATIONS (2)" 1 2 4.50
}

@test "R12 refuses to start when a required binary is missing" {
  bin="$TEST_TMP/bin"
  mkdir -p "$bin"
  for b in bash env git jq timeout awk mkdir cat date dirname touch grep; do ln -s "$(command -v "$b")" "$bin/$b"; done
  run --separate-stderr env PATH="$bin" ./loop.sh
  [ "$status" -eq 2 ]
  [ "$stderr" = "loop.sh: missing claude" ]

  rm "$bin/jq"
  ln -s "$HL_DIR/test/stub/claude" "$bin/claude"
  run --separate-stderr env PATH="$bin" ./loop.sh
  [ "$status" -eq 2 ]
  [ "$stderr" = "loop.sh: missing jq" ]
  [ "$(calls)" -eq 0 ]
}

@test "R13 refuses MAX_ITERATIONS=0 and a non-number" {
  MAX_ITERATIONS=0 run --separate-stderr ./loop.sh
  [ "$status" -eq 2 ]
  [ "$stderr" = "loop.sh: MAX_ITERATIONS must be > 0" ]
  MAX_ITERATIONS=lots run --separate-stderr ./loop.sh
  [ "$status" -eq 2 ]
  [ "${stderr_lines[${#stderr_lines[@]} - 1]}" = "loop.sh: MAX_ITERATIONS must be > 0" ]
  [ "$(calls)" -eq 0 ]
}

@test "R14 refuses to start when features.json is not committed" {
  git rm -q --cached features.json
  git commit -q -m "untrack features.json"
  run --separate-stderr ./loop.sh
  [ "$status" -eq 2 ]
  [ "$stderr" = "loop.sh: commit features.json first" ]
  [ "$(calls)" -eq 0 ]
}

@test "R15 refuses to start when a feature has no usable test id" {
  for bad in '.[1].test = ""' 'del(.[1].test)' '.[1].test = null' '.[1].test = "a b"' '{features: .}'; do
    features_json | jq "$bad" > features.json
    git commit -qam "bad test id: $bad"
    run --separate-stderr ./loop.sh
    [ "$status" -eq 2 ]
    [ "$stderr" = "loop.sh: every feature in features.json needs a test id without spaces" ]
  done
  [ "$(calls)" -eq 0 ]
}
