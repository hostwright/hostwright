#!/usr/bin/env python3
"""Replay the authenticated retained build trace for the seven bzip2 SDK objects."""

import argparse
import copy
import hashlib
import importlib.util
import json
import os
from pathlib import Path, PurePosixPath
import shutil
import tarfile


HERE = Path(__file__).resolve().parent
SPEC = importlib.util.spec_from_file_location("sdk_capture", HERE / "capture-sdk-object-sources.py")
CAPTURE = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(CAPTURE)
V = CAPTURE.V

EXPECTED_ARCHIVE = "b9addf394f5a4d00c3170c4948c0ab122faa88062cd6fb14c7b5507c40d59368"
EXPECTED_MEMBERS = {
    "blocksort.o": ("f6bd1af752f212aaf25d851d2bca571f98b25ac1d96c462902bab2dbdc662c6a", 36600),
    "huffman.o": ("c983ec82d8e247d16dd80772531cb3f0e092f6bc3a7817c4d15df1e8b24eda38", 10336),
    "crctable.o": ("feb30b796acaeddf3939d5d61a2fec283f5dd957c9c62b24a7fe390b36ce1df6", 4024),
    "randtable.o": ("8d965fae44189483f3a51bcd24ee8f43a72c376ee745f6c788f05f534632bda5", 5032),
    "compress.o": ("b5758b5d63be88315b827fe7adf11c01c77050b793b6f208cf3717d64a9c7a50", 54208),
    "decompress.o": ("bb3da20a5fa17b98a5be5bf4923177598ce964aed611f200fba9342a5369ae50", 41400),
    "bzlib.o": ("969efed9003ba7f06d0159c05cb08e738a375540b53686f29181879aa07889bd", 64912),
}
PROJECTS = {
    "swift-sdk/bzip2": "bzip2",
    "swift-sdk/musl": "musl",
    "swift-sdk/swift-project/llvm-project": "llvm-project",
}


def sha256_file(path):
    with path.open("rb") as stream:
        return hashlib.file_digest(stream, "sha256").hexdigest()


def verified_checksums(records):
    rows = {}
    for line in (records / "checksums.sha256").read_text().splitlines():
        digest, name = line.split("  ", 1)
        name = V.path(name.removeprefix("./"))
        V.require(name not in rows and len(digest) == 64, "invalid or duplicate retained checksum row")
        rows[name] = digest

    def check(name):
        name = V.path(name)
        path = records / name
        V.require(name in rows and path.is_file() and not path.is_symlink(), "missing checksummed SDK evidence: " + name)
        V.require(sha256_file(path) == rows[name], "retained SDK evidence checksum mismatch: " + name)
        return path

    return check


def safe_hardlink(source, destination):
    destination.parent.mkdir(parents=True, exist_ok=True)
    V.require(not destination.exists() and not destination.is_symlink(), "unexpected recovery catalog path")
    os.link(source, destination)


def inventory_hash(contents):
    return V.digest(V.canonical({name: V.digest(data) for name, data in contents.items()}))


