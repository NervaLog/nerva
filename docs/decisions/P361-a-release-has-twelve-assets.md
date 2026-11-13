---
id: P361
date: 2026-11-12
area: Releases
amends: P360
---

# A release has twelve assets, and the automation publishes only `X.Y.Z` and `X.Y.Z-rc.N`

**Decision.** P360 point 7 says `publish-ready` accepts "exactly eleven assets". A release has
**twelve**: the ten files in `release.yml`'s `dist/` (four tarballs, four packages,
`nerva-<tag>.cdx.json` and `SHA256SUMS`, which lists nine of them) that `gh release create`
uploads, plus the zip and its `.zip.sha256` that `mac-sign.yml` adds. `publish-ready` refuses
anything else (NRV-E1131). The spec's "nine assets" before `mac`, and its "11 assets", are corrected
in `docs/releases/automation.md`: ten before `mac`, twelve after it.

Two further rules, from the slice A review:

- `publish-ready` also refuses a release whose `prerelease` flag is not "the tag has a `-`"
  (NRV-E1133), because the publish step takes `--latest` from the tag.
- The site's list takes versions `X.Y.Z` and `X.Y.Z-rc.N` only. `release_notes.sh site` (in the
  `version` job, before CI) and `site_release.py` refuse any other, so **only `-rc.N` prereleases
  can be published by the automation**; another suffix is refused before anything is built.
  `site_release.py` also refuses a version not newer than the site's newest (SemVer, `-rc.N`
  numerically, a release newer than its candidates) and a date that is not a calendar day or is
  earlier than the newest entry's, as the site's checker does.

**Reason.** P360's count came from a miscount of `dist/`. Implemented as written, every release
would be refused, or a later fix to "eleven" would refuse every release. The other rules close
cases the review showed passing the publish job and failing 20 minutes later on the site's pull
request, after the release was public.

**Cost.** P360 still reads "eleven"; this decision is the correction (P360 is not edited). A
prerelease with another suffix (`-beta.1`) needs a manual release.
