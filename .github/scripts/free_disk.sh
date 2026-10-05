#!/usr/bin/env bash
# Keeps a CI job from starting on a full disk (docs/DECISIONS.md N65). Run from the repository
# root before installing Zig.
#
# Each runner Machine has a 10 GB volume that keeps the Zig toolchain and Zig's global build
# cache between jobs. The build cache grows with every branch built and nothing pruned it, so a
# Machine that got a well-used volume ran out of disk on the integration test's first data file.
# Below `free_min_gib` free on the workspace's or the cache's filesystem, this empties the build
# cache (a job rebuilds what it needs) and older toolchains, never the pinned one, and logs what
# it found either way, so a full disk shows in the log.
set -euo pipefail

free_min_gib=${FREE_MIN_GIB:-6}
cache="${XDG_CACHE_HOME:-$HOME/.cache}"
toolchain="zig-$(sha256sum zig/download.sh | cut -c1-16)"
mkdir -p "$cache"

free_gib() {
  df --output=avail -B1G "$1" | tail -1 | tr -d ' '
}

report() {
  echo "$1: workspace ${PWD} has $(free_gib .) GiB free; cache ${cache} has $(free_gib "$cache") GiB free"
  df -h . "$cache" | sed 's/^/  /'
}

report "Disk"
if [ "$(free_gib .)" -ge "$free_min_gib" ] && [ "$(free_gib "$cache")" -ge "$free_min_gib" ]; then
  exit 0
fi

echo "Below ${free_min_gib} GiB free: emptying the Zig build cache and older toolchains"
du -sh "$cache"/* 2>/dev/null | sed 's/^/  /' || true
rm -rf "$cache/zig"
if [ -d "$cache/nerva-toolchain" ]; then
  find "$cache/nerva-toolchain" -mindepth 1 -maxdepth 1 ! -name "$toolchain" -exec rm -rf {} +
fi
report "After"
if [ "$(free_gib .)" -lt "$free_min_gib" ] || [ "$(free_gib "$cache")" -lt "$free_min_gib" ]; then
  echo "::warning::still below ${free_min_gib} GiB free after emptying the Zig caches"
  du -sh "$cache"/* "$PWD"/.zig-cache 2>/dev/null | sed 's/^/  /' || true
fi