def make_project_catalog(records, work, build_inputs, declarations):
    catalog = work / "projects"
    catalog.mkdir()
    projects = []
    for identity, destination in PROJECTS.items():
        row = next((item for item in build_inputs["sourceProjects"] if item["identity"] == identity), None)
        declaration = next((item for item in declarations["sdk"] if item["identity"] == identity), None)
        V.require(row is not None and declaration is not None, "missing exact reviewed source project: " + identity)
        prefix = "evidence/" + destination
        srcdir = records / "build-inputs" / V.path(row["directory"])
        src = row["source"]
        project = dict(identity=identity, commit=src["commit"], tree=src["tree"],
                       spdx=declaration["spdx"], licenses=[], notices=[], patches=[])
        if "submodules" in src:
            project["submodules"] = copy.deepcopy(src["submodules"])
        for field, filename in (("archive", "source.tar.gz"), ("inventory", "source-inventory.json"),
                                ("commitObject", "commit.object")):
            check_path = srcdir / V.path(src[field]["path"])
            V.require(check_path.is_file() and not check_path.is_symlink()
                      and sha256_file(check_path) == src[field]["sha256"]
                      and check_path.stat().st_size == src[field]["sizeBytes"],
                      "captured project evidence mismatch: " + identity + "/" + field)
            rel = prefix + "/" + filename
            safe_hardlink(check_path, catalog / rel)
            project[field] = dict(path=rel, sha256=src[field]["sha256"], sizeBytes=src[field]["sizeBytes"])
        archive_path = catalog / project["archive"]["path"]
        with tarfile.open(archive_path, "r:*") as archive:
            contents = {}
            for member in archive.getmembers():
                name = V.path(member.name)
                V.require(member.isfile() or member.isdir(), "unsafe retained source archive member")
                if member.isfile():
                    V.require(name not in contents and member.size <= V.MAX_FILE,
                              "duplicate or oversized retained source archive member")
                    contents[name] = archive.extractfile(member).read()
        if "workingTreePatch" in row:
            patch_meta = row["workingTreePatch"]
            patch_path = records / "build-inputs" / V.path(patch_meta["path"])
            V.require(patch_path.is_file() and not patch_path.is_symlink()
                      and patch_path.stat().st_size == patch_meta["sizeBytes"]
                      and sha256_file(patch_path) == patch_meta["sha256"], "captured source patch mismatch")
            patch = patch_path.read_bytes()
            before = inventory_hash(contents)
            V.apply_patch_bytes(patch, contents)
            after = inventory_hash(contents)
            rel = prefix + "/patches/build.patch"
            patch_destination = catalog / rel
            patch_destination.parent.mkdir(parents=True, exist_ok=True)
            shutil.copyfile(patch_path, patch_destination)
            project["patches"].append(dict(path=rel, sha256=patch_meta["sha256"],
                sizeBytes=patch_meta["sizeBytes"], beforeInventorySHA256=before, afterInventorySHA256=after))
        for name in declaration["licenses"]:
            name = V.path(name)
            V.require(name in contents, "reviewed source license is absent from captured archive")
            data = contents[name]
            rel = prefix + "/licenses/" + name
            dest = catalog / rel
            dest.parent.mkdir(parents=True, exist_ok=True)
            dest.write_bytes(data)
            reference = dict(path=rel, sha256=V.digest(data), sizeBytes=len(data), sourcePath=name,
                             component=identity, spdx=declaration["spdx"])
            project["licenses"].append(reference)
            project["notices"].append(copy.deepcopy(reference))
        projects.append(project)
    (catalog / "projects.json").write_bytes(V.canonical(projects))
    return catalog


def extract_sdk_inputs(sdk_archive, build_root):
    sdk_root = build_root / "sdk_root"
    wanted = []
    with tarfile.open(sdk_archive, "r:*") as archive:
        for member in archive.getmembers():
            name = member.name.lstrip("./")
            marker = "/aarch64/"
            if marker not in "/" + name or not member.isfile():
                continue
            tail = name.split("aarch64/", 1)[1]
            if not (tail.startswith("usr/include/") or tail.startswith("usr/lib/clang/")
                    or tail.startswith("usr/lib/swift/clang/")):
                continue
            relative = PurePosixPath("aarch64") / tail
            V.path(relative.as_posix())
            wanted.append((member, sdk_root / relative))
        V.require(wanted, "SDK archive contains no captured aarch64 compiler headers")
        for member, destination in wanted:
            destination.parent.mkdir(parents=True, exist_ok=True)
            with archive.extractfile(member) as source, destination.open("xb") as target:
                shutil.copyfileobj(source, target)
    return sdk_root


