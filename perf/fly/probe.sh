#!/bin/bash
# Runs on a Fly Machine at boot. Answers the Phase 0 questions, writes /data/probe.txt,
# then touches /data/probe.done and idles until the driver destroys the Machine.
set -u
out=/data/probe.txt
exec > >(tee "$out") 2>&1
section() { echo; echo "=== $*"; }
# Replicas authenticate each other (P102); any key of 32 bytes or more.
NERVA_CLUSTER_KEY="$(head -c 32 /dev/urandom | od -An -tx1 | tr -d ' \n')"
export NERVA_CLUSTER_KEY

section host
uname -a; nproc; free -m; df -h /data; findmnt -no FSTYPE,OPTIONS /data
echo "FLY_PRIVATE_IP=${FLY_PRIVATE_IP:-unset} FLY_VM_MEMORY_MB=${FLY_VM_MEMORY_MB:-unset}"
nerva version

section "direct io: production format + start (no --development)"
rm -f /data/p_0.nerva
if nerva format --cluster=0 --replica=0 --replica-count=1 /data/p_0.nerva; then
  (sleep 15) | timeout 20 nerva start --addresses=0 /data/p_0.nerva > /data/start.log 2>&1
  echo "start exit=$? (124 = still running at timeout = good)"
  tail -5 /data/start.log
  grep -iE "direct|O_DIRECT|error" /data/start.log | head -5
else
  echo "FORMAT FAILED"
fi
rm -f /data/p_0.nerva

section "private ipv6: 3 replicas + nerva api on [${FLY_PRIVATE_IP:-?}]"
ip=${FLY_PRIVATE_IP:-}
if [ -n "$ip" ]; then
  addrs="[$ip]:3001,[$ip]:3002,[$ip]:3003"
  pids=()
  for r in 0 1 2; do
    rm -f /data/c_$r.nerva
    nerva format --cluster=0 --replica=$r --replica-count=3 --development /data/c_$r.nerva >/dev/null 2>&1
    nerva start --development --addresses="$addrs" /data/c_$r.nerva > /data/c_$r.log 2>&1 &
    pids+=($!)
  done
  sleep 5
  NERVA_KEY=probe nerva api --cluster=0 --addresses="$addrs" --listen=127.0.0.1:8080 > /data/api.log 2>&1 &
  pids+=($!)
  sleep 3
  for i in 1 2 3 4 5; do
    curl -sS -m 10 -H 'X-Nerva-Key: probe' -d '{"entries":[{"kind":"put","table":1,"id":"'$i'","value_hex":"c0ffee"}]}' http://127.0.0.1:8080/v1/commit; echo
  done
  start=$(date +%s%N)
  for i in $(seq 1 50); do curl -sS -m 10 -o /dev/null -H 'X-Nerva-Key: probe' -d '{"rows":[{"table":1,"id":"1"}]}' http://127.0.0.1:8080/v1/lookup; done
  echo "50 lookups via api: $(( ($(date +%s%N) - start) / 50000000 )) ms each (development config, informal)"
  kill "${pids[@]}" 2>/dev/null; wait "${pids[@]}" 2>/dev/null
  tail -3 /data/api.log
  rm -f /data/c_*.nerva
else
  echo "FLY_PRIVATE_IP unset"
fi

section "perf_event_open"
cat /proc/sys/kernel/perf_event_paranoid
perf stat -e task-clock,cycles,instructions -- sleep 0.2 2>&1 | tail -8
perf record -F 99 -g -o /tmp/p.data -- sleep 1 2>&1 | tail -2 && perf report -i /tmp/p.data --stdio 2>/dev/null | head -5

section "fio on /data (direct=1)"
f="--directory=/data --size=4G --direct=1 --ioengine=libaio --time_based --runtime=20 --group_reporting --output-format=terse --terse-version=3"
for job in "randwrite 4k 32" "randread 4k 32" "write 512k 8" "read 512k 8"; do
  set -- $job
  r=$(fio --name=p --rw=$1 --bs=$2 --iodepth=$3 $f 2>&1)
  # terse v3: field 7/8 = read bw KiB/s / IOPS, 48/49 = write bw KiB/s / IOPS
  echo "$job: $(echo "$r" | awk -F';' '{printf "read %d MiB/s %d IOPS, write %d MiB/s %d IOPS", $7/1024, $8, $48/1024, $49}')"
done
rm -f /data/p.*

section done
echo PROBE_DONE > /data/probe.done
exec sleep infinity
