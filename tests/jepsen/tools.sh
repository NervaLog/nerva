#!/usr/bin/env bash
# Installs Leiningen 2.12.0 into tests/jepsen/.tools/ and prints the path of its script.
# Both files are checked against pinned SHA-256 sums (computed from the GitHub release), so a
# changed download fails instead of running. Needs curl and sha256sum; a JDK is separate.
#
#   lein=$(tests/jepsen/tools.sh)
#   LEIN_JAR=tests/jepsen/.tools/leiningen-standalone.jar "$lein" test
#
# run.sh calls this when `lein` is not on PATH and $LEIN is unset, and sets LEIN_JAR for it.
set -euo pipefail

version=2.12.0
script_sha256=f8e1266c0c78c08bd4af6e111889ecc316c9dd56d1e8645bbee6c1703d351bc3
jar_sha256=b721a573af631784f27ccb52e719e6d1287d9d3951ad56d316d38f7ecfa81aa2

here=$(cd "$(dirname "$0")" && pwd)
tools="$here/.tools"
mkdir -p "$tools"

# fetch <url> <file> <sha256>: downloads unless the file is already there and matches.
fetch() {
  local url=$1 file=$2 sum=$3
  if [[ -f "$file" ]] && echo "$sum  $file" | sha256sum -c - > /dev/null 2>&1; then
    return
  fi
  curl -fsSL --retry 3 -o "$file.part" "$url"
  echo "$sum  $file.part" | sha256sum -c - > /dev/null \
    || { rm -f "$file.part"; echo "tools.sh: $url does not match its pinned sha256" >&2; exit 1; }
  mv "$file.part" "$file"
}

fetch "https://raw.githubusercontent.com/technomancy/leiningen/$version/bin/lein" \
  "$tools/lein" "$script_sha256"
fetch "https://github.com/technomancy/leiningen/releases/download/$version/leiningen-$version-standalone.jar" \
  "$tools/leiningen-standalone.jar" "$jar_sha256"
chmod +x "$tools/lein"
echo "$tools/lein"
