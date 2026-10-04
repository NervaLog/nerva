#!/usr/bin/env sh
# Downloads the pinned Zig toolchain into ./zig (run from the repository root).
#
# Primary source: ziglang.org, verified against pinned SHA-256 checksums.
# Fallback: the official binaries repackaged on PyPI (`ziglang` wheel), verified by a pinned
# wheel hash. Used where ziglang.org is unreachable (e.g. restricted cloud sandboxes).
set -eu

ZIG_RELEASE="0.14.1"
ZIG_MIRROR="https://ziglang.org/download"
ZIG_CHECKSUMS=$(cat<<EOF
${ZIG_MIRROR}/0.14.1/zig-aarch64-linux-0.14.1.tar.xz f7a654acc967864f7a050ddacfaa778c7504a0eca8d2b678839c21eea47c992b
${ZIG_MIRROR}/0.14.1/zig-aarch64-macos-0.14.1.tar.xz 39f3dc5e79c22088ce878edc821dedb4ca5a1cd9f5ef915e9b3cc3053e8faefa
${ZIG_MIRROR}/0.14.1/zig-x86_64-linux-0.14.1.tar.xz 24aeeec8af16c381934a6cd7d95c807a8cb2cf7df9fa40d359aa884195c4716c
${ZIG_MIRROR}/0.14.1/zig-x86_64-macos-0.14.1.tar.xz b0f8bdfb9035783db58dd6c19d7dea89892acc3814421853e5752fe4573e5f43
EOF
)
# PyPI wheel hashes, keyed by "<arch>-<os>".
ZIG_WHEEL_HASHES=$(cat<<EOF
x86_64-linux 6eb9d4d759b292c83810dbee2e9e8e3fbfbf01d864e6e9811bae711fd74e1c2f
EOF
)

if [ "$(uname -m)" = 'arm64' ] || [ "$(uname -m)" = 'aarch64' ]; then
    ZIG_ARCH="aarch64"
else
    ZIG_ARCH="x86_64"
fi

case "$(uname)" in
    Linux) ZIG_OS="linux" ;;
    Darwin) ZIG_OS="macos" ;;
    *)
        echo "Unsupported OS: $(uname)"
        exit 1
        ;;
esac

if [ -x zig/zig ] && [ "$(zig/zig version)" = "$ZIG_RELEASE" ]; then
    echo "Zig $ZIG_RELEASE already installed."
    exit 0
fi

sha256() {
    if command -v sha256sum > /dev/null; then
        sha256sum "$1" | cut -d ' ' -f 1
    else
        shasum -a 256 "$1" | cut -d ' ' -f 1
    fi
}

# Moves an extracted toolchain directory ($1, containing `zig` and `lib`) into ./zig.
install_from() {
    rm -rf zig/lib zig/doc zig/zig
    mv "$1/lib" zig/
    mv "$1/zig" zig/
    chmod +x zig/zig
}

download_ziglang_org() {
    url="${ZIG_MIRROR}/${ZIG_RELEASE}/zig-${ZIG_ARCH}-${ZIG_OS}-${ZIG_RELEASE}.tar.xz"
    expected=$(echo "$ZIG_CHECKSUMS" | grep -F "$url" | cut -d ' ' -f 2)
    archive="zig/cache/$(basename "$url")"
    mkdir -p zig/cache
    if [ ! -f "$archive" ] || [ "$(sha256 "$archive")" != "$expected" ]; then
        curl --location --silent --show-error --fail --output "$archive" "$url" || return 1
    fi
    if [ "$(sha256 "$archive")" != "$expected" ]; then
        echo "Checksum mismatch for $archive."
        exit 1
    fi
    tar -xf "$archive" -C zig/cache
    install_from "zig/cache/$(basename "$archive" .tar.xz)"
    rm -rf "zig/cache/$(basename "$archive" .tar.xz)"
}

download_pypi() {
    hash=$(echo "$ZIG_WHEEL_HASHES" | grep -F "${ZIG_ARCH}-${ZIG_OS} " | cut -d ' ' -f 2)
    if [ -z "$hash" ]; then
        echo "No pinned PyPI wheel for ${ZIG_ARCH}-${ZIG_OS}."
        return 1
    fi
    mkdir -p zig/cache/pypi
    echo "ziglang==${ZIG_RELEASE} --hash=sha256:${hash}" > zig/cache/pypi/requirements.txt
    python3 -m pip download --quiet --no-deps --require-hashes \
        -r zig/cache/pypi/requirements.txt -d zig/cache/pypi || return 1
    rm -rf zig/cache/pypi/extracted
    python3 -m zipfile -e zig/cache/pypi/ziglang-*.whl zig/cache/pypi/extracted
    install_from zig/cache/pypi/extracted/ziglang
    rm -rf zig/cache/pypi/extracted
}

echo "Downloading Zig $ZIG_RELEASE ..."
if ! download_ziglang_org; then
    echo "ziglang.org unavailable; falling back to PyPI."
    download_pypi
fi

if [ "$(zig/zig version)" != "$ZIG_RELEASE" ]; then
    echo "Installed Zig reports $(zig/zig version), expected $ZIG_RELEASE."
    exit 1
fi
echo "Zig $ZIG_RELEASE installed at $(pwd)/zig/zig"
