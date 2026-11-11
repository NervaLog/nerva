#!/bin/sh
# Installs Nerva from the release tarball this script sits in (v0.7.1, P284b; docs/briefs/v0.7.1.md).
#
#   sudo ./install.sh [--dry-run] [--upgrade]
#   sudo ./install.sh --uninstall [--dry-run]
#
# As root it puts `nerva` in /usr/local/bin, creates the system user `nerva`, /var/lib/nerva
# (0750) and /etc/nerva (0750), installs the units nerva@.service and nerva-api@.service in
# /etc/systemd/system and runs `systemctl daemon-reload`. It never formats, enables or starts
# anything, and prints the next three commands. A second run changes nothing. A `nerva` of
# another release is replaced only with --upgrade. --uninstall removes the binary and the units
# and leaves /var/lib/nerva, /etc/nerva and the user. --dry-run prints what would change, and
# changes nothing; it runs the same checks as a real run.
#
# Every refusal is one coded diagnostic, as `nerva`'s are (docs/ERRORS.md, 11xx).
set -eu
# Root trusts nothing of the caller's environment: a fixed PATH, and no CDPATH (`cd` would print).
PATH=/usr/sbin:/usr/bin:/sbin:/bin
export PATH
unset CDPATH

bin_dir=/usr/local/bin
unit_dir=/etc/systemd/system
data_dir=/var/lib/nerva
etc_dir=/etc/nerva
user=nerva
units="nerva@.service nerva-api@.service"
examples="replica.env.example api.env.example"
marker="^# Part of Nerva "

# refuse <status> <code> <headline> <cause> <fix>: one block, as `nerva` prints, then exit.
refuse() {
    printf 'error[%s]: install.sh: %s\n  cause  %s\n  fix    %s\n' "$2" "$3" "$4" "$5" >&2
    exit "$1"
}

dry=0
upgrade=0
uninstall=0
for arg in "$@"; do
    case "$arg" in
        --dry-run) dry=1 ;;
        --upgrade) upgrade=1 ;;
        --uninstall) uninstall=1 ;;
        -h | --help)
            sed -n '2,15p' "$0" | sed 's/^# \{0,1\}//'
            exit 0
            ;;
        *)
            refuse 1 NRV-E1106 "unknown argument $arg" \
                "install.sh was given a flag or a combination of flags it does not take" \
                "usage: install.sh [--dry-run] [--upgrade] | --uninstall [--dry-run] (see --help)"
            ;;
    esac
done
if [ "$upgrade" = 1 ] && [ "$uninstall" = 1 ]; then
    refuse 1 NRV-E1106 "--upgrade and --uninstall do not go together" \
        "install.sh was given a flag or a combination of flags it does not take" \
        "usage: install.sh [--dry-run] [--upgrade] | --uninstall [--dry-run] (see --help)"
fi

# do_ <description> <command...>: runs the command, or only says it would.
do_() {
    description=$1
    shift
    if [ "$dry" = 1 ]; then
        echo "would $description"
    else
        echo "$description"
        "$@"
    fi
}

here=$(cd "$(dirname "$0")" && pwd)

# 1. Checks. Nothing is changed before all of them pass.
if [ "$(id -u)" != 0 ]; then
    refuse 1 NRV-E1101 "must run as root" \
        "The installer was not run as root" "run it with sudo"
fi
if ! command -v systemctl > /dev/null 2>&1 || [ ! -d /run/systemd/system ]; then
    refuse 2 NRV-E1102 "this machine is not running systemd" \
        "The installer found no running systemd" \
        "install on a machine that boots with systemd, or run nerva by hand (docs/QUICKSTART.md)"
fi
if ! command -v sha256sum > /dev/null 2>&1; then
    refuse 2 NRV-E1109 "sha256sum is not installed" \
        "The installer needs sha256sum, and this machine has none on its PATH" \
        "install coreutils, then run install.sh again"
fi
# elf_machine <file>: the ELF header's machine as `uname -m` names it, or nothing when the file is
# not an ELF this installer knows (x86_64, aarch64).
elf_machine() {
    [ "$(od -An -tx1 -N4 "$1" | tr -d ' \n')" = 7f454c46 ] || return 0
    case "$(od -An -tx1 -j18 -N2 "$1" | tr -d ' \n')" in
        3e00) echo x86_64 ;;
        b700) echo aarch64 ;;
    esac
}
if [ "$uninstall" = 0 ]; then
    for file in nerva $units $examples; do
        if [ ! -f "$here/$file" ]; then
            refuse 1 NRV-E1108 "$here/$file is missing" \
                "The tarball is incomplete, or install.sh was run outside the unpacked tarball" \
                "unpack the release tarball whole, and run install.sh from its directory"
        fi
    done
    # A dry run changes nothing, the permissions of the tarball's files included: it cannot run a
    # nerva that is not executable, so it skips that check and says so.
    runnable=1
    if [ "$dry" = 1 ] && [ ! -x "$here/nerva" ]; then
        echo "would make $here/nerva executable (0755); a dry run does not run it to check it"
        runnable=0
    elif [ "$dry" = 0 ]; then
        chmod 0755 "$here/nerva" 2> /dev/null || true
    fi
    host=$(uname -m)
    [ "$host" != arm64 ] || host=aarch64
    built=$(elf_machine "$here/nerva")
    if [ -n "$built" ] && [ "$built" != "$host" ]; then
        refuse 2 NRV-E1104 "the nerva in $here is for $built, and this machine is $host" \
            "The tarball's nerva is for another architecture than this machine's" \
            "download the tarball for this machine: x86_64-linux or aarch64-linux"
    fi
    status=0
    [ "$runnable" = 0 ] || "$here/nerva" version > /dev/null 2>&1 || status=$?
    if [ "$status" != 0 ]; then
        refuse 2 NRV-E1107 "the nerva in $here cannot run (exit status $status)" \
            "This machine cannot run the tarball's nerva, though it is for this architecture" \
            "unpack the tarball where programs may run (not a noexec mount such as /tmp on a hardened host), and run '$here/nerva version' to see why"
    fi
