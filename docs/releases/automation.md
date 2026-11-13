# Release automation: spec, bill of materials, setup

Status: spec, 2026-11-12 ([P360](../decisions/P360-release-automation.md), amending P343). Nothing
here is built yet. Until it lands, a release runs as `release.yml`, `mac-sign.yml` and
`mac-verify.yml` do today, and the owner publishes the draft and commits the formula by hand
(P311, P343).

**Timing.** It is used for v0.7.1 only if the `v0.7.1-rc.2` rehearsal below passes before the
v0.7.1 soak ends (about 27 hours after it starts, on 2026-11-12). Otherwise v0.7.1 ships the way it
does today, and this lands first thing after the `v0.7.1` tag. The change touches `.github/`, a
script and documents, never `src/` or `build.zig`, so the release freeze does not cover it. It
changes how v0.7.1 ships, though, so the rehearsal is the gate.

## Goal

A release needs one human act: the owner approves the `mac` job in the `apple-signing`
environment. Everything before that approval runs without anyone: CI, the build, the draft.
Everything after it does too: signing, notarization, the checks on both Mac architectures,
publishing the draft (which creates the tag), the Homebrew tap, the site's pull request and a
`brew install` from the tap. Nothing needs a second click.

The release gates (P147b) do not change. The fleet soak, Jepsen and the two adversarial reviews
still come before the `VERSION` commit, and the release PR still quotes them. What changes is what
the approval means. Today it means "sign this draft", and the owner publishes later. From now on
it means **"ship this release"**: once the Mac jobs are green, the draft is published without
another look. The draft, with its notes and its ten assets (the zip and its checksum join them in `mac`), already exists when the approval
prompt appears, so the owner can read it before they click.

Today the owner does four things after the draft exists: approve `mac`, read the green
`mac-verify` run, publish the draft, and commit `Formula/nerva.rb` to the tap (a status PR on the
site follows, made by a session). After this change, only the first is left.

## The flow

```
VERSION commit merged to main (CHANGELOG section with its site line, P360)
  └─ release.yml  (push to main touching VERSION, or a dispatch)
       version ── refuses: bad VERSION, no notes or no site line, no SBOM, wrong ref, a tag or draft exists
         └─ ci  (ci.yml, workflow_call)
              └─ release  ── builds 4 targets + 4 packages + SBOM + SHA256SUMS ── DRAFT v<V>, --target <sha>
                   └─ finish  (release-finish.yml, workflow_call; main only)
                        mac        env apple-signing ── WAITS FOR THE OWNER'S ONE APPROVAL ──
                        │          (mac-sign.yml: keychain, mac-release -Dnotarize=true,
                        │           mac_zip_check.sh, upload zip + .zip.sha256, artifact homebrew-formula)
                        └─ mac-verify  (mac-verify.yml on the draft: arm64 + x86_64; brew skipped)
                             └─ publish  env release-publish (main only, no reviewers)
                                  ├─ release_check.sh publish-ready: draft, same commit, 12 assets, prerelease flag = tag (P361)
                                  ├─ publish the draft  → GitHub creates tag v<V> at the target
                                  ├─ tap:  Formula/nerva.rb → NervaLog/homebrew-tap main   (App token)
                                  │        (a prerelease: branch rc/v<V>, never main)
                                  └─ site: PR to NervaLog/nervalog.github.io, merged after site-check  (App token)
                                           (a prerelease: PR opened, no auto-merge)
                                  └─ verify  (mac-verify.yml on the published release:
                                              arm64 + x86_64, brew install from the tap, nerva version, brew test)

release-finish.yml  dispatched from main with a draft's tag: the same four jobs.
                    It is the rehearsal path (a prerelease drafted from a branch) and the
                    recovery path (a release run that stopped after its draft).
```

One approval covers signing and publishing because `apple-signing` is the only environment in
the graph with a required reviewer. `release-publish` has none, so `publish` starts as soon as
`mac-verify` is green. If any Mac check fails, nothing is published, and the draft stays as it
was.

A release published by hand (the fallback when `release-finish.yml` is not used) has no such gate:
`mac-verify.yml` then runs only on `release: published`, after the zip is public. Before publishing a
draft by hand, dispatch `mac-verify.yml` with the draft's tag and publish only when it is green.

## Workflows and jobs

Existing files keep their names. `mac_keychain.sh`, `mac_zip_check.sh`, `release_check.sh` and
`release_notes.sh` are reused as they are, with the additions below. Every action is pinned by
full commit SHA, as today.

### `release.yml` (changed)

- **Triggers:** unchanged (push to `main` touching `VERSION`; `workflow_dispatch`).
  `concurrency: release`, `cancel-in-progress: false`, unchanged.
