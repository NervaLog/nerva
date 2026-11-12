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
#   release_check.sh publish-ready <tag>       needs gh, GH_TOKEN and GITHUB_REPOSITORY; prints the commit
#                                              (the publish job: NRV-E1131, and E1120, E1122, E1124 for the target)
#   release_check.sh candidate <tag> <commit>  needs git with the full history (the release commit's
#                                              ancestors); NRV-E1158, P374
#
# `candidate` enforces the code freeze (P147b amended): `release/candidate` at <commit> names the
# full SHA of the candidate that was soaked, Jepsen-tested and reviewed, and <commit> must be that
# candidate's descendant whose `git diff --name-only` lists no pinned path: src/, build.zig,
# build.zig.zon and zig/ (everything that goes into the binary and the toolchain that builds it).
# A prerelease whose commit has no `release/candidate` passes; a release without one is refused.
# `ref` refuses a version without a suffix (a release, not a prerelease) from any ref but
# refs/heads/main (NRV-E1116): a dispatch from a branch would draft a release that targets a commit
# that is not on main. `unreleased` refuses a tag that exists and a release of that tag, published or a draft (a draft
# has no tag until it is published, so the tag check alone would let a second run build another
# draft). `binary` refuses a binary whose `nerva version` `version` line is not <version>, and one
# whose `nerva version --verbose` lacks `commit_keys deduplicate` (#271: the test build
# `-Dtest-commit-keys=off` is never shipped). `assets` refuses a draft whose asset names are not
# exactly the files of <dist-dir>: GitHub renames a file whose name has a character it does not keep.
# `publish-ready` (the publish job of release-finish.yml) refuses a release that is missing or does
# not hold exactly the twelve assets it is published with, the ten of `release` and the Mac zip with
# its checksum (NRV-E1131), and applies mac-draft's checks of the target commit (NRV-E1120, E1122,
# E1124); a release that is already published passes, so a re-run carries on.
set -euo pipefail

where=release.yml

refuse() {
  printf 'error[%s]: %s: %s\n  cause  %s\n  fix    %s\n' "$1" "$where" "$2" "$3" "$4" >&2
  echo "::error::$1 $2" >&2
  exit 1
}

