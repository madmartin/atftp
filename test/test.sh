#!/bin/bash

ATFTP=../atftp
ATFTPD=../atftpd
HOST=localhost
PORT=2001

DIRECTORY=/tmp

SERVER_ARGS="--daemon --no-fork --logfile=/dev/stdout --port=$PORT --verbose=6 $DIRECTORY"
SERVER_LOG=./atftpd.log

ERROR=0

# verify that atftp and atftpd are runnable
if [ ! -x $ATFTP ]; then
	echo "$ATFTP not found"
	exit 1
fi
if [ ! -x $ATFTPD ]; then
	echo "$ATFTPD not found"
	exit 1
fi

function start_server() {
    # start a server
    #echo "Starting atftpd server on port $PORT"
    $ATFTPD  $SERVER_ARGS > $SERVER_LOG &
    ATFTPD_PID=$!
    if [ $? != 0 ]; then
	echo "Error starting server"
	exit 1
    fi
    sleep 1
}

function stop_server() {
    #echo "Stopping server"
    kill $ATFTPD_PID
}


function check_file() {
    if cmp $1 $2 ; then
	echo OK
    else
	echo ERROR
	ERROR=1
    fi
}

function test_get_put() {
    echo -n "Testing get, $1 ($2)... "
    $ATFTP $2 --get -r $1 -l out.bin $HOST $PORT 2>/dev/null
    check_file $DIRECTORY/$1 out.bin
    echo -n "Testing put, $1 ($2)... "
    $ATFTP $2 --put -r $WRITE -l out.bin $HOST $PORT 2>/dev/null
    # because in some case the server may not have time to close the file
    # before the file compare.
    sleep 1
    check_file $DIRECTORY/$WRITE out.bin
}

function test_blocksize() {
    echo -n " block size $1 bytes ... "
    $ATFTP --option "blksize $1" --trace --get -r $READ_128K -l /dev/null $HOST $PORT 2> out
    if  [ `grep DATA out | wc -l` -eq $(( 128*1024 / $1 + 1)) ]; then
	echo OK
    else
	echo ERROR
	ERROR=1
    fi
}

# make sure we have /tftpboot with some files
if [ ! -d $DIRECTORY ]; then
	echo "create $DIRECTORY before running this test"
	exit 1
fi

# files needed
READ_0=READ_0.bin
READ_511=READ_511.bin
READ_512=READ_512.bin
READ_2K=READ_2K.bin
READ_BIG=READ_BIG.bin
READ_128K=READ_128K.bin
READ_1M=READ_1M.bin
WRITE=write.bin

echo -n "Creating test files ... "
touch $DIRECTORY/$READ_0
touch $DIRECTORY/$WRITE; chmod a+w $DIRECTORY/$WRITE
dd if=/dev/urandom of=$DIRECTORY/$READ_511 bs=1 count=511 2>/dev/null
dd if=/dev/urandom of=$DIRECTORY/$READ_512 bs=1 count=512 2>/dev/null
dd if=/dev/urandom of=$DIRECTORY/$READ_2K bs=1 count=2048 2>/dev/null
dd if=/dev/urandom of=$DIRECTORY/$READ_BIG bs=1 count=51111 2>/dev/null
dd if=/dev/urandom of=$DIRECTORY/$READ_128K bs=1K count=128 2>/dev/null
dd if=/dev/urandom of=$DIRECTORY/$READ_1M bs=1M count=1 2>/dev/null
echo "done"

start_server

#
# test get and put
#
test_get_put $READ_0
test_get_put $READ_511
test_get_put $READ_512
test_get_put $READ_2K
test_get_put $READ_BIG
test_get_put $READ_128K

#
# testing for invalid file name
#
echo ""
echo -n "Testing invalid file name ... "
$ATFTP --trace --get -r "thisfiledoesntexist" -l /dev/null $HOST $PORT 2> out
if grep -q "<File not found>" out; then
    echo OK
else
    echo ERROR
    ERROR=1
fi

#
# testing for blocksize
#
echo ""
echo "Testing blksize option ..."
echo -n " minimum ... "
$ATFTP --option "blksize 7" --trace --get -r $READ_2K -l /dev/null $HOST $PORT 2> out
if grep -q "<Failure to negotiate RFC1782 options>" out; then
    echo OK
else
    echo ERROR
    ERROR=1
fi
echo -n " maximum ... "
$ATFTP --option "blksize 65465" --trace --get -r $READ_2K -l /dev/null $HOST $PORT 2> out
if grep -q "<Failure to negotiate RFC1782 options>" out; then
    echo OK
