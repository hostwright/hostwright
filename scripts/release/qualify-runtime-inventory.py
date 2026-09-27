#!/usr/bin/env python3
"""Regenerate runtime license artifacts from locally verified build evidence."""

import argparse
import copy
import hashlib
import importlib.util
import io
import json
import os
from pathlib import Path
import subprocess
import tarfile
import tempfile


HERE = Path(__file__).resolve().parent


def load(name, filename):
    spec = importlib.util.spec_from_file_location(name, HERE / filename)
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


V = load("runtime_inventory_verifier", "verify-runtime-provenance.py")
NOTICES = load("runtime_inventory_notice_validator", "validate-third-party-notices.py")
ASSETS = ("kata-linux-kernel", "apple-vminit-oci", "hostwright-netfilter-loader")
RUNTIME_INVENTORY = "runtime-license-inventory.json"
THIRD_PARTY_INVENTORY = "third-party-license-inventory.json"
NOTICES_FILE = "THIRD_PARTY_NOTICES"
CONFIG_PATH = "ThirdPartyLicenses/runtime-build-recipes/kernel-actual-config-6.18.15-186"
CONFIG_DOC_PATH = "runtime-build-recipe/kernel-actual-config-6.18.15-186"
SOURCE_DOCUMENTS = "ThirdPartyLicenses/runtime-build-recipes/source-documents.json"
SOURCE_CONFIG_PATH = "kernel-actual-config-6.18.15-186"


def regular(root, relative):
    candidate = Path(root)
    for part in V.path(relative).split("/"):
        candidate /= part
        V.require(not candidate.is_symlink(), "symlink in runtime inventory input: " + relative)
    V.require(candidate.is_file() and candidate.resolve().is_relative_to(Path(root).resolve()),
              "missing regular runtime inventory input: " + relative)
    return candidate


def read_json(root, relative):
    return V.parse(regular(root, relative).read_bytes())


def sha(data):
    return hashlib.sha256(data).hexdigest()


def verify_prepared_evidence(prepared_root):
    """Run the full provenance verifier with auth disabled for local review input."""
    manifest_data = regular(prepared_root, "runtime-provenance/manifest.json").read_bytes()
    manifest = V.parse(manifest_data)
    runtime = read_json(prepared_root, "licenses/runtime-license-inventory.json")

    def fetch(name):
        return regular(prepared_root, name).read_bytes()

    payloads = {
        V.path(record["path"]): fetch("runtime-provenance/payloads/" + V.path(record["path"]))
        for record in manifest["payloads"]
    }
    result = V.verify(manifest_data, runtime, payloads, fetch, manifest["sourceCommit"],
                      require_authentication=False)
    return manifest, runtime, manifest_data, payloads, fetch, result


def source_project_data(project, fetch):
    record = project["archive"]
    archive_data = V.bound(record, fetch)
    inventory = V.parse(V.bound(project["inventory"], fetch), limit=V.MAX_SOURCE_INVENTORY)
    with tarfile.open(fileobj=io.BytesIO(archive_data), mode="r:*") as archive:
        members = {V.path(member.name): member for member in archive.getmembers() if member.isfile()}
        V.require(len(members) == sum(member.isfile() for member in archive.getmembers()),
                  "duplicate captured source archive entry")
        result = {}
        for leaf in inventory:
            name = V.path(leaf["path"])
            V.require(name in members, "captured source archive omits an inventory leaf")
            data = archive.extractfile(members[name]).read()
            V.require(len(data) == leaf["sizeBytes"] and sha(data) == leaf["sha256"],
                      "captured source leaf differs from its exact inventory")
            result[name] = data
        V.require(set(result) == set(members), "captured source archive/inventory coverage mismatch")
        return result


