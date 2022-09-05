#!/bin/bash
#
# This script does some testing of atftp server and client.
# It needs ~150MB free diskspace in $TEMPDIR
#
# Some Tests need root access (e.g. to mount a tempfs filesystem)
# and need sudo for this, so the script might asks for a password.
# Use:
#         --interactive
# as argument or set:
#         INTERACTIVE="true"
# in the environment to run these tests.
# By default, all generated files and directories are removed at the end.
# To skip this cleanup, use:
#         --no-cleanup
# as argument or set:
#         CLEANUP="false"
# in the environment.

set -eu

# Assume we are called in the source tree after the build.
# Binaries are one dir up:
ATFTP=../atftp
ATFTPD=../atftpd

# Try installed binaries, if binaries are not available:
for EX in ATFTP ATFTPD ; do
    cmd=$(basename ${!EX})
    if [[ ! -x ${!EX} ]] ; then
        eval $EX="$(command -v "$cmd")"
        echo "Using installed $cmd binary '${!EX}'."
    else
        echo "Using $cmd from build directory '${!EX}'."
    fi
done

# Set some defaults:
: "${HOST:=127.0.0.1}"
: "${PORT:=2001}"
: "${TEMPDIR:="/tmp"}"
TDIR=$(mktemp -d ${TEMPDIR}/atftp-test.XXXXXX)
echo "Server root directory is '$TDIR'."
SERVER_ARGS="--daemon --no-fork --logfile=/dev/stdout --port=$PORT \
                      --verbose=6 --pcre $TDIR/PCRE_pattern.txt $TDIR"
SERVER_LOG=./atftpd.log
ERROR=0
WRITE="write.bin"
OUTBIN="00-out"

# Number of parallel clients for high server load test
: "${NBSERVER:=200}"

# Options:
: "${CLEANUP:=true}"
: "${INTERACTIVE:=false}"
: "${MCASTCLNTS:=}"
[[ "$@" =~ no-cleanup ]] && CLEANUP="false"
[[ "$@" =~ interactive ]] && INTERACTIVE="true"

## Some replacement patterns:
DICT='^[p]?pxelinux.cfg/[0-9A-F]{1,6}$  pxelinux.cfg/default
^[p]?pxelinux.0$                  pxelinux.0
linux                             linux
PCREtest                          2K.bin
^str$                             replaced1
^str                              replaced2
str$                              replaced3
repl(ace)                         m$1
^\w*\.conf$                       master.conf
(PCRE-)(.*)(-test)                $2.bin'

echo "$DICT" > "$TDIR/PCRE_pattern.txt"

## Some test patterns:
PAT="stronestr
PCRE-READ_2K-test
ppxelinux.cfg/012345
ppxelinux.cfg/678
ppxelinux.cfg/9ABCDE
ppxelinux.cfg/9ABCDEF
pppxelinux.0
pxelinux.cfg/F
linux
something_linux_like
str
strong
PCREtest
validstr
doreplacethis
any.conf"

######### Functions #########

start_server() {
    # start a server
    echo -n "Starting 'atftpd "${SERVER_ARGS/ \*/ /}"', "
    $ATFTPD $SERVER_ARGS > $SERVER_LOG &
    if [ $? != 0 ]; then
	echo "Error starting server."
	exit 1
    fi
    sleep 1
    ATFTPD_PID=$!
    # test if server process exists
    if ! ps -p $ATFTPD_PID >/dev/null 2>&1 ; then
	echo "Server process died!"
	exit 1
    fi
    echo "PID: $ATFTPD_PID"
    trap stop_and_clean EXIT SIGINT SIGTERM
}

stop_server() {
	echo "Stopping atftpd server"
	kill $ATFTPD_PID
}

check_file() {
	if cmp "$1" "$2" 2>/dev/null ; then
		echo "OK"
	else
		echo "ERROR - $1 $2 not equal!"
		ERROR=1
	fi
}

