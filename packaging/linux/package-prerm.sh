#!/bin/sh
# Part of Nerva (https://github.com/NervaLog/nerva): the .deb's prerm and the .rpm's preun scriptlet,
# one script (v0.7.1, P295). On removal only, it disables the instances the operator enabled
# (nerva@0, nerva-api@0), as `install.sh --uninstall` does (P286b): left behind the links dangle,
# and a later install would make them live again. It never stops anything, so a running replica
# keeps running, and an upgrade (dpkg `upgrade`, rpm's count 1) does nothing. The text never uses a
# percent sign: the .rpm embeds it in its spec.
set -eu

# dpkg passes `remove` (also for a purge, which removes first); rpm passes the count left, 0.
case "${1:-}" in
    remove | 0) ;;
    *) exit 0 ;;
esac
command -v systemctl > /dev/null 2>&1 || exit 0

unit_dir=/etc/systemd/system
for link in "$unit_dir"/*.wants/nerva@*.service "$unit_dir"/*.wants/nerva-api@*.service; do
    [ -L "$link" ] || continue
    systemctl disable "$(basename "$link")" > /dev/null || true
done
