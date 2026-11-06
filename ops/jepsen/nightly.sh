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

# `--dry-run` is `JEPSEN_DRY_RUN=1` (sudo drops the variable; a flag survives it).
if [[ "${1:-}" == "--dry-run" ]]; then
  JEPSEN_DRY_RUN=1
  shift
fi
export JEPSEN_DRY_RUN

# This file lives in the checkout the night then moves to the tip of main, and bash reads a
# script as it runs: run a private copy, so the checkout cannot change the script under it.
# Stage 1 fetches the tip; if the tip's nightly.sh differs from this one, stage 2 is a private
# copy of the tip's, so the script and the reporter it calls are always the same commit's.
if [[ -z "${JEPSEN_COPY_OF:-}" ]]; then
  copy=$(mktemp)
  cp "${BASH_SOURCE[0]}" "$copy"
  JEPSEN_STAGE=1 JEPSEN_COPY_OF=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd) \
    JEPSEN_COPY_PATH=$copy exec bash "$copy" "$@"
fi
trap 'rm -f "${JEPSEN_COPY_PATH:-}"' EXIT
here=$JEPSEN_COPY_OF
stage=${JEPSEN_STAGE:-1}
night_start=$((SECONDS - ${JEPSEN_ELAPSED:-0}))
mkdir -p "$JEPSEN_HOME"/{archive,state,nights}

# One night at a time. A second start (the timer while a run is late, or by hand) leaves quietly.
# Stage 2 inherits the held descriptor across the re-exec: opening the file again would close
# fd 9 and release the lock for a moment.
if [[ -z "${JEPSEN_LOCK_HELD:-}" ]]; then
  exec 9>"$JEPSEN_HOME/nightly.lock"
  if ! flock -n 9; then
    log "another night is running; leaving"
    exit 0
  fi
fi

# A dry run has a night, an archive and a state of its own: it never touches the real ones.
date_utc=${JEPSEN_DATE:-$(date -u +%Y-%m-%d)}
suffix=""
state_file="$JEPSEN_HOME/state/state.json"
if [[ -n "$JEPSEN_DRY_RUN" ]]; then
  suffix="-dry"
  state_file="$JEPSEN_HOME/state/dry-run.json"
fi
night="$JEPSEN_HOME/nights/$date_utc$suffix"
if ((stage == 1)); then
  rm -rf "$night"
  [[ -z "$suffix" ]] || rm -f "$state_file"
  mkdir -p "$night/store"
  : > "$night/store/runs"
fi

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

# Fetches the tip of main and checks it out; sets $commit and $fetched. Returns 1, with
# host-failure written, if it cannot. Every step is checked by hand: `set -e` is off in a
# function called from a condition.
fetch_tip() {
  if [[ ! -d "$JEPSEN_REPO_DIR/.git" ]]; then
    timeout "$(remaining)" git clone --quiet "$JEPSEN_REMOTE" "$JEPSEN_REPO_DIR" \
      || { host_failure "git clone failed"; return 1; }
  fi
  cd "$JEPSEN_REPO_DIR" || { host_failure "cannot enter $JEPSEN_REPO_DIR"; return 1; }
  timeout "$(remaining)" git fetch --quiet origin "$JEPSEN_BRANCH" \
    || { host_failure "git fetch failed"; return 1; }
  git checkout --quiet --detach FETCH_HEAD \
    || { host_failure "git checkout of the fetched tip failed"; return 1; }
  fetched=1
  commit=$(git rev-parse HEAD) || { host_failure "git rev-parse failed"; return 1; }
  echo "$commit" > "$night/commit" || { host_failure "cannot write $night/commit"; return 1; }
}

# Builds the checked-out tip.
build_tip() {
  cd "$JEPSEN_REPO_DIR" || { host_failure "cannot enter $JEPSEN_REPO_DIR"; return 1; }
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
  local args=(ingest --store "$night/store" --commit "$commit" --state "$state_file")
  # A night that did not fetch the tip tested nothing: no status on the commit it knew before.
  ((fetched)) || args+=(--no-status)
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
fetched=0
archive="$JEPSEN_HOME/archive/$date_utc$suffix.tar.zst"
ready=0
if ((stage == 2)); then
  commit=$(cat "$night/commit") && fetched=1 && ready=1
  cd "$JEPSEN_REPO_DIR"
elif fetch_tip; then
  tip="$JEPSEN_REPO_DIR/ops/jepsen/nightly.sh"
  if [[ -f "$tip" ]] && ! cmp -s "$tip" "${BASH_SOURCE[0]}"; then
    next=$(mktemp)
    cp "$tip" "$next"
    if ! bash -n "$next" 2> /dev/null; then
      # A tip whose script does not parse would die silently at stage 2: keep this script,
      # which reports the night as the host's (status error) and the tracker line.
      rm -f "$next"
      host_failure "the tip's ops/jepsen/nightly.sh does not parse (bash -n); nothing was run"
      ready=0
    else
      rm -f "$JEPSEN_COPY_PATH"
      log "running the tip's nightly.sh"
      JEPSEN_LOCK_HELD=1 JEPSEN_STAGE=2 JEPSEN_DATE=$date_utc \
        JEPSEN_ELAPSED=$((SECONDS - night_start)) JEPSEN_COPY_PATH=$next \
        JEPSEN_COPY_OF="$JEPSEN_REPO_DIR/ops/jepsen" exec bash "$next" "$@"
    fi
  else
    ready=1
  fi
fi
if ((ready)) && build_tip; then
  n=0
  for workload in $JEPSEN_WORKLOADS; do
    n=$((n + 1))
    seed=$(od -An -N4 -tu4 /dev/urandom | tr -d ' ')
    run "$n" test --workload "$workload" --nemesis "$JEPSEN_NEMESIS" \
      --time-limit "$JEPSEN_TIME_LIMIT" --seed "$seed"
  done
fi
if [[ -z "$commit" ]]; then
  # Even a night that could not fetch is reported (the tracker's line), against the last commit
  # the host knows, and with no status: it tested nothing.
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
