#!/usr/bin/env bash
# The Jepsen nightly (ops/jepsen/README.md, R1 slice 6): fetch the tip of main, build `nerva`
# in ReleaseSafe, run the retry and bank workloads for an hour each under kill, partition and
# gateway faults (docs/briefs/r1.md, demo steps 1 and 2), archive the store, and hand the night
# to `jepsen_report.py ingest`. Started by jepsen.service as the user `jepsen`; the unit stops
# the simulation fleet before this script and starts it again after, whatever happens here.
#
# This script and jepsen_report.py are installed by setup.sh into /opt/jepsen/bin and the unit
# runs that copy (P240): the night never runs the tip's ops/jepsen/, only the tip's code under
# test (the build and tests/jepsen, in $JEPSEN_REPO_DIR). A change to the runner reaches the
# host when setup.sh runs again.
#
# A failure of the host (a build that failed, Docker down, a run past the deadline, a systemd
# stop or timeout, a `set -e` abort such as a full disk) is written to `host-failure` or the
# `runs` file and reported as the host's, once: a status `error`. A `host-failure` is written only
# when no run had finished (a finished run's finding is reported as it is, P235), and a workload
# that never ran gets a 143 line, so an interrupted night is never `success`. The token is a file
# (the unit's credential); this script never prints it.
set -euo pipefail

: "${JEPSEN_HOME:=/var/lib/jepsen}"
: "${JEPSEN_REPO_DIR:=$JEPSEN_HOME/nerva}"
: "${JEPSEN_REMOTE:=https://github.com/NervaLog/nerva.git}"
: "${JEPSEN_GH_REPO:=NervaLog/nerva}"
: "${JEPSEN_BRANCH:=main}"
: "${JEPSEN_TRACKER:=}"
: "${JEPSEN_TOKEN_FILE:=${CREDENTIALS_DIRECTORY:-/nonexistent}/token}"
: "${JEPSEN_NIGHT_SECONDS:=10800}"  # The whole night, the build included (brief: 3 h).
: "${JEPSEN_TIME_LIMIT:=3600}"      # Jepsen's own limit for one run.
: "${JEPSEN_NEMESIS:=kill,partition,gateway}"
: "${JEPSEN_WORKLOADS:=retry bank}"
: "${JEPSEN_EXPECT_INVALID:=}"      # Set by the canary (slice 8): the run must be invalid.
: "${JEPSEN_KEEP_DAYS:=90}"
: "${JEPSEN_DRY_RUN:=}"             # Report with --dry-run: print, write nothing to GitHub.

log() { echo "jepsen-nightly: $*" >&2; }

# The trap runs inside whatever call was interrupted, redirections included (a run's log, say):
# keep the real stdout and stderr to put back.
exec 7>&1 8>&2

# `--dry-run` is `JEPSEN_DRY_RUN=1` (sudo drops the variable; a flag survives it).
if [[ "${1:-}" == "--dry-run" ]]; then
  JEPSEN_DRY_RUN=1
  shift
fi
export JEPSEN_DRY_RUN

# The night cannot report without a token: say so at once, before anything is stopped or run.
# The unit calls `nightly.sh --check-token` first, ahead of the step that stops the fleet.
check_token() {
  [[ -n "$JEPSEN_DRY_RUN" || -s "$JEPSEN_TOKEN_FILE" ]] && return 0
  log "no token: $JEPSEN_TOKEN_FILE is missing or empty; no night was run (README.md, setup)"
  return 1
}
if [[ "${1:-}" == "--check-token" ]]; then
  check_token
  exit $?
fi
check_token || exit 1

here=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
reporter="$here/jepsen_report.py"
night_start=$SECONDS
mkdir -p "$JEPSEN_HOME"/{archive,state,nights}

# One night at a time. A second start (by hand, say) leaves, and fails, with the holder's pid.
# This process takes the lock once and keeps it to its exit; the long children get fd 9 closed,
# so none can outlive the night holding it.
exec 9>"$JEPSEN_HOME/nightly.lock"
if ! flock -n 9; then
  # Not 0: a real night that finds a dry run's lock (the README suggests one by hand) would end
  # with the fleet stopped, no status and no tracker line, and the unit shown as a success.
  log "another night is running (pid $(cat "$JEPSEN_HOME/nightly.pid" 2> /dev/null || echo unknown)); this start did nothing (exit 75, the unit fails)"
  exit 75
