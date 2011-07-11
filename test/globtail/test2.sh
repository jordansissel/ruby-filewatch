#!/bin/sh

. $(dirname $0)/framework.sh

test_init

echo a > $TEST_DIR/a.log
sleep 8
mv $TEST_DIR/a.log $TEST_DIR/b.log
sleep 8
echo b >> $TEST_DIR/b.log
sleep 3

test_done
