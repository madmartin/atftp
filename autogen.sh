#!/bin/sh

AUTOCONF_REQUIRED_VERSION=2.5
AUTOMAKE_REQUIRED_VERSION=1.7

# this function taken from gimp plugin template
check_version ()
{
    if expr $1 \>= $2 > /dev/null; then
        echo "yes (version $1)"
    else
        echo "no  (version $1)"
        exit 1
    fi
}

echo -n "checking for autoconf >= $AUTOCONF_REQUIRED_VERSION ... "
if autoconf --version >/dev/null; then
    VER=$(autoconf --version | grep -iw autoconf | sed "s/.* \([0-9.]*\)[-a-z0-9]*$/\1/")
    check_version $VER $AUTOCONF_REQUIRED_VERSION
else
    echo "not found"
    exit 1
fi

echo -n "checking for automake >= $AUTOMAKE_REQUIRED_VERSION ... "
if automake --version >/dev/null; then
    VER=$(automake --version | grep -iw automake | sed "s/.* \([0-9.]*\)[-a-z0-9]*$/\1/")
    check_version $VER $AUTOMAKE_REQUIRED_VERSION
else
    echo "not found"
    exit 1
fi

aclocal
autoheader
automake
autoconf
