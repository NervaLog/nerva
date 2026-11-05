---
id: N6-N20
date: 2026-10-04
area: "Milestone 2b: the first gateway (superseded)"
---

# Superseded by N39.

An application-specific HTTP gateway, differential tests against
that application's reference implementation, and its storage choices. Two choices outlived it,
in `documents.zig`: values longer than a row are chunked across rows (N12), and chunk ids are
the first 8 bytes of SHA-256 over the key (N13), with tail chunks' ids derived from chunk 0's
(N25).
