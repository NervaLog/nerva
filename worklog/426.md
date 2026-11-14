# Stopped: #357 needs a persisted-format change

2026-11-14

- Task: refuse a keys-off export in `nerva import` with NRV-E0732. The export file records nothing
  about the build that wrote it (`src/nerva/export_file.zig`: header is magic, version, a reserved
  u32 that readers require to be zero). Marking it is a format change, so this stops at the owner's
  question (see the PR description). No code changed.
