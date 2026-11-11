#!/bin/sh
# Builds nerva-<version>-1.<arch>.rpm with rpmbuild -bb from nerva.spec (v0.7.1, P284b;
# docs/briefs/v0.7.1.md, slice 5). The spec's macros and the reproducibility settings live here once.
#
#   build-rpm.sh <nerva> <x86_64|aarch64> <version> <out-dir>
#
# <version> is N.N.N, or N.N.N~suffix for a prerelease; the file name has `.` for the `~`.
#
# <nerva> is the release binary already built for that architecture; nothing is compiled, so one
# x86_64 machine builds both (`--target`). Reproducible: SOURCE_DATE_EPOCH (the commit's time;
# default the HEAD commit's) is the build time and every mtime; the build host is a fixed name.
# The package is unsigned.
set -eu

[ "$#" = 4 ] || {
    echo "usage: build-rpm.sh <nerva> <x86_64|aarch64> <version> <out-dir>" >&2
    exit 1
}
nerva=$(realpath "$1")
arch=$2
version=$3
out=$4
here=$(cd "$(dirname "$0")" && pwd)
root=$(cd "$here/../.." && pwd)

case "$arch" in
    x86_64 | aarch64) ;;
    *) echo "build-rpm.sh: architecture $arch is not x86_64 or aarch64" >&2; exit 1 ;;
esac
# N.N.N, or N.N.N~suffix for a prerelease (0.7.1-rc.1 is 0.7.1~rc.1: `~` sorts before the release).
case "${version%~*}" in
    *[!0-9.]* | "" | .* | *. | *..*)
        echo "build-rpm.sh: version $version is not N.N.N" >&2
        exit 1
        ;;
esac
case "$version" in
    *~*)
        case "${version#*~}" in
            "" | *[!0-9A-Za-z.]*)
                echo "build-rpm.sh: version $version has a bad suffix after the ~" >&2
                exit 1
                ;;
        esac
        ;;
esac
# The file name has `.` for `~` (GitHub renames an asset whose name has a `~`, P311); the version
# inside the package keeps it.
file_version=$(printf '%s' "$version" | tr '~' '.')
[ -f "$nerva" ] || { echo "build-rpm.sh: $nerva is not a file" >&2; exit 1; }
. "$here/check-elf.sh"
check_elf build-rpm.sh "$nerva" "$arch"
SOURCE_DATE_EPOCH=${SOURCE_DATE_EPOCH:-$(git -C "$root" log -1 --format=%ct)}
export SOURCE_DATE_EPOCH

top=$(mktemp -d)
trap 'rm -rf "$top"' EXIT
mkdir -p "$top/BUILD" "$top/RPMS" "$top/SOURCES" "$top/SPECS" "$top/SRPMS"
rpmbuild -bb --target "$arch-linux" \
    --define "_topdir $top" \
    --define "nerva_version $version" \
    --define "nerva_bin $nerva" \
    --define "nerva_src $here" \
    --define "nerva_root $root" \
    --define "_buildhost nerva-release" \
    --define "use_source_date_epoch_as_buildtime 1" \
    --define "clamp_mtime_to_source_date_epoch 1" \
    --define "_binary_payload w9.gzdio" \
    --define "_binary_filedigest_algorithm 8" \
    "$here/nerva.spec" > "$top/rpmbuild.log" 2>&1 || {
    cat "$top/rpmbuild.log" >&2
    exit 1
}
mkdir -p "$out"
cp "$top/RPMS/$arch/nerva-$version-1.$arch.rpm" "$out/nerva-$file_version-1.$arch.rpm"
echo "$out/nerva-$file_version-1.$arch.rpm"
