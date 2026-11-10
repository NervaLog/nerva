#!/bin/sh
# Part of Nerva (https://github.com/NervaLog/nerva): the .deb's preinst and the .rpm's pre scriptlet, one
# script (v0.7.1, P284b; docs/briefs/v0.7.1.md, slice 5). It creates the system user `nerva`,
# /var/lib/nerva (0750, nerva:nerva) and /etc/nerva (0750, root:nerva), and does nothing else:
# it never formats, enables, starts or removes anything, and no removal script touches the data.
# A second run changes nothing. A user or group named nerva that is not the one install.sh makes
# is refused with NRV-E1105, and a tarball install still on the machine (install.sh's binary in
# /usr/local/bin or its units in /etc/systemd/system, which would shadow the package's) with
# NRV-E1111, both before the package's files are unpacked. The text never uses a
# percent sign: the .rpm embeds it in its spec.
set -eu

# dpkg calls the preinst with `install`, `upgrade` or `abort-upgrade`; rpm passes a count.
case "${1:-}" in
    abort-*) exit 0 ;;
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

# install.sh's files shadow the package's: /usr/local/bin comes before /usr/bin on the PATH and
# /etc/systemd/system overrides /usr/lib/systemd/system. install.sh refuses the same way.
for left in /usr/local/bin/nerva /etc/systemd/system/nerva@.service /etc/systemd/system/nerva-api@.service; do
    if [ -e "$left" ]; then
        echo "error[NRV-E1111]: nerva package: $left exists, from a tarball install" >&2
        echo "  cause  A tarball install of Nerva is still on this machine and would shadow the package's binary and units" >&2
        echo "  fix    run install.sh --uninstall from the tarball (it keeps /var/lib/nerva, /etc/nerva and the user), then install the package" >&2
        exit 1
    fi
done

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
        --shell /usr/sbin/nologin "$user"
fi

install -d -m 750 -o root -g "$user" "$etc_dir"
install -d -m 750 -o "$user" -g "$user" "$data_dir"