def recover(records, output, work):
    records = records.resolve(strict=True)
    V.require(records.is_dir() and not records.is_symlink(), "unsafe SDK records root")
    V.require(output.is_absolute() and output.parent.is_dir() and not output.exists() and not output.is_symlink(),
              "recovery output must be a new absolute file")
    V.require(work.is_absolute() and not work.exists() and not work.is_symlink()
              and not work.resolve().is_relative_to(records), "recovery work directory must be new and external")
    check = verified_checksums(records)
    old_map_path = check("build-inputs/sdk-object-sources.json")
    inputs_path = check("build-inputs/build-inputs.json")
    objects_path = check("build-inputs/objects.json")
    trace = check("build.trace")
    sdk_archive = check("swift-static-sdk.tar.gz")
    old_map = V.parse(old_map_path.read_bytes(), limit=V.MAX_SOURCE_INVENTORY)
    build_inputs = V.parse(inputs_path.read_bytes(), limit=V.MAX_SOURCE_INVENTORY)
    objects = V.parse(objects_path.read_bytes(), limit=V.MAX_SOURCE_INVENTORY)
    declarations = V.parse((HERE / "runtime-native-source-licenses.json").read_bytes(), limit=V.MAX_SOURCE_INVENTORY)
    unresolved = {row.get("member"): row for row in old_map["unresolved"]
                  if row.get("archive") == "/workspace/build/sdk_root/aarch64/usr/lib/libbz2.a"}
    if not unresolved:
        shutil.copyfile(old_map_path, output)
        evidence_dir = output.parent / "sdk-source-recovery"
        V.require(not evidence_dir.exists() and not evidence_dir.is_symlink(),
                  "recovery evidence directory already exists")
        evidence_dir.mkdir(mode=0o700)
        receipt = dict(kind="hostwright.sdk-object-source-recovery.v1",
            sourceMapSHA256=V.digest(old_map_path.read_bytes()),
            checksumsSHA256=V.digest((records / "checksums.sha256").read_bytes()),
            traceSHA256=sha256_file(trace), sdkArchiveSHA256=sha256_file(sdk_archive),
            outputSHA256=sha256_file(output), recoveredObjects=[])
        (evidence_dir / "recovery.json").write_bytes(V.canonical(receipt))
        return dict(output=str(output), recovered=0, unresolved=len(old_map["unresolved"]),
                    evidence=str(evidence_dir), projects=None)
    expected_rows = {name: (digest, size) for name, (digest, size) in EXPECTED_MEMBERS.items()}
    V.require(set(unresolved) == set(expected_rows), "retained map does not contain exactly the seven expected bzip2 gaps")
    for name, (digest, size) in expected_rows.items():
        row = unresolved[name]
        V.require(row["objectSHA256"] == digest and row["objectSizeBytes"] == size
                  and row["archiveSHA256"] == EXPECTED_ARCHIVE, "bzip2 unresolved inventory differs from fixed expected evidence")
    object_rows = {row["sha256"]: row for row in objects}
    work.mkdir(mode=0o700)
    build_root = work / "build"
    source_root = work / "sources"
    (build_root / "aarch64/bzip2").mkdir(parents=True)
    source_root.mkdir()
    for identity, destination in PROJECTS.items():
        (source_root / destination).mkdir(parents=True, exist_ok=True)
    project_catalog = make_project_catalog(records, work, build_inputs, declarations)
    project_evidence = work / "projects"
    # Projects are verified from the retained source archives; only the bzip2 translation units are materialized.
    bzip_project = next(item for item in build_inputs["sourceProjects"] if item["identity"] == "swift-sdk/bzip2")
    bzip_archive = records / "build-inputs" / bzip_project["directory"] / bzip_project["source"]["archive"]["path"]
    with tarfile.open(bzip_archive, "r:*") as archive:
        for member in archive.getmembers():
            name = V.path(member.name)
            if member.isfile():
                destination = source_root / "bzip2" / name
                destination.parent.mkdir(parents=True, exist_ok=True)
                with archive.extractfile(member) as source, destination.open("xb") as target:
                    shutil.copyfileobj(source, target)
    # The retained command compiled basename-only C inputs from this build directory.
    # Materialize those same pinned bytes at those original paths for relocation replay.
    for source in (source_root / "bzip2").rglob("*"):
        if not source.is_file() or source.is_symlink():
            continue
        destination = build_root / "aarch64/bzip2" / source.relative_to(source_root / "bzip2")
        destination.parent.mkdir(parents=True, exist_ok=True)
        shutil.copyfile(source, destination)
    V.require(all((build_root / "aarch64/bzip2" / (Path(name).stem + ".c")).is_file()
                  for name in EXPECTED_MEMBERS), "retained bzip2 translation units are missing")
    sdk_root = extract_sdk_inputs(sdk_archive, build_root)
    archive_data = None
    with tarfile.open(sdk_archive, "r:*") as archive:
        candidates = [member for member in archive.getmembers()
                      if member.isfile() and member.name.endswith("/aarch64/usr/lib/libbz2.a")]
        V.require(len(candidates) == 1, "SDK archive lacks a unique selected libbz2.a")
        archive_data = archive.extractfile(candidates[0]).read()
    V.require(V.digest(archive_data) == EXPECTED_ARCHIVE, "selected libbz2.a digest mismatch")
    archive_entries = V.archive_entries(archive_data)
    V.require(len({name for name, _, _ in archive_entries}) == len(archive_entries),
              "selected libbz2.a contains duplicate member names")
    members = {name: (offset, data) for name, offset, data in archive_entries}
    selected = []
    for name, (digest, size) in expected_rows.items():
        archive_offset, member_data = members.get(name, (None, None))
        V.require(name in members and archive_offset == unresolved[name]["archiveOffset"]
                  and len(member_data) == size and V.digest(member_data) == digest,
                  "libbz2.a member differs from retained unresolved row: " + name)
        object_row = object_rows.get(digest)
        V.require(object_row is not None and object_row["sizeBytes"] == size
                  and object_row["buildPath"] == "aarch64/bzip2/" + name
                  and object_row["originalPath"] == "/workspace/build/aarch64/bzip2/" + name,
                  "bzip2 object is not bound to the retained object inventory")
        build_path = build_root / object_row["buildPath"]
        build_path.parent.mkdir(parents=True, exist_ok=True)
        build_path.write_bytes(member_data)
        selected.append(dict(object=str(build_path), objectSHA256=digest, objectSizeBytes=size))
    evidence_dir = output.parent / "sdk-source-recovery"
    V.require(not evidence_dir.exists() and not evidence_dir.is_symlink(), "recovery evidence directory already exists")
    evidence_dir.mkdir(mode=0o700)
    result = CAPTURE.capture(source_root, [build_root], None, [], traces=[trace],
        relocations=[(Path("/workspace/build"), build_root), (Path("/workspace/sources"), source_root)],
        projects_root=project_catalog, source_roots={identity: source_root / destination
            for identity, destination in PROJECTS.items()},
        selected_inputs=selected, trace_cwd=Path("/workspace/build"), generated_output=evidence_dir / "generated",
        mapping_root=evidence_dir, external_header_roots=[sdk_root])
    (work / "capture.json").write_bytes(V.canonical(result))
    V.require(not result["rejectedInputs"], "actual trace replay rejected compiler evidence: " +
              V.canonical(result["rejectedInputs"][:5]).decode())
    recovered = {row["objectSHA256"]: row for row in result["sourceMap"]}
    V.require(set(recovered) == {value[0] for value in expected_rows.values()},
              "trace replay did not map exactly all seven selected bzip2 objects")
    old_rows = {row["objectSHA256"]: row for row in old_map["sourceMap"]}
    merged = copy.deepcopy(old_map)
    def install_compiler_inputs(row):
        reference = row.get("compilerInputs")
        if not isinstance(reference, dict):
            return
        original = evidence_dir / V.path(reference["path"])
        data = V.bound(reference, lambda _: original.read_bytes())
        row["compilerInputs"] = dict(path="sdk-source-recovery/" + reference["path"],
                                     sha256=V.digest(data), sizeBytes=len(data))

    recovered_rows = [copy.deepcopy(recovered[digest]) for digest in sorted(recovered)]
    for row in recovered_rows:
        install_compiler_inputs(row)
        V.native_source_files(row, lambda name: (output.parent / V.path(name)).read_bytes())
    merged["sourceMap"] = sorted([*old_map["sourceMap"], *recovered_rows],
                                 key=lambda row: row["objectSHA256"])
    removed = set(recovered)
    merged["unresolved"] = [row for row in old_map["unresolved"] if row["objectSHA256"] not in removed]
    V.require(all(row["objectSHA256"] in old_rows for row in merged["sourceMap"] if row["objectSHA256"] not in removed),
              "recovery changed existing source mappings")
    merged["counts"]["mappedMembers"] += len(recovered)
    merged["counts"]["unresolvedMembers"] -= len(recovered)
    merged["counts"]["mappedObjects"] += len(recovered)
    with output.open("xb") as stream:
        stream.write(V.canonical(merged))
    receipt = dict(kind="hostwright.sdk-object-source-recovery.v1",
        sourceMapSHA256=V.digest(old_map_path.read_bytes()),
        checksumsSHA256=V.digest((records / "checksums.sha256").read_bytes()),
        traceSHA256=sha256_file(trace), sdkArchiveSHA256=sha256_file(sdk_archive),
        outputSHA256=sha256_file(output), recoveredObjects=sorted(recovered))
    (evidence_dir / "recovery.json").write_bytes(V.canonical(receipt))
    return dict(output=str(output), recovered=len(recovered), unresolved=len(merged["unresolved"]),
                evidence=str(evidence_dir), projects=str(project_evidence))


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--records", type=Path, required=True)
    parser.add_argument("--output", type=Path, required=True)
    parser.add_argument("--work-dir", type=Path, required=True)
    args = parser.parse_args()
    print(json.dumps(recover(args.records, args.output, args.work_dir), sort_keys=True))


if __name__ == "__main__":
    main()
