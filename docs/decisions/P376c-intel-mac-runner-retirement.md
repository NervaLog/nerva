---
id: P376c
date: 2026-11-12
area: CI
amends: P293
---

# When `macos-15-intel` goes, x86_64 macOS is checked under Rosetta

**Decision.** `ci.yml`'s `macos-x86_64` and `mac-verify.yml`'s x86_64 cell stay on
`macos-15-intel` while GitHub offers it. GitHub has said that Intel macOS images end with
the macOS 15 image, in about the autumn of 2027. Slice M recovers the date from the
`actions/runner-images` README when it runs.

**Trigger.** Slice M runs on the first of these:
- GitHub announces the label's retirement date;
- a brownout run fails;
- 90 days before the date.

**What slice M does.**
- Both jobs move to `macos-15` (arm64) and run the x86_64 binary under Rosetta 2. Before the
  smoke test, they run `softwareupdate --install-rosetta --agree-to-license` and check
  `arch -x86_64 /usr/bin/true`. The test itself runs `arch -x86_64 <binary> ...` on the thin
  x86_64 binary and on the universal one.
- `docs/releases/automation.md` and P293's "runs natively" become "under Rosetta".

Dropping x86_64 macOS from the release is a separate decision, for the owner, and is not taken
here.

**Reason.** Apple silicon runs x86_64 code under Rosetta, so the shipped x86_64 binary still
starts, runs its smoke test and verifies its signature. The release keeps the universal zip.

**Cost.**
- Rosetta is not native Intel hardware. A fault that occurs only on a real Intel CPU, such as a
  CPU-feature mismatch, would no longer be caught.
- Rosetta itself may be retired by Apple later.