# target_commit <tag> <target>: the commit a draft's target resolves to, printed, after the
# checks that make it one a release may be signed or published from (NRV-E1120, E1122, E1124).
target_commit() {
  local tag=$1 target=$2 commit version compared status
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
  candidate)
    tag=${2:?usage: release_check.sh candidate <tag> <commit>}
    commit=${3:?usage: release_check.sh candidate <tag> <commit>}
    short=${commit:0:7}
    if ! git cat-file -e "$commit^{commit}" 2> /dev/null; then
      refuse NRV-E1158 "cannot read the commit $commit" \
        "the checkout has no such commit (a shallow clone, or a mistyped commit)" \
        "check out the full history (fetch-depth: 0) and run again"
    fi
    if ! file=$(git show "$commit:release/candidate" 2> /dev/null); then
      # A prerelease may be rehearsed on a commit that names no candidate; a release may not.
      if [[ "$tag" == *-* ]]; then
        echo "release_check.sh: $short has no release/candidate; $tag is a prerelease, so nothing is pinned" >&2
        exit 0
      fi
      refuse NRV-E1158 "release/candidate is missing at $short" \
        "a release is cut only from the candidate that was soaked and tested, and the file that names it is not on this commit (P147b)" \
        "write the candidate's full SHA to release/candidate on main (one line), review it, and release from a commit that holds it"
    fi
    if ! [[ "$file" =~ ^[0-9a-f]{40}$ ]]; then
      refuse NRV-E1158 "release/candidate at $short is not one line of 40 lowercase hex characters" \
        "the file must hold the candidate's full SHA and nothing else" \
        "write the candidate's full SHA to release/candidate (git rev-parse <candidate>)"
    fi
    cand=$file
    if ! git cat-file -e "$cand^{commit}" 2> /dev/null ||
      ! git merge-base --is-ancestor "$cand" "$commit" 2> /dev/null; then
      refuse NRV-E1158 "the candidate ${cand:0:7} is not an ancestor of the release commit $short" \
        "release/candidate names a commit that is not in this commit's history (a rewritten or mistyped SHA, or a shallow clone)" \
        "name the candidate that main contains, or fetch the full history and run again"
    fi
    drift=$(git diff --no-renames --name-only "$cand" "$commit" |
      grep -E '^(src/|build\.zig$|build\.zig\.zon$|zig/)' || true)
    if [[ -n "$drift" ]]; then
      printf 'release_check.sh: pinned paths changed since the candidate %s:\n%s\n' "${cand:0:7}" "$drift" >&2
      refuse NRV-E1158 "the release commit $short changes $(wc -l <<< "$drift") pinned path(s) since the candidate ${cand:0:7}: $(head -n3 <<< "$drift" | tr '\n' ' ')" \
        "the soak and Jepsen covered the candidate's code, and src/, build.zig, build.zig.zon and zig/ must be identical to it (P147b amended); only packaging, docs and workflow changes may follow" \
        "release the candidate's code (revert the paths above), or choose a new candidate and restart the soak and Jepsen on it"
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
    commit=$(target_commit "$tag" "${found#*$'\t'}")
    echo "$commit"
    ;;
  publish-ready)
    tag=${2:?usage: release_check.sh publish-ready <tag>}
    if ! [[ "$tag" =~ ^v[0-9]+\.[0-9]+\.[0-9]+(-[0-9A-Za-z.]+)?$ ]]; then
      refuse NRV-E1131 "'$tag' is not a release tag v<VERSION>" \
        "the tag must be v followed by the version (v0.7.1, v0.7.1-rc.1), with no space or other text" \
        "run the workflow for the tag the release job made"
    fi
    if ! found=$(gh api --paginate "repos/$GITHUB_REPOSITORY/releases" \
      --jq ".[] | select(.tag_name == \"$tag\") | [.draft, .target_commitish, .prerelease, (.assets | map(.name) | join(\",\"))] | @tsv" \
      2> /dev/null | head -n1); then
      echo "release_check.sh: cannot list the releases of $GITHUB_REPOSITORY (GitHub did not answer); run again" >&2
      exit 2
    fi
    if [[ -z "$found" ]]; then
      refuse NRV-E1131 "there is no release named $tag to publish" \
        "the draft was deleted, or release.yml did not make it" \
        "run release.yml again on the VERSION commit"
    fi
    # A published release is where an earlier run of the publish job stopped: it carries on.
    IFS=$'\t' read -r _ target prerelease names <<< "$found"
    # The prerelease flag is the tag's suffix: step 4 picks --latest from the tag, so a hand-edited
    # flag would make a candidate Latest or publish a release as a prerelease.
    want=false
    [[ "$tag" == *-* ]] && want=true
    if [[ "$prerelease" != "$want" ]]; then
      refuse NRV-E1133 "the release $tag is marked prerelease=$prerelease, and its tag says $want" \
        "the 'Set as a pre-release' box was changed by hand, or release.yml did not set it from the version" \
        "set it (gh release edit $tag --prerelease=$want) and run the failed job again"
    fi
    # The ten files `release` builds (release.yml's dist/: four tarballs, four packages, the bill
    # of materials and SHA256SUMS, which lists nine of them) and the two of the Mac zip.
    ver=${tag#v}
    filever=${ver//-/.}
    expected=$(printf '%s\n' \
      "nerva-$tag-x86_64-linux.tar.gz" "nerva-$tag-aarch64-linux.tar.gz" \
      "nerva-$tag-x86_64-macos.tar.gz" "nerva-$tag-aarch64-macos.tar.gz" \
      "nerva_$filever-1_amd64.deb" "nerva_$filever-1_arm64.deb" \
      "nerva-$filever-1.x86_64.rpm" "nerva-$filever-1.aarch64.rpm" \
      "nerva-$tag.cdx.json" SHA256SUMS \
      "nerva-$tag-universal-macos.zip" "nerva-$tag-universal-macos.zip.sha256" | LC_ALL=C sort)
    uploaded=$(tr ',' '\n' <<< "$names" | LC_ALL=C sort)
    if [[ "$uploaded" != "$expected" ]]; then
      diff=$(diff <(echo "$expected") <(echo "$uploaded") | tr '\n' ' ' || true)
      refuse NRV-E1131 "the release $tag does not hold exactly the assets it is published with ($diff)" \
        "an upload is missing (the Mac zip comes from mac-sign.yml's job), or a file was added or renamed" \
        "run the failed job again; if the draft is wrong, delete it (gh release delete $tag) and run release.yml again"
    fi
    commit=$(target_commit "$tag" "$target")
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
    echo "usage: release_check.sh ref <tag> <git-ref> | unreleased <tag> | binary <nerva> <version> | assets <tag> <dist-dir> | mac-draft <tag> | mac-same <tag> <signed> <now> | mac-upload <tag> <dir> | publish-ready <tag> | candidate <tag> <commit>" >&2
    exit 2
    ;;
esac