fi
echo "$$" > "$JEPSEN_HOME/nightly.pid"

# A dry run has a night, an archive and a state of its own: it never touches the real ones.
date_utc=$(date -u +%Y-%m-%d)
suffix=""
state_file="$JEPSEN_HOME/state/state.json"
if [[ -n "$JEPSEN_DRY_RUN" ]]; then
  suffix="-dry"
  state_file="$JEPSEN_HOME/state/dry-run.json"
fi
night="$JEPSEN_HOME/nights/$date_utc$suffix"
rm -rf "$night"
[[ -z "$suffix" ]] || rm -f "$state_file"
mkdir -p "$night/store"
: > "$night/store/runs"

# Seconds left in the night, never below 1 (`timeout 0` means no limit).
remaining() {
  local left=$((JEPSEN_NIGHT_SECONDS - (SECONDS - night_start)))
  ((left > 0)) || left=1
  echo "$left"
}

# The first reason stands: a later end (a TERM during the archive, say) must not replace the
# real cause (a build that failed) with a vaguer one.
host_failure() {
  if [[ -s "$night/store/host-failure" ]]; then
    log "the host's: $1 (not recorded; the first reason stands: $(head -n 1 "$night/store/host-failure"))"
    return 0
  fi
  echo "$1" > "$night/store/host-failure"
  log "the host's: $1"
}

# supervise CMD...: runs CMD in the background and waits for it, so a TERM reaches the trap at
# once (bash holds a trap back while a foreground command runs). Redirections on the call apply
# to CMD. Sets $child while it runs.
child=0
supervise() {
  "$@" &
  child=$!
  local rc=0
  wait "$child" || rc=$?
  child=0
  return "$rc"
}

# Fetches the tip of main and checks it out as the code under test; sets $commit and $fetched.
# Returns 1, with host-failure written, if it cannot. Every step is checked by hand: `set -e` is
# off in a function called from a condition.
fetch_tip() {
  if [[ ! -d "$JEPSEN_REPO_DIR/.git" ]]; then
    supervise timeout "$(remaining)" git clone --quiet "$JEPSEN_REMOTE" "$JEPSEN_REPO_DIR" 9>&- \
      || { host_failure "git clone failed"; return 1; }
  fi
  cd "$JEPSEN_REPO_DIR" || { host_failure "cannot enter $JEPSEN_REPO_DIR"; return 1; }
  supervise timeout "$(remaining)" git fetch --quiet origin "$JEPSEN_BRANCH" 9>&- \
    || { host_failure "git fetch failed"; return 1; }
  git checkout --quiet --detach FETCH_HEAD 9>&- \
    || { host_failure "git checkout of the fetched tip failed"; return 1; }
  fetched=1
  commit=$(git rev-parse HEAD) || { host_failure "git rev-parse failed"; return 1; }
  echo "$commit" > "$night/commit" || { host_failure "cannot write $night/commit"; return 1; }
}

# Builds the checked-out tip.
build_tip() {
  cd "$JEPSEN_REPO_DIR" || { host_failure "cannot enter $JEPSEN_REPO_DIR"; return 1; }
  if ! { supervise timeout "$(remaining)" ./zig/download.sh \
         && supervise timeout "$(remaining)" ./zig/zig build -Drelease; } > "$night/build.log" 2>&1 9>&-; then
    host_failure "the build of $commit failed (build.log on the host)"
    return 1
  fi
  # Bounded: a wedged dockerd must not hold the lock and the stopped fleet until the unit's timeout.
  supervise timeout 60 docker info > /dev/null 2>&1 9>&- \
    || { host_failure "Docker is not answering"; return 1; }
}

# The run in flight, for the trap: label, start and arguments; and the code it ended with, once
# `supervise` returned it (empty while it runs).
run_label="" run_began=0 run_args="" run_code=""

