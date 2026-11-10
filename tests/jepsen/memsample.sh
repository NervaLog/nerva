#!/usr/bin/env bash
# The hosted run's memory sampler (P242j): every 5 s, one bounded block (at most 40 lines) with the
# /proc/meminfo fields that can hide memory, the RSS summed per command, the 12 largest processes
# and the 8 largest container cgroups. The whole log is capped at 8 MiB (about 5,000 samples, far
# over the 20 minutes plus setup a run may take); the block at the lowest MemAvailable is kept
# apart. Usage: memsample.sh LOG LOW   (runs until killed)
set -u
log=$1
low=$2
cap=$((8 * 1024 * 1024))
: > "$log"
min=
while :; do
  v=$(awk '/^MemAvailable:/ {print int($2/1024)}' /proc/meminfo)
  blk=$(
    echo "=== $(date -u +%H:%M:%S) MemAvailable ${v} MiB"
    awk '/^(MemTotal|MemFree|MemAvailable|Buffers|Cached|Shmem|AnonPages|Slab|SReclaimable|Mapped|Dirty):/ {printf "%s %d MiB; ", $1, $2/1024} END {print ""}' /proc/meminfo
    echo "-- RSS MiB per command (sum, count)"
    ps -eo rss=,comm= | awk '{s[$2]+=$1; n[$2]++} END {for (c in s) printf "%d %s %d\n", s[c]/1024, c, n[c]}' | sort -rn | head -8
    echo "-- top 12 processes: pid rss-MiB comm args"
    ps -eo pid=,rss=,comm=,args= --sort=-rss | head -12 | awk '{p=$1; r=int($2/1024); c=$3; $1=$2=$3=""; printf "%s %d %s %.110s\n", p, r, c, $0}'
    echo "-- container cgroups MiB"
    for f in /sys/fs/cgroup/system.slice/docker-*.scope/memory.current /sys/fs/cgroup/docker/*/memory.current; do
      [[ -r "$f" ]] && echo "$(($(cat "$f") / 1048576)) $(basename "$(dirname "$f")" | cut -c1-19)"
    done 2>/dev/null | sort -rn | head -8
  )
  if [[ -z "$min" || "$v" -lt "$min" ]]; then
    min=$v
    printf '%s\n' "$blk" > "$low"
  fi
  if [[ $(stat -c %s "$log") -lt $cap ]]; then
    printf '%s\n' "$blk" >> "$log"
  fi
  sleep 5
done
