#!/usr/bin/env python3
"""Capture complete, pinned Go runtime and linked module source projects."""

import argparse
import importlib.util
import os
from pathlib import Path
import re
import subprocess
import tempfile


SPEC = importlib.util.spec_from_file_location("source", Path(__file__).with_name("capture-runtime-source.py"))
SOURCE = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(SOURCE)
V = SOURCE.VERIFIER


def capture(pins, host_repository, source_commit, repositories, output):
    if not output.is_absolute() or not output.parent.is_dir() or output.exists() or output.is_symlink():
        raise ValueError("source projects require a new absolute output")
    if SOURCE.git(host_repository, "rev-parse", "HEAD").decode().strip() != source_commit:
        raise ValueError("Hostwright checkout differs from the source commit")
    if SOURCE.git(host_repository, "status", "--porcelain=v1", "--untracked-files=all"):
        raise ValueError("Hostwright source checkout is dirty")
    host = dict(identity="hostwright", commit=source_commit, spdx="Apache-2.0",
                licenses=["LICENSE"], notices=["LICENSE"])
    projects = []
    identities = set()
    with tempfile.TemporaryDirectory(prefix=".go-source-projects-", dir=output.parent) as temporary:
        staging = Path(temporary) / "projects"
        staging.mkdir(mode=0o700)
        for pin in [host, pins["go"], *pins["modules"]]:
            identity = pin["identity"]
            if not re.fullmatch(r"[a-z0-9][a-z0-9-]*", identity) or identity in identities:
                raise ValueError("invalid or duplicate Go source identity")
            identities.add(identity)
            repository = host_repository if identity == "hostwright" else repositories / (identity + ".git")
            source = SOURCE.capture(repository, pin["commit"], staging / identity)
            project = dict(source, identity=identity, spdx=V.spdx(pin["spdx"]), patches=[])
            for field in ("licenses", "notices"):
                project[field] = []
                for name in pin[field]:
                    name = V.path(name)
                    data = SOURCE.git(repository, "show", pin["commit"] + ":" + name)
                    if not data.strip():
                        raise ValueError("empty Go source license or notice")
                    relative = "licenses/" + name
                    target = staging / identity / relative
                    target.parent.mkdir(parents=True, exist_ok=True)
                    target.write_bytes(data)
                    project[field].append(dict(path=relative, sourcePath=name, component=identity,
                                               spdx=project["spdx"], sha256=V.digest(data), sizeBytes=len(data)))
            V.source_project(project, lambda name: (staging / identity / name).read_bytes())
            (staging / identity / "project.json").write_bytes(V.canonical(project))
            projects.append(dict(identity=identity, module=pin.get("module"), version=pin.get("version"),
                                 directory=identity, project=project))
        (staging / "projects.json").write_bytes(V.canonical(projects))
        os.rename(staging, output)
    return projects


def fetch_repositories(pins, output):
    if not output.is_absolute() or not output.parent.is_dir() or output.exists() or output.is_symlink():
        raise ValueError("repository cache requires a new absolute output")
    with tempfile.TemporaryDirectory(prefix=".go-source-repositories-", dir=output.parent) as temporary:
        staging = Path(temporary) / "repositories"
        staging.mkdir(mode=0o700)
        for pin in [pins["go"], *pins["modules"]]:
            if not re.fullmatch(r"[a-z0-9][a-z0-9-]*", pin["identity"]) or not re.fullmatch(r"[a-f0-9]{40}", pin["commit"]):
                raise ValueError("invalid pinned Go source")
            if not pin["repository"].startswith(("https://github.com/", "https://go.googlesource.com/")):
                raise ValueError("unsupported Go source repository")
            repository = staging / (pin["identity"] + ".git")
            subprocess.run(["git", "init", "--quiet", "--bare", str(repository)], check=True)
            subprocess.run(["git", "-C", str(repository), "fetch", "--quiet", "--no-tags", "--depth=1",
                            pin["repository"], pin["commit"] + ":refs/heads/pinned"], check=True)
            if SOURCE.git(repository, "rev-parse", "FETCH_HEAD").decode().strip() != pin["commit"]:
                raise ValueError("fetched Go source differs from pinned commit")
            subprocess.run(["git", "-C", str(repository), "symbolic-ref", "HEAD", "refs/heads/pinned"], check=True)
        os.rename(staging, output)


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--pins", type=Path, default=Path(__file__).with_name("runtime-go-sources.json"))
    parser.add_argument("--repositories", type=Path, required=True)
    parser.add_argument("--fetch", action="store_true")
    parser.add_argument("--source-root", type=Path)
    parser.add_argument("--source-commit")
    parser.add_argument("--output", type=Path)
    args = parser.parse_args()
    pins = V.parse(args.pins.read_bytes())
    if args.fetch:
        fetch_repositories(pins, args.repositories)
    if args.output:
        if args.source_root is None or args.source_commit is None:
            parser.error("--output requires --source-root and --source-commit")
        capture(pins, args.source_root, args.source_commit, args.repositories, args.output)
    elif not args.fetch:
        parser.error("provide --fetch or --output")


if __name__ == "__main__":
    main()
