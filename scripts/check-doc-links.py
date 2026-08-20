#!/usr/bin/env python3
"""Check local Markdown links without fetching the network."""

from __future__ import annotations

import argparse
import posixpath
import re
import sys
import urllib.parse
from pathlib import Path


LINK = re.compile(r"!?\[[^\]]*\]\(([^)]+)\)")
SCHEMES = ("http://", "https://", "mailto:", "tel:", "data:")
PINNED_FILES = globals().get("HOSTWRIGHT_QUALIFICATION_FILES")
PINNED_ENTRIES = globals().get("HOSTWRIGHT_QUALIFICATION_ENTRIES")
if (PINNED_FILES is None) != (PINNED_ENTRIES is None):
    raise RuntimeError("incomplete qualification source snapshot")


def markdown_files(paths: list[Path]) -> list[Path]:
    if PINNED_FILES is not None:
        files: set[Path] = set()
        for path in paths:
            relative = path.as_posix().rstrip("/")
            for candidate in PINNED_FILES:
                if candidate == relative or candidate.startswith(relative + "/"):
                    selected = Path(candidate)
                    if selected.suffix.lower() in {".md", ".mdx"} and ".build" not in selected.parts:
                        files.add(selected)
        return sorted(files)
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
    if PINNED_ENTRIES is not None:
        candidate = posixpath.normpath(posixpath.join(base.as_posix(), decoded))
        if candidate == ".." or candidate.startswith("../"):
            return False
        if candidate in PINNED_ENTRIES or any(
            entry.startswith(candidate.rstrip("/") + "/") for entry in PINNED_ENTRIES
        ):
            return True
        if not posixpath.splitext(candidate)[1] and candidate + ".md" in PINNED_ENTRIES:
            return True
        return candidate.rstrip("/") + "/README.md" in PINNED_ENTRIES
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
        text = (
            PINNED_FILES[file.as_posix()].decode("utf-8")
            if PINNED_FILES is not None
            else file.read_text(encoding="utf-8")
        )
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
