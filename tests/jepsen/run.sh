#!/usr/bin/env bash
# Runs the Jepsen suite against five Docker containers on this machine, each a node with one
# replica and one `nerva api` gateway (tests/jepsen/README.md). Needs Docker (privileged
# containers, for iptables), ssh-keygen, gnuplot (Jepsen's graphs; without it a result is
# `:unknown`), a JDK (21) and Leiningen: $LEIN, else `lein` on PATH, else the pinned 2.12.0
# that tools.sh downloads into tests/jepsen/.tools/. $NERVA_CLUSTER_KEY (at least 32 bytes) is
# the replicas' cluster key; unset, the test makes a fresh random one (db.clj).
#
#   run.sh <path to nerva> <lein run arguments...>
#   run.sh ../../zig-out/bin/nerva test --workload bank --nemesis kill,partition --time-limit 300
#   run.sh ../../zig-out/bin/nerva test-all --time-limit 120
#
# Results land in tests/jepsen/store/ (`lein run serve` browses them). The containers and
# their network are removed on exit, whatever happens.
set -euo pipefail

here=$(cd "$(dirname "$0")" && pwd)
nerva=$(realpath "$1")
shift
[[ -x "$nerva" ]] || { echo "not an executable: $nerva" >&2; exit 2; }

network=nerva-jepsen
subnet=10.77.0.0/24
nodes=(10.77.0.11 10.77.0.12 10.77.0.13 10.77.0.14 10.77.0.15)
image=nerva-jepsen-node
key="$here/.ssh/id_ed25519"

mkdir -p "$here/.ssh"
[[ -f "$key" ]] || ssh-keygen -q -t ed25519 -N '' -C nerva-jepsen -f "$key"

cleanup() {
  for i in "${!nodes[@]}"; do docker rm -f "nerva-jepsen-n$((i + 1))" > /dev/null 2>&1 || true; done
  docker network rm "$network" > /dev/null 2>&1 || true
}
trap cleanup EXIT
cleanup

# JEPSEN_LAZYFS_PATCH=no builds stock LazyFS: the teeth canary of the lose-unfsynced-writes fault.
docker build -q --build-arg "LAZYFS_PATCH=${JEPSEN_LAZYFS_PATCH:-yes}" -t "$image" "$here/node" > /dev/null
docker network create --subnet "$subnet" "$network" > /dev/null
# LazyFS (the lose-unfsynced-writes fault) mounts a FUSE filesystem in each node: it needs the
# host's /dev/fuse, which --privileged also exposes; passing it by name keeps it explicit.
fuse=()
[[ -e /dev/fuse ]] && fuse=(--device /dev/fuse)
# The public key is copied in, not mounted: a mounted file keeps its owner on the host (`runner`
# in CI), and sshd refuses root an authorized_keys file another user owns.
for i in "${!nodes[@]}"; do
  docker run -d --name "nerva-jepsen-n$((i + 1))" --hostname "n$((i + 1))" \
    --network "$network" --ip "${nodes[$i]}" --privileged ${fuse[@]+"${fuse[@]}"} "$image" > /dev/null
  docker exec -i "nerva-jepsen-n$((i + 1))" \
    sh -c 'cat > /root/.ssh/authorized_keys && chown root:root /root/.ssh/authorized_keys && chmod 600 /root/.ssh/authorized_keys' \
    < "$key.pub"
done

# sshd is up once its port answers.
for node in "${nodes[@]}"; do
  for _ in $(seq 1 50); do
    (exec 3<> "/dev/tcp/$node/22") 2> /dev/null && break
    sleep 0.2
  done
done

lein=${LEIN:-}
if [[ -z "$lein" ]]; then
  if command -v lein > /dev/null; then
    lein=lein
  else
    lein=$("$here/tools.sh")
    export LEIN_JAR="$here/.tools/leiningen-standalone.jar"
  fi
fi

cd "$here"
node_list=$(IFS=,; echo "${nodes[*]}")
"$lein" run "$@" --nodes "$node_list" --username root --ssh-private-key "$key" \
  --nerva-binary "$nerva"
