#!/bin/bash -ex

cd `dirname $0`

VERSION=$1

testfile=.buildage

# Force rebuild without cache every 24 hours
test ! -r "$testfile" || (
    if [ `stat --format=%Y $testfile` -le $(( `date +%s` - 86400 )) ] ; then
	rm -f "$testfile"
    fi
)

param=""

if [ -e "$testfile" ] ; then
	docker build -t smartmet-cibase-${VERSION} -f Dockerfile.${VERSION} .
else
	docker build --no-cache -t smartmet-cibase-${VERSION} -f Dockerfile.${VERSION} .
fi

docker push smartmet-cibase-${VERSION}:latest

# Create timestamp with current time if not already there
test ! -e "$testfile" && touch "$testfile"
exit 0
