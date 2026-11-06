#!/usr/bin/env bash
# The Jepsen nightly (ops/jepsen/README.md, R1 slice 6): fetch the tip of main, build `nerva`
# in ReleaseSafe, run the retry and bank workloads for an hour each under kill, partition and
# gateway faults (docs/briefs/r1.md, demo steps 1 and 2), archive the store, and hand the night
# to `jepsen_report.py ingest`. Started by jepsen.service as the user `jepsen`; the unit stops
# the simulation fleet before this script and starts it again after, whatever happens here.
#
# A failure of the host (a build that failed, Docker down, a run past the deadline) is written
# to `host-failure` or the `runs` file and reported as the host's: a status `error`, never an
# issue. The token is a file (the unit's credential); this script never prints it.
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

# This file lives in the checkout the night then moves to the tip of main, and bash reads a
# script as it runs: run a private copy, so the checkout cannot change the script under it.
if [[ -z "${JEPSEN_COPY_OF:-}" ]]; then
  copy=$(mktemp)
  cp "${BASH_SOURCE[0]}" "$copy"
  JEPSEN_COPY_OF=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd) JEPSEN_COPY_PATH=$copy \
    exec bash "$copy" "$@"
fi
trap 'rm -f "${JEPSEN_COPY_PATH:-}"' EXIT
here=$JEPSEN_COPY_OF
night_start=$SECONDS
mkdir -p "$JEPSEN_HOME"/{archive,state,nights}

# One night at a time. A second start (the timer while a run is late, or by hand) leaves quietly.
exec 9>"$JEPSEN_HOME/nightly.lock"
if ! flock -n 9; then
  log "another night is running; leaving"
  exit 0
fi

date_utc=$(date -u +%Y-%m-%d)
night="$JEPSEN_HOME/nights/$date_utc"
rm -rf "$night"
mkdir -p "$night/store"
: > "$night/store/runs"

# Seconds left in the night, never below 1 (`timeout 0` means no limit).
remaining() {
  local left=$((JEPSEN_NIGHT_SECONDS - (SECONDS - night_start)))
  ((left > 0)) || left=1
  echo "$left"
}

host_failure() {
  echo "$1" > "$night/store/host-failure"
  log "the host's: $1"
}

# Fetches and builds the tip of main; sets $commit. Returns 1, with host-failure written, if it
# cannot.
prepare() {
  if [[ ! -d "$JEPSEN_REPO_DIR/.git" ]]; then
    timeout "$(remaining)" git clone --quiet "$JEPSEN_REMOTE" "$JEPSEN_REPO_DIR" \
      || { host_failure "git clone failed"; return 1; }
  fi
  cd "$JEPSEN_REPO_DIR"
  timeout "$(remaining)" git fetch --quiet origin "$JEPSEN_BRANCH" \
    || { host_failure "git fetch failed"; return 1; }
  git checkout --quiet --detach FETCH_HEAD
  commit=$(git rev-parse HEAD)
  echo "$commit" > "$night/commit"
  if ! { timeout "$(remaining)" ./zig/download.sh \
         && timeout "$(remaining)" ./zig/zig build -Drelease; } > "$night/build.log" 2>&1; then
    host_failure "the build of $commit failed (build.log on the host)"
    return 1
  fi
  docker info > /dev/null 2>&1 || { host_failure "Docker is not answering"; return 1; }
}

# run LABEL ARGS...: one Jepsen run; its store goes to $night/store/LABEL and a line to `runs`.
run() {
  local label=$1
  shift
  local began=$SECONDS code=0
  rm -rf "$JEPSEN_REPO_DIR/tests/jepsen/store"
  # --kill-after: run.sh's cleanup (removing the containers) gets a minute after the TERM.
  timeout --kill-after=60 "$(remaining)" \
    "$JEPSEN_REPO_DIR/tests/jepsen/run.sh" "$JEPSEN_REPO_DIR/zig-out/bin/nerva" "$@" \
    > "$night/run-$label.log" 2>&1 || code=$?
  if [[ -d "$JEPSEN_REPO_DIR/tests/jepsen/store" ]]; then
    mv "$JEPSEN_REPO_DIR/tests/jepsen/store" "$night/store/$label"
  fi
  echo "$label $code $((SECONDS - began)) $*" >> "$night/store/runs"
  log "run $label ($1): exit $code in $((SECONDS - began)) s"
}

report() {
  local args=(ingest --store "$night/store" --commit "$commit" --state "$JEPSEN_HOME/state/state.json")
  [[ -z "$archive" ]] || args+=(--archive "$archive")
  [[ -z "$JEPSEN_TRACKER" ]] || args+=(--tracker "$JEPSEN_TRACKER")
  [[ -z "$JEPSEN_EXPECT_INVALID" ]] || args+=(--expect-invalid)
  if [[ -n "$JEPSEN_DRY_RUN" ]]; then
    args+=(--dry-run)
  else
    args+=(--repo "$JEPSEN_GH_REPO" --token-file "$JEPSEN_TOKEN_FILE")
  fi
  python3 -I "$here/jepsen_report.py" "${args[@]}"
}

commit=""
archive="$JEPSEN_HOME/archive/$date_utc.tar.zst"
if prepare; then
  n=0
  for workload in $JEPSEN_WORKLOADS; do
    n=$((n + 1))
    seed=$(od -An -N4 -tu4 /dev/urandom | tr -d ' ')
    run "$n" test --workload "$workload" --nemesis "$JEPSEN_NEMESIS" \
      --time-limit "$JEPSEN_TIME_LIMIT" --seed "$seed"
  done
fi
if [[ -z "$commit" ]]; then
  # Even a night that could not fetch is reported, against the last commit the host knows.
  commit=$(git -C "$JEPSEN_REPO_DIR" rev-parse HEAD 2> /dev/null || true)
fi

# Archive first, so the issues can name it. A failed archive is logged, and the findings are
# reported without its path (it must not hide them behind a host failure).
if ! tar --zstd -C "$night" -cf "$archive.new" store 2> /dev/null; then
  rm -f "$archive.new"
  archive=""
  log "the archive could not be written"
else
  mv "$archive.new" "$archive"
  find "$JEPSEN_HOME/archive" -name '*.tar.zst' -mtime +"$JEPSEN_KEEP_DAYS" -delete
fi
find "$JEPSEN_HOME/nights" -mindepth 1 -maxdepth 1 -mtime +7 -exec rm -rf {} +

if [[ -z "$commit" ]]; then
  log "no commit is known (the first fetch failed); nothing can be reported"
  exit 1
fi
report
