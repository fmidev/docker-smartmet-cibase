#!/bin/bash

targetuid=`id -u`
targetgid=`id -g`

# CircleCI CLI does not have -u parameter
# We can pass the host system uids via environment
if [ "$LOCALUID" ] ; then
	targetuid=$LOCALUID
	targetgid=${LOCALGID:-0}
fi

# Execute various prepartion steps when running something inside the container
if [ "$targetuid" != "0" ] ; then
	# Create a user for this user and make home available
	gosu 0 groupadd -o -g $targetgid g$targetgid
	gosu 0 useradd -o -m -u $targetuid -g $targetgid -s /bin/bash u$targetuid
	HOME=/home/u$targetuid
	export HOME
fi

# Make sure certain file permissions are ok on host system
if [  "$targetuid" != "0" ] ; then sudo chown -R $targetuid:$targetgid /var/cache/yum /ccache ; fi
test -e /etc/ccache.conf && \
  sudo chown -R $targetuid:$targetgid /etc/ccache.conf && \
  sudo chmod 777 /etc/ccache.conf


# Run as the target user, keeping the exit status of the command
if [ "$targetuid" != "`id -u`" ] ; then
	sudo -u u$targetuid "$@"
else
	"$@"
fi
status=$?

# Make sure certain file permissions are left ok on host system
if [  "$targetuid" != "0" ] ; then sudo chown -R $targetuid:$targetgid /var/cache/yum /ccache ; fi

exit $status
