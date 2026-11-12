---
id: P352
date: 2026-11-11
area: Security
amends: P332
---

# The gateway key has the cluster key's 32-byte minimum; the development key guards loopback only

**Decision.** (#335) `nerva api` and `nerva view` refuse a `NERVA_KEY` or `NERVA_KEY_NEXT` shorter
than 32 bytes (`peer_auth.key_length_min`, the cluster key's own minimum), under NRV-E0008.
(#336) `nerva start` refuses `NERVA_CLUSTER_KEY` or `NERVA_CLUSTER_KEY_NEXT` equal to the published
`peer_auth.development_key` unless every address is loopback, under NRV-E0901; on loopback an
explicit development key still works, as `--development` does.

**Why.** The issues propose exactly these. 32 is already decided for the cluster key, and
`openssl rand -hex 32` (which every doc and example tells operators to run) gives 64. No new codes:
both messages extend codes P332 already extended. Nothing persisted or on the wire changes.

**Cost.** An existing deployment with a gateway key shorter than 32 bytes stops starting on
upgrade: the release's upgrade note says to set a longer key (rotate through `NERVA_KEY_NEXT`
before upgrading to avoid refusing clients). Length is the only strength rule; a long guessable key
passes. The docs' `NERVA_KEY=secret` examples became `openssl rand -hex 32`.

**Owner's answer.** 32 bytes is the minimum for the gateway key, as chosen here.

**Also refused.** A key with leading or trailing space or tab, or a control byte, is refused under
NRV-E0008 too: the header parser trims those, so no client could ever present such a key.
