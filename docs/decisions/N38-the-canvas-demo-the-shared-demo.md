---
id: N38
date: 2026-10-04
area: "Milestone 3: positioned reads and the first views"
---

# The canvas demo, the shared demo base, and what profiling it found.

- The canvas is a 64 x 64 typed table (`x`, `y`, `color`, `paints`, `painter`) with three
  views; the canvas itself is a view, so a timelapse frame is the view read as of an op, as
  the seat map is (N36). A paint reads the pixel and writes it at the version read, counting
  repaints, so painters on one pixel race. The canvas clears every `--reset-minutes`.
- Moderation defaults, **to be confirmed by the owner before anything is public**: 8 colours,
  one pixel a second per visitor, a clear every hour, no free text except view names
  (lowercase letters, digits and `_`, which can still spell words: a policy question).
- `demo/common.py` holds what both demos share, including rate limits per visitor (crash or
  restart one every 5 s, declare one view every 10 s, paint 1 a second, buy 2 a second).
  `--behind-proxy` takes the visitor from `Fly-Client-IP` or `X-Forwarded-For`; otherwise the
  socket address, which a client cannot forge.
- Profiling a timelapse frame (650 ms) found that `ArrayHashMap.sort` is insertion sort, O(n²):
  a 4,096-group view took 145 ms to sort. Declared views now use `sortUnstable` (keys are
  unique): 10 ms. A Debug build had made it look like a build-mode problem; it was not.
- Measured: about 11 ms per request through one gateway to a three-replica `--development`
  cluster, so one gateway serves about 90 requests a second, enough for the demos.
- `tests/demo/canvas_chaos.py` checks that every confirmed paint is on the canvas as of its op
  (each timelapse frame is such a read), under crashes. Mutation-tested: frames that ignore
  `as_of` fail it.
