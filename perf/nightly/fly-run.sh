#!/bin/bash
# Runs the nightly performance comparison on a Fly Machine created for it, and destroys the
# Machine and its volume on exit, whether the run succeeded or not (docs/DECISIONS.md N56).
#
# Usage: fly-run.sh <builds> <results.jsonl>
#   <builds>/baseline and <builds>/candidate each hold nerva, bench, bench-load and `commit`.
# Environment: FLY_API_TOKEN; FLY_APP (nerva-perf), FLY_REGION (iad), FLY_SIZE (performance-8x),
# FLY_MEMORY_MB (16384), FLY_VOLUME_GB (50), FLY (flyctl), and PERF_ROUNDS, PERF_SECONDS,
# PERF_CLIENTS, PERF_WORKLOADS, passed through to run.sh.
set -euo pipefail
builds=$1; results=$2
app=${FLY_APP:-nerva-perf}; region=${FLY_REGION:-iad}; size=${FLY_SIZE:-performance-8x}
memory=${FLY_MEMORY_MB:-16384}; volume_gb=${FLY_VOLUME_GB:-50}; fly=${FLY:-flyctl}
here=$(cd "$(dirname "$0")" && pwd)
run_id="nightly-$(date -u +%Y%m%d%H%M%S)"
volume_name="perf_$(date -u +%Y%m%d%H%M%S)"
mid=""; vol=""

cleanup() {
  set +e
  [ -n "$mid" ] && $fly machine destroy "$mid" -a "$app" --force
  [ -n "$vol" ] && $fly volumes destroy "$vol" -a "$app" --yes
  echo "cleanup done for $run_id"
}
trap cleanup EXIT

# Sweep anything a cancelled run left behind (older than four hours).
cutoff=$(date -u -d '4 hours ago' +%Y-%m-%dT%H:%M:%S)
$fly machine list -a "$app" --json | python3 -c '
import json, sys
cutoff = sys.argv[1]
for m in json.load(sys.stdin):
    if m.get("created_at", "")[:19] < cutoff:
        print(m["id"])' "$cutoff" | while read -r stale; do
  echo "sweeping stale machine $stale"; $fly machine destroy "$stale" -a "$app" --force || true
done
$fly volumes list -a "$app" --json | python3 -c '
import json, sys
cutoff = sys.argv[1]
for v in json.load(sys.stdin):
    if v.get("created_at", "")[:19] < cutoff and not v.get("attached_machine_id"):
        print(v["id"])' "$cutoff" | while read -r stale; do
  echo "sweeping stale volume $stale"; $fly volumes destroy "$stale" -a "$app" --yes || true
done

# The image's build context: the two builds and the runner.
context=$(mktemp -d)
cp -r "$builds/baseline" "$builds/candidate" "$here/run.sh" "$here/Dockerfile" "$context/"

vol=$($fly volumes create "$volume_name" -a "$app" -r "$region" -s "$volume_gb" --yes --json |
  python3 -c 'import json,sys; print(json.load(sys.stdin)["id"])')
echo "volume $vol"
cd "$context"
mid=$($fly machine run . -a "$app" -r "$region" --vm-size "$size" --vm-memory "$memory" \
  -v "$vol:/data" --name "$run_id" --metadata nerva_perf_run="$run_id" --restart no \
  --autostop=off --detach \
  -e PERF_ROUNDS="${PERF_ROUNDS:-3}" -e PERF_SECONDS="${PERF_SECONDS:-20}" \
  -e PERF_CLIENTS="${PERF_CLIENTS:-8}" -e PERF_WORKLOADS="${PERF_WORKLOADS:-}" 2>&1 |
  tee /dev/stderr | grep -oE 'Machine ID: [a-z0-9]+' | awk '{print $3}')
[ -n "$mid" ] || { echo "no machine id"; exit 1; }
echo "machine $mid"
$fly machine wait "$mid" -a "$app" --state started --wait-timeout 5m

# Poll for the done marker for up to 2 hours; print progress every 5 minutes.
for i in $(seq 1 240); do
  if $fly machine exec "$mid" -a "$app" "cat /data/done" 2>/dev/null | grep -q PERF_DONE; then break; fi
  if [ $((i % 10)) = 0 ]; then
    $fly machine exec "$mid" -a "$app" "tail -n 2 /data/run.log" 2>/dev/null || true
  fi
  sleep 30
done
$fly machine exec "$mid" -a "$app" "cat /data/done" 2>/dev/null | grep -q PERF_DONE ||
  { echo "the run did not finish in time"; exit 1; }

# Results, compressed and base64 encoded to pass through exec's output intact.
$fly machine exec "$mid" -a "$app" "sh -c 'gzip -c /data/results.jsonl | base64 -w0'" |
  tr -d '\r\n' | base64 -d | gunzip > "$results"
$fly machine exec "$mid" -a "$app" "cat /data/run.log" > "${results%.jsonl}.log" || true
echo "results: $(wc -l < "$results") lines"
