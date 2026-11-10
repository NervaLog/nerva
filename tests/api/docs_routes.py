#!/usr/bin/env python3
"""docs/API.md names exactly the routes `nerva api` serves.

Usage: docs_routes.py <nerva>   (the binary is not used: the gateway lists no routes at run time,
so they are read from its source; the argument only keeps the runner's calling convention)

The gateway's routes are the `routes` table in src/nerva/api/api.zig, the prefix and suffix
constants beside it, `/healthz` in src/nerva/api/server.zig, and the `Route` enum. This test
derives every `METHOD /path` from them and compares it with the headings of docs/API.md, which
are written ### `METHOD /path` with `<name>` for a path's variable part. A route the source
serves and the page lacks fails; so does a heading for a route that does not exist. A `Route`
member this test has no mapping for fails too, so a new route cannot be added without a decision
here and a section in the page. The methods of the prefix routes (tables, views, ledgers,
indexes) are fixed in this file: they are not in a table the source exposes. `nerva view`'s own
routes (the header of src/nerva/view/server.zig) must be among the page's too.
"""
import os
import re
import sys

ROOT = os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))


def read(path):
    with open(os.path.join(ROOT, path), encoding="utf-8") as f:
        return f.read()


def constant(source, name):
    match = re.search(r'pub const %s = "([^"]*)";' % name, source)
    assert match, "api.zig has no constant %s" % name
    return match.group(1)


def served(api, server):
    """The set of `METHOD /path` the gateway serves, and the Route members it maps."""
    found = set()
    for path, route, method in re.findall(
        r'\.path = "([^"]+)", \.route = \.(\w+), \.method = \.(\w+)', api
    ):
        found.add("%s %s" % (method.upper(), path))
    assert len(found) >= 8, "the routes table was not found in api.zig"
    assert re.search(r'request\.method == \.get and std\.mem\.eql\(u8, target, "/healthz"\)', server)
    found.add("GET /healthz")

    tables = constant(api, "tables_prefix") + "<table>"
    views = constant(api, "views_prefix")
    ledgers = constant(api, "ledgers_prefix") + "<id>"
    indexes = constant(api, "indexes_prefix")
    groups = constant(api, "views_groups_suffix")
    definition = constant(api, "views_definition_suffix")
    scan = constant(api, "index_scan_suffix")
    by_route = {
        "tables": ["GET " + tables, "PUT " + tables],
        "views": ["GET %s<name>" % views, "PUT %s<name>" % views],
        "view_groups": ["GET %s<name>%s" % (views, groups)],
        "view_definition": ["GET %s<name>%s" % (views, definition)],
        "view_list": ["GET " + views.rstrip("/")],
        "ledgers": ["GET " + ledgers, "PUT " + ledgers],
        "index_list": ["GET " + indexes.rstrip("/")],
        "indexes": ["GET %s<name>" % indexes, "PUT %s<name>" % indexes],
        "index_scan": ["POST %s<name>%s" % (indexes, scan)],
    }
    members = re.search(r"pub const Route = enum \{(.*?)\n\};", api, re.S).group(1)
    members = re.findall(r"^\s+(\w+),", members, re.M)
    in_table = {route for _, route, _ in re.findall(
        r'\.path = "([^"]+)", \.route = \.(\w+), \.method = \.(\w+)', api)}
    for member in members:
        if member in in_table:
            continue
        assert member in by_route, (
            "Route.%s has no mapping in docs_routes.py: add it, and a section to docs/API.md"
            % member)
        found.update(by_route[member])
    return found


def view_routes(view):
    found = set()
    header = [line for line in view.splitlines() if line.startswith("//!")][:8]
    for line in header:
        match = re.match(r"//!\s+(GET) (/\S+)", line)
        if match:
            found.add("%s %s" % (match.group(1), re.sub(r"\?.*", "", match.group(2))))
    assert found, "the route list in view/server.zig's header was not found"
    return found


def documented(page):
    found = set()
    for method, path in re.findall(r"^#{2,4} `([A-Z]+) (/\S*)`", page, re.M):
        found.add("%s %s" % (method, path))
    return found


def normal(routes):
    return {re.sub(r"<[^>]*>", "<>", route) for route in routes}


def main():
    api = read("src/nerva/api/api.zig")
    server = read("src/nerva/api/server.zig")
    view = read("src/nerva/view/server.zig")
    page = documented(read("docs/API.md"))
    want = served(api, server)
    have = normal(page)
    failures = []
    for route in sorted(normal(want) - have):
        failures.append("docs/API.md has no section for %s, which the gateway serves" % route)
    for route in sorted(have - normal(want)):
        failures.append("docs/API.md has a section for %s, which the gateway does not serve" % route)
    for route in sorted(normal(view_routes(view)) - have):
        failures.append("docs/API.md has no section for %s, which nerva view serves" % route)
    if failures:
        print("\n".join(failures))
        sys.exit(1)
    print("docs_routes: %d routes, all in docs/API.md" % len(have))


if __name__ == "__main__":
    main()
