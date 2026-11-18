---
id: P478
date: 2026-11-18
area: Releases
---

# `start` owns the binary's path; `MultiversionOS` borrows it

**Decision.** `MultiversionOS.init` keeps the binary's path without copying it. It reads that
path to poll the binary every second and to re-execute it at a release transition. In
`nerva_main`, the path is now:
- read in `start`'s own scope, with `self_exe_path`;
- passed to `bundle_open`;
- freed by a `defer` registered before `MultiversionOS.deinit`'s, so it is freed after it.

Before this, `bundle_open` freed the path on return (#477).

**Why.** This is the ownership upstream TigerBeetle has: its `Command` owns `self_exe_path` for
the life of the process, and `MultiversionOS` borrows it. `nerva_main` is the only caller of
`MultiversionOS.init`, so the fix stays in Nerva's own file. The vendored `multiversion.zig` does
not change: it does not copy the path, and it does not take ownership in `init` and free it in
`deinit`.

**What it costs.** The borrow is a contract the type does not enforce. A second caller of
`MultiversionOS.init` must keep its path alive just as long. `bundle_open`'s parameter comment
says so, and `test:release` (`bundle.py`'s poll check) fails if the path is freed early.
