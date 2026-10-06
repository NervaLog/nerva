#!/usr/bin/env python3
"""Gateways rotate keys without refusing anyone: NERVA_KEY_NEXT is accepted too.

Usage: keys.py <nerva>

Against one replica, `nerva api` and `nerva view` with NERVA_KEY alone refuse the next key; with
NERVA_KEY and NERVA_KEY_NEXT they take either (and refuse any other, or none); once NERVA_KEY is
the next key and NERVA_KEY_NEXT unset, the old key is refused. That is a rotation in three
restarts of each gateway, with no moment where a client holding either key is refused.
"""
import http.client
import os
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from api import Cluster  # noqa: E402

OLD, NEW = "key-old", "key-new"


def status(port, target, key):
    connection = http.client.HTTPConnection("127.0.0.1", port, timeout=60)
    try:
        headers = {} if key is None else {"X-Nerva-Key": key}
        connection.request("GET", target, headers=headers)
        response = connection.getresponse()
        response.read()
        return response.status
    finally:
        connection.close()


def gateway(cluster, command, key, key_next=None):
    env = {**os.environ, "NERVA_KEY": key}
    env.pop("NERVA_KEY_NEXT", None)
    if key_next is not None:
        env["NERVA_KEY_NEXT"] = key_next
    process = cluster.spawn([cluster.nerva, command, "--cluster=0",
                             f"--addresses={cluster.address}", "--listen=127.0.0.1:0"], env=env)
    return process, int(process.stdout.readline())


def main():
    cluster = Cluster(sys.argv[1])
    try:
        checked = 0
        for command, target in (("api", "/v1/tables/1"), ("view", "/v1/views")):
            steps = (
                ((OLD, None), {OLD: True, NEW: False}),
                ((OLD, NEW), {OLD: True, NEW: True}),
                ((NEW, None), {OLD: False, NEW: True}),
            )
            for (key, key_next), accepted in steps:
                process, port = gateway(cluster, command, key, key_next)
                for sent, ok in accepted.items():
                    got = status(port, target, sent)
                    assert (got != 401) == ok, (command, key, key_next, sent, got)
                    checked += 1
                for sent in ("key-other", "", None):
                    got = status(port, target, sent)
                    assert got == 401, (command, key, key_next, sent, got)
                    checked += 1
                process.kill()
                process.wait()
        print(f"keys: PASSED (api and view rotate from one key to another through NERVA_KEY_NEXT; "
              f"{checked} requests)")
    finally:
        cluster.close()


if __name__ == "__main__":
    main()
