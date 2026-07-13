#!/usr/bin/env python3
"""Verify that internal links in a statically built site resolve."""

from __future__ import annotations

import argparse
import sys
import urllib.parse
from html.parser import HTMLParser
from pathlib import Path


class LinkParser(HTMLParser):
    def __init__(self) -> None:
        super().__init__()
        self.links: list[str] = []

    def handle_starttag(self, tag: str, attrs: list[tuple[str, str | None]]) -> None:
        attribute = "href" if tag in {"a", "link"} else "src" if tag in {"img", "script", "source"} else None
        if attribute is None:
            return
        for name, value in attrs:
            if name == attribute and value:
                self.links.append(value)


def resolves(root: Path, page: Path, raw: str) -> bool:
    if raw.startswith(("#", "http://", "https://", "mailto:", "tel:", "data:", "javascript:", "//")):
        return True
    path = urllib.parse.unquote(urllib.parse.urlsplit(raw).path)
    if not path:
        return True
    candidate = root / path.lstrip("/") if path.startswith("/") else page.parent / path
    candidates = [candidate]
    if path.endswith("/") or candidate.is_dir():
        candidates.append(candidate / "index.html")
    if not candidate.suffix:
        candidates.extend([candidate.with_suffix(".html"), candidate / "index.html"])
    return any(item.exists() for item in candidates)


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("site_root", type=Path)
    arguments = parser.parse_args()
    root = arguments.site_root.resolve()
    failures: list[str] = []
    checked = 0
    for page in sorted(root.rglob("*.html")):
        parser_instance = LinkParser()
        parser_instance.feed(page.read_text(encoding="utf-8", errors="replace"))
        for link in parser_instance.links:
            checked += 1
            if not resolves(root, page, link):
                failures.append(f"{page.relative_to(root)}: missing internal target {link}")
    if failures:
        print("\n".join(failures), file=sys.stderr)
        return 1
    print(f"built-site links: checked {checked} references")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
