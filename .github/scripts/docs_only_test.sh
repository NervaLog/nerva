#!/usr/bin/env bash
# Table test for docs_only.sh.
set -eu
here=$(cd "$(dirname "$0")" && pwd)
fail=0
check() {
    want=$1; shift
    got=$(printf '%s' "$1" | "$here/docs_only.sh")
    if [ "$got" != "$want" ]; then
        echo "docs_only_test: want $want, got $got for: $1" >&2
        fail=1
    fi
}
check true ''
check true $'\n'
check false 'README.md'
check false $'README.md\ndocs/decisions/P1-x.md\nworklog/1.md\n'
check false 'docs/briefs/r5.md'
check true 'docs/ERRORS.md'
check true $'README.md\nUPSTREAM.md'
check true 'src/nerva.zig'
check true $'README.md\nsrc/nerva.zig'
check true '.github/workflows/ci.yml'
check true 'notes.md.zig'
check true 'VERSION'
check true 'docs/a.markdown'
check true 'docs/img.png'
[ "$fail" = 0 ] && echo "docs_only_test: ok"
exit "$fail"
