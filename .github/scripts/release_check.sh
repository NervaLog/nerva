#!/usr/bin/env bash
# The release workflow's refusals that have a code (docs/ERRORS.md, NRV-E1112 to NRV-E1116; v0.7.1
# slice 7a). Each prints one coded block, `error[<code>]: release.yml: <what>` with a cause and a
# fix line, and exits 1.
#
#   release_check.sh ref <tag> <git-ref>       <git-ref> is GITHUB_REF
#   release_check.sh unreleased <tag>          needs gh, GH_TOKEN and GITHUB_REPOSITORY
#   release_check.sh binary <nerva> <version>  <version> is VERSION's text, without the v
#   release_check.sh assets <tag> <dist-dir>   needs gh, GH_TOKEN and GITHUB_REPOSITORY
#   release_check.sh mac-draft <tag>           needs gh, GH_TOKEN and GITHUB_REPOSITORY; prints the commit
#                                              (prints mac-sign.yml: NRV-E1119, E1120, E1122, E1123, E1124)
#   release_check.sh mac-same <tag> <signed-commit> <commit-now>   mac-sign.yml: NRV-E1128
#   release_check.sh mac-upload <tag> <dir>    needs gh, GH_TOKEN; mac-sign.yml: NRV-E1129
#
# `ref` refuses a version without a suffix (a release, not a prerelease) from any ref but
# refs/heads/main (NRV-E1116): a dispatch from a branch would draft a release that targets a commit
# that is not on main. `unreleased` refuses a tag that exists and a release of that tag, published or a draft (a draft
# has no tag until it is published, so the tag check alone would let a second run build another
# draft). `binary` refuses a binary whose `nerva version` `version` line is not <version>, and one
# whose `nerva version --verbose` lacks `commit_keys deduplicate` (#271: the test build
# `-Dtest-commit-keys=off` is never shipped). `assets` refuses a draft whose asset names are not
# exactly the files of <dist-dir>: GitHub renames a file whose name has a character it does not keep.
set -euo pipefail

where=release.yml

refuse() {
  printf 'error[%s]: %s: %s\n  cause  %s\n  fix    %s\n' "$1" "$where" "$2" "$3" "$4" >&2
  echo "::error::$1 $2" >&2
  exit 1
}

