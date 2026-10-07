#!/bin/bash
# The nightly performance run, on the perf Machine (docs/DECISIONS.md N56).
#
# Runs every microbenchmark and every load workload for the `baseline` and `candidate` builds in
# /opt/perf/<role>/ (nerva, bench, bench-load), interleaved over PERF_ROUNDS rounds (A B, B A,
# A B, ...), and appends one JSON line per result to $PERF_DATA/results.jsonl. Writes PERF_DONE
# to $PERF_DATA/done when finished, whatever happened, then idles until the Machine is destroyed.
#
# Environment: PERF_ROUNDS (3), PERF_SECONDS (20 per workload), PERF_CLIENTS (8),
# PERF_WORKLOADS (all), PERF_DEVELOPMENT=1 (start replicas with --development, for dry runs
# on machines without Direct IO), PERF_DATA (/data), PERF_BIN (/opt/perf), PERF_IDLE (1).
set -u

rounds=${PERF_ROUNDS:-3}
seconds=${PERF_SECONDS:-20}
clients=${PERF_CLIENTS:-8}
data=${PERF_DATA:-/data}
bin=${PERF_BIN:-/opt/perf}
development=()
[ "${PERF_DEVELOPMENT:-0}" = 1 ] && development=(--development)
# Replicas authenticate each other with the cluster key (P102): one random key per run unless
# one is given, never printed. Builds from before P102 ignore it.
export NERVA_CLUSTER_KEY=${NERVA_CLUSTER_KEY:-$(head -c 32 /dev/urandom | od -An -tx1 | tr -d ' \n')}
# workload:batch pairs; the key in the results is "<workload>/b<batch>".
workloads=${PERF_WORKLOADS:-"c1:1 c1:64 c2:1 c3:1 c3_adds:1 c4:1 c4:64 c5:1024 c7:1"}

results=$data/results.jsonl
log=$data/run.log
mkdir -p "$data"
: > "$results"
exec > >(tee -a "$log") 2>&1

emit() { # role round kind json
  printf '{"role":"%s","commit":"%s","round":%d,"kind":"%s","result":%s}\n' \
    "$1" "$(cat "$bin/$1/commit")" "$2" "$3" "$4" >> "$results"
}

health() {
  echo "=== health"
  local r
  r=$(fio --name=h --directory="$data" --size=1G --direct=1 --ioengine=libaio --rw=randwrite \
    --bs=4k --iodepth=32 --time_based --runtime=20 --output-format=json 2>/dev/null |
    python3 -c 'import json,sys; j=json.load(sys.stdin)["jobs"][0]["write"]; print(json.dumps({"iops":round(j["iops"]),"mib_s":round(j["bw"]/1024,1)}))' ||
    echo '{"error":"fio failed"}')
  rm -f "$data"/h.*
  printf '{"role":"machine","round":0,"kind":"health","result":%s}\n' "$r" >> "$results"
  echo "$r"
}

micro() { # role round
  echo "=== micro $1 round $2"
  "$bin/$1/bench" 2>&1 | sed -n 's/^bench-json: //p' | while read -r line; do
    emit "$1" "$2" micro "$line"
  done
}

load() { # role round
  local role=$1 round=$2 dir=$data/cluster pids=() addresses=127.0.0.1:3001,127.0.0.1:3002,127.0.0.1:3003
  echo "=== load $role round $round"
  rm -rf "$dir"; mkdir -p "$dir"
  for r in 0 1 2; do
    "$bin/$role/nerva" format --cluster=0 --replica=$r --replica-count=3 "${development[@]}" \
      "$dir/$r.nerva" > "$dir/format-$r.log" 2>&1 || { echo "format failed"; cat "$dir/format-$r.log"; return 1; }
  done
  for r in 0 1 2; do
    "$bin/$role/nerva" start --addresses=$addresses "${development[@]}" "$dir/$r.nerva" \
      > "$dir/replica-$r.log" 2>&1 &
    pids+=($!)
  done
  # A replica that cannot start (a missing key, a bad flag) exits at once: record that, rather
  # than workloads against a cluster that is not there.
  sleep 2
  for r in 0 1 2; do
    if ! kill -0 "${pids[$r]}" 2>/dev/null; then
      echo "replica $r exited at start"; tail -5 "$dir/replica-$r.log"
      for pair in $workloads; do
        emit "$role" "$round" error "{\"key\":\"${pair%%:*}/b${pair##*:}\",\"error\":\"replica $r exited at start\"}"
      done
      kill "${pids[@]}" 2>/dev/null; wait "${pids[@]}" 2>/dev/null
      rm -rf "$dir"
      return 1
    fi
  done
  for pair in $workloads; do
    local workload=${pair%%:*} batch=${pair##*:} out
    out=$("$bin/$role/bench-load" --addresses=$addresses --workload="$workload" --batch="$batch" \
      --clients="$clients" --seconds="$seconds" --keys=100000 --seed=$((round * 1000 + 1)) \
      2> "$dir/bench-load.err")
    if [ -n "$out" ]; then
      emit "$role" "$round" load "$(printf '%s' "$out" | python3 -c 'import json,sys; r=json.load(sys.stdin); r["key"]=r["workload"]+"/b"+str(r["batch"]); print(json.dumps(r))')"
      echo "$workload/b$batch: $out"
    else
      echo "$workload/b$batch: no result"; tail -5 "$dir/bench-load.err"
      emit "$role" "$round" error "{\"key\":\"$workload/b$batch\",\"error\":\"bench-load failed\"}"
    fi
  done
  kill "${pids[@]}" 2>/dev/null; wait "${pids[@]}" 2>/dev/null
  rm -rf "$dir"
}

echo "=== perf nightly: baseline $(cat "$bin/baseline/commit") candidate $(cat "$bin/candidate/commit")"
health
for round in $(seq 1 "$rounds"); do
  # Alternate the order each round so drift over the night falls on both builds alike.
  if [ $((round % 2)) = 1 ]; then order="baseline candidate"; else order="candidate baseline"; fi
  for role in $order; do
    micro "$role" "$round"
    load "$role" "$round"
  done
done
echo "=== done: $(wc -l < "$results") results"
echo PERF_DONE > "$data/done"
[ "${PERF_IDLE:-1}" = 1 ] && exec sleep infinity
exit 0