check_trace() {
    local LOG="$1" FILE="$2" oack tsize wsize bsize c d e
    oack=$(grep "OACK" "$LOG")
    tsize=$(echo "$oack" | sed -n -E "s/.*tsize: ([0-9]+).*/\1/p")
    wsize=$(echo "$oack" | sed -n -E "s/.*windowsize: ([0-9]+).*/\1/p")
    bsize=$(echo "$oack" | sed -n -E "s/.*blksize: ([0-9]+).*/\1/p")
    c=$(grep -c "DATA <block:" "$LOG")
    d=$(grep -c "ACK <block:" "$LOG")
    e=$(grep -c "sent ACK <block: 0>" "$LOG" || true)
    ## defaults, if not found in OACK:
    : "${tsize:=$(stat --format="%s" "${FILE}" | cut -d ' ' -f5)}"
    : "${wsize:=1}"
    : "${bsize:=512}"
    ## e is for the ACK of the OACK
    ## the +1 is the last block, it might be empty and ist ACK'd:
    if [[ $((tsize/bsize + 1)) -ne $c ]] || \
           [[ $((tsize/(bsize*wsize) + 1 + e)) -ne $d ]] ; then
        echo -e "\nERROR: expected blocks: $((tsize/bsize + 1)), received/sent blocks: $c"
        echo "ERROR: expected ACKs: $((tsize/(bsize*wsize) + 1)), sent/received ACKs: $((d-e))"
        ERROR=1
    else
        echo -en " $c blocks, $((d-e)) ACKs\t→ "
    fi
}

get_put() {
    local FILE="$1"
    shift
    echo -en "  get: ${FILE}\t${@//--option/}\t... "
    if [[ "$@" =~ trace ]] ; then
        stdout="${TDIR}/${WRITE}.stdout"
    else
        stdout="/dev/null"
    fi
    $ATFTP "$@" --get --remote-file "${FILE}" \
           --local-file "$OUTBIN" $HOST $PORT 2> $stdout
    if [[ -f "$stdout" ]] ;  then
        check_trace "$stdout" "$OUTBIN"
    fi
    check_file "${TDIR}/${FILE}" "$OUTBIN"

    echo -en "  put: ${FILE}\t${@//--option/}\t... "
    $ATFTP "$@" --put --remote-file "$WRITE" \
           --local-file "${TDIR}/${FILE}" "$HOST" "$PORT" 2> $stdout
    if [[ -f "$stdout" ]] ;  then
        check_trace "$stdout" "${TDIR}/${FILE}"
    fi
    # wait a second because in some case the server may not have time
    # to close the file before the file compare:
    #sleep 1 ## is this still needed?
    check_file "${TDIR}/${FILE}" "${TDIR}/${WRITE}"
}

perl-replace (){
    local STR=$1 FILE=$2 P R RES MATCH CMD
    while read -r LINE; do
        P="$(echo "$LINE" | sed -nE "s/\s+\S+$//p")"
        R="$(echo "$LINE" | sed -nE "s/^\S+\s+//p")"
        RES="$(perl -e "\$x = \"$STR\"; \$x =~ s#$P#$R#; print \"\$x\";")"
        CMD="perl -e '\$x = \"$STR\"; \$x =~ s#$P#$R#; print \"\$x\\n\";'"
        MATCH=$(perl -e "if(\"$STR\" =~ m#$P#){print \"yes\";}")
        if [[ -n "$MATCH" ]] ; then
            break
        fi
    done < "$FILE"
    echo "$RES|$CMD"
}

