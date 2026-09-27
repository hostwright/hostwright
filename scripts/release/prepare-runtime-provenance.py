#!/usr/bin/env python3
"""Join captured runtime builds into the exact pre-attestation source closure."""

import argparse
import copy
import importlib.util
import os
from pathlib import Path
import re
import shutil
import tempfile


HERE = Path(__file__).resolve().parent


def load(name, filename):
    spec = importlib.util.spec_from_file_location(name, HERE / filename)
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


V = load("runtime_verifier", "verify-runtime-provenance.py")
A = load("runtime_assembler", "assemble-runtime-provenance.py")
ASSETS = ("kata-linux-kernel", "apple-vminit-oci", "hostwright-netfilter-loader")


def regular(root, name):
    candidate = root
    for part in V.path(name).split("/"):
        candidate = candidate / part
        V.require(not candidate.is_symlink(), "symlink in runtime input: " + name)
    V.require(candidate.is_file() and candidate.resolve().is_relative_to(root.resolve()),
              "missing regular runtime input: " + name)
    return candidate


def rebase(value, prefix):
    if isinstance(value, dict):
        result = {key: rebase(child, prefix) for key, child in value.items()}
        if {"path", "sha256", "sizeBytes"} <= result.keys():
            result["path"] = prefix + V.path(result["path"])
        return result
    if isinstance(value, list):
        return [rebase(child, prefix) for child in value]
    return value


def identity_bytes(value):
    """Storage locations may differ; every captured byte and other field must agree."""
    if isinstance(value, dict):
        result = {key: identity_bytes(child) for key, child in value.items()}
        if {"path", "sha256", "sizeBytes"} <= result.keys():
            result["path"] = "evidence"
        return result
    if isinstance(value, list):
        return [identity_bytes(child) for child in value]
    return value


def merge(items, keys, fetch):
    result, seen = [], [{} for _ in keys]
    for item in items:
        previous = [index[item[key]] for key, index in zip(keys, seen) if item[key] in index]
        if previous:
            V.require(all(identity_bytes(other) == identity_bytes(item) for other in previous),
                      "conflicting runtime " + keys[0] + ": " + str(item[keys[0]]))
            # Check discarded duplicate evidence too; equal metadata alone is insufficient.
            for record in A.records(item).values():
                V.bound(record, fetch)
            continue
        result.append(item)
        for key, index in zip(keys, seen):
            index[item[key]] = item
    return result


def licensing(projects, kernel, oci, loader):
    if loader.get("format") == "go-buildinfo-v1":
        loader_components = {loader["project"], loader["goRuntimeProject"]} | {
            item["project"] for item in loader["modules"]}
    else:
        loader_components = {source["project"] for item in loader["selectedInputs"]
                             for source in item["sourceFiles"]}
    components = {
        "kata-linux-kernel": {kernel["project"]},
        "apple-vminit-oci": {component for item in oci["files"] for component in item["components"]},
        "hostwright-netfilter-loader": loader_components,
    }
    projects = {item["identity"]: item for item in projects}
    mappings, assets = {}, []
    for identity in ASSETS:
        V.require(components[identity] and components[identity] <= projects.keys(),
                  "missing runtime source component: " + identity)
        mappings[identity] = []
        expressions = set()
        for component in sorted(components[identity]):
            project = projects[component]
            expressions.add(V.spdx(project["spdx"]))
            mappings[identity].append(dict(project=component, spdx=project["spdx"],
                licenses=sorted(record["path"] for record in project["licenses"]),
                notices=sorted(record["path"] for record in project["notices"])))
        expressions = sorted(expressions)
        expression = expressions[0] if len(expressions) == 1 else "(" + " AND ".join(
            "(" + value + ")" for value in expressions) + ")"
        assets.append(dict(identity=identity, status="qualified", blockers=[], licenseExpression=expression))
    return mappings, dict(kind="hostwright.runtime-license-inventory.v1", schemaVersion=1,
                          status="qualified", assets=assets)


def rebase_loader(value, fetch, generated):
    result = rebase(value, "loader/")
    if value.get("format") == "go-buildinfo-v1":
        raw = V.bound(value["packageTrace"], lambda name: fetch("loader/" + name))
        trace = V.canonical(rebase(V.parse(raw), "loader/"))
        record = result["packageTrace"]
        generated[record["path"]] = trace
        record.update(sha256=V.digest(trace), sizeBytes=len(trace))
    return result


