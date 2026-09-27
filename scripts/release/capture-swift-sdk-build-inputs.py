#!/usr/bin/env python3
"""Retain SDK source trees and build metadata before an ephemeral builder exits."""

import argparse
import hashlib
import importlib.util
import os
from pathlib import Path
import shutil
import tempfile


SPEC = importlib.util.spec_from_file_location("source_capture", Path(__file__).with_name("capture-runtime-source.py"))
SOURCE = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(SOURCE)
V = SOURCE.VERIFIER


def digest_file(filename):
    with filename.open("rb") as stream:
        return hashlib.file_digest(stream, "sha256").hexdigest()


def retain(root, filename):
    if filename.is_symlink() or not filename.is_file():
        raise ValueError("build evidence must be a regular file: " + str(filename))
    digest = digest_file(filename)
    target = root / "files" / digest / filename.name
    target.parent.mkdir(parents=True, exist_ok=True)
    if not target.exists():
        shutil.copyfile(filename, target)
    if digest_file(target) != digest or digest_file(filename) != digest:
        raise ValueError("SDK build evidence changed during capture")
    return dict(path=target.relative_to(root).as_posix(), sha256=digest, sizeBytes=target.stat().st_size)


def capture(sources, build, sdk_archive, pins, output):
    for directory in (sources, build):
        if directory.is_symlink() or not directory.is_dir():
            raise ValueError("SDK source and build directories must be regular directories")
    if sdk_archive.is_symlink() or not sdk_archive.is_file():
        raise ValueError("SDK archive must be a regular file")
    if not output.is_absolute() or not output.parent.is_dir() or output.exists() or output.is_symlink():
        raise ValueError("SDK evidence requires a new absolute output directory")
    if not isinstance(pins, list) or not pins:
        raise ValueError("SDK source pins are missing")
    sources = sources.resolve()
    build = build.resolve()
    if output.resolve().is_relative_to(sources) or output.resolve().is_relative_to(build):
        raise ValueError("SDK evidence output must be outside source and build trees")
    sdk_digest = digest_file(sdk_archive)
    with tempfile.TemporaryDirectory(prefix=".sdk-build-inputs-", dir=output.parent) as temporary:
        staging = Path(temporary) / "capture"
        staging.mkdir(mode=0o700)
        (staging / "source-trees").mkdir()
        projects = []
        destinations = set()
        for pin in pins:
            destination = V.path(pin["destination"])
            if destination in destinations:
                raise ValueError("duplicate SDK source destination")
            destinations.add(destination)
            repository = sources / destination
            if repository.is_symlink() or not repository.resolve().is_relative_to(sources):
                raise ValueError("SDK source checkout escapes its root")
            if Path(SOURCE.git(repository, "rev-parse", "--show-toplevel").decode().strip()).resolve() != repository.resolve():
                raise ValueError("SDK source is not an independent pinned checkout")
            if SOURCE.git(repository, "rev-parse", "HEAD").decode().strip() != pin["commit"]:
                raise ValueError("SDK source checkout differs from its exact pin")
            source_output = staging / "source-trees" / destination
            source_output.parent.mkdir(parents=True, exist_ok=True)
            source = SOURCE.capture(repository, pin["commit"], source_output)
            row = dict(identity="swift-sdk/" + destination, destination=destination,
                       originalPath=str(repository), directory="source-trees/" + destination, source=source)
            patch = SOURCE.git(repository, "diff", "--binary", "--no-ext-diff", "--no-textconv", "HEAD", "--")
            if patch:
                patch_path = source_output / "build.patch"
                patch_path.write_bytes(patch)
                row["workingTreePatch"] = retain(staging, patch_path)
            projects.append(row)

        metadata = []
        objects = []
        for directory, children, filenames in os.walk(build, followlinks=False):
            parent = Path(directory)
            children[:] = sorted(name for name in children
                                  if not (parent / name).is_symlink()
                                  and not name.endswith(".artifactbundle"))
            for name in sorted(filenames):
                filename = parent / name
                if filename.is_symlink() or not filename.is_file():
                    continue
                relative = filename.relative_to(build).as_posix()
                if name in {"compile_commands.json", "build.ninja", "rules.ninja", ".ninja_deps", ".ninja_log",
                            "CMakeCache.txt", "description.json", "release.yaml", "debug.yaml", "sources"} or name.endswith(
                                (".d", ".rsp", "output-file-map.json", ".SwiftFileList")):
                    metadata.append(dict(originalPath=str(filename), buildPath=relative, file=retain(staging, filename)))
                elif name.endswith((".o", ".obj", ".a", ".lo", ".os")):
                    objects.append(dict(originalPath=str(filename), buildPath=relative,
                                        sha256=digest_file(filename), sizeBytes=filename.stat().st_size))
        if not metadata or not objects:
            raise ValueError("SDK build lacks retained compilation metadata or object files")
        if sdk_digest != digest_file(sdk_archive):
            raise ValueError("SDK archive changed during evidence capture")
        result = dict(kind="hostwright.swift-sdk-build-inputs.v1", status="prepared-not-release-qualified",
                      sdkArchiveSHA256=sdk_digest, sdkArchiveSizeBytes=sdk_archive.stat().st_size,
                      sourceRoot=str(sources), buildRoot=str(build), sourceProjects=projects,
                      metadata=metadata, objectInventory="objects.json")
        (staging / "objects.json").write_bytes(V.canonical(objects))
        (staging / "build-inputs.json").write_bytes(V.canonical(result))
        os.rename(staging, output)
    return result


if __name__ == "__main__":
    parser = argparse.ArgumentParser()
    parser.add_argument("--sources", type=Path, required=True)
    parser.add_argument("--build", type=Path, required=True)
    parser.add_argument("--sdk-archive", type=Path, required=True)
    parser.add_argument("--output", type=Path, required=True)
    parser.add_argument("--pins", type=Path, default=Path(__file__).with_name("runtime-swift-sources.json"))
    arguments = parser.parse_args()
    capture(arguments.sources, arguments.build, arguments.sdk_archive,
            V.parse(arguments.pins.read_bytes()), arguments.output)