######### Tests #########
test_get_put(){
    echo -e "\n===== Test get and put with standard options:"
    for FILE in 0 "${TFILE[@]}" ; do
        get_put "${FILE}.bin"
    done

    echo -e "\n===== Test get and put with misc blocksizes:"
    get_put 50K.bin --option "blksize 8"
    get_put 50K.bin --option "blksize 256"
    get_put 100M.bin --option "blksize 1428"
    get_put 1M.bin --option "blksize 1533"
    get_put 1M.bin --option "blksize 16000"
    get_put 1M.bin --option "blksize 40000"
    get_put 1M.bin --option "blksize 65464"

    echo -e "\n===== Test get and put with misc windowsizes:"
    ## add some options here to allow trace analysis:
    get_put 2K.bin --option "windowsize 1" --option "tsize 0" --option "blksize 1024" --trace
    get_put 2K.bin --option "windowsize 2" --option "tsize 0" --option "blksize 512" --trace
    get_put 2K.bin --option "windowsize 4" --option "tsize 0" --option "blksize 256" --trace
    get_put 128K.bin --option "windowsize 8" --option "tsize 0" --option "blksize 1024" --trace
    get_put 128K.bin --option "windowsize 16" --option "tsize 0" --option "blksize 512" --trace
    get_put 100M.bin --option "windowsize 32" --option "tsize 0" --option "blksize 1428" --trace
    get_put 1M.bin --option "windowsize 5" --option "tsize 0" --option "blksize 1428" --trace

    echo -e "\n===== Test large file with small blocksize so block numbers will wrap over 65536:"
    get_put 1M.bin --option "blksize 8" --trace
}

check_error(){
    local OUTPUTFILE="$1" EXPECTED="${2:-<Failure to negotiate RFC2347 options>}"
    if grep -q "$EXPECTED" "$OUTPUTFILE" ; then
	echo OK
    else
	echo ERROR:
	ERROR=1
    fi
}

test_options(){
    echo -en "\n===== Test detection of non-existing file name ... "
    OUTPUTFILE="01-out"
    set +e
    $ATFTP --trace --get -r "thisfiledoesntexist" -l /dev/null $HOST $PORT 2> "$OUTPUTFILE"
    set -e
    check_error "$OUTPUTFILE" "<File not found>"

    echo -e "\n===== Test for invalid blksize options ..."
    # maximum blocksize is 65464 as described in RCF2348
    OUTPUTFILE="02-out"
    echo -n "  smaller than minimum ... "
    set +e
    $ATFTP --option "blksize 7" --trace --get -r "2K.bin" -l /dev/null $HOST $PORT 2> "$OUTPUTFILE"
    set -e
    check_error "$OUTPUTFILE"
    echo -n "  bigger than maximum ... "
    set +e
    $ATFTP --option "blksize 65465" --trace --get -r "2K.bin" -l /dev/null $HOST $PORT 2> "$OUTPUTFILE"
    set -e
    check_error "$OUTPUTFILE"

    echo -e "\n===== Test timeout option limit ... "
    OUTPUTFILE="04-out"
    echo -n "  minimum ... "
    set +e
    $ATFTP --option "timeout 0" --trace --get -r "2K.bin" -l /dev/null $HOST $PORT 2> "$OUTPUTFILE"
    set -e
    check_error "$OUTPUTFILE"
    echo -n "  maximum ... "
    set +e
    $ATFTP --option "timeout 256" --trace --get -r "2K.bin" -l /dev/null $HOST $PORT 2> "$OUTPUTFILE"
    set -e
    check_error "$OUTPUTFILE"

    echo -ne "\n===== Test tsize option ... "
    OUTPUTFILE="03-out"
    $ATFTP --option "tsize" --trace --get -r "2K.bin" -l /dev/null $HOST $PORT 2> "$OUTPUTFILE"
    TSIZE=$(grep "OACK <tsize:" "$OUTPUTFILE" | sed -e "s/[^0-9]//g")
    S="$(stat --format="%s" "$TDIR/2K.bin")"
    if [ "$TSIZE" != "$S" ]; then
	echo "ERROR (server report $TSIZE bytes but it should be $S)"
	ERROR=1
    else
	echo "OK"
    fi
}

