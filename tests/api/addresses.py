#!/usr/bin/env python3
"""A gateway given a replica address it cannot open a socket for reports it and retries (#92).

Usage: addresses.py <nerva>

`nerva api` with a replica at `[::1]`: on a host without IPv6 the socket cannot be opened
(`AddressFamilyNotSupported`), which used to abort the gateway on an assertion in the message
bus (`tick_connect`). Now it logs the error once and dials again each tick, until its
registration times out (30 s) and it exits with an error, as for any cluster it cannot reach.
On a host with IPv6 the dial is refused instead (no replica listens there): the same exit.
Either way: exit status 1, a timeout named, no panic.
"""
import os
import subprocess
import sys
import time


def main():
    nerva = sys.argv[1]
    started = time.monotonic()
    result = subprocess.run(
        [nerva, "api", "--cluster=0", "--addresses=[::1]:3", "--listen=127.0.0.1:0"],
        capture_output=True, text=True, timeout=120,
        env={**os.environ, "NERVA_KEY": "addresses-test-key"})
    log = result.stderr
    assert "panic" not in log, log[-3000:]
    assert result.returncode == 1, (result.returncode, log[-3000:])
    assert "Timeout" in log, log[-3000:]
    unopened = log.count("init_tcp error=")
    ipv6 = os.path.exists("/proc/net/if_inet6")
    if unopened:
        assert "AddressFamilyNotSupported" in log, log[-3000:]
        lines = [line for line in log.splitlines()
                 if "error(message_bus)" in line and "init_tcp error=" in line]
        assert len(lines) == 1, lines[:5]  # Said once, though retried every tick.
    print(f"addresses: PASSED (gateway with [::1] on a host {'with' if ipv6 else 'without'} "
          f"IPv6: {'socket unopened, said once, ' if unopened else 'dial refused, '}"
          f"exit 1 on timeout, no panic; {time.monotonic() - started:.0f} s)")


if __name__ == "__main__":
    main()