- **`version`:** unchanged, plus one refusal. `release_notes.sh site <tag>` prints the section's
  site line (see "The site line"), and a version without a suffix that has none is refused before
  CI runs (new code, registered by the implementing PR in `docs/ERRORS.md`; the next free numbers
  are from NRV-E1130). A prerelease without one gets `Release candidate <tag>.` (it is never
  merged into the site).
- **`ci`, `release`:** unchanged. `release_notes.sh <tag>` drops the site line from the notes it
  prints, so the GitHub release notes stay as they are.
- **`mac` and `mac-verify` are replaced by one job, `finish`:**
  ```yaml
  finish:
    needs: [version, release]
    if: github.ref == 'refs/heads/main'
    uses: ./.github/workflows/release-finish.yml
    permissions:
      contents: write
    with:
      tag: ${{ needs.version.outputs.tag }}
  ```
  The `if` stays, so a prerelease dispatched from a branch makes its draft and stops there, as it
  does today. Each environment's main-only deployment rule is the second guard.
- The header comment changes: the owner approves `mac` once, and the run publishes.

### `release-finish.yml` (new)

- **Triggers:** `workflow_call` (input `tag`) from `release.yml`. `workflow_dispatch` (input
  `tag`) for the rehearsal and for recovery. A dispatch from any ref but `main` cannot deploy to
  either environment, and the first job also refuses it outright (`release_check.sh ref`, NRV-E1116,
  is for the version, so the check is a plain `github.ref` test with its own code).
- **Top-level `permissions: contents: read`.** `concurrency: release-finish-<tag>`,
  `cancel-in-progress: false`.
- **`mac`:** `uses: ./.github/workflows/mac-sign.yml` with `tag`, `permissions: contents: write`.
  This is the existing job as it is, with environment `apple-signing`, `mac-draft` before any
  secret, the keychain from `mac_keychain.sh create`, `mac-release -Dnotarize=true`,
  `mac_zip_check.sh`, `mac-same`, `mac-upload`, the `homebrew-formula` artifact and
  `mac_keychain.sh destroy` under `always()`. Because the reusable workflow runs inside the caller's
  run, its artifact belongs to this run, and `publish` can download it.
- **`mac-verify`:** `needs: mac`, `uses: ./.github/workflows/mac-verify.yml` with `tag`,
  `permissions: contents: write` (listing a draft). This is the existing check of the draft on
  `macos-15` and `macos-15-intel`, where `brew` is skipped.
