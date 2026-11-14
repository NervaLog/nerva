#!/usr/bin/env python3
"""A binary that carries the release before it (R6 slice 3, P259d, P417).

Usage: bundle.py <nerva> <nerva_next> <nerva_pack>

`nerva_next` is this code under the next test release, packed with a build of `nerva` (the past
release). Checks, without a cluster:
- `nerva_next version` lists the bundled release, `nerva version` bundles none, and the format
  digests are equal;
- one changed byte in each part of the bundle (the code, the past release, the header, the
  section names, the section table, the trailer) is refused with NRV-E0719, never run or read
  as "bundles none";
- the packer refuses, with NRV-E0725 and no output, a past release that is not lower, of another
  format digest, or whose clients the next release would refuse;
- the packer refuses an input it cannot read in full (NRV-E0727) or an output it cannot write
  (NRV-E0810), with a code and no error name;
- the packer refuses a result over its size limit with NRV-E0719, and writes it at the limit;
- the packed binary is under `multiversion_binary_platform_size_max` (64 MiB); the margin is
  printed.
`nerva_next start` on N's data file (the switch) is slice 2's test, `rolling.py`.
"""
import os
import re
import shutil
import stat
import subprocess
import sys
import tempfile

PLATFORM_SIZE_MAX = 64 * 1024 * 1024  # config.process.multiversion_binary_platform_size_max.
SECTION_NAME = b".tb_mvb"


def run(argv):
    return subprocess.run(argv, capture_output=True, text=True, timeout=120)


def facts(exe):
    result = run([exe, "version", "--verbose"])
    assert result.returncode == 0, (exe, result.stderr)
    return dict(line.split(" ", 1) for line in result.stdout.splitlines() if " " in line)


def stub(path, text):
    """A past 'release' that only says its facts: the packer needs nothing else of it."""
    with open(path, "w") as file:
        file.write("#!/bin/sh\ncat <<'EOF'\n" + text + "EOF\n")
    os.chmod(path, 0o755)


def facts_text(release, client_min, fmt, commit):
    return (f"Nerva version 0.0.0\nrelease {release}\nrelease_client_min {client_min}\n"
            f"format {fmt}\nbundles none\nversion 0.0.0\ncommit {commit}\n")


def main():
    nerva, nerva_next, nerva_pack = sys.argv[1:4]
    work = tempfile.mkdtemp(prefix="nerva-bundle-")
    try:
        check(nerva, nerva_next, nerva_pack, work)
    finally:
        shutil.rmtree(work, ignore_errors=True)


def past_stub_ok(work, base):
    path = os.path.join(work, "past_stub_ok")
    stub(path, facts_text("0.0.5", base[1], base[2], base[3]))
    return path


