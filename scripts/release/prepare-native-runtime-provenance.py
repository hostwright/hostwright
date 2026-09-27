#!/usr/bin/env python3
"""Join retained native build evidence without depending on deleted build directories."""

import argparse
import gzip
import hashlib
import importlib.util
import io
import os
from pathlib import Path
import re
import tarfile
import tempfile


HERE = Path(__file__).resolve().parent
SPEC = importlib.util.spec_from_file_location("native_verifier", HERE / "verify-runtime-provenance.py")
V = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(V)
PREFIX = "share/hostwright/containerization/"


def regular(root, name):
    current = Path(root)
    for part in V.path(name).split("/"):
        current /= part
        V.require(not current.is_symlink(), "symlink in native provenance input: " + name)
    V.require(current.is_file() and current.resolve().is_relative_to(Path(root).resolve()),
              "missing native provenance input: " + name)
    return current


def prepare(ingredients, source_projects, source_map, source_commit, kernel_project, output, source_map_root=None):
    V.require(re.fullmatch("[a-f0-9]{40}", source_commit), "invalid native release source commit")
    for root in (ingredients, source_projects):
        V.require(root.is_dir() and not root.is_symlink(), "unsafe native input root")
    ingredients, source_projects = ingredients.resolve(), source_projects.resolve()
    V.require(output.is_absolute() and output.parent.is_dir() and not output.exists() and not output.is_symlink(),
              "native output must be a new absolute directory")
    V.require(all(not output.resolve().is_relative_to(root) for root in (ingredients, source_projects)),
              "native output must be outside input roots")
    V.require(isinstance(source_map, list) and source_map, "missing actual native object/source mappings")
    if any("generatedHeaders" in row or "compilerInputs" in row for row in source_map):
        V.require(source_map_root is not None, "native compiler evidence requires a source map root")
    if source_map_root is not None:
        source_map_root = Path(source_map_root)
        V.require(source_map_root.is_dir() and not source_map_root.is_symlink(), "unsafe source map evidence root")
        source_map_root = source_map_root.resolve()
    evidence = ingredients / "evidence"
    captures = {kind: V.parse(regular(evidence, "native-" + kind + "-first.json").read_bytes())
                for kind in ("kernel", "swift")}
    for kind, capture in captures.items():
        V.require(capture.get("kind") == kind and capture.get("status") == "prepared-not-release-qualified",
                  "native build capture kind/status mismatch")
    with tempfile.TemporaryDirectory(prefix=".native-provenance-", dir=output.parent) as temporary:
        staging = Path(temporary) / "prepared"
        staging.mkdir(mode=0o700)

        def write(name, data):
            name = V.path(name)
            target = staging / name
            target.parent.mkdir(parents=True, exist_ok=True)
            if target.exists():
                V.require(target.read_bytes() == data, "conflicting retained native evidence: " + name)
            else:
                target.write_bytes(data)
            return dict(path=name, sha256=V.digest(data), sizeBytes=len(data))

        copied = {}
        mapping_files = {}

        def mapping_fetch(name):
            name = V.path(name)
            if name not in mapping_files:
                mapping_files[name] = regular(source_map_root, name).read_bytes()
            return mapping_files[name]

        def copy_evidence(value, root, prefix):
            if isinstance(value, dict):
                result = {key: copy_evidence(child, root, prefix) for key, child in value.items()}
                if {"path", "sha256", "sizeBytes"} <= value.keys():
                    name = V.path(value["path"])
                    identity = (root.resolve(), name)
                    binding = (value["sha256"], value["sizeBytes"])
                    destination = prefix + name
                    if identity in copied:
                        previous, stored = copied[identity]
                        V.require(previous == binding, "conflicting native evidence binding: " + name)
                        if destination != stored:
                            write(destination, regular(staging, stored).read_bytes())
                    else:
                        if prefix.startswith("evidence/source-map/"):
                            relative = (root.resolve() / name).relative_to(source_map_root).as_posix()
                            data = V.bound(value, lambda _: mapping_fetch(relative))
                        else:
                            original = regular(root, name)
                            data = V.bound(value, lambda _: original.read_bytes())
                        write(destination, data)
                        copied[identity] = (binding, destination)
                    result["path"] = destination
                return result
            return [copy_evidence(child, root, prefix) for child in value] if isinstance(value, list) else value

        def fetch(name):
            return regular(staging, name).read_bytes()

        catalog = V.parse(regular(source_projects, "projects.json").read_bytes())
        projects = copy_evidence(catalog, source_projects, "sources/")
        commits = {project["identity"]: project["commit"] for project in projects}
        V.require(len(commits) == len(projects) and kernel_project in commits, "missing or duplicate native source project")
        leaves = {project["identity"]: V.source_project(project, fetch, commits) for project in projects}
        sources = {}
        for row in source_map:
            V.require(re.fullmatch("[a-f0-9]{64}", row["objectSHA256"]) and row["sourceFiles"],
                      "native object mapping lacks source evidence")
            for source in V.native_source_files(row, mapping_fetch):
                leaf = leaves.get(source["project"], {}).get(source["path"])
                V.require(leaf is not None and leaf["gitMode"] != "120000" and leaf["sha256"] == source["sha256"],
                          "native object source mapping differs from captured Git source")
            row = dict(row)
            if "compilerInputs" in row:
                document, prefix = V.compiler_input_document(row, mapping_fetch)
                copy_evidence(document, source_map_root / prefix, "evidence/source-map/" + prefix)
                row["compilerInputs"] = copy_evidence(row["compilerInputs"], source_map_root, "evidence/source-map/")
            if "generatedHeaders" in row:
                headers = row["generatedHeaders"]
                V.require(isinstance(headers, list) and headers, "missing generated-header evidence")
                for header in headers:
                    V.require(isinstance(header, dict) and isinstance(header.get("originalPath"), str)
                              and Path(header["originalPath"]).is_absolute()
                              and isinstance(header.get("file"), dict)
                              and {"path", "sha256", "sizeBytes"} <= header["file"].keys(),
                              "invalid generated-header file evidence")
                    V.require(isinstance(header.get("compilerArguments"), list) and header["compilerArguments"]
                              and all(isinstance(argument, str) for argument in header["compilerArguments"])
                              and isinstance(header.get("cwd"), str) and Path(header["cwd"]).is_absolute()
                              and isinstance(header.get("evidence"), dict), "missing generated-header compiler metadata")
                    metadata = header.get("retainedEvidence")
                    V.require(isinstance(metadata, list) and metadata and all(
                        isinstance(item, dict) and isinstance(item.get("file"), dict)
                        and {"path", "sha256", "sizeBytes"} <= item["file"].keys() for item in metadata),
                        "missing retained generated-header compiler evidence")
                row["generatedHeaders"] = copy_evidence(headers, source_map_root, "evidence/source-map/")
            sources.setdefault(row["objectSHA256"], []).append(row)

        tools = {}
        for capture in captures.values():
            for tool in capture["toolchain"]:
                path = tool["executablePath"]
                retained = copy_evidence(tool, evidence, "evidence/")
                if path in tools:
                    for field in ("executable", "version"):
                        V.require(all(tools[path][field][key] == retained[field][key] for key in ("sha256", "sizeBytes")),
                                  "native tool " + field + " changed between builds")
                    V.require({(row["sha256"], row["sizeBytes"]) for row in tools[path]["loadedLibraries"]} ==
                              {(row["sha256"], row["sizeBytes"]) for row in retained["loadedLibraries"]},
                              "native tool loaded libraries changed between builds")
                    continue
                retained["identity"] = "native-" + V.digest(path.encode())[:16]
                tools[path] = retained

        kernel_commands = []
        for command in captures["kernel"]["invocations"]:
            target = command.get("target", "")
            if not target.startswith(("arch/arm64/", "kernel/", "mm/", "init/")):
                continue
            argv = V.parse(V.bound(command["argv"], lambda name: regular(evidence, name).read_bytes()))
            if len(argv) > 1 and "-c" in argv and argv[0] in tools:
                V.require(argv[0] == command["executablePath"], "kernel command executable differs from retained tool")
                kernel_commands.append(command)
        V.require(kernel_commands, "missing actual target-kernel compiler command")
        compiler_command = sorted(kernel_commands, key=lambda row: row["target"])[0]
        compiler_path = compiler_command["executablePath"]
        tools[compiler_path]["identity"] = "compiler"
        linker_paths = [path for path in tools if Path(path).name in ("ld.lld", "lld")]
        V.require(len(linker_paths) == 1, "missing or ambiguous actual LLD linker")
        tools[linker_paths[0]]["identity"] = "linker"
        toolchain = sorted(tools.values(), key=lambda tool: tool["identity"])
        authenticated = V.toolchain(dict(toolchain=toolchain), fetch)

        kernels = sorted((ingredients / "payloads").glob("vmlinux*"))
        V.require(len(kernels) == 1 and not kernels[0].is_symlink(), "missing or ambiguous native kernel payload")
        kernel_data = kernels[0].read_bytes()
        V.arm64_image(kernel_data)
        for pass_name in ("first", "second"):
            V.require(regular(ingredients, "evidence/rebuilds/kernel-" + pass_name + ".Image").read_bytes() == kernel_data,
                      "kernel retained rebuild differs from payload")
        kernel_payload = write(PREFIX + "kernel/" + kernels[0].name, kernel_data)
        configurations = [item["file"] for item in captures["kernel"]["metadata"]
                          if Path(item["originalPath"]).name == ".config"]
        V.require(len(configurations) == 1, "missing actual target-kernel configuration")
        config = V.bound(configurations[0], lambda name: regular(evidence, name).read_bytes())
        V.require(b"CONFIG_ARM64=y" in config, "native kernel config lacks ARM64")
        kernel = dict(project=kernel_project, payloadPath=kernel_payload["path"], outputSHA256=V.digest(kernel_data),
                      config=write("evidence/kernel.config", config), compiler=tools[compiler_path]["executable"],
                      commands=copy_evidence(compiler_command["argv"], evidence, "evidence/"),
                      patches=next(project["patches"] for project in projects if project["identity"] == kernel_project))
        V.argv(kernel["commands"], fetch, authenticated)
        payloads = [kernel_payload]
        oci_root = ingredients / "payloads/vminit"
        inventory = {}
        for item in sorted(oci_root.rglob("*")):
            V.require(not item.is_symlink(), "symlink in OCI payload input")
            if item.is_file():
                name = V.path(item.relative_to(oci_root).as_posix())
                inventory[name] = item.read_bytes()
                payloads.append(write(PREFIX + "vminit/" + name, inventory[name]))
        V.require(V.parse(inventory["oci-layout"]) == {"imageLayoutVersion": "1.0.0"}, "wrong native OCI layout")
        visited = {"index.json", "oci-layout"}

        def blob(descriptor, media):
            V.require(descriptor.get("mediaType") == media and re.fullmatch("sha256:[a-f0-9]{64}", descriptor["digest"]),
                      "wrong native OCI descriptor")
            name = "blobs/sha256/" + descriptor["digest"][7:]
            data = inventory[name]
            V.require(len(data) == descriptor["size"] and V.digest(data) == descriptor["digest"][7:], "native OCI blob mismatch")
            visited.add(name)
            return data

        index = V.parse(inventory["index.json"])
        V.require(index.get("schemaVersion") == 2 and index.get("mediaType") == "application/vnd.oci.image.index.v1+json"
                  and len(index["manifests"]) == 1, "unsupported native OCI index")
        image = V.parse(blob(index["manifests"][0], "application/vnd.oci.image.manifest.v1+json"))
        V.require(image.get("schemaVersion") == 2 and image.get("mediaType") == "application/vnd.oci.image.manifest.v1+json"
                  and len(image["layers"]) == 1, "unsupported native OCI manifest")
        configuration = V.parse(blob(image["config"], "application/vnd.oci.image.config.v1+json"))
        layer = blob(image["layers"][0], "application/vnd.oci.image.layer.v1.tar+gzip")
        V.require(visited == set(inventory), "extra native OCI payload")
        V.require(configuration.get("architecture") == "arm64" and configuration.get("os") == "linux",
                  "wrong native OCI architecture")
        diff_id = hashlib.sha256()
        total = 0
        with gzip.GzipFile(fileobj=io.BytesIO(layer)) as stream:
            for chunk in iter(lambda: stream.read(1024 * 1024), b""):
                total += len(chunk)
                V.require(total <= 4 * 1024**3, "oversized native OCI layer")
                diff_id.update(chunk)
        V.require(configuration.get("rootfs") == {"type": "layers", "diff_ids": ["sha256:" + diff_id.hexdigest()]},
                  "native OCI rootfs mismatch")
        regular_files = {}
        with tarfile.open(fileobj=io.BytesIO(layer), mode="r:gz") as archive:
            seen = set()
            for member in archive:
                name = V.path(member.name.rstrip("/"))
                V.require(name not in seen and not name.startswith("proc/self/exe/"), "unsafe native OCI layer path")
                seen.add(name)
                V.require(len(seen) <= V.MAX_FILES, "too many native OCI layer files")
                if member.issym():
                    V.require(name == "proc/self/exe" and member.linkname == "sbin/vminitd" and member.size == 0,
                              "unsupported native OCI symlink")
                else:
                    V.require(member.isfile() or member.isdir(), "unsupported native OCI special file")
                if member.isfile():
                    V.require(member.size <= V.MAX_FILE, "oversized native OCI file")
                    regular_files[name] = archive.extractfile(member).read()
        V.require(set(regular_files) == {"sbin/vminitd", "sbin/vmexec"}, "native OCI profile requires exactly two runtime ELF files")
        links, files = [], []
        for path, data in sorted(regular_files.items()):
            name = Path(path).name
            for filename in ("payloads/" + name, "evidence/rebuilds/" + name + "-first", "evidence/rebuilds/" + name + "-second"):
                V.require(regular(ingredients, filename).read_bytes() == data, "native ELF retained rebuild differs from OCI payload")
            selections = [link for link in captures["swift"]["links"] if Path(link["map"]["path"]).name == name + "-first.map"]
            V.require(len(selections) == 1, "missing or ambiguous actual runtime link map")
            retained = copy_evidence(selections[0], evidence, "evidence/")
            commands, responses = [], []
            working_directory = None
            for invocation in captures["swift"]["invocations"]:
                if invocation["executablePath"] != linker_paths[0]:
                    continue
                argv = V.parse(V.bound(invocation["argv"], lambda entry: regular(evidence, entry).read_bytes()))
                response_records = [dict(item["file"], originalPath=item["originalPath"]) for item in invocation["responseFiles"]]
                expanded = V.expand_response_arguments(argv, response_records,
                    lambda entry: regular(evidence, entry).read_bytes(), invocation.get("cwd")) if response_records else argv
                if not any(argument.endswith(name + "-first.map") and ("-Map" in argument or "--Map" in argument) for argument in expanded):
                    continue
                commands.append(copy_evidence(invocation["argv"], evidence, "evidence/"))
                responses.extend(copy_evidence(item, evidence, "evidence/") for item in response_records)
                working_directory = invocation.get("cwd")
            V.require(len(commands) == 1 and responses, "missing actual linker argv or retained response files for " + name)
            for selected in retained["selectedInputs"]:
                candidates = [row for row in sources.get(selected["objectSHA256"], [])
                              if row.get("mapInput", selected["mapInput"]) == selected["mapInput"]]
                choices = {V.canonical(dict(
                    sourceFiles=sorted(row["sourceFiles"], key=lambda item: (item["project"], item["path"])),
                    **{key: row[key] for key in ("generatedHeaders", "compilerInputs") if key in row}))
                    for row in candidates}
                V.require(len(choices) == 1, "missing or ambiguous native source mapping for " + selected["mapInput"])
                selected.update(V.parse(next(iter(choices))))
            link = dict(retained, path=path, outputSHA256=V.digest(data), commands=commands, responseFiles=responses)
            if working_directory is not None:
                link["workingDirectory"] = working_directory
            V.link_closure(link, data, leaves, fetch, authenticated)
            links.append(link)
            files.append(dict(path=path, sha256=V.digest(data), sizeBytes=len(data), type="elf",
                components=sorted({source["project"] for selected in link["selectedInputs"] for source in selected["sourceFiles"]})))
        write("upstream/kernel-source-signature.json", regular(evidence, "kernel-source-signature.json").read_bytes())
        result = dict(status="prepared-not-release-qualified", sourceCommit=source_commit, sourceProjects=projects,
                      toolchain=toolchain, kernel=kernel, oci=dict(prefix=PREFIX + "vminit", links=links, files=files),
                      payloads=sorted(payloads, key=lambda item: item["path"]))
        write("native-provenance.json", V.canonical(result))
        V.require(not output.exists() and not output.is_symlink(), "native output already exists")
        os.rename(staging, output)
    return result


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--ingredients", type=Path, required=True)
    parser.add_argument("--source-projects", type=Path, required=True)
    parser.add_argument("--source-map", type=Path, required=True)
    parser.add_argument("--source-map-root", type=Path, help="Retained mapping evidence root; defaults to the source map's parent")
    parser.add_argument("--source-commit", required=True)
    parser.add_argument("--kernel-project", required=True)
    parser.add_argument("--output", type=Path, required=True)
    args = parser.parse_args()
    prepare(args.ingredients, args.source_projects, V.parse(args.source_map.read_bytes()),
            args.source_commit, args.kernel_project, args.output, args.source_map_root or args.source_map.parent)
