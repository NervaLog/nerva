#!/bin/sh
# Part of Nerva (https://github.com/NervaLog/nerva): the .deb's preinst and the .rpm's pre scriptlet, one
# script (v0.7.1, P284b; docs/briefs/v0.7.1.md, slice 5). It creates the system user `nerva`,
# /var/lib/nerva (0750, nerva:nerva) and /etc/nerva (0750, root:nerva), and does nothing else:
# it never formats, enables, starts or removes anything, and no removal script touches the data.
# A second run changes nothing. A user or group named nerva that is not the one install.sh makes
# is refused with NRV-E1105, and a tarball install still on the machine (install.sh's binary in
# /usr/local/bin or its units in /etc/systemd/system, which would shadow the package's) with
# NRV-E1111, both before the package's files are unpacked. The NRV-E1111 check runs on a first
# install only (dpkg `install`, with or without an old version; rpm `1`): on an upgrade, a file
# there is the operator's own (`systemctl edit --full`, a source-built binary), not a tarball
# install (#319). On an upgrade a /usr/local/bin/nerva left behind still shadows the package's
# binary, so the script warns about it (NRV-W1101) and goes on. The text never uses a percent sign:
# the .rpm embeds it in its spec.
set -eu

# dpkg calls the preinst with `install`, `upgrade` or `abort-upgrade`; rpm passes a count.
case "${1:-}" in
    abort-*) exit 0 ;;
esac

# A first install: dpkg `install` (also passed, with the old version, when reinstalling after a
# removal without purge) or rpm `1`. dpkg `upgrade` and rpm 2 or more are upgrades.
case "${1:-}" in
    upgrade | [2-9] | [1-9][0-9]*) first_install=no ;;
    *) first_install=yes ;;
esac

user=nerva
data_dir=/var/lib/nerva
etc_dir=/etc/nerva

refuse() { # <headline> <fix>
    echo "error[NRV-E1105]: nerva package: $1" >&2
    echo "  cause  A user, group or unit named nerva exists and is not the one Nerva's installer makes" >&2
    echo "  fix    $2" >&2
    exit 1
}

setup_failed() { # <what> <fix>: the tool's own message is already on stderr, above this block
    echo "error[NRV-E1163]: nerva package: could not $1" >&2
    echo "  cause  A tool that creates the service user or a directory the package needs refused; its own message is printed just above" >&2
    echo "  fix    $2" >&2
    exit 1
}

# A file install.sh would make, or one that overrides the package's, shadows the package's:
# /usr/local/bin comes before /usr/bin on the PATH and /etc/systemd/system overrides
# /usr/lib/systemd/system. It is a tarball install's, a source build's or a full unit override.
# install.sh does not look for the package's /usr/bin/nerva (#292), so nothing refuses the reverse.
if [ "$first_install" = yes ]; then
    for left in /usr/local/bin/nerva /etc/systemd/system/nerva@.service /etc/systemd/system/nerva-api@.service; do
        if [ -e "$left" ]; then
            echo "error[NRV-E1111]: nerva package: $left exists and is not this package's" >&2
            echo "  cause  A file that is not this package's (a tarball install, a source build or a full unit override) would shadow the package's binary or units" >&2
            echo "  fix    if it is a tarball install, stop its replicas with systemd, run install.sh --uninstall from the tarball (it keeps /var/lib/nerva, /etc/nerva and the user; its enabled nerva@N and nerva-api@N instances are removed, as no package is installed yet, so enable them again after installing the package); otherwise move or remove the file (change a unit with a drop-in); then install the package" >&2
            exit 1
        fi
    done
elif [ -e /usr/local/bin/nerva ]; then
    # An upgrade is not refused (#319), but the file still comes first on the PATH, and both units
    # run a bare nerva, so the replicas would keep running it instead of the package's new binary.
    echo "warning[NRV-W1101]: nerva package: /usr/local/bin/nerva exists and shadows this package's /usr/bin/nerva" >&2
    echo "  cause  /usr/local/bin comes before /usr/bin on the path, and the units run nerva by name, so the replicas run that file and not the package's new nerva" >&2
    echo "  fix    keep one install: if it is a tarball install, stop the nerva@N and nerva-api@N replicas with systemd, run install.sh --uninstall from the tarball (it keeps /var/lib/nerva, /etc/nerva, the user and the enabled nerva@N and nerva-api@N instances), then start the replicas; otherwise move or remove the file. Enable any instance that is not enabled" >&2
fi

if getent passwd "$user" > /dev/null 2>&1; then
    home=$(getent passwd "$user" | cut -d: -f6)
    if [ "$home" != "$data_dir" ]; then
        refuse "the user $user exists, with home $home" \
            "rename or remove that user, or give it the home $data_dir"
    fi
    group=$(id -gn "$user" 2> /dev/null || true)
    if [ "$group" != "$user" ]; then
        refuse "the user $user exists, with primary group ${group:-unknown}" \
            "give the user the primary group $user (usermod -g $user $user), or remove the user"
    fi
elif getent group "$user" > /dev/null 2>&1; then
    refuse "the group $user exists, and the user $user does not" \
        "remove the group (groupdel $user), or create the user $user with it as primary group (useradd -g $user ...)"
else
    useradd --system --user-group --home-dir "$data_dir" --no-create-home \
        --shell /usr/sbin/nologin "$user" ||
        setup_failed "create the system user $user" \
            "find why useradd refused (its message is above: /etc/passwd read-only or managed by LDAP, no free system uid, SELinux), or create the user yourself (useradd --system --user-group --home-dir $data_dir --no-create-home --shell /usr/sbin/nologin $user), then install the package again"
fi

dir_fix="find why install -d refused (its message is above: a read-only file system, no space, a path that is a file), fix that, then install the package again"
install -d -m 750 -o root -g "$user" "$etc_dir" ||
    setup_failed "make the directory $etc_dir" "$dir_fix"
install -d -m 750 -o "$user" -g "$user" "$data_dir" ||
    setup_failed "make the directory $data_dir" "$dir_fix"
