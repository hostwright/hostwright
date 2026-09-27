#!/usr/bin/env python3
"""Match the pinned kernel.org source archive to every leaf of its exact Git tree."""

import argparse
import hashlib
import importlib.util
import os
from pathlib import Path
import tarfile
import tempfile


COMMIT = "df0dc1b06fb6b6461f9838694bf84079eca7562a"
ARCHIVE_SHA256 = "7c716216c3c4134ed0de69195701e677577bbcdd3979f331c182acd06bf2f170"
ARCHIVE_PREFIX = "linux-6.18.15"
SPEC = importlib.util.spec_from_file_location("runtime_source_capture", Path(__file__).with_name("capture-runtime-source.py"))
SOURCE = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(SOURCE)
V = SOURCE.VERIFIER


def compare_archive(stream, inventory, prefix):
    V.path(prefix)
    expected = {item["path"]: item for item in inventory}
    V.require(len(expected) == len(inventory) and expected, "empty or duplicate Git source inventory")
    members = set()
    leaves = set()
    with tarfile.open(fileobj=stream, mode="r|*") as archive:
        for member in archive:
            name = member.name.rstrip("/") if member.isdir() else member.name
            V.path(name)
            V.require(name not in members, "duplicate source archive entry: " + name)
            members.add(name)
            V.require(name == prefix or name.startswith(prefix + "/"), "source archive entry escapes its prefix: " + name)
            if member.isdir():
                continue
            V.require(name.startswith(prefix + "/"), "source archive root must be a directory")
            V.require(member.type in (tarfile.REGTYPE, tarfile.AREGTYPE, tarfile.SYMTYPE) and not member.issparse(),
                      "unsupported source archive entry: " + name)
            relative = name.removeprefix(prefix + "/")
            V.require(relative in expected, "source archive has an extra Git leaf: " + relative)
            leaf = expected[relative]
            if member.issym():
                data = member.linkname.encode("utf-8", errors="surrogateescape")
                mode, size, digest = "120000", len(data), V.digest(data)
            else:
                V.require(0 <= member.size <= V.MAX_FILE, "source archive file exceeds provenance bound")
                with archive.extractfile(member) as source:
                    digest = hashlib.file_digest(source, "sha256").hexdigest()
                mode = "100755" if member.mode & 0o111 else "100644"
                size = member.size
            V.require((mode, size, digest) == (leaf["gitMode"], leaf["sizeBytes"], leaf["sha256"]),
                      "source archive differs from the captured Git leaf: " + relative)
            leaves.add(relative)
    missing = sorted(set(expected) - leaves)
    V.require(not missing, "source archive is missing Git leaves: " + ", ".join(missing[:8]))
    return len(leaves)


def capture(repository, source_archive, output, *, commit=COMMIT, archive_sha256=ARCHIVE_SHA256,
            archive_prefix=ARCHIVE_PREFIX):
    repository, source_archive, output = Path(repository), Path(source_archive), Path(output)
    V.require(repository.is_absolute(), "kernel repository must be absolute")
    V.require(output.is_absolute() and output.parent.is_dir() and not output.exists() and not output.is_symlink(),
              "kernel source capture requires a new absolute output in an existing parent")
    with source_archive.open("rb") as stream:
        V.require(hashlib.file_digest(stream, "sha256").hexdigest() == archive_sha256,
                  "kernel source archive digest mismatch")
        archive_size = os.fstat(stream.fileno()).st_size
        with tempfile.TemporaryDirectory(prefix=".linux-source-", dir=output.parent) as temporary:
            staging = Path(temporary) / "capture"
            source = SOURCE.capture(repository, commit, staging)
            inventory = V.parse((staging / source["inventory"]["path"]).read_bytes(), limit=V.MAX_SOURCE_INVENTORY)
            stream.seek(0)
            leaf_count = compare_archive(stream, inventory, archive_prefix)
            stream.seek(0)
            V.require(hashlib.file_digest(stream, "sha256").hexdigest() == archive_sha256,
                      "kernel source archive changed during capture")
            receipt = dict(kind="hostwright.linux-source-archive-match.v1", commit=commit, tree=source["tree"],
                           archivePrefix=archive_prefix, leafCount=leaf_count, inventory=source["inventory"],
                           sourceArchive=dict(name=source_archive.name, sha256=archive_sha256, sizeBytes=archive_size))
            (staging / "archive-match.json").write_bytes(V.canonical(receipt))
            os.rename(staging, output)
    return source


if __name__ == "__main__":
    parser = argparse.ArgumentParser()
    parser.add_argument("--repository", type=Path, required=True)
    parser.add_argument("--source-archive", type=Path, required=True)
    parser.add_argument("--output", type=Path, required=True)
    args = parser.parse_args()
    capture(args.repository, args.source_archive, args.output)
