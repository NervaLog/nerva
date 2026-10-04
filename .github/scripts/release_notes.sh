#!/usr/bin/env bash
# Prints the CHANGELOG.md section of release tag $1 (`## v0.2.0 — <date>`), without its heading.
# Fails if the section is missing or empty: every release has notes.
set -euo pipefail
tag="$1"
notes=$(awk -v heading="## $tag " '
  index($0, heading) == 1 { found = 1; next }
  found && /^## / { exit }
  found { print }
' CHANGELOG.md)
if [[ -z "${notes//[[:space:]]/}" ]]; then
  echo "::error::CHANGELOG.md has no notes for $tag: add a '## $tag — <date>' section" >&2
  exit 1
fi
# Trim leading and trailing blank lines.
printf '%s\n' "$notes" | sed -e '/./,$!d' | tac | sed -e '/./,$!d' | tac
