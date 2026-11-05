#!/bin/sh
# Sets up the simulation fleet on a fresh Ubuntu 24.04 host (ops/sim-fleet/README.md). Run as
# root: `sh setup.sh [--token-file PATH] [--deploy-key-file PATH]`. Safe to run again. Secrets
# are copied from files (never printed, never passed as argument values) to /etc/sim-fleet, mode
# 0600. It starts the service only when a token is present. It stops a running service first,
# so its build never races the service's, and starts it again at the end.
set -eu
# This script's directory, resolved before the `cd /` below: run by a relative path, as the
# README's "Deploy" says, `dirname "$0"` would be read against / (#178).
SCRIPT_DIR=$(CDPATH= cd -P -- "$(dirname -- "$(readlink -f -- "$0")")" && pwd -P)
# `su simfleet` keeps the working directory, which simfleet may not be allowed to read.
cd /

HOME_DIR=/var/lib/sim-fleet
CHECKOUT=$HOME_DIR/nerva
# GitHub's published SSH host key (docs.github.com, "GitHub's SSH key fingerprints"):
# SHA256:+DiY3wvvV6TuJJhbpZisF/zLDA0zPMSvHdkr4UvCOqU.
# Used only with an ssh remote (a private repository). Unverified from this session: check it
# against https://docs.github.com/en/authentication/keeping-your-account-and-data-secure/githubs-ssh-key-fingerprints before relying on it.
GITHUB_HOST_KEY='github.com ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIOMqqnkVzrm0SdG6UOoqKLsabgH5C9okWi0dh2l9GKJl'

TOKEN_SRC=""
KEY_SRC=""
while [ $# -gt 0 ]; do
    case "$1" in
    --token-file | --deploy-key-file)
        if [ $# -lt 2 ]; then
            echo "setup.sh: $1 needs a path" >&2
            exit 1
        fi
        if [ "$1" = --token-file ]; then TOKEN_SRC=$2; else KEY_SRC=$2; fi
        shift 2
        ;;
    *)
        echo "usage: setup.sh [--token-file PATH] [--deploy-key-file PATH]" >&2
        exit 1
        ;;
    esac
done

if [ "$(id -u)" -ne 0 ]; then
    echo "setup.sh: run as root" >&2
    exit 1
fi

apt-get update -q
apt-get install -y -q git curl xz-utils ca-certificates python3 openssh-client util-linux

if ! id simfleet >/dev/null 2>&1; then
    useradd --system --create-home --home-dir "$HOME_DIR" --shell /usr/sbin/nologin simfleet
fi
mkdir -p /etc/sim-fleet
chmod 700 /etc/sim-fleet

# Copies secret file $1 to $2, mode 0600, without printing it.
install_secret() {
    if [ ! -s "$1" ]; then
        echo "setup.sh: $1 is missing or empty" >&2
        exit 1
    fi
    (umask 077 && cat "$1" >"$2.new")
    chmod 600 "$2.new"
    mv "$2.new" "$2"
}
if [ -n "$TOKEN_SRC" ]; then install_secret "$TOKEN_SRC" /etc/sim-fleet/token; fi
if [ -n "$KEY_SRC" ]; then install_secret "$KEY_SRC" /etc/sim-fleet/deploy-key; fi
# LoadCredential refuses to start the unit when a file it names is missing.
[ -f /etc/sim-fleet/token ] || install -m 600 /dev/null /etc/sim-fleet/token
[ -f /etc/sim-fleet/deploy-key ] || install -m 600 /dev/null /etc/sim-fleet/deploy-key
echo "$GITHUB_HOST_KEY" >"$HOME_DIR/known_hosts"
chown simfleet:simfleet "$HOME_DIR/known_hosts"

if [ ! -f /etc/sim-fleet/fleet.env ]; then
    cp "$SCRIPT_DIR/fleet.env.example" /etc/sim-fleet/fleet.env
