#!/usr/bin/env bash
# Apple's public Developer ID intermediate certificates, for `mac_keychain.sh create` (P455). The
# owner's .p12 holds the Developer ID Application certificate and its key only, and without an
# intermediate the identity has no chain, so `security find-identity -v` counts no valid identity.
#
#   mac_ca.sh fetch <dir>   downloads both into the new directory <dir>, checking each file against its pinned SHA-256
#
# `mac-sign.yml` runs it in a step of its own, with no secret in its environment, so curl never runs
# beside one. https only; a file whose hash differs is deleted and refused with NRV-E1165.
set -euo pipefail

# name sha256 (G2 is valid until 2031; the original Developer ID CA until 2027-02)
PINS='DeveloperIDG2CA.cer f16cd3c54c7f83cea4bf1a3e6a0819c8aaa8e4a1528fd144715f350643d2df3a
DeveloperIDCA.cer 7afc9d01a62f03a2de9637936d4afe68090d2de18d03f29c88cfb0b1ba63587f'

# fail <headline> <cause> <fix>
fail() {
  printf 'error[NRV-E1165]: mac_ca.sh: %s\n  cause  %s\n  fix    %s\n' "$1" "$2" "$3" >&2
  echo "::error::NRV-E1165 $1" >&2
  exit 1
}

fetch() {
  local dir=${1:-} name sum got
  [[ -n "$dir" ]] || { echo "usage: mac_ca.sh fetch <dir>" >&2; exit 2; }
  if ! mkdir "$dir" 2> /dev/null; then
    fail "the directory '$dir' for Apple's intermediates could not be made" \
      "it exists already (a reused machine) or its parent cannot be written" \
      "use a fresh runner, or remove the directory"
  fi
  while read -r name sum; do
    if ! curl -fsS --proto '=https' --tlsv1.2 --retry 3 -o "$dir/$name" \
      "https://www.apple.com/certificateauthority/$name"; then
      rm -f "$dir/$name"
      fail "Apple's $name could not be downloaded" \
        "www.apple.com/certificateauthority did not answer, or answered with an error" \
        "run again; if it repeats, check Apple's certificate page for a moved file"
    fi
    got=$(openssl dgst -sha256 -r "$dir/$name" | cut -d ' ' -f 1)
    if [[ "$got" != "$sum" ]]; then
      rm -f "$dir/$name"
      fail "Apple's $name has SHA-256 $got, not the pinned $sum" \
        "Apple replaced the file (it can reissue an intermediate), or the download was altered on the way" \
        "do not import it; check the new file against Apple's certificate page, then change the pin in mac_ca.sh in a pull request"
    fi
  done <<< "$PINS"
  echo "fetched and checked: $(cut -d ' ' -f 1 <<< "$PINS" | tr '\n' ' ')"
}

case "${1:-}" in
  fetch) shift; fetch "$@" ;;
  *) echo "usage: mac_ca.sh fetch <dir>" >&2; exit 2 ;;
esac
