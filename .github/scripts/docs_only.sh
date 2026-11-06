#!/usr/bin/env bash
# Reads a pull request's changed file names on stdin, one per line, and prints `true` when any of
# them can change what CI proves ("code") or `false` when every one is Markdown that no build or
# test reads. An empty list is `true` (fail closed). Amends N68.
#
# These Markdown files are read by a build step or a test, so they count as code:
#   docs/ERRORS.md  (unit tests: diagnostic, wire_code, http_connection)
#   UPSTREAM.md     (.github/scripts/sbom.py and test_sbom.py)
# Re-check with: grep -rn '\.md"' build.zig src .github/scripts perf ops
set -eu

reads_md='^(docs/ERRORS\.md|UPSTREAM\.md)$'
seen=0
while IFS= read -r file || [ -n "$file" ]; do
    [ -n "$file" ] || continue
    seen=1
    case "$file" in
    *.md) ;;
    *) echo true; exit 0 ;;
    esac
    if printf '%s\n' "$file" | grep -Eq "$reads_md"; then
        echo true
        exit 0
    fi
done
if [ "$seen" = 1 ]; then echo false; else echo true; fi
