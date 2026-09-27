#!/usr/bin/env python3
"""Prepare selected captured sources using exact reviewed license declarations."""

import argparse
import importlib.util
import os
from pathlib import Path
import re
import tarfile
import tempfile


HERE = Path(__file__).resolve().parent
SPEC = importlib.util.spec_from_file_location("native_source_preparer", HERE / "prepare-native-source-projects.py")
P = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(P)
V = P.V


def compiler_inputs(row, source_map_root):
    V.require(source_map_root is not None, "compiler input evidence requires a source map root")
    return V.compiler_input_document(row, lambda name: P.regular(source_map_root, name).read_bytes())[0]


def selected_sources(source_map, source_map_root=None):
    if isinstance(source_map, dict):
        V.require(not source_map.get("unresolved"), "selected object mapping has unresolved sources")
        source_map = source_map.get("sourceMap")
    V.require(isinstance(source_map, list) and source_map, "missing selected object/source mapping")
    selected = {}
    for row in source_map:
        V.require(isinstance(row, dict) and re.fullmatch("[a-f0-9]{64}", row.get("objectSHA256", ""))
                  and isinstance(row.get("sourceFiles"), list) and row["sourceFiles"],
                  "invalid selected object/source mapping")
        sources = row["sourceFiles"]
        if "compilerInputs" in row:
            V.require(source_map_root is not None, "compiler input evidence requires a source map root")
            sources = V.native_source_files(row, lambda name: P.regular(source_map_root, name).read_bytes())
        for source in sources:
            identity, name = V.path(source["project"]), V.path(source["path"])
            V.require(re.fullmatch("[a-f0-9]{64}", source["sha256"]), "invalid selected source digest")
            previous = selected.setdefault(identity, {}).setdefault(name, source["sha256"])
            V.require(previous == source["sha256"], "conflicting selected source bytes")
    return source_map, selected


def in_scope(declaration, name):
    V.require(not declaration.get("scope") or
              "allowedSourcePrefixes" in declaration or "excludedSourcePrefixes" in declaration,
              "reviewed scope requires explicit source prefixes: " + declaration["identity"])
    scopes = {}
    for field in ("allowedSourcePrefixes", "excludedSourcePrefixes"):
        values = declaration.get(field, [])
        V.require(isinstance(values, list), "invalid reviewed source scope")
        for value in values:
            V.require(isinstance(value, str) and value, "empty reviewed source prefix")
            V.path(value[:-1] if value.endswith("/") else value)
        scopes[field] = values
    if "allowedSourcePrefixes" in declaration:
        V.require(any(name.startswith(prefix) for prefix in scopes["allowedSourcePrefixes"]),
                  "selected source is outside reviewed scope: " + name)
    V.require(not any(name.startswith(prefix) for prefix in scopes["excludedSourcePrefixes"]),
              "selected source is excluded from reviewed scope: " + name)


def rebase(value, prefix):
    if isinstance(value, dict):
        result = {key: rebase(child, prefix) for key, child in value.items()}
        if {"path", "sha256", "sizeBytes"} <= value.keys():
            result["path"] = prefix + V.path(value["path"])
        return result
    return [rebase(child, prefix) for child in value] if isinstance(value, list) else value


def retain_source_map(source_map, source_map_root, staging):
    retained_files = {}

    def retain_mapping(value, root=source_map_root, prefix="source-map/", rebase_records=True):
        if isinstance(value, dict):
            result = {key: retain_mapping(child, root, prefix, rebase_records) for key, child in value.items()}
            if {"path", "sha256", "sizeBytes"} <= value.keys():
                original = V.path(value["path"])
                binding = (value["sha256"], value["sizeBytes"])
                name = prefix + original
                if name in retained_files:
                    V.require(retained_files[name] == binding, "conflicting source map evidence")
                else:
                    data = V.bound(value, lambda name: P.regular(root, name).read_bytes())
                    target = staging / name
                    target.parent.mkdir(parents=True, exist_ok=True)
                    target.write_bytes(data)
                    retained_files[name] = binding
                if rebase_records:
                    result["path"] = name
            return result
        return [retain_mapping(child, root, prefix, rebase_records) for child in value] if isinstance(value, list) else value

    def retain_headers(headers, root=source_map_root, prefix="source-map/", rebase_records=True):
        V.require(isinstance(headers, list) and headers, "missing generated-header evidence")
        for header in headers:
            V.require(isinstance(header, dict) and isinstance(header.get("file"), dict)
                      and {"path", "sha256", "sizeBytes"} <= header["file"].keys(),
                      "invalid generated-header file evidence")
            header_metadata = header.get("retainedEvidence")
            V.require(isinstance(header_metadata, list) and header_metadata and all(
                isinstance(item, dict) and isinstance(item.get("file"), dict)
                and {"path", "sha256", "sizeBytes"} <= item["file"].keys() for item in header_metadata),
                "missing retained generated-header compiler evidence")
        return retain_mapping(headers, root, prefix, rebase_records)

    retained_map = []
    for row in source_map:
        retained_row = dict(row)
        if "generatedHeaders" in row:
            retained_row["generatedHeaders"] = retain_headers(row["generatedHeaders"])
        if "compilerInputs" in row:
            inputs = compiler_inputs(row, source_map_root)
            record = row["compilerInputs"]
            parent = Path(V.path(record["path"])).parent
            prefix = "source-map/" + (parent.as_posix() + "/" if parent != Path(".") else "")
            if "generatedHeaders" in inputs:
                retain_headers(inputs["generatedHeaders"], source_map_root / parent, prefix, False)
            for field in ("compilerModuleFiles", "compilerResponseFiles"):
                if field in inputs:
                    retain_mapping(inputs[field], source_map_root / parent, prefix, False)
            retained_row["compilerInputs"] = retain_mapping(record)
        retained_map.append(retained_row)
    return retained_map


