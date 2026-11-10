---
id: P242e
date: 2026-11-09
area: Releases
amends: P242
---

# The LazyFS verdict checks that a sentinel was lost, not that bytes were

The decision (owner, 2026-11-09, option A): the `:lazyfs` verdict no longer requires that a clear
lost bytes of Nerva's. It requires that each clear was confirmed by LazyFS (`:remaining` 0) and that
a sentinel was lost. Before every clear, with the replica dead, `lose!` writes a 4 KiB file,
`lazyfs-sentinel`, on the LazyFS mount without syncing it (`dd`, no `fsync`, no `O_DSYNC`). After
the clear the file must be gone or smaller (`:gone`, `:truncated`). If it is still its full size
(`:survived`) the fault did not bite, and the verdict is `:unknown` with NRV-E0607 and a `:reason`.
A sentinel that was never written in full (`:unwritten`) or never checked also proves nothing. The
bytes LazyFS reports lost (`:lost-bytes`) stay in the verdict and the op, as information; the
`:no-bytes-lost` problem is gone. The verdict also reports `:sentinel`, a count by outcome.

Why: P242d made every Nerva write durable, because Nerva writes `O_DSYNC`. LazyFS then holds no
unsynced Nerva bytes, and a correct run lost 0 bytes on every clear (smoke run 42660150311: 4
faults, 0 bytes) and was `:unknown`. The fault's claim is a crash that loses what was not made
durable; with a correct Nerva that is nothing of its own, so "bytes lost" cannot be the proof. The
proof the clear works is a file that is not durable and is lost.

The "invalid" of the decision is Jepsen's `:unknown`, not `:valid? false` (CHECKLIST: a harness
problem is never a Nerva finding). The reporter reads NRV-E0607 as the host's, so it needs no change.
No new code: NRV-E0607's entry names the sentinel.

What it costs: the fault now also proves LazyFS's clear, not Nerva's data loss; a run that takes the
fault on a Nerva that was not durable would show it only through the other checkers, as before.
The sentinel's name is in the node's mount, which Nerva does not read.
