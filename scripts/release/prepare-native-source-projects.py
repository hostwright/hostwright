#!/usr/bin/env python3
"""Bind reviewed license declarations and actual patches to captured Git sources."""

import argparse
import copy
import hashlib
import importlib.util
import os
from pathlib import Path
import shutil
import tarfile
import tempfile


SPEC = importlib.util.spec_from_file_location("source_verifier", Path(__file__).with_name("verify-runtime-provenance.py"))
V = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(V)


def regular(root, relative):
    candidate = root
    for part in V.path(relative).split("/"):
        candidate = candidate / part
        V.require(not candidate.is_symlink(), "symlink in native source input: " + relative)
    V.require(candidate.is_file() and candidate.resolve().is_relative_to(root.resolve()),
              "missing regular native source input: " + relative)
    return candidate


def inventory_digest(contents):
    return V.digest(V.canonical({name: V.digest(data) for name, data in contents.items()}))


def prepare(input_root, metadata, output):
    V.require(input_root.is_dir() and not input_root.is_symlink(), "unsafe native source input root")
    input_root = input_root.resolve()
    V.require(output.is_absolute() and output.parent.is_dir() and not output.exists() and not output.is_symlink(),
              "native source output must be a new absolute path")
    V.require(not output.resolve().is_relative_to(input_root), "native source output must be outside input root")
    V.require(isinstance(metadata, list) and 0 < len(metadata) <= V.MAX_FILES,
              "reviewed native source declarations are missing")
    declarations, identities = [], set()
    for declaration in metadata:
        V.require(isinstance(declaration, dict) and
                  {"identity", "sourceDirectory", "spdx", "licenses", "notices", "patches"} <= set(declaration) and
                  set(declaration) <= {"identity", "sourceDirectory", "spdx", "licenses", "notices", "patches",
                                      "embeddedLicenseDocuments"},
                  "native source declaration requires explicit identity, directory, SPDX, licenses, notices, and patches")
        identity = V.path(declaration["identity"])
        V.require(identity not in identities, "duplicate native source identity")
        identities.add(identity)
        V.spdx(declaration["spdx"])
        for field in ("licenses", "notices", "patches"):
            values = declaration[field]
            V.require(isinstance(values, list) and (values or field == "patches"),
                      "missing reviewed native source " + field)
            V.require(len(set(V.path(value) for value in values)) == len(values),
                      "duplicate native source " + field)
        directory = V.path(declaration["sourceDirectory"])
        source = V.parse(regular(input_root, directory + "/source.json").read_bytes())
        V.require({"commit", "tree", "commitObject", "archive", "inventory"} <= source.keys(),
                  "incomplete captured native source")
        declarations.append((declaration, source))
    declarations.sort(key=lambda item: item[0]["identity"])
    commits = {declaration["identity"]: source["commit"] for declaration, source in declarations}
    with tempfile.TemporaryDirectory(prefix=".native-source-projects-", dir=output.parent) as temporary:
        staging = Path(temporary) / "projects"
        staging.mkdir(mode=0o700)

        def retain(name, data):
            filename = staging / V.path(name)
            filename.parent.mkdir(parents=True, exist_ok=True)
            if filename.exists():
                V.require(filename.read_bytes() == data, "conflicting native source evidence")
            else:
                filename.write_bytes(data)
            return dict(path=name, sha256=V.digest(data), sizeBytes=len(data))

        projects = []
        project_contents = {}
        embedded_specs = {}
        for index, (declaration, source) in enumerate(declarations):
            prefix = "sources/" + str(index).zfill(4) + "/"
            project = dict(identity=declaration["identity"], commit=source["commit"], tree=source["tree"],
                           spdx=declaration["spdx"], licenses=[], notices=[], patches=[])
            if "submodules" in source:
                project["submodules"] = copy.deepcopy(source["submodules"])
            for field, filename in (("commitObject", "commit.object"), ("archive", "source.tar.gz"),
                                    ("inventory", "source-inventory.json")):
                record = source[field]
                original = regular(input_root, declaration["sourceDirectory"] + "/" + V.path(record["path"]))
                destination = staging / (prefix + filename)
                destination.parent.mkdir(parents=True, exist_ok=True)
                shutil.copyfile(original, destination)
                with destination.open("rb") as stream:
                    digest = hashlib.file_digest(stream, "sha256").hexdigest()
                V.require(destination.stat().st_size == record["sizeBytes"] <= V.MAX_FILE and digest == record["sha256"],
                          "captured native source bytes mismatch: " + field)
                project[field] = dict(path=prefix + filename, sha256=digest, sizeBytes=record["sizeBytes"])
            leaves = V.parse((staging / project["inventory"]["path"]).read_bytes(), limit=V.MAX_SOURCE_INVENTORY)
            V.require(isinstance(leaves, list) and 0 < len(leaves) <= V.MAX_FILES, "missing native source leaves")
            leaves = {V.path(leaf["path"]): leaf for leaf in leaves}
            contents = {}
            with tarfile.open(staging / project["archive"]["path"], "r:*") as archive:
                members = archive.getmembers()
                V.require(len(members) <= V.MAX_FILES, "oversized native source archive")
                for member in members:
                    name = V.path(member.name)
                    V.require(member.isfile() or member.isdir(), "unsafe native source archive entry")
                    if member.isfile():
                        V.require(name not in contents and member.size <= V.MAX_FILE,
                                  "duplicate or oversized native source archive entry")
                        contents[name] = archive.extractfile(member).read()
            V.require(contents.keys() == leaves.keys(), "native source archive/inventory coverage mismatch")
            project_contents[declaration["identity"]] = contents
            if "embeddedLicenseDocuments" in declaration:
                embedded_specs[declaration["identity"]] = declaration["embeddedLicenseDocuments"]
            for index, name in enumerate(declaration["patches"]):
                data = regular(input_root, name).read_bytes()
                V.require(all(leaves[path]["gitMode"] != "120000" for path in contents if ("a/" + path).encode() in data),
                          "source patch targets retained link")
                before = inventory_digest(contents)
                V.apply_patch_bytes(data, contents)
                project["patches"].append(dict(retain(prefix + "patches/" + str(index).zfill(4) + ".patch", data),
                    beforeInventorySHA256=before, afterInventorySHA256=inventory_digest(contents)))
            for field in ("licenses", "notices"):
                for name in declaration[field]:
                    V.require(name in contents and leaves[name]["gitMode"] != "120000" and contents[name].strip(),
                              "declared native source license/notice is missing, empty, or a symlink: " + name)
                    project[field].append(dict(retain(prefix + "licenses/" + name, contents[name]), sourcePath=name,
                                               component=project["identity"], spdx=project["spdx"]))
            projects.append(project)
        projects_by_identity = {project["identity"]: project for project in projects}
        for identity, documents in embedded_specs.items():
            project = projects_by_identity[identity]
            V.require(isinstance(documents, list) and documents, "missing embedded license documents")
            for embedded in documents:
                V.require(isinstance(embedded, dict) and
                          set(embedded) == {"sourceProject", "embeddedPinPath", "embeddedCommit", "sourcePath", "data"},
                          "invalid embedded license document")
                source_identity = V.path(embedded["sourceProject"])
                source_path = V.path(embedded["sourcePath"])
                pin_path = V.path(embedded["embeddedPinPath"])
                commit = embedded["embeddedCommit"]
                V.require(source_identity != identity and V.re.fullmatch("[a-f0-9]{40}", commit) is not None,
                          "invalid embedded source identity or commit")
                pin = project_contents[identity].get(pin_path, b"")
                data = embedded["data"]
                V.require(pin and isinstance(data, bytes) and data.strip(),
                          "embedded license or captured source pin is missing")
                V.verify_embedded_source_pin(pin, commit)
                destination = ("sources/" + str(next(i for i, d in enumerate(declarations)
                    if d[0]["identity"] == identity)).zfill(4) + "/licenses/embedded/" +
                    source_identity.replace("/", "_") + "/" + source_path)
                copied = retain(destination, data)
                copied.update(sourceProject=source_identity, embeddedPinPath=pin_path, embeddedCommit=commit,
                              sourcePath=source_path, component=identity, spdx=project["spdx"])
                project["licenses"].append(copied)
                project["notices"].append(dict(copied))
        for project in projects:
            V.source_project(project, lambda name: regular(staging, name).read_bytes(), commits)
        (staging / "projects.json").write_bytes(V.canonical(projects))
        V.require(not output.exists() and not output.is_symlink(), "native source output already exists")
        os.rename(staging, output)
    return projects


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--input-root", type=Path, required=True)
    parser.add_argument("--metadata", type=Path, required=True,
                        help="Reviewed JSON declarations; all input paths are relative to --input-root")
    parser.add_argument("--output", type=Path, required=True)
    args = parser.parse_args()
    prepare(args.input_root, V.parse(args.metadata.read_bytes()), args.output)
