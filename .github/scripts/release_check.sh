#!/usr/bin/env bash
# The release workflow's refusals that have a code (docs/ERRORS.md, NRV-E1112 to NRV-E1116; v0.7.1
# slice 7a). Each prints one coded block, `error[<code>]: release.yml: <what>` with a cause and a
# fix line, and exits 1.
#
#   release_check.sh ref <tag> <git-ref>       <git-ref> is GITHUB_REF
#   release_check.sh unreleased <tag>          needs gh, GH_TOKEN and GITHUB_REPOSITORY
#   release_check.sh binary <nerva> <version>  <version> is VERSION's text, without the v
#   release_check.sh assets <tag> <dist-dir>   needs gh, GH_TOKEN and GITHUB_REPOSITORY
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

refuse() {
  printf 'error[%s]: release.yml: %s\n  cause  %s\n  fix    %s\n' "$1" "$2" "$3" "$4" >&2
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
    if ! "$nerva" version --verbose 2> /dev/null | grep -qx 'commit_keys deduplicate'; then
      refuse NRV-E1113 "the built nerva is not the commit-key deduplication build" \
        "'nerva version --verbose' has no 'commit_keys deduplicate' line: this is the test build -Dtest-commit-keys=off (#271), or an older nerva" \
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
  *)
    echo "usage: release_check.sh ref <tag> <git-ref> | unreleased <tag> | binary <nerva> <version> | assets <tag> <dist-dir>" >&2
    exit 2
    ;;
esac
