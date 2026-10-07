#!/bin/bash
#
# Pre-install the external (non-smartmet) build and test dependencies of all
# SmartMet modules into a CI image.
#
# Usage: prebake-deps.sh MODULE_LIST [BRANCH]
#
# MODULE_LIST is a file with one module (GitHub repository) name per line.
# smartmet-* dependencies found in the spec files are followed recursively,
# so the list only needs to contain the top-level modules, but listing every
# module is harmless and makes the result independent of spec parsing.
#
# Strategy:
#   1. dnf builddep each spec and its #TestRequires with all repos enabled.
#      This pulls in smartmet-* packages from smartmet-open(-beta) together
#      with all of their external dependencies.
#   2. Remove the packages of the modules built in CI again (rpm -e --nodeps).
#      CI jobs must build against the RPMs produced in the same workflow, never
#      against whatever happened to be in smartmet-open when the image was
#      built. Other smartmet-* packages (e.g. smartmet-SFCGAL-libs) are kept,
#      and the build fails if anything that stays has lost a dependency.
#   3. Keep the dnf metadata cache so that jobs do not need to download it.
#
# Failures of individual specs are reported but do not fail the image build:
# a missing dependency is merely installed at job run time as before.

set -uo pipefail

modlist="$1"
branch="${2:-master}"

# Same ignore list as ci-config-rebuild.pl in smartmet-rpm-build-all
declare -A seen
for m in smartmet-fonts smartmet-test-data smartmet-topography-data \
         smartmet-qdtools-test-data smartmet-engine-grid-test smartmet-library-grid-files-test \
         smartmet-SFCGAL-libs smartmet-library-spine-plugin-test smartmet-trajectory-formats \
         smartmet-trajectory smartmet-library-newbase-python ; do
    seen[$m]=ignored
done

specdir=$(mktemp -d)
queue=()
failed=()

for m in $(grep -v '^#' "$modlist") ; do queue+=("$m") ; done

# Discover modules recursively and download their spec files
while [ ${#queue[@]} -gt 0 ] ; do
    m="${queue[0]}"
    queue=("${queue[@]:1}")
    [ -n "${seen[$m]:-}" ] && continue
    seen[$m]=1

    spec="$specdir/$m.spec"
    url="https://raw.githubusercontent.com/fmidev/$m/$branch/$m.spec"
    if ! curl -fsSL --retry 5 --retry-delay 5 -o "$spec" "$url" ; then
        echo "WARNING: could not download $url"
        rm -f "$spec"
        continue
    fi

    for dep in $(grep -E '^(BuildRequires|Requires|#TestRequires):' "$spec" | \
                     grep -oE 'smartmet-[A-Za-z0-9_.+-]+' | sed -e 's/-devel$//' | sort -u) ; do
        [ -z "${seen[$dep]:-}" ] && queue+=("$dep")
    done
done

echo "Downloaded $(ls "$specdir" | wc -l) spec files"

dnf -y update

for spec in "$specdir"/*.spec ; do
    m=$(basename "$spec" .spec)
    echo "=== Build dependencies of $m"
    dnf builddep -y --skip-unavailable --disablerepo='*source*' "$spec" || failed+=("$m")

    if grep -q '^#TestRequires:' "$spec" ; then
        echo "=== Test dependencies of $m"
        sed -e 's/^BuildRequires:/#BuildRequires:/' -e 's/^#TestRequires:/BuildRequires:/' \
            < "$spec" > "$specdir/test.spec.tmp"
        dnf builddep -y --skip-unavailable --disablerepo='*source*' "$specdir/test.spec.tmp" || failed+=("$m(test)")
        rm -f "$specdir/test.spec.tmp"
    fi
done

# Source package names of the modules built in CI. Their binary packages
# (including subpackages such as -devel) must not stay in the image. Other
# smartmet-* packages, such as smartmet-SFCGAL-libs needed by gdal, are
# external dependencies like any other and are kept.
declare -A built
for spec in "$specdir"/*.spec ; do
    name=$(rpmspec -q --srpm --qf '%{NAME}\n' "$spec" 2>/dev/null | tail -1)
    built[${name:-$(basename "$spec" .spec)}]=1
done

# Large data-only packages are dropped as well to keep the image small.
# Test jobs install them from smartmet-open-noarch when needed.
remove=()
while read -r pkg srpm ; do
    src=$(echo "$srpm" | sed -e 's/-[^-]*-[^-]*\.src\.rpm$//')
    case "$pkg" in
        smartmet-test-data|smartmet-topography-data|smartmet-qdtools-test-data) remove+=("$pkg") ;;
        *) [ -n "${built[$src]:-}" ] && remove+=("$pkg") ;;
    esac
done < <(rpm -qa --qf '%{NAME} %{SOURCERPM}\n' 'smartmet-*')

if [ ${#remove[@]} -gt 0 ] ; then
    echo "Removing packages built in CI:" "${remove[@]}"
    rpm -e --nodeps "${remove[@]}"
fi

rm -rf "$specdir"

# Nothing that stays may have lost a dependency in the removal above.
# Otherwise jobs succeed in installing dependencies but fail to link.
if ! dnf check --dependencies ; then
    echo "ERROR: packages left in the image have missing dependencies"
    exit 1
fi

# Keep metadata, drop downloaded packages
dnf clean packages
dnf makecache

if [ ${#failed[@]} -gt 0 ] ; then
    echo "WARNING: dependency installation failed for: ${failed[*]}"
    echo "These dependencies will be installed at CI job run time instead."
fi
exit 0
