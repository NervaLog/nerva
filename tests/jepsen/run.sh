#!/usr/bin/env bash
# Runs the Jepsen suite against five Docker containers on this machine, each a node with one
# replica and one `nerva api` gateway (tests/jepsen/README.md). Needs Docker (privileged
# containers, for iptables), a JDK and Leiningen (`lein`, or $LEIN).
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
chmod 600 "$key.pub"

cleanup() {
  for i in "${!nodes[@]}"; do docker rm -f "nerva-jepsen-n$((i + 1))" > /dev/null 2>&1 || true; done
  docker network rm "$network" > /dev/null 2>&1 || true
}
trap cleanup EXIT
cleanup

docker build -q -t "$image" "$here/node" > /dev/null
docker network create --subnet "$subnet" "$network" > /dev/null
for i in "${!nodes[@]}"; do
  docker run -d --name "nerva-jepsen-n$((i + 1))" --hostname "n$((i + 1))" \
    --network "$network" --ip "${nodes[$i]}" --privileged \
    -v "$key.pub:/root/.ssh/authorized_keys:ro" "$image" > /dev/null
done

# sshd is up once its port answers.
for node in "${nodes[@]}"; do
  for _ in $(seq 1 50); do
    (exec 3<> "/dev/tcp/$node/22") 2> /dev/null && break
    sleep 0.2
  done
done

cd "$here"
node_list=$(IFS=,; echo "${nodes[*]}")
"${LEIN:-lein}" run "$@" --nodes "$node_list" --username root --ssh-private-key "$key" \
  --nerva-binary "$nerva"