def prepare(native_root, loader_root, source_commit, run_id, attempt, output):
    V.require(re.fullmatch("[a-f0-9]{40}", source_commit) is not None, "invalid source commit")
    producer = dict(commit=source_commit, runID=run_id, attempt=attempt)
    V.producer_binding(producer, source_commit)
    roots = {}
    for name, root in (("native", native_root), ("loader", loader_root)):
        V.require(not root.is_symlink() and root.is_dir(), "unsafe runtime input root")
        roots[name] = root.resolve(strict=True)
    V.require(not output.exists() and not output.is_symlink(), "runtime output already exists")
    output = output.absolute()
    V.require(all(not output.resolve().is_relative_to(root) for root in roots.values()),
              "runtime output must be outside input roots")
    generated = {}

    def input_file(name):
        prefix, separator, relative = V.path(name).partition("/")
        V.require(separator and prefix in roots, "unbound runtime evidence path: " + name)
        return regular(roots[prefix], relative)

    def fetch(name):
        return generated[name] if name in generated else input_file(name).read_bytes()

    native = V.parse(fetch("native/native-provenance.json"))
    loader_fragment = V.parse(fetch("loader/loader-provenance.json"))
    for fragment in (native, loader_fragment):
        V.require(fragment.get("status") == "prepared-not-release-qualified" and
                  fragment.get("sourceCommit") == source_commit, "runtime fragment source/status mismatch")
    projects = merge([*(rebase(item, "native/") for item in native["sourceProjects"]),
                      *(rebase(item, "loader/") for item in loader_fragment["sourceProjects"])],
                     ("identity",), fetch)
    loader_tools = loader_fragment.get("toolchain")
    if loader_tools is None:
        tool_file = roots["loader"] / "loader-toolchain.json"
        loader_tools = V.parse(fetch("loader/loader-toolchain.json")) if tool_file.exists() or tool_file.is_symlink() else []
    V.require(isinstance(loader_tools, list), "loader toolchain must be a list")
    if loader_fragment["loader"].get("format") == "go-buildinfo-v1":
        V.require(loader_tools, "missing captured Go toolchain records")
    tools = merge([*rebase(native["toolchain"], "native/"), *rebase(loader_tools, "loader/")],
                  ("identity", "executablePath"), fetch)
    kernel = rebase(native["kernel"], "native/")
    oci = dict(prefix=native["oci"]["prefix"], links=rebase(native["oci"]["links"], "native/"),
               files=copy.deepcopy(native["oci"]["files"]))

    loader = rebase_loader(loader_fragment["loader"], fetch, generated)
    payload_records = copy.deepcopy(native["payloads"])
    payloads = {}
    for record in payload_records:
        V.require(record["path"] not in payloads, "duplicate native payload")
        payloads[record["path"]] = V.bound(record, lambda name: fetch("native/" + name))
    loader_data = fetch("loader/capture-first/payload")
    V.require(loader["path"] not in payloads, "native fragment contains the loader payload")
    payloads[V.path(loader["path"])] = loader_data
    payload_records.append(dict(path=loader["path"], sha256=V.digest(loader_data), sizeBytes=len(loader_data)))
    mappings, inventory = licensing(projects, kernel, oci, loader)
    manifest = dict(kind=V.KIND, schemaVersion=1, closureMode="new-source-build", sourceCommit=source_commit,
                    producer=producer, runtimeInventorySHA256=V.digest(V.canonical(inventory)),
                    payloads=sorted(payload_records, key=lambda item: item["path"]),
                    sourceProjects=sorted(projects, key=lambda item: item["identity"]),
                    toolchain=tools, kernel=kernel, oci=oci, loader=loader, licensing=mappings)
    if "reproducibleBuild" in loader_fragment:
        V.require(fetch("loader/capture-second/payload") == loader_data, "Go loader rebuilds differ")
        second = dict(manifest, loader=rebase_loader(loader_fragment["reproducibleBuild"], fetch, generated))
        V.verify(V.canonical(second), inventory, payloads, fetch, source_commit, require_authentication=False)
    elif loader.get("format") == "go-buildinfo-v1":
        raise ValueError("missing reproducible Go loader build")
    receipt_data = fetch("native/upstream/kernel-source-signature.json")
    receipt = V.parse(receipt_data)
    V.require(receipt.get("kind") == "hostwright.kernel-source-signature.v1" and
              receipt.get("archiveSHA256") == "7c716216c3c4134ed0de69195701e677577bbcdd3979f331c182acd06bf2f170" and
              receipt.get("fingerprint") == "647F28654894E3BD457199BE38DBBDC86092693E" and
              receipt.get("signatureVerified") is True and receipt.get("exitStatus") == 0,
              "kernel upstream signature receipt is not qualified")
    output.parent.mkdir(parents=True, exist_ok=True)
    with tempfile.TemporaryDirectory(prefix=".runtime-provenance-", dir=output.parent) as temporary:
        staging = Path(temporary) / "prepared"
        staging.mkdir()

        def write(name, data):
            filename = staging / V.path(name)
            filename.parent.mkdir(parents=True, exist_ok=True)
            with filename.open("xb") as stream:
                stream.write(data)

        layer_records = {(item["path"], item["sha256"], item["sizeBytes"]) for item in oci["files"]}
        payload_names = set(payloads)
        for name, record in A.evidence_records(manifest, fetch).items():
            if (name, record["sha256"], record["sizeBytes"]) in layer_records:
                continue
            if name in payload_names:
                write("runtime-provenance/payloads/" + name, payloads[name])
            elif name in generated:
                write(name, generated[name])
            else:
                destination = staging / name
                destination.parent.mkdir(parents=True, exist_ok=True)
                shutil.copyfile(input_file(name), destination)
            stored = "runtime-provenance/payloads/" + name if name in payload_names else name
            V.bound(record, lambda _, stored=stored: regular(staging, stored).read_bytes())
        manifest_data = V.canonical(manifest)
        write("runtime-provenance/manifest.json", manifest_data)
        write("licenses/runtime-license-inventory.json", V.canonical(inventory))
        write("upstream/kernel-source-signature.json", receipt_data)
        V.verify(manifest_data, inventory, payloads, lambda name: regular(staging, name).read_bytes(),
                 source_commit, require_authentication=False)
        V.require(not output.exists() and not output.is_symlink(), "runtime output already exists")
        os.rename(staging, output)
    return manifest


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--native-root", type=Path, required=True)
    parser.add_argument("--loader-root", type=Path, required=True)
    parser.add_argument("--source-commit", required=True)
    parser.add_argument("--run-id", type=int, required=True)
    parser.add_argument("--attempt", type=int, required=True)
    parser.add_argument("--output", type=Path, required=True)
    args = parser.parse_args()
    prepare(args.native_root, args.loader_root, args.source_commit, args.run_id, args.attempt, args.output)