case "${1:-}" in
  unreleased)
    tag=${2:?usage: release_check.sh unreleased <tag>}
    # Only a 404 means "no such tag": any other failure (401, 5xx, rate limit) stops the run, exit 2.
    if out=$(gh api "repos/$GITHUB_REPOSITORY/git/ref/tags/$tag" 2>&1); then
      refuse NRV-E1114 "the tag $tag already exists" \
        "a release of this version was cut, or its draft was published" \
        "bump VERSION to release again"
    elif ! grep -q 'HTTP 404' <<< "$out"; then
      echo "release_check.sh: cannot tell whether the tag $tag exists: $out" >&2
      exit 2
    fi
    found=$(gh api --paginate "repos/$GITHUB_REPOSITORY/releases" \
      --jq ".[] | select(.tag_name == \"$tag\") | if .draft then \"draft\" else \"release\" end")
    if [[ -n "$found" ]]; then
      refuse NRV-E1114 "a $(head -n1 <<< "$found") named $tag already exists" \
        "an earlier run of release.yml left it, and a second run would make another" \
        "publish it, or delete it (gh release delete $tag), or bump VERSION"
    fi
    ;;
  ref)
    tag=${2:?usage: release_check.sh ref <tag> <git-ref>}
    ref=${3:?usage: release_check.sh ref <tag> <git-ref>}
    if [[ "$tag" != *-* && "$ref" != refs/heads/main ]]; then
      refuse NRV-E1116 "$tag is a release, and this run is on $ref, not main" \
        "a release is cut only from a main commit (P147b); only a prerelease may be dispatched from a branch" \
        "dispatch the workflow on main, or test the mechanics with a prerelease VERSION (0.7.1-rc.1)"
    fi
    ;;
  binary)
    nerva=${2:?usage: release_check.sh binary <nerva> <version>}
    version=${3:?usage: release_check.sh binary <nerva> <version>}
    shown=$("$nerva" version 2> /dev/null | sed -n 's/^version //p' | head -n1 || true)
    if [[ "$shown" != "$version" ]]; then
      refuse NRV-E1112 "the built nerva reports version '${shown:-none}', and VERSION is $version" \
        "the binary was built from sources whose VERSION differs, or its version line is missing" \
        "build from the commit whose VERSION is $version (build.zig reads VERSION)"
    fi
    # The keys-off build says so on its first line, whatever else it prints (#271).
    if "$nerva" version 2> /dev/null | grep -q '+keys-off' ||
      ! "$nerva" version --verbose 2> /dev/null | grep -qx 'commit_keys deduplicate'; then
      refuse NRV-E1113 "the built nerva is not the commit-key deduplication build" \
        "'nerva version --verbose' has no 'commit_keys deduplicate' line, or 'nerva version' carries '+keys-off': this is the test build -Dtest-commit-keys=off (#271), or an older nerva" \
        "build the release without -Dtest-commit-keys=off"
    fi
    ;;
  assets)
    tag=${2:?usage: release_check.sh assets <tag> <dist-dir>}
    dist=${3:?usage: release_check.sh assets <tag> <dist-dir>}
    expected=$(cd "$dist" && printf '%s\n' * | LC_ALL=C sort)
    uploaded=$(gh api --paginate "repos/$GITHUB_REPOSITORY/releases" \
      --jq ".[] | select(.tag_name == \"$tag\" and .draft) | .assets[].name" | LC_ALL=C sort)
    if [[ "$uploaded" != "$expected" ]]; then
      diff=$(diff <(echo "$expected") <(echo "$uploaded") | tr '\n' ' ' || true)
      refuse NRV-E1115 "the draft $tag does not hold the assets that were built ($diff)" \
        "GitHub renamed or dropped a file on upload, or an upload failed" \
        "delete the draft (gh release delete $tag), fix the file names and run again"
    fi
    ;;
  mac-draft)
    tag=${2:?usage: release_check.sh mac-draft <tag>}
    where=mac-sign.yml
    if ! [[ "$tag" =~ ^v[0-9]+\.[0-9]+\.[0-9]+(-[0-9A-Za-z.]+)?$ ]]; then
      refuse NRV-E1123 "'$tag' is not a release tag v<VERSION>" \
        "the tag input must be v followed by the version (v0.7.1, v0.7.1-rc.1), with no space or other text" \
        "dispatch again with the draft's tag, as the releases page names it"
    fi
    if ! found=$(gh api --paginate "repos/$GITHUB_REPOSITORY/releases" \
      --jq ".[] | select(.tag_name == \"$tag\") | [.draft, .target_commitish] | @tsv" 2> /dev/null | head -n1); then
      echo "release_check.sh: cannot list the releases of $GITHUB_REPOSITORY (GitHub did not answer); run again" >&2
      exit 2
    fi
    if [[ -z "$found" ]]; then
      refuse NRV-E1119 "there is no draft release named $tag to sign into" \
        "release.yml did not make it, or it was deleted" \
        "run release.yml (or fix the tag); mac-sign.yml only adds the macOS zip to an existing draft"
    fi
    if [[ "${found%%$'\t'*}" != true ]]; then
      refuse NRV-E1119 "the release $tag is not a draft" \
        "it was published, and a published release's assets are not replaced" \
        "to correct a published release, cut the next version"
    fi
    target=${found#*$'\t'}
    if ! commit=$(gh api "repos/$GITHUB_REPOSITORY/commits/$target" --jq .sha 2> /dev/null) || [[ -z "$commit" ]]; then
      refuse NRV-E1122 "cannot read the commit $target that the draft $tag targets" \
        "the commit or branch no longer exists (a deleted branch), or GitHub did not answer" \
        "if the target is gone, delete the draft (gh release delete $tag) and run release.yml on the VERSION commit; otherwise run again"
    fi
    if ! version=$(gh api -H "Accept: application/vnd.github.raw" \
      "repos/$GITHUB_REPOSITORY/contents/VERSION?ref=$commit" 2> /dev/null | head -n1 | tr -d '[:space:]'); then
      refuse NRV-E1122 "cannot read VERSION at ${commit:0:7}, the commit the draft $tag targets" \
        "the commit has no VERSION file, or GitHub did not answer" \
        "if the commit has no VERSION, delete the draft (gh release delete $tag) and run release.yml on the VERSION commit; otherwise run again"
    fi
    if [[ "$version" != "${tag#v}" ]]; then
      refuse NRV-E1120 "the draft $tag targets ${commit:0:7}, whose VERSION is '${version:-none}', not ${tag#v}" \
        "the draft was made from another commit than the VERSION commit, or the tag was mistyped" \
        "delete the draft (gh release delete $tag) and run release.yml on the VERSION commit"
    fi
    # Is the commit on main? Compare main with it: `identical` or `behind` means it is on main. The
    # files are relative to the merge base, which is on main (a first page of 30 cannot hide a file
    # beyond VERSION and CHANGELOG.md in a list of at most two).
    if ! compared=$(gh api "repos/$GITHUB_REPOSITORY/compare/main...$commit" \
      --jq '.status, (.files[]? | .filename)' 2> /dev/null) || [[ -z "$compared" ]]; then
      refuse NRV-E1122 "cannot compare the commit ${commit:0:7}, which the draft $tag targets, with main" \
        "GitHub did not answer the compare call, so it is not known whether the commit is on main" \
        "run again"
    fi
    status=$(head -n1 <<< "$compared")
    if [[ "$status" != identical && "$status" != behind ]]; then
      if [[ "$tag" != *-* ]]; then
        refuse NRV-E1124 "$tag is a release, and its draft targets ${commit:0:7}, which is not on main" \
          "a release is cut only from a main commit (P147b)" \
          "delete the draft (gh release delete $tag) and run release.yml on main"
      fi
      # A prerelease may add the version bump to main, and nothing else: its build.zig and
      # zig/download.sh run with the keychain unlocked, so they must be main's (P343).
      if tail -n +2 <<< "$compared" | grep -qvxE 'VERSION|CHANGELOG\.md'; then
        refuse NRV-E1124 "$tag is a prerelease, and its draft targets ${commit:0:7}, which changes more than VERSION and CHANGELOG.md on top of main" \
          "the code that runs with the signing keychain unlocked must be main's; a prerelease may add only the version bump to it (P343)" \
          "delete the draft (gh release delete $tag) and run release.yml on main, or on a commit that changes only VERSION and CHANGELOG.md"
      fi
    fi
    echo "$commit"
    ;;
  mac-same)
    tag=${2:?usage: release_check.sh mac-same <tag> <signed-commit> <commit-now>}
    signed=${3:?usage: release_check.sh mac-same <tag> <signed-commit> <commit-now>}
    now=${4:?usage: release_check.sh mac-same <tag> <signed-commit> <commit-now>}
    where=mac-sign.yml
    if [[ "$now" != "$signed" ]]; then
      refuse NRV-E1128 "the draft $tag now targets ${now:0:7}, not ${signed:0:7}, which was signed" \
        "the draft was deleted and made again, or retargeted, while the zip was built and notarized" \
        "nothing was uploaded; run mac-sign.yml again for the draft as it is now"
    fi
    ;;
  mac-upload)
    tag=${2:?usage: release_check.sh mac-upload <tag> <dir>}
    dir=${3:?usage: release_check.sh mac-upload <tag> <dir>}
    where=mac-sign.yml
    zip="$dir/nerva-$tag-universal-macos.zip"
    # --clobber replaces only an unpublished zip: the draft was checked just before.
    if ! out=$(gh release upload "$tag" "$zip" "$zip.sha256" --clobber 2>&1); then
      printf 'gh: %s\n' "$out" >&2
      refuse NRV-E1129 "the zip and its checksum could not be uploaded to the draft $tag" \
        "GitHub did not answer or refused the upload, the draft was published or deleted meanwhile, or a file is missing" \
        "run mac-sign.yml again (it replaces an unpublished zip); if the draft is gone or published, see NRV-E1119"
    fi
    ;;
  *)
    echo "usage: release_check.sh ref <tag> <git-ref> | unreleased <tag> | binary <nerva> <version> | assets <tag> <dist-dir> | mac-draft <tag> | mac-same <tag> <signed> <now> | mac-upload <tag> <dir>" >&2
    exit 2
    ;;
esac
