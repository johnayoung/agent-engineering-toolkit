# Agent behaviors for STUB_ACTION scripts. Each runs in the repo, as the agent would.
# shellcheck shell=bash
# SC2016: these functions write shell code to files, so $ must not expand.
# shellcheck disable=SC2016

# flip <op>...: set passes:true on the features whose test is test_<op>.sh
flip() {
  local id
  for id in "$@"; do
    jq --arg id "$id" 'map(if (.test | tostring | test("/test_" + $id + "\\.sh$")) then .passes = true else . end)' \
      features.json > features.json.tmp && mv features.json.tmp features.json
  done
}

# implement <op>...: make calc.sh handle add and/or sub correctly
implement() {
  local op
  for op in "$@"; do
    case "$op" in
      add) printf 'add) echo $(( $2 + $3 )) ;;\n' >> ops.inc ;;
      sub) printf 'sub) echo $(( $2 - $3 )) ;;\n' >> ops.inc ;;
    esac
  done
  write_calc
}

write_calc() {
  {
    printf '#!/usr/bin/env bash\ncase "$1" in\n'
    cat ops.inc 2>/dev/null
    printf '*) echo "not implemented: $1" >&2; exit 1 ;;\nesac\n'
  } > calc.sh
}
