#!/usr/bin/env bash
# The alarm of the package repositories (docs/releases/packages.md, "Alarms"). A failed job of the
# workflows that keep the repositories fresh runs this in its own `alarm` job, which holds
# `issues: write` and nothing else.
#
#   repos_alarm.sh <workflow> <job> <code> <run-url>
#
# It opens one issue labelled `package-repos`, assigned to PACKAGE_REPOS_OWNER, or, when one is open,
# adds a comment to it, unless that issue already has a comment for the same (workflow, job, code)
# from the last 24 hours (at most one comment per triple per day). Through REST only. It never
# fails a run: when GitHub refuses, it prints NRV-W1103 and exits 0. Environment: GH_TOKEN,
# GITHUB_REPOSITORY, PACKAGE_REPOS_OWNER. Nothing secret is ever printed.
#
# Only comments by github-actions[bot] count for the deduplication: anyone may comment on a public issue.
#
# Testing override: REPOS_ALARM_NOW (an epoch second, instead of the clock).
set -euo pipefail
{ set +x; } 2>/dev/null

where=repos_alarm.sh
label=package-repos

usage() { echo "usage: repos_alarm.sh <workflow> <job> <code> <run-url>" >&2; exit 64; }

# NRV-W1103: a warning, never the run's verdict.
warn() {
  printf 'warning[NRV-W1103]: %s: the alarm could not be filed: %s\n  cause  %s\n  fix    Check that the label %s exists and GitHub'"'"'s status; the failed job is still red\n' \
    "$where" "$1" "$2" "$label" >&2
  echo "::warning::NRV-W1103 the alarm could not be filed: $1" >&2
  exit 0
}

[ $# = 4 ] || usage
workflow=$1 job=$2 code=$3 url=$4
[[ $workflow =~ ^[A-Za-z0-9._-]{1,80}$ ]] || usage
[[ $job =~ ^[A-Za-z0-9._-]{1,80}$ ]] || usage
# A code is NRV-E1139 and the like, or one of the words the workflows write (`alarm-test`, `missed`,
# `cancelled`, `unknown`). Anything else is not trusted into an issue's text.
[[ $code =~ ^[A-Za-z0-9._-]{1,40}$ ]] || code=unknown
[[ $url =~ ^https?://[^[:space:]\`]{1,300}$ ]] || usage
: "${GITHUB_REPOSITORY:?GITHUB_REPOSITORY is not set}"
[[ $GITHUB_REPOSITORY =~ ^[A-Za-z0-9._-]+/[A-Za-z0-9._-]+$ ]] || usage
owner=${PACKAGE_REPOS_OWNER:-}
[[ -z $owner || $owner =~ ^[A-Za-z0-9-]{1,39}$ ]] || usage

line="\`$workflow\` / \`$job\` failed with \`$code\`: $url"
now=${REPOS_ALARM_NOW:-$(date -u +%s)}
since=$(date -u -d "@$((now - 86400))" +%Y-%m-%dT%H:%M:%SZ)
err=$(mktemp)
trap 'rm -f "$err"' EXIT
fail() { warn "$1" "$(head -c 300 "$err" | tr '\n' ' ')"; }

# The open alarm issue, if any (never a pull request: the issues endpoint lists both).
issue=$(gh api "repos/$GITHUB_REPOSITORY/issues?labels=$label&state=open&sort=created&direction=asc&per_page=100" \
  --jq '[.[] | select(has("pull_request") | not) | .number][0] // empty' 2>"$err") || fail "reading the open issues failed"

if [ -n "$issue" ]; then
  [[ $issue =~ ^[0-9]+$ ]] || fail "the issue number is not a number"
  prefix="\`$workflow\` / \`$job\` failed with \`$code\`:"
  seen=$(gh api "repos/$GITHUB_REPOSITORY/issues/$issue/comments?since=$since&per_page=100" \
    --jq ".[] | select(.created_at >= \"$since\" and .user.login == \"github-actions[bot]\") | .body" 2>"$err") || fail "reading the comments of issue #$issue failed"
  if printf '%s\n' "$seen" | grep -qF -e "$prefix"; then
    echo "::notice::the alarm for $workflow / $job / $code was commented in the last 24 hours; not repeated" >&2
    exit 0
  fi
  gh api -X POST "repos/$GITHUB_REPOSITORY/issues/$issue/comments" -f "body=$line" >/dev/null 2>"$err" ||
    fail "commenting on issue #$issue failed"
  echo "::notice::commented on issue #$issue" >&2
  exit 0
fi

title="Package repositories: \`$workflow\` failed (\`$code\`)"
body="$line

What to do is in docs/releases/packages.md, \"Recovery\". Later failures of any workflow become comments on this issue until it is closed after the fix."
args=(-X POST "repos/$GITHUB_REPOSITORY/issues" -f "title=$title" -f "body=$body" -f "labels[]=$label")
if [ -n "$owner" ]; then
  args+=(-f "assignees[]=$owner")
else
  echo "::notice::PACKAGE_REPOS_OWNER is not set: the issue is opened without an assignee" >&2
fi
gh api "${args[@]}" >/dev/null 2>"$err" || fail "opening the issue failed"
echo "::notice::opened the package-repos alarm issue" >&2