# Moves the run's store into the night and writes its line to `runs`.
finish_run() {
  local code=$1
  if [[ -d "$JEPSEN_REPO_DIR/tests/jepsen/store" && ! -e "$night/store/$run_label" ]]; then
    mv "$JEPSEN_REPO_DIR/tests/jepsen/store" "$night/store/$run_label"
  fi
  echo "$run_label $code $((SECONDS - run_began)) $run_args" >> "$night/store/runs"
  log "run $run_label (${run_args%% *}): exit $code in $((SECONDS - run_began)) s"
  run_label=""
}

# run LABEL ARGS...: one Jepsen run; its store goes to $night/store/LABEL and a line to `runs`.
run() {
  local code=0
  run_code=""
  run_label=$1
  shift
  run_began=$SECONDS
  run_args="$*"
  rm -rf "$JEPSEN_REPO_DIR/tests/jepsen/store"
  # --kill-after: run.sh's cleanup (removing the containers) gets a minute after the TERM.
  supervise timeout --kill-after=60 "$(remaining)" \
    "$JEPSEN_REPO_DIR/tests/jepsen/run.sh" "$JEPSEN_REPO_DIR/zig-out/bin/nerva" "$@" \
    > "$night/run-$run_label.log" 2>&1 9>&- || code=$?
  run_code=$code
  finish_run "$code"
}

# Archives the night's store at $archive, so the issues can name it. A failed archive is logged
# and $archive is emptied: the findings are reported without its path. $1 is a time limit in
# seconds, given only on the early-exit path (the stop budget); the normal night's has none.
archived=0     # 1 once the archive is in place
make_archive() {
  [[ -n "$archive" ]] || return 0
  local limit=()
  [[ -z "${1:-}" ]] || limit=(timeout "$1")
  if ! supervise "${limit[@]}" tar --zstd -C "$night" -cf "$archive.new" store 2> /dev/null 9>&-; then
    rm -f "$archive.new"
    archive=""
    log "the archive could not be written"
    return 0
  fi
  mv "$archive.new" "$archive"
  archived=1
  find "$JEPSEN_HOME/archive" -name '*.tar.zst' -mtime +"$JEPSEN_KEEP_DAYS" -delete
}

report_limit=900  # Seconds the reporter may take; the trap shortens it.
report() {
  local args=(ingest --store "$night/store" --commit "$commit" --state "$state_file")
  # A night that did not fetch the tip tested nothing: no status on the commit it knew before.
  ((fetched)) || args+=(--no-status)
  [[ -z "$archive" ]] || args+=(--archive "$archive")
  [[ -z "$JEPSEN_TRACKER" ]] || args+=(--tracker "$JEPSEN_TRACKER")
  [[ -z "$JEPSEN_WORKLOADS" ]] || args+=(--expect-workloads "$JEPSEN_WORKLOADS")
  [[ -z "$JEPSEN_EXPECT_INVALID" ]] || args+=(--expect-invalid)
  if [[ -n "$JEPSEN_DRY_RUN" ]]; then
    args+=(--dry-run)
  else
    args+=(--repo "$JEPSEN_GH_REPO" --token-file "$JEPSEN_TOKEN_FILE")
  fi
  timeout "$report_limit" python3 -I "$reporter" "${args[@]}" 9>&-
}

# The commit to report against: the tip if fetched, else the last the host knows (the tracker's
# line is the alarm, even for a night that could not fetch).
known_commit() {
  [[ -n "$commit" ]] || commit=$(git -C "$JEPSEN_REPO_DIR" rev-parse HEAD 2> /dev/null || true)
}

