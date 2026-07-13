#!/usr/bin/env python3
"""Render/check the human-readable v0.0.2 workstream index from issues.json."""

from __future__ import annotations

import argparse
import json
import sys
from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]
MANIFEST = ROOT / "docs/roadmap/v0.0.2/issues.json"
OUTPUT = ROOT / "docs/roadmap/v0.0.2/WORKSTREAM_INDEX.md"


def render() -> str:
    document = json.loads(MANIFEST.read_text(encoding="utf-8"))
    issues = document["issues"]
    master = next(issue for issue in issues if issue["kind"] == "master")
    epics = sorted((issue for issue in issues if issue["kind"] == "epic"), key=lambda issue: issue["phase"])
    lines = [
        "# v0.0.2 Workstream Index",
        "",
        "> Generated deterministically from `issues.json` by `scripts/render-roadmap-index.py`. Edit GitHub/`issues.json`, then regenerate; do not hand-edit this file.",
        "",
        f"Master: [#{master['number']}]({master['url']}) — {master['title']}",
        "",
        f"Ledger: {document['counts']['epics']} phase epics, {document['counts']['workstreams']} child workstreams, {document['counts']['total']} total roadmap issues.",
        "",
    ]
    for epic in epics:
        phase = epic["phase"]
        lines.extend([
            f"## {epic['title']}",
            "",
            f"Epic: [#{epic['number']}]({epic['url']})",
            "",
            "| Marker | Issue | Workstream |",
            "| --- | ---: | --- |",
        ])
        children = sorted(
            (issue for issue in issues if issue["kind"] == "workstream" and issue["phase"] == phase),
            key=lambda issue: issue["child"],
        )
        for child in children:
            title = child["title"].split(": ", 1)[-1].replace("|", "\\|")
            lines.append(f"| `{child['marker']}` | [#{child['number']}]({child['url']}) | {title} |")
        lines.append("")
    return "\n".join(lines).rstrip() + "\n"


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("command", choices=["write", "check"])
    arguments = parser.parse_args()
    expected = render()
    if arguments.command == "write":
        OUTPUT.write_text(expected, encoding="utf-8")
        print(f"roadmap index: wrote {OUTPUT.relative_to(ROOT)}")
        return 0
    actual = OUTPUT.read_text(encoding="utf-8") if OUTPUT.exists() else ""
    if actual != expected:
        print("roadmap index is stale; run scripts/render-roadmap-index.py write", file=sys.stderr)
        return 1
    print("roadmap index: generated workstream document agrees with issues.json")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
