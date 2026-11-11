#!/usr/bin/env bash
# The temporary keychain that `zig build -Drelease mac-release -Dnotarize=true` signs from, in
# `mac-sign.yml` (macOS signing in CI, v0.7.1; docs/decisions P<n>-mac-signed-in-ci.md). It needs
# macOS's `security` and `xcrun notarytool`, and runs on a hosted runner only.
#
#   mac_keychain.sh create [--skip-notary]   reads its secrets from the environment
#   mac_keychain.sh destroy                  never fails; run it under `if: always()`
#
# `create` needs APPLE_DEVELOPER_ID_P12 (base64 of the .p12: the Developer ID Application
# certificate, its key and the Developer ID G2 intermediate) and APPLE_DEVELOPER_ID_P12_PASSWORD,
# and, unless `--skip-notary`, APPLE_NOTARY_KEY_P8 (base64 of AuthKey_<id>.p8),
# APPLE_NOTARY_KEY_ID and APPLE_NOTARY_ISSUER_ID. An empty one is refused with NRV-E1121 before
# anything is touched. It makes a keychain with a random password, imports the identity, puts the
# keychain first in the user search list and makes it the default (`mac-release` passes no
# `--keychain` to security, codesign or notarytool), and stores a notary profile `nerva-notary`.
# It prints the identities (exactly one valid one is required) and no secret.
#
# `--skip-notary` is for ci.yml's `mac-keychain` job only: a self-signed test certificate, no
# notary profile, and any code-signing identity (not only a trusted one) is accepted.
set -euo pipefail

kc="${RUNNER_TEMP:?RUNNER_TEMP is not set: this script runs on a GitHub Actions runner}/nerva-signing.keychain-db"
saved_default="$RUNNER_TEMP/nerva-signing.default-keychain"
saved_list="$RUNNER_TEMP/nerva-signing.keychain-list"

refuse() {
  printf 'error[NRV-E1121]: mac_keychain.sh: %s\n  cause  %s\n  fix    %s\n' "$1" "$2" "$3" >&2
  echo "::error::NRV-E1121 $1" >&2
  exit 1
}

# The user's keychain search list, one path per line, without quotes.
user_keychains() {
  security list-keychains -d user | sed -e 's/^[[:space:]]*"//' -e 's/"$//'
}

create() {
  local skip_notary=0
  case "${1:-}" in
    '') ;;
    --skip-notary) skip_notary=1 ;;
    *) echo "usage: mac_keychain.sh create [--skip-notary]" >&2; exit 2 ;;
  esac
  local names=(APPLE_DEVELOPER_ID_P12 APPLE_DEVELOPER_ID_P12_PASSWORD)
  if [[ $skip_notary == 0 ]]; then
    names+=(APPLE_NOTARY_KEY_P8 APPLE_NOTARY_KEY_ID APPLE_NOTARY_ISSUER_ID)
  fi
  local name
  for name in "${names[@]}"; do
    if [[ -z "${!name:-}" ]]; then
      refuse "the signing secret $name is empty" \
        "the environment apple-signing does not hold it, or this run was not approved for it" \
        "set $name in the environment apple-signing (the owner's setup checklist), then run again"
    fi
  done

  umask 077
  local p12="$RUNNER_TEMP/nerva-id.p12" p8="$RUNNER_TEMP/nerva-notary.p8"
  trap 'rm -f "$p12" "$p8"' EXIT

  local pw
  pw=$(openssl rand -base64 32)
  echo "::add-mask::$pw"
  user_keychains > "$saved_list"
  security default-keychain -d user | sed -e 's/^[[:space:]]*"//' -e 's/"$//' > "$saved_default"

  security create-keychain -p "$pw" "$kc"
  security set-keychain-settings -lut 3600 "$kc"
  security unlock-keychain -p "$pw" "$kc"
  printf '%s' "$APPLE_DEVELOPER_ID_P12" | base64 --decode > "$p12"
  if ! security import "$p12" -k "$kc" -f pkcs12 -P "$APPLE_DEVELOPER_ID_P12_PASSWORD" \
    -T /usr/bin/codesign > /dev/null; then
    refuse "the keychain could not import APPLE_DEVELOPER_ID_P12" \
      "the secret is not the base64 of a .p12, its password is wrong, or OpenSSL 3 wrote it with an encryption macOS cannot read (MAC verification failed)" \
      "export it again with 'openssl pkcs12 -export -legacy', and check APPLE_DEVELOPER_ID_P12_PASSWORD"
  fi
  rm -f "$p12"
  # Without this, codesign fails with errSecInternalComponent: there is no UI to allow it.
  security set-key-partition-list -S apple-tool:,apple:,codesign: -s -k "$pw" "$kc" > /dev/null

  # Search list and default keychain: mac-release passes no --keychain to anything it runs.
  local list=("$kc") line
  while IFS= read -r line; do
    [[ -n "$line" && "$line" != "$kc" ]] && list+=("$line")
  done < "$saved_list"
  security list-keychains -d user -s "${list[@]}"
  security default-keychain -d user -s "$kc"

  if [[ $skip_notary == 0 ]]; then
    printf '%s' "$APPLE_NOTARY_KEY_P8" | base64 --decode > "$p8"
    xcrun notarytool store-credentials nerva-notary --key "$p8" \
      --key-id "$APPLE_NOTARY_KEY_ID" --issuer "$APPLE_NOTARY_ISSUER_ID" --keychain "$kc" > /dev/null
    rm -f "$p8"
  fi

  local flags=(-p codesigning) found
  [[ $skip_notary == 0 ]] && flags=(-v -p codesigning)
  found=$(security find-identity "${flags[@]}" "$kc")
  printf '%s\n' "$found"
  if [[ $skip_notary == 0 ]]; then
    grep -q '^ *1 valid identities found' <<< "$found" || refuse \
      "the keychain does not hold exactly one valid code-signing identity" \
      "the .p12 lacks the Developer ID Application certificate, its private key or the Developer ID G2 intermediate, or holds more than one identity" \
      "export the certificate with its key and the G2 intermediate (the owner's setup checklist), one identity only"
  else
    grep -q '^ *1) ' <<< "$found" || refuse \
      "the keychain holds no code-signing identity" \
      "the test certificate was not imported" \
      "check the certificate the job made"
  fi
}

# Never fails: it runs under `if: always()`, and the hosted VM is discarded afterwards anyway.
destroy() {
  set +e
  rm -f "$RUNNER_TEMP/nerva-id.p12" "$RUNNER_TEMP/nerva-notary.p8"
  if [[ -s "$saved_list" ]]; then
    local list=() line
    while IFS= read -r line; do
      [[ -n "$line" && "$line" != "$kc" ]] && list+=("$line")
    done < "$saved_list"
    [[ ${#list[@]} -gt 0 ]] && security list-keychains -d user -s "${list[@]}"
  fi
  if [[ -s "$saved_default" ]]; then
    security default-keychain -d user -s "$(cat "$saved_default")"
  fi
  security delete-keychain "$kc" > /dev/null 2>&1
  rm -f "$saved_list" "$saved_default"
  exit 0
}

case "${1:-}" in
  create) shift; create "$@" ;;
  destroy) destroy ;;
  *) echo "usage: mac_keychain.sh create [--skip-notary] | destroy" >&2; exit 2 ;;
esac
