#!/bin/sh
# Sets up the Jepsen nightly on a fresh Ubuntu 24.04 host (ops/jepsen/README.md). Run as root:
# `sh setup.sh --token-file PATH`. Safe to run again. The token is copied from a file (never
# printed, never an argument value) to /etc/jepsen/token, mode 0600. The unit stops the
# simulation fleet before each night and starts it again after (jepsen.service), so this script
# does not touch the fleet.
#
# It also installs the runner (nightly.sh, jepsen_report.py, the unit and the timer) from the
# checkout it is run in, into /opt/jepsen/bin and /etc/systemd/system (P240). The night never
# runs the tip's ops/jepsen/: a change to the runner reaches the host only when this runs again.
set -eu
SCRIPT_DIR=$(CDPATH='' cd -P -- "$(dirname -- "$(readlink -f -- "$0")")" && pwd -P)
cd /

HOME_DIR=/var/lib/jepsen
CHECKOUT=$HOME_DIR/nerva
BIN_DIR=/opt/jepsen/bin

TOKEN_SRC=""
while [ $# -gt 0 ]; do
    case "$1" in
    --token-file)
        if [ $# -lt 2 ]; then
            echo "setup.sh: --token-file needs a path" >&2
            exit 1
        fi
        TOKEN_SRC=$2
        shift 2
        ;;
    *)
        echo "usage: setup.sh [--token-file PATH]" >&2
        exit 1
        ;;
    esac
done

if [ "$(id -u)" -ne 0 ]; then
    echo "setup.sh: run as root" >&2
    exit 1
fi
if [ ! -e /dev/kvm ]; then
    echo "setup.sh: warning: no /dev/kvm; the nightly does not need it, slice 10 does" >&2
fi

apt-get update -q
apt-get install -y -q git curl xz-utils zstd ca-certificates python3 util-linux \
    openjdk-21-jdk-headless gnuplot-nox docker.io

if ! id jepsen >/dev/null 2>&1; then
    useradd --system --create-home --home-dir "$HOME_DIR" --shell /usr/sbin/nologin jepsen
fi
# The docker group is root-equivalent: this host is single-purpose, and the fleet's user and
# token stay apart from this user and its own token.
usermod -aG docker jepsen
systemctl enable --now docker.service

mkdir -p /etc/jepsen
chmod 700 /etc/jepsen
if [ -n "$TOKEN_SRC" ]; then
    if [ ! -s "$TOKEN_SRC" ]; then
        echo "setup.sh: $TOKEN_SRC is missing or empty" >&2
        exit 1
    fi
    (umask 077 && cat "$TOKEN_SRC" >/etc/jepsen/token.new)
    chmod 600 /etc/jepsen/token.new
    mv /etc/jepsen/token.new /etc/jepsen/token
fi
# LoadCredential refuses to start the unit when the file is missing.
[ -f /etc/jepsen/token ] || install -m 600 /dev/null /etc/jepsen/token
[ -f /etc/jepsen/jepsen.env ] || cp "$SCRIPT_DIR/jepsen.env.example" /etc/jepsen/jepsen.env

# The checkout is the code under test (the build and tests/jepsen); the night moves it to the
# tip of main itself. The runner is not in it: it is installed below.
if [ ! -d "$CHECKOUT/.git" ]; then
    runuser -u jepsen -- env HOME="$HOME_DIR" \
        git clone --quiet https://github.com/NervaLog/nerva.git "$CHECKOUT"
fi
# The toolchain and Leiningen (tests/jepsen/tools.sh, sha256 pinned) are fetched now, so a broken
# host shows today and not at 01:17.
runuser -u jepsen -- env HOME="$HOME_DIR" sh -c "cd '$CHECKOUT' && git fetch --quiet origin main && \
    git checkout --quiet --detach FETCH_HEAD && ./zig/download.sh && tests/jepsen/tools.sh >/dev/null && \
    python3 -I '$SCRIPT_DIR/test_jepsen_report.py'"

# The runner: root-owned, readable by jepsen, and under /opt, which the unit sees read-only. Each
# file is moved into place, so a night running now keeps the copy it started with.
mkdir -p "$BIN_DIR"
for file in nightly.sh jepsen_report.py; do
    mode=644
    [ "$file" != nightly.sh ] || mode=755
    install -m "$mode" "$SCRIPT_DIR/$file" "$BIN_DIR/.$file.new"
    mv -f "$BIN_DIR/.$file.new" "$BIN_DIR/$file"
done
cp "$SCRIPT_DIR/jepsen.service" /etc/systemd/system/jepsen.service
cp "$SCRIPT_DIR/jepsen.timer" /etc/systemd/system/jepsen.timer
systemctl daemon-reload
# A timer enabled with no token runs a whole night that cannot report: enable it only with one.
if [ -s /etc/jepsen/token ]; then
    systemctl enable jepsen.timer
else
    # A timer #235 enabled on a host with no token would still stop the fleet every night.
    systemctl disable --now jepsen.timer || true
    echo "jepsen: no token installed, so the timer is not enabled; put the token in" \
        "/etc/jepsen/token (README.md), then: systemctl enable --now jepsen.timer" >&2
fi

# Keep the journal from filling the disk (the fleet's drop-in sets the same value).
mkdir -p /etc/systemd/journald.conf.d
printf '[Journal]\nSystemMaxUse=2G\n' >/etc/systemd/journald.conf.d/jepsen.conf
systemctl restart systemd-journald

if [ -s /etc/jepsen/token ]; then
    systemctl start jepsen.timer
    echo "jepsen: the timer is on (01:17 UTC); systemctl list-timers jepsen.timer"
    echo "jepsen: to run a night now: systemctl start jepsen.service; journalctl -u jepsen -f"
fi
