#!/usr/bin/env bash
# The simulation fleet's loop (ops/sim-fleet/README.md, P147h): follow the tip of main, rebuild
# when it moves, run the VOPR (both state machines) and the fuzzers on fresh random seeds in
# parallel workers for a round, then hand the round to `sim_fleet.py ingest`. Settings come from
# the environment (the unit reads /etc/sim-fleet/fleet.env). The token is a file; this script
# never prints it.
set -euo pipefail

main() {
    # What follow_main re-execs with, and the checksum of the run.sh bash loaded (#424): bash reads
    # this file once, but the checkout it follows rewrites it in place.
    RUN_ARGS=("$@")
    # The SIM_FLEET_* environment as the unit gave it, before the defaults below land in it: the
    # re-exec restores exactly this, so the new run.sh computes its own defaults (#424, review).
    ORIG_ENV=()
    local name
    for name in $(compgen -e SIM_FLEET_); do ORIG_ENV+=("$name=${!name}"); done
    RUN_SH=$(readlink -f "${BASH_SOURCE[0]}")
    RUN_SH_SUM=$(sha256sum "$RUN_SH" | cut -d' ' -f1)
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
    for name in SIM_FLEET_SEED_MEMORY_MB SIM_FLEET_RESERVE_MB; do
        if [[ ! "${!name}" =~ ^[0-9]+$ ]] || (( 10#${!name} == 0 )); then
            log "$name must be a positive whole number of MB, not '${!name}'"
            exit 2
        fi
    done
    local mem_mb mem_source
    read -r mem_mb mem_source < <(memory_mb)
    local computed=""
    if [[ -z "${SIM_FLEET_WORKERS:-}" ]]; then
        SIM_FLEET_WORKERS=$(default_workers "$(nproc)" "$mem_mb" "$mem_source")
        workers_from="computed from $(nproc) cores and $mem_mb MB ($mem_source)"
        computed=1
    else
        workers_from="set"
    fi
    # The split. Set any of the four to override; 0 stops that kind.
    local plan
    plan=$(split_workers "$SIM_FLEET_WORKERS")
    read -r SIM_FLEET_WORKERS_VOPR_NERVA SIM_FLEET_WORKERS_VOPR_TESTING SIM_FLEET_WORKERS_FUZZ \
        SIM_FLEET_WORKERS_MIXED <<<"$plan"
    local planned=$(( SIM_FLEET_WORKERS_VOPR_NERVA + SIM_FLEET_WORKERS_VOPR_TESTING \
        + SIM_FLEET_WORKERS_FUZZ + SIM_FLEET_WORKERS_MIXED ))
    if [[ -n "$computed" ]] && (( planned > SIM_FLEET_WORKERS )); then
        log "warning: the worker settings in fleet.env add up to $planned, above the" \
            "$SIM_FLEET_WORKERS that $mem_mb MB holds; the settings win, and seeds may be OOM-killed"
    fi
    if (( planned == 0 )); then
        log "no workers: SIM_FLEET_WORKERS=$SIM_FLEET_WORKERS ($workers_from) and the" \
            "SIM_FLEET_WORKERS_* settings give a plan of 0 workers in total; set at least one"
        exit 2
    fi
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
    # Consecutive failing rounds (ingest failed or left no record, or a worker died) before the
    # alarm (NRV-E0730, P429).
    : "${SIM_FLEET_ALARM_ROUNDS:=3}"
    if [[ ! "$SIM_FLEET_ALARM_ROUNDS" =~ ^[0-9]{1,6}$ ]] ||
        (( 10#$SIM_FLEET_ALARM_ROUNDS == 0 )); then
        log "SIM_FLEET_ALARM_ROUNDS must be a positive whole number, not '$SIM_FLEET_ALARM_ROUNDS'"
        exit 2
    fi

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
    mkdir -p "$STATE/bin" "$STATE/rotation"
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
    # A round the last run left is settled first, by the reporter already built: not after
    # `follow_main`, which may take an hour to build or die. With none built, `run_round` does it.
    if [[ -n "$built" && -r "$STATE/bin/$built/sim_fleet.py" ]]; then
        bin="$STATE/bin/$built" round="$STATE/round"
        settle_leftover
    fi
    rounds=0
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

# The memory the fleet may use, in MB, and where the figure came from: MemTotal, or the lowest
# memory.max on the cgroup's path up to the root when that is lower than MemTotal (the unit's
# MemoryMax, which setup.sh sets to MemTotal minus the reserve). MemTotal rather than
# MemAvailable: it does not move with the page cache or with the fleet's own restart, so a
# restart picks the same worker count. The three paths can be overridden for the tests.
memory_mb() {
    local meminfo=${SIM_FLEET_MEMINFO:-/proc/meminfo}
    local proc_cgroup=${SIM_FLEET_PROC_CGROUP:-/proc/self/cgroup}
    local root=${SIM_FLEET_CGROUP_ROOT:-/sys/fs/cgroup}
    local total path limit lowest=""
    total=$(awk '/^MemTotal:/ { print int($2 / 1024) }' "$meminfo")
    path=$(sed -n 's/^0:://p' "$proc_cgroup" 2>/dev/null || true)
    path=${path%/}
    while :; do
        if [[ -r "$root$path/memory.max" ]]; then
            limit=$(cat "$root$path/memory.max" 2>/dev/null || true)
            if [[ "$limit" =~ ^[0-9]+$ ]] && { [[ -z "$lowest" ]] || (( limit < lowest )); }; then
                lowest=$limit
            fi
        fi
        if [[ -z "$path" ]]; then break; fi
        path=${path%/*}
    done
    if [[ -n "$lowest" ]] && (( lowest / 1048576 < total )); then
        echo "$(( lowest / 1048576 )) cgroup memory.max"
    else
        echo "$total MemTotal"
    fi
}

# Default worker count for $1 cores and $2 MB: the smaller of cores - 1 and MB per seed, at least
# 1. $3 says where the MB came from (memory_mb's second word): MemTotal leaves the reserve
# SIM_FLEET_RESERVE_MB to the host; a cgroup limit is already MemTotal minus that reserve
# (setup.sh), so the reserve is taken here only once.
default_workers() {
    local cores=$1 mem=$2 source=${3:-MemTotal} by_cpu by_mem
    by_cpu=$(( cores > 1 ? cores - 1 : 1 ))
    if [[ "$source" == MemTotal ]]; then mem=$(( mem - SIM_FLEET_RESERVE_MB )); fi
    by_mem=$(( mem / SIM_FLEET_SEED_MEMORY_MB ))
    echo $(( by_mem < by_cpu ? (by_mem > 1 ? by_mem : 1) : by_cpu ))
}

# The split of $1 workers: `nerva testing fuzz mixed`. A setting in the environment wins. By
# default, 3 workers or more give an eighth each (at least one) to the testing state machine and
# the fuzzers and the rest to Nerva's. Fewer than 3 are all mixed workers, which rotate through
# the kinds seed by seed (MIXED below, so Nerva's get half), as three single-kind workers would
# not fit the memory that made the count small.
split_workers() {
    local total=$1 eighth n t f m left
    eighth=$(( total / 8 > 0 ? total / 8 : 1 ))
    if [[ -n "${SIM_FLEET_WORKERS_VOPR_NERVA:-}${SIM_FLEET_WORKERS_VOPR_TESTING:-}\
${SIM_FLEET_WORKERS_FUZZ:-}" ]]; then
        # Kinds set by hand keep their number. The others share only what is left of the total
        # (Nerva's first, as by default), so one setting never adds workers: a worker is 4 GB.
        m=${SIM_FLEET_WORKERS_MIXED:-0}
        left=$(( total - m - ${SIM_FLEET_WORKERS_VOPR_NERVA:-0} \
            - ${SIM_FLEET_WORKERS_VOPR_TESTING:-0} - ${SIM_FLEET_WORKERS_FUZZ:-0} ))
        if (( left < 0 )); then left=0; fi
        n=${SIM_FLEET_WORKERS_VOPR_NERVA:-}
        if [[ -z "$n" ]]; then
            t=${SIM_FLEET_WORKERS_VOPR_TESTING:-$eighth}
            f=${SIM_FLEET_WORKERS_FUZZ:-$eighth}
            n=$(( total - t - f > 1 ? total - t - f : 1 ))
            n=$(( n < left ? n : left ))
            left=$(( left - n ))
        fi
        t=${SIM_FLEET_WORKERS_VOPR_TESTING:-$(( eighth < left ? eighth : left ))}
        if [[ -z "${SIM_FLEET_WORKERS_VOPR_TESTING:-}" ]]; then left=$(( left - t )); fi
        f=${SIM_FLEET_WORKERS_FUZZ:-$(( eighth < left ? eighth : left ))}
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
        reexec_if_changed "$head"
    else
        rm -rf "$STATE/bin/$head"
        # Recorded first: a crash before the checkout is undone must not rebuild $head.
        echo "$head" >"$STATE/broken.new"
        mv "$STATE/broken.new" "$STATE/broken"
        broken=$head
        log "build of $head FAILED or timed out (see $STATE/build.log); still testing" \
            "${built:-nothing}"
        # The unit starts the checkout's run.sh at a restart: it must be the built commit's, next
        # to that commit's reporter, not the one that failed to build (#432). And the run.sh
        # running now may be the unbuilt head's (a restart during the build): hand over to the
        # built commit's, as after a successful build (#424).
        if [[ -n "$built" ]]; then
            git checkout --quiet --detach "$built"
            reexec_if_changed "$built"
        fi
    fi
}

# After a build of $1: if that commit's run.sh is not the one bash loaded, runs that one instead,
# with the same arguments and the environment it was started with (#424). Without it, a changed
# interface between run.sh and sim_fleet.py (#382's --round-id) failed every ingest. Once per built commit: the marker
# SIM_FLEET_REEXEC names the commit the run.sh just exec'd came from, so it does not exec again.
# The lock (fd 9) is closed first; the new run.sh takes it. Needs RUN_ARGS, RUN_SH_SUM, ORIG_ENV.
reexec_if_changed() {
    local head=$1 new="$SIM_FLEET_REPO_DIR/ops/sim-fleet/run.sh" sum
    if [[ "${SIM_FLEET_REEXEC:-}" == "$head" ]]; then return 0; fi
    [[ -r "$new" ]] || return 0
    sum=$(sha256sum "$new" | cut -d' ' -f1)
    if [[ "$sum" == "$RUN_SH_SUM" ]]; then return 0; fi
    # A run.sh that does not parse would kill the loop and crash-loop the unit: stay on this one.
    if ! bash -n "$new" 2>/dev/null; then
        log "ALARM error[NRV-E0730]: run.sh of $head does not parse (bash -n); staying on the" \
            "run.sh that is running"
        return 0
    fi
    log "run.sh of $head differs from the one running; re-executing it"
    local rounds_left=${SIM_FLEET_ROUNDS:-0} name kv
    # The rounds a dry run or a test asked for are counted from the first run.sh.
    if (( rounds_left != 0 )); then rounds_left=$(( rounds_left - ${rounds:-1} + 1 )); fi
    # The environment this run.sh was started with, not the one it has since filled in.
    for name in $(compgen -e SIM_FLEET_); do unset "$name"; done
    for kv in ${ORIG_ENV[@]+"${ORIG_ENV[@]}"}; do export "${kv%%=*}=${kv#*=}"; done
    export SIM_FLEET_REEXEC=$head
    if (( rounds_left != 0 )); then export SIM_FLEET_ROUNDS=$rounds_left; fi
    exec bash "$new" "${RUN_ARGS[@]}" 9>&-
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

# A round a stop, a reboot or a crash left is settled from the results it holds, as any other
# round: its finished seeds are counted (#370, P382). A round whose `id.refuse` exists had a
# worker die: that verdict was made durable (by a rename, which needs no disk space) before it
# was recorded, so it is refused, never counted. A round with no valid id is not this run.sh's
# (or it was half deleted after its record was saved): deleted, as before. Needs `bin`, `round`.
settle_leftover() {
    [[ -d "$round" ]] || return 0
    local left_id left_commit mode=""
    left_id=$(cat "$round/id" 2>/dev/null || true)
    if [[ -e "$round/id.refuse" ]]; then
        left_id=$(cat "$round/id.refuse" 2>/dev/null || true)
        mode=refuse
    fi
    left_commit=$(cat "$round/commit" 2>/dev/null || true)
    if [[ "$left_id" =~ ^[0-9]{1,20}-[0-9a-f]{16}$ && "$left_commit" =~ ^[0-9a-f]{7,64}$ ]]
    then
        log "settling round $left_id of $left_commit, left by a stop or a crash${mode:+ ($mode)}"
        settle "$left_id" "$left_commit" $mode
    else
        log "deleting a round with no id or commit"
        rm -rf "$round"
    fi
}

# One round: every worker runs seeds of its kind until the round's time is up, then the
# reporter reads what they wrote. A round is made whole under a temporary name, with its id and
# commit, so `round` always has both.
run_round() {
    bin="$STATE/bin/$built"
    round="$STATE/round"
    rm -rf "$round.new"
    settle_leftover
    local id
    id="$(date +%s)-$(od -An -N8 -tx1 /dev/urandom | tr -d ' \n')"
    mkdir "$round.new"
    echo "$id" >"$round.new/id"
    echo "$built" >"$round.new/commit"
    sync "$round.new/id" "$round.new/commit" "$round.new"
    mv "$round.new" "$round"
    # The id must survive a power cut before any worker writes a result under it.
    sync "$round" "$(dirname "$round")"
    local deadline=$(( $(date +%s) + SIM_FLEET_ROUND_SECONDS )) w=0 i pid died=0 pids=()
    for (( i = 0; i < SIM_FLEET_WORKERS_VOPR_NERVA; i++ )); do
        worker "$w" vopr-nerva "$deadline" & pids+=("$!") w=$(( w + 1 ))
    done
    for (( i = 0; i < SIM_FLEET_WORKERS_VOPR_TESTING; i++ )); do
        worker "$w" vopr-testing "$deadline" & pids+=("$!") w=$(( w + 1 ))
    done
    for (( i = 0; i < SIM_FLEET_WORKERS_FUZZ; i++ )); do
        # Each fuzz worker starts at a different fuzzer and moves to the next after every seed.
        worker "$w" fuzz "$deadline" "$i" & pids+=("$!") w=$(( w + 1 ))
    done
    for (( i = 0; i < SIM_FLEET_WORKERS_MIXED; i++ )); do
        # Each mixed worker starts at a different place in the rotation.
        worker "$w" mixed "$deadline" "$i" & pids+=("$!") w=$(( w + 1 ))
    done
    # A worker that exits non-zero died before the round's end (any failed command, under the
    # inherited `set -e`): it may have lost a failing seed, so the round is refused (#370).
    for pid in "${pids[@]}"; do
        wait "$pid" || died=$(( died + 1 ))
    done
    if (( died > 0 )); then
        log "$died of ${#pids[@]} workers of round $id died before its end; refusing it"
        # The verdict first, durably: `refuse` may be unable to write the state (a full disk),
        # and a restart must not count this round.
        mv "$round/id" "$round/id.refuse"
        sync "$round/id.refuse" "$round"
        settle "$id" "$built" refuse
    else
        settle "$id" "$built"
    fi
}

# Worker $1 of kind $2 runs seeds until time $3; a fuzz worker starts its rotation at $4. Each
# seed is one line of `results`: `<target> <seed> <exit code> <seconds>`. A failing seed keeps the
# tail of its output; a VOPR correctness failure (129) is replayed with full logs for its last
# `[err]` lines, since the short log the fleet runs with has none.
worker() {
    local dir="$round/w$1" kind=$2 deadline=$3 next=${4:-0}
    local target exe seed code started out turn=$next cur=$kind
    local rot="$STATE/rotation/$kind-${4:-0}" saved_turn saved_next
    mkdir -p "$dir"
    # The rotation resumes where the last round left it: a round is short, and the last fuzzers
    # of the list would never run if every round began at the first.
    if [[ -r "$rot" ]] && read -r saved_turn saved_next <"$rot" &&
        [[ "$saved_turn" =~ ^[0-9]+$ && "$saved_next" =~ ^[0-9]+$ ]]; then
        turn=$saved_turn next=$saved_next
    fi
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
        # The seed's `results` line is its only record, so it comes first, synced when the seed
        # did not pass; its log and its full-log replay (up to SIM_FLEET_REPLAY_TIMEOUT) come
        # after, and a stop or a full disk there cannot lose it (#370). If anything here fails,
        # this worker dies and run_round refuses the round. A stop kills this bash with its
        # seed: that seed had not finished, so it had not failed, and it is not recorded.
        echo "$target $seed $code $(( $(date +%s) - started ))" >>"$dir/results"
        if (( code != 0 )); then sync "$dir/results" "$dir" "$round"; fi
        if (( code != 0 && code != 124 && code != 137 )); then
            out="$dir/fail-${target/:/-}-$seed"
            mkdir -p "$out"
            tail -c "$SIM_FLEET_TAIL_BYTES" "$dir/seed.log" >"$out/tail.log"
        fi
        if [[ "$cur" == vopr-* && $code -eq 129 ]]; then
            # The last 20: a passing run logs `[err] (client): ... session evicted` too, and
            # the checker's message is the last line before the exit.
            timeout "$SIM_FLEET_REPLAY_TIMEOUT" "$bin/$cur-full" "$seed" 2>&1 </dev/null 9>&- |
                grep -a -E '^\[err\] ' | tail -n 20 >"$out/errors.log" || true
        fi
        if [[ "$kind" == mixed || "$kind" == fuzz ]]; then
            echo "$(( turn % ${#MIXED[@]} )) $(( next % ${#FUZZERS[@]} ))" >"$rot.new" &&
                mv "$rot.new" "$rot"
        fi
    done
    rm -f "$dir/seed.log"
}

# Settles round $1 of commit $2: `ingest` counts it (or refuses it) and saves that with the
# round's id in the state file, in one atomic write; with $3 = `refuse` (a worker died), the
# round is refused without reading it. The decision is that record, never an exit code (P382):
# with no record, `refuse` records the round as refused; with none still (the state cannot be
# written), the round stays where it is and the loop stops, so systemd's restart settles it
# again. A round that is recorded is deleted, or, when it was refused or `ingest` did not exit 0,
# kept in `last-failed-round` for a look.
settle() {
    local id=$1 commit=$2 code=1
    if [[ "${3:-}" == refuse ]]; then
        # code stays 1: a refused round is a failing round.
        :
    else
        code=0
        ingest_round "$id" "$commit" || code=$?
        if ! recorded "$id"; then
            log "sim_fleet.py ingest exited $code and did not record round $id; refusing it"
            if (( code == 0 )); then code=1; fi
        fi
    fi
    if ! recorded "$id"; then
        timeout "$SIM_FLEET_REPORT_TIMEOUT" "$SIM_FLEET_PYTHON" -I "$bin/sim_fleet.py" refuse \
            --round-id "$id" --commit "$commit" --state "$STATE/state.json" || true
    fi
    if ! recorded "$id"; then
        log "round $id of $commit is recorded nowhere (can $STATE/state.json be written?);" \
            "it stays in $round, and the loop stops"
        exit 1
    fi
    note_round "$code" "$id" "$commit"
    if (( code == 0 )); then
        rm -rf "$round"
    else
        rm -rf "$STATE/last-failed-round"
        mv "$round" "$STATE/last-failed-round"
        log "round $id is recorded, refused or with sim_fleet.py exit $code; the round is kept" \
            "in $STATE/last-failed-round for a look"
    fi
}

# Counts consecutive failing rounds ($1 is the round's code: not 0 is failing) in
# $STATE/failing-rounds (`<count> <alarmed 0|1>`, so a restart keeps it). At SIM_FLEET_ALARM_ROUNDS
# in a row: one loud line, and `sim_fleet.py alarm` files or comments on the `sim-fleet` issue,
# once per streak; if that fails, it is tried again at the next failing round. A round that
# counts ends the streak (#424, NRV-E0730, P429).
note_round() {
    local code=$1 id=$2 commit=$3 count=0 alarmed=0 file="$STATE/failing-rounds"
    if (( code == 0 )); then
        rm -f "$file"
        return 0
    fi
    if [[ -r "$file" ]]; then read -r count alarmed <"$file" || true; fi
    [[ "$count" =~ ^[0-9]{1,9}$ ]] || count=0
    [[ "$alarmed" == 1 ]] || alarmed=0
    count=$(( 10#$count + 1 ))
    if (( count >= ${SIM_FLEET_ALARM_ROUNDS:-3} && alarmed == 0 )); then
        log "ALARM error[NRV-E0730]: $count rounds in a row failed (the latest, $id of" \
            "${commit:0:7}); soak reads no hours until one counts. See $STATE/last-failed-round"
        set -- alarm --rounds "$count" --round-id "$id" --commit "$commit"
        if [[ -n "$SIM_FLEET_DRY_RUN" ]]; then
            set -- "$@" --dry-run
        else
            set -- "$@" --repo "$SIM_FLEET_GH_REPO" --token-file "$token_file"
        fi
        if timeout "$SIM_FLEET_REPORT_TIMEOUT" "$SIM_FLEET_PYTHON" -I "$bin/sim_fleet.py" "$@"; then
            alarmed=1
        else
            log "the alarm was not filed; asking again at the next failing round"
        fi
    fi
    echo "$count $alarmed" >"$file.new" && mv "$file.new" "$file" ||
        log "cannot save $file; the count of failing rounds restarts"
}

# `sim_fleet.py ingest` of round $1 of commit $2 (its exit code).
ingest_round() {
    local id=$1 commit=$2
    set -- ingest --round "$round" --round-id "$id" --commit "$commit" \
        --state "$STATE/state.json" --source-root "$SIM_FLEET_REPO_DIR"
    if [[ -n "$SIM_FLEET_DRY_RUN" ]]; then
        set -- "$@" --dry-run
    else
        set -- "$@" --repo "$SIM_FLEET_GH_REPO" --token-file "$token_file"
    fi
    if [[ -n "$SIM_FLEET_TRACKER" ]]; then set -- "$@" --tracker "$SIM_FLEET_TRACKER"; fi
    timeout "$SIM_FLEET_REPORT_TIMEOUT" "$SIM_FLEET_PYTHON" -I "$bin/sim_fleet.py" "$@"
}

# Whether the state file holds the record of round $1: the id is a random token that only
# `last_round` holds, and it is written in the same atomic save as the round's count.
recorded() {
    [[ "$1" =~ ^[0-9]{1,20}-[0-9a-f]{16}$ ]] && grep -qsF -- "\"$1\"" "$STATE/state.json"
}

# Sourced by the tests, which call the functions above.
if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then main "$@"; fi
