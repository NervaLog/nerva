#!/usr/bin/env bash
# Prints the CHANGELOG.md section of release tag $1 (`## v0.2.0 — <date>`), without its heading
# and without its site line (`<!-- site: <one sentence> -->`, see below).
# Fails if the section is missing or empty (every release has notes), or still holds a `TO FILL`
# placeholder (NRV-E1117): the notes are published unchanged as the GitHub release notes.
#
#   release_notes.sh <tag>        the notes
#   release_notes.sh site <tag>   the text of the site line, for the site's RELEASES entry
#                                 (docs/releases/automation.md); refused with NRV-E1130 when the
#                                 section has none, an empty one, one of more than 300 characters,
#                                 one holding a non-printable or non-ASCII character or one of
#                                 < > & \ ` " or a `TO FILL`; a prerelease (a tag
#                                 with a `-`) with no site line gets `Release candidate <tag>.`
set -euo pipefail

# The lines of the section of tag $1, without its heading.
section() {
  awk -v heading="## $1 " '
    index($0, heading) == 1 { found = 1; next }
    found && /^## / { exit }
    found { print }
  ' CHANGELOG.md
}

site_refuse() {
  printf 'error[NRV-E1130]: release.yml: %s\n  cause  %s\n  fix    %s\n' "$1" "$2" \
    'write the line as the first line of the section, <!-- site: <one sentence, at most 300 characters, printable ASCII without < > & \ ` "> -->, then run again' >&2
  echo "::error::NRV-E1130 $1" >&2
  exit 1
}

if [[ "${1:-}" == site ]]; then
  tag=${2:?usage: release_notes.sh site <tag>}
  line=$(section "$tag" | grep -m1 -E '^<!-- site:.*-->[[:space:]]*$' || true)
  if [[ -z "$line" ]]; then
    # A prerelease is never merged into the site: its line is a default.
    if [[ "$tag" == *-* ]]; then
      printf 'Release candidate %s.\n' "$tag"
      exit 0
    fi
    site_refuse "the CHANGELOG.md section of $tag has no site line" \
      "the site's release list takes one sentence from the section, and this release has none"
  fi
  text=${line#'<!-- site:'}
  text=${text%%-->*}
  text=$(sed -e 's/^[[:space:]]*//' -e 's/[[:space:]]*$//' <<< "$text")
  if [[ -z "$text" ]]; then
    site_refuse "the site line of $tag is empty" "the comment holds no text"
  fi
  if ((${#text} > 300)); then
    site_refuse "the site line of $tag is ${#text} characters, over the limit of 300" \
      "the site's release list shows one sentence"
  fi
  # Printable ASCII, and none of < > & \ ` ": the site writes the sentence into a string in its script
  # and into HTML (NervaLog/nervalog.github.io's site check holds the same rule).
  if LC_ALL=C grep -q '[^ -~]' <<< "$text" || [[ "$text" == *['<>&\`"']* ]]; then
    site_refuse "the site line of $tag holds a character the site does not take" \
      'the sentence must be printable ASCII without < > & \ ` or ", because the site writes it into its script and its HTML'
  fi
  if [[ "$text" == *'TO FILL'* ]]; then
    site_refuse "the site line of $tag still holds a TO FILL placeholder" \
      "the line was not completed before the VERSION commit, and it is published on the site"
  fi
  printf '%s\n' "$text"
  exit 0
fi

tag="$1"
notes=$(section "$tag" | grep -v -E '^<!-- site:.*-->[[:space:]]*$' || true)
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
