#!/usr/bin/env bash
# The temporary keychain that `zig build -Drelease mac-release -Dnotarize=true` signs from, in
# `mac-sign.yml` (macOS signing in CI, v0.7.1; docs/decisions P343-mac-signed-in-ci.md). It needs
# macOS's `security` and `xcrun notarytool`, and runs on a hosted runner only.
#
#   mac_keychain.sh create [--skip-notary]   reads its secrets from the environment
#   mac_keychain.sh destroy                  never fails on a runner; run it under `if: always()`; refused (NRV-E1125) without RUNNER_TEMP
#
# `create` needs APPLE_DEVELOPER_ID_P12 (base64 of the .p12: the Developer ID Application
# certificate, its key and the Developer ID G2 intermediate) and APPLE_DEVELOPER_ID_P12_PASSWORD,
# and, unless `--skip-notary`, APPLE_NOTARY_KEY_P8 (base64 of AuthKey_<id>.p8),
# APPLE_NOTARY_KEY_ID and APPLE_NOTARY_ISSUER_ID. An empty one is refused with NRV-E1121 before
# anything is touched. It makes a keychain with a random password, imports the identity, puts the
# keychain first in the user search list and makes it the default (`mac-release` passes no
# `--keychain` to security, codesign or notarytool), and stores a notary profile `nerva-notary`.
# It prints the identities (exactly one valid one is required) and no secret. `security import -P`
# has no stdin form, so the .p12 password (and the random keychain password) are in `security`'s
# argv for a moment, where other processes of the runner's VM can read them: on a hosted runner
# those are this job's own.
# Every failure has a code, a headline, a cause and a fix (docs/ERRORS.md): NRV-E1121 for the
# secrets and the identity (`refuse`), NRV-E1125 for the runner and the `security` commands that make
# and arrange the keychain (`fail`). Nothing ends in a raw command error.
#
# `--skip-notary` is for ci.yml's `mac-keychain` job only: a self-signed test certificate, no
# notary profile, and any code-signing identity (not only a trusted one) is accepted.
set -euo pipefail

RUNNER_TEMP="${RUNNER_TEMP:-}"
kc="$RUNNER_TEMP/nerva-signing.keychain-db"
saved_default="$RUNNER_TEMP/nerva-signing.default-keychain"
saved_list="$RUNNER_TEMP/nerva-signing.keychain-list"
p12="$RUNNER_TEMP/nerva-id.p12"
p8="$RUNNER_TEMP/nerva-notary.p8"

# fail <code> <headline> <cause> <fix>
fail() {
  printf 'error[%s]: mac_keychain.sh: %s\n  cause  %s\n  fix    %s\n' "$1" "$2" "$3" "$4" >&2
  echo "::error::$1 $2" >&2
  exit 1
}

refuse() { fail NRV-E1121 "$@"; }

# step <headline> <cause> <fix> <command...>: runs the command; if it fails, prints its output
# (never a secret: none of these commands prints one) and ends with NRV-E1125.
step() {
  local headline=$1 cause=$2 fix=$3 out
  shift 3
  if ! out=$("$@" 2>&1); then
    printf 'command: %s\n' "$out" >&2
    fail NRV-E1125 "$headline" "$cause" "$fix"
  fi
}

# The user's keychain search list, one path per line, without quotes.
user_keychains() {
  security list-keychains -d user | sed -e 's/^[[:space:]]*"//' -e 's/"$//'
}

# Saves the user's search list and default keychain where `destroy` finds them.
# (Called inside `step`'s `if`, where `set -e` is off: each command ends `|| return 1`.)
read_user_state() {
  user_keychains > "$saved_list" || return 1
  security default-keychain -d user | sed -e 's/^[[:space:]]*"//' -e 's/"$//' > "$saved_default" || return 1
}

make_keychain() {
  security create-keychain -p "$1" "$kc" || return 1
  security set-keychain-settings "$kc" || return 1
  security unlock-keychain -p "$1" "$kc" || return 1
}

# arrange_keychains <keychain> <search list...>
arrange_keychains() {
  local keychain=$1
  shift
  security list-keychains -d user -s "$@" || return 1
  security default-keychain -d user -s "$keychain" || return 1
}

