# Installing Nerva

Nerva v0.7.1 is not released yet. This page says how each kind of download installs, so that the
release can be used from its notes alone. Until the release exists, the file names below are the
names the release process is set up to give its assets (the release workflow for the Linux
assets, `zig build -Drelease mac-release` for the Mac zip), and the Homebrew tap and the packages are
built but not published: check the release page for what it actually lists. The Linux
repositories at `packages.nerva.pro` are signed (see [Linux](#the-apt-and-dnf-repositories));
the files on the release page are not, and are checked with `SHA256SUMS`. What is signed or
checked is said under each heading.

Nerva is for development and evaluation on macOS, and for production on Linux (x86_64 with AES, or
aarch64). Nerva is alpha: see [MATURITY.md](./MATURITY.md) for what that promises.

**Where the outputs come from.** Every output on this page and in [QUICKSTART.md](./QUICKSTART.md)
was recorded from a build of `main` at commit `4ddd232` on Linux x86_64 (the candidate's
`nerva version` still says `version 0.7.0` there, because `VERSION` is bumped last). The release
re-records them. Outputs marked "not run" were written from the files and not run.

## Which download

| You have | Take | Section |
|---|---|---|
| a Mac | Homebrew, or the zip | [macOS](#macos) |
| Linux with systemd, production | the apt or dnf repository, or the tarball and `install.sh`, or the `.deb` or `.rpm` | [Linux](#linux) |
| Linux, to try it | the tarball, run by hand | [QUICKSTART.md](./QUICKSTART.md) |
| any machine with a compiler | the source | [From source](#from-source) |

The tarballs, the packages and the bill of materials are covered by `SHA256SUMS`, and the Mac
zip by its own `.sha256` file: [check a download first](#checking-a-download).

## macOS

### Homebrew

```bash
brew install nervalog/tap/nerva
nerva version
```

The tap is `NervaLog/homebrew-tap`, which exists once the first release is out; from then on
`brew install nervalog/tap/nerva` installs the latest release from its `main`. A release candidate's
formula is on the tap's `rc/v<V>` branch, never on `main`, so `brew install` never installs one.
The formula is generated from
[`packaging/homebrew/nerva.rb`](../packaging/homebrew/nerva.rb) by `zig build -Drelease mac-release`, which the
release's Mac signing job runs (`mac-sign.yml`), and installs the prebuilt universal binary (arm64 and x86_64) pinned by its SHA-256. It builds nothing
and needs no `sudo`. The formula's own test is that `nerva version` ends in `version <the
release>`.

### The zip

`nerva-v0.7.1-universal-macos.zip` holds a directory, `nerva-v0.7.1-universal-macos/`, with the
universal `nerva`, `LICENSE` and `NOTICE`; its SHA-256 is in `nerva-v0.7.1-universal-macos.zip.sha256`
beside it.

```bash
unzip nerva-v0.7.1-universal-macos.zip
./nerva-v0.7.1-universal-macos/nerva version
```

The release page also lists `nerva-v0.7.1-x86_64-macos.tar.gz` and
`nerva-v0.7.1-aarch64-macos.tar.gz`. They are for scripts that pin them: they are not signed with
a Developer ID or notarized, so Gatekeeper may block them. On a Mac, take Homebrew or the zip.

The zip's binary is signed with a Developer ID Application certificate and notarized by Apple in the
release's Mac signing job (`mac-sign.yml`), which runs once the owner approves it. If that job
cannot run, the owner signs and notarizes on a Mac instead, and the release notes say which. A bare
executable cannot carry Apple's notarization ticket, so Gatekeeper looks the notarization up online
when the file is first opened: the first launch needs a network connection.

**A browser download.** A browser marks what it downloads with a quarantine attribute, and
Gatekeeper then checks the file when it first runs. A notarized binary passes that check. If macOS
refuses a binary from a zip whose SHA-256 you have already verified against its `.sha256`, you
can clear the mark, from the directory you unzipped in, with
`xattr -d com.apple.quarantine nerva-v0.7.1-universal-macos/nerva` (the mark is usually on the
zip, and on what Archive Utility extracts from it). Do that only for a zip whose SHA-256 matches.
Homebrew and `curl` do not set the mark.

macOS is not a production platform for Nerva: no Mac has been used to test Nerva's durability or
failure behavior, and the production claims in this repository are Linux's.

## Linux

### The apt and dnf repositories

`https://packages.nerva.pro` serves signed apt and dnf repositories with every release (v0.7.1 and
later). The repository's metadata and its rpms are signed with one key, and its fingerprint is

```
949F066FB37C440E54B2A902AEA7B66340A6DBAB
```

It is `packaging/keys/fingerprints` in this repository, the `current` line. Check it before you
trust the key: the key file comes from GitHub, and the steps below show you the fingerprint.

**Debian 12 and 13, Ubuntu 22.04 and 24.04** (apt 2.4 or later reads an armored key file):

```bash
sudo install -d -m 0755 /etc/apt/keyrings
curl -fsSL https://raw.githubusercontent.com/NervaLog/nerva/main/packaging/keys/nerva-release.asc | sudo tee /etc/apt/keyrings/nerva.asc > /dev/null
gpg --show-keys /etc/apt/keyrings/nerva.asc     # the pub line's fingerprint must be 949F066FB37C440E54B2A902AEA7B66340A6DBAB
sudo tee /etc/apt/sources.list.d/nerva.sources > /dev/null <<'EOF'
Types: deb
URIs: https://packages.nerva.pro/apt
Suites: stable
Components: main
Architectures: amd64 arm64
Signed-By: /etc/apt/keyrings/nerva.asc
EOF
sudo apt update && sudo apt install nerva
```

(A minimal Debian or Ubuntu image has neither `curl` nor `ca-certificates`: install both first,
`sudo apt install curl ca-certificates`. `gpg` is not there either. Compare the fingerprint on
another machine, or install `gnupg` first. `Architectures` keeps apt from asking for i386 on hosts with multiarch. To
pin Nerva, pin by Origin, `o=Nerva`: the Suite name `stable` is also Debian's.)

**Fedora 43 and later, Rocky Linux and RHEL 9** (Fedora 41 and 42 are past their end of life and
are not supported):

```bash
sudo tee /etc/yum.repos.d/nerva.repo > /dev/null <<'EOF'
[nerva]
name=Nerva
baseurl=https://packages.nerva.pro/rpm/stable
enabled=1
gpgcheck=1
repo_gpgcheck=1
gpgkey=https://raw.githubusercontent.com/NervaLog/nerva/main/packaging/keys/nerva-release.asc
EOF
sudo dnf install nerva      # dnf shows the key's fingerprint and asks: it must be 949F066FB37C440E54B2A902AEA7B66340A6DBAB
```

- **dnf 5 (Fedora 43 and later here)** fetches the key from `gpgkey=` and asks once; answering yes
  imports it for both the repository's metadata and the packages. Do not import it with
  `rpm --import` instead: dnf 5 then cannot verify `repomd.xml` ("Signing key not found"). On
  Fedora 43 and 44, update dnf5 first (`sudo dnf upgrade dnf5`) if the import hangs.
- **Fallback, if `repo_gpgcheck` still fails:** `repo_gpgcheck=0`. Each rpm is still checked
  against the key (`gpgcheck=1`), so nothing unsigned installs. What it gives up: the signed
  metadata, so a mirror or a bucket token holder could offer an older signed Nerva, or hide a new
  one.
- **Upgrades:** `sudo apt update && sudo apt upgrade`, or `sudo dnf upgrade nerva`. A package
  upgrade replaces the binary and never restarts a replica (P295b). Restart them as OPERATING.md
  says.
- **Candidates:** use `Suites: rc`, or `baseurl=https://packages.nerva.pro/rpm/rc`. That channel
  also has every release.
- **Switching from a downloaded package:** add the repository. The package installed from the file
  is the same package, and the next upgrade comes from the repository.

**Check the key through a second channel.** The key file comes from GitHub. `nerva.pro`
publishes the same key by WKD, from another repository and another host. Both must show the same
fingerprint, `949F066FB37C440E54B2A902AEA7B66340A6DBAB`:

```bash
curl -fsSL 'https://nerva.pro/.well-known/openpgpkey/hu/ndqm47zydhyqyzabecddtdk1q3bponab?l=nerva' | gpg --show-keys
```

If the two disagree, stop and do not install. Report it as a security issue. (With GnuPG's own
lookup, `gpg --auto-key-locate clear,wkd --locate-external-keys nerva@nerva.pro` does the same,
but it imports the key into your keyring.)

**A new signing key, every two years.** There is one key, with no subkeys, so a rotation is a new
key with a new fingerprint (P392). Nothing changes until the CHANGELOG and the pinned issue
announce it, and the announcement carries the new fingerprint: compare it, through both channels
above, before you accept it.

- **apt:** run the `curl` line above again, and check the new fingerprint. If you miss it,
  `apt update` fails with `NO_PUBKEY` after the switch, and the same line fixes it.
- **dnf:** run `sudo dnf upgrade --refresh nerva`. dnf asks to import the new key from `gpgkey=`:
  answer yes only if its fingerprint is the announced one. On dnf 5, a host that has not received
  the new key skips the repository and exits 0 ("Signing key not found"), so read the output of an
  upgrade, not its exit status.

The repository's rpms and metadata are signed, while the files on the release page are not, and
are checked with `SHA256SUMS`.

### The tarball and `install.sh`

Without the repository, download the file for your machine (`uname -m` says `x86_64` or `aarch64`).

`nerva-v0.7.1-x86_64-linux.tar.gz` and `nerva-v0.7.1-aarch64-linux.tar.gz` unpack to a directory of
the same name that holds `nerva`, `LICENSE`, `NOTICE`, `install.sh`, the units `nerva@.service`
and `nerva-api@.service`, and the settings examples `replica.env.example` and `api.env.example`.

```bash
tar -xzf nerva-v0.7.1-x86_64-linux.tar.gz
cd nerva-v0.7.1-x86_64-linux
sudo ./install.sh --dry-run     # says what it would do; changes nothing
sudo ./install.sh
```

As root, `install.sh`:

- puts `nerva` in `/usr/local/bin`;
- creates the system user and group `nerva` (home `/var/lib/nerva`, no login), `/var/lib/nerva`
  (mode 0750, for data files) and `/etc/nerva` (0750, for settings);
- installs `nerva@.service` (one replica per instance, `nerva@0`) and `nerva-api@.service` (one
  gateway per instance) in `/etc/systemd/system`, and the two `.env.example` files in `/etc/nerva`,
  then runs `systemctl daemon-reload`.

It formats nothing and enables and starts nothing. It prints the next three commands, which
[QUICKSTART.md](./QUICKSTART.md#three-hosts) explains. A second run changes nothing.

Flags: `--dry-run` (the same checks as a real run, no change), `--upgrade` (replace a `nerva` of
another release: stop the replicas first and start them after; the only upgrade this release states as in place is v0.7.0 to v0.7.1, see
[OPERATING.md](./OPERATING.md#upgrading), and read
[Upgrading a cluster](../README.md#upgrading-a-cluster) when the protocol release changes), and
`--uninstall` (removes the binary and the units, and is refused with NRV-E1118 while replicas or the gateway run: stop them first; leaves `/var/lib/nerva`, `/etc/nerva` and the
user, so your data stays).

When `install.sh` refuses, it prints one coded block and changes nothing
([docs/ERRORS.md](./ERRORS.md)):

| Code | Exit | It means | Do |
|---|---|---|---|
| NRV-E1101 | 1 | not run as root | run it with `sudo` |
| NRV-E1102 | 2 | no running systemd (a container, or a machine booted without it) | install on a systemd machine, or run `nerva` by hand |
| NRV-E1103 | 1 | a different `nerva` is already in `/usr/local/bin` | stop the replicas, then `--upgrade` |
| NRV-E1104 | 2 | the tarball is for another architecture than this machine | take the other tarball |
| NRV-E1105 | 1 | a user, group or unit named `nerva` exists and is not Nerva's | rename or remove it, or give the user home `/var/lib/nerva` and group `nerva` |
| NRV-E1106 | 1 | a flag it does not take | `install.sh --help` |
| NRV-E1107 | 2 | this machine cannot run the tarball's `nerva` (a `noexec` mount such as `/tmp` on a hardened host) | unpack where programs may run |
| NRV-E1108 | 1 | the tarball is incomplete, or `install.sh` ran outside it | unpack it whole, run from its directory |
| NRV-E1109 | 2 | no `sha256sum` | install coreutils |
| NRV-E1118 | 1 | an install over a different `nerva` (the tarball's in `/usr/local/bin`, else a package's in `/usr/bin`), or an `--uninstall` of `/usr/local/bin/nerva`, while `nerva@*` or `nerva-api@*` units are running | stop them, install (`--upgrade` over a tarball install), start them |

When a package's `/usr/bin/nerva` is installed too, `install.sh` goes on and warns (NRV-W1102): the tarball's
`/usr/local/bin/nerva` comes first on the path, so it is the one the units run. Leave the package installed: removing it disables the enabled `nerva@N` and `nerva-api@N` instances, so enable them again afterwards. `install.sh --uninstall` keeps those instances while the package's `/usr/bin/nerva` exists.

Recorded: `./install.sh --dry-run`, as root, in a container that is not running systemd:

```
error[NRV-E1102]: install.sh: this machine is not running systemd
  cause  The installer found no running systemd
  fix    install on a machine that boots with systemd, or run nerva by hand (docs/QUICKSTART.md)
```

(exit status 2). The installing run itself needs systemd and was not run there.

### The `.deb` and the `.rpm`

Each release has a `.deb` (`amd64`, `arm64`) and an `.rpm` (`x86_64`, `aarch64`):
`nerva_0.7.1-1_<arch>.deb` and `nerva-0.7.1-1.<arch>.rpm`. They hold the same binary and the same
units and examples as the tarball: the binary in `/usr/bin/nerva`, the units in
`/usr/lib/systemd/system`, and the two examples in `/usr/share/nerva`. They create the `nerva`
user, `/var/lib/nerva` and `/etc/nerva`, but **do not put the examples in `/etc/nerva`**: you copy
them there yourself ([QUICKSTART.md](./QUICKSTART.md#three-hosts)). They format, enable and start
nothing, and removing them leaves your data, your settings and the user.

**The files on the release page are not signed**: you download the file,
[check it against `SHA256SUMS`](#checking-a-download), and install it from disk. The
[repository](#the-apt-and-dnf-repositories) serves the same packages, signed.

```bash
sudo apt install ./nerva_0.7.1-1_amd64.deb         # Debian 12, Ubuntu 24.04
sudo dnf install ./nerva-0.7.1-1.x86_64.rpm        # Rocky 9, Fedora
```

Use `dnf` for the `.rpm`: it installs a local unsigned file with its defaults. Fedora's rpm 6
refuses an unsigned file with `rpm -i` and `rpm -U`; with rpm directly, add `--nosignature`
(`sudo rpm -U --nosignature nerva-0.7.1-1.x86_64.rpm`). Rocky 9's rpm accepts both. Do not turn
signature checking off globally for this.

A package refuses to install, before it unpacks anything, when:

- a user `nerva` that is not Nerva's already exists (NRV-E1105); or
- on a first install, `/usr/local/bin/nerva` or a unit in `/etc/systemd/system` exists and would
  shadow the package's (NRV-E1111). If it is a tarball install, run `sudo ./install.sh --uninstall`
  from the tarball first; it keeps your data, your settings and the user. Otherwise move or remove
  the file. An upgrade is not refused, but if `/usr/local/bin/nerva` is still there, the preinst warns
  (NRV-W1101) that it shadows the package's binary and the replicas keep running it. See
  [TROUBLESHOOTING.md](./TROUBLESHOOTING.md#the-installer-refused).

What differs from the tarball when you follow [QUICKSTART.md](./QUICKSTART.md#three-hosts): the
examples are in `/usr/share/nerva`, not `/etc/nerva`, and the binary is `/usr/bin/nerva`, not
`/usr/local/bin/nerva`. Everything else is the same.

## From source

Zig is pinned inside the repository and `./zig/download.sh` installs it; nothing else is needed.
The commands are in the README's [Building](../README.md#building):

```bash
git clone https://github.com/NervaLog/nerva.git && cd nerva
./zig/download.sh
./zig/zig build -Drelease      # zig-out/bin/nerva
```

A build from a checkout prints `+<commit>` after the protocol release. `./zig/zig build test`
runs the unit tests and the format check. The unit tests build and run on macOS (Apple silicon in
CI); Linux needs io_uring.

## Checking a download

Every release has `SHA256SUMS` and a bill of materials, `nerva-v0.7.1.cdx.json` (CycloneDX 1.5): the
vendored TigerBeetle commit and the Zig toolchain Nerva was built from. `SHA256SUMS` lists the
tarballs, the packages and the bill of materials, not the Mac zip. Put the files you downloaded
beside `SHA256SUMS`:

```bash
sha256sum -c --ignore-missing SHA256SUMS          # Linux
grep nerva-v0.7.1-aarch64-macos.tar.gz SHA256SUMS | shasum -a 256 -c    # macOS: one file
```

The Mac zip has its own file, `<hex>  <name>`, beside it:

```bash
shasum -a 256 -c nerva-v0.7.1-universal-macos.zip.sha256     # macOS
```

Homebrew checks the formula's own `sha256` when it installs.

Recorded, on a Linux tarball and a `SHA256SUMS` made by hand from it on `4ddd232` (no release
workflow has produced either yet):

```
nerva-v0.7.1-x86_64-linux.tar.gz: OK
```

The `shasum` forms were not run (this machine is not a Mac).

A line that says `FAILED` means the file is not the release's: delete it and download again. The
checksum proves the file is the one the workflow published, not that the workflow can be trusted:
for that, read the build ([release.yml](../.github/workflows/release.yml)) and the bill of
materials, which lists every pinned input.

The SBOM is JSON; `python3 -m json.tool nerva-v0.7.1.cdx.json` pretty-prints it, and any
CycloneDX tool reads it.

Then, on any download:

```bash
nerva version
```

Its first line is `Nerva version <protocol release>+<commit>`; its last is `version <release>`, the
one on GitHub and in `brew`. Next: [QUICKSTART.md](./QUICKSTART.md).

## Where to go next

[QUICKSTART.md](./QUICKSTART.md) runs a first cluster. For production read
[OPERATING.md](./OPERATING.md) (sizing, backups, upgrades) and [SECURITY.md](../SECURITY.md) (what
the keys protect) before you rely on it, and [MATURITY.md](./MATURITY.md) for what the alpha label
promises. When an install refuses, [TROUBLESHOOTING.md](./TROUBLESHOOTING.md#the-installer-refused)
has each message.
