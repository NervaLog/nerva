#!/bin/bash
# Materializes a probe Machine + volume in $APP, waits for its report, prints it,
# and destroys both on exit (success, failure or Ctrl-C).
# Usage: FLY_API_TOKEN=... perf/fly/run-probe.sh <path-to-nerva-binary> [app] [region] [size]
set -euo pipefail
bin=$1; app=${2:-nerva-perf}; region=${3:-iad}; size=${4:-performance-4x}
here=$(cd "$(dirname "$0")" && pwd)
run_id="probe-$(date -u +%Y%m%d%H%M%S)"
fly=${FLY:-flyctl}
vol=""; mid=""

cleanup() {
  set +e
  [ -n "$mid" ] && $fly machine destroy "$mid" -a "$app" --force
  [ -n "$vol" ] && $fly volumes destroy "$vol" -a "$app" --yes
  echo "cleanup done for $run_id"
}
trap cleanup EXIT

cp "$bin" "$here/nerva"
vol=$($fly volumes create probe_data -a "$app" -r "$region" -s 10 --yes --json | python3 -c 'import json,sys;print(json.load(sys.stdin)["id"])')
echo "volume $vol"
cd "$here"
mid=$($fly machine run . -a "$app" -r "$region" --vm-size "$size" -v "$vol:/data" \
  --name "$run_id" --metadata nerva_perf_run="$run_id" --restart no --autostop=off --detach 2>&1 \
  | tee /dev/stderr | grep -oE 'Machine ID: [a-z0-9]+' | awk '{print $3}')
rm -f "$here/nerva"
echo "machine $mid"
$fly machine wait "$mid" -a "$app" --state started --wait-timeout 5m

for _ in $(seq 1 60); do
  if $fly machine exec "$mid" -a "$app" "cat /data/probe.done" 2>/dev/null | grep -q PROBE_DONE; then break; fi
  sleep 10
done
$fly machine exec "$mid" -a "$app" "cat /data/probe.txt"
