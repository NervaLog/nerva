---
id: P183b
date: 2026-11-05
area: Releases
---
NRV-E0009 is decided while the flags are parsed, before `NERVA_KEY` is read or any socket is bound.

**Decision.** `listen_resolve` (src/nerva/cli.zig) parses `--listen` and refuses a non-loopback
address there. An address that does not parse still answers NRV-E0003 first; a good address that
is not loopback answers E0009 before E0008 (`NERVA_KEY`). "Loopback" is 127.0.0.0/8 or exactly
`::1`; every IPv4-mapped IPv6 address, `::ffff:127.0.0.1` included, is not, because a dual-stack
socket would reach more than the machine.

**Why.** A refusal that depends only on the command line belongs with the other flag checks, and
refusing before binding means nothing is ever served on the wrong interface, not even briefly.

**Cost.** None beyond the order of codes above, which `tests/errors/commands.py` pins.
