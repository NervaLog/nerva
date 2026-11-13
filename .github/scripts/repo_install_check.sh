#!/usr/bin/env bash
# repo_install_check.sh <apt|dnf> <channel> <base-url> <fingerprint> <version>
#
# The `repos-verify` check (docs/releases/packages.md, "`repos-verify`"): inside a distribution's
# container, install Nerva from the signed repository exactly as INSTALL.md tells a user to, and
# check that what installed is the release. The commands between the INSTALL-BEGIN and INSTALL-END
# markers are INSTALL.md's own, with `sudo` as $SUDO, the repository as $BASE, the channel as
# $CHANNEL and the key file as $KEY_URL; tests/packaging/repos.py checks that they stay equal to the
# install text. The check never runs `rpm --import`: dnf 5 fills its own keyring from `gpgkey=`.
#
# Setup (the prerequisites the install text assumes) failing is NRV-E1157, the environment's;
# every other failure is NRV-E1146, which says the release is already public. Nothing here reads
# a credential. INSTALL_KEY_URL (the key file's URL) is for tests; a runner never sets it.
# The install lines keep INSTALL.md's own spelling, unquoted: their values hold no space or glob.
# shellcheck disable=SC2086
set -euo pipefail
{ set +x; } 2>/dev/null
export LC_ALL=C

where=repo_install_check.sh
block() { printf 'error[%s]: %s: %s\n  cause  %s\n  fix    %s\n' "$1" "$where" "$2" "$3" "$4" >&2; echo "::error::$1 $2" >&2; }
usage() { echo "usage: repo_install_check.sh <apt|dnf> <channel> <base-url> <fingerprint> <version>" >&2; exit 64; }

[ $# -eq 5 ] || usage
mgr=$1 CHANNEL=$2 BASE=${3%/} fpr=$4 version=$5
KEY_URL=${INSTALL_KEY_URL:-https://raw.githubusercontent.com/NervaLog/nerva/main/packaging/keys/nerva-release.asc}
case $mgr in apt | dnf) ;; *) usage ;; esac
case $CHANNEL in stable | rc) ;; *) usage ;; esac
[[ $fpr =~ ^[0-9A-F]{40}$ ]] || usage
[[ $version =~ ^[0-9]+\.[0-9]+\.[0-9]+(-rc\.[0-9]+)?$ ]] || usage
if [ "$(id -u)" = 0 ]; then SUDO=; else SUDO=sudo; fi
APT_VER=${version/-rc./~rc.}-1
RPM_VER=${version/-rc./~rc.}-1
log=$(mktemp)
trap 'rm -f "$log"' EXIT

setup_failed() {
  block NRV-E1157 "$1 failed before any check of the repository ran" "the registry or a mirror did not answer, or refused" \
    "Make the registry or mirror reachable, then run repos-verify again"
  sed 's/^/  | /' "$log" | tail -n 20 >&2
  exit 1
}
check_failed() {
  block NRV-E1146 "$1" "the release is already public; the GitHub release's files still install by hand (INSTALL.md)" \
    "Read the distribution's install output, fix the repository or the check, then run repos-verify again"
  sed 's/^/  | /' "$log" | tail -n 20 >&2
  exit 1
}
setup() { local what=$1; shift; "$@" >"$log" 2>&1 || setup_failed "$what"; }
step() { local what=$1; shift; "$@" >"$log" 2>&1 || check_failed "$what"; }

fingerprint_of() { gpg --batch --show-keys --with-colons "$1" 2>/dev/null | awk -F: '$1=="pub"{p=1;next} $1=="fpr"&&p{print $10;p=0}'; }
check_key() {
  local f=$1
  fingerprint_of "$f" | grep -qx "$fpr" || check_failed "the key at $KEY_URL does not have the fingerprint $fpr"
}

# ---- apt ---------------------------------------------------------------------------------------

apt_prepare() {
  export DEBIAN_FRONTEND=noninteractive
  setup "apt-get update" apt-get update
  setup "installing curl, ca-certificates and gnupg" apt-get install -y curl ca-certificates gnupg
}

