#!/usr/bin/env python3
"""Writes the software bill of materials for a release, as CycloneDX 1.5 JSON (N62).

Usage: sbom.py <tag> <commit> [<repository root>]

Nerva has no package dependencies. What its binaries are made of is read from the repository's
own pins, so the SBOM cannot drift from them:
- Nerva itself: the tag, the commit, and the protocol release (`release` in build.zig).
- TigerBeetle, vendored with local changes: the pinned commit in UPSTREAM.md.
- The Zig standard library and compiler-rt, compiled into every binary: the Zig version in
  zig/download.sh, which must match UPSTREAM.md and build.zig.
- The Zig compiler that built them (not shipped): the pinned SHA-256 of the x86_64-linux archive,
  the host every target is cross-compiled on.
The output depends only on the tag, the commit and the repository, so it is reproducible.
"""
import json
import os
import re
import subprocess
import sys
import uuid
from pathlib import Path

REPOSITORY = "Botpike/nerva-ledger"
BUILD_HOST = "x86_64-linux"


def fail(message):
    print(f"::error::sbom.py: {message}", file=sys.stderr)
    sys.exit(1)


def find(pattern, text, what):
    matches = re.findall(pattern, text, re.MULTILINE)
    if len(matches) != 1:
        fail(f"expected one {what}, found {len(matches)}")
    return matches[0]


def pins(root):
    """The versions the release is built from, checked against each other."""
    upstream = (root / "UPSTREAM.md").read_text()
    download = (root / "zig" / "download.sh").read_text()
    build = (root / "build.zig").read_text()

    tigerbeetle = find(r"^- \*\*Pinned commit:\*\* `([0-9a-f]{40})`", upstream,
                       "pinned TigerBeetle commit in UPSTREAM.md")
    zig = find(r'^ZIG_RELEASE="([0-9]+\.[0-9]+\.[0-9]+)"$', download,
               "ZIG_RELEASE in zig/download.sh")
    zig_upstream = find(r"^- \*\*Zig:\*\* ([0-9]+\.[0-9]+\.[0-9]+)", upstream,
                        "Zig version in UPSTREAM.md")
    zig_build = ".".join(
        find(rf"\.{part} = ([0-9]+),", build.split("const zig_version", 1)[1].split("};", 1)[0],
             f"zig_version.{part} in build.zig")
        for part in ("major", "minor", "patch"))
    if not zig == zig_upstream == zig_build:
        fail(f"Zig versions disagree: zig/download.sh {zig}, UPSTREAM.md {zig_upstream}, "
             f"build.zig {zig_build}")
    toolchain_sha256 = find(
        rf"/zig-{BUILD_HOST}-{re.escape(zig)}\.tar\.xz ([0-9a-f]{{64}})$", download,
        f"pinned SHA-256 of the {BUILD_HOST} Zig archive in zig/download.sh")
    protocol = find(r'^const release = "([0-9]+\.[0-9]+\.[0-9]+)";$', build,
                    "protocol release in build.zig")
    return {
        "tigerbeetle": tigerbeetle,
        "zig": zig,
        "toolchain_sha256": toolchain_sha256,
        "protocol": protocol,
    }


def commit_time(root, commit):
    result = subprocess.run(["git", "-C", str(root), "show", "-s", "--format=%cd",
                             "--date=format-local:%Y-%m-%dT%H:%M:%SZ", commit],
                            capture_output=True, text=True, env={**os.environ, "TZ": "UTC"})
    if result.returncode != 0:
        fail(f"commit {commit} not found: {result.stderr.strip()}")
    return result.stdout.strip()


