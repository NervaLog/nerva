#!/usr/bin/env bash
# The simulation fleet's loop (ops/sim-fleet/README.md, P147h): follow the tip of main, rebuild
# when it moves, run the VOPR (both state machines) and the fuzzers on fresh random seeds in
# parallel workers for a round, then hand the round to `sim_fleet.py ingest`. Settings come from
# the environment (the unit reads /etc/sim-fleet/fleet.env). The token is a file; this script
# never prints it.
set -euo pipefail

main() {
    : "${SIM_FLEET_HOME:=/var/lib/sim-fleet}"
    : "${SIM_FLEET_DRY_RUN:=}"
    # A dry run gets a checkout and a state of its own: it must not touch the service's.
    if [[ -n "$SIM_FLEET_DRY_RUN" ]]; then
        : "${SIM_FLEET_REPO_DIR:=$SIM_FLEET_HOME/dry/nerva}"
        : "${SIM_FLEET_STATE_DIR:=$SIM_FLEET_HOME/dry/state}"
    else
        : "${SIM_FLEET_REPO_DIR:=$SIM_FLEET_HOME/nerva}"
        : "${SIM_FLEET_STATE_DIR:=$SIM_FLEET_HOME/state}"
    fi
    : "${SIM_FLEET_REMOTE:=https://github.com/NervaLog/nerva.git}"
    : "${SIM_FLEET_GH_REPO:=NervaLog/nerva}"
    : "${SIM_FLEET_BRANCH:=main}"
    : "${SIM_FLEET_TRACKER:=}"
    # Workers: one core each, and about SIM_FLEET_SEED_MEMORY_MB of RAM each (P179). By default
    # the smaller of every core but one (git, builds and the reporter) and what memory holds.
    : "${SIM_FLEET_SEED_MEMORY_MB:=4096}"
    : "${SIM_FLEET_RESERVE_MB:=1024}"
    local mem_mb mem_source
    read -r mem_mb mem_source < <(memory_mb)
    if [[ -z "${SIM_FLEET_WORKERS:-}" ]]; then
        SIM_FLEET_WORKERS=$(default_workers "$(nproc)" "$mem_mb")
        workers_from="computed from $(nproc) cores and $mem_mb MB ($mem_source)"
    else
        workers_from="set"
    fi
    # The split. Set any of the four to override; 0 stops that kind.
    local plan
    plan=$(split_workers "$SIM_FLEET_WORKERS")
    read -r SIM_FLEET_WORKERS_VOPR_NERVA SIM_FLEET_WORKERS_VOPR_TESTING SIM_FLEET_WORKERS_FUZZ \
        SIM_FLEET_WORKERS_MIXED <<<"$plan"
    # Every fuzzer in src/fuzz_tests.zig but `canary` (fails on purpose) and `smoke`, as fuzz.yml.
    : "${SIM_FLEET_FUZZERS:=ewah lsm_scan lsm_cache_map lsm_manifest_log lsm_manifest_level \
lsm_segmented_array lsm_tree message_bus storage vsr_free_set vsr_superblock \
vsr_superblock_quorums vsr_multi_batch nerva_adds nerva_http_head nerva_documents}"
    # A round: workers start seeds until this many seconds have passed, then the round is
    # reported. A seed already running finishes (or meets its own deadline).
    : "${SIM_FLEET_ROUND_SECONDS:=900}"
    # Deadlines, in seconds: nothing the loop waits on may hang it.
    : "${SIM_FLEET_VOPR_SEED_TIMEOUT:=600}"
    : "${SIM_FLEET_FUZZ_SEED_TIMEOUT:=900}"
    : "${SIM_FLEET_REPLAY_TIMEOUT:=1800}"
    : "${SIM_FLEET_GIT_TIMEOUT:=300}"
    : "${SIM_FLEET_BUILD_TIMEOUT:=3600}"
    : "${SIM_FLEET_REPORT_TIMEOUT:=600}"
    # Bytes of a failing seed's output kept for the reporter (it puts at most 8 KiB in an issue).
    : "${SIM_FLEET_TAIL_BYTES:=65536}"
    : "${SIM_FLEET_CACHE_MB:=16384}"
    # 0: run forever (the service). N: stop after N rounds (a dry run, a test).
    : "${SIM_FLEET_ROUNDS:=0}"
    : "${SIM_FLEET_IDLE_SECONDS:=60}"
    : "${SIM_FLEET_PYTHON:=python3}"

    (( SIM_FLEET_WORKERS_VOPR_NERVA + SIM_FLEET_WORKERS_VOPR_TESTING + SIM_FLEET_WORKERS_FUZZ \
        + SIM_FLEET_WORKERS_MIXED <= 1024 )) || { log "more than 1024 workers"; exit 2; }
    (( SIM_FLEET_TAIL_BYTES > 0 && SIM_FLEET_TAIL_BYTES <= 262144 )) ||
        { log "SIM_FLEET_TAIL_BYTES must be 1..262144"; exit 2; }
    read -r -a FUZZERS <<<"$SIM_FLEET_FUZZERS"
    if (( SIM_FLEET_WORKERS_FUZZ + SIM_FLEET_WORKERS_MIXED > 0 && ${#FUZZERS[@]} == 0 )); then
        log "fuzz workers but no SIM_FLEET_FUZZERS"
        exit 2
    fi

    token_file="${SIM_FLEET_TOKEN_FILE:-${CREDENTIALS_DIRECTORY:+$CREDENTIALS_DIRECTORY/token}}"
    if [[ -z "$SIM_FLEET_DRY_RUN" && -z "$token_file" ]]; then
        log "no token: set SIM_FLEET_TOKEN_FILE, run under the unit, or set SIM_FLEET_DRY_RUN=1"
        exit 2
    fi
    # A read-only deploy key for a private repository, if systemd handed one over.
    if [[ -n "${CREDENTIALS_DIRECTORY:-}" && -s "$CREDENTIALS_DIRECTORY/deploy-key" ]]; then
        export GIT_SSH_COMMAND="ssh -i $CREDENTIALS_DIRECTORY/deploy-key -o IdentitiesOnly=yes \
-o UserKnownHostsFile=$SIM_FLEET_HOME/known_hosts -o StrictHostKeyChecking=yes"
    fi

    STATE=$SIM_FLEET_STATE_DIR
    mkdir -p "$STATE/bin"
    # One loop per state directory: two would race on the state file and the checkout.
    exec 9>"$STATE/lock"
    if ! flock -n 9; then
        log "another run.sh holds $STATE/lock; exiting"
        exit 2
    fi
    if [[ ! -d "$SIM_FLEET_REPO_DIR/.git" ]]; then
        mkdir -p "$(dirname "$SIM_FLEET_REPO_DIR")"
        timeout "$SIM_FLEET_GIT_TIMEOUT" git clone --quiet "$SIM_FLEET_REMOTE" "$SIM_FLEET_REPO_DIR"
    fi
    cd "$SIM_FLEET_REPO_DIR"
    # Remembered across restarts: a restart neither rebuilds a good commit nor retries a bad one.
    built=$(cat "$STATE/built" 2>/dev/null || true)
    broken=$(cat "$STATE/broken" 2>/dev/null || true)
    if [[ -n "$built" && ! -x "$STATE/bin/$built/fuzz" ]]; then built=""; fi
    log "workers: vopr-nerva $SIM_FLEET_WORKERS_VOPR_NERVA, vopr-testing" \
        "$SIM_FLEET_WORKERS_VOPR_TESTING, fuzz $SIM_FLEET_WORKERS_FUZZ, mixed" \
        "$SIM_FLEET_WORKERS_MIXED ($SIM_FLEET_WORKERS $workers_from; $SIM_FLEET_SEED_MEMORY_MB MB" \
        "a seed, $SIM_FLEET_RESERVE_MB MB reserved)"
    local rounds=0
    while (( SIM_FLEET_ROUNDS == 0 || rounds < SIM_FLEET_ROUNDS )); do
        rounds=$(( rounds + 1 ))
        follow_main
        if [[ -z "$built" ]]; then
            log "nothing built yet; waiting"
            sleep "$SIM_FLEET_IDLE_SECONDS"
            continue
        fi
        run_round
    done
}

# The memory the fleet may use, in MB, and where the figure came from: MemTotal, or the cgroup's
# memory.max when that is lower. MemTotal rather than MemAvailable: it does not move with the page
# cache or with the fleet's own restart, so a restart picks the same worker count.
memory_mb() {
    local total cg path limit=""
    total=$(awk '/^MemTotal:/ { print int($2 / 1024) }' /proc/meminfo)
    path=$(sed -n 's/^0:://p' /proc/self/cgroup 2>/dev/null || true)
    for cg in "/sys/fs/cgroup$path/memory.max" /sys/fs/cgroup/memory.max; do
        if [[ -r "$cg" ]]; then limit=$(cat "$cg"); break; fi
    done
    if [[ "$limit" =~ ^[0-9]+$ ]] && (( limit / 1048576 < total )); then
        echo "$(( limit / 1048576 )) cgroup memory.max"
    else
        echo "$total MemTotal"
    fi
}

# Default worker count for $1 cores and $2 MB: the smaller of cores - 1 and (MB - reserve) per
# seed, at least 1.
default_workers() {
    local cores=$1 mem=$2 by_cpu by_mem
    by_cpu=$(( cores > 1 ? cores - 1 : 1 ))
    by_mem=$(( (mem - SIM_FLEET_RESERVE_MB) / SIM_FLEET_SEED_MEMORY_MB ))
    echo $(( by_mem < by_cpu ? (by_mem > 1 ? by_mem : 1) : by_cpu ))
}

# The split of $1 workers: `nerva testing fuzz mixed`. A setting in the environment wins. By
# default, 3 workers or more give an eighth each (at least one) to the testing state machine and
# the fuzzers and the rest to Nerva's. Fewer than 3 are all mixed workers, which rotate through
# the kinds seed by seed (MIXED below, so Nerva's get half), as three single-kind workers would
# not fit the memory that made the count small.
split_workers() {
    local total=$1 eighth n t f m
    eighth=$(( total / 8 > 0 ? total / 8 : 1 ))
    if [[ -n "${SIM_FLEET_WORKERS_VOPR_NERVA:-}${SIM_FLEET_WORKERS_VOPR_TESTING:-}\
${SIM_FLEET_WORKERS_FUZZ:-}" ]]; then
        # Kinds set by hand: the others keep the old defaults, and nothing rotates unless asked.
        t=${SIM_FLEET_WORKERS_VOPR_TESTING:-$eighth}
        f=${SIM_FLEET_WORKERS_FUZZ:-$eighth}
        n=${SIM_FLEET_WORKERS_VOPR_NERVA:-$(( total - t - f > 0 ? total - t - f : 1 ))}
        m=${SIM_FLEET_WORKERS_MIXED:-0}
    elif (( total < 3 )); then
        n=0 t=0 f=0 m=${SIM_FLEET_WORKERS_MIXED:-$total}
    else
        t=$eighth f=$eighth n=$(( total - 2 * eighth ))
        m=${SIM_FLEET_WORKERS_MIXED:-0}
    fi
    echo "$n $t $f $m"
}

# What a mixed worker runs, seed by seed: Nerva's state machine half the time.
MIXED=(vopr-nerva vopr-testing vopr-nerva fuzz)

log() {
    printf '%s sim-fleet: %s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$*"
}

# Fetches the branch; if its tip is a commit not built (and not already known to fail to build),
# builds it into a directory of its own and switches to it only once every build succeeded. A
# build that fails leaves the last good binaries in use and is logged once.
follow_main() {
    if ! timeout "$SIM_FLEET_GIT_TIMEOUT" git fetch --quiet origin "$SIM_FLEET_BRANCH"; then
        log "git fetch failed or timed out; keeping ${built:-nothing}"
        return 0
    fi
    local head
    head=$(git rev-parse FETCH_HEAD)
    if [[ "$head" == "$built" || "$head" == "$broken" ]]; then
        return 0
    fi
    prune_cache
    git checkout --quiet --detach "$head"
    log "building $head"
    rm -rf "$STATE/bin/$head"
    # `9>&-`: a build left behind by a killed loop must not hold the loop's lock.
    if timeout "$SIM_FLEET_BUILD_TIMEOUT" bash -c 'set -euo pipefail; build_into "$1"' _ \
        "$STATE/bin/$head" >"$STATE/build.log" 2>&1 9>&-; then
        echo "$head" >"$STATE/built.new"
        mv "$STATE/built.new" "$STATE/built"
        built=$head
        log "built $head"
        prune_bin
    else
        rm -rf "$STATE/bin/$head"
        echo "$head" >"$STATE/broken.new"
        mv "$STATE/broken.new" "$STATE/broken"
        broken=$head
        log "build of $head FAILED or timed out (see $STATE/build.log); still testing" \
            "${built:-nothing}"
    fi
}

# The five binaries of one commit, built as CI and fuzz_loop.sh build them (ReleaseSafe), and
# the reporter of the same commit. `-Dvopr-log=full` is only for replaying a correctness failure:
# the short log has no `[err]` lines. `timeout` runs it in a new bash, so it is exported.
build_into() {
    local out=$1 sm
    mkdir -p "$out"
    ./zig/download.sh
    for sm in nerva testing; do
        cp "$(./zig/zig build -Drelease -Dvopr-state-machine="$sm" vopr:build -Dprint-exe |
            tail -n1)" "$out/vopr-$sm"
        cp "$(./zig/zig build -Drelease -Dvopr-state-machine="$sm" -Dvopr-log=full vopr:build \
            -Dprint-exe | tail -n1)" "$out/vopr-$sm-full"
    done
    cp "$(./zig/zig build -Drelease fuzz:build -Dprint-exe | tail -n1)" "$out/fuzz"
    cp ops/sim-fleet/sim_fleet.py "$out/sim_fleet.py"
}
export -f build_into

# The binaries of every commit but the one in use.
prune_bin() {
    local dir
    for dir in "$STATE"/bin/*; do
        [[ -d "$dir" ]] || continue
        if [[ "$(basename "$dir")" != "$built" ]]; then rm -rf "$dir"; fi
    done
}

# The build caches grow with every commit; past the limit they are emptied and the next build
# starts cold.
prune_cache() {
    local used
    # du fails on a cache that is not there yet; its total line is still right.
    used=$( (du -smc .zig-cache "$HOME/.cache/zig" 2>/dev/null || true) | tail -n1 | cut -f1)
    if (( ${used:-0} > SIM_FLEET_CACHE_MB )); then
        log "build caches are ${used} MB (limit $SIM_FLEET_CACHE_MB); emptying them"
        rm -rf .zig-cache "$HOME/.cache/zig"
    fi
}

# One round: every worker runs seeds of its kind until the round's time is up, then the
# reporter reads what they wrote.
run_round() {
    bin="$STATE/bin/$built"
    round="$STATE/round"
    rm -rf "$round"
    mkdir -p "$round"
    local deadline=$(( $(date +%s) + SIM_FLEET_ROUND_SECONDS )) w=0 i
    for (( i = 0; i < SIM_FLEET_WORKERS_VOPR_NERVA; i++ )); do
        worker "$w" vopr-nerva "$deadline" & w=$(( w + 1 ))
    done
    for (( i = 0; i < SIM_FLEET_WORKERS_VOPR_TESTING; i++ )); do
        worker "$w" vopr-testing "$deadline" & w=$(( w + 1 ))
    done
    for (( i = 0; i < SIM_FLEET_WORKERS_FUZZ; i++ )); do
        # Each fuzz worker starts at a different fuzzer and moves to the next after every seed.
        worker "$w" fuzz "$deadline" "$i" & w=$(( w + 1 ))
    done
    for (( i = 0; i < SIM_FLEET_WORKERS_MIXED; i++ )); do
        # Each mixed worker starts at a different place in the rotation.
        worker "$w" mixed "$deadline" "$i" & w=$(( w + 1 ))
    done
    wait
    ingest
}

# Worker $1 of kind $2 runs seeds until time $3; a fuzz worker starts its rotation at $4. Each
# seed is one line of `results`: `<target> <seed> <exit code> <seconds>`. A failing seed keeps the
# tail of its output; a VOPR correctness failure (129) is replayed with full logs for its last
# `[err]` lines, since the short log the fleet runs with has none.
worker() {
    local dir="$round/w$1" kind=$2 deadline=$3 next=${4:-0}
    local target exe seed code started out turn=$next cur=$kind
    mkdir -p "$dir"
    while (( $(date +%s) < deadline )); do
        seed=$(od -An -N8 -tu8 /dev/urandom | tr -d ' ')
        if [[ "$kind" == mixed ]]; then
            cur=${MIXED[turn % ${#MIXED[@]}]}
            turn=$(( turn + 1 ))
        fi
        case "$cur" in
        vopr-*)
            target=$cur
            set -- timeout "$SIM_FLEET_VOPR_SEED_TIMEOUT" "$bin/$cur" "$seed"
            ;;
        fuzz)
            target="fuzz:${FUZZERS[next % ${#FUZZERS[@]}]}"
            next=$(( next + 1 ))
            set -- timeout "$SIM_FLEET_FUZZ_SEED_TIMEOUT" "$bin/fuzz" "${target#fuzz:}" "$seed"
            ;;
        esac
        started=$(date +%s)
        code=0
        # The whole output goes to a file of this worker's, overwritten by the next seed (a VOPR
        # seed writes about 100 KB in the short log mode).
        "$@" >"$dir/seed.log" 2>&1 </dev/null 9>&- || code=$?
        if (( code != 0 && code != 124 && code != 137 )); then
            out="$dir/fail-${target/:/-}-$seed"
            mkdir -p "$out"
            tail -c "$SIM_FLEET_TAIL_BYTES" "$dir/seed.log" >"$out/tail.log"
            if [[ "$cur" == vopr-* && $code -eq 129 ]]; then
                # The last 20: a passing run logs `[err] (client): ... session evicted` too, and
                # the checker's message is the last line before the exit.
                timeout "$SIM_FLEET_REPLAY_TIMEOUT" "$bin/$cur-full" "$seed" 2>&1 </dev/null 9>&- |
                    grep -a -E '^\[err\] ' | tail -n 20 >"$out/errors.log" || true
            fi
        fi
        echo "$target $seed $code $(( $(date +%s) - started ))" >>"$dir/results"
    done
    rm -f "$dir/seed.log"
}

# Hands the round to the reporter of the commit the round ran. A round it refused or could not
# report is kept for a look; its failures recur in later rounds if they are real.
ingest() {
    local code=0
    set -- ingest --round "$round" --commit "$built" --state "$STATE/state.json" \
        --source-root "$SIM_FLEET_REPO_DIR"
    if [[ -n "$SIM_FLEET_DRY_RUN" ]]; then
        set -- "$@" --dry-run
    else
        set -- "$@" --repo "$SIM_FLEET_GH_REPO" --token-file "$token_file"
    fi
    if [[ -n "$SIM_FLEET_TRACKER" ]]; then set -- "$@" --tracker "$SIM_FLEET_TRACKER"; fi
    timeout "$SIM_FLEET_REPORT_TIMEOUT" "$SIM_FLEET_PYTHON" -I "$bin/sim_fleet.py" "$@" ||
        code=$?
    if (( code == 0 )); then return 0; fi
    rm -rf "$STATE/last-failed-round"
    mv "$round" "$STATE/last-failed-round"
    log "sim_fleet.py ingest exited $code; the round is in $STATE/last-failed-round"
}

# Sourced by the tests, which call the functions above.
if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then main "$@"; fi
