#!/bin/sh

. $(dirname $0)/framework.sh

test_init

echo a > $TEST_DIR/a.log
echo b > $TEST_DIR/b.log
echo c > $TEST_DIR/c.log
echo a >> $TEST_DIR/a.log
echo c >> $TEST_DIR/c.log

sleep 7

test_done
