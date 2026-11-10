#!/bin/sh
# Builds nerva_<version>-1_<arch>.deb with dpkg-deb (v0.7.1, P284b; docs/briefs/v0.7.1.md, slice 5).
#
#   build-deb.sh <nerva> <amd64|arm64> <version> <out-dir>
#
# <nerva> is the release binary already built for that architecture: nothing is compiled. The
# units and examples come from this directory (slice 4's files, byte for byte), and the maintainer scripts are
# package-setup.sh (preinst), package-prerm.sh and package-reload.sh (postinst and postrm). The build is reproducible: SOURCE_DATE_EPOCH (the commit's time; default the
# HEAD commit's) is every mtime, entries are owned by root:root, and the control file is fixed text.
set -eu

[ "$#" = 4 ] || {
    echo "usage: build-deb.sh <nerva> <amd64|arm64> <version> <out-dir>" >&2
    exit 1
}
nerva=$1
arch=$2
version=$3
out=$4
here=$(cd "$(dirname "$0")" && pwd)
root=$(cd "$here/../.." && pwd)

case "$arch" in
    amd64 | arm64) ;;
    *) echo "build-deb.sh: architecture $arch is not amd64 or arm64" >&2; exit 1 ;;
esac
case "$version" in
    *[!0-9.]* | "" | .* | *. | *..*)
        echo "build-deb.sh: version $version is not N.N.N" >&2
        exit 1
        ;;
esac
[ -f "$nerva" ] || { echo "build-deb.sh: $nerva is not a file" >&2; exit 1; }
. "$here/check-elf.sh"
check_elf build-deb.sh "$nerva" "$([ "$arch" = amd64 ] && echo x86_64 || echo aarch64)"
SOURCE_DATE_EPOCH=${SOURCE_DATE_EPOCH:-$(git -C "$root" log -1 --format=%ct)}
export SOURCE_DATE_EPOCH

stage=$(mktemp -d)
trap 'rm -rf "$stage"' EXIT
pkg=$stage/pkg
install -d -m 755 "$pkg/DEBIAN" "$pkg/usr/bin" "$pkg/usr/lib/systemd/system" \
    "$pkg/usr/share/nerva" "$pkg/usr/share/doc/nerva"
install -m 755 "$nerva" "$pkg/usr/bin/nerva"
for unit in nerva@.service nerva-api@.service; do
    install -m 644 "$here/$unit" "$pkg/usr/lib/systemd/system/$unit"
done
# The examples are not documentation: a minimized system that excludes /usr/share/doc (dpkg's
# path-exclude) still has them. install.sh puts the same files in /etc/nerva.
for doc in replica.env.example api.env.example; do
    install -m 644 "$here/$doc" "$pkg/usr/share/nerva/$doc"
done
# Debian's name for the licence file, the one /usr/share/doc exclusions keep.
install -m 644 "$root/LICENSE" "$pkg/usr/share/doc/nerva/copyright"
install -m 644 "$root/NOTICE" "$pkg/usr/share/doc/nerva/NOTICE"
install -m 755 "$here/package-setup.sh" "$pkg/DEBIAN/preinst"
install -m 755 "$here/package-prerm.sh" "$pkg/DEBIAN/prerm"
install -m 755 "$here/package-reload.sh" "$pkg/DEBIAN/postinst"
install -m 755 "$here/package-reload.sh" "$pkg/DEBIAN/postrm"

# DEBIAN/md5sums, so that dpkg --verify and debsums can check the installed files.
(cd "$pkg" && find . -type f ! -path './DEBIAN/*' | LC_ALL=C sort | sed 's|^\./||' \
    | xargs md5sum > DEBIAN/md5sums)
chmod 644 "$pkg/DEBIAN/md5sums"

# Installed-Size is in KiB, from the files' sizes (not `du`, which counts the filesystem's blocks).
bytes=$(find "$pkg" -type f ! -path "$pkg/DEBIAN/*" -exec wc -c {} \; | awk '{ n += $1 } END { print n }')
cat > "$pkg/DEBIAN/control" << CONTROL
Package: nerva
Version: $version-1
Architecture: $arch
Maintainer: The Nerva authors <https://github.com/NervaLog/nerva>
Installed-Size: $(((bytes + 1023) / 1024))
Pre-Depends: passwd
Recommends: systemd
Section: database
Priority: optional
Homepage: https://github.com/NervaLog/nerva
Description: Nerva, a research database with derived state maintained from one replicated log
 One static binary: a replica (nerva start), the JSON gateway (nerva api) and the tools
 around them. The package installs the binary, the systemd units nerva@.service and
 nerva-api@.service, and the example settings in /usr/share/nerva. It creates the system
 user nerva and the directories /var/lib/nerva and /etc/nerva, and nothing more: it never
 formats, enables or starts a replica, and removing it leaves /var/lib/nerva.
CONTROL
chmod 644 "$pkg/DEBIAN/control"

# Every mtime is the commit's. dpkg-deb clamps to SOURCE_DATE_EPOCH too; this makes it the rule
# for the files themselves, symlinks and directories included.
find "$pkg" -exec touch -h -d "@$SOURCE_DATE_EPOCH" {} +

mkdir -p "$out"
dpkg-deb --root-owner-group -Zxz --build "$pkg" "$out/nerva_$version-1_$arch.deb" > /dev/null
echo "$out/nerva_$version-1_$arch.deb"
