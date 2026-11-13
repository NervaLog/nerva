#!/bin/sh
# The site's build gate (docs/releases/packages.md, "The site on a Cloudflare Worker"; P410).
#
# Workers Builds' build command, set in the Cloudflare dashboard, downloads this file from
# raw.githubusercontent.com at a pinned commit of NervaLog/nerva, checks its SHA-256 and runs it
# from the root of a checkout of NervaLog/nervalog.github.io. It refuses a tree that could change
# what Cloudflare runs, installs or binds (NRV-E1152), copies the named files into
# .nerva-site/dist/, and writes .nerva-site/wrangler.json, the only Wrangler configuration the
# deploy and preview commands read (they run inside .nerva-site/ and name it with --config): an
# assets-only Worker, with no `main` and no binding. It copies nothing else.
set -eu

out=.nerva-site
wkd_policy=.well-known/openpgpkey/policy
wkd_key=.well-known/openpgpkey/hu/ndqm47zydhyqyzabecddtdk1q3bponab

fail() {
    echo "error[NRV-E1152]: site build: $1; nothing is deployed" >&2
    echo "  cause  the site repository holds a file the build refuses, or the Worker's build variables changed" >&2
    echo "  fix    remove the file in a site pull request, or set SKIP_DEPENDENCY_INSTALL to 1 in the Worker's build variables, then rebuild" >&2
    exit 1
}

if [ "${SKIP_DEPENDENCY_INSTALL:-}" != 1 ]; then
    fail "SKIP_DEPENDENCY_INSTALL is not 1"
fi

# Names that make Cloudflare run code, install dependencies, bind resources or configure
# Wrangler or npm (a .env file sets Wrangler's own variables; .npmrc picks npm's registry).
# `.env*` and `.dev.vars*` are globs: when nothing matches, the pattern itself is tested.
for p in wrangler.toml wrangler.json wrangler.jsonc functions _worker.js _routes.json \
    package.json package-lock.json npm-shrinkwrap.json yarn.lock pnpm-lock.yaml \
    pnpm-workspace.yaml bun.lock bun.lockb bunfig.toml node_modules .npmrc .yarnrc .yarnrc.yml \
    requirements.txt Pipfile Pipfile.lock pyproject.toml poetry.lock uv.lock Gemfile \
    Gemfile.lock go.mod .tool-versions .nvmrc .node-version .python-version .ruby-version \
    runtime.txt .wrangler "$out" .env* .dev.vars*; do
    if [ -e "$p" ] || [ -L "$p" ]; then
        fail "$p is not allowed in the site repository"
    fi
done

for f in index.html 404.html _headers; do
    if [ -L "$f" ] || [ ! -f "$f" ]; then
        fail "$f is missing, not a regular file, or a symlink"
    fi
done

# The WKD files are a pair (P398): both, as regular files, or neither.
for f in .well-known .well-known/openpgpkey .well-known/openpgpkey/hu "$wkd_policy" "$wkd_key"; do
    if [ -L "$f" ]; then
        fail "$f is a symlink"
    fi
done
w=0
for f in "$wkd_policy" "$wkd_key"; do
    if [ -f "$f" ]; then
        w=$((w + 1))
    elif [ -e "$f" ]; then
        fail "$f is not a regular file"
    fi
done
if [ "$w" = 1 ]; then
    if [ -e .well-known/openpgpkey/hu ] && [ ! -d .well-known/openpgpkey/hu ]; then
        fail ".well-known/openpgpkey/hu is not a directory"
    fi
    fail "one WKD file is present without the other; both or neither"
fi

mkdir -p "$out/dist"
for f in index.html 404.html _headers; do
    cp "$f" "$out/dist/$f"
done
if [ "$w" = 2 ]; then
    mkdir -p "$out/dist/.well-known/openpgpkey/hu"
    cp "$wkd_policy" "$out/dist/$wkd_policy"
    cp "$wkd_key" "$out/dist/$wkd_key"
fi

# The Worker: static assets only. No `main` (no script runs), no binding of any kind, no route
# (the custom domain is set in the dashboard, which a deploy without routes leaves alone).
# `previews` is required by `wrangler preview`, and empty: a Preview has no binding either.
cat > "$out/wrangler.json" <<'EOF'
{
  "name": "nerva-site",
  "compatibility_date": "2026-10-23",
  "workers_dev": true,
  "preview_urls": true,
  "assets": {
    "directory": "dist",
    "not_found_handling": "404-page",
    "html_handling": "auto-trailing-slash"
  },
  "previews": {}
}
EOF

echo "site build: copied $((3 + w)) files to $out/dist and wrote $out/wrangler.json"