def prepare(catalog, source_map, output, sdk_inputs=None, ingredients=None, native_patches=None,
            source_map_root=None, sdk_source_patches=None):
    V.require(catalog.get("kind") == "hostwright.runtime-native-source-licenses.v1"
              and catalog.get("status") == "reviewed-declarations-not-link-qualified",
              "invalid reviewed source license catalog")
    V.require(sdk_inputs is not None or ingredients is not None, "source capture inputs are missing")
    V.require(output.is_absolute() and output.parent.is_dir() and not output.exists() and not output.is_symlink(),
              "reviewed source output must be a new absolute path")
    if source_map_root is not None:
        source_map_root = Path(source_map_root)
        V.require(source_map_root.is_dir() and not source_map_root.is_symlink(), "unsafe source map evidence root")
        source_map_root = source_map_root.resolve()
    source_map, selected = selected_sources(source_map, source_map_root)
    if any("generatedHeaders" in row for row in source_map):
        V.require(source_map_root is not None, "generated-header evidence requires a source map root")
    roots = {}
    for name, directory in (("sdk", sdk_inputs), ("native", ingredients)):
        if directory is not None:
            V.require(directory.is_dir() and not directory.is_symlink(), "unsafe source capture root")
            directory = directory.resolve()
            V.require(not output.resolve().is_relative_to(directory), "source output must be outside inputs")
            roots[name] = directory if name == "sdk" else directory / "evidence"
            V.require(roots[name].is_dir() and not roots[name].is_symlink(), "unsafe source evidence root")
    V.require(native_patches is None or isinstance(native_patches, dict), "invalid native patch ledger")
    native_patches = native_patches or {}
    V.require(sdk_source_patches is None or isinstance(sdk_source_patches, dict), "invalid SDK source patch ledger")
    sdk_source_patches = sdk_source_patches or {}
    declarations, excluded = {}, {}
    for row in catalog.get("excluded", []):
        identity = V.path(row["identity"])
        V.require(identity not in excluded, "duplicate excluded source identity")
        excluded[identity] = row["reason"]
    for group in ("sdk", "guest", "kernel", "containerization"):
        rows = catalog.get(group, []) if group in ("sdk", "guest") else [catalog[group]]
        for row in rows:
            identity = V.path(row["identity"])
            V.require(identity not in declarations and identity not in excluded, "duplicate reviewed source identity")
            declarations[identity] = (group, row)

    captures = {}

    def add_capture(group, identity, directory, embedded=None, patch_records=()):
        identity, directory = V.path(identity), V.path(directory)
        V.require(identity not in captures, "duplicate captured source identity")
        root = roots[group]
        source = V.parse(P.regular(root, directory + "/source.json").read_bytes())
        V.require(embedded is None or embedded == source, "capture catalog differs from retained source.json")
        patches = []
        for record in patch_records:
            V.bound(record, lambda name: P.regular(root, name).read_bytes())
            patches.append(V.path(record["path"]))
        captures[identity] = dict(group=group, directory=directory, source=source, patches=patches)

    if "sdk" in roots:
        build = V.parse(P.regular(roots["sdk"], "build-inputs.json").read_bytes())
        V.require(build.get("kind") == "hostwright.swift-sdk-build-inputs.v1"
                  and build.get("status") == "prepared-not-release-qualified", "invalid SDK source capture")
        sdk_project_ids = set()
        for row in build["sourceProjects"]:
            destination = V.path(row["destination"])
            sdk_project_ids.add(row["identity"])
            V.require(row["identity"] == "swift-sdk/" + destination
                      and row["directory"] == "source-trees/" + destination, "SDK capture destination mismatch")
            V.require(not ("workingTreePatch" in row and row["identity"] in sdk_source_patches),
                      "SDK source patch is already captured")
            patches = [row["workingTreePatch"]] if "workingTreePatch" in row else sdk_source_patches.get(row["identity"], [])
            V.require(isinstance(patches, list) and all(isinstance(item, dict) for item in patches),
                      "invalid SDK source patch records")
            add_capture("sdk", row["identity"], row["directory"], row["source"], patches)
        V.require(set(sdk_source_patches) <= sdk_project_ids, "SDK source patch project is missing")
    if "native" in roots:
        for key in ("kernel", "containerization"):
            row = catalog[key]
            identity = row["identity"]
            if key == "kernel" or identity in selected:
                V.require(identity in native_patches and isinstance(native_patches[identity], list),
                          "missing explicit native applied-patch ledger: " + identity)
                add_capture("native", identity, row["destination"], patch_records=native_patches[identity])
        guest_ids = {identity for identity in selected if declarations.get(identity, (None,))[0] == "guest"}
        if guest_ids:
            prefix = "source-trees/vminit-packages/"
            rows = V.parse(P.regular(roots["native"], prefix + "sources.json").read_bytes())
            for row in rows:
                add_capture("native", row["identity"], prefix + V.path(row["directory"]), row["source"])

    requested = set(selected)
    if "native" in roots:
        requested.add(catalog["kernel"]["identity"])
    queue = list(requested)
    while queue:
        identity = queue.pop()
        V.require(identity not in excluded, "selected source project is excluded: " + identity + "; "
                  + excluded.get(identity, ""))
        V.require(identity in declarations and identity in captures, "selected source project is missing: " + identity)
        for child in captures[identity]["source"].get("submodules", []):
            if child["project"] not in requested:
                requested.add(child["project"])
                queue.append(child["project"])
        reviewed = declarations[identity][1]
        embedded = reviewed.get("embeddedLicenseProjects", [])
        V.require(isinstance(embedded, list), "invalid embedded source license projects: " + identity)
        for dependency in embedded:
            V.require(isinstance(dependency, dict) and
                      set(dependency) == {"identity", "pinPath", "licensePaths"} and
                      isinstance(dependency["licensePaths"], list) and dependency["licensePaths"],
                      "invalid embedded source license declaration: " + identity)
            child_identity = V.path(dependency["identity"])
            V.path(dependency["pinPath"])
            V.require(child_identity in declarations and child_identity in captures and
                      child_identity != identity, "embedded license source project is missing: " + child_identity)
            V.require(len(set(V.path(name) for name in dependency["licensePaths"])) == len(dependency["licensePaths"]),
                      "duplicate embedded source license path: " + child_identity)
            if child_identity not in requested:
                requested.add(child_identity)
                queue.append(child_identity)

    metadata = {name: [] for name in roots}
    for identity in sorted(requested):
        group, reviewed = declarations[identity]
        captured = captures[identity]
        source = captured["source"]
        V.require(source["commit"] == reviewed["commit"], "captured source differs from reviewed commit: " + identity)
        root, directory = roots[captured["group"]], captured["directory"]
        inventory = V.parse(V.bound(source["inventory"], lambda name: P.regular(root, directory + "/" + name).read_bytes()),
                            limit=V.MAX_SOURCE_INVENTORY)
        leaves = {row["path"]: row for row in inventory}
        V.require(len(leaves) == len(inventory), "duplicate captured source leaf")
        documents = reviewed["documents"]
        V.require({row["path"] for row in documents} == set(reviewed["licenses"] + reviewed["notices"])
                  and len({row["path"] for row in documents}) == len(documents), "incomplete reviewed source documents")
        for document in documents:
            name = V.path(document["path"])
            leaf = leaves.get(name)
            V.require(leaf is not None and leaf["gitMode"] != "120000"
                      and all(leaf[key] == document[key] for key in ("sha256", "sizeBytes", "gitBlobSHA1")),
                      "source document differs from reviewed bytes: " + identity + "/" + name)
        for name in selected.get(identity, {}):
            in_scope(reviewed, name)
        declaration = dict(identity=identity, sourceDirectory=directory,
            spdx=reviewed["spdx"], licenses=reviewed["licenses"], notices=reviewed["notices"], patches=captured["patches"])
        if "embeddedLicenseProjects" in reviewed:
            embedded_documents = []
            for dependency in reviewed["embeddedLicenseProjects"]:
                child_identity = dependency["identity"]
                child_group, child_reviewed = declarations[child_identity]
                child_capture = captures[child_identity]
                child_root = roots[child_group]
                child_directory = child_capture["directory"]
                child_archive_record = child_capture["source"]["archive"]
                archive_path = P.regular(child_root, child_directory + "/" + V.path(child_archive_record["path"]))
                with tarfile.open(archive_path, "r:*") as archive:
                    for source_path in dependency["licensePaths"]:
                        source_path = V.path(source_path)
                        document = next((item for item in child_reviewed["documents"]
                                         if item["path"] == source_path), None)
                        V.require(document is not None and source_path in child_reviewed["licenses"] + child_reviewed["notices"],
                                  "embedded document is not a reviewed source license: " + child_identity + "/" + source_path)
                        member = archive.extractfile(source_path)
                        V.require(member is not None, "embedded source license leaf is missing")
                        data = member.read()
                        V.bound(document, lambda _name, data=data: data)
                        embedded_documents.append(dict(sourceProject=child_identity,
                            embeddedPinPath=dependency["pinPath"], embeddedCommit=child_capture["source"]["commit"],
                            sourcePath=source_path, data=data))
            declaration["embeddedLicenseDocuments"] = embedded_documents
        metadata[captured["group"]].append(declaration)

    with tempfile.TemporaryDirectory(prefix=".reviewed-native-sources-", dir=output.parent) as temporary:
        staging = Path(temporary) / "projects"
        staging.mkdir(mode=0o700)
        retained_map = retain_source_map(source_map, source_map_root, staging)
        projects = []
        for group, rows in metadata.items():
            if rows:
                projects.extend(rebase(P.prepare(roots[group], rows, staging / group), group + "/"))
                (staging / group / "projects.json").unlink()
        projects.sort(key=lambda row: row["identity"])
        commits = {row["identity"]: row["commit"] for row in projects}
        fetch = lambda name: P.regular(staging, name).read_bytes()
        source_leaves = {}
        for project in projects:
            identity = project["identity"]
            leaves = V.source_project(project, fetch, commits)
            source_leaves[identity] = leaves
            for name, digest in selected.get(identity, {}).items():
                leaf = leaves.get(name)
                V.require(leaf is not None and leaf["gitMode"] != "120000" and leaf["sha256"] == digest,
                          "selected source differs from captured patched bytes: " + identity + "/" + name)
            reviewed = declarations[identity][1]
            documents = reviewed.get("patchedDocuments", reviewed["documents"])
            expected = {V.path(row["path"]): row for row in documents}
            V.require(len(expected) == len(documents) and set(expected) ==
                      {row["path"] for row in reviewed["documents"]}, "incomplete reviewed patched documents")
            for record in project["licenses"] + project["notices"]:
                if "sourceProject" in record:
                    continue
                document = expected[record["sourcePath"]]
                data = V.bound(record, fetch)
                V.require(record["sha256"] == document["sha256"] and record["sizeBytes"] == document["sizeBytes"]
                          and V.git_object("blob", data) == document["gitBlobSHA1"],
                          "applied patch changes reviewed license/notice bytes: " + identity)
        V.verify_embedded_license_documents(projects, fetch)
        (staging / "projects.json").write_bytes(V.canonical(projects))
        (staging / "source-map.json").write_bytes(V.canonical(retained_map))
        V.require(not output.exists() and not output.is_symlink(), "reviewed source output already exists")
        os.rename(staging, output)
        return projects


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--sdk-inputs", type=Path)
    parser.add_argument("--ingredients", type=Path)
    parser.add_argument("--source-map", type=Path, required=True)
    parser.add_argument("--source-map-root", type=Path,
                        help="Retained mapping evidence root; defaults to the source map's parent")
    parser.add_argument("--native-patches", type=Path,
                        help="JSON project identity to ordered retained patch records, relative to ingredients/evidence")
    parser.add_argument("--sdk-source-patches", type=Path,
                        help="JSON SDK project identity to ordered retained source/license patches, relative to SDK inputs")
    parser.add_argument("--catalog", type=Path, default=HERE / "runtime-native-source-licenses.json")
    parser.add_argument("--output", type=Path, required=True)
    args = parser.parse_args()
    prepare(V.parse(args.catalog.read_bytes()), V.parse(args.source_map.read_bytes()), args.output,
            args.sdk_inputs, args.ingredients, V.parse(args.native_patches.read_bytes()) if args.native_patches else None,
            args.source_map_root or args.source_map.parent,
            V.parse(args.sdk_source_patches.read_bytes()) if args.sdk_source_patches else None)
