#!/usr/bin/env python3
"""Check that hostwright.dev presents the same v0.0.2 contract truth."""

from __future__ import annotations

import argparse
import sys
from pathlib import Path


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("site_root", type=Path)
    arguments = parser.parse_args()
    root = arguments.site_root
    required = {
        "docs/src/content/docs/index.mdx": ["0.0.2-dev", "v0.0.2", "not production ready"],
        "docs/src/content/docs/reference/manifest.mdx": ["version: 2", "migrate preview"],
        "docs/src/content/docs/reference/compatibility.mdx": ["0.0.2-dev", "v0.0.2"],
        "docs/src/content/docs/reference/limitations.mdx": ["v0.0.2", "15 phases"],
        "docs/src/content/docs/getting-started/install-from-source.mdx": ["0.0.2-dev", "brew install hostwright", "does not exist"],
        "docs/src/content/docs/roadmap/index.mdx": ["v0.0.2", "15", "167", "2026-07-13", "2026-07-27"],
    }
    errors: list[str] = []
    for relative, fragments in required.items():
        path = root / relative
        if not path.is_file():
            errors.append(f"missing website contract file: {relative}")
            continue
        content = path.read_text(encoding="utf-8")
        for fragment in fragments:
            if fragment.lower() not in content.lower():
                errors.append(f"{relative} lacks contract fragment: {fragment}")
    if errors:
        print("\n".join(errors), file=sys.stderr)
        return 1
    print("website contract: v0.0.2 version, install, manifest, limitation, and roadmap truth agree")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
