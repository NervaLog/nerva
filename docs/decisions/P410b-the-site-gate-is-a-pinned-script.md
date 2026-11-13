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
The script keeps P398's checks and refusals (NRV-E1152), and also refuses `.env*`, `.dev.vars*`,
`.npmrc`, `.yarnrc*`, `.wrangler`, `node_modules`, `.nerva-site` and the remaining manifests and
version files the build image acts on. It copies the allowed files into `.nerva-site/dist/` and
writes `.nerva-site/wrangler.json`, the only Wrangler configuration. The deploy and preview
commands run inside `.nerva-site/`, with `npx --yes wrangler@4.153.0` and `--config wrangler.json`.
`.github/scripts/test_site_build.py` tests the script on fixture trees and checks that the
commands in the spec, filled in, are at most 400 characters.

**Why.** The dashboard limits a build command to 512 characters (owner), and P398's gate is about
2,600. A script in a site repository could be changed by a site merge, so it lives here, under
this repository's guard, and the dashboard pins it by commit and hash, so a later merge here
changes nothing until the owner moves the pin. Wrangler reads `.env` from its working directory
and npm reads `.npmrc`, so Wrangler runs in a directory the gate wrote, and the repository's root
never reaches it. `--config` also stops Workers Builds from generating a configuration. Wrangler
4.153.0 (published 2026-10-26) is pinned because the deploy runs with the build token.

**What it costs.** Every change to `site_build.sh` needs a second step by the owner (move the pin);
until then the old gate runs. The site's build depends on `raw.githubusercontent.com` and on
npm's registry being reachable.
