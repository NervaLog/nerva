# Maturity

**Maturity: alpha.**

That line is the only place the label is set; other pages link here. Alpha means: try Nerva,
report what breaks, and expect at least one export and import before 1.0. Nerva has had no external correctness review
yet ([GOALS-1.0](./GOALS-1.0.md), non-goals; [PRODUCTION.md](./PRODUCTION.md)): its testing is the
project's own. Do not hold real money, or data you cannot rebuild elsewhere, only in Nerva. The
promises below are all there are.

## What it promises

- **Within v0.7.x, a newer release is meant to open an older one's data files in place.**
  Upgrade every replica before any gateway (P260). v0.7.1 is meant to change no protocol, data
  file or state machine format (P284), and slice 7's release audit (to be filled in; it does
  not exist yet) is what confirms that and checks each such upgrade path. Downgrades are not
  promised. v0.6.1, v0.7.0 and v0.7.1 share release `0.0.6` and so one cluster, which is why
  the order matters (#272).
- **The next protocol release moves by export and import.** The first release that ships rolling
  upgrades (R6) does not open v0.7.x data files. The move is `nerva export` with the old release
  and `nerva import` with the new one, with the cluster closed (P259g;
  [Upgrading a cluster](../README.md#upgrading-a-cluster)).
- **An export is read by at least the next release.** Format versions are listed under
  [Upgrading a cluster](../README.md#upgrading-a-cluster); a release reads every version
  before it, back to v0.4.0, except that from v0.5.0 to v0.6.0 `import` refuses rows in tables
  from `2147483648` up (P123e). This rests on N80's design. What is tested is an export read
  across two builds of one commit (`tests/release/upgrade.py`), not an export written by a real
  earlier release.
- **Wire identifiers and NRV codes keep their spelling** (P147c;
  [docs/ERRORS.md](./ERRORS.md)). `conflict`, `out_of_bounds`, `unpaired`, `key_reused` and the
  other identifiers clients match on, and every `NRV-` code, are never renamed, renumbered or
  reused.
- **Anything else in the API may change**, with notes in
  [CHANGELOG.md](../CHANGELOG.md): routes, fields and messages that are not in the two lists
  above.

## What it does not promise

- No rolling upgrades and no retention yet: commit keys, history and view versions grow without
  bound, and an upgrade across a protocol release closes the cluster for as long as the export
  and import take ([docs/PRODUCTION.md](./PRODUCTION.md), R6 and R7).
- Sizing was measured on one host, not on the three-machine topology (R3).
- No security beyond what [SECURITY.md](../SECURITY.md) lists, and the
  [non-goals](./NON-GOALS.md) stay non-goals until a milestone changes them.
- No external correctness review or security audit.
- Production use is on Linux. macOS is for development and evaluation.

## What was tested for this release

_Not filled in yet. The release slice (slice 7 of v0.7.1) fills this section in at release from
the release commit: the simulation fleet's tracker line, the Jepsen night's result and the two
reviewers' verdicts. Until then this section holds no numbers._

## Support

GitHub issues on [NervaLog/nerva](https://github.com/NervaLog/nerva/issues). There is no SLA
and no other support channel. A vulnerability goes through [SECURITY.md](../SECURITY.md), not
an issue.

## Where to go next

[INSTALL.md](./INSTALL.md) and [QUICKSTART.md](./QUICKSTART.md) get a cluster running;
[OPERATING.md](./OPERATING.md) says how to run it, back it up and upgrade it, and
[TROUBLESHOOTING.md](./TROUBLESHOOTING.md) what to do when it refuses.
