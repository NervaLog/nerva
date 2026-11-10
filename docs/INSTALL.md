# Installing Nerva

Nerva v0.7.1 is not released yet. This page says how each kind of download installs, so that the
release can be used from its notes alone. Until the release exists, the file names below are the
names the release workflow gives its assets, and the Homebrew tap and the packages are built but
not published. Nothing here is signed by a Linux key; what is signed or checked is said under each
heading.

Nerva is for development and evaluation on macOS, and for production on Linux (x86_64 with AES, or
aarch64). It is a research database: see the [README](../README.md) for what that promises.

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

Every release asset is covered by `SHA256SUMS`: [check it first](#checking-a-download).

## macOS

### Homebrew

```bash
brew install nervalog/tap/nerva
nerva version
```

The tap is `NervaLog/homebrew-tap`. It is not published yet; its formula is generated from
[`packaging/homebrew/nerva.rb`](../packaging/homebrew/nerva.rb) by `zig build mac-release`, and
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

The binary is meant to be signed with the owner's Developer ID and notarized before the release is
published; neither has been done for a candidate, and this page does not say it has. A bare
executable cannot carry Apple's notarization ticket, so Gatekeeper looks the notarization up
online when the file is first opened.

**A browser download.** A browser marks what it downloads with a quarantine attribute, and
Gatekeeper then checks the file when it first runs. A notarized binary passes that check. If macOS
refuses a file you have already verified against its checksum, you can clear the mark with
`xattr -d com.apple.quarantine nerva`. Do that only for a file whose SHA-256 matches. Homebrew and
`curl` do not set the mark.

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
another release: stop the replicas first and start them after, and read
[Upgrading a cluster](../README.md#upgrading-a-cluster) when the protocol release changes), and
`--uninstall` (removes the binary and the units; leaves `/var/lib/nerva`, `/etc/nerva` and the
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
units and examples as the tarball (the binary in `/usr/bin/nerva`, the units in
`/usr/lib/systemd/system`, the examples in `/usr/share/doc/nerva`), and create the `nerva` user,
`/var/lib/nerva` and `/etc/nerva`. They format, enable and start nothing, and removing them leaves
your data, your settings and the user.

**They are not signed in v0.7.1**, and there is no apt or dnf repository: you download the file,
[check it against `SHA256SUMS`](#checking-a-download), and install it from disk.

```bash
sudo apt install ./nerva_0.7.1-1_amd64.deb         # Debian 12, Ubuntu 24.04
sudo dnf install ./nerva-0.7.1-1.x86_64.rpm        # Rocky 9, Fedora
```

`dnf` installs a local unsigned file with its defaults. Fedora 43 and later carry rpm 6, whose own
command refuses an unsigned file, so use `dnf` there; with rpm directly, `sudo rpm -U --nosignature
nerva-0.7.1-1.x86_64.rpm` works on every version. Do not turn signature checking off globally for
this. A package whose user `nerva` conflicts with another one fails with NRV-E1105 before it
unpacks anything.

The next steps are the same as after the tarball: [QUICKSTART.md](./QUICKSTART.md#three-hosts).

## From source

Zig is pinned inside the repository and `./zig/download.sh` installs it; nothing else is needed.
The commands are in the README's [Building](../README.md#building):

```bash
git clone https://github.com/NervaLog/nerva.git && cd nerva
./zig/download.sh
./zig/zig build -Drelease      # zig-out/bin/nerva
```

A build from a checkout prints `+<commit>` after the protocol release. `./zig/zig build test`
runs the unit tests and the format check; Linux needs io_uring, and the unit tests do not build
on a Mac.

## Checking a download

Every release has `SHA256SUMS` and a bill of materials, `nerva-v0.7.1.cdx.json` (CycloneDX 1.5): the
vendored TigerBeetle commit and the Zig toolchain Nerva was built from. Put the files you
downloaded beside `SHA256SUMS`:

```bash
sha256sum -c --ignore-missing SHA256SUMS          # Linux
shasum -a 256 -c SHA256SUMS                       # macOS (it reports every missing file)
```

Recorded, on the Linux tarball:

```
nerva-v0.7.1-x86_64-linux.tar.gz: OK
```

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
