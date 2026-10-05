#!/usr/bin/env bash
# Runs one fuzzer, or the VOPR, on random seeds until a time budget is spent (N57).
#
#   fuzz_loop.sh fuzz <fuzzer> <minutes>
#   fuzz_loop.sh vopr <nerva|testing> <minutes>
#
# Builds once (ReleaseSafe), then loops: a fresh random seed per run, each run capped at
# `run_minutes_max`. A failing seed replays exactly, so the job prints the seed and the command to
# replay it, writes them to the job summary, and fails. A run that hits the cap is reported as a
# warning, not a failure: some fuzzers' default sizes are long. Writes nothing outside its own
# log directory.
set -euo pipefail

kind="$1"
name="$2"
minutes="$3"
run_minutes_max=30
logs="${RUNNER_TEMP:-/tmp}/fuzz-loop-$kind-$name"
mkdir -p "$logs"
summary="${GITHUB_STEP_SUMMARY:-/dev/null}"

case "$kind" in
  fuzz)
    binary=$(./zig/zig build -Drelease fuzz:build -Dprint-exe | tail -1)
    run_line() { echo "$binary $name $1"; }
    replay() { echo "./zig/zig build -Drelease fuzz -- $name $1"; }
    ;;
  vopr)
    binary=$(./zig/zig build -Drelease -Dvopr-state-machine="$name" vopr:build -Dprint-exe | tail -1)
    run_line() { echo "$binary $1"; }
    replay() { echo "./zig/zig build -Drelease -Dvopr-state-machine=$name vopr -- $1"; }
    ;;
  *)
    echo "usage: fuzz_loop.sh fuzz|vopr <name> <minutes>" >&2
    exit 2
    ;;
esac
[[ -x "$binary" ]] || { echo "::error::build failed for $kind $name" >&2; exit 1; }

deadline=$(( $(date +%s) + minutes * 60 ))
runs=0
failures=0
timeouts=0
while (( $(date +%s) < deadline )); do
  seed=$(od -An -N8 -tu8 /dev/urandom | tr -d ' ')
  log="$logs/$seed.log"
  status=0
  read -r -a argv <<< "$(run_line "$seed")"
  timeout "$(( run_minutes_max * 60 ))" "${argv[@]}" > "$log" 2>&1 || status=$?
  runs=$(( runs + 1 ))
  if (( status == 124 )); then
    timeouts=$(( timeouts + 1 ))
    echo "::warning::$kind $name seed $seed ran past $run_minutes_max min (not a failure)"
  elif (( status != 0 )); then
    failures=$(( failures + 1 ))
    echo "::error::$kind $name failed on seed $seed (exit $status). Replay: $(replay "$seed")"
    tail -n 60 "$log"
    {
      echo "### ❌ $kind \`$name\` failed on seed \`$seed\` (exit $status)"
      echo
      echo "Replay: \`$(replay "$seed")\`"
      echo
      echo '```'
      tail -n 30 "$log"
      echo '```'
    } >> "$summary"
    # One failing seed is the finding: stop, so the job's time goes to other fuzzers.
    break
  fi
done

echo "$kind $name: $runs runs, $failures failed, $timeouts past the per-run cap, in $minutes min budget"
echo "$kind \`$name\`: $runs runs, $failures failed, $timeouts past the per-run cap" >> "$summary"
(( failures == 0 ))