fi
if getent passwd "$user" > /dev/null 2>&1; then
    home=$(getent passwd "$user" | cut -d: -f6)
    if [ "$home" != "$data_dir" ]; then
        refuse 1 NRV-E1105 "the user $user exists, with home $home" \
            "A user, group or unit named nerva exists and is not the one Nerva's installer makes" \
            "rename or remove that user, or give it the home $data_dir"
    fi
    group=$(id -gn "$user" 2> /dev/null || true)
    if [ "$group" != "$user" ]; then
        refuse 1 NRV-E1105 "the user $user exists, with primary group ${group:-unknown}" \
            "A user, group or unit named nerva exists and is not the one Nerva's installer makes" \
            "give the user the primary group $user (usermod -g $user $user), or remove the user"
    fi
elif getent group "$user" > /dev/null 2>&1; then
    refuse 1 NRV-E1105 "the group $user exists, and the user $user does not" \
        "A user, group or unit named nerva exists and is not the one Nerva's installer makes" \
        "remove the group (groupdel $user), or create the user $user with it as primary group (useradd -g $user ...)"
fi
for unit in $units; do
    if [ -e "$unit_dir/$unit" ] && ! grep -q "$marker" "$unit_dir/$unit" 2> /dev/null; then
        refuse 1 NRV-E1105 "$unit_dir/$unit exists and is not Nerva's" \
            "A user, group or unit named nerva exists and is not the one Nerva's installer makes" \
            "move it away, or change it with a drop-in (systemctl edit) and keep Nerva's"
    fi
done
sum_of() { sha256sum "$1" | cut -d' ' -f1; }
if [ "$uninstall" = 0 ] && [ -e "$bin_dir/nerva" ] &&
    [ "$(sum_of "$bin_dir/nerva")" != "$(sum_of "$here/nerva")" ] && [ "$upgrade" = 0 ]; then
    installed=$("$bin_dir/nerva" version 2> /dev/null | head -n1 || true)
    refuse 1 NRV-E1103 "$bin_dir/nerva is a different build (${installed:-unknown})" \
        "A different nerva is already installed" \
        "pass --upgrade to replace it with this one (stop the replicas first, then restart them)"
fi
# The nerva the units run now: $bin_dir's, else a package's (the units find $bin_dir first). Putting
# a different one first means a replica that restarts runs the new binary: a cluster of two
# releases, or NRV-E0701 across a protocol release. Units still starting or stopping count as
# running. A unit started after this check and before the install is not seen.
current=
if [ -e "$bin_dir/nerva" ]; then
    current=$bin_dir/nerva
elif [ -e /usr/bin/nerva ]; then
    current=/usr/bin/nerva
fi
# refuse_if_running <what>: NRV-E1118 when a replica or gateway unit runs now, and NRV-E1102 when
# systemctl cannot say (fail closed).
refuse_if_running() {
    list=$(systemctl list-units --plain --no-legend --state=active,activating,deactivating,reloading \
        'nerva@*.service' 'nerva-api@*.service' 2> /dev/null) || refuse 2 NRV-E1102 \
        "systemctl could not list the nerva units, so a running replica would not be seen" \
        "The installer found no running systemd" \
        "run systemctl list-units 'nerva@*' to see why it fails (no bus, or a chroot), then run install.sh again"
    running=$(printf '%s\n' "$list" | cut -d' ' -f1 | tr '\n' ' ')
    if [ -n "${running% }" ]; then
        refuse 1 NRV-E1118 "$1 while units are running: ${running% }" \
            "install.sh found a replica or gateway unit running, and would replace the nerva it executes" \
            "stop them (systemctl stop 'nerva@*' 'nerva-api@*'), run install.sh again (--upgrade over a tarball install; --uninstall to remove it), then start them; across a protocol release upgrade by export and import (README, Upgrading a cluster)"
    fi
}
if [ "$uninstall" = 0 ] && [ -n "$current" ] && [ "$(sum_of "$current")" != "$(sum_of "$here/nerva")" ]; then
    refuse_if_running "an install over $current"