# Any end of the night that is not the end of the script comes here, from the EXIT trap: a
# systemd stop or timeout or a Ctrl-C (TERM, INT: `exit 143`), a `set -e` abort (a full disk, say)
# or an unset variable. The night is reported once, as the host's `error` with the tracker's line,
# within seconds: the run in flight is recorded (143 only if it was still running), a
# `host-failure` is written, the archive gets 30 s and the reporter 60 s. The unit's TimeoutStopSec
# leaves room (child 20 s + archive 30 s + reporter 60 s = 110 s).
night_over=0   # 1 once the night is reported or nothing more is owed
reporting=0    # 1 from the start of the final report: a second one could file its issues twice
on_exit() {
  local rc=$?
  trap '' TERM INT
  set +e
  exec >&7 2>&8
  ((night_over)) && exit "$rc"
  night_over=1
  if ((reporting)); then
    if ((rc == 2)); then
      log "the reporter exited 2 (a usage error, the state file, token, a rate limit or GitHub unreachable; its lines are above): the report did not finish; it is not run again, as it may have filed issues"
    else
      log "the night's report did not finish (exit $rc); not reporting it twice"
    fi
    exit "$rc"
  fi
  log "the night ended early (exit $rc); reporting it as the host's"
  if ((child != 0)); then
    kill -TERM "$child" 2> /dev/null
    for _ in $(seq 20); do kill -0 "$child" 2> /dev/null || break; sleep 1; done
  fi
  # An archive cut short is of no use, and nothing else would remove it.
  [[ -z "$archive" ]] || rm -f "$archive.new"
  # A run has finished if one is on record, or the one in flight returned its code (its line is
  # written just below, with that code).
  local finished=0
  { [[ -s "$night/store/runs" ]] || [[ -n "$run_code" ]]; } && finished=1
  if [[ -n "$run_label" ]] && ! grep -q "^$run_label " "$night/store/runs" 2> /dev/null; then
    # The run's own code once it ended; 143 only if it was still running.
    finish_run "${run_code:-143}"
  fi
  # A workload with no line never ran: it is the host's 143, so a night cut short between two runs
  # cannot read as `success` (the reporter checks the same list, --expect-workloads).
  if ((finished)); then
    local n=0 workload
    for workload in $JEPSEN_WORKLOADS; do
      n=$((n + 1))
      grep -q "^$n " "$night/store/runs" 2> /dev/null ||
        echo "$n 143 0 test --workload $workload" >> "$night/store/runs"
    done
  fi
  # A host failure makes the night `error` and the reporter skips every finding, so it is
  # written only when no run had finished. With runs on record they are reported as they are, the
  # interrupted one as the host's 143 (or its own code), and the end goes to the journal.
  if ((finished)); then
    log "the night ended early (exit $rc) with its finished runs on record; reporting them"
  elif ((rc == 143)); then
    host_failure "the night was interrupted (a systemd stop or timeout) before it finished"
  else
    host_failure "nightly.sh stopped on an error (exit $rc) before it finished (disk full?)"
  fi
  known_commit
  # A night cut short still archives the runs that finished, so an issue filed for one names an
  # archive that outlives the night's directory (7 days); a night with none has nothing to keep.
  if ((archived)); then
    :
  elif ((finished)); then
    make_archive 30
  else
    archive=""
  fi
  report_limit=60
  if [[ -n "$commit" ]]; then
    report || log "the report of the night failed (exit $?)"
  else
    log "no commit is known (the first fetch failed); nothing can be reported"
  fi
  exit "$rc"
}
# Assigned before the traps: `set -u` is on inside the trap, so a TERM before this would kill it.
commit=""
fetched=0
archive="$JEPSEN_HOME/archive/$date_utc$suffix.tar.zst"
trap 'exit 143' TERM INT
trap on_exit EXIT
if fetch_tip && build_tip; then
  n=0
  for workload in $JEPSEN_WORKLOADS; do
    n=$((n + 1))
    seed=$(od -An -N4 -tu4 /dev/urandom | tr -d ' ')
    run "$n" test --workload "$workload" --nemesis "$JEPSEN_NEMESIS" \
      --time-limit "$JEPSEN_TIME_LIMIT" --seed "$seed"
  done
fi
known_commit

# Archive first, so the issues can name it (a failed archive must not hide them behind a host failure).
make_archive
find "$JEPSEN_HOME/nights" -mindepth 1 -maxdepth 1 -mtime +7 -exec rm -rf {} +

if [[ -z "$commit" ]]; then
  log "no commit is known (the first fetch failed); nothing can be reported"
  night_over=1
  exit 1
fi
reporting=1
report
night_over=1
