---
id: P410b
date: 2026-11-13
area: Releases
amends: P398
---

# The site's gate is a script in this repository, fetched at a pinned commit and hash

**Decision.** The `nerva-site` Worker's build command, set in the dashboard, downloads
`.github/scripts/site_build.sh` from `raw.githubusercontent.com` at a full commit SHA of `main`,
checks its SHA-256 with `sha256sum -c`, and runs it; a failed fetch or a wrong hash is NRV-E1164.
The script keeps P398's checks and refusals (NRV-E1152), and accepts only named files: the root
may hold `index.html`, `404.html`, `_headers`, the WKD pair under `.well-known/openpgpkey/` and
the repository's metadata (`.git`, `.github`, `.nojekyll`, `README.md`, `LICENSE`, `CLAUDE.md`);
any other path, a dotfile or a symlink included, is refused and named. It copies the allowed
files into `.nerva-site/dist/` and writes `.nerva-site/wrangler.json`, the only Wrangler
configuration, and a `package.json` and `package-lock.json` for Wrangler 4.153.0 and its whole
tree, with integrity hashes, embedded in the script so the pinned SHA-256 covers them. The
deploy and preview commands run inside `.nerva-site/`: `npm ci --ignore-scripts`, then
`npx --no-install wrangler deploy|preview --config wrangler.json`, so nothing outside the lock
file is installed and no install script runs while the build token is present.
`.github/scripts/test_site_build.py` tests the script on fixture trees and checks that the
commands in the spec, filled in, are at most 400 characters.

**Why.** The dashboard limits a build command to 512 characters (owner), and P398's gate is about
2,600. A script in a site repository could be changed by a site merge, so it lives here, under
this repository's guard, and the dashboard pins it by commit and hash, so a later merge here
changes nothing until the owner moves the pin. The gate runs after the build image has handled
the checkout, so it only detects and refuses a tree with such files, and nothing is deployed.
`SKIP_DEPENDENCY_INSTALL=1` stops the dependency install, but Cloudflare does not document that it
stops version selection from `.nvmrc`, `.node-version`, `.python-version`, `runtime.txt`,
`.ruby-version` or `packageManager`, so before the gate refuses it a merged site change could make
the image install a toolchain with the build token in its environment. That residual reach is kept
small because site changes go through reviewed pull requests (owner and branch protection); the
rehearsal checks what the image does. A list of
bad names fails open for any name it does not know, so the gate lists the good ones. Wrangler reads `.env` from its working directory
and npm reads `.npmrc`, so Wrangler runs in a directory the gate wrote, and the repository's root
never reaches it. `--config` also stops Workers Builds from generating a configuration. Wrangler
4.153.0 (published 2026-10-26) is pinned, with its dependencies, because the deploy runs with the
build token: `npx wrangler@4.153.0` fixes only the top of the tree. The platform binaries
(`workerd`, `esbuild`) are optional packages of the lock file, and an assets-only deploy runs
neither's install script (`wrangler deploy --dry-run` after `npm ci --ignore-scripts` ran,
2026-11-13).

**What it costs.** Every change to `site_build.sh` needs a second step by the owner (move the pin);
until then the old gate runs. Moving Wrangler means regenerating the embedded lock file. The
site's build depends on `raw.githubusercontent.com` and on npm's registry being reachable, and a
new name in the site repository needs a change here before it can be added.
