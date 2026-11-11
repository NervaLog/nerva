#!/usr/bin/env bash
# Prints the CHANGELOG.md section of release tag $1 (`## v0.2.0 — <date>`), without its heading.
# Fails if the section is missing or empty (every release has notes), or still holds a `TO FILL`
# placeholder (NRV-E1117): the notes are published unchanged as the GitHub release notes.
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
if grep -qF 'TO FILL' <<< "$notes"; then
  printf 'error[NRV-E1117]: release.yml: the CHANGELOG.md notes for %s still hold a TO FILL placeholder\n  cause  the section was not completed before the VERSION commit, and the notes are published unchanged\n  fix    fill every TO FILL in the section (or remove what does not apply), then run again\n' "$tag" >&2
  echo "::error::NRV-E1117 the CHANGELOG.md notes for $tag still hold a TO FILL placeholder" >&2
  exit 1
fi
# Trim leading and trailing blank lines.
printf '%s\n' "$notes" | sed -e '/./,$!d' | tac | sed -e '/./,$!d' | tac
