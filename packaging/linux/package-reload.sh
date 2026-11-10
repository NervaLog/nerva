#!/bin/sh
# Part of Nerva (https://github.com/NervaLog/nerva): the .deb's postinst and postrm, one script
# (v0.7.1, P295). After the units are unpacked or removed it runs `systemctl daemon-reload` when
# systemd is running, as install.sh does, so that `systemctl restart nerva@0` runs the new unit and
# not the one systemd loaded earlier. It starts, stops and restarts nothing. (The .rpm needs no
# such script: systemd's rpm file triggers reload after a transaction that changes a unit.)
set -eu

case "${1:-}" in
    configure | remove | purge) ;;
    *) exit 0 ;;
esac
if command -v systemctl > /dev/null 2>&1 && [ -d /run/systemd/system ]; then
    systemctl daemon-reload || true
fi
