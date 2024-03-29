#!/bin/bash

if [ -z "$_CXX_" ] ; then
    _CXX_="g++"
fi

if [ -f .circleci/local-config ] ; then
    source .circleci/local-config
fi

function insudo {
    user=`whoami`
    if [ "$user" = "root" ] ; then
		"$@"
		return $?
    fi
    if [ ! -x /usr/bin/sudo ] ; then
		echo "Sudo not installed and installation not possible as regular user"
		exit 1
    fi
    /usr/bin/sudo "$@"
    return $?
}

function usage { 
	echo "usage: `basename $0` step [step] ..." >&2
	echo "where steps are executed in order given and might be one of:" >&2
	echo "  deps         Prepare for building such as installation of dependencies" >&2
	echo "  rpm          Build rpms and move over to directory defined by DISTDIR" >&2
	echo "  install      Install all files in DISTDIR" >&2
	echo "  testprep     Prepare for testing i.e. install dependencies" >&2
	echo "               Also links library files to test to work dir" >&2
	echo "  test         Run make test" >&2
	echo "  target param Run build of provided make target (exactly one parameter" >&2
	echo "               must be provided)" >&2
	echo "">&2
	echo "DISTDIR=$DISTDIR" >&2
	exit 1
}

# Number of jobs to use in make
if [ "$CIRCLE_BUILD_NUM" ] ; then
	# Running inside real CircleCI cloud service(not local simulation/other CI system)
	# CircleCI cloud shows excessive amounts of CPUs but has very little memory
	# Using multiple jobs will cause out-of-memory errors and compiles will fail.
        # Limit the amount of CPUs to use there. Allow override for current project
        # when provided
        if [ -z "$RPM_BUILD_NCPUS" ] ; then
	    RPM_BUILD_NCPUS=3
	fi
else
	# Local builds don't have a build number
	# Using the maximum available
	RPM_BUILD_NCPUS=`fgrep processor /proc/cpuinfo | wc -l`
fi
export RPM_BUILD_NCPUS
echo RPM_BUILD_NCPUS=$RPM_BUILD_NCPUS

# Define DISTDIR
test -d "$DISTDIR/." || insudo mkdir -p "$DISTDIR"
export DISTDIR

# Enable smartmet-open-staging if .circleci/enable-staging is found and contains name of
# of current GIT branch at the start of line (note enabling staging for master branch is
# intentionally excluded from this)
if [ -f .circleci/enable-staging ] ; then
    if [ -x /usr/bin/git ] ; then
        branch=$(git branch | awk 'substr($0,0,1)=="*" {print $2}')
        if ! [ -z "$branch" ] ; then
            if [ "$branch" != "master" ] ; then
                if grep -P "^${branch}(|\s.*)\$" .circleci/enable-staging >/dev/null ; then
                    echo ".circleci/enable-staging contains current branch $branch: enabling smartmet-open-staging"
                    insudo yum-config-manager --verbose --enable smartmet-open-staging
                fi
            fi
        fi
    fi
fi

# Help
if [ "$#" -lt "1" ] ; then usage ; fi

# Quick test disable: if this file exists, won't run make test
test_disable=.circleci/disable-tests-in-ci

# Workaround for apparent ccache race condition
# Apparently, when ccache directory is completely empty, and multiple compilations are run simultanously,
# a compilation may fail with an error indication ccache.conf is missing from the ccache directory.
# However, this is normally created automatically. Perhaps simultanous runs break this.
# Force creation of the file by checking statistics here.
# Statictics are discarded, it just will create the file, if needed, as a side-effect.
ccache -s >/dev/null 2>&1 || true

# Search for the root of build tree but stop when in system root
depthlimit=20
while [ ! -d .git -a "$depthlimit" -gt "0"  ] ; do
	cd ..
	depthlimit=`expr $depthlimit - 1`
done
if [ ! -d .git ] ; then
	echo "This is not a git source tree"
	exit 1
fi
echo "Source tree base is in `pwd`"

