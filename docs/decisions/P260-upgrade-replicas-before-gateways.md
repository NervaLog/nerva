---
id: P260
date: 2026-11-10
area: Releases
amends: N61
---

# v0.7.0 upgrades replicas before gateways, and rolls back only if no gateway has combined requests

**Decision.** The owner decided on 2026-11-10 that v0.7.0 ships with corrected documentation:
no v0.6.2 and no protocol bump. The CHANGELOG's "Upgrading from v0.6.1" says to upgrade every
replica before any gateway, never to run a v0.7.0 gateway (or any client that sends several
batches in one request) while a v0.6.1 replica is in the cluster, and that a rollback to v0.6.1
is safe only if none of them has run since the upgrade. It no longer promises that a v0.6.1
binary can always open what v0.7.0 wrote. The fix for #254 and #255 (#263, #267) is listed under
"Fixed", with advice to every v0.6.1 operator to upgrade.

**Why.** v0.6.1 replicas panic on every replay of an op of resent keyed transactions over
`min`/`max` view members, and v0.7.0 gateways combine up to 16 requests into one op (P143), so
such ops become likely. Both releases are protocol `0.0.6`, so they share a cluster, and N61
and the v0.7.0 audit's first draft said that was safe. Release reviewers B (#272) and A (#270)
found that it is not.

**What it costs.** Operators must order their upgrade and cannot treat rollback as always safe.
Nothing stops a v0.7.0 gateway from combining requests in front of a v0.6.1 replica: it is
documentation only. A gateway that refuses to combine until the cluster runs a release with the
fix would need a release bump, which the owner declined. The upgrade-with-hazard case has not
been run against a real v0.6.1 binary.
