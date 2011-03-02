#! /bin/sh
#
# atftpd - Script to launch atftpd server. Based on Skeleton.
#

PATH=/usr/local/sbin:/usr/local/bin:/sbin:/bin:/usr/sbin:/usr/bin
DAEMON=/usr/sbin/atftpd
NAME=atftpd
DESC="Advanced Trivial FTP server"
USE_INETD=true
OPTIONS=""

test -f $DAEMON || exit 0

set -e

if [ -f /etc/default/atftpd ]; then
    . /etc/default/atftpd
fi

if [ "$USE_INETD" = "true" ]; then
    exit 0;
fi

case "$1" in
  start)
	echo -n "Starting $DESC: "
	start-stop-daemon --start --oknodo --quiet --exec $DAEMON -- $OPTIONS
	echo "$NAME."
	;;
  stop)
	echo -n "Stopping $DESC: "
	start-stop-daemon --stop --oknodo --quiet --exec $DAEMON
	echo "$NAME."
	;;
  restart|reload|force-reload)
	echo -n "Restarting $DESC: "
	start-stop-daemon --stop --oknodo --quiet --exec $DAEMON
	sleep 1
	start-stop-daemon --start --oknodo --quiet --exec $DAEMON -- $OPTIONS
	echo "$NAME."
	;;
  *)
	N=/etc/init.d/$NAME
        echo "Usage: $N {start|stop|restart|reload|force-reload}" >&2
	exit 1
	;;
esac

exit 0
