#!/usr/bin/env python3
"""Tests for build.py, without the network. Run from the repository root:
python3 site/test_build.py"""
import contextlib
import importlib.util
import io
import re
import tempfile
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
spec = importlib.util.spec_from_file_location("build", ROOT / "site/build.py")
build = importlib.util.module_from_spec(spec)
spec.loader.exec_module(build)


def refused(test, call):
    """Asserts that `call` exits with an error, without printing it."""
    with contextlib.redirect_stderr(io.StringIO()) as stderr:
        with test.assertRaises(SystemExit):
            call()
    test.assertIn("::error::", stderr.getvalue())


def fake_render(markdown):
    """Stands in for GitHub's API: headings as it renders them, links as plain anchors."""
    out = []
    for line in markdown.splitlines():
        heading = re.match(r"(#+) (.*)", line)
        if heading:
            slug = re.sub(r"[^a-z0-9 -]", "", heading.group(2).lower()).replace(" ", "-")
            out.append(f'<div class="markdown-heading"><h1>{heading.group(2)}</h1>'
                       f'<a id="user-content-{slug}" class="anchor" href="#{slug}"></a></div>')
        out.extend(f'<a href="{href}">{text}</a>'
                   for text, href in re.findall(r"\[([^\]]*)\]\(([^)]*)\)", line))
    return "\n".join(out)


class RewriteHref(unittest.TestCase):
    def test_published_pages_stay_on_the_site(self):
        self.assertEqual(build.rewrite_href("./docs/TUTORIAL.md#part-1", "README.md"),
                         "tutorial.html#part-1")
        self.assertEqual(build.rewrite_href("../README.md", "docs/TUTORIAL.md"), "design.html")
        self.assertEqual(build.rewrite_href("GOALS-1.0.md", "docs/TUTORIAL.md"), "goals.html")

    def test_other_files_link_to_the_repository(self):
        self.assertEqual(build.rewrite_href("./docs/DECISIONS.md#n52", "README.md"),
                         "https://github.com/Botpike/nerva-ledger/blob/main/docs/DECISIONS.md#n52")
        self.assertEqual(build.rewrite_href("../src/nerva", "docs/TUTORIAL.md"),
                         "https://github.com/Botpike/nerva-ledger/tree/main/src/nerva")

    def test_anchors_and_absolute_links_are_kept(self):
        for href in ["#roadmap", "https://example.com/a.md", "mailto:a@example.com", ""]:
            self.assertEqual(build.rewrite_href(href, "README.md"), href)

    def test_a_link_outside_the_repository_is_kept(self):
        self.assertEqual(build.rewrite_href("../../x.md", "docs/TUTORIAL.md"), "../../x.md")


class Postprocess(unittest.TestCase):
    def test_heading_ids_lose_githubs_prefix(self):
        rendered = build.postprocess('<a id="user-content-roadmap" href="#roadmap"></a>', "README.md")
        self.assertEqual(rendered, '<a id="roadmap" href="#roadmap"></a>')

    def test_links_are_rewritten_and_escaped(self):
        rendered = build.postprocess(
            '<a href="./CHANGELOG.md">c</a> <a class="x" href="docs/design/a&amp;b.md">d</a>',
            "README.md")
        self.assertIn('href="changelog.html"', rendered)
        self.assertIn('href="https://github.com/Botpike/nerva-ledger/blob/main/docs/design/a&amp;b.md"',
                      rendered)


class Milestones(unittest.TestCase):
    def test_the_home_page_lists_every_milestone_of_the_goals(self):
        build.check_milestones()

    def test_goals_milestones_are_read_from_their_section(self):
        goals = "# G\n\n1. **Not one.**\n\n## Milestones\n\n1. **A.** x\n   - 1a\n2. ✅ **B.**\n\n## After\n\n3. **C.**\n"
        self.assertEqual(build.milestones_in_goals(goals), [1, 2])

    def test_goals_without_milestones_are_refused(self):
        refused(self, lambda: build.milestones_in_goals("# G\n"))

    def test_home_table_rows_are_read(self):
        self.assertEqual(build.milestones_on_home("| # | M |\n|---|---|\n| 1 | a |\n| 2 | b |\n"), [1, 2])


class Build(unittest.TestCase):
    def test_publishes_exactly_the_listed_pages(self):
        with tempfile.TemporaryDirectory() as directory:
            output = Path(directory) / "site"
            build.build(output, fake_render, "0" * 40)
            published = sorted(p.name for p in output.iterdir())
            expected = sorted([out for _, out, _ in build.PAGES] + ["style.css", ".nojekyll"])
            self.assertEqual(published, expected)
            home = (output / "index.html").read_text()
            version = (ROOT / "VERSION").read_text().strip()
            self.assertIn(f"v{version}", home)
            self.assertNotIn("{{version}}", home)
            self.assertIn('href="tutorial.html#part-0-the-idea-in-five-minutes"', home)
            self.assertIn('<a href="index.html" aria-current="page">Home</a>', home)
            for _, out, _ in build.PAGES:
                text = (output / out).read_text()
                self.assertNotIn('id="user-content-', text)
                self.assertIsNone(re.search(r'href="(?!https?:|#|mailto:)[^"]*\.md', text), out)

    def test_every_site_anchor_exists(self):
        with tempfile.TemporaryDirectory() as directory:
            output = Path(directory) / "site"
            build.build(output, fake_render, "0" * 40)
            ids = {out: set(re.findall(r'id="([^"]+)"', (output / out).read_text()))
                   for _, out, _ in build.PAGES}
            home = (output / "index.html").read_text()
            for page, anchor in re.findall(r'href="([a-z0-9-]+\.html)#([^"]+)"', home):
                self.assertIn(anchor, ids[page], f"{page}#{anchor}")

    def test_never_writes_into_a_directory_with_files(self):
        with tempfile.TemporaryDirectory() as directory:
            (Path(directory) / "keep").write_text("mine")
            refused(self, lambda: build.build(Path(directory), fake_render, "0" * 40))
            self.assertEqual((Path(directory) / "keep").read_text(), "mine")


if __name__ == "__main__":
    unittest.main()
