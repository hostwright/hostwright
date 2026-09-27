#!/usr/bin/env python3
"""Join actual Swift output maps with selected authenticated SDK object mappings."""

import argparse
import hashlib
import importlib.util
import json
from pathlib import Path
import re
import shlex
import tempfile

HERE = Path(__file__).resolve().parent


def load(name, filename):
    spec = importlib.util.spec_from_file_location(name, HERE / filename)
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


V = load("runtime_verifier", "verify-runtime-provenance.py")
C = load("native_capture", "capture-native-runtime-build.py")
S = load("sdk_capture", "capture-sdk-object-sources.py")
P = load("reviewed_sources", "prepare-reviewed-native-sources.py")


def capture_c_inputs(tree, roots, projects, native, evidence_root, selected, sdk_rows, sdk_root, output, sdk_source_captures=None):
    fetch = lambda name: (evidence_root / V.path(name)).read_bytes()
    sdk_fetch = lambda name: (sdk_root / V.path(name)).read_bytes()
    metadata = {row["originalPath"]: row["file"] for row in native.get("metadata", [])}
    retained = None
    sdk_sources = None
    sdk_headers = {}

    def sdk_index():
        nonlocal sdk_sources
        if sdk_sources is not None:
            return
        sdk_sources = {}
        seen = set()
        captures = sdk_source_captures or sdk_root / "source-trees"
        if captures.is_dir():
            for inventory in sorted(captures.rglob("source-inventory.json")):
                identity = "swift-sdk/" + inventory.parent.relative_to(captures).as_posix()
                for leaf in V.parse(inventory.read_bytes(), limit=V.MAX_SOURCE_INVENTORY):
                    if leaf["gitMode"] == "120000":
                        continue
                    source = dict(project=identity, path=leaf["path"], sha256=leaf["sha256"])
                    sdk_sources.setdefault(source["sha256"], {})[(source["project"], source["path"])] = source
        for row in sdk_rows:
            reference = row.get("compilerInputs")
            key = reference["sha256"] if reference else V.digest(V.canonical(row))
            if key in seen:
                continue
            seen.add(key)
            document, prefix = V.compiler_input_document(row, sdk_fetch) if reference else (row, "")
            for source in document["sourceFiles"]:
                sdk_sources.setdefault(source["sha256"], {})[(source["project"], source["path"])] = source
            for header in document.get("generatedHeaders", []):
                sdk_headers.setdefault((header["file"]["sha256"], Path(header["originalPath"]).name), (header, prefix))

    def retain_sdk(value, prefix):
        if isinstance(value, dict):
            if {"path", "sha256", "sizeBytes"} <= value.keys():
                return retained.retain(V.bound(value, lambda name: sdk_fetch(prefix + name)))
            return {key: retain_sdk(child, prefix) for key, child in value.items()}
        return [retain_sdk(child, prefix) for child in value] if isinstance(value, list) else value

    mappings = {}
    for invocation in native.get("invocations", []):
        if re.fullmatch(r"clang(?:\+\+)?(?:-[0-9]+)?", Path(invocation["executablePath"]).name) is None:
            continue
        arguments = V.parse(V.bound(invocation["argv"], fetch))
        if "-o" in arguments:
            candidate = tree / arguments[arguments.index("-o") + 1]
            if candidate.is_file() and V.digest(candidate.read_bytes()) not in selected:
                continue
        if "-c" not in arguments and not invocation.get("responseFiles"):
            continue
        responses = [dict(row["file"], originalPath=row["originalPath"])
                     for row in invocation.get("responseFiles", [])]
        arguments = V.expand_response_arguments(arguments, responses, fetch, str(tree))
        if "-c" not in arguments or "-o" not in arguments:
            continue
        obj = (tree / arguments[arguments.index("-o") + 1]).resolve(strict=True)
        digest = V.digest(obj.read_bytes())
        if digest not in selected:
            continue
        V.require("-MF" in arguments, "selected C object lacks a compiler dependency file")
        dep = str((tree / arguments[arguments.index("-MF") + 1]).resolve())
        V.require(dep in metadata, "selected C object lacks retained compiler dependencies")
        dep_data = V.bound(metadata[dep], fetch)
        unit = C.source_file(tree / arguments[arguments.index("-c") + 1], roots, projects)
        if retained is None:
            retained = S.RetainedInputs(output.parent / (output.stem + "-inputs"), output.parent)
        evidence = [dict(originalPath=dep, file=retained.retain(dep_data)),
                    dict(kind="compiler-argv", file=retained.retain(V.bound(invocation["argv"], fetch)))]
        evidence.extend(dict(originalPath=row["originalPath"], file=retained.retain(V.bound(row, fetch)))
                        for row in responses)
        with tempfile.NamedTemporaryFile(dir=output.parent) as stream:
            stream.write(dep_data)
            stream.flush()
            dependencies = C.depfile_sources(stream.name)
        sources = {V.canonical(unit): unit}
        headers = []
        for name in sorted(set(dependencies)):
            leaf = (tree / name).resolve(strict=True)
            native_candidates = [(identity, leaf.relative_to(root).as_posix())
                                 for identity, root in roots.items() if leaf.is_relative_to(root)]
            if any(relative in projects[identity] for identity, relative in native_candidates):
                source = C.source_file(leaf, roots, projects)
                sources[V.canonical(source)] = source
                continue
            sdk_index()
            data = leaf.read_bytes()
            sha = V.digest(data)
            matches = sdk_sources.get(sha, {})
            if not data:
                headers.append(dict(originalPath=str(leaf), file=retained.retain(data),
                                    kind="empty-header", compilerArguments=arguments, cwd=str(tree),
                                    evidence=dict(dependencyFile=dep), retainedEvidence=evidence))
            elif matches:
                sources.update((V.canonical(source), source) for source in matches.values())
                headers.append(dict(originalPath=str(leaf), file=retained.retain(data),
                                    kind="copied-header", matchingSources=list(matches.values()),
                                    compilerArguments=arguments, cwd=str(tree),
                                    evidence=dict(dependencyFile=dep), retainedEvidence=evidence))
            else:
                V.require((sha, leaf.name) in sdk_headers, "compiler dependency lacks captured source or SDK generation evidence: " + str(leaf))
                original, prefix = sdk_headers[(sha, leaf.name)]
                header = retain_sdk(original, prefix)
                header["originalPath"] = str(leaf)
                header["retainedEvidence"] += evidence
                headers.append(header)
                for source in header.get("sourceFiles", []) + header.get("matchingSources", []):
                    sources[V.canonical(source)] = source
        value = dict(objectSHA256=digest, sourceFiles=[sources[key] for key in sorted(sources)])
        if headers:
            value["generatedHeaders"] = headers
        row = S.compact_compiler_inputs(value, [unit], retained)
        V.native_source_files(row, lambda name: (output.parent / name).read_bytes())
        prior = mappings.setdefault(digest, row)
        V.require(prior == row, "conflicting captured C compiler inputs")
    return list(mappings.values())


