#!/usr/bin/env python3
"""The placeholder keys the code refuses (#306) are the ones the env examples publish.

Usage: test_placeholder_keys.py   (from the repository root)

`peer_auth.placeholder_key` and `http_connection.placeholder_key` are refused at startup; the
examples under packaging/linux ship the same strings. If either side changes alone, an unedited
example would start a cluster on a known key again. A Zig test cannot embed the examples (they
are outside the package path), so this reads both.
"""
import re
import sys

CASES = (
    ("src/nerva/peer_auth.zig", "packaging/linux/replica.env.example", "NERVA_CLUSTER_KEY"),
    ("src/nerva/http_connection.zig", "packaging/linux/api.env.example", "NERVA_KEY"),
)


def main():
    for source, example, variable in CASES:
        code = re.search(r'pub const placeholder_key = "([^"]+)";', open(source).read())
        assert code, f"{source}: placeholder_key not found"
        lines = open(example).read().splitlines()
        found = [line.split("=", 1)[1] for line in lines if line.startswith(variable + "=")]
        assert found == [code.group(1)], (source, example, found, code.group(1))
    print("placeholder keys match the env examples")


if __name__ == "__main__":
    sys.exit(main())
