#!/usr/bin/env python3
"""Retain every Git source leaf without export-ignore or symlink dereferencing."""

import argparse
import gzip
import hashlib
import importlib.util
import io
import os
from pathlib import Path
import re
import subprocess
import tarfile
import tempfile


SPEC = importlib.util.spec_from_file_location(
    "runtime_provenance", Path(__file__).with_name("verify-runtime-provenance.py")
)
VERIFIER = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(VERIFIER)


def git(repository, *arguments):
    return subprocess.check_output(["git", "-C", str(repository), *arguments])


def capture(repository, commit, output, submodules=None):
    if not re.fullmatch(r"[0-9a-f]{40}", commit):
        raise ValueError("an exact Git commit is required")
    if output.exists() or output.is_symlink():
        raise ValueError("source capture output already exists")
    if not output.is_absolute() or not output.parent.is_dir():
        raise ValueError("source capture requires an existing absolute parent")
    commit_data = git(repository, "cat-file", "commit", commit)
    if VERIFIER.git_object("commit", commit_data) != commit:
        raise ValueError("source commit object mismatch")
    tree = git(repository, "rev-parse", commit + "^{tree}").decode().strip()
    entries = []
    links = []
    submodules = {} if submodules is None else submodules
    if not isinstance(submodules, dict) or not all(
        isinstance(name, str) and isinstance(identity, str) and identity.strip()
        for name, identity in submodules.items()
    ):
        raise ValueError("submodules must map source paths to captured project identities")
    for row in git(repository, "ls-tree", "-r", "-z", "--full-tree", commit).split(b"\0"):
        if not row:
            continue
        metadata, name = row.split(b"\t", 1)
        mode, kind, oid = metadata.decode("ascii").split()
        name = VERIFIER.path(name.decode("utf-8"))
        if mode == "160000" and kind == "commit" and name in submodules:
            links.append(dict(path=name, project=submodules[name], commit=oid))
            continue
        if mode not in ("100644", "100755", "120000") or kind != "blob":
            raise ValueError("source tree requires separately captured submodule: " + name)
        entries.append((name, mode, oid))
    if set(submodules) != {link["path"] for link in links}:
        raise ValueError("submodule mapping differs from the exact Git tree")
    if not entries or len(entries) + len(links) > VERIFIER.MAX_FILES:
        raise ValueError("source tree leaf count exceeds the provenance bound")

    with tempfile.TemporaryDirectory(prefix=".runtime-source-", dir=output.parent) as temporary:
        staging = Path(temporary) / "capture"
        staging.mkdir(mode=0o700)
        (staging / "commit.object").write_bytes(commit_data)
        inventory = []
        with subprocess.Popen(
            ["git", "-C", str(repository), "cat-file", "--batch"],
            stdin=subprocess.PIPE, stdout=subprocess.PIPE,
        ) as process:
            try:
                with (staging / "source.tar.gz").open("xb") as raw:
                    with gzip.GzipFile(filename="", fileobj=raw, mode="wb", mtime=0) as compressed:
                        with tarfile.open(fileobj=compressed, mode="w|", format=tarfile.PAX_FORMAT) as archive:
                            for name, mode, oid in sorted(entries):
                                process.stdin.write((oid + "\n").encode())
                                process.stdin.flush()
                                header = process.stdout.readline().decode("ascii").split()
                                if len(header) != 3 or header[:2] != [oid, "blob"]:
                                    raise ValueError("source blob is unavailable: " + name)
                                size = int(header[2])
                                if not 0 <= size <= VERIFIER.MAX_FILE:
                                    raise ValueError("source blob exceeds the provenance bound: " + name)
                                data = process.stdout.read(size)
                                if process.stdout.read(1) != b"\n" or len(data) != size:
                                    raise ValueError("truncated source blob: " + name)
                                if VERIFIER.git_object("blob", data) != oid:
                                    raise ValueError("source blob identity mismatch: " + name)
                                inventory.append(dict(path=name, gitMode=mode, gitBlobSHA1=oid,
                                                      sha256=VERIFIER.digest(data), sizeBytes=size))
                                member = tarfile.TarInfo(name)
                                member.size = size
                                # Git link targets are retained as bytes, never live archive links.
                                member.mode = 0o755 if mode == "100755" else 0o644
                                archive.addfile(member, io.BytesIO(data))
                process.stdin.close()
                if process.wait() != 0:
                    raise ValueError("Git source capture failed")
            except BaseException:
                process.kill()
                process.wait()
                raise

        inventory_data = VERIFIER.canonical(inventory)
        if len(inventory_data) > VERIFIER.MAX_SOURCE_INVENTORY:
            raise ValueError("complete source inventory exceeds the provenance bound")
        (staging / "source-inventory.json").write_bytes(inventory_data)

        def record(name):
            path = staging / name
            digest = hashlib.sha256()
            with path.open("rb") as stream:
                for chunk in iter(lambda: stream.read(1024 * 1024), b""):
                    digest.update(chunk)
            return dict(path=name, sha256=digest.hexdigest(), sizeBytes=path.stat().st_size)

        source = dict(commit=commit, tree=tree, commitObject=record("commit.object"),
                      archive=record("source.tar.gz"), inventory=record("source-inventory.json"))
        if links:
            source["submodules"] = sorted(links, key=lambda link: link["path"])
        (staging / "source.json").write_bytes(VERIFIER.canonical(source))
        os.rename(staging, output)
    return source


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--repository", type=Path, required=True)
    parser.add_argument("--commit", required=True)
    parser.add_argument("--output", type=Path, required=True)
    parser.add_argument("--submodules", type=Path,
                        help="JSON mapping of Git submodule paths to separately captured project identities")
    args = parser.parse_args()
    submodules = VERIFIER.parse(args.submodules.read_bytes()) if args.submodules else None
    capture(args.repository, args.commit, args.output, submodules)


if __name__ == "__main__":
    main()
