#!/usr/bin/env bash
# Files a failure of a scheduled or dispatched suite (fuzz.yml, jepsen.yml) as one GitHub issue.
#
#   file_issue.sh <label> <title> <body file>
#
# One open issue per label and title: if one is open, the body is added to it as a comment (a
# re-run, or the next night's failure, while the first is not fixed); otherwise a new issue is
# filed with the label. Needs `gh` and GH_TOKEN with `issues: write`.
set -euo pipefail

label="$1"
title="$2"
body="$3"
[[ -s "$body" ]] || { echo "empty issue body: $body" >&2; exit 2; }

# An issue or comment holds at most 65536 characters.
body_bytes_max=60000
if (( $(wc -c < "$body") > body_bytes_max )); then
  cut="$body.cut"
  head -c "$body_bytes_max" "$body" > "$cut"
  printf '\n\n(Cut at %d bytes: the run summary and artifacts have the rest.)\n' "$body_bytes_max" >> "$cut"
  body="$cut"
fi

gh label create "$label" --color B60205 --description "Found by the nightly $label run" --force

# Listing by label (not searching) sees an issue filed a moment ago: the search index lags.
# shellcheck disable=SC2016 # $ENV is jq's
number=$(TITLE="$title" gh issue list --label "$label" --state open --limit 100 \
  --json number,title --jq '[.[] | select(.title == $ENV.TITLE)][0].number // empty')

if [[ -n "$number" ]]; then
  gh issue comment "$number" --body-file "$body"
  echo "Updated #$number: $title"
else
  gh issue create --title "$title" --label "$label" --body-file "$body"
fi