create() {
  local skip_notary=0
  case "${1:-}" in
    '') ;;
    --skip-notary) skip_notary=1 ;;
    *) echo "usage: mac_keychain.sh create [--skip-notary]" >&2; exit 2 ;;
  esac
  if [[ -z "$RUNNER_TEMP" || ! -d "$RUNNER_TEMP" || ! -w "$RUNNER_TEMP" ]]; then
    fail NRV-E1125 "the runner's temporary directory '$RUNNER_TEMP' is not a writable directory" \
      "RUNNER_TEMP is unset or names a directory that does not exist or cannot be written; this script runs on a GitHub Actions runner" \
      "run it as a step of a workflow job on a hosted runner"
  fi
  if [[ -e "$kc" ]]; then
    fail NRV-E1125 "a signing keychain already exists at $kc" \
      "an earlier run on this machine left it (a hosted runner is discarded after each job, so this is a reused machine), and a second create would overwrite the saved search list" \
      "run 'mac_keychain.sh destroy', or use a fresh runner"
  fi
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
  # The secret files go on every path, refusals and errors included (they are globals: the trap
  # fires after create has returned).
  trap 'rm -f "$p12" "$p8"' EXIT

  local pw
  if ! pw=$(openssl rand -base64 32 2> /dev/null) || [[ -z "$pw" ]]; then
    fail NRV-E1125 "a random keychain password could not be made" \
      "'openssl rand' failed or printed nothing" \
      "run again; if it repeats, the runner image is broken"
  fi
  echo "::add-mask::$pw"
  step "the user's keychain search list and default keychain could not be read" \
    "'security list-keychains' or 'security default-keychain' failed, or the runner's temporary directory could not be written" \
    "run again; if it repeats, the runner image is broken" \
    read_user_state
  # No -t: the default auto-lock (300 s) could lock the keychain during a long build; the job destroys it.
  step "the signing keychain could not be created or unlocked" \
    "'security create-keychain', 'set-keychain-settings' or 'unlock-keychain' failed" \
    "run again; if it repeats, the runner image is broken" \
    make_keychain "$pw"
  if ! printf '%s' "$APPLE_DEVELOPER_ID_P12" | base64 --decode > "$p12" 2> /dev/null; then
    refuse "the signing secret APPLE_DEVELOPER_ID_P12 is not base64" \
      "it holds something other than the base64 of the .p12 file" \
      "set it from 'base64 < developer-id.p12' (one line, no quotes) in the environment apple-signing"
  fi
  if ! security import "$p12" -k "$kc" -f pkcs12 -P "$APPLE_DEVELOPER_ID_P12_PASSWORD" \
    -T /usr/bin/codesign > /dev/null; then
    refuse "the keychain could not import APPLE_DEVELOPER_ID_P12" \
      "the secret is not the base64 of a .p12, its password is wrong, or OpenSSL 3 wrote it with an encryption macOS cannot read (MAC verification failed)" \
      "export it again with 'openssl pkcs12 -export -legacy', and check APPLE_DEVELOPER_ID_P12_PASSWORD"
  fi
  rm -f "$p12"
  # Without this, codesign fails with errSecInternalComponent: there is no UI to allow it.
  if ! security set-key-partition-list -S apple-tool:,apple:,codesign: -s -k "$pw" "$kc" > /dev/null 2>&1; then
    refuse "the keychain's signing key could not be opened for codesign" \
      "the .p12 holds no private key, so codesign would fail with errSecInternalComponent" \
      "export the certificate together with its private key (the owner's setup checklist)"
  fi

  # Search list and default keychain: mac-release passes no --keychain to anything it runs.
  local list=("$kc") line
  while IFS= read -r line; do
    [[ -n "$line" && "$line" != "$kc" ]] && list+=("$line")
  done < "$saved_list"
  step "the signing keychain could not be put first in the search list and made the default" \
    "'security list-keychains -s' or 'security default-keychain -s' failed" \
    "run again; if it repeats, the runner image is broken" \
    arrange_keychains "$kc" "${list[@]}"

  if [[ $skip_notary == 0 ]]; then
    if ! printf '%s' "$APPLE_NOTARY_KEY_P8" | base64 --decode > "$p8" 2> /dev/null; then
      refuse "the signing secret APPLE_NOTARY_KEY_P8 is not base64" \
        "it holds something other than the base64 of AuthKey_<id>.p8" \
        "set it from 'base64 < AuthKey_<id>.p8' (one line, no quotes) in the environment apple-signing"
    fi
    local stored
    if ! stored=$(xcrun notarytool store-credentials nerva-notary --key "$p8" \
      --key-id "$APPLE_NOTARY_KEY_ID" --issuer "$APPLE_NOTARY_ISSUER_ID" --keychain "$kc" 2>&1); then
      printf 'notarytool: %s\n' "$stored" >&2
      refuse "the notary profile could not be stored" \
        "Apple refused the key (a wrong APPLE_NOTARY_KEY_ID or APPLE_NOTARY_ISSUER_ID, a revoked or mistyped .p8) or its service is unreachable" \
        "check the three notary secrets against App Store Connect (Users and Access, Integrations), then run again"
    fi
    rm -f "$p8"
  fi

  local flags=(-p codesigning) found
  [[ $skip_notary == 0 ]] && flags=(-v -p codesigning)
  if ! found=$(security find-identity "${flags[@]}" "$kc" 2>&1); then
    printf 'security: %s\n' "$found" >&2
    fail NRV-E1125 "the keychain's identities could not be listed" \
      "'security find-identity' failed on the keychain" \
      "run again; if it repeats, the runner image is broken"
  fi
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
  # Without RUNNER_TEMP every path below would be at the root of the disk.
  if [[ -z "$RUNNER_TEMP" ]]; then
    fail NRV-E1125 "the runner's temporary directory '' is not a writable directory" \
      "RUNNER_TEMP is unset, so there is no keychain to find; this script runs on a GitHub Actions runner" \
      "run it as a step of a workflow job on a hosted runner"
  fi
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
