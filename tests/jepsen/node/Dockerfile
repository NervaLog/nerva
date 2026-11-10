# A Jepsen node: sshd for the control node, iptables and iproute2 for partitions, sudo for
# Jepsen's `su`, and LazyFS with FUSE for the `lose-unfsynced-writes` fault (slice 9). nerva
# itself is uploaded by the test (db.clj), so the image does not change with it.

# LazyFS, built from one pinned commit (tag 0.3.0, the version `jepsen.lazyfs` is written for)
# plus `lazyfs-osync.patch` (P242d, #246): LazyFS drops the acknowledged writes of a file opened
# O_DSYNC unless it syncs in `lfs_write`. The commit is the pin: the build fails if the checkout
# is not exactly it, or if the patch does not apply. Its two build-time
# downloads, toml11 v3.7.1 and spdlog 1.10.0, are named by tag and URL in LazyFS's CMakeLists
# at this commit, so they move only with the commit.
FROM debian:bookworm-slim AS lazyfs
ARG LAZYFS_COMMIT=9c5685e828da8b5d113d2f9134f6671e481d7162
# `no` builds stock LazyFS, the teeth canary of the lose-unfsynced-writes checkers (P242h): with
# `--lazyfs-strict-sync` (hosted) or `--lazyfs-all-nodes` (R1 host) they must fail on it (P242j).
# Never `no` in a real run. The patch's upstream issue: https://github.com/dsrhaslab/lazyfs/issues/25
# (the full-cache write-through, P242f, is #24).
ARG LAZYFS_PATCH=yes
RUN apt-get update \
 && apt-get install -y --no-install-recommends \
      build-essential cmake git ca-certificates libfuse3-dev fuse3 \
 && rm -rf /var/lib/apt/lists/*
COPY lazyfs-osync.patch /tmp/
RUN git init -q /opt/jepsen/lazyfs \
 && cd /opt/jepsen/lazyfs \
 && git remote add origin https://github.com/dsrhaslab/lazyfs.git \
 && git fetch -q --depth 1 origin "$LAZYFS_COMMIT" \
 && git checkout -q FETCH_HEAD \
 && test "$(git rev-parse HEAD)" = "$LAZYFS_COMMIT" \
 && if [ "$LAZYFS_PATCH" = yes ]; then git apply --check /tmp/lazyfs-osync.patch && git apply /tmp/lazyfs-osync.patch; fi \
 && (cd libs/libpcache && ./build.sh) \
 && (cd lazyfs && ./build.sh) \
 && test -x lazyfs/build/lazyfs \
 && rm -rf .git

FROM debian:bookworm-slim
RUN apt-get update \
 && apt-get install -y --no-install-recommends \
      openssh-server iptables iproute2 procps psmisc sudo ca-certificates fuse3 libfuse3-3 \
 && rm -rf /var/lib/apt/lists/* \
 && mkdir -p /run/sshd /root/.ssh \
 && chmod 700 /root/.ssh \
 && sed -i 's/^#\?PermitRootLogin.*/PermitRootLogin prohibit-password/' /etc/ssh/sshd_config \
 && sed -i 's/^#\s*user_allow_other/user_allow_other/' /etc/fuse.conf
COPY --from=lazyfs /opt/jepsen/lazyfs /opt/jepsen/lazyfs
# Every library LazyFS links must be found here, or the build fails now and not at a mount.
RUN ! ldd /opt/jepsen/lazyfs/lazyfs/build/lazyfs | grep -q 'not found'
CMD ["/usr/sbin/sshd", "-D", "-e"]