fi
# The remote fleet.env names (a private repository is fetched over SSH with the deploy key).
REMOTE=$(sed -n 's/^SIM_FLEET_REMOTE=//p' /etc/sim-fleet/fleet.env | tail -n1)
REMOTE=${REMOTE:-https://github.com/NervaLog/nerva.git}

# MemoryMax from this host (P179): the shipped unit's 56G suits a 64 GB host, and on a smaller one
# the kernel's global OOM killer acts before the cgroup limit does. The drop-in caps the service
# at MemTotal - 1 GiB (at most the unit's 56G), so the cgroup limit is hit first and sshd and the
# journal keep their memory; run.sh then takes its workers from that limit. Worked out, and
# refused, before anything is stopped: a host too small for one seed is not left with the fleet
# down. Rewritten on every run, so run it again after resizing the host.
mem_total_mb=$(awk '/^MemTotal:/ { print int($2 / 1024) }' /proc/meminfo)
mem_max_mb=$((mem_total_mb - 1024))
[ "$mem_max_mb" -le 57344 ] || mem_max_mb=57344
seed_mb=$(sed -n 's/^SIM_FLEET_SEED_MEMORY_MB=//p' /etc/sim-fleet/fleet.env | tail -n1)
# One pair of surrounding quotes is dropped, as systemd's EnvironmentFile= does.
case "$seed_mb" in
\"*\" | \'*\') seed_mb=${seed_mb#?}; seed_mb=${seed_mb%?} ;;
esac
seed_mb=${seed_mb:-4096}
case "$seed_mb" in
'' | *[!0-9]* | 0 | 00*)
    echo "setup.sh: SIM_FLEET_SEED_MEMORY_MB in /etc/sim-fleet/fleet.env is '$seed_mb', not a positive number" >&2
    exit 1
    ;;
esac
if [ "$mem_max_mb" -lt "$seed_mb" ]; then
    echo "setup.sh: $mem_total_mb MB of memory leaves $mem_max_mb MB for the service, and a seed" \
        "needs about $seed_mb MB (SIM_FLEET_SEED_MEMORY_MB); use a bigger host" >&2
    exit 1
fi

if systemctl is-active --quiet sim-fleet.service; then
    echo "sim-fleet: stopping the service for the setup build"
    systemctl stop sim-fleet.service
fi

# The first clone and build run as simfleet, with a copy of the deploy key it can read only for
# this step.
key_copy=""
if [ -s /etc/sim-fleet/deploy-key ]; then
    key_copy=$(mktemp)
    cat /etc/sim-fleet/deploy-key >"$key_copy"
    chown simfleet "$key_copy"
    chmod 600 "$key_copy"
    GIT_SSH_COMMAND="ssh -i $key_copy -o IdentitiesOnly=yes \
-o UserKnownHostsFile=$HOME_DIR/known_hosts -o StrictHostKeyChecking=yes"
fi
# Runs shell text $1 as simfleet, with the deploy key's GIT_SSH_COMMAND if there is one.
run_as_simfleet() {
    if [ -n "$key_copy" ]; then
        runuser -u simfleet -- env HOME="$HOME_DIR" GIT_SSH_COMMAND="$GIT_SSH_COMMAND" sh -c "$1"
    else
        runuser -u simfleet -- env HOME="$HOME_DIR" sh -c "$1"
    fi
}
if [ ! -d "$CHECKOUT/.git" ]; then
    run_as_simfleet "git clone --quiet '$REMOTE' '$CHECKOUT'"
fi
# A first build of main, so the toolchain is downloaded and a broken host shows now, not at
# 3 a.m. run.sh builds each new tip itself.
run_as_simfleet "cd '$CHECKOUT' && timeout 300 git fetch --quiet origin main && \
    git checkout --quiet --detach FETCH_HEAD && ./zig/download.sh && \
    ./zig/zig build -Drelease -Dvopr-state-machine=nerva vopr:build && \
    python3 ops/sim-fleet/test_sim_fleet.py"
if [ -n "$key_copy" ]; then rm -f "$key_copy"; fi

cp "$CHECKOUT/ops/sim-fleet/sim-fleet.service" /etc/systemd/system/sim-fleet.service
mkdir -p /etc/systemd/system/sim-fleet.service.d
# Named to sort after `override.conf` (`systemctl edit`), so no hand-made cap silently wins.
rm -f /etc/systemd/system/sim-fleet.service.d/memory.conf
printf '[Service]\nMemoryMax=%sM\n' "$mem_max_mb" \
    >/etc/systemd/system/sim-fleet.service.d/zz-memory.conf
systemctl daemon-reload
effective=$(systemctl show -p MemoryMax --value sim-fleet.service)
if [ "$effective" != $((mem_max_mb * 1048576)) ]; then
    echo "sim-fleet: warning: MemoryMax is $effective bytes, not ${mem_max_mb}M; another drop-in" \
        "or the unit overrides zz-memory.conf (systemctl cat sim-fleet)" >&2
fi
systemctl enable sim-fleet.service

# Keep the journal from filling the disk.
mkdir -p /etc/systemd/journald.conf.d
printf '[Journal]\nSystemMaxUse=2G\n' >/etc/systemd/journald.conf.d/sim-fleet.conf
systemctl restart systemd-journald

if [ -s /etc/sim-fleet/token ]; then
    systemctl restart sim-fleet.service
    echo "sim-fleet: started; journalctl -u sim-fleet -f"
else
    echo "sim-fleet: installed, not started. Put the token in /etc/sim-fleet/token (README.md)," >&2
    echo "then: systemctl start sim-fleet" >&2
fi
