#!/usr/bin/env python3
"""Retain applied patches only after the build tree matches their exact replay."""

import argparse
import importlib.util
import os
from pathlib import Path
import re
import subprocess
import tempfile


SPEC = importlib.util.spec_from_file_location("patch_verifier", Path(__file__).with_name("verify-runtime-provenance.py"))
V = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(V)


def regular(root, name):
    current = root
    for part in V.path(name).split("/"):
        current /= part
        V.require(not current.is_symlink(), "symlink in native patch evidence")
    V.require(current.is_file(), "missing native patch evidence: " + name)
    return current


def kernel_patches(log, directory):
    lines = log.read_text().splitlines()
    V.require(sum(line.startswith("Kernel source ready:") for line in lines) == 1,
              "kernel setup did not finish successfully")
    counts = [int(match[1]) for line in lines if (match := re.fullmatch(r"INFO: Found ([0-9]+) patches", line))]
    names = [line[len("INFO: Apply "):] for line in lines
             if line.startswith("INFO: Apply ") and not line.startswith("INFO: Apply patches from ")]
    V.require(len(counts) == 1 and counts[0] == len(names) and len(set(names)) == len(names),
              "kernel applied-patch log is incomplete or ambiguous")
    patches = []
    for name in names:
        path = Path(name)
        V.require(path.is_absolute() and path.parent.name == directory.name and path.suffix == ".patch",
                  "kernel patch is outside the selected version directory")
        patches.append(regular(directory, path.name))
    return patches


def capture(repository, source_capture, tree, root, project, patches, output):
    for directory in (repository, source_capture, tree, root):
        V.require(directory.is_dir() and not directory.is_symlink(), "unsafe native patch input directory")
    repository, source_capture, tree, root = (path.resolve() for path in (repository, source_capture, tree, root))
    V.path(project)
    V.require(output.is_absolute() and output.parent.is_dir() and not output.exists() and not output.is_symlink(),
              "native patch ledger must be a new absolute file")
    source = V.parse(regular(source_capture, "source.json").read_bytes())
    commit = V.bound(source["commitObject"], lambda name: regular(source_capture, name).read_bytes())
    V.require(V.git_object("commit", commit) == source["commit"]
              and commit.splitlines()[0] == b"tree " + source["tree"].encode(), "native patch source commit mismatch")
    command = ["git", "-c", "core.filemode=true", "-c", "core.symlinks=true", "-C", str(repository)]
    V.require(subprocess.check_output(command + ["cat-file", "commit", source["commit"]]) == commit,
              "native patch repository differs from captured source")
    inventory = V.parse(V.bound(source["inventory"], lambda name: regular(source_capture, name).read_bytes()),
                        limit=V.MAX_SOURCE_INVENTORY)
    leaves = {row["path"]: row for row in inventory}
    entries = {}
    for entry in subprocess.check_output(command + ["ls-tree", "-r", "-z", source["commit"]]).split(b"\0"):
        if entry:
            metadata, name = entry.split(b"\t", 1)
            mode, kind, oid = metadata.decode().split()
            V.require(kind == "blob", "native patch source requires separately captured submodule")
            entries[V.path(name.decode())] = (mode, oid)
    V.require(len(leaves) == len(inventory) and entries == {
        name: (row["gitMode"], row["gitBlobSHA1"]) for name, row in leaves.items()},
        "native patch source inventory differs from captured Git tree")
    patch_data, contents = [], {}
    for patch in patches:
        V.require(patch.is_file() and not patch.is_symlink(), "missing regular applied patch")
        data = patch.read_bytes()
        for name in re.findall(rb"^--- a/(.+)$", data, re.MULTILINE):
            name = V.path(name.decode())
            V.require(name in leaves and leaves[name]["gitMode"] != "120000", "patch targets missing source or link")
            if name not in contents:
                original = subprocess.check_output(command + ["show", source["commit"] + ":" + name])
                V.require(V.digest(original) == leaves[name]["sha256"]
                          and V.git_object("blob", original) == leaves[name]["gitBlobSHA1"],
                          "patch source differs from captured Git leaf")
                contents[name] = original
        V.apply_patch_bytes(data, contents)
        patch_data.append((patch.name, data))
    directories = {tree}
    for name, leaf in leaves.items():
        filename = tree
        for part in name.split("/")[:-1]:
            filename /= part
            if filename not in directories:
                V.require(filename.is_dir() and not filename.is_symlink(), "unsafe native source directory: " + name)
                directories.add(filename)
        filename /= name.split("/")[-1]
        mode = "120000" if filename.is_symlink() else "100755" if filename.is_file() and filename.stat().st_mode & 0o111 else "100644"
        V.require(mode == leaf["gitMode"] and (filename.is_file() or filename.is_symlink()),
                  "native build source differs from the applied patch ledger: " + name)
        data = os.readlink(filename).encode() if mode == "120000" else filename.read_bytes()
        matches = data == contents[name] if name in contents else (
            V.digest(data) == leaf["sha256"] and V.git_object("blob", data) == leaf["gitBlobSHA1"])
        V.require(matches, "native build source differs from the applied patch ledger: " + name)
    with tempfile.TemporaryDirectory(prefix=".native-patches-", dir=output.parent) as temporary:
        temporary = Path(temporary)
        ledger = []
        for index, (name, data) in enumerate(patch_data):
            relative = "native-patches/" + project + "/" + str(index).zfill(4) + "-" + name
            destination = root / V.path(relative)
            directory = root
            for part in relative.split("/")[:-1]:
                directory /= part
                V.require(not directory.is_symlink(), "symlink in retained patch directory")
                directory.mkdir(exist_ok=True)
            if destination.exists():
                V.require(not destination.is_symlink() and destination.read_bytes() == data, "conflicting applied patch evidence")
            else:
                destination.write_bytes(data)
            ledger.append(dict(path=relative, sha256=V.digest(data), sizeBytes=len(data)))
        result = {project: ledger}
        pending = temporary / "ledger.json"
        pending.write_bytes(V.canonical(result))
        V.require(not output.exists() and not output.is_symlink(), "native patch ledger already exists")
        os.rename(pending, output)
    return result


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    for name in ("repository", "source-capture", "tree", "root", "output"):
        parser.add_argument("--" + name, type=Path, required=True)
    parser.add_argument("--project", required=True)
    parser.add_argument("--patch", type=Path, action="append", default=[])
    parser.add_argument("--kernel-setup-log", type=Path)
    parser.add_argument("--kernel-patches-dir", type=Path)
    args = parser.parse_args()
    V.require((args.kernel_setup_log is None) == (args.kernel_patches_dir is None), "kernel log and patch directory are required together")
    patches = args.patch
    if args.kernel_setup_log is not None:
        V.require(not patches, "kernel patch order must come from the actual setup log")
        patches = kernel_patches(args.kernel_setup_log, args.kernel_patches_dir)
    capture(args.repository, args.source_capture, args.tree, args.root, args.project, patches, args.output)
