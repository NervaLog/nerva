---
id: P398
date: 2026-11-13
area: Releases
amends: P376
---

# The site builds without the WKD files until a published tag holds a key file

**Decision.** The Pages build command (`docs/releases/packages.md`, "The site on Cloudflare
Pages") requires `index.html`, `404.html` and `_headers`, each a regular file and not a symlink,
and treats the two WKD files (`.well-known/openpgpkey/policy` and its `hu/` key) as a pair: both
present, as regular files, and both are copied; or both absent, and the build goes on without
them. One without the other, a WKD file that is not a regular file, or a symlink at either file or
at a directory above it in `.well-known/` is NRV-E1152. Whether the WKD files should be there, and
what they hold, stays the site check's job (NRV-E1162). A new slice, 5a, adds `404.html`,
`_headers` and `site_check.mjs`'s check for the three required files to the site repository now,
before setup step 2. No slice adds the WKD files by hand.

**Amendment of P376 point 6.**
- "The build command copies exactly those two files" becomes the pair rule above.
- `release-finish.yml`'s `site` job writes **both** WKD files into the site pull request it opens:
  `policy`, empty, created if absent, and the `hu/` key file, the dearmored key file at the tag it
  publishes. It writes them only when that tag's commit is an ancestor of `main`, so a candidate
  tagged on a branch (the rehearsal's) gets neither and its pull request passes `site-check`
  against the older reference (#400). The first WKD pair on the site comes with v0.7.1's site
  pull request.
- `release_finish.sh site-live`, like `site_check.mjs`, passes with a notice when the reference's
  tag has no key file (v0.7.0), and then requires the WKD path to answer 404.
- WKD's adoption test ("only if the rehearsal shows Pages serves the dot-directory and answers an
  unknown hash with 404") moves from the rehearsal to v0.7.1's release: once `site-verify` is
  green, the supervisor checks `policy` (200), an unknown hash (404), the two headers `_headers`
  sets, and `gpg --locate-external-keys` by WKD. If any fails, point 6 is cut by a decision right
  after v0.7.1, and a site pull request removes both WKD files.

**Reason.** P376 had the build require both WKD files, while its site check forbids any WKD file as
long as the reference tag has no key file (v0.7.0). So Pages could not deploy before v0.7.1, and
v0.7.1 waits for the rehearsal, which needs a deployed site: a loop (#399). Nothing added
`404.html` or `_headers` to the site repository either, so the build could never pass. With the
pair rule, nothing on `nerva.pro` serves a WKD file until v0.7.1's site pull request merges, since
the rehearsal's candidate is tagged on a branch and is never the reference. So the rehearsal has
no WKD file to check, and the adoption test can run only at v0.7.1.

**Cost.** The build no longer insists that the key is served: a site deployed without the WKD files
is green, and only `site_check.mjs` on a pull request and `site-live` at a release notice a WKD file
that should be there. A merge that removes both files deploys a site with no WKD key until the
next site pull request, whose check fails (NRV-E1162). One more slice, in the site repository.
WKD is first tested on the release itself: if Pages does not serve it, v0.7.1 ships with an
INSTALL.md that names a second channel that does not work until the cut lands, and the rehearsal
proves nothing about WKD.