else
    echo ERROR
    ERROR=1
fi

test_blocksize 8
test_blocksize 256
test_blocksize 1428
test_blocksize 16000
test_blocksize 64000
test_blocksize 65465

#
# testing fot tsize
#
echo ""
echo -n "Testing tsize option... "
$ATFTP --option "tsize" --trace --get -r $READ_2K -l /dev/null $HOST $PORT 2> out
TSIZE=`grep "OACK <tsize:" out | sed -e "s/[^0-9]//g"`
if [ "$TSIZE" != "2048" ]; then
    echo "ERROR (server report $TSIZE bytes but it should be 2048)"
else
    echo "OK"
    ERROR=1
fi

#
# testing for timeout
#
echo ""
echo "Testing timeout option limit..."
echo -n " minimum ... "
$ATFTP --option "timeout 0" --trace --get -r $READ_2K -l /dev/null $HOST $PORT 2> out
if grep -q "<Failure to negotiate RFC1782 options>" out; then
    echo OK
else
    echo ERROR
    ERROR=1
fi
echo -n " maximum ... "
$ATFTP --option "timeout 256" --trace --get -r $READ_2K -l /dev/null $HOST $PORT 2> out
if grep -q "<Failure to negotiate RFC1782 options>" out; then
    echo OK
else
    echo ERROR
    ERROR=1
fi

# Test that timeout is well set to 1 sec and works.
# Restart the server with full logging
if $ATFTP --help 2>&1 | grep --quiet -- --delay ; then
    stop_server
    OLD_ARGS=$SERVER_ARGS
    SERVER_ARGS="$SERVER_ARGS --verbose=7"
    start_server

    $ATFTP --option "timeout 1" --delay 200 --get -r $READ_2K -l /dev/null $HOST $PORT 2> /dev/null &
    CPID=$!
    sleep 1
    kill -s STOP $CPID
    echo -n "Testing timeout "
    for i in `seq 6`; do
	sleep 1
	echo -n "."
    done
    kill $CPID

    stop_server

    sleep 1
    grep "timeout: retrying..." $SERVER_LOG | cut -d " " -f 3 > out
    count=`wc -l out | cut -d "o" -f1`
    if [ $count != 5 ]; then
	ERROR=1
	echo "ERROR"
    else
	prev=0
	res="OK"
	while read line; do
	    hrs=`echo $line | cut -d ":" -f 1`
	    min=`echo $line | cut -d ":" -f 2`
	    sec=`echo $line | cut -d ":" -f 3`
	    cur=$(( 24*60*10#$hrs + 60*10#$min + 10#$sec ))
	
	    if [ $prev -gt 0 ]; then
		if [ $(($cur - $prev)) != 1 ]; then
		    res="ERROR"
		    ERROR=1
		fi
	    fi
	    prev=$cur
	done < out
	echo " $res"
    fi
    SERVER_ARGS=$OLD_ARGS
    start_server
else
    echo "Compile atftp with debug support for more timeout testing"
fi

#
# testing PCRE
#

#
# testing multicast
#

#echo ""
#echo -n "Testing multicast option  "
#for i in `seq 10`; do
#    echo -n "."
#    atftp --blksize=8 --multicast -d --get -r $READ_BIG -l out.$i.bin $HOST $PORT 2> /dev/null&
#done
#echo "OK"

#
# testing mtftp
#


#
# Test for high server load
#
NBSERVER=50
echo ""
echo -n "Testing high server load ... "
( for i in $(seq 1 $NBSERVER); do
    ($ATFTP --get -r $READ_1M -l /dev/null $HOST $PORT 2> out.$i)&
done )
error=0;
for i in $(seq 1 $NBSERVER); do
    if grep -q "timeout: retrying..." out.$i; then
	error=1;
    fi
done
if [ "$error" -eq "1" ]; then
    echo ERROR;
    ERROR=1
else
    echo OK
fi

stop_server

# cleanup
rm -f out*
rm -f $SERVER_LOG $DIRECTORY/$READ_0 $DIRECTORY/$READ_511 $DIRECTORY/$READ_512
rm -f $DIRECTORY/$READ_2K $DIRECTORY/$READ_BIG $DIRECTORY/$READ_128K $DIRECTORY/$READ_1M
rm -f $DIRECTORY/$WRITE

# Exit with proper error status
if [ $ERROR -eq 1 ]; then
    exit 1
else
    exit 0
fi
