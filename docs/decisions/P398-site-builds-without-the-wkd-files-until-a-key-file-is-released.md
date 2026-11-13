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
before setup step 2; slice 5 adds the WKD files only once the reference has a key file.

**Reason.** P376 had the build require both WKD files, while its site check forbids any WKD file as
long as the reference tag has no key file (v0.7.0). So Pages could not deploy before v0.7.1, and
v0.7.1 waits for the rehearsal, which needs a deployed site: a loop (#398's review). Nothing added
`404.html` or `_headers` to the site repository either, so the build could never pass.

**Cost.** The build no longer insists that the key is served: a site deployed without the WKD files
is green, and only `site_check.mjs` on a pull request and `site-live` at a release notice a WKD file
that should be there. A merge that removes both files deploys a site with no WKD key until the
next site pull request, whose check fails (NRV-E1162). One more slice, in the site repository.
