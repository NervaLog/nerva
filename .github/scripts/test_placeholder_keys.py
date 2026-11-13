#!/usr/bin/env python3
"""The env examples publish no key, and the placeholders the code refuses stay refused (#306, #373).

Usage: test_placeholder_keys.py   (from the repository root)

The examples under packaging/linux leave `NERVA_CLUSTER_KEY=` and `NERVA_KEY=` empty (#383), so an
unedited copy is refused as missing. `peer_auth.placeholder_key` and
`http_connection.placeholder_key` stay refused for files copied from an older release, which
published them. If an example ships a value again, it must not be one that starts on a known key.
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
        assert found == [""], (example, "must leave", variable, "empty", found)
    print("env examples leave the keys empty; placeholders stay refused in code")


if __name__ == "__main__":
    sys.exit(main())
