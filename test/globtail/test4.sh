#!/bin/sh

. $(dirname $0)/framework.sh

test_init

echo 1 > $TEST_DIR/a.log
sleep 3
echo 2 >> $TEST_DIR/a.log
sleep 3
echo 3 >> $TEST_DIR/a.log
sleep 3
echo 4 > $TEST_DIR/a.log
sleep 3

test_done
