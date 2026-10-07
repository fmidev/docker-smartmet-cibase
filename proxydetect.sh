#!/bin/bash

# Detect whether an explicit proxy is needed and set up proxy environment
# variables (and yum proxy) accordingly. Intended to be sourced.
#
# Every network probe is strictly time limited and has stdin closed, so
# this can not hang in a restricted environment (e.g. CircleCI remote docker).

proxyfile=/tmp/proxysetup
fmi_proxy=http://wwwcache.fmi.fi:8080

# Returns 0 if network is reachable with current proxy settings
_proxydetect_probe() {
    timeout -s KILL 8 curl -s -o /dev/null --connect-timeout 3 --max-time 5 \
	https://www.google.com </dev/null >/dev/null 2>&1
}

# Setup proxy environment variables, if needed
if [ ! -r "$proxyfile" ] ; then
    (
	if ! _proxydetect_probe ; then
	    # Use FMI proxy only if it is resolvable from here
	    if getent hosts wwwcache.fmi.fi >/dev/null 2>&1 ; then
		https_proxy=$fmi_proxy
		http_proxy=$fmi_proxy
		ftp_proxy=$fmi_proxy
		export https_proxy http_proxy ftp_proxy
		_proxydetect_probe || { https_proxy=; http_proxy=; ftp_proxy=; }
	    fi
	fi

	if [ "$http_proxy" ] ; then
	    cat >"$proxyfile" <<EOT
https_proxy=$https_proxy
http_proxy=$http_proxy
ftp_proxy=$ftp_proxy
export https_proxy http_proxy ftp_proxy
EOT
	else
	    # No (working) proxy: create empty file so we do not probe again
	    touch "$proxyfile"
	fi
    ) </dev/null
fi
unset -f _proxydetect_probe

# Read already generated proxy settings
test ! -r "$proxyfile" || . "$proxyfile"

# Fix yum.conf if needed
test -z "$http_proxy" || test ! -w /etc/yum.conf || \
    grep -q "^proxy=" /etc/yum.conf || \
    echo "proxy=$http_proxy" >> /etc/yum.conf

true