def verify_root_guest_bindings(source_root, third_party, runtime, manifest, fetch):
    """Require current host locks and loader sources to agree with retained records."""
    NOTICES.verify(source_root, require_qualified=False)
    resolved = regular(source_root, "Package.resolved").read_bytes()
    V.require(sha(resolved) == third_party["resolvedSHA256"],
              "root Package.resolved differs from its exact host dependency inventory")
    head = subprocess.check_output(
        ["git", "-C", str(Path(source_root).resolve()), "rev-parse", "HEAD"], text=True).strip()
    V.require(head == manifest["sourceCommit"], "source root HEAD differs from the prepared runtime source commit")
    hostwright = next((project for project in manifest["sourceProjects"]
                       if project["identity"] == manifest["loader"]["project"]), None)
    V.require(hostwright is not None and hostwright["commit"] == manifest["sourceCommit"],
              "prepared loader source revision differs from the accepted source commit")
    retained = runtime["retainedLoaderSourceFiles"]
    V.require(len(retained) == 20, "retained loader source inventory is incomplete")
    source_leaves = source_project_data(hostwright, fetch)
    for name, digest in retained.items():
        data = regular(source_root, name).read_bytes()
        V.require(sha(data) == digest and name in source_leaves and sha(source_leaves[name]) == digest,
                  "root loader source differs from the prepared exact source tree: " + name)
    for name, field in (("Guest/HostwrightNetfilter/go.mod", "goModuleSHA256"),
                        ("Guest/HostwrightNetfilter/go.sum", "goSumSHA256")):
        data = regular(source_root, name).read_bytes()
        V.require(sha(data) == runtime[field] and name in source_leaves and sha(source_leaves[name]) == sha(data),
                  "root Go dependency lock differs from the prepared exact source tree: " + name)
    return result


def add_document(notices, records, category, source_path, data, source_paths):
    V.require(data and source_paths, "empty runtime source document or provenance")
    heading = ("\n\n--- " + source_path + " ---\n").encode()
    notices.extend(heading)
    offset = len(notices)
    notices.extend(data)
    records.append(dict(category=category, offsetBytes=offset, sha256=sha(data),
                        sizeBytes=len(data), sourcePath=source_path,
                        sourcePaths=sorted(set(source_paths))))


def bind_notice_digests(notices, third_party, runtime):
    digest = sha(bytes(notices))
    third_party["noticesSHA256"] = digest
    runtime["noticesSHA256"] = digest
    documents = [document for dependency in third_party["dependencies"]
                 for document in dependency["documents"]] + third_party["runtimeDocuments"]
    for document in documents:
        start = document["offsetBytes"]
        end = start + document["sizeBytes"]
        V.require(0 <= start <= end <= len(notices) and sha(notices[start:end]) == document["sha256"],
                  "notice document offset or digest mismatch")
    V.require(runtime["noticesSHA256"] == third_party["noticesSHA256"],
              "runtime and third-party notice digests disagree")
    return digest


def payload_file_records(manifest, payloads, loader_path):
    expected = {V.path(record["path"]): record for record in manifest["payloads"]}
    V.require(len(expected) == len(manifest["payloads"]) and set(expected) == set(payloads),
              "runtime payload file coverage differs from the verified manifest")
    records = []
    for path, record in sorted(expected.items()):
        data = payloads[path]
        V.require(sha(data) == record["sha256"] and len(data) == record["sizeBytes"],
                  "runtime payload bytes differ from the verified manifest: " + path)
        records.append(dict(path=path, sha256=record["sha256"], sizeBytes=record["sizeBytes"],
                            mode=0o755 if path == loader_path else 0o644))
    return records


