#!/usr/bin/env bash
# The check of the signed macOS zip from outside, in `mac-sign.yml`, after `mac-release` built it and
# before anything is uploaded (docs/ERRORS.md, NRV-E1126 and NRV-E1127). It needs `shasum`, `unzip`
# and macOS's `codesign`.
#
#   mac_zip_check.sh <dir> <tag>    <dir> holds nerva-<tag>-universal-macos.zip and its .sha256
#
# It refuses a zip that does not match its checksum file or does not hold the binary (NRV-E1126), and
# a binary whose signature is not a Developer ID Application one with the hardened runtime and a
# secure timestamp, as notarization requires (NRV-E1127). Each prints one coded block,
# `error[<code>]: mac-sign.yml: <what>` with a cause and a fix line, and exits 1.
set -euo pipefail

dir=${1:?usage: mac_zip_check.sh <dir> <tag>}
tag=${2:?usage: mac_zip_check.sh <dir> <tag>}
where=mac-sign.yml

refuse() {
  printf 'error[%s]: %s: %s\n  cause  %s\n  fix    %s\n' "$1" "$where" "$2" "$3" "$4" >&2
  echo "::error::$1 $2" >&2
  exit 1
}

zip="nerva-$tag-universal-macos.zip"
scratch=$(mktemp -d "${RUNNER_TEMP:-${TMPDIR:-/tmp}}/zipcheck.XXXXXX")
trap 'rm -rf "$scratch"' EXIT

if ! sums=$(cd "$dir" && shasum -a 256 -c "$zip.sha256" 2>&1); then
  printf 'shasum: %s\n' "$sums" >&2
  refuse NRV-E1126 "$zip does not match its checksum file, or one of the two is missing" \
    "mac-release wrote a zip and a checksum that disagree, or one of them was not written" \
    "run mac-sign.yml again; if it repeats, read the mac-release step's output"
fi
if ! unpacked=$(unzip -q "$dir/$zip" -d "$scratch" 2>&1); then
  printf 'unzip: %s\n' "$unpacked" >&2
  refuse NRV-E1126 "$zip cannot be unpacked" \
    "the file is not a readable zip" \
    "run mac-sign.yml again; if it repeats, read the mac-release step's output"
fi
nerva="$scratch/nerva-$tag-universal-macos/nerva"
if [[ ! -f "$nerva" ]]; then
  refuse NRV-E1126 "$zip holds no nerva at nerva-$tag-universal-macos/nerva" \
    "mac-release packed another layout, or another version's name" \
    "run mac-sign.yml again with the draft's tag; if it repeats, read the mac-release step's output"
fi

if ! codesign -dv --verbose=4 "$nerva" 2> "$scratch/signature.txt"; then
  cat "$scratch/signature.txt" >&2
  refuse NRV-E1127 "codesign cannot read a signature from the zip's nerva" \
    "the binary is not signed at all, or codesign failed" \
    "read the mac-release step's output: it signs with the keychain mac_keychain.sh made"
fi
cat "$scratch/signature.txt"
if ! grep -q '^Authority=Developer ID Application' "$scratch/signature.txt"; then
  refuse NRV-E1127 "the zip's nerva is not signed with a Developer ID Application certificate" \
    "mac-release signed it ad hoc or with another identity (a missing identity name, or a certificate that is not Developer ID Application)" \
    "check APPLE_DEVELOPER_ID_P12 and the repository variable NERVA_SIGN_IDENTITY"
fi
if ! grep -Eq 'flags=0x[0-9a-f]+\([^)]*runtime' "$scratch/signature.txt"; then
  refuse NRV-E1127 "the zip's nerva does not have the hardened runtime" \
    "mac-release did not sign with --options runtime, which notarization requires" \
    "read the mac-release step's output; the signing flags are build.zig's"
fi
if ! grep -q '^Timestamp=' "$scratch/signature.txt"; then
  refuse NRV-E1127 "the zip's nerva has no secure timestamp" \
    "mac-release did not sign with --timestamp, or Apple's timestamp service did not answer" \
    "run mac-sign.yml again; if it repeats, read the mac-release step's output"
fi
