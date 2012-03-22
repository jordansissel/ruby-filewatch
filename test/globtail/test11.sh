#!/bin/sh
#
# Test: multiple instances 
# Description: running tails to simulate the effect of input {  file { path => ... } file { path => ...  } file { path => ...  } }
#  checks that the sincedb reflects the processed state
# 

. $(dirname $0)/framework.sh

test_multi_start() {
# need a unique arg. doesn't support many tests of same file
[ $# -eq 0  ] && exit 99
echo $TAIL
$TAIL "$TEST_DIR/$1" >>$(mktemp --tmpdir=${TEST_DIR}  multi_XXXXXXXX) 2>&1 &
[ "$TEST_MULTI_TAIL_PID" ] && export TEST_MULTI_TAIL_PID=$TEST_MULTI_TAIL_PID,$! || export TEST_MULTI_TAIL_PID=$!
}

test_multi_stop() {
OLD_TEST_TAIL_PID=$TEST_TAIL_PID

# if no args stop them all
[ $# -eq 0  ] && { echo "$TEST_MULTI_TAIL_PID" | tr "," "\n" | while read TEST_TAIL_PID; do test_stop 2>/dev/null ;done; export TEST_MULTI_TAIL_PID=; }
# or
[ $# -eq 1  ] && { TEST_TAIL_PID=$1; test_stop; }

export TEST_TAIL_PID=$OLD_TEST_TAIL_PID
}


test_init

# so not have to wait for discover
> $TEST_DIR/a.log
> $TEST_DIR/b.log

# start 2 threads watch 2 files.
test_multi_start a.log
test_multi_start b.log

# misses first logs without a sleep
sleep 1

# put something in both log files.
echo a1 >> $TEST_DIR/a.log
echo b1 >> $TEST_DIR/b.log

# allow both tails to write out their SINCEDB
sleep 5

# stop everything (instances write out their sincedb also on shutdown?)
test_multi_stop

# make a aggregate log file for use by test harness
cat $TEST_DIR/multi_* > $TEST_OUT

# Status: draft
# if there is a bashism for finding the number jruby is using for dev_major and dev_minor? (is not the same as lstat output)
# or i just check  the inodes and sizes for a simple test
# this check wont create accurate lists for tests with files with truncations, and deletes during the tests
# a more sophisticated would be required to track inode changes etc
#
filelist=$(sed -e "s,^${TEST_DIR}/,," -e '/^D, \[/d' $TEST_OUT | awk '{print $1}' | awk -F ":" '{print $1}' | sort -u)
if [ $(cat $SINCEDB | egrep "^" | wc -l) -ne $(echo "$filelist" | egrep "^" | wc -l)  ]; then
errs=$errs"ERROR: file count for sincedb not match count of files processed\n"
errs=$errs"sincedb file count: $(cat $SINCEDB | egrep "^" | wc -l)\n"
errs=$errs"filelist file count: $(echo "$filelist" | egrep "^" | wc -l)\n"
fi

# ridiculous subshell f****y
errs=$errs$(
echo "$filelist" | while read file; do
inode=`stat --printf="%i" ${TEST_DIR}/$file`
disk_size=`stat --printf="%s" ${TEST_DIR}/$file`
egrep "^$inode " $SINCEDB >/dev/null || { echo "File $file not found in sincedb"; continue; }
sincedb_size=$(egrep "^$inode" $SINCEDB | awk '{print $4}')
echo "Filename: $file Inode: $inode DiskSize: $disk_size SinceDB_size: $sincedb_size" 1>&2
[ $sincedb_size -eq $disk_size ] || { echo "File $file size mismatch $disk_size != "; continue; }
done
)
 

[ "$errs" ] && echo -e "Sincedb not match filelist\n${errs}" >> $TEST_OUT




test_done