test_unreachable(){
    echo -en "\n===== Test return code after timeout when server is unreachable ... "
    # We assume there is no tftp server listening on 127.0.0.77, returncode must be 255.
    local OUTPUTFILE="05-out" RET
    set +e
    $ATFTP --put --local-file "2K.bin" 127.0.0.77 2>"$OUTPUTFILE"
    RET=$?
    set -e
    echo -n "return code: $RET → "
    if [ $RET -eq 255 ]; then
	echo "OK"
    else
	echo "ERROR"
	ERROR=1
    fi
}

test_diskspace(){
    # Test behaviour when disk is full.
    # Preparation: Create a small ramdisk. We need the "sudo" command for that.
    local DIR="${TDIR}/small_fs" FILE="$TDIR/1M.bin" RET SUDO
    echo -en "\n===== Test disk-out-of-space ...\nPrepare filesystem → "
    mkdir -v "$DIR"
    if [[ $(id -u) -eq 0 ]]; then
	SUDO=""
    else
	SUDO="sudo"
	echo "  Trying to mount ramdisk, 'sudo' may ask for a password!"
    fi
    $SUDO mount -t tmpfs shm "$DIR" -o size=500k
    echo "  Disk space before test: $(LANG=C df -k -P "${DIR}" | grep "${DIR}" | awk '{print $4}') kiB."
    echo "  Exceed server disk space by uploading '$FILE':"
    set +e
    $ATFTP --put --local-file "$FILE" --remote-file "small_fs/fillup.bin" $HOST $PORT
    RET=$?
    set -e
    echo -n "  Return code: $RET → "
    if [ $RET -ne 0 ]; then
	echo "OK"
    else
	echo "ERROR"
	ERROR=1
    fi
    rm "$TDIR/small_fs/fillup.bin"
    echo "  Exceed 'local' disk space by downloading '$(basename "$FILE")':"
    set +e
    $ATFTP --get --remote-file "$(basename "$FILE")" \
           --local-file "$TDIR/small_fs/fillup-put.bin" $HOST $PORT
    RET=$?
    set -e
    echo -n "  Return code: $RET → "
    if [ $RET -ne 0 ]; then
	echo "OK"
    else
	echo "ERROR"
	ERROR=1
    fi
    $SUDO umount "$DIR"
    rmdir "$DIR"
}

