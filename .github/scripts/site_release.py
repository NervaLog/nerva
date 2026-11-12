#!/usr/bin/env python3
"""Adds a release to the site's data (docs/releases/automation.md, "release.yml"), in the checkout of
NervaLog/nervalog.github.io that the publish job edits:

    python3 -I .github/scripts/site_release.py <index.html> <version> <date> <site line>

<version> is VERSION's text (0.7.1, 0.7.1-rc.1, no v), <date> is YYYY-MM-DD, and <site line> is
`release_notes.sh site`'s output. It prepends `{v:"<V>", date:"<date>", d:"<site line>"}` to
`RELEASES` and sets `SITE.version`, `SITE.released` and `SITE.updated`. It does nothing, and exits 0,
if `RELEASES` already holds <V> (a re-run). It refuses with NRV-E1132, changing nothing, unless
`const SITE = {` and `const RELEASES = [` occur exactly once and `updated`, `version` and `released`
occur exactly once in SITE, each with a string value; or if an argument is not well formed."""
import os
import re
import sys
import tempfile

CODE = "NRV-E1132"


def refuse(headline, cause, fix):
    sys.stderr.write(f"error[{CODE}]: site_release.py: {headline}\n  cause  {cause}\n  fix    {fix}\n")
    sys.stderr.write(f"::error::{CODE} {headline}\n")
    sys.exit(1)


def check_arguments(version, date, line):
    if not re.fullmatch(r"[0-9]+\.[0-9]+\.[0-9]+(-[0-9A-Za-z.]+)?", version):
        refuse(f"'{version}' is not a version", "the version is VERSION's text, like 0.7.1 or 0.7.1-rc.1, with no v",
               "pass the tag without its v")
    if not re.fullmatch(r"[0-9]{4}-[0-9]{2}-[0-9]{2}", date):
        refuse(f"'{date}' is not a date", "the date is written YYYY-MM-DD", "pass the release's date")
    if not line.strip() or len(line) > 300 or '"' in line or "\\" in line or "\n" in line:
        refuse("the site line is empty, over 300 characters, or holds a quote, a backslash or a newline",
               "it is written into the site's script as a string", "pass the output of release_notes.sh site")


def block(text, opener, closer):
    """The text between the one `opener` and the first `closer` after it, with its start offset."""
    if text.count(opener) != 1:
        refuse(f"the site page has {text.count(opener)} of '{opener}', not one",
               "the page's data block was reshaped, and this script edits it by its shape",
               "edit the page by hand, and update this script and its test to the new shape")
    start = text.index(opener) + len(opener)
    end = text.find(closer, start)
    if end < 0:
        refuse(f"the block that '{opener}' opens has no end '{closer.strip()}'", "the page's data block was reshaped",
               "edit the page by hand, and update this script and its test to the new shape")
    return start, end


def edit(text, version, date, line):
    s_start, s_end = block(text, "const SITE = {", "\n};")
    r_start, r_end = block(text, "const RELEASES = [", "\n];")
    site = text[s_start:s_end]
    for key in ("updated", "version", "released"):
        found = re.findall(rf'(?m)^[ \t]*{key}:[ \t]*"[^"\n]*"', site)
        if len(found) != 1:
            refuse(f"SITE has {len(found)} string values for '{key}', not one",
                   "the page's data block was reshaped, and this script edits it by its shape",
                   "edit the page by hand, and update this script and its test to the new shape")
    if re.search(rf'(?m)^[ \t]*\{{[ \t]*v:[ \t]*"{re.escape(version)}"', text[r_start:r_end]):
        return None
    for key, value in (("updated", date), ("version", version), ("released", date)):
        site = re.sub(rf'(?m)^([ \t]*{key}:[ \t]*)"[^"\n]*"', lambda m: f'{m.group(1)}"{value}"', site)
    entry = f'\n  {{v:"{version}", date:"{date}", d:"{line}"}},'
    # The entry goes first in RELEASES, after the opener's line break.
    return text[:s_start] + site + text[s_end:r_start] + entry + text[r_start:]


def main(argv):
    if len(argv) != 5:
        sys.stderr.write("usage: site_release.py <index.html> <version> <date> <site line>\n")
        return 2
    path, version, date, line = argv[1:]
    check_arguments(version, date, line)
    with open(path, encoding="utf-8", newline="") as f:
        text = f.read()
    edited = edit(text, version, date, line)
    if edited is None:
        print(f"site_release.py: RELEASES already holds {version}; nothing to do")
        return 0
    directory = os.path.dirname(os.path.abspath(path))
    fd, tmp = tempfile.mkstemp(dir=directory, prefix=".site_release.")
    with os.fdopen(fd, "w", encoding="utf-8", newline="") as f:
        f.write(edited)
    os.chmod(tmp, os.stat(path).st_mode & 0o7777)
    os.replace(tmp, path)
    print(f"site_release.py: added {version} ({date}) to {path}")
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