apt_config() {
  # INSTALL-BEGIN apt
  $SUDO install -d -m 0755 /etc/apt/keyrings
  curl -fsSL $KEY_URL | $SUDO tee /etc/apt/keyrings/nerva.asc > /dev/null
  gpg --show-keys /etc/apt/keyrings/nerva.asc
  $SUDO tee /etc/apt/sources.list.d/nerva.sources > /dev/null <<EOF
Types: deb
URIs: $BASE/apt
Suites: $CHANNEL
Components: main
Architectures: amd64 arm64
Signed-By: /etc/apt/keyrings/nerva.asc
EOF
  # INSTALL-END apt
}

apt_install_cmd() {
  # INSTALL-BEGIN apt-install
  $SUDO apt-get update && $SUDO apt-get install -y nerva=$APT_VER
  # INSTALL-END apt-install
}
apt_install() { step "apt-get update and install nerva=$APT_VER from $CHANNEL" apt_install_cmd; }

apt_not_stable() {
  CHANNEL=stable apt_config >/dev/null 2>&1 || check_failed "writing the stable sources file"
  step "apt-get update with stable configured" $SUDO apt-get update
  # Only what the configured sources list: an empty dpkg status keeps the installed candidate out.
  if apt-cache -o Dir::State::status=/dev/null madison nerva 2>&1 | grep -qF "$APT_VER"; then
    check_failed "stable lists the candidate $APT_VER"
  fi
}

# ---- dnf ---------------------------------------------------------------------------------------

dnf_prepare() {
  command -v curl >/dev/null || setup "installing curl" dnf install -y curl
  command -v gpg >/dev/null || setup "installing gnupg2" dnf install -y gnupg2
  if rpm -q dnf5 >/dev/null 2>&1; then
    local have
    have=$(rpm -q --qf '%{VERSION}-%{RELEASE}' dnf5)
    [ "$(rpm --eval "%{lua: print(rpm.vercmp('$have', '5.2.18.0-4'))}")" -ge 0 ] ||
      check_failed "dnf5 $have is older than 5.2.18.0-4, which hangs on importing a repository key (RHBZ 2458182)"
  fi
}

dnf_config() {
  # INSTALL-BEGIN dnf
  $SUDO tee /etc/yum.repos.d/nerva.repo > /dev/null <<EOF
[nerva]
name=Nerva
baseurl=$BASE/rpm/$CHANNEL
enabled=1
gpgcheck=1
repo_gpgcheck=1
gpgkey=$KEY_URL
EOF
  # INSTALL-END dnf
}

dnf_install() {
  # INSTALL-BEGIN dnf-install
  $SUDO dnf install -y nerva-$RPM_VER
  # INSTALL-END dnf-install
}

dnf_not_stable() {
  CHANNEL=stable dnf_config >/dev/null 2>&1 || check_failed "writing the stable repository file"
  dnf clean all >/dev/null 2>&1 || true
  # The output, never the exit status: on an empty channel `dnf list` exits 1 with
  # "No matching packages to list", which is the right answer here.
  # --available --repo: only what the repository lists, never the installed package.
  if dnf list --available --showduplicates --repo nerva nerva 2>&1 | grep -qF "$RPM_VER"; then
    check_failed "stable lists the candidate $RPM_VER"
  fi
}

# ---- the check ---------------------------------------------------------------------------------

installed_version() {
  nerva version | tail -n 1
}

case $mgr in
  apt)
    apt_prepare
    step "fetching the key and writing the repository's sources file" apt_config
    check_key /etc/apt/keyrings/nerva.asc
    apt_install
    ;;
  dnf)
    dnf_prepare
    step "writing the repository file" dnf_config
    step "fetching the key" curl -fsSL -o /tmp/nerva-key.asc "$KEY_URL"
    check_key /tmp/nerva-key.asc
    step "dnf install nerva-$RPM_VER from $CHANNEL" dnf_install
    ;;
esac

got=$(installed_version 2>"$log") || check_failed "nerva version failed after the install"
[ "$got" = "version $version" ] || check_failed "nerva version ends in '$got', not 'version $version'"

if [ "$CHANNEL" = rc ]; then "${mgr}_not_stable"; fi
echo "repo_install_check.sh: $mgr $CHANNEL $version installed and verified"
