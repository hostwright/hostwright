#!/usr/bin/env python3
"""Check local Markdown links without fetching the network."""

from __future__ import annotations

import argparse
import re
import sys
import urllib.parse
from pathlib import Path


LINK = re.compile(r"!?\[[^\]]*\]\(([^)]+)\)")
SCHEMES = ("http://", "https://", "mailto:", "tel:", "data:")


def markdown_files(paths: list[Path]) -> list[Path]:
    files: list[Path] = []
    for path in paths:
        if path.is_dir():
            files.extend(candidate for candidate in path.rglob("*.md") if ".build" not in candidate.parts)
        elif path.suffix.lower() in {".md", ".mdx"}:
            files.append(path)
    return sorted(set(files))


def target_path(raw: str) -> str:
    raw = raw.strip()
    if raw.startswith("<") and ">" in raw:
        return raw[1 : raw.index(">")]
    return raw.split(maxsplit=1)[0]


def exists(base: Path, target: str) -> bool:
    decoded = urllib.parse.unquote(target.split("#", 1)[0].split("?", 1)[0])
    if not decoded or decoded.startswith("/") or decoded.startswith(SCHEMES) or decoded.startswith("//"):
        return True
    candidate = (base / decoded).resolve()
    if candidate.exists():
        return True
    if not candidate.suffix and candidate.with_suffix(".md").exists():
        return True
    if candidate.is_dir() and (candidate / "README.md").exists():
        return True
    return False


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("paths", nargs="+", type=Path)
    arguments = parser.parse_args()
    failures: list[str] = []
    checked = 0
    for file in markdown_files(arguments.paths):
        text = file.read_text(encoding="utf-8")
        for line_number, line in enumerate(text.splitlines(), start=1):
            for match in LINK.finditer(line):
                target = target_path(match.group(1))
                checked += 1
                if not exists(file.parent, target):
                    failures.append(f"{file}:{line_number}: missing local link target {target}")
    if failures:
        print("\n".join(failures), file=sys.stderr)
        return 1
    print(f"documentation links: checked {checked} local/external references")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