def capture(tree, source_captures, sdk_map_file, sdk_map_root, native_capture_file, output, sdk_source_captures=None):
    for root in (tree, source_captures, sdk_map_root):
        V.require(root.is_dir() and not root.is_symlink(), "unsafe native source-map input root")
    for file in (sdk_map_file, native_capture_file):
        V.require(file.is_file() and not file.is_symlink(), "missing native source-map input")
    V.require(output.is_absolute() and output.parent.is_dir() and not output.exists() and not output.is_symlink(),
              "native source-map output must be a new absolute file")

    catalog = V.parse((HERE / "runtime-native-source-licenses.json").read_bytes())
    sdk_capture = V.parse(sdk_map_file.read_bytes())
    V.require(sdk_capture.get("kind") == "hostwright.sdk-object-sources.v1"
              and sdk_capture.get("status") == "partial-not-release-qualified", "invalid SDK object source capture")
    native_capture = V.parse(native_capture_file.read_bytes())
    V.require(native_capture.get("status") == "prepared-not-release-qualified"
              and native_capture.get("kind") == "swift", "invalid native Swift build capture")

    projects = {}
    roots = {}

    def add_project(identity, directory, capture_directory, current_root):
        capture_root = source_captures / capture_directory
        inventory = V.parse((capture_root / "source-inventory.json").read_bytes())
        rows = {row["path"]: row for row in inventory}
        V.require(rows and len(rows) == len(inventory), "invalid captured source inventory: " + identity)
        current_root = current_root.resolve(strict=True)
        roots[identity] = current_root
        # Hash live tracked bytes so applied, explicitly retained source patches are represented here.
        # Reviewed source preparation later binds every selected row to the captured patch chain.
        leaves = {}
        for relative, record in rows.items():
            candidate = current_root / relative
            if not candidate.is_file() or candidate.is_symlink():
                continue
            leaves[relative] = dict(project=identity, path=relative,
                                    sha256=hashlib.sha256(candidate.read_bytes()).hexdigest(),
                                    gitMode=record["gitMode"])
        projects[identity] = leaves

    containerization = catalog["containerization"]["identity"]
    container_root = tree.parent.resolve(strict=True)
    add_project(containerization, "containerization", "containerization", container_root)
    package_rows = V.parse((source_captures / "vminit-packages" / "sources.json").read_bytes())
    package_roots = {}
    for row in package_rows:
        checkout = tree / ".build" / "checkouts" / row["directory"]
        if checkout.is_dir():
            package_roots[row["identity"]] = checkout
    pending = {row["identity"]: row for row in package_rows if row["identity"] not in package_roots}
    while pending:
        progressed = False
        for identity, row in list(pending.items()):
            for parent in package_rows:
                parent_root = package_roots.get(parent["identity"])
                if parent_root is None:
                    continue
                child = next((item for item in parent["source"].get("submodules", [])
                              if item["project"] == identity), None)
                if child is None:
                    continue
                candidate = parent_root / child["path"]
                if candidate.is_dir():
                    package_roots[identity] = candidate
                    del pending[identity]
                    progressed = True
                    break
        V.require(progressed, "missing package or submodule checkout for " + ", ".join(sorted(pending)))
    for row in package_rows:
        identity = row["identity"]
        add_project(identity, row["directory"], "vminit-packages/" + row["directory"],
                    package_roots[identity])

    selected_inputs = [row for link in native_capture.get("links", []) for row in link.get("selectedInputs", [])]
    V.require(selected_inputs, "native Swift links have no retained selected inputs")
    selected_local = {row["objectSHA256"] for row in selected_inputs
                      if re.fullmatch(r".+\.a\([^()]+\)", row["mapInput"]) is None}
    local_mappings = []
    output_maps = sorted(tree.rglob("output-file-map.json"))
    V.require(output_maps, "Swift build emitted no output-file maps")
    for mapping in output_maps:
        entries = V.parse(mapping.read_bytes())
        selected_entries = {}
        for source, mapped_output in entries.items():
            if "object" not in mapped_output:
                continue
            object_path = (mapping.parent / mapped_output["object"]).resolve()
            if object_path.is_file() and V.digest(object_path.read_bytes()) in selected_local:
                selected_entries[source] = dict(mapped_output, object=str(object_path.resolve()))
        if not selected_entries:
            continue
        source_list = mapping.parent / "sources"
        with tempfile.NamedTemporaryFile(mode="wb", dir=output.parent, prefix=".runtime-map-", suffix=".json") as stream:
            stream.write(V.canonical(selected_entries))
            stream.flush()
            rows = C.source_map_from_swift_output_map(stream.name, roots, projects,
                                                      source_list if source_list.is_file() else None,
                                                      tree)
        local_mappings.extend(rows)
    local_mappings.extend(capture_c_inputs(tree, roots, projects, native_capture,
                                           native_capture_file.parent, selected_local,
                                           sdk_capture["sourceMap"], sdk_map_root, output, sdk_source_captures))

    selected_sdk = {}
    available_sdk = {}
    for row in sdk_capture.get("sourceMap", []):
        available_sdk.setdefault(row["objectSHA256"], []).append(row)
    for selected in selected_inputs:
        name = selected["mapInput"]
        candidates = available_sdk.get(selected["objectSHA256"], [])
        if not candidates:
            V.require(any(row["objectSHA256"] == selected["objectSHA256"] for row in local_mappings),
                      "selected native object has no source mapping: " + name)
            continue
        attributions = {V.canonical({key: value for key, value in row.items() if key != "mapInput"})
                        for row in candidates}
        V.require(len(attributions) == 1,
                  "selected SDK object has missing or ambiguous source mapping: " + name)
        row = dict(candidates[0])
        if re.fullmatch(r".+\.a\([^()]+\)", name):
            row["mapInput"] = name
        selected_sdk.setdefault((row["objectSHA256"], row.get("mapInput")), row)

    combined = local_mappings + [selected_sdk[key] for key in sorted(selected_sdk)]
    V.require(combined, "no actual native object/source mappings were captured")
    digests = {}
    for row in combined:
        key = (row["objectSHA256"], row.get("mapInput"))
        previous = digests.setdefault(key, row)
        V.require(previous == row, "conflicting object/source mapping")

    combined = local_mappings + P.retain_source_map(
        [selected_sdk[key] for key in sorted(selected_sdk)], sdk_map_root, output.parent)
    combined.sort(key=V.canonical)
    with output.open("xb") as stream:
        stream.write(V.canonical(combined))
    return combined


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--tree", type=Path, required=True)
    parser.add_argument("--source-captures", type=Path, required=True)
    parser.add_argument("--sdk-object-sources", type=Path, required=True)
    parser.add_argument("--sdk-source-map-root", type=Path, required=True)
    parser.add_argument("--sdk-source-captures", type=Path)
    parser.add_argument("--native-capture", type=Path, required=True)
    parser.add_argument("--output", type=Path, required=True)
    args = parser.parse_args()
    result = capture(args.tree, args.source_captures, args.sdk_object_sources,
                     args.sdk_source_map_root, args.native_capture, args.output, args.sdk_source_captures)
    print(json.dumps({"mappedObjects": len(result), "output": str(args.output)}, sort_keys=True))
