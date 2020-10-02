#!/bin/bash -ex

cd `dirname $0`

# Establish OS version
if grep -q -i "release 7" /etc/redhat-release ; then
  imagenamefile=imagename7.txt
elif grep -q -i "release 8" /etc/redhat-release ; then
  imagenamefile=imagename8.txt
else
  echo "Running neither RHEL7.x nor RHEL 8.x !"
  exit 1
fi


testfile=.buildage

# Force rebuild without cache every 24 hours
test ! -r "$testfile" || (
    if [ `stat --format=%Y $testfile` -le $(( `date +%s` - 86400 )) ] ; then
	rm -f "$testfile"
    fi
)

param=""

if [ -e "$testfile" ] ; then
	docker build -t $(cat $imagenamefile) .
else
	docker build --no-cache -t $(cat $imagenamefile) .
fi

# Create timestamp with current time if not already there
test ! -e "$testfile" && touch "$testfile"
exit 0
