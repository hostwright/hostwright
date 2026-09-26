#!/usr/bin/env python3
"""Check out the exact source revisions used to build the static Swift SDK."""

import argparse
import json
import re
import subprocess
from pathlib import Path, PurePosixPath


def run(arguments, *, text=True):
    return subprocess.check_output(arguments, text=text, stderr=subprocess.STDOUT)


def materialize(root, catalog):
    if not root.is_absolute() or root.exists() or root.is_symlink():
        raise ValueError("Swift source root must be a new absolute directory")
    if not isinstance(catalog, list) or not catalog:
        raise ValueError("Swift source lock must be a nonempty array")
    root.mkdir(mode=0o700, parents=True)
    rows = []
    destinations = set()
    identities = set()
    for item in catalog:
        if not isinstance(item, dict) or set(item) != {"destination", "repository", "commit"}:
            raise ValueError("invalid Swift source lock entry")
        destination = item["destination"]
        repository = item["repository"]
        commit = item["commit"]
        relative = PurePosixPath(destination)
        identity = "swift-sdk/" + destination
        if (not destination or relative.is_absolute() or ".." in relative.parts
                or destination in destinations or identity in identities
                or not isinstance(repository, str) or not repository.startswith("https://")
                or not re.fullmatch(r"[a-f0-9]{40}", commit)):
            raise ValueError("unsafe or duplicate Swift source lock entry")
        destinations.add(destination)
        identities.add(identity)
        checkout = root.joinpath(*relative.parts)
        checkout.parent.mkdir(mode=0o700, parents=True, exist_ok=True)
        run(["git", "clone", "--filter=blob:none", "--no-checkout", "--", repository, str(checkout)])
        run(["git", "-C", str(checkout), "-c", "core.hooksPath=/dev/null", "checkout", "--detach", commit])
        observed = run(["git", "-C", str(checkout), "rev-parse", "HEAD"]).strip()
        tree = run(["git", "-C", str(checkout), "rev-parse", "HEAD^{tree}"]).strip()
        origin = run(["git", "-C", str(checkout), "remote", "get-url", "origin"]).strip()
        status = run(["git", "-C", str(checkout), "status", "--porcelain=v1", "--untracked-files=all"])
        if observed != commit or origin != repository or status:
            raise ValueError("materialized Swift source differs from its lock: " + destination)
        rows.append(dict(identity=identity, destination=destination, repository=repository,
                         commit=commit, tree=tree))
    result = dict(kind="hostwright.swift-sdk-source-lock.v1", projects=rows)
    (root / "source-revisions.json").write_text(json.dumps(result, sort_keys=True, separators=(",", ":")) + "\n")
    return result


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--root", type=Path, required=True)
    parser.add_argument("--catalog", type=Path, default=Path(__file__).with_name("runtime-swift-sources.json"))
    arguments = parser.parse_args()
    catalog = json.loads(arguments.catalog.read_text(encoding="utf-8"))
    materialize(arguments.root, catalog)


if __name__ == "__main__":
    main()
