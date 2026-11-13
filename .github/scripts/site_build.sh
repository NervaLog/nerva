#!/bin/sh
# The site's build gate (packages.md, "The site on Cloudflare Pages"; NRV-E1152).
# Cloudflare's build command downloads this file at a pinned commit, checks its SHA-256 and
# runs it from the root of NervaLog/nervalog.github.io. It refuses a tree that could change what
# Pages runs or binds, then copies the three named files into an empty dist/.
set -eu

fail() {
    echo "error[NRV-E1152]: site build: $1; nothing is deployed" >&2
    exit 1
}

if [ "${SKIP_DEPENDENCY_INSTALL:-}" != 1 ]; then
    fail "SKIP_DEPENDENCY_INSTALL is not 1"
fi
for p in wrangler.toml wrangler.json wrangler.jsonc functions _worker.js _routes.json package.json package-lock.json npm-shrinkwrap.json yarn.lock pnpm-lock.yaml bun.lock bun.lockb requirements.txt Pipfile Pipfile.lock pyproject.toml poetry.lock Gemfile Gemfile.lock .tool-versions .nvmrc .node-version .python-version .ruby-version runtime.txt; do
    if [ -e "$p" ] || [ -L "$p" ]; then
        fail "$p is not allowed in the site repository"
    fi
done
rm -rf dist
mkdir -p dist/.well-known/openpgpkey/hu
for f in index.html .well-known/openpgpkey/policy .well-known/openpgpkey/hu/ndqm47zydhyqyzabecddtdk1q3bponab; do
    if [ -L "$f" ] || [ ! -f "$f" ]; then
        fail "$f is missing or is a symlink"
    fi
    cp "$f" "dist/$f"
done