def sbom(tag, commit, root):
    if not re.fullmatch(r"v[0-9]+\.[0-9]+\.[0-9]+(-[0-9A-Za-z.]+)?", tag):
        fail(f"not a release tag: {tag!r}")
    if not re.fullmatch(r"[0-9a-f]{40}", commit):
        fail(f"not a full commit hash: {commit!r}")
    pinned = pins(root)
    version = tag[1:]
    apache = [{"license": {"id": "Apache-2.0"}}]
    mit = [{"license": {"id": "MIT"}}]
    return {
        "bomFormat": "CycloneDX",
        "specVersion": "1.5",
        "serialNumber": "urn:uuid:" + str(uuid.uuid5(
            uuid.NAMESPACE_URL, f"https://github.com/{REPOSITORY}/releases/{tag}#{commit}")),
        "version": 1,
        "metadata": {
            "timestamp": commit_time(root, commit),
            "tools": {"components": [{
                "type": "application",
                "name": "sbom.py",
                "description": f"{REPOSITORY} .github/scripts/sbom.py at {commit}",
            }]},
            "component": {
                "type": "application",
                "bom-ref": "nerva",
                "name": "nerva",
                "version": version,
                "description": "Nerva: replicated log with declared derived state",
                "licenses": apache,
                "purl": f"pkg:github/{REPOSITORY}@{tag}",
                "externalReferences": [
                    {"type": "vcs", "url": f"https://github.com/{REPOSITORY}"},
                    {"type": "distribution",
                     "url": f"https://github.com/{REPOSITORY}/releases/tag/{tag}"},
                ],
                "properties": [
                    {"name": "nerva:commit", "value": commit},
                    {"name": "nerva:protocol_release", "value": pinned["protocol"]},
                ],
            },
        },
        "components": [
            {
                "type": "library",
                "bom-ref": "tigerbeetle",
                "name": "tigerbeetle",
                "version": pinned["tigerbeetle"],
                "description": "Consensus, storage, IO and simulator, vendored as source",
                "licenses": apache,
                "purl": f"pkg:github/tigerbeetle/tigerbeetle@{pinned['tigerbeetle']}",
                "externalReferences": [
                    {"type": "vcs", "url": "https://github.com/tigerbeetle/tigerbeetle"},
                ],
                "pedigree": {"notes": "Copied at the pinned commit, with local changes; "
                             f"every change is listed in UPSTREAM.md at {commit}."},
            },
            {
                "type": "library",
                "bom-ref": "zig-std",
                "name": "zig standard library and compiler-rt",
                "version": pinned["zig"],
                "description": "Compiled into every binary. Linux binaries are static and link "
                               "no libc; macOS binaries link the system's libSystem.",
                "licenses": mit,
                "purl": f"pkg:generic/ziglang/zig-std@{pinned['zig']}",
                "externalReferences": [{"type": "vcs", "url": "https://github.com/ziglang/zig"}],
            },
            {
                "type": "application",
                "bom-ref": "zig",
                "name": "zig",
                "version": pinned["zig"],
                "description": f"The compiler that built every target, on {BUILD_HOST}; "
                               "not shipped",
                "scope": "excluded",
                "licenses": mit,
                "purl": f"pkg:generic/ziglang/zig@{pinned['zig']}",
                "hashes": [{"alg": "SHA-256", "content": pinned["toolchain_sha256"]}],
                "externalReferences": [{
                    "type": "distribution",
                    "url": f"https://ziglang.org/download/{pinned['zig']}/"
                           f"zig-{BUILD_HOST}-{pinned['zig']}.tar.xz",
                }],
            },
        ],
        "dependencies": [
            {"ref": "nerva", "dependsOn": ["tigerbeetle", "zig-std"]},
            {"ref": "tigerbeetle", "dependsOn": ["zig-std"]},
            {"ref": "zig-std", "dependsOn": []},
            {"ref": "zig", "dependsOn": []},
        ],
    }


def main():
    if len(sys.argv) not in (3, 4):
        fail("usage: sbom.py <tag> <commit> [<repository root>]")
    root = Path(sys.argv[3] if len(sys.argv) == 4 else ".")
    json.dump(sbom(sys.argv[1], sys.argv[2], root), sys.stdout, indent=2)
    print()


if __name__ == "__main__":
    main()
