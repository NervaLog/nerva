---
id: P415c
date: 2026-11-14
area: Releases
amends: P259
---

# A bundled `nerva` refuses to start unless `vm.memfd_noexec` is 0 (or absent)

The brief said pre-flight refuses `vm.memfd_noexec = 2` (NRV-E0720). That was too narrow.

**Decision.** `nerva start` on a bundled binary refuses any `vm.memfd_noexec` other than 0, as
NRV-E0720. An absent or unreadable file (a kernel before 6.3) is not a refusal. The hint says
"set `vm.memfd_noexec` to 0".

**Reason.** Upstream's `open_memory_file` calls `memfd_create` with `MFD_CLOEXEC` only, neither
`MFD_EXEC` nor `MFD_NOEXEC_SEAL`. The kernel's `vm.memfd_noexec` documentation says that with 1
such a call "acts like MFD_NOEXEC_SEAL was set"; with 2 it is sealed the same way (6.6 on) or
fails (6.3 to 6.5). A sealed `memfd` cannot be executed, so `execveat` at the switch gets `EACCES`
and the replica panics, which is the failure E0720 exists to prevent. Only 0 sets `MFD_EXEC`
implicitly.

**Cost.** A host that hardens with `vm.memfd_noexec = 1` cannot run a bundled binary until the
operator sets 0. Patching the vendored `memfd_create` to pass `MFD_EXEC` would lift that on
kernels that know the flag, but is a vendored change and is not made here.
