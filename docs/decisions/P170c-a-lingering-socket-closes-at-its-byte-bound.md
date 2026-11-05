---
id: P170c
date: 2026-11-05
area: Releases
amends: P168c
---

# A lingering socket closes as soon as it has read `linger_bytes_max`

**Decision.** After a refusal, the Receiver keeps the socket open and discards what the client still sends, until the client closes, `linger_ns` (1 s) passes, or `linger_bytes_max` (64 KiB) has arrived. At the byte bound it closes at once. If the linger table (`linger_max`, 16) is full, the reply is still written and the socket is closed at once; `lingering_dropped` counts it.

**Why.** Each bound limits what a misbehaving client can cost the gateway, while a client sending a normal-sized request still reads its reply.

**Cost.** A refused client that sends more than 64 KiB may see a reset before it reads its reply (R4 brief, risk 3).
