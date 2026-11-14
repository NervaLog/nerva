#!/usr/bin/env bash
# Runs the one-machine half of docs/QUICKSTART.md in a loop (#305) and reports,
# per run, the time from the gateway's start to its `listening` line.
# Usage: scripts/quickstart_loop.sh <nerva-binary> [runs=30] [workdir=${TMPDIR:-/tmp}/quickstart_loop] [slow_s=15]
# Needs bash, curl, awk and perl (all present on Linux and macOS). The clock has millisecond
# resolution and the wait for `listening` polls every 0.1 s, so a time can be late by ~0.15 s.
# Each invocation works in its own fresh <workdir>/loop.XXXXXX/ (it never touches anything else
# in workdir). A run slower than slow_s, or whose healthz is not ready, or in which a replica or
# the gateway died, keeps its replica and gateway logs in <workdir>/loop.XXXXXX/slow_<n>/; the
# script prints that directory's path before it exits, and removes the directory if nothing was kept.
# Data files (1.1 GiB each) are deleted after every run, and on exit, Ctrl-C or SIGTERM.
# Exit 0: every run ready. 1: a run hit the 150 s cap (the #305 symptom) or its healthz was not
# ready (the run is named). 2: bad arguments or setup, a format failure, or the QUICKSTART.md
# commands changed. 3: a replica or the gateway died (its error line is printed; nothing is
# counted as a hang). 130, 143: interrupted by Ctrl-C, by SIGTERM.
# Refusals print `error[NRV-E0741]` (exit 2) or `error[NRV-E0742]` (exit 3), then the failing
# process's own `error[NRV-...]` line when it printed one (docs/ERRORS.md).
# The commands below mirror docs/QUICKSTART.md steps 1 to 3; the guard below refuses to run
# if the page's commands drift from them. Keep the guard's strings in sync with the commands
# in the run loop (format, start, api, the key export and the healthz header).
set -u
refuse() { echo "error[NRV-E0741]: quickstart_loop.sh: $*" >&2; exit 2; }
died() { echo "error[NRV-E0742]: quickstart_loop.sh: $*" >&2; exit 3; }
[ $# -ge 1 ] || refuse "usage: quickstart_loop.sh <nerva> [runs] [workdir] [slow_s]"
NERVA_ARG=$1
RUNS=${2:-30}
WORK=${3:-${TMPDIR:-/tmp}/quickstart_loop}
SLOW=${4:-15}
CAP=150
KILL_WAIT=10
case "$NERVA_ARG" in
  */*) NERVA=$NERVA_ARG ;;
  *) NERVA=$(command -v -- "$NERVA_ARG") || NERVA= ;;  # a bare name is looked up on PATH
esac
if [ -z "$NERVA" ] || [ ! -f "$NERVA" ] || [ ! -x "$NERVA" ]; then
  refuse "'$NERVA_ARG' is not an executable nerva binary"
fi
NERVA=$(cd "$(dirname "$NERVA")" && pwd)/$(basename "$NERVA")
case "$RUNS" in ''|*[!0-9]*|0|0[0-9]*) refuse "runs must be a positive integer, got '$RUNS'" ;; esac
case "$SLOW" in ''|.|*[!0-9.]*|*.*.*) refuse "slow_s must be a number, got '$SLOW'" ;; esac
mkdir -p "$WORK" 2>/dev/null && WORK=$(cd "$WORK" && pwd) || refuse "cannot use workdir '$WORK'"
LOOP=$(mktemp -d "$WORK/loop.XXXXXX" 2>/dev/null) || refuse "cannot create a directory in '$WORK'"
HERE=$(cd "$(dirname "$0")" && pwd)

# Drift guard: each command line this script runs must still be on the page.
QS="$HERE/../docs/QUICKSTART.md"
[ -f "$QS" ] || { rmdir "$LOOP"; refuse "docs/QUICKSTART.md not found next to this script ($QS); run it from the repository"; }
for line in \
  '"$NERVA" format --cluster=1 --replica=$i --replica-count=3 --development 1_$i.nerva' \
  '"$NERVA" start --addresses=3001,3002,3003 --development 1_$i.nerva > replica_$i.log 2>&1 &' \
  '"$NERVA" api --cluster=1 --addresses=3001,3002,3003 --listen=127.0.0.1:8080 > api.log 2>&1 &' \
  'export NERVA_KEY=secret' \
  'curl -s -H "X-Nerva-Key: $NERVA_KEY"'; do
  grep -qF -- "$line" "$QS" || { rmdir "$LOOP"; refuse "QUICKSTART.md changed: '$line' is gone; update this script"; }
done

# kill -0 is true for a zombie (an exited child not yet waited for), so read the state.
alive() { local s; s=$(ps -o stat= -p "$1" 2>/dev/null); [ -n "$s" ] && [ "${s#Z}" = "$s" ]; }
now() { perl -MTime::HiRes=time -e 'printf "%.3f\n", time'; }
lt() { awk -v a="$1" -v b="$2" 'BEGIN { exit !(a < b) }'; }
sub() { awk -v a="$1" -v b="$2" 'BEGIN { printf "%.3f\n", a - b }'; }

pids=(); names=(); d=
# Stops every child it started: SIGTERM, then SIGKILL (naming the survivor) after KILL_WAIT s.
stop_children() {
  local k p deadline
  [ "${#pids[@]}" -gt 0 ] || return 0
  kill "${pids[@]}" 2>/dev/null
  deadline=$(awk -v n="$(now)" -v w="$KILL_WAIT" 'BEGIN { printf "%.3f\n", n + w }')
  while lt "$(now)" "$deadline"; do
    p=0
    for k in "${pids[@]}"; do alive "$k" && p=1; done
    [ "$p" = 0 ] && break
    sleep 0.1
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
# Bounded (stop_children waits at most KILL_WAIT s), so a second INT or TERM must not abort it.
cleanup() {
  trap '' INT TERM
  stop_children
  cd "$WORK" || return 0
  [ -z "$d" ] || rm -rf "$d"
  rmdir "$LOOP" 2>/dev/null
  [ ! -d "$LOOP" ] || echo "logs of the runs kept (slow, not ready, or a process died): $LOOP"
  return 0
}
trap cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM

# The ports must be free, or the run would measure someone else's processes.
port_busy() { (exec 3<>"/dev/tcp/127.0.0.1/$1") 2>/dev/null; }
for p in 3001 3002 3003 8080; do
  if port_busy "$p"; then refuse "port $p is already in use; stop the process holding it (a quickstart cluster?)"; fi
done

first_error() { grep -m1 '^error\[' "$1" 2>/dev/null || tail -n 1 "$1" 2>/dev/null; }
# Keeps run $1's logs in $LOOP/slow_$1/ (the EXIT trap names the directory).
keep_logs() { mkdir -p "$LOOP/slow_$1" && cp ./*.log "$LOOP/slow_$1/"; }
# A replica that is gone: keep the logs, say which one, exit 3.
check_replicas() {
  local i
  for i in 0 1 2; do
    if ! alive "${pids[$i]}"; then
      keep_logs "$1"; died "run $1: replica $i exited $2: $(first_error replica_$i.log)"
    fi
  done
}

times=(); capped=0; notready=()
for r in $(seq 1 "$RUNS"); do
  d="$LOOP/run_$r"; { mkdir "$d" && cd "$d"; } 2>/dev/null || refuse "run $r: cannot create or enter $d"
  for i in 0 1 2; do
    "$NERVA" format --cluster=1 --replica=$i --replica-count=3 --development 1_$i.nerva > format_$i.log 2>&1 \
      || refuse "run $r: format of replica $i failed: $(first_error format_$i.log)"
  done
  for i in 0 1 2; do
    "$NERVA" start --addresses=3001,3002,3003 --development 1_$i.nerva > replica_$i.log 2>&1 & pids+=($!); names+=("replica $i")
  done
  sleep 5
  for i in 0 1 2; do
    if ! alive "${pids[$i]}" || ! grep -q listening replica_$i.log; then
      keep_logs "$r"; died "run $r: replica $i did not start: $(first_error replica_$i.log)"
    fi
  done
  export NERVA_KEY=secret
  t0=$(now)
  "$NERVA" api --cluster=1 --addresses=3001,3002,3003 --listen=127.0.0.1:8080 > api.log 2>&1 & api_pid=$!; pids+=($api_pid); names+=("gateway")
  while :; do
    grep -q listening api.log && break
    alive "$api_pid" || { keep_logs "$r"; died "run $r: gateway exited before listening: $(first_error api.log)"; }
    check_replicas "$r" "during the gateway wait"
    lt "$(sub "$(now)" "$t0")" "$CAP" || break
    sleep 0.1
  done
  if grep -q listening api.log; then
    t=$(sub "$(now)" "$t0"); h=$(curl -s -m 10 -H "X-Nerva-Key: $NERVA_KEY" http://127.0.0.1:8080/healthz)
    printf 'run %d: listening after %.2f s, healthz %s\n' "$r" "$t" "${h:-<no answer>}"
  else
    t=$CAP; h=TIMEOUT; capped=$((capped+1))
    printf 'run %d: not listening after %d s (capped)\n' "$r" "$CAP"
  fi
  times+=("$t")
  ready=1; [ "$h" = '{"ok":true,"session":"ready"}' ] || { ready=0; [ "$h" = TIMEOUT ] || notready+=("$r"); }
  if lt "$SLOW" "$t" || [ "$ready" = 0 ]; then
    keep_logs "$r"
  fi
  stop_children
  cd "$LOOP" && rm -rf "$d"; d=
done
printf '%s\n' "${times[@]}" | sort -n | awk -v c="$capped" '{ a[NR] = $1 } END {
  k = int(NR * 0.99); if (k < NR * 0.99) k++
  printf "runs %d  p50 %.2f s  p99 %.2f s  max %.2f s  capped %d\n", NR, a[int((NR + 1) / 2)], a[k], a[NR], c }'
if [ "${#notready[@]}" -gt 0 ]; then
  echo "healthz was not ready after listening in run(s): ${notready[*]}"
fi
[ "$capped" = 0 ] && [ "${#notready[@]}" = 0 ]
