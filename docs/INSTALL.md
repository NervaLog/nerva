# Installing Nerva

Nerva v0.7.1 is not released yet. This page says how each kind of download installs, so that the
release can be used from its notes alone. Until the release exists, the file names below are the
names the release process is set up to give its assets (the release workflow for the Linux
assets, `zig build -Drelease mac-release` for the Mac zip), and the Homebrew tap and the packages are
built but not published: check the release page for what it actually lists. Nothing here is
signed by a Linux key; what is signed or checked is said under each heading.

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
| Linux with systemd, production | the tarball and `install.sh`, or the `.deb` or `.rpm` | [Linux](#linux) |
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

The tap is `NervaLog/homebrew-tap`. It is not published yet; its formula is generated from
[`packaging/homebrew/nerva.rb`](../packaging/homebrew/nerva.rb) by `zig build -Drelease mac-release`, and
installs the prebuilt universal binary (arm64 and x86_64) pinned by its SHA-256. It builds nothing
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

The zip's binary is meant to be signed with the owner's Developer ID and notarized before the release is
published; neither has been done for a candidate, and this page does not say it has. A bare
executable cannot carry Apple's notarization ticket, so Gatekeeper looks the notarization up
online when the file is first opened.

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

Download the file for your machine (`uname -m` says `x86_64` or `aarch64`).

### The tarball and `install.sh`

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

**They are not signed in v0.7.1**, and there is no apt or dnf repository: you download the file,
[check it against `SHA256SUMS`](#checking-a-download), and install it from disk.

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
