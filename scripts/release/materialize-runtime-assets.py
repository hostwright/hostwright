#!/usr/bin/env python3
"""Verify an authenticated runtime provenance archive and materialize its product payloads."""
import argparse
import importlib.util
import os
import pathlib
import re
import tarfile
import tempfile


HERE = pathlib.Path(__file__).resolve().parent
SPEC = importlib.util.spec_from_file_location("runtime_provenance", HERE / "verify-runtime-provenance.py")
VERIFIER = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(VERIFIER)
PREFIX = "share/hostwright/containerization/"


def fail(message):
    raise ValueError(message)


def lexical_path(value, role):
    candidate = pathlib.Path(os.path.abspath(value))
    current = pathlib.Path(candidate.anchor)
    for component in candidate.parts[1:]:
        current /= component
        if current.is_symlink():
            fail(role + " traverses a symlink")
    return candidate


def materialize(archive_path, output, source_commit):
    archive_path = lexical_path(archive_path, "runtime provenance archive")
    output = lexical_path(output, "runtime asset output")
    if not re.fullmatch(r"[a-f0-9]{40}", source_commit):
        fail("invalid runtime asset source commit")
    if not archive_path.is_file():
        fail("runtime provenance archive must be a regular file")
    if output.exists():
        fail("runtime asset output must not exist")
    if not output.parent.is_dir():
        fail("runtime asset output parent must be a non-symlink directory")

    with tarfile.open(archive_path, "r:gz") as archive:
        members = archive.getmembers()
        files = {}
        for member in members:
            name = VERIFIER.path(member.name.rstrip("/"))
            if name in files:
                fail("duplicate runtime provenance archive member")
            files[name] = member

        def fetch(name):
            name = VERIFIER.path(name)
            member = files.get(name)
            if member is None or not member.isfile() or member.size > VERIFIER.MAX_FILE:
                fail("missing regular runtime provenance member: " + name)
            return archive.extractfile(member).read()

        manifest_data = fetch("runtime-provenance/manifest.json")
        manifest = VERIFIER.parse(manifest_data)
        inventory = VERIFIER.parse(fetch("licenses/runtime-license-inventory.json"))
        payloads = {
            record["path"]: fetch("runtime-provenance/payloads/" + VERIFIER.path(record["path"]))
            for record in manifest["payloads"]
        }
        VERIFIER.verify(manifest_data, inventory, payloads, fetch, source_commit)

    if not payloads or any(not name.startswith(PREFIX) for name in payloads):
        fail("runtime provenance contains a non-product payload")
    relative_payloads = {name.removeprefix(PREFIX): data for name, data in payloads.items()}
    if any(not name for name in relative_payloads):
        fail("runtime provenance contains an empty product payload path")

    temporary = pathlib.Path(tempfile.mkdtemp(prefix="." + output.name + ".", dir=output.parent))
    try:
        os.chmod(temporary, 0o700)
        for name, data in sorted(relative_payloads.items()):
            target = temporary.joinpath(*name.split("/"))
            target.parent.mkdir(parents=True, exist_ok=True, mode=0o700)
            target.write_bytes(data)
            target.chmod(0o755 if name == "guest/hostwright-netfilter" else 0o644)
        for directory, directories, _ in os.walk(temporary):
            pathlib.Path(directory).chmod(0o700)
            for name in directories:
                (pathlib.Path(directory) / name).chmod(0o700)
        os.replace(temporary, output)
    except BaseException:
        if temporary.exists():
            import shutil
            shutil.rmtree(temporary)
        raise
    return {"payloadCount": len(payloads), "sourceCommit": source_commit, "output": str(output)}


if __name__ == "__main__":
    parser = argparse.ArgumentParser()
    parser.add_argument("--archive", type=pathlib.Path, required=True)
    parser.add_argument("--output", type=pathlib.Path, required=True)
    parser.add_argument("--source-commit", required=True)
    arguments = parser.parse_args()
    print(VERIFIER.canonical(materialize(arguments.archive, arguments.output, arguments.source_commit)).decode(), end="")