def check(nerva, nerva_next, nerva_pack, work):
    past = facts(nerva)
    next_ = facts(nerva_next)
    assert past["format"] == next_["format"], "the pair differs in format: not a rolling pair"

    # `version` lists both releases.
    out = run([nerva, "version", "--verbose"]).stdout
    assert "\nbundles none\n" in out, out
    out = run([nerva_next, "version", "--verbose"]).stdout
    assert f"\nbundles {past['release']}\n" in out, out
    assert f"\nrelease {next_['release']}\n" in out, out
    assert next_["release"] != past["release"]

    # A reader that stops after one line (`| head -n1`, as install.sh does) is not a bug (#420),
    # however long `version` takes to read the binary: the whole text is written once.
    for exe in (nerva, nerva_next):
        piped = subprocess.run(f'"{exe}" version | head -n1', shell=True, capture_output=True, text=True)
        assert piped.returncode == 0 and piped.stderr == "", (exe, piped.stderr)

    # The size, against the bound.
    size = os.path.getsize(nerva_next)
    assert size < PLATFORM_SIZE_MAX, f"packed binary is {size} bytes, over {PLATFORM_SIZE_MAX}"
    print(f"bundle: nerva_next is {size} bytes, {PLATFORM_SIZE_MAX - size} under the limit "
          f"({size * 100 // PLATFORM_SIZE_MAX}% of it)")

    # One changed byte is damage, wherever it is: the unloaded tail of the linked executable (so
    # that the damaged binary still runs far enough to say so), the bundle, the header, the
    # section table. Each is refused with NRV-E0719, never run.
    data = open(nerva_next, "rb").read()
    body = data.index(b"\x7fELF\x02\x01\x01\x00", 8)  # The past release's own ELF header.
    # The names the sections are found by, and the trailer: a changed byte there must not read as
    # "bundles none".
    places = [("linked tail", body - 100), ("bundle", body + 4096),
              ("header", data.index(b"nervapak")), ("section table", len(data) - 100),
              ("header section name", data.rindex(b".tb_mvh\x00") + 3),
              ("body section name", data.rindex(b".tb_mvb\x00") + 3),
              ("trailer", len(data) - 1), ("trailer start", len(data) - 16)]
    for name, offset in places:
        damaged = os.path.join(work, "damaged")
        changed = bytearray(data)
        changed[offset] ^= 1
        with open(damaged, "wb") as file:
            file.write(changed)
        os.chmod(damaged, 0o755)
        result = run([damaged, "version"])
        assert result.returncode == 1, (name, result.returncode, result.stdout, result.stderr)
        assert "NRV-E0719" in result.stderr, (name, result.stderr)

    # The refusals: nothing is written.
    base = (past["release"], past["release_client_min"], past["format"], past["commit"])
    cases = {
        "not lower": facts_text(next_["release"], base[1], base[2], base[3]),
        "format differs": facts_text(base[0], base[1], "0" * 63 + "1", base[3]),
        "clients refused": facts_text("0.0.1", "0.0.1", base[2], base[3]),
    }
    for name, text in cases.items():
        past_stub = os.path.join(work, "past_stub")
        output = os.path.join(work, "refused")
        stub(past_stub, text)
        result = run([nerva_pack, "--input", nerva_next, "--past", past_stub, "--output", output])
        assert result.returncode == 1, (name, result.returncode, result.stderr)
        assert "NRV-E0725" in result.stderr, (name, result.stderr)
        assert not os.path.exists(output), name

    # A file the packer cannot read in full (a `/sys` file's size is not its length), and one it
    # cannot write, are refused with a code, never with an error name.
    if os.path.exists("/sys/kernel/mm/transparent_hugepage/enabled"):
        result = run([nerva_pack, "--input", nerva_next,
                      "--past", "/sys/kernel/mm/transparent_hugepage/enabled",
                      "--output", os.path.join(work, "short")])
        assert result.returncode == 1 and "NRV-E0727" in result.stderr, result.stderr
    result = run([nerva_pack, "--input", nerva, "--past", past_stub_ok(work, base),
                  "--output", os.path.join(work, "no", "such", "directory", "nerva")])
    assert result.returncode == 1 and "NRV-E0810" in result.stderr, result.stderr
    assert "error." not in result.stderr, result.stderr

    # The size limit: written at exactly the size it takes, refused one byte under it.
    past_stub = os.path.join(work, "past_stub")
    stub(past_stub, facts_text("0.0.5", base[1], base[2], base[3]))
    packed = os.path.join(work, "packed")
    pack = [nerva_pack, "--input", nerva, "--past", past_stub, "--output", packed]
    result = run(pack)
    assert result.returncode == 0, result.stderr
    exact = os.path.getsize(packed)
    os.remove(packed)
    result = run(pack + ["--size-max", str(exact - 1)])
    assert result.returncode == 1 and "NRV-E0719" in result.stderr, result.stderr
    assert not os.path.exists(packed)
    result = run(pack + ["--size-max", str(exact)])
    assert result.returncode == 0 and os.path.getsize(packed) == exact, result.stderr
    print("bundle: ok")


if __name__ == "__main__":
    main()
