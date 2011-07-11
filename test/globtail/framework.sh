#!/bin/sh

test_init() {
  export TEST_BASE=$(dirname $0)
  export FW_BASE="$TEST_BASE/../.."
  export RUBYLIB=$FW_BASE/lib:$RUBYLIB
  export TAIL="$FW_BASE/bin/globtail"
  export TEST_DIR=$(mktemp -d)
  export TEST_OUT=$(mktemp)
  $TAIL "$TEST_DIR/*" >$TEST_OUT 2>&1 &
  export TEST_TAIL_PID=$!
}

test_done() {
  kill $TEST_TAIL_PID

  output=$(mktemp)
  sed -e "s,^${TEST_DIR}/,," $TEST_OUT | sort > $output

  data_file=$(echo $0 | sed -e 's/\.sh$/.data/')
  diff -u $TEST_BASE/$data_file $output
  diff_rc=$?
  rm -rf $TEST_DIR $TEST_OUT $output
  if [ $diff_rc -ne 0 ]; then
    echo "$0 TEST FAILURE (output differs)"
    exit 1
  fi
  exit 0
}