def regenerate(prepared_root, source_root):
    manifest, prepared_inventory, manifest_data, payloads, fetch, verification = verify_prepared_evidence(prepared_root)
    third_party = read_json(source_root, THIRD_PARTY_INVENTORY)
    runtime = read_json(source_root, RUNTIME_INVENTORY)
    notices = bytearray(regular(source_root, NOTICES_FILE).read_bytes())
    verify_root_guest_bindings(source_root, third_party, runtime, manifest, fetch)
    manifest_hash = sha(manifest_data)

    # Replace only the stale embedded kernel configuration document; retain all
    # host and pre-existing runtime notice bytes and their source attribution.
    config = V.substantive(manifest["kernel"]["config"], fetch)
    config_record = next((record for record in third_party["runtimeDocuments"]
                          if record["sourcePath"] == CONFIG_DOC_PATH), None)
    V.require(config_record is not None, "existing runtime notice inventory lacks the kernel configuration")
    start = config_record["offsetBytes"]
    end = start + config_record["sizeBytes"]
    V.require(sha(notices[start:end]) == config_record["sha256"],
              "existing kernel configuration notice does not match its inventory")
    notices = notices[:start] + bytearray(config) + notices[end:]
    delta = len(config) - config_record["sizeBytes"]
    config_record.update(sha256=sha(config), sizeBytes=len(config),
                         sourcePaths=["embedded-IKCFG_ST:sha256:" + manifest["kernel"]["outputSHA256"],
                                      "runtime-provenance/manifest.json#sha256=" + manifest_hash])
    for record in third_party["runtimeDocuments"]:
        if record is not config_record and record["offsetBytes"] >= end:
            record["offsetBytes"] += delta

    projects = {project["identity"]: project for project in manifest["sourceProjects"]}
    license_documents = {}
    for identity in ASSETS:
        V.require(identity in manifest["licensing"], "runtime manifest lacks a licensed asset: " + identity)
        for mapping in manifest["licensing"][identity]:
            project = projects[mapping["project"]]
            V.require(mapping["spdx"] == project["spdx"], "runtime project SPDX mapping changed")
            archive = project["archive"]
            for field in ("licenses", "notices"):
                expected_paths = set(mapping[field])
                actual_records = {record["path"]: record for record in project[field]}
                V.require(expected_paths == set(actual_records),
                          "runtime license mapping differs from captured project documents")
                for evidence_path in sorted(expected_paths):
                    item = actual_records[evidence_path]
                    data = V.substantive(item, fetch)
                    key = (project["identity"], item["sourcePath"], item["sha256"])
                    license_documents.setdefault(key, dict(project=project, item=item, data=data,
                                                           assets=set(), categories=set()))
                    license_documents[key]["assets"].add(identity)
                    license_documents[key]["categories"].add(field)

    records = third_party["runtimeDocuments"]
    for (project_identity, source_name, document_hash), entry in sorted(license_documents.items()):
        project, item, data = entry["project"], entry["item"], entry["data"]
        expected_hash = (item["sha256"], item["sizeBytes"])
        V.require((sha(data), len(data)) == expected_hash and document_hash == item["sha256"],
                  "captured runtime license bytes mismatch")
        kind = "kernel" if "kata-linux-kernel" in entry["assets"] else (
            "loader" if "hostwright-netfilter-loader" in entry["assets"] else "native")
        output_path = "runtime-source/" + project_identity + "@" + project["commit"] + "/" + source_name
        source_paths = [
            "git-object:" + project_identity + "@" + project["commit"] + ":" + source_name,
            "prepared-local-source-coverage:runtime-provenance/manifest.json#sha256=" + manifest_hash,
            "prepared-local-source-coverage:runtime-provenance/" + project["archive"]["path"] +
            "#sha256=" + project["archive"]["sha256"] + "&sizeBytes=" + str(project["archive"]["sizeBytes"]),
        ]
        add_document(notices, records, "runtime-" + kind + "-license", output_path, data, source_paths)

    third_party["runtimeDocuments"] = records
    bind_notice_digests(notices, third_party, runtime)

    kernel_path = manifest["kernel"]["payloadPath"]
    loader_path = manifest["loader"]["path"]
    oci_prefix = "share/hostwright/containerization/vminit/"
    oci_paths = sorted(name for name in payloads if name.startswith(oci_prefix))
    V.require({kernel_path, loader_path} <= set(payloads) and len(oci_paths) == 5,
              "runtime payload inventory is incomplete")
    oci_prefix_blob = oci_prefix + "blobs/sha256/"
    index = V.parse(payloads[oci_prefix + "index.json"])
    V.require(len(index.get("manifests", [])) == 1, "OCI index does not identify one direct image manifest")
    descriptor = index["manifests"][0]
    descriptor_digest = descriptor["digest"].removeprefix("sha256:")
    oci_manifest_path = oci_prefix_blob + descriptor_digest
    V.require(oci_manifest_path in payloads and descriptor["size"] == len(payloads[oci_manifest_path]) and
              sha(payloads[oci_manifest_path]) == descriptor_digest,
              "direct OCI image manifest descriptor differs from the retained payload")
    oci_manifest = V.parse(payloads[oci_manifest_path])
    config_digest = oci_manifest["config"]["digest"].removeprefix("sha256:")
    layer_digest = oci_manifest["layers"][0]["digest"].removeprefix("sha256:")
    kernel_data = payloads[kernel_path]
    loader_data = payloads[loader_path]
    V.require(sha(kernel_data) == manifest["kernel"]["outputSHA256"] and
              sha(loader_data) == manifest["loader"]["outputSHA256"], "runtime payload digest mismatch")

    current_assets = {asset["identity"]: asset for asset in runtime["assets"]}
    V.require(set(current_assets) == set(ASSETS), "root runtime inventory asset set changed")
    source_evidence = {}
    signature_path = "upstream/kernel-source-signature.json"
    signature_data = regular(prepared_root, signature_path).read_bytes()
    signature = V.parse(signature_data)
    V.require(signature.get("signatureVerified") is True and signature.get("exitStatus") == 0 and
              signature.get("archiveSHA256") == runtime["kernelSourceEvidence"]["sourceArchiveSHA256"],
              "retained kernel source signature does not bind the recorded upstream archive")
    for identity in ASSETS:
        refs = ["prepared-local-source-coverage:runtime-provenance/manifest.json#sha256=" + manifest_hash]
        if identity == "kata-linux-kernel":
            refs.append("prepared-local-source-coverage:" + signature_path + "#sha256=" + sha(signature_data))
        for mapping in manifest["licensing"][identity]:
            project = projects[mapping["project"]]
            archive = project["archive"]
            refs.append("prepared-local-source-coverage:runtime-provenance/" + archive["path"] +
                        "#sha256=" + archive["sha256"] + "&sizeBytes=" + str(archive["sizeBytes"]))
        source_evidence[identity] = sorted(set(refs))

    asset_values = {
        "kata-linux-kernel": (kernel_path, sha(kernel_data), len(kernel_data)),
        "apple-vminit-oci": (oci_manifest_path, sha(payloads[oci_manifest_path]), len(payloads[oci_manifest_path])),
        "hostwright-netfilter-loader": (loader_path, sha(loader_data), len(loader_data)),
    }
    for identity, (path, digest, size) in asset_values.items():
        asset = current_assets[identity]
        asset.update(payloadPaths=([path] if identity != "apple-vminit-oci" else oci_paths),
                     sha256=digest, sizeBytes=size,
                     licenseExpression=next(row["licenseExpression"] for row in prepared_inventory["assets"]
                                            if row["identity"] == identity),
                     status="qualified", blockers=[],
                     sourceDistributionEvidence=source_evidence[identity])

    # Refresh root build identities from the exact verified payloads and retained
    # compiler/build records after full offline source and license verification.
    framework = next(project for project in manifest["sourceProjects"] if project["identity"] == "containerization")
    framework_leaves = source_project_data(framework, fetch)
    resolved_data = framework_leaves["vminitd/Package.resolved"]
    resolved = V.parse(resolved_data)
    runtime.update(
        frameworkVersion=runtime["frameworkVersion"], frameworkRevision=framework["commit"],
        initImageReference="untagged@sha256:" + sha(payloads[oci_manifest_path]),
        initImageConfigurationSHA256=config_digest, initImageLayerSHA256=layer_digest,
        guestResolvedSHA256=sha(resolved_data),
        guestDependencies=[dict(identity=pin["identity"], location=pin["location"],
                                revision=pin["state"]["revision"], version=pin["state"].get("version", ""))
                           for pin in resolved["pins"]],
        retainedLoaderSourceRevision=manifest["loader"]["moduleRevisions"].get(
            manifest["loader"]["project"], manifest["sourceCommit"]),
        retainedLoaderBinarySHA256=sha(loader_data),
        retainedLoaderLinkedModules=[],
        status="qualified",
    )
    version, modules = V.go_build_info(loader_data)
    runtime["goVersion"] = version
    go_deps = {(item["module"], item["version"]): item for item in runtime["goDependencies"]}
    linked = []
    for module in modules:
        if len(module) != 3:
            continue
        key = (module[0], module[1])
        V.require(key in go_deps and go_deps[key]["checksum"] == module[2],
                  "Go binary module metadata differs from the retained dependency lock")
        linked.append(copy.deepcopy(go_deps[key]))
    V.require(len(linked) == 6, "Go runtime metadata lacks its exact six linked modules")
    runtime["retainedLoaderLinkedModules"] = sorted(linked, key=lambda item: item["module"])
    runtime["retainedLoaderBuildSettings"].update({"GOOS": "linux", "GOARCH": "arm64", "CGO_ENABLED": "0"})
    tool_versions = {tool["identity"]: V.substantive(tool["version"], fetch).decode("utf-8").strip()
                     for tool in manifest["toolchain"] if tool["identity"] in ("compiler", "linker")}
    V.require(set(tool_versions) == {"compiler", "linker"}, "kernel compiler or linker version evidence is missing")
    kernel_evidence = runtime["kernelSourceEvidence"]
    kernel_evidence.update(
        actualConfigurationSHA256=sha(config), actualConfigurationSizeBytes=len(config),
        compiler=tool_versions["compiler"], linker=tool_versions["linker"],
    )
    runtime.pop("kernelArchiveURL", None)
    runtime.pop("kernelArchiveSHA256", None)
    runtime["payloadFiles"] = payload_file_records(manifest, payloads, loader_path)
    V.require(len(runtime["payloadFiles"]) == 7, "runtime manifest does not contain the exact seven shipped payloads")

    source_documents = read_json(source_root, SOURCE_DOCUMENTS)
    source_config = next((record for record in source_documents
                          if record["path"] == SOURCE_CONFIG_PATH), None)
    V.require(source_config is not None, "kernel source document index lacks the configuration record")
    source_config.update(sha256=sha(config), sizeBytes=len(config),
                         url="embedded-IKCFG_ST:sha256:" + manifest["kernel"]["outputSHA256"])

    outputs = {
        NOTICES_FILE: bytes(notices),
        THIRD_PARTY_INVENTORY: V.canonical(third_party),
        RUNTIME_INVENTORY: V.canonical(runtime),
        SOURCE_DOCUMENTS: V.canonical(source_documents),
        CONFIG_PATH: config,
    }
    V.require(sha(outputs[NOTICES_FILE]) == third_party["noticesSHA256"] == runtime["noticesSHA256"],
              "generated notice digest coverage mismatch")
    return outputs, verification


