#!/usr/bin/env bash
# Runs the one-machine half of docs/QUICKSTART.md in a loop (#305) and reports,
# per run, the time from the gateway's start to its `listening` line.
# Usage: scripts/quickstart_loop.sh <nerva-binary> [runs=30] [workdir=$TMPDIR] [slow_s=15]
# A run slower than slow_s keeps its replica and gateway logs in <workdir>/slow_<n>/.
# Data files (1.1 GiB each) are deleted after every run. Exit 1 if any run hit the 150 s cap.
set -u
NERVA=$(realpath "${1:?usage: quickstart_loop.sh <nerva> [runs] [workdir] [slow_s]}")
RUNS=${2:-30}
WORK=${3:-${TMPDIR:-/tmp}/quickstart_loop}
SLOW=${4:-15}
CAP=150
mkdir -p "$WORK"
now() { date +%s.%N; }
times=(); capped=0
for r in $(seq 1 "$RUNS"); do
  d="$WORK/run_$r"; rm -rf "$d"; mkdir -p "$d"; cd "$d" || exit 2
  for i in 0 1 2; do
    "$NERVA" format --cluster=1 --replica=$i --replica-count=3 --development 1_$i.nerva > format_$i.log 2>&1 || { echo "run $r: format failed"; exit 2; }
  done
  pids=()
  for i in 0 1 2; do
    "$NERVA" start --addresses=3001,3002,3003 --development 1_$i.nerva > replica_$i.log 2>&1 & pids+=($!)
  done
  sleep 5
  export NERVA_KEY=secret
  t0=$(now)
  "$NERVA" api --cluster=1 --addresses=3001,3002,3003 --listen=127.0.0.1:8080 > api.log 2>&1 & pids+=($!)
  while ! grep -q listening api.log && [ "$(echo "$(now) - $t0 < $CAP" | bc)" = 1 ]; do sleep 0.1; done
  if grep -q listening api.log; then
    t=$(echo "$(now) - $t0" | bc); h=$(curl -s -m 10 -H "X-Nerva-Key: $NERVA_KEY" http://127.0.0.1:8080/healthz)
  else t=$CAP; h=TIMEOUT; capped=$((capped+1)); fi
  printf 'run %d: listening after %.2f s, healthz %s\n' "$r" "$t" "$h"
  times+=("$t")
  if [ "$(echo "$t > $SLOW" | bc)" = 1 ] || [ "$h" != '{"ok":true,"session":"ready"}' ]; then
    mkdir -p "$WORK/slow_$r"; cp ./*.log "$WORK/slow_$r/"
  fi
  kill "${pids[@]}" 2>/dev/null; wait 2>/dev/null
  cd "$WORK" && rm -rf "$d"
done
printf '%s\n' "${times[@]}" | sort -n | awk -v c="$capped" '{ a[NR] = $1 } END {
  k = int(NR * 0.99); if (k < NR * 0.99) k++
  printf "runs %d  p50 %.2f s  p99 %.2f s  max %.2f s  capped %d\n", NR, a[int((NR + 1) / 2)], a[k], a[NR], c }'
[ "$capped" = 0 ]