test_timeout(){
    local OUTPUTFILE="06-out" OLD_ARGS C
    echo -en "\n===== Test timeout ...\n  Restart the server with full logging.\n  "
    stop_server
    OLD_ARGS="$SERVER_ARGS"
    SERVER_ARGS="${SERVER_ARGS//--verbose=?/--verbose=7}"
    SERVER_ARGS="${SERVER_ARGS//--pcre*PCRE_pattern.txt/}"
    echo -n "  " ; start_server
    $ATFTP --option "timeout 1" --delay 200 --get -r "2K.bin" \
           -l /dev/null $HOST $PORT 2> /dev/null &
    CPID=$!
    sleep 1
    kill -s STOP $CPID
    echo -n "  Running tests "
    for i in $(seq 6); do
	sleep 1
	echo -n "."
    done
    echo
    kill $CPID
    echo -n "  " ; stop_server ; sleep 1
    C=$(grep "timeout .\+ retrying" $SERVER_LOG | cut -d " " -f 3 | tee "$OUTPUTFILE" | wc -l)
    SERVER_ARGS="$OLD_ARGS"
    echo -n "  " ; start_server
    if [ "$C" = 5 ]; then
        prev=0
        res="  → OK"
        while read -r line; do
            hrs=$(echo "$line" | cut -d ":" -f 1)
            min=$(echo "$line" | cut -d ":" -f 2)
            sec=$(echo "$line" | cut -d ":" -f 3)
            cur=$(( 24*60*10#$hrs + 60*10#$min + 10#$sec ))
            if [ $prev -gt 0 ]; then
                if [ $((cur - prev)) != 1 ]; then
                    res="  ERROR: delay not one second."
                    ERROR=1
                fi
            fi
            prev=$cur
        done < "$OUTPUTFILE"
        echo "  $res"
    else
        ERROR=1
        echo "    ERROR: $C lines found, expected 5."
    fi
}

test_PCRE(){
    echo -en "\n===== Test PCRE substitution ... "
    if diff -u <(echo "$PAT" | $ATFTPD --pcre-test <(echo "$DICT") | \
                     tr -d '"' | cut -d ' ' -f 2-4) \
            <(for P in $PAT ; do
                  echo -n "$P -> "
                  perl-replace "$P" <(echo "$DICT") | cut -d '|' -f1
              done)
    then
        echo OK
    else
        ERROR=1
        echo "ERROR"
    fi

    # Test a download with pattern matching:
    echo "  Test PCRE mapped download ... "
    for F in "PCREtest" "PCRE-512-test" ; do
        $ATFTP --get -r $F -l /dev/null $HOST $PORT
        L="$(grep "PCRE mapped" $SERVER_LOG | tail -1 | cut -d ' ' -f6-)"
        if [[ "$L" =~ 'PCRE mapped PCRE'.*'test -> '.+'.bin' ]] ; then
            echo "    $L → OK"
        else
            ERROR=1
            echo "    ERROR: $L"
        fi
    done
}

test_highload(){
    echo -e "\n===== Test high server load ... "
    echo -n "  Starting $NBSERVER simultaneous atftp get processes "
    set +e
    for i in $(seq 1 $NBSERVER) ; do
        [[ $(( i%10 )) = 0 ]] && echo -n "."
        $ATFTP --get --remote-file "1M.bin" --local-file /dev/null $HOST $PORT \
               2> "$TDIR/high-server-load-out.$i" &
    done
    set -e
    echo " done."
    CHECKCOUNTER=0
    MAXCHECKS=90
    while [[ $CHECKCOUNTER -lt $MAXCHECKS ]]; do
	PIDCOUNT=$(pidof $ATFTP|wc -w)
	if [ "$PIDCOUNT" -gt 0 ]; then
	    echo "  Waiting for atftp processes to complete: $PIDCOUNT running."
	    CHECKCOUNTER=$((CHECKCOUNTER + 1))
	    sleep 1
	else
	    CHECKCOUNTER=$((MAXCHECKS + 1))
	fi
    done

    # high server load test passed, now examine the results
    true >"$TDIR/high-server-load-out.result"
    for i in $(seq 1 $NBSERVER); do
	# merge all output together
	cat "$TDIR/high-server-load-out.$i" >>"$TDIR/high-server-load-out.result"
    done

    # remove timeout/retry messages, they are no error indicator
    grep -v "timeout: retrying..." "$TDIR/high-server-load-out.result" \
         > "$TDIR/high-server-load-out.clean-result" || true

    # the remaining output is considered as error messages
    error_cnt=$(wc -l <"$TDIR/high-server-load-out.clean-result")

    # print out error summary
    if [ "$error_cnt" -gt "0" ]; then
	echo "Errors occurred during high server load test, # lines output: $error_cnt"
	echo "======================================================"
	cat "$TDIR/high-server-load-out.clean-result"
	echo "======================================================"
	ERROR=1
    else
	echo -e "    → OK"
    fi
    # remove all empty output files
    find "$TDIR" -name "high-server-load-out.*" -size 0 -delete
}

check-rlogs(){
    local CLNTS=$1 TOTAL=$2 NAME=$3 RLOG=$4 C
    echo -en "  Copy log file '$RLOG' from hosts: "
    for C in $CLNTS ; do
        echo -n "."
        scp -q "$C:$RLOG" "$TDIR/${NAME}-${C##*@}.log"
    done
    echo
    T=$(grep "/tmp/" "$TDIR"/${NAME}*.log | wc -l)
    if [[ $T = $TOTAL ]] ; then
        echo -e "\n  All $T $NAME downloads registered → OK"
    else
        ERROR=1
        echo "ERROR: Files missing:  $T != $TOTAL."
        echo "Did you wait long enough?"
    fi
    grep --no-filename "/tmp/" "$TDIR/${NAME}"*.log | sort | uniq | \
        sed -e "s# /tmp/# $TDIR/#" > "$TDIR/MD5SUMS"
    echo -n "  Check md5sums → "
    md5sum -c "$TDIR/MD5SUMS" | sed "s#$TDIR/##" | tr '\n' '\t'
}


test_multicast(){
    local F L M N=0 C NUM=10 FILE=("128K.bin" "50K.bin") NAME='multicast' L="/tmp/multicast.log"
    echo -e "\n===== Test multicast option ..."
    echo -en "  Run atftp on hosts: "
    for C in $MCASTCLNTS ; do
        echo -n "."
        F="${FILE[$((N%2))]}"
        ssh "$C" "rm -f $L ; for N in \$(seq $NUM) ; do ./atftp --option multicast \
                 --option 'blksize 500' --get -r $F -l /tmp/$F --trace $HOST $PORT 2>&1 \
                 | grep -C3 OACK >> $L ; md5sum /tmp/$F >> $L ; rm /tmp/$F ; done  " &
        N=$(( N + 1 ))
        sleep 0.02
    done
    echo ", fetching: ${FILE[@]}"
    sleep $(( 2*N ))
    TOTAL=$(( N * NUM ))

    check-rlogs "$MCASTCLNTS" "$TOTAL" "$NAME" "$L"

    ## detailed checks:
    M=$(grep --no-filename 'received OACK <mc = 1>' "$TDIR"/multicast*.log | wc -l)
    N=$(grep 'Client transferred to' "$SERVER_LOG" | wc -l)
    if [[ $M = $N ]] ; then
        echo -e "\n  Multicast client transfers detected: $M → OK"
    else
        ERROR=1
        echo -e "\nERROR: Multicast client transfers are inconsistent:  $M != $N."
    fi
}

test_mtftp(){
    local F I M N=0 P T C NUM=10 FILE=("linux" "pxelinux.0") MCASTIP=("239.255.1.1" "239.255.1.2")
    local NAME='mtftp' L="/tmp/multicast.log" TNUM
    echo -e "\n===== Test mtftp ..."
    [[ -e "$TDIR/linux" ]] || ln -sf  "$TDIR/128K.bin"  "$TDIR/linux"
    [[ -e "$TDIR/pxelinux.0" ]] || ln -sf "$TDIR/50K.bin" "$TDIR/pxelinux.0"
    stop_server
    OLD_ARGS="$SERVER_ARGS"
    SERVER_ARGS="${SERVER_ARGS//--verbose=?/--verbose=7}"
    SERVER_ARGS="${SERVER_ARGS//--pcre*PCRE_pattern.txt/--mtftp mtftp.conf --mtftp-port $((PORT + 1)) --trace}"
    echo -n "  " ; start_server

    echo -en "  Run atftp on hosts: "
    for C in $MCASTCLNTS ; do
        echo -n "."
        F="${FILE[$((N%2))]}"
        I="${MCASTIP[$((N%2))]}"
        ssh "$C" "rm -f $L ; for N in \$(seq $NUM) ; do ./atftp --mtftp 'client-port 3001' \
                 --mtftp 'mcast-ip $I' --mget -r $F -l /tmp/$F --trace $HOST 2002 2>&1 \
                 | grep 'got all packets' >> $L ; md5sum /tmp/$F >> $L ; rm /tmp/$F ; done" &
        sleep 0.02
        N=$(( N + 1 ))
    done
    echo ", fetching: ${FILE[@]}"

    sleep $(( 3 * N ))
    TOTAL=$(( N * NUM ))

    check-rlogs "$MCASTCLNTS" "$TOTAL" "$NAME" "$L"

    ## detailed checks:
    M=$(grep --no-filename 'got all packets' "$TDIR"/mtftp*.log | wc -l)
    N=$(grep 'mtftp: already serving this file' "$SERVER_LOG" | wc -l)
    P=$(grep 'received RRQ' "$SERVER_LOG" | wc -l)
    echo -e "\n  RRQs received: $P, but 'already served': $N"
    echo "  Received by just listening, no RRQ: $M"
    if [[ $((M+P-N)) = $T ]] ; then
        echo -e "\n  MTFTP client transfers consistent → OK"
    else
        ERROR=1
        echo -e "\nERROR: Multicast client transfers are inconsistent:  $M != $N."
    fi
}

stop_and_clean(){
    echo "========================================================"
    stop_server
    trap - EXIT SIGINT SIGTERM
    tail -n 14 "$SERVER_LOG" | cut -d ' ' -f6-
    echo
    ## +3 is for "Test tsize option ..." and "Test PCRE mapped download ... "
    ## +2 for diskspace tests:
    local M=$(grep "/tmp/" "$TDIR"/multicast*.log | wc -l)
    $INTERACTIVE && D=2
    cat <<EOF
Expected:
   number of errors:         $(( $(grep -c "\s\+check_error" "$0") + ${D:-0} ))
   number of files sent:     $(( $(grep -c "\s\+get_put" "$0") + ${#TFILE[@]} + NBSERVER + 3 + $M ))
   number of files received: $(( $(grep -c "\s\+get_put" "$0") + ${#TFILE[@]} ))

EOF

    if ! $CLEANUP ; then
	echo "No cleanup, files from test are left in $TDIR"
    else
    	echo -n "Cleaning up test files and logs ... "
	rm -fr "$TDIR" "$SERVER_LOG" ./??-out
        echo "done."
    fi
}

############### main #################

echo -n "Generate test files: "
touch "$TDIR/0.bin"
TFILE=(511 512 2K 50K 128K 1M 10M 100M)
for FILE in "${TFILE[@]}" ; do
    echo -n "${FILE}.bin "
    dd if=/dev/urandom of="$TDIR/${FILE}.bin" bs="${FILE}" count=1 2>/dev/null
done
echo "→ OK"
start_server

test_get_put
test_options
test_unreachable
test_PCRE
test_highload

if $INTERACTIVE ; then
    test_diskspace
else
    echo -e "\nDisk-out-of-space tests not performed.  Start with '--interactive' if desired."
fi

# Test that timeout is well set to 1 sec and works.
# We need atftp compiled with debug support to do that.
if $ATFTP --help 2>&1 | grep --quiet -- --delay ; then
    test_timeout
else
	echo -e "\nDetailed timeout test could not be done."
	echo "Compile atftp with debug support for more timeout testing."
fi

if [[ -n "$MCASTCLNTS" ]] && [[ "$HOST" != "127.0.0.1" ]]  ; then
    test_multicast
    test_mtftp
else
    cat <<EOF

To test multicast (RFC 2090) or MTFTP, you need to prepare some
hosts in the local network.  Make sure they have atftp available
and configure ssh pubkey login (without password).

Then run $0 like:

   MCASTCLNTS='user1@host1 … userN@hostN' HOST='192.168.2.100' $0

In addition, consider checking network traffic with tcpdump or
wireshark when running the command above.
EOF
fi

echo
stop_and_clean

if [ $ERROR -eq 1 ]; then
    echo "Errors have occurred!"
    exit 1
else
    cat <<EOF

     ###########################
     # Overall Test status: OK #
     ###########################

EOF
fi

# vim: ts=4:sw=4:autoindent