def write_output(output, files):
    V.require(output.is_absolute() and output.parent.is_dir() and not output.exists() and not output.is_symlink(),
              "runtime inventory output must be a new absolute directory")
    with tempfile.TemporaryDirectory(prefix=".runtime-inventory-", dir=output.parent) as temporary:
        stage = Path(temporary) / "output"
        stage.mkdir(mode=0o700)
        for name, data in files.items():
            destination = stage / V.path(name)
            destination.parent.mkdir(parents=True, exist_ok=True)
            destination.write_bytes(data)
        os.rename(stage, output)


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--prepared-root", type=Path, required=True)
    parser.add_argument("--source-root", type=Path, required=True)
    parser.add_argument("--output", type=Path, required=True)
    args = parser.parse_args()
    V.require(args.prepared_root.is_dir() and not args.prepared_root.is_symlink(), "unsafe prepared provenance root")
    V.require(args.source_root.is_dir() and not args.source_root.is_symlink(), "unsafe source root")
    outputs, result = regenerate(args.prepared_root.resolve(), args.source_root.resolve())
    write_output(args.output, outputs)
    print(json.dumps(dict(status="qualified", output=str(args.output),
                          manifestSHA256=result["manifestSHA256"], payloadCount=result["payloadCount"],
                          files=sorted(outputs)), sort_keys=True))
