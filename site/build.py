#!/usr/bin/env python3
"""Builds the project site that pages.yml publishes to GitHub Pages.

The site is public even though the repository is private, so it publishes only the pages listed
in PAGES, never a directory. Each page's Markdown is rendered by GitHub's own Markdown API (as the
repository shows it, no dependency to install); links between published pages stay on the site,
and every other link into the repository points at github.com, where only members can read it.

Run from anywhere: GITHUB_TOKEN=... python3 -I site/build.py <output directory>
"""
import html
import json
import os
import posixpath
import re
import shutil
import subprocess
import sys
import urllib.request
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
REPOSITORY = os.environ.get("GITHUB_REPOSITORY", "Botpike/nerva-ledger")
API = os.environ.get("GITHUB_API_URL", "https://api.github.com")

# (source, published as, title in the navigation). Everything the site publishes is here.
PAGES = [
    ("site/index.md", "index.html", "Home"),
    ("docs/TUTORIAL.md", "tutorial.html", "Tutorial"),
    ("docs/GOALS-1.0.md", "goals.html", "Goals and milestones"),
    ("README.md", "design.html", "Design and reference"),
    ("CHANGELOG.md", "changelog.html", "Changelog"),
]
STATIC = ["site/style.css"]
# A source Markdown file's limit, so a renderer call stays well inside the API's 400 KB.
SOURCE_BYTES_MAX = 256 * 1024

HREF = re.compile(r'(<a\b[^>]*?\bhref=")([^"]*)(")')


def fail(message):
    print(f"::error::{message}", file=sys.stderr)
    sys.exit(1)


def render_github(markdown):
    """Renders Markdown with GitHub's API, in the repository's context."""
    token = os.environ.get("GITHUB_TOKEN")
    if not token:
        fail("GITHUB_TOKEN is not set: the Markdown API needs it")
    request = urllib.request.Request(
        f"{API}/markdown",
        data=json.dumps({"text": markdown, "mode": "gfm", "context": REPOSITORY}).encode(),
        headers={"Authorization": f"Bearer {token}", "Accept": "application/vnd.github+json",
                 "X-GitHub-Api-Version": "2022-11-28"},
        method="POST")
    with urllib.request.urlopen(request, timeout=60) as response:
        return response.read().decode()


def milestones_in_goals(goals):
    """The numbers of the milestones docs/GOALS-1.0.md lists under "## Milestones"."""
    section = goals.split("\n## Milestones\n", 1)
    if len(section) != 2:
        fail("docs/GOALS-1.0.md has no '## Milestones' section")
    body = section[1].split("\n## ", 1)[0]
    return [int(n) for n in re.findall(r"^(\d+)\. (?:✅ )?\*\*", body, re.MULTILINE)]


def milestones_on_home(index):
    """The numbers of the milestones the home page's table lists."""
    return [int(n) for n in re.findall(r"^\| (\d+) \|", index, re.MULTILINE)]


def check_milestones():
    """The home page summarizes every milestone of the goals, so a new one cannot be missed."""
    goals = milestones_in_goals((ROOT / "docs/GOALS-1.0.md").read_text())
    home = milestones_on_home((ROOT / "site/index.md").read_text())
    if not goals:
        fail("docs/GOALS-1.0.md lists no milestones")
    if goals != home:
        fail(f"site/index.md lists milestones {home}, docs/GOALS-1.0.md lists {goals}: "
             "update the home page's milestone table")


def rewrite_href(href, source):
    """A link as the site serves it: on the site for a published page, else on github.com."""
    if not href or href.startswith(("#", "http://", "https://", "mailto:", "//")):
        return href
    path, hash_mark, fragment = href.partition("#")
    if not path:
        return href
    target = posixpath.normpath(posixpath.join(posixpath.dirname(source), path))
    if target.startswith("../") or target == "..":
        return href
    for page_source, published, _ in PAGES:
        if target == page_source:
            return published + hash_mark + fragment
    kind = "tree" if (ROOT / target).is_dir() else "blob"
    return f"https://github.com/{REPOSITORY}/{kind}/main/{target}{hash_mark}{fragment}"


def postprocess(rendered, source):
    """Makes the API's HTML work outside github.com: plain heading ids, links rewritten."""
    # github.com's own script maps #roadmap to id="user-content-roadmap"; a static page cannot.
    rendered = rendered.replace('id="user-content-', 'id="').replace('name="user-content-', 'name="')
    return HREF.sub(lambda m: m.group(1) + html.escape(
        rewrite_href(html.unescape(m.group(2)), source), quote=True) + m.group(3), rendered)


def page(title, body, published, version, commit):
    current = ' aria-current="page"'
    nav = "\n".join(f'<a href="{out}"{current if out == published else ""}>{html.escape(name)}</a>'
                    for _, out, name in PAGES)
    source = f"https://github.com/{REPOSITORY}"
    return f"""<!doctype html>
<html lang="en">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<title>{html.escape(title)} · Nerva</title>
<link rel="stylesheet" href="style.css">
</head>
<body>
<header class="site">
<a class="brand" href="index.html">Nerva</a>
<span class="version">v{html.escape(version)}</span>
<nav>{nav}</nav>
</header>
<main class="markdown-body">
{body}
</main>
<footer class="site">Built from <a href="{source}/commit/{commit}"><code>{commit[:12]}</code></a>.
Links into the repository need access to <a href="{source}">{REPOSITORY}</a>.</footer>
</body>
</html>
"""


def build(output, render, commit):
    check_milestones()
    version = (ROOT / "VERSION").read_text().strip()
    if not re.fullmatch(r"\d+\.\d+\.\d+", version):
        fail(f"VERSION is not a release number: {version!r}")
    # Never deletes: a mistyped output directory must not cost anyone their files.
    if output.exists() and any(output.iterdir()):
        fail(f"{output} is not empty")
    output.mkdir(parents=True, exist_ok=True)
    for source, published, title in PAGES:
        markdown = (ROOT / source).read_text()
        if len(markdown.encode()) > SOURCE_BYTES_MAX:
            fail(f"{source} is over {SOURCE_BYTES_MAX} bytes, the site's limit per page")
        markdown = markdown.replace("{{version}}", version)
        body = postprocess(render(markdown), source)
        (output / published).write_text(page(title, body, published, version, commit))
    for source in STATIC:
        shutil.copyfile(ROOT / source, output / Path(source).name)
    # Served as files, not through Jekyll.
    (output / ".nojekyll").write_text("")


def main():
    if len(sys.argv) != 2:
        fail("usage: build.py <output directory>")
    commit = os.environ.get("GITHUB_SHA") or subprocess.run(
        ["git", "-C", str(ROOT), "rev-parse", "HEAD"], capture_output=True, text=True,
        check=True).stdout.strip()
    build(Path(sys.argv[1]).resolve(), render_github, commit)


if __name__ == "__main__":
    main()
