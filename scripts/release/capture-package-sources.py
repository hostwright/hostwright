#!/usr/bin/env python3
"""Capture locked Swift package checkouts and every initialized Git submodule."""

import argparse
import hashlib
import importlib.util
import os
from pathlib import Path
import re
import tempfile


SPEC = importlib.util.spec_from_file_location(
    "source_capture", Path(__file__).with_name("capture-runtime-source.py")
)
SOURCE = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(SOURCE)
V = SOURCE.VERIFIER


def capture_packages(lockfile, checkouts, output):
    lock_data = lockfile.read_bytes()
    lock = V.parse(lock_data)
    V.require(lock.get("version") == 3 and isinstance(lock.get("pins"), list) and lock["pins"],
              "expected a version 3 Swift package lockfile")
    V.require(checkouts.is_dir() and not checkouts.is_symlink(), "unsafe package checkout directory")
    V.require(output.is_absolute() and output.parent.is_dir() and not output.exists() and not output.is_symlink(),
              "package source output must be a new absolute path")
    identities = set()
    projects = []
    with tempfile.TemporaryDirectory(prefix=".package-sources-", dir=output.parent) as temporary:
        staging = Path(temporary) / "capture"
        staging.mkdir(mode=0o700)

        def capture(repository, identity, commit, depth=0):
            V.require(depth <= 32 and len(identities) < V.MAX_FILES, "excessive source submodule graph")
            V.require(identity not in identities, "duplicate package source identity")
            identities.add(identity)
            V.require(not repository.is_symlink() and repository.is_dir(), "missing initialized source checkout")
            actual_root = SOURCE.git(repository, "rev-parse", "--show-toplevel").decode().strip()
            V.require(Path(actual_root).resolve() == repository.resolve(), "submodule is not initialized")
            actual_commit = SOURCE.git(repository, "rev-parse", "HEAD").decode().strip()
            V.require(actual_commit == commit, "package checkout differs from its pinned commit")
            V.require(not SOURCE.git(repository, "status", "--porcelain=v1", "--untracked-files=all"),
                      "package source checkout is dirty")
            submodules = {}
            for row in SOURCE.git(repository, "ls-tree", "-r", "-z", commit).split(b"\0"):
                if not row:
                    continue
                metadata, raw_name = row.split(b"\t", 1)
                mode, kind, oid = metadata.decode().split()
                if mode != "160000":
                    continue
                V.require(kind == "commit", "invalid source submodule object")
                name = V.path(raw_name.decode())
                child = repository.joinpath(*name.split("/"))
                V.require(repository.resolve() in child.resolve().parents, "source submodule escapes checkout")
                child_identity = identity + "-submodule-" + hashlib.sha256(name.encode()).hexdigest()[:16]
                submodules[name] = child_identity
                capture(child, child_identity, oid, depth + 1)
            source = SOURCE.capture(repository, commit, staging / identity, submodules)
            projects.append(dict(identity=identity, directory=identity, source=source))

        for pin in lock["pins"]:
            identity = pin["identity"]
            V.require(isinstance(identity, str) and re.fullmatch(r"[a-z0-9][a-z0-9-]*", identity),
                      "unsafe Swift package identity")
            V.require(pin["kind"] == "remoteSourceControl", "unsupported Swift package source kind")
            commit = pin["state"]["revision"]
            V.require(isinstance(commit, str) and re.fullmatch(r"[a-f0-9]{40}", commit), "unpinned Swift package")
            capture(checkouts / identity, identity, commit)
        (staging / "Package.resolved").write_bytes(lock_data)
        (staging / "sources.json").write_bytes(V.canonical(sorted(projects, key=lambda p: p["identity"])))
        os.rename(staging, output)
    return projects


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--lockfile", type=Path, required=True)
    parser.add_argument("--checkouts", type=Path, required=True)
    parser.add_argument("--output", type=Path, required=True)
    args = parser.parse_args()
    capture_packages(args.lockfile, args.checkouts, args.output)


if __name__ == "__main__":
    main()