- **`publish`** (new): `needs: [mac, mac-verify]`, `runs-on: ubuntu-24.04`, `timeout-minutes: 45`,
  `environment: release-publish`, `permissions: contents: write` (the draft in `NervaLog/nerva`
  only). `env: TAG`. The steps, each idempotent, so "Re-run failed jobs" finishes a half-done
  publish:
  1. Check out the workflow's own ref (`persist-credentials: false`). The scripts come from it,
     never from the draft's target.
  2. `release_check.sh publish-ready "$TAG"` (new subcommand, new code), using `GH_TOKEN` from
     `github.token`. It refuses unless all of these hold: the release is a draft (or already
     published, which a re-run continues past), its target resolves to the commit `mac-draft`
     accepts (main for a release; main plus `VERSION` and `CHANGELOG.md` for a prerelease), and
     its `prerelease` flag is true exactly when the tag has a `-` (NRV-E1133), its assets are exactly the ten `release` built (P361; `SHA256SUMS` lists nine of them) plus `nerva-<tag>-universal-macos.zip` and
     its `.zip.sha256`. It prints the commit.
  3. Download the `homebrew-formula` artifact (`actions/download-artifact`, pinned). Refuse,
     with a new code, unless its `url` is
     `https://github.com/NervaLog/nerva/releases/download/<tag>/nerva-<tag>-universal-macos.zip`,
     its `version` is `<tag>` without the `v`, and its `sha256` equals the first field of the
     draft's `.zip.sha256`, downloaded with the token.
  4. **Publish:** `gh release edit "$TAG" --draft=false`, with `--latest` for a release and
     without it for a prerelease, which keeps its prerelease flag. GitHub creates tag `v<V>` at the
     draft's target. The token is `GITHUB_TOKEN`, so the `release: published` event starts no
     workflow (`mac-verify.yml`'s own trigger stays for a publish by hand). The tap and the site
     come after this step, because a formula must never name a URL that is not public yet.
     Then check that `git/ref/tags/<tag>` resolves to the commit from step 2.
  5. **App token:** `actions/create-github-app-token` (pinned), `app-id: ${{ vars.RELEASE_APP_ID }}`,
     `private-key: ${{ secrets.RELEASE_APP_PRIVATE_KEY }}`, `owner: NervaLog`,
     `repositories: homebrew-tap,nervalog.github.io`, `permission-contents: write`,
     `permission-pull-requests: write`. The token is given only to steps 6 and 7, as `GH_TOKEN`
     in `env:`, and it expires within the hour.
  6. **Tap:** clone `NervaLog/homebrew-tap` over HTTPS using a credential helper that reads
     `GH_TOKEN` from the environment, never a URL holding the token. Write the artifact to
     `Formula/nerva.rb`. If a file was there before, refuse (new code) when `git diff` changes any
     line but `url`, `version` and `sha256`. If nothing differs, skip the commit (a re-run).
     Otherwise commit `nerva <V>` as the App's bot identity and push: **to `main` for a release,
     and to branch `rc/v<V>` for a prerelease**. A prerelease never reaches the tap's `main`, so
     `brew install nervalog/tap/nerva` never installs a candidate.
  7. **Site:** `python3 .github/scripts/site_release.py index.html <version> <date> <site line>`
     (new script, unit-tested in `ci.yml`'s scripts step) edits a checkout of
     `NervaLog/nervalog.github.io`. It prepends `{v:"<V>", date:"<date>", d:"<site line>"}` to
     `RELEASES` and sets `SITE.version`, `SITE.released` and `SITE.updated`. It refuses (new code)
     unless `const SITE = {`, `const RELEASES = [` and each of those three keys occur exactly once,
     and it does nothing if `RELEASES` already holds `<V>`. The step pushes branch
     `release/v<V>` and opens a pull request, `Release v<V>`, whose body links the release.
     - For a release, wait for the site's `site-check` on the PR's head commit to succeed (failure or
       no result in time: NRV-E1136, PR left open), then `gh pr merge --squash --match-head-commit
       <sha>`, with `--auto` only as the fallback if that is refused (P364), then wait up to
       the merge. Both waits share one 20-minute deadline (`SITE_DEADLINE`), inside the job's 45
       minutes. Fail if it does not merge, and say so in one coded line. The release itself is out by
       then, and the site PR can be merged by hand. Only `check.yml`'s `site-check` from GitHub Actions
       counts. The `--auto` fallback pins the head commit only when auto-merge is turned on; what stops a
       later push from merging unchecked is the site's ruleset (required `site-check`, no bypass), and
       `site-wait` refuses a merge whose head has no passing check.
     - For a prerelease, the PR is opened without auto-merge, and the step waits for its check to
       pass. The supervisor closes it after the rehearsal.
     - An open PR for the same branch is reused.
     - `SITE.stage`, `NEXT` and `PRODUCTION` are prose and stay with the supervisor's status PR,
       as today (CLAUDE.md, "README and site status").
- **`verify`** (new): `needs: publish`, `uses: ./.github/workflows/mac-verify.yml` with `tag` and
  `tap-ref` (`main`, or `rc/v<V>` for a prerelease), `permissions: contents: write`. The release is
  now published, so the brew step runs on both architectures: it taps `nervalog/tap`, checks out
  `tap-ref`, then `brew install nervalog/tap/nerva`, `nerva version` (ending `version <V>`) and
  `brew test nerva`. No environment and no secret.

### `mac-sign.yml` (comments only)

The jobs do not change. The header and the upload step's comment say a publish is now a later job
in the same run (`publish` needs `mac`), not the owner's act, so the race the comment describes
cannot happen in that path.

### `mac-verify.yml` (changed)

- A new optional input, `tap-ref` (default `main`), for both `workflow_call` and
  `workflow_dispatch`. After `brew tap nervalog/tap`, the brew step checks out that ref in the tap's
  repository. The `release: published` trigger stays, for a draft published by hand.
- With `workflow_call` on a published release, the step makes one attempt (`EVENT` is not
  `release`), which is right: the tap is committed before `verify` starts.
- The header no longer says the owner commits the formula.

### `release_notes.sh` and the site line (changed)

The site's `RELEASES` entry has a one-sentence `d` that nothing in this repository holds today.
The CHANGELOG section gains it as an HTML comment, which GitHub does not render, as its first
line:

```
## v0.7.1 — 2026-11-13
<!-- site: The first release for outside users: a signed and notarized Mac binary with a Homebrew tap, Linux packages and an installer. -->
```

`release_notes.sh <tag>` drops that line, and only that one. `release_notes.sh site <tag>` prints
its text and fails (NRV-E1130) when it is missing, there are two (only a line outside a fenced
code block counts, so a section may show the convention in one), it is empty, longer than 300
characters, or holds a `"`, a `\`, or a `--` (a `-->` inside the sentence would end the comment
early). It also refuses a tag that is not `v<X.Y.Z>` or `v<X.Y.Z>-rc.<N>`: only `-rc.N`
prereleases are published by the automation (P361). The check runs in `version`, before CI. The supervisor writes the line in the `VERSION` PR, as it
writes the rest of the section.

### `NervaLog/nervalog.github.io` (new file there)

`.github/workflows/check.yml` runs on every pull request to `main`. It extracts the page's
`<script>`, runs `node --check` on it, and evaluates the data block to assert that `RELEASES` is
newest first and `SITE.version` equals `RELEASES[0].v`. Its job name, `site-check`, is the
required status check of the ruleset in the setup guide. Without a required check, auto-merge has
nothing to wait for, and today the repository allows no auto-merge at all.

### `apt` and `dnf` repositories (v0.7.2): the hook

The repositories come in v0.7.2, through a Cloudflare Worker (NEXT on the site). They join this
graph as one more job of `release-finish.yml`, `repos`. It runs after `publish`, `needs: publish`,
in its own environment that holds the signing key and the Worker's token. It must be idempotent
for a re-run, and `verify` then also waits for it. Its design is v0.7.2's. This spec only keeps
`publish` free of anything that job will need.

## Conflicts with the current workflows and documents

1. **P343:** "no secret is added to `apple-signing` until sessions run as that account". P360
   amends it on that point (owner, 2026-11-12). The machine account and "Prevent self-review"
   remain the later fix.
2. **`mac-verify.yml`'s `release: published` trigger does not fire** when a workflow publishes with
   `GITHUB_TOKEN`. That is deliberate, and `verify` is the explicit replacement. A publish by
   hand still triggers it.
3. **The headers of `release.yml` and `mac-verify.yml`, and `mac-sign.yml`'s upload comment,** say
   the owner publishes and commits the formula. They change with the workflows.
4. **`release.yml`'s `if: github.ref == 'refs/heads/main'`** means a prerelease drafted from a
   branch cannot reach `publish` in the same run. `release-finish.yml`'s dispatch from `main`
   covers it, as `mac-sign.yml`'s dispatch does today.
5. **`docs/INSTALL.md`** says the tap is "not published yet". The implementing PR words it for a
   tap that exists once the first release is out.
6. **The site repository** has no workflow, no ruleset, and `allow_auto_merge` off (checked
   2026-11-12). Auto-merge cannot work until the setup below is done.
7. **The site's `d` text** has no source in this repository. The site line fills that gap and
   adds a refusal to the `version` job.
8. **`concurrency: release`:** a run waiting for approval holds the group, for up to 30 days.
   A second `VERSION` push waits behind it, and a third replaces the second while it is pending.
   That is acceptable for one release at a time, and it is how things work today.
9. **The site's own rule** ("changes go by PR") is kept. The tap has no such rule; see P360 for why
   its formula goes straight to `main`.

## Security notes

- **No secret on argv, none echoed.** Secrets enter steps only through `env:`, and only the steps
  that use them. The App's key goes only to `create-github-app-token`, and its token only to the
  tap and site steps. Git authenticates through a credential helper that reads the environment,
  never a token in a URL or a `-c` argument. **The `.p12` is re-wrapped first** (owner,
  2026-11-12; slice A): `mac_keychain.sh` runs `openssl pkcs12 -passin env:<real> -passout
  env:<throwaway>` with a random throwaway password made in the step, and `security import -P`
  sees only that throwaway. The real export password then reaches only `openssl`, through `env:`,
  and never argv (P343 had accepted it on argv for a moment).
- **Actions pinned to a full SHA:** `actions/create-github-app-token` and
  `actions/download-artifact` are added, each pinned, with the tag in a comment.
- **The App's reach.** "Nerva Release" has these repository permissions: Contents read and write,
  Pull requests read and write, Metadata read. It has nothing else. It is installed only on
  `NervaLog/homebrew-tap` and `NervaLog/nervalog.github.io`, **not on `NervaLog/nerva`**: writes to
  Nerva itself use the run's `GITHUB_TOKEN`. Its key and id live only in the environment
  `release-publish`, which accepts deployments from `main` only, so only a workflow merged to
  `main` can read them. Each run mints a token for those two repositories, narrowed to the two
  permissions, and the token lasts an hour.
- **The Apple secrets** stay as P343 set them. They are in `apple-signing` only, which needs the
  owner's approval, accepts deployments from `main` only and does not let administrators bypass
  it. They reach only the keychain step, and `mac-draft` runs before any of them. The target's code
  that runs with the keychain unlocked is `main`'s, or `main` plus `VERSION` and `CHANGELOG.md`.
- **Accepted risk: sessions act as `topwombat`.** Sessions in this repository authenticate to
  GitHub as the owner's account `topwombat`, which is also the only required reviewer of
  `apple-signing`. A session could therefore, in principle, approve a waiting `mac` deployment
  through `POST /repos/NervaLog/nerva/actions/runs/{id}/pending_deployments`. From this change on,
  that approval would also publish the release. The owner accepts this risk until the machine
  account exists. What keeps it in check today:
  - Sessions have no tool that approves a deployment. The GitHub tools they are given have no such
    call, and the session proxy refused this session's read of `repos/NervaLog/nerva/environments`
    (2026-11-12). Whether the approval endpoint is refused too was not tried, and must not be
    tried.
  - The rule "a session never approves a deployment" is written into CLAUDE.md by the implementing
    PR.
  - Every workflow change that could widen the reach of either environment is reviewed before it
    merges.
  - The later fix is the machine account (P343's gate), after which "Prevent self-review" is turned
    on for `apple-signing` and the owner's own account is its only reviewer.
  The same applies to `release-publish`: any workflow merged to `main` can name it. Merging is the
  guard, and CODEOWNERS for `.github/workflows/` (P343 7d, pending) will make it a real review.
- **Prereleases cannot reach users.** A prerelease's formula goes to a tap branch and its site
  change stays an unmerged PR. Its tag and release are deleted after the rehearsal.

## Bill of materials

Checked against the repositories on 2026-11-12. "Unknown" means the session's proxy refused the
read (environment settings and secrets). The owner checks those with the commands in step 7.

| # | Item | Kind | Where | Owner of it | Exists? |
|---|---|---|---|---|---|
| 1 | GitHub App "Nerva Release": Contents RW, Pull requests RW, Metadata R | GitHub App | NervaLog org, installed on `homebrew-tap`, `nervalog.github.io` | owner | new |
| 2 | `RELEASE_APP_ID` | variable | env `release-publish` | owner | new |
| 3 | `RELEASE_APP_PRIVATE_KEY` (the App's `.pem`) | secret | env `release-publish` | owner | new |
| 4 | Environment `release-publish`: deployments from `main` only, no reviewers | environment | NervaLog/nerva | owner | new |
| 5 | Environment `apple-signing`: owner as required reviewer, `main` only, no admin bypass | environment | NervaLog/nerva | owner | unknown (P343 says the owner creates it; `mac-sign.yml` names it) |
| 6 | `APPLE_DEVELOPER_ID_P12` (base64 of the CI Developer ID `.p12`, P343 7c), `APPLE_DEVELOPER_ID_P12_PASSWORD` | secrets | env `apple-signing` | owner | unknown; P343: none added yet |
| 7 | `APPLE_NOTARY_KEY_P8` (base64 of `AuthKey_<id>.p8`), `APPLE_NOTARY_KEY_ID`, `APPLE_NOTARY_ISSUER_ID` | secrets | env `apple-signing` | owner | unknown; P343: none added yet |
| 8 | `NERVA_SIGN_IDENTITY` (optional; unset means `build.zig`'s default) | variable | env `apple-signing` | owner | unknown |
| 9 | `NervaLog/homebrew-tap`, public, `main` with a README | repository | NervaLog | owner | new (owner creates it) |
| 10 | Ruleset on the tap's `main`: no force push, no deletion | ruleset | NervaLog/homebrew-tap | owner | new |
| 11 | `allow_auto_merge` on | setting | NervaLog/nervalog.github.io | owner | no (off) |
| 12 | Ruleset on the site's `main`: required check `site-check`, owner (admin) may bypass | ruleset | NervaLog/nervalog.github.io | owner | no (no rulesets) |
| 13 | `.github/workflows/check.yml` (job `site-check`) | workflow | NervaLog/nervalog.github.io | implementer | no (no workflows) |
| 14 | `.github/workflows/release-finish.yml` | workflow | NervaLog/nerva | implementer | new |
| 15 | `release.yml`: `version` site-line check; `mac` and `mac-verify` replaced by `finish` | workflow | NervaLog/nerva | implementer | changed |
| 16 | `mac-verify.yml`: `tap-ref` input, header | workflow | NervaLog/nerva | implementer | changed |
| 17 | `mac-sign.yml`: comments only | workflow | NervaLog/nerva | implementer | exists |
| 18 | `release_check.sh publish-ready`, `release_notes.sh site`, with tests in `test_release_check.py` | script | NervaLog/nerva | implementer | changed |
| 19 | `.github/scripts/site_release.py` and its test | script | NervaLog/nerva | implementer | new |
| 20 | `mac_keychain.sh`, `mac_zip_check.sh` | scripts | NervaLog/nerva | — | exist, unchanged |
| 21 | New codes from NRV-E1130 in `docs/ERRORS.md` (site line, publish-ready, formula, tap diff, site edit, site merge, finish ref) | docs | NervaLog/nerva | implementer | new |
| 22 | `actions/create-github-app-token`, `actions/download-artifact`, each pinned to a full SHA | actions | `release-finish.yml` | implementer | new |
| 23 | CHANGELOG site line in each release section | docs | NervaLog/nerva | supervisor | new |
| 24 | CLAUDE.md: "release.yml publishes after the owner's one approval; a session never approves a deployment"; `docs/INSTALL.md` tap wording | docs | NervaLog/nerva | implementer | changed |
| 25 | Tag rulesets: none on NervaLog/nerva today (the one ruleset, "To Auto-merge", targets branches). If one is added for `v*`, GitHub Actions needs to be on its bypass list, because publishing creates the tag. | ruleset | NervaLog/nerva | owner | none, nothing to do |

## Setup guide (owner, once)

Every secret goes in through standard input or a prompt, never on the command line. Run these on
your Mac (`base64 -i` and `rm -P` are macOS forms), signed in to `gh` as `topwombat`. The session proxy cannot reach these settings.

**1. The tap repository.**

```bash
gh repo create NervaLog/homebrew-tap --public --add-readme --description "Homebrew tap for Nerva: brew install nervalog/tap/nerva"
```

```bash
printf '%s' '{"name":"main","target":"branch","enforcement":"active","conditions":{"ref_name":{"include":["~DEFAULT_BRANCH"],"exclude":[]}},"rules":[{"type":"non_fast_forward"},{"type":"deletion"}]}' | gh api -X POST repos/NervaLog/homebrew-tap/rulesets --input -
```

**2. The GitHub App.** This part is in the browser. Go to the NervaLog organisation, then
Settings, Developer settings, GitHub Apps, New GitHub App.
- Name: `Nerva Release`. Homepage: `https://github.com/NervaLog/nerva`.
- Webhook: untick Active.
- Repository permissions: **Contents: Read and write**, **Pull requests: Read and write**,
  Metadata: Read. Nothing else.
- Where it can be installed: "Only on this account".
- Create it, and note the App ID. Then **Generate a private key**, and a `.pem` downloads.
- Then **Install App**, choose NervaLog, then **Only select repositories**: `homebrew-tap` and
  `nervalog.github.io`. Do not select `nerva`.

**3. The environment `release-publish`.**

```bash
printf '%s' '{"deployment_branch_policy":{"protected_branches":false,"custom_branch_policies":true}}' | gh api -X PUT repos/NervaLog/nerva/environments/release-publish --input -
```

```bash
gh api -X POST repos/NervaLog/nerva/environments/release-publish/deployment-branch-policies -f name=main -f type=branch
```

**4. The App's id and key in it.** The first command prompts for the App ID. The second reads the
`.pem` from standard input. Give the path when asked.

```bash
read -rp 'Nerva Release App ID: ' app_id && printf '%s' "$app_id" | gh variable set RELEASE_APP_ID --env release-publish --repo NervaLog/nerva
```

```bash
read -rp 'Path to the App private key (.pem): ' pem && gh secret set RELEASE_APP_PRIVATE_KEY --env release-publish --repo NervaLog/nerva < "$pem" && rm -P "$pem"
```

(The App can issue a new key at any time, so the `.pem` is deleted.)

**5. `apple-signing`: its settings, then the Apple secrets (amends P343).** The first command sets
you as the only required reviewer, `main` only, with no administrator bypass. It changes nothing if
those are already the settings.

```bash
id=$(gh api users/topwombat --jq .id) && printf '{"reviewers":[{"type":"User","id":%s}],"can_admins_bypass":false,"deployment_branch_policy":{"protected_branches":false,"custom_branch_policies":true}}' "$id" | gh api -X PUT repos/NervaLog/nerva/environments/apple-signing --input -
```

```bash
gh api repos/NervaLog/nerva/environments/apple-signing/deployment-branch-policies --jq '.branch_policies[].name' | grep -qx main || gh api -X POST repos/NervaLog/nerva/environments/apple-signing/deployment-branch-policies -f name=main -f type=branch
```

Export the **CI** Developer ID Application certificate (P343 7c: not the laptop's) with its key
as a `.p12`, with an export password. Use Keychain Access, under My Certificates, then Export.

```bash
read -rp 'Path to the CI Developer ID .p12: ' p12 && base64 -i "$p12" | gh secret set APPLE_DEVELOPER_ID_P12 --env apple-signing --repo NervaLog/nerva && rm -P "$p12"
```

```bash
gh secret set APPLE_DEVELOPER_ID_P12_PASSWORD --env apple-signing --repo NervaLog/nerva
```

(`gh` prompts for the value.) Next, the notary key. In App Store Connect, go to Users and Access,
Integrations, App Store Connect API, Team Keys. Generate a key with the role **Developer**, note
its Key ID and the Issuer ID, and download `AuthKey_<id>.p8` (it can be downloaded once).

```bash
read -rp 'Path to AuthKey_<id>.p8: ' p8 && base64 -i "$p8" | gh secret set APPLE_NOTARY_KEY_P8 --env apple-signing --repo NervaLog/nerva && rm -P "$p8"
```

```bash
gh secret set APPLE_NOTARY_KEY_ID --env apple-signing --repo NervaLog/nerva
```

```bash
gh secret set APPLE_NOTARY_ISSUER_ID --env apple-signing --repo NervaLog/nerva
```

**6. The site repository: auto-merge and its required check.** Do this after `check.yml` has
merged there (slice D), so the check has run once and can be required.

```bash
gh api -X PATCH repos/NervaLog/nervalog.github.io -F allow_auto_merge=true -F delete_branch_on_merge=true --silent
```

```bash
printf '%s' '{"name":"main","target":"branch","enforcement":"active","bypass_actors":[{"actor_id":5,"actor_type":"RepositoryRole","bypass_mode":"always"}],"conditions":{"ref_name":{"include":["~DEFAULT_BRANCH"],"exclude":[]}},"rules":[{"type":"deletion"},{"type":"non_fast_forward"},{"type":"required_status_checks","parameters":{"strict_required_status_checks_policy":false,"required_status_checks":[{"context":"site-check"}]}}]}' | gh api -X POST repos/NervaLog/nervalog.github.io/rulesets --input -
```

(`actor_id` 5 is the repository admin role, so your own direct pushes still go through. The
App's pull requests wait for `site-check`.)

The site's `check.yml` accepts a release pull request only from the App, and reads the App's login
from the site repository's variable `RELEASE_APP_LOGIN`: `<app-slug>[bot]`, which is
`nerva-release[bot]` for the App named `Nerva Release`. Without it that author rule does not hold.

```bash
printf '%s' 'nerva-release[bot]' | gh variable set RELEASE_APP_LOGIN --repo NervaLog/nervalog.github.io
```

(Check the slug on the App's settings page; it is the name in lower case with dashes.)

**7. Check.**

```bash
gh secret list --env apple-signing --repo NervaLog/nerva
```

```bash
gh secret list --env release-publish --repo NervaLog/nerva && gh variable list --env release-publish --repo NervaLog/nerva
```

```bash
gh variable list --repo NervaLog/nervalog.github.io
```

```bash
gh api repos/NervaLog/nerva/environments --jq '.environments[] | [.name, (.protection_rules | map(.type) | join(","))] | @tsv'
```

Expect five Apple secrets in `apple-signing`, `RELEASE_APP_PRIVATE_KEY` and `RELEASE_APP_ID` in
`release-publish`, `RELEASE_APP_LOGIN` on the site, `apple-signing` with `required_reviewers,branch_policy`, and `release-publish`
with `branch_policy` only. Then tell the supervisor, and the rehearsal follows.

## A release afterwards

0. **Choosing a candidate writes `release/candidate`** (P374, "code pinned"): the full SHA, one
   line, merged to `main` before the soak starts. The soak, Jepsen and the reviews run on that SHA.
   A later change to `src/`, `build.zig`, `build.zig.zon`, `zig/`, `.gitmodules` or a
   `.gitattributes` means a new candidate and a new soak; packaging, docs and workflow changes need
   none. The `VERSION` commit may not change `release/candidate`: the check reads it at that
   commit's first parent, so the file is on `main` before the bump.
1. The gates pass (P147b): the soak, Jepsen and both review verdicts. The supervisor merges the
   `VERSION` PR, whose CHANGELOG section has its site line. **The freeze is enforced:**
   `release.yml`'s `version` job runs `release_check.sh candidate <tag> $GITHUB_SHA <before>` (full
   history; `before` is the push's `github.event.before`) before CI and any build, and `release-finish.yml`'s `publish` job runs it on the
   draft's target before the draft is published, so a hand-dispatched finish cannot publish an
   unpinned commit. It refuses (NRV-E1158) a missing or malformed file, a candidate that is not an
   ancestor of the release commit, a release commit that changes `release/candidate`, or a push that changed it together with the bump (a rebase merge; a release dispatched with no push is refused), and any
   pinned path that differs from the candidate (it prints the paths). A prerelease with no
   `release/candidate` passes; with one it is checked, so a rehearsal exercises the check.
2. `release.yml` runs `version`, `ci` and `release`. The draft appears with ten assets, and
   `mac` waits.
3. **The owner reads the draft and approves `mac` once.** That approval ships the release.
4. `mac`, `mac-verify`, `publish` and `verify` run. The tag, the tap's `main` and the site's
   merged PR follow without anyone.
5. The supervisor quotes the run link in the release's worklog note. It writes the retro within a
   day and updates the README and the site's prose (`SITE.stage`, `NEXT`) in its status PR.

If a job fails, "Re-run failed jobs" resumes it. If the run itself is gone, dispatch
`release-finish.yml` from `main` with the tag. Each job is idempotent. For a release that is
already published the dispatch skips `mac` (nothing is signed twice), still runs `mac-verify`
on the published zip (steps 1 to 4, `brew: 'no'`, since the tap has no formula yet) and carries
on with `publish`, which publishes nothing again but checks the tag, then the tap, the site and
`verify`; the formula is then made from the template and the zip's published checksum. Everything
that can refuse without writing (the App's token, the site's sentence, the tap's diff, the site's
edit, a release older than the latest one, and a tag that already exists at another commit) runs before the draft is published, so a setup
mistake leaves a draft and not a half-finished release. A draft that cannot be
signed in CI falls back to the owner's Mac, as P311 and P343 describe. After uploading the zip, the
owner dispatches `release-finish.yml` again; its `mac` job approval is then the only click, and it
replaces the zip with CI's.

## The rehearsal on `v0.7.1-rc.2`

P343 7b already approved this rehearsal: `v0.7.1-rc.2`, from a branch that is never merged and that
the owner deletes afterwards. It now covers the whole graph.

1. The setup guide is done (steps 1 to 7). Slices A, B and D have merged.
2. The supervisor makes branch `rehearsal/v0.7.1-rc.2` from `main`. It changes only `VERSION`
   (`0.7.1-rc.2`) and `CHANGELOG.md` (a `## v0.7.1-rc.2 — <date>` section with a site line).
3. The supervisor dispatches `release.yml` from that branch. Expect `version`, `ci` and `release`
   green, a prerelease draft with ten assets, and `finish` skipped (not main).
4. The supervisor dispatches `release-finish.yml` from `main` with `tag=v0.7.1-rc.2`. The owner
   approves `mac` once.
5. **Pass:**
   - `mac` notarizes, with `notarytool` accepting the zip.
   - `mac-verify` is green on both architectures.
   - `publish` publishes the prerelease (tag `v0.7.1-rc.2` at the branch commit, not marked latest),
     pushes `rc/v0.7.1-rc.2` to the tap, and opens the site PR, whose `site-check` passes.
   - `verify` runs `brew install` from that tap branch and gets `version 0.7.1-rc.2` on both
     architectures.
   - There was exactly one approval prompt.
6. **Then delete what it made:** the release and tag `v0.7.1-rc.2` (`gh release delete
   v0.7.1-rc.2 --cleanup-tag`), the `v0.7.1-rc.1` draft, the tap branch, the site PR and its branch,
   and `rehearsal/v0.7.1-rc.2`. The run link goes in the worklog note of the PR that records the
   result.

**What the rehearsal does not exercise** (the owner accepted this on 2026-11-12, with the by-hand
fallback below): the push-triggered path (`release.yml` calling `finish`
on `main`), a commit to the tap's `main`, and an auto-merge on the site. These are the same steps
with a different branch and one flag. The first real release is their first run. If any of them
fails, the release is already published, and the fallback is today's manual step for that one
piece: commit the formula, or merge the site PR.

**If it does not pass before the soak ends,** v0.7.1 ships the way it does today. `release.yml`
and `mac-sign.yml` are left as they are on the release commit (slice B is held or reverted), and
this lands after the tag.

## Slices

Concurrent slices touch different files (P250). Each gets a fresh agent and is reviewed
adversarially by a fresh reviewer, whose findings are posted on its PR.
The model column names the tier from CLAUDE.md's "Agent context discipline" (P148b): the
implementation tier for a slice and its tests, the review tier for adversarial review, the
mechanical tier for work fully specified by a pattern.

| Slice | What | Files | Model (tier) |
|---|---|---|---|
| A | `mac_keychain.sh` re-wraps the `.p12` (see "Security notes") with a test; `release_check.sh publish-ready`; `release_notes.sh site` and dropping the site line; `site_release.py`; their tests in `ci.yml`'s scripts step; the new codes in `docs/ERRORS.md` | `.github/scripts/*`, `docs/ERRORS.md`, `ci.yml` (one step) | implementation tier; review tier |
| D | The site's `check.yml` (`site-check`), as a PR on `NervaLog/nervalog.github.io` (runs in parallel with A) | that repository only | implementation tier; review tier |
| B | `release-finish.yml`; `release.yml`'s `finish` and site-line refusal; `mac-verify.yml`'s `tap-ref`. Tried on a dispatch with a prerelease before review where it can be (no secrets are needed up to `mac`). After A. | `.github/workflows/{release,release-finish,mac-verify}.yml` | implementation tier; review tier (security focus: environments, tokens, argv) |
| C | Header comments of `mac-sign.yml`, `release.yml` and `mac-verify.yml`; `docs/INSTALL.md`'s tap wording; the CLAUDE.md release line, and a CLAUDE.md rule that a session never approves a deployment (P360 2 relies on it). Mechanical, from this spec. After B. | those files | mechanical tier; the supervisor checks the diff |
| E | The setup guide above | GitHub settings | owner (in parallel with A and D) |
| F | The rehearsal, the cleanup, and the run link recorded | worklog | supervisor |
