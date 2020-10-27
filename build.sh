#!/bin/bash -ex

cd `dirname $0`
testfile=.buildage

# Force rebuild without cache every 24 hours
test ! -r "$testfile" || (
    if [ `stat --format=%Y $testfile` -le $(( `date +%s` - 86400 )) ] ; then
	rm -f "$testfile"
    fi
)

param=""

if [ -e "$testfile" ] ; then
	docker build --add-host smartmet-test:127.0.0.1 -t `cat imagename.txt` .
else
	docker build --add-host smartmet-test:127.0.0.1 --no-cache -t `cat imagename.txt` .
fi

# Create timestamp with current time if not already there
test ! -e "$testfile" && touch "$testfile"
exit 0
