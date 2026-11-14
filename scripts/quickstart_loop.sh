#!/usr/bin/env bash
# Runs the one-machine half of docs/QUICKSTART.md in a loop (#305) and reports,
# per run, the time from the gateway's start to its `listening` line.
# Usage: scripts/quickstart_loop.sh <nerva-binary> [runs=30] [workdir=$TMPDIR] [slow_s=15]
# Needs bash, curl, awk and perl (all present on Linux and macOS); times have millisecond resolution.
# A run slower than slow_s keeps its replica and gateway logs in <workdir>/slow_<n>/.
# Data files (1.1 GiB each) are deleted after every run, and on exit, Ctrl-C or SIGTERM.
# Exit 0: every run ready. 1: a run hit the 150 s cap (the #305 symptom). 2: bad setup, a
# format failure, or the QUICKSTART.md commands changed. 3: a replica or the gateway died at
# startup (its error line is printed; nothing is counted as a hang).
# The commands below mirror docs/QUICKSTART.md steps 1 to 3; the guard below refuses to run
# if the page's commands drift from them.
set -u
NERVA_ARG=${1:?usage: quickstart_loop.sh <nerva> [runs] [workdir] [slow_s]}
NERVA=$(cd "$(dirname "$NERVA_ARG")" && pwd)/$(basename "$NERVA_ARG")
RUNS=${2:-30}
WORK=${3:-${TMPDIR:-/tmp}/quickstart_loop}
SLOW=${4:-15}
CAP=150
KILL_WAIT=10
mkdir -p "$WORK" && WORK=$(cd "$WORK" && pwd) || exit 2
HERE=$(cd "$(dirname "$0")" && pwd)

# Drift guard: each command line this script runs must still be on the page.
QS="$HERE/../docs/QUICKSTART.md"
for line in \
  '"$NERVA" format --cluster=1 --replica=$i --replica-count=3 --development 1_$i.nerva' \
  '"$NERVA" start --addresses=3001,3002,3003 --development 1_$i.nerva > replica_$i.log 2>&1 &' \
  '"$NERVA" api --cluster=1 --addresses=3001,3002,3003 --listen=127.0.0.1:8080 > api.log 2>&1 &' \
  'export NERVA_KEY=secret'; do
  grep -qF -- "$line" "$QS" || { echo "QUICKSTART.md changed: '$line' is gone; update this script"; exit 2; }
done

# kill -0 is true for a zombie (an exited child not yet waited for), so read the state.
alive() { local s; s=$(ps -o stat= -p "$1" 2>/dev/null); [ -n "$s" ] && [ "${s#Z}" = "$s" ]; }
now() { perl -MTime::HiRes=time -e 'printf "%.3f\n", time'; }
lt() { awk -v a="$1" -v b="$2" 'BEGIN { exit !(a < b) }'; }
sub() { awk -v a="$1" -v b="$2" 'BEGIN { printf "%.3f\n", a - b }'; }

pids=(); names=(); d=
# Stops every child it started: SIGTERM, then SIGKILL (naming the survivor) after KILL_WAIT s.
stop_children() {
  local k p
  [ "${#pids[@]}" -gt 0 ] || return 0
  kill "${pids[@]}" 2>/dev/null
  for k in $(seq 1 $((KILL_WAIT * 10))); do
    for p in "${pids[@]}"; do alive "$p" && continue 2; done
    break
  done
  for k in "${!pids[@]}"; do
    if alive "${pids[$k]}"; then
      echo "${names[$k]} (pid ${pids[$k]}) survived SIGTERM for $KILL_WAIT s; sent SIGKILL"
      kill -KILL "${pids[$k]}" 2>/dev/null
    fi
  done
  wait 2>/dev/null
  pids=(); names=()
}
cleanup() { stop_children; cd "$WORK" && [ -n "$d" ] && rm -rf "$d"; }
trap cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM

# The ports must be free, or the run would measure someone else's processes.
port_busy() { (exec 3<>"/dev/tcp/127.0.0.1/$1") 2>/dev/null; }
for p in 3001 3002 3003 8080; do
  if port_busy "$p"; then echo "port $p is already in use; stop the process holding it (a quickstart cluster?)"; exit 2; fi
done

first_error() { grep -m1 '^error\[' "$1" 2>/dev/null || tail -n 1 "$1" 2>/dev/null; }

times=(); capped=0
for r in $(seq 1 "$RUNS"); do
  d="$WORK/run_$r"; rm -rf "$d"; mkdir -p "$d"; cd "$d" || exit 2
  for i in 0 1 2; do
    "$NERVA" format --cluster=1 --replica=$i --replica-count=3 --development 1_$i.nerva > format_$i.log 2>&1 \
      || { echo "run $r: format of replica $i failed: $(first_error format_$i.log)"; exit 2; }
  done
  for i in 0 1 2; do
    "$NERVA" start --addresses=3001,3002,3003 --development 1_$i.nerva > replica_$i.log 2>&1 & pids+=($!); names+=("replica $i")
  done
  sleep 5
  for i in 0 1 2; do
    if ! alive "${pids[$i]}" || ! grep -q listening replica_$i.log; then
      echo "run $r: replica $i did not start: $(first_error replica_$i.log)"; exit 3
    fi
  done
  export NERVA_KEY=secret
  t0=$(now)
  "$NERVA" api --cluster=1 --addresses=3001,3002,3003 --listen=127.0.0.1:8080 > api.log 2>&1 & api_pid=$!; pids+=($api_pid); names+=("gateway")
  while :; do
    grep -q listening api.log && break
    alive "$api_pid" || { echo "run $r: gateway exited before listening: $(first_error api.log)"; exit 3; }
    lt "$(sub "$(now)" "$t0")" "$CAP" || break
    sleep 0.1
  done
  if grep -q listening api.log; then
    t=$(sub "$(now)" "$t0"); h=$(curl -s -m 10 -H "X-Nerva-Key: $NERVA_KEY" http://127.0.0.1:8080/healthz)
  else t=$CAP; h=TIMEOUT; capped=$((capped+1)); fi
  printf 'run %d: listening after %.2f s, healthz %s\n' "$r" "$t" "$h"
  times+=("$t")
  if lt "$SLOW" "$t" || [ "$h" != '{"ok":true,"session":"ready"}' ]; then
    mkdir -p "$WORK/slow_$r"; cp ./*.log "$WORK/slow_$r/"
  fi
  stop_children
  cd "$WORK" && rm -rf "$d"; d=
done
printf '%s\n' "${times[@]}" | sort -n | awk -v c="$capped" '{ a[NR] = $1 } END {
  k = int(NR * 0.99); if (k < NR * 0.99) k++
  printf "runs %d  p50 %.2f s  p99 %.2f s  max %.2f s  capped %d\n", NR, a[int((NR + 1) / 2)], a[k], a[NR], c }'
[ "$capped" = 0 ]