# Not supported on older git versions:
# echo "Git origin is `git remote get-url origin`"
echo "Git origin is `git config --get remote.origin.url`"

# Try to find/create suitable directory for build time distribution files
if [ -z "$DISTDIR" ] ; then
    test ! -d "/dist" || DISTDIR="/dist"
    test ! -d "/root/dist" || DISTDIR="/root/dist"
    test ! -d "$HOME/dist" || DISTDIR="$HOME/dist"
    test -n "$DISTDIR" || DISTDIR="/dist" # The default
fi
insudo chown `id -u` "$DISTDIR/."

# Make sure we are using proxy, if that is needed
test -z "$http_proxy" || (
    grep -q "^proxy=" /etc/yum.conf || \
       echo proxy=$http_proxy | \
           insudo tee -a /etc/yum.conf
)
test ! -x /usr/local/bin/proxydetect || . /usr/local/bin/proxydetect
test ! -x /usr/local/bin/proxydetect || insudo /usr/local/bin/proxydetect

set -ex
echo DISTDIR: $DISTDIR

# Make sure ccache is actually writable if it is available
if [ -d /ccache ] ; then
    test -w /ccache/. || sudo chown -R `id -u` /ccache/.
fi

while ! [ -z "$*" ] ; do
    step=$1
    shift
    case $step in
	install)
	    insudo yum install -y $(ls -1 $DISTDIR/*.rpm | grep -v src.rpm)
	    ;;
	deps)
	    insudo yum -y clean all
	    insudo yum-builddep --disablerepo="*source*" -y *.spec
	    ;;
	testprep)
	    # Symbolically link already installed smartmet .so and .a files here
	    find /usr/share/smartmet -name \*.so | \
               xargs --no-run-if-empty -I LIB -P 10 -n 1 ln -svf LIB .
        rpm -qal | grep 'smartmet-[^/]*[.]so$' | \
               xargs --no-run-if-empty -I LIB -P 10 -n 1 ln -svf LIB .
        rpm -qal | grep 'smartmet-[^/]*[.]a$' | \
               xargs --no-run-if-empty -I LIB -P 10 -n 1 ln -svf LIB .
        insudo yum install -y git make || true # Install make regardless but ignore errors
	    sed -e 's/^BuildRequires:/#BuildRequires:/' -e 's/^#TestRequires:/BuildRequires:/' < *.spec > /tmp/test.spec
	    insudo yum-builddep -y /tmp/test.spec
	    ;;
	test)
	    test -r $test_disable && (
	       set +x 
	       echo "Test step disabled by existence of $test_disable, remove to enable tests"
	       cat $test_disable  ) || CXX="${_CXX_}" make -j "$RPM_BUILD_NCPUS" test
	    ;;
	target)
	    target=$1;
	    shift;
	    if [ -r .circleci/${target}_disable ] ; then
		set +x
		echo "target $target step disabled by existence of ${target}_disable, remove to enable the step"
	    else
		CXX="${_CXX_}" make -j "$RPM_BUILD_NCPUS" $target
	    fi
	    ;;
	rpm)
            set +x
	    CXX=${_CXX_} make -j "$RPM_BUILD_NCPUS" rpm
	    tmpd=`mktemp -d`
	    for d in /root/rpmbuild $HOME/rpmbuild ; do
			test ! -d "$d" || find "$d" -name \*.rpm -exec sudo mv -v {} "$tmpd" \;
	    done
            mkdir -p $HOME/dist
            mname=$(basename *.spec .spec)
	    mfile="$DISTDIR/$mname.lst"
	    echo Creating $mfile
	    pushd .
            cd "$tmpd"
	    ls *.rpm > "$mfile"
	    popd
            echo "List of RPMs produced:"
            cat "$mfile"
            mv $(ls -1 $tmpd/*.rpm | grep -v src.rpm) "$DISTDIR"
	    echo "Distribution files and file list are now in $DISTDIR"
	    ;;
	dummy)
	    # Do nothing but may have modified yum.conf etc.
	    ;;
	*)
	    echo "Unknown build step $step"
	    ;;
    esac
done
