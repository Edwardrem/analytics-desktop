#!/usr/bin/env python3
"""Check the static site before a commit.

Usage: python3 site/check.py            (checks the folder this file is in)

For every .html page it checks:
- a non-empty <title>, a non-empty meta description and a meta viewport tag;
- the trademark line in the footer;
- every internal href / src points to a file that exists, and every #fragment to an id on that page.
External links (http, https, mailto) are not fetched. Standard library only. Exits 1 on any problem.
"""
import os
import sys
from html.parser import HTMLParser
from urllib.parse import urlsplit, unquote

ROOT = os.path.dirname(os.path.abspath(__file__))
LEGAL = "Analytics Desktop is not affiliated with or endorsed by Microsoft. Power BI is a trademark of Microsoft."
LINK_ATTRS = {"a": "href", "link": "href", "script": "src", "img": "src", "source": "src"}


class Page(HTMLParser):
    def __init__(self):
        super().__init__(convert_charrefs=True)
        self.title = ""
        self.in_title = False
        self.description = None
        self.viewport = None
        self.links = []   # (url, line)
        self.ids = set()
        self.text = []

    def handle_starttag(self, tag, attrs):
        a = dict(attrs)
        if "id" in a and a["id"]:
            self.ids.add(a["id"])
        if tag == "a" and a.get("name"):
            self.ids.add(a["name"])
        if tag == "title":
            self.in_title = True
        if tag == "meta":
            name = (a.get("name") or "").lower()
            if name == "description":
                self.description = (a.get("content") or "").strip()
            elif name == "viewport":
                self.viewport = (a.get("content") or "").strip()
        attr = LINK_ATTRS.get(tag)
        if attr and a.get(attr):
            self.links.append((a[attr], self.getpos()[0]))

    def handle_startendtag(self, tag, attrs):
        self.handle_starttag(tag, attrs)

    def handle_endtag(self, tag):
        if tag == "title":
            self.in_title = False

    def handle_data(self, data):
        if self.in_title:
            self.title += data
        self.text.append(data)


def parse(path):
    p = Page()
    with open(path, encoding="utf-8") as f:
        p.feed(f.read())
    return p


def main():
    pages = {}
    for d, dirs, files in os.walk(ROOT):
        dirs[:] = [x for x in dirs if not x.startswith(".")]
        for name in files:
            if name.endswith(".html"):
                path = os.path.join(d, name)
                pages[os.path.normpath(path)] = parse(path)

    problems = []
    for path, page in sorted(pages.items()):
        rel = os.path.relpath(path, ROOT)
        if not page.title.strip():
            problems.append(f"{rel}: missing or empty <title>")
        if not page.description:
            problems.append(f"{rel}: missing or empty meta description")
        if not page.viewport or "width=device-width" not in page.viewport:
            problems.append(f"{rel}: missing meta viewport with width=device-width")
        if LEGAL not in " ".join(" ".join(page.text).split()):
            problems.append(f"{rel}: footer is missing the trademark line")
        for url, line in page.links:
            parts = urlsplit(url)
            if parts.scheme or parts.netloc:
                if parts.scheme not in ("http", "https", "mailto"):
                    problems.append(f"{rel}:{line}: unexpected link scheme in {url!r}")
                continue
            if url.startswith("/"):
                problems.append(f"{rel}:{line}: absolute path {url!r} breaks under /analytics-desktop/; use a relative link")
                continue
            target = path if not parts.path else os.path.normpath(os.path.join(os.path.dirname(path), unquote(parts.path)))
            if os.path.isdir(target):
                target = os.path.join(target, "index.html")
            if not os.path.isfile(target):
                problems.append(f"{rel}:{line}: broken link {url!r}")
                continue
            if parts.fragment:
                other = pages.get(os.path.normpath(target))
                if other is not None and parts.fragment not in other.ids:
                    problems.append(f"{rel}:{line}: no id {parts.fragment!r} in {os.path.relpath(target, ROOT)}")

    for p in problems:
        print(p)
    print(f"Checked {len(pages)} pages: " + ("OK" if not problems else f"{len(problems)} problem(s)"))
    return 1 if problems else 0


if __name__ == "__main__":
    sys.exit(main())