fi
# --uninstall removes $bin_dir/nerva: a replica that restarts then runs a package's /usr/bin/nerva
# (another release, #292's hazard) or finds none.
if [ "$uninstall" = 1 ] && [ -e "$bin_dir/nerva" ]; then
    refuse_if_running "an uninstall of $bin_dir/nerva"
fi
if [ "$uninstall" = 0 ] && [ -e /usr/bin/nerva ]; then
    printf 'warning[NRV-W1102]: install.sh: /usr/bin/nerva exists and %s/nerva shadows it\n  cause  install.sh found a package'"'"'s /usr/bin/nerva, which the tarball'"'"'s %s/nerva shadows\n  fix    leave the package installed (removing it disables the enabled nerva@N and nerva-api@N instances, so none starts at the next boot; run systemctl enable for each again after; install.sh --uninstall keeps them while the package is installed)\n' \
        "$bin_dir" "$bin_dir" >&2
fi

# 2. Uninstall.
if [ "$uninstall" = 1 ]; then
    changed=0
    if [ -e "$bin_dir/nerva" ]; then
        do_ "remove $bin_dir/nerva" rm -f "$bin_dir/nerva"
        changed=1
    fi
    # The enable links of instances the operator enabled (nerva@0, nerva-api@0): left behind they
    # dangle, and a later install would make them live again.
    # A package's /usr/bin/nerva means its units serve the same instances: the links stay (P340).
    for link in "$unit_dir"/*.wants/nerva@*.service "$unit_dir"/*.wants/nerva-api@*.service; do
        [ -L "$link" ] || continue
        if [ -e /usr/bin/nerva ]; then
            echo "keep $(basename "$link"): the package's /usr/bin/nerva is installed and uses it"
            continue
        fi
        do_ "disable $(basename "$link") (remove the link $link)" \
            systemctl disable "$(basename "$link")"
        changed=1
    done
    for unit in $units; do
        if [ -e "$unit_dir/$unit" ]; then
            do_ "remove $unit_dir/$unit" rm -f "$unit_dir/$unit"
            changed=1
        fi
    done
    if [ "$changed" = 1 ]; then
        do_ "run systemctl daemon-reload" systemctl daemon-reload
        echo "Replicas that are running keep running: stop them (systemctl stop 'nerva@*')."
    else
        echo "nothing to remove"
    fi
    echo "left in place: $data_dir (your data), $etc_dir (your settings) and the user $user"
    exit 0
fi

# 3. Install. Each step does nothing when it is already done.
if ! getent passwd "$user" > /dev/null 2>&1; then
    do_ "create the system user $user (home $data_dir, no login)" \
        useradd --system --user-group --home-dir "$data_dir" --no-create-home \
        --shell /usr/sbin/nologin "$user"
fi
if [ "$dry" = 1 ] && ! getent passwd "$user" > /dev/null 2>&1; then
    owner=root
else
    owner=$user
fi
ensure_dir() { # <path> <mode> <group>
    if [ ! -d "$1" ] || [ "$(stat -L -c '%a %U %G' "$1")" != "$2 root $3" ]; then
        do_ "make $1 ($2, root:$3)" install -d -m "$2" -o root -g "$3" "$1"
    fi
}
ensure_dir "$etc_dir" 750 "$owner"
if [ ! -d "$data_dir" ] || [ "$(stat -L -c '%a %U %G' "$data_dir")" != "750 $owner $owner" ]; then
    do_ "make $data_dir (750, $owner:$owner)" install -d -m 750 -o "$owner" -g "$owner" "$data_dir"
fi

# put <source> <destination> <mode>: copies when the destination is missing or different, and
# never rewrites an identical file (so a second run leaves every mtime alone).
put() {
    if [ -e "$2" ] && [ "$(sum_of "$1")" = "$(sum_of "$2")" ]; then
        return 0
    fi
    base=$(dirname "$2")
    if [ "$dry" = 1 ]; then
        echo "would install $2"
    else
        echo "install $2"
        install -m "$3" -o root -g root "$1" "$base/.install.$$"
        mv -f "$base/.install.$$" "$2"
    fi
    changed=1
}
changed=0
put "$here/nerva" "$bin_dir/nerva" 755
units_changed=0
for unit in $units; do
    changed=0
    put "$here/$unit" "$unit_dir/$unit" 644
    [ "$changed" = 1 ] && units_changed=1
done
for file in $examples; do
    put "$here/$file" "$etc_dir/$file" 644
done
if [ "$units_changed" = 1 ]; then
    do_ "run systemctl daemon-reload" systemctl daemon-reload
fi

if [ "$dry" = 1 ]; then
    echo "dry run: nothing was changed"
    exit 0
fi
echo "installed: $("$bin_dir/nerva" version | head -n1)"
cat << NEXT

Nothing is formatted, enabled or started. Next, for replica 0 of three (docs/QUICKSTART.md):
  1. install -m 0600 -o root -g root /etc/nerva/replica.env.example /etc/nerva/replica-0.env   # then set the addresses and key
  2. runuser -u nerva -- $bin_dir/nerva format --cluster=1 --replica=0 --replica-count=3 /var/lib/nerva/0.nerva
  3. systemctl enable --now nerva@0
NEXT
