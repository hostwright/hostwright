#!/usr/bin/env python3
"""Map installed SDK archive objects to pinned source bytes; retain every coverage gap."""

import argparse
import hashlib
import importlib.util
import json
import os
from pathlib import Path
import re
import shlex
import shutil
import subprocess


HERE = Path(__file__).resolve().parent
SPEC = importlib.util.spec_from_file_location("native_capture", HERE / "capture-native-runtime-build.py")
N = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(N)
V = N.V


def digest_file(path):
    with Path(path).open("rb") as stream:
        return hashlib.file_digest(stream, "sha256").hexdigest()


class RetainedInputs:
    def __init__(self, directory, mapping_root):
        directory, mapping_root = Path(directory), Path(mapping_root)
        V.require(directory.is_absolute() and mapping_root.is_absolute(), "retained input paths must be absolute")
        self.directory = directory.resolve()
        self.mapping_root = mapping_root.resolve(strict=True)
        V.require(self.directory != self.mapping_root and self.directory.is_relative_to(self.mapping_root),
                  "generated output must be inside the mapping output directory")
        self.directory.mkdir()
        self.files = {}
        self.paths = {}
        self.verified = {}

    def retain(self, data):
        digest = V.digest(data)
        filename = self.directory / digest
        if digest not in self.files:
            filename.write_bytes(data)
            self.files[digest] = dict(path=filename.relative_to(self.mapping_root).as_posix(),
                                      sha256=digest, sizeBytes=len(data))
        return self.files[digest]

    def retain_file(self, path):
        path = Path(path)
        stat = path.stat()
        version = (stat.st_ino, stat.st_size, stat.st_mtime_ns)
        if self.paths.get(path, (None,))[0] != version:
            data = path.read_bytes()
            after = path.stat()
            V.require(version == (after.st_ino, after.st_size, after.st_mtime_ns),
                      "compiler evidence changed during capture: " + str(path))
            self.paths[path] = (version, self.retain(data))
        return self.paths[path][1]

    def compiler_inputs(self, value):
        def check(item):
            if isinstance(item, dict):
                if {"path", "sha256", "sizeBytes"} <= item.keys():
                    name = V.path(item["path"])
                    signature = (item["sha256"], item["sizeBytes"])
                    if self.verified.get(name) != signature:
                        path = self.mapping_root / name
                        V.require(path.is_file() and not path.is_symlink()
                                  and path.resolve(strict=True).is_relative_to(self.mapping_root),
                                  "unsafe retained compiler input: " + name)
                        V.bound(item, lambda _: path.read_bytes())
                        self.verified[name] = signature
                for child in item.values():
                    check(child)
            elif isinstance(item, list):
                for child in item:
                    check(child)
        check(value)
        data = V.canonical(value)
        V.require(len(data) <= V.MAX_METADATA, "compiler input metadata exceeds the per-object bound")
        digest = V.digest(data)
        name = "compiler-inputs-" + digest + ".json"
        path = self.mapping_root / name
        if path.exists() or path.is_symlink():
            V.require(path.is_file() and not path.is_symlink() and path.read_bytes() == data,
                      "existing compiler input metadata differs from its digest")
        else:
            with path.open("xb") as stream:
                stream.write(data)
        return dict(path=name, sha256=digest, sizeBytes=len(data))


def compact_compiler_inputs(value, translation_units, retained):
    full = {V.canonical(row): row for row in value["sourceFiles"]}
    units = {V.canonical(row): row for row in translation_units}
    V.require(units and units.keys() <= full.keys(), "compiler translation units must match full source evidence")
    representatives = {}
    for key in sorted(units):
        representatives.setdefault(units[key]["project"], units[key])
    for key in sorted(full):
        representatives.setdefault(full[key]["project"], full[key])
    metadata = dict(value, translationUnits=[units[key] for key in sorted(units)])
    return dict(objectSHA256=value["objectSHA256"], sourceFiles=[representatives[key] for key in sorted(representatives)],
                compilerInputs=retained.compiler_inputs(metadata))


def select_source_mappings(mappings, retained):
    complete = {}
    for digest, variants in mappings.items():
        if len(variants) == 1:
            complete[digest] = next(iter(variants.values()))
            continue
        if retained is None:
            continue
        candidates = []
        for value in variants.values():
            reference = value.get("compilerInputs")
            if not isinstance(reference, dict):
                continue
            name = V.path(reference.get("path"))
            filename = retained.mapping_root / name
            V.require(filename.is_file() and not filename.is_symlink()
                      and filename.resolve(strict=True).is_relative_to(retained.mapping_root),
                      "unsafe retained compiler input: " + name)
            metadata = V.parse(V.bound(reference, lambda _: filename.read_bytes()))
            candidates.append((metadata.get("translationUnits"), value))
        unit_sets = {V.canonical(units) for units, _ in candidates}
        if (len(candidates) == len(variants) and unit_sets
                and all(isinstance(units, list) and units for units, _ in candidates) and len(unit_sets) == 1):
            complete[digest] = max((value for _, value in candidates),
                                   key=lambda value: (len(value.get("sourceFiles", [])), V.canonical(value)))
            continue
        documents = []
        for value in (value for _, value in candidates):
            reference = value["compilerInputs"]
            name = V.path(reference["path"])
            filename = retained.mapping_root / name
            documents.append(V.parse(V.bound(reference, lambda _: filename.read_bytes())))
        if (len(documents) != len(variants)
                or not all(set(document) == {"objectSHA256", "sourceFiles", "translationUnits"}
                           and document["objectSHA256"] == digest for document in documents)):
            continue
        project_sets = [{row["project"] for row in document["sourceFiles"]}
                        for document in documents]
        if (documents and all(len(projects) == 1 for projects in project_sets)
                and len(set.union(*project_sets)) == 1):
            source_rows = {V.canonical(row): row for document in documents for row in document["sourceFiles"]}
            unit_rows = {V.canonical(row): row for document in documents for row in document["translationUnits"]}
            if unit_rows and unit_rows.keys() <= source_rows.keys():
                metadata = dict(objectSHA256=digest,
                                sourceFiles=[source_rows[key] for key in sorted(source_rows)],
                                translationUnits=[unit_rows[key] for key in sorted(unit_rows)])
                complete[digest] = dict(objectSHA256=digest,
                    sourceFiles=[unit_rows[sorted(unit_rows)[0]]],
                    compilerInputs=retained.compiler_inputs(metadata))
    return complete


def mapped_object_path(value, mapping, build_roots):
    path = Path(value)
    if path.is_absolute():
        return path
    matches = set()
    for directory in (mapping.parent, *mapping.parent.parents):
        candidate = directory / path
        if candidate.is_file():
            resolved = candidate.resolve(strict=True)
            if any(resolved.is_relative_to(root) for root in build_roots):
                matches.add(resolved)
    V.require(len(matches) == 1, "output-file-map object path does not resolve uniquely: " + value)
    return next(iter(matches))


class Sources:
    def __init__(self, root, pins, relocations, projects_root=None, source_roots=None, source_build_inputs=None):
        self.root = Path(root).resolve(strict=True)
        self.relocations = sorted(relocations, key=lambda pair: -len(str(pair[0])))
        self.repositories = []
        self.blobs = {}
        self.cache = {}
        self.resolved = {}
        self.tracked_paths = {}
        self.patched_sources = {}
        for pin in pins:
            destination = V.path(pin["destination"])
            repository = self.root / destination
            commit = pin["commit"]
            actual = subprocess.check_output(["git", "-C", str(repository), "rev-parse", "HEAD"], text=True).strip()
            V.require(actual == commit, "SDK source differs from pin: " + destination)
            rows = subprocess.check_output(["git", "-C", str(repository), "ls-tree", "-r", "-z", commit])
            leaves = {}
            identity = "swift-sdk/" + destination
            for row in rows.split(b"\0"):
                if not row:
                    continue
                metadata, filename = row.split(b"\t", 1)
                mode, kind, oid = metadata.decode().split()
                if kind != "blob" or mode not in ("100644", "100755"):
                    continue
                name = V.path(filename.decode())
                leaves[name] = ("git", oid)
                self.blobs.setdefault(("git", oid), []).append((identity, name))
            self.repositories.append((repository, identity, leaves))
        if source_build_inputs is not None:
            source_build_inputs = Path(source_build_inputs).resolve(strict=True)
            build_root = source_build_inputs.parent
            inventory = V.parse(source_build_inputs.read_bytes(), limit=V.MAX_SOURCE_INVENTORY)
            by_destination = {pin["destination"]: pin["commit"] for pin in pins}
            def fetch_patch(name):
                filename = build_root / V.path(name)
                V.require(not filename.is_symlink() and filename.resolve(strict=True).is_relative_to(build_root),
                          "unsafe retained SDK source patch")
                return filename.read_bytes()
            for project in inventory.get("sourceProjects", []):
                destination = V.path(project["destination"])
                source = project.get("source", {})
                if destination not in by_destination or "workingTreePatch" not in project:
                    continue
                V.require(source.get("commit") == by_destination[destination],
                          "SDK source patch commit differs from the exact pin: " + destination)
                patch = V.bound(project["workingTreePatch"], fetch_patch)
                names = sorted(set(V.path(match.decode("utf-8")) for match in
                    re.findall(rb"^--- a/([^\n]+)$", patch, re.MULTILINE)))
                V.require(names, "SDK source patch has no source files: " + destination)
                repository = self.root / destination
                contents = {name: subprocess.check_output(["git", "-C", str(repository), "show",
                            by_destination[destination] + ":" + name]) for name in names}
                V.apply_patch_bytes(patch, contents)
                applied = contents
                for name, data in applied.items():
                    self.patched_sources[(repository.resolve(strict=True), name)] = V.digest(data)
        if projects_root is not None:
            projects_root = Path(projects_root).resolve(strict=True)
            projects = V.parse((projects_root / "projects.json").read_bytes())
            commits = {project["identity"]: project["commit"] for project in projects}
            V.require(len(commits) == len(projects) and set(source_roots) <= commits.keys(), "invalid explicit source roots")
            def fetch(name):
                path = projects_root / V.path(name)
                V.require(not path.is_symlink() and path.resolve().is_relative_to(projects_root), "unsafe captured source input")
                return path.read_bytes()
            for project in projects:
                leaves = V.source_project(project, fetch, commits)
                identity = project["identity"]
                if identity not in source_roots:
                    continue
                entries = {}
                for name, leaf in leaves.items():
                    if leaf["gitMode"] == "120000":
                        continue
                    entries[name] = ("sha256", leaf["sha256"])
                    self.blobs.setdefault(entries[name], []).append((identity, name))
                self.repositories.append((Path(source_roots[identity]).resolve(strict=True), identity, entries))
        self.repositories.sort(key=lambda item: -len(str(item[0])))

    def relocate(self, name, cwd=None):
        key = (str(name), str(cwd))
        if key in self.resolved:
            return self.resolved[key]
        path = Path(name)
        if not path.is_absolute():
            V.require(cwd is not None, "relative build input has no captured working directory")
            path = Path(cwd) / path
        for old, new in self.relocations:
            if path.is_relative_to(old):
                path = Path(new) / path.relative_to(old)
                break
        path = path.resolve(strict=True)
        self.resolved[key] = path
        return path

    def source_candidates(self, name, cwd=None):
        path = self.relocate(name, cwd)
        if path in self.cache:
            return self.cache[path]
        data = path.read_bytes()
        oid = V.git_object("blob", data)
        digest = V.digest(data)
        selected = None
        for directory, identity, leaves in self.repositories:
            if path.is_relative_to(directory):
                relative = path.relative_to(directory).as_posix()
                base = leaves.get(relative)
                if base not in (("git", oid), ("sha256", digest)):
                    V.require(self.patched_sources.get((directory, relative)) == digest,
                              "unverified generated or changed source: " + str(path))
                selected = [(identity, relative)]
                break
        if selected is None:
            V.require(data, "empty copied input requires retained compiler evidence: " + str(path))
            candidates = sorted(set(self.blobs.get(("git", oid), []) + self.blobs.get(("sha256", digest), [])))
            V.require(candidates, "copied/generated source lacks pinned bytes: " + str(path))
            selected = candidates
        result = [dict(project=identity, path=relative, sha256=digest) for identity, relative in selected]
        self.cache[path] = result
        return result

    def source(self, name, cwd=None):
        rows = self.source_candidates(name, cwd)
        V.require(len(rows) == 1, "source identity is ambiguous across pinned projects: " + str(name))
        return rows[0]

    def is_tracked_path(self, name, cwd=None):
        path = self.relocate(name, cwd)
        if path not in self.tracked_paths:
            self.tracked_paths[path] = any(path.is_relative_to(directory) for directory, _, _ in self.repositories)
        return self.tracked_paths[path]

    def generated_swift_sources(self, name, cwd=None):
        path = self.relocate(name, cwd)
        V.require(not self.is_tracked_path(name, cwd),
                  "changed pinned Swift source cannot be treated as generated: " + str(path))
        data = path.read_bytes()
        V.require(path.suffix in (".swift", ".mm") and data,
                  "not a nonempty generated Swift/C-family source: " + str(path))
        paths = {match.decode("utf-8") for match in
                 re.findall(rb'// ###sourceLocation\(file: "([^"\n]+\.(?:gyb|swift))"', data)}
        paths.update(match.decode("utf-8") for match in
                     re.findall(rb'// original-source-range: ([^\s:]+\.(?:gyb|swift)):\d+:\d+', data))
        paths = sorted(paths)
        V.require(paths, "generated Swift source has no sourceLocation template evidence: " + str(path))
        rows = {V.canonical(row): row for source in paths for row in self.source_candidates(source)}
        V.require(rows, "generated Swift source templates are not pinned: " + str(path))
        return list(rows.values()), paths

    def build_header(self, name, cwd, build_roots):
        path = self.relocate(name, cwd)
        V.require(not self.is_tracked_path(name, cwd),
                  "unverified generated or changed source: " + str(path))
        V.require(any(path.is_relative_to(directory) for directory in build_roots)
                  and (path.suffix in (".h", ".hh", ".hpp", ".inc", ".def")
                       or not path.suffix
                       or path.name in ("__config_site", "__undef_macros", "cmake_pch.h.c", "SDKSettings.json")),
                  "unverified external source: " + str(path))
        data = path.read_bytes()
        if path.name == "cmake_pch.h.c":
            V.require(data == b"/* generated by CMake */\n", "unrecognized generated precompiled-header source")
            return path, data, []
        if path.name == "SDKSettings.json":
            V.require(isinstance(json.loads(data), dict), "unrecognized SDK configuration input")
            return path, data, []
        digest = V.digest(data)
        candidates = sorted(set(self.blobs.get(("git", V.git_object("blob", data)), [])
                                + self.blobs.get(("sha256", digest), [])))
        matches = [dict(project=identity, path=name, sha256=digest) for identity, name in candidates]
        if not path.suffix and path.name not in ("__config_site", "__undef_macros"):
            V.require(matches, "extensionless copied header lacks pinned source bytes: " + str(path))
        if not data:
            return path, data, []
        return path, data, matches


def ninja_dependencies(directory):
    ninja = shutil.which("ninja")
    if not ninja or not (directory / ".ninja_deps").is_file():
        return {}
    result = subprocess.run([ninja, "-C", str(directory), "-t", "deps"], text=True,
                            stdout=subprocess.PIPE, stderr=subprocess.PIPE, check=False)
    V.require(result.returncode == 0, "cannot read actual Ninja dependencies")
    rows, target = {}, None
    for line in result.stdout.splitlines():
        match = re.fullmatch(r"(.+): #deps (\d+), deps mtime \d+ \(VALID\)", line)
        if match:
            target = match[1]
            rows[target] = []
        elif line.startswith("    ") and target:
            rows[target].append(line[4:])
        else:
            target = None
    return rows


def trace_compilers(filename, sources, selected_hashes, initial_cwd=None, selected_sizes=None):
    """Stream legacy/current strace without retaining or publishing environment variables."""
    decoder = json.JSONDecoder()
    pending, calls, reads, pending_reads, pending_cwds, pending_exits = {}, {}, {}, {}, {}, {}
    working_directories = {}
    process_parents = {}
    first_pid = None

    def relevant_source_open(path, call):
        if Path(path).suffix != ".s":
            return True
        for argument in call["argv"]:
            if Path(argument).suffix not in (".S", ".s"):
                continue
            try:
                if sources.relocate(argument, call["cwd"]) == Path(path):
                    return True
            except (ValueError, OSError):
                continue
        return False
    with Path(filename).open(errors="strict") as stream:
        for line_number, line in enumerate(stream, 1):
            prefix = re.match(r"\s*(\d+)\s+(?:\d+\.\d+\s+)?(.*)", line)
            if not prefix:
                continue
            pid, body = prefix.groups()
            if first_pid is None:
                first_pid = pid
                if initial_cwd is not None:
                    working_directories[pid] = str(initial_cwd)
            observed = re.search(r"AT_FDCWD<(/[^<>]+)>", body)
            if observed:
                working_directories[pid] = observed[1]
                if pid in calls and calls[pid]["cwd"] is None:
                    calls[pid]["cwd"] = observed[1]
            changed = re.match(r'chdir\(("(?:[^"\\]|\\.)*")\)', body)
            descriptor = re.match(r'fchdir\(\d+<(/[^<>]+)>\)', body)
            if changed or descriptor:
                name = decoder.raw_decode(changed[1])[0] if changed else descriptor[1]
                if "<unfinished ...>" in body:
                    pending_cwds[pid] = name
                    name = None
                elif not re.search(r'= 0(?:\s|$)', body):
                    name = None
            elif re.match(r'<\.\.\. f?chdir resumed>', body):
                name = pending_cwds.pop(pid, None)
                if not re.search(r'= 0(?:\s|$)', body):
                    name = None
            else:
                name = None
            if name is not None:
                if name.startswith("/"):
                    working_directories[pid] = name
                elif pid in working_directories:
                    working_directories[pid] = os.path.normpath(working_directories[pid] + "/" + name)
            child = re.search(r'(?:^(?:clone3?|vfork|fork)\(|<\.\.\. (?:clone3?|vfork|fork) resumed>).*?= ([1-9][0-9]*)(?:\s|$)', body)
            if child and pid in working_directories:
                working_directories.setdefault(child[1], working_directories[pid])
                process_parents[child[1]] = pid
            if body.startswith("execve("):
                calls.pop(pid, None)
                reads.pop(pid, None)
                try:
                    executable, end = decoder.raw_decode(body[7:])
                    if not re.search(r"(?:clang(?:\+\+)?|gcc|cc|swiftc|swift-frontend)(?:-\d+)?$", executable):
                        continue
                    rest = body[7 + end:].lstrip(", ")
                    argv, end = decoder.raw_decode(rest)
                    swift_wmo = executable.endswith("swiftc") and "-whole-module-optimization" in argv
                    if "-o" not in argv or not ("-c" in argv or "-emit-obj" in argv or swift_wmo):
                        continue
                    output = argv[argv.index("-o") + 1]
                    if not output.endswith((".o", ".obj", ".lo", ".os")):
                        continue
                    cwd = working_directories.get(pid)
                    rest = rest[end:].lstrip(", ")
                    if rest.startswith("["):
                        environment, _ = decoder.raw_decode(rest)
                        cwd = cwd or next((item[4:] for item in environment if item.startswith("PWD=")), None)
                    if cwd is None:
                        cwd = next((argv[i + 1] for i, item in enumerate(argv[:-1])
                                    if item in ("-fdebug-compilation-dir", "-working-directory")), None)
                    response_files, response_units = [], []
                    swift_driver = executable.endswith(("swiftc", "swift-frontend"))
                    response_paths = ([(Path(argument[1:]), False) for argument in argv if argument.startswith("@")]
                                      + [(Path(argv[index + 1]), True) for index, argument in enumerate(argv[:-1])
                                         if argument == "-filelist"]) if swift_driver else []
                    for response_path, filelist in response_paths:
                        if not response_path.is_absolute():
                            response_path = Path(cwd or ".") / response_path
                        data = sources.relocate(str(response_path), cwd).read_bytes()
                        response_arguments = data.decode("utf-8").splitlines() if filelist else shlex.split(data.decode("utf-8"))
                        units = [value for value in response_arguments if Path(value).suffix == ".swift"]
                        response_units.extend(units)
                        response_files.append(dict(originalPath=str(response_path), data=data, sourcePaths=units))
                    call = dict(object=output, argv=argv, cwd=cwd, responseFiles=response_files,
                                translationUnits=sorted(set(response_units)), sourceReadTrace=[], sourceReadTraceLineNumbers=[],
                                evidence=dict(path=str(filename), line=line_number))
                    if re.search(r"= 0(?:\s+<[^>]+>)?\s*$", body):
                        calls[pid], reads[pid] = call, set()
                    elif "<unfinished ...>" in body:
                        pending[pid] = call
                except (ValueError, OSError, IndexError):
                    continue
            elif "execve resumed>" in body and pid in pending:
                call = pending.pop(pid)
                if re.search(r"= 0(?:\s+<[^>]+>)?\s*$", body):
                    calls[pid], reads[pid] = call, set()
            elif pid not in calls and pid in process_parents:
                owner = process_parents[pid]
                while owner not in calls and owner in process_parents:
                    owner = process_parents[owner]
                if owner in calls and (((body.startswith(("open(", "openat(", "openat2(")) and "O_RDONLY" in body
                                       and "O_DIRECTORY" not in body) or ("openat resumed>" in body and pid in pending_reads))):
                    if "<unfinished ...>" in body:
                        pending_reads[pid] = owner
                        calls[owner]["sourceReadTrace"].append(line)
                        calls[owner]["sourceReadTraceLineNumbers"].append(line_number)
                    else:
                        pending_reads.pop(pid, None)
                        opened = re.search(r"= \d+<(/[^<>]+)>", body)
                        if opened and relevant_source_open(opened[1], calls[owner]) and (re.search(r"\.(?:c|cc|cpp|cxx|h|hh|hpp|inc|def|S|s|swift|pch|pcm)$", opened[1])
                                       or "/sources/" in opened[1]
                                       or Path(opened[1]).name in ("__config_site", "__undef_macros")):
                            reads[owner].add(opened[1])
                            calls[owner]["sourceReadTrace"].append(line)
                            calls[owner]["sourceReadTraceLineNumbers"].append(line_number)
            elif pid in calls:
                if body.startswith(("exit_group(", "exit(")) and "<unfinished ...>" in body:
                    pending_exits[pid] = body.startswith(("exit_group(0", "exit(0"))
                elif body.startswith(("<... exit_group resumed>)", "<... exit resumed>)")):
                    succeeded = pending_exits.pop(pid, False)
                    if succeeded:
                        call = calls.pop(pid)
                        call["sources"] = sorted(reads.pop(pid))
                        call["sourceReadTrace"].append(line)
                        call["sourceReadTraceLineNumbers"].append(line_number)
                        try:
                            obj = sources.relocate(call["object"], call["cwd"])
                            if selected_sizes is not None and obj.stat().st_size not in selected_sizes:
                                continue
                            digest = digest_file(obj)
                            if digest in selected_hashes:
                                call.update(object=str(obj), objectSHA256=digest)
                                yield call
                        except (ValueError, OSError):
                            pass
                    else:
                        calls.pop(pid, None)
                        reads.pop(pid, None)
                elif "+++ exited with 0 +++" in body or body.startswith(("exit_group(0)", "exit(0)")):
                    call = calls.pop(pid)
                    call["sources"] = sorted(reads.pop(pid))
                    call["sourceReadTrace"].append(line)
                    call["sourceReadTraceLineNumbers"].append(line_number)
                    try:
                        obj = sources.relocate(call["object"], call["cwd"])
                        if selected_sizes is not None and obj.stat().st_size not in selected_sizes:
                            continue
                        digest = digest_file(obj)
                        if digest in selected_hashes:
                            call.update(object=str(obj), objectSHA256=digest)
                            yield call
                    except (ValueError, OSError):
                        pass
                elif "+++ exited with" in body or "+++ killed by" in body or body.startswith(("exit_group(", "exit(")):
                    calls.pop(pid, None)
                    reads.pop(pid, None)
                elif ((body.startswith(("open(", "openat(", "openat2(")) and "O_RDONLY" in body
                       and "O_DIRECTORY" not in body) or ("openat resumed>" in body and pid in pending_reads)):
                    if "<unfinished ...>" in body:
                        pending_reads[pid] = pid
                        calls[pid]["sourceReadTrace"].append(line)
                        calls[pid]["sourceReadTraceLineNumbers"].append(line_number)
                    else:
                        pending_reads.pop(pid, None)
                        opened = re.search(r"= \d+<(/[^<>]+)>", body)
                        if opened and relevant_source_open(opened[1], calls[pid]) and (re.search(r"\.(?:c|cc|cpp|cxx|h|hh|hpp|inc|def|S|s|swift|pch|pcm)$", opened[1])
                       or "/sources/" in opened[1] or opened[1].endswith(".pcm")
                                       or Path(opened[1]).name in ("__config_site", "__undef_macros")):
                            reads[pid].add(opened[1])
                            calls[pid]["sourceReadTrace"].append(line)
                            calls[pid]["sourceReadTraceLineNumbers"].append(line_number)


def capture(source_root, build_roots, sdk_root, pins, traces=(), relocations=(),
            projects_root=None, source_roots=None, selected_inputs=(), trace_cwd=None,
            generated_output=None, mapping_root=None, external_header_roots=(), sdk_build_inputs=None):
    sources = Sources(source_root, pins, relocations, projects_root, source_roots, sdk_build_inputs)
    retained = RetainedInputs(generated_output, mapping_root or Path(generated_output).parent) if generated_output else None
    header_roots = [Path(root).resolve(strict=True) for root in build_roots]
    if sdk_root is not None:
        header_roots.append(Path(sdk_root).resolve(strict=True))
    header_roots.extend(Path(root).resolve(strict=True) for root in external_header_roots)
    members = list(selected_inputs)
    V.require(all(re.fullmatch("[a-f0-9]{64}", row["objectSHA256"]) for row in members), "invalid selected object digest")
    for archive in sorted(Path(sdk_root).rglob("*.a")) if sdk_root is not None else []:
        data = archive.read_bytes()
        archive_digest = V.digest(data)
        for member, offset, obj in V.archive_entries(data):
            members.append(dict(archive=str(archive), archiveSHA256=archive_digest, member=member,
                                archiveOffset=offset, objectSHA256=V.digest(obj), objectSizeBytes=len(obj)))
    empty_non_source_members = []
    empty_crt_paths = {
        "aarch64/usr/lib/swift/clang/lib/linux/crtbeginT.o",
        "aarch64/usr/lib/swift/clang/lib/linux/crtend.o",
    }
    for obj in sorted(Path(sdk_root).rglob("*")) if sdk_root is not None else []:
        if obj.is_file() and obj.suffix in (".o", ".obj"):
            digest, size = digest_file(obj), obj.stat().st_size
            row = dict(object=str(obj), objectSHA256=digest, sizeBytes=size)
            members.append(row)
            if (sdk_root is not None and obj.relative_to(Path(sdk_root)).as_posix() in empty_crt_paths
                    and size == 0 and digest == V.digest(b"")):
                empty_non_source_members.append(dict(row,
                    disposition="empty-clang-crt-placeholder",
                    reason="verified zero-byte compiler resource; contains no source payload"))
    V.require(members, "no installed or explicitly selected object inputs")
    selected = {row["objectSHA256"] for row in members}
    sizes = [row.get("objectSizeBytes", row.get("sizeBytes") if "object" in row else None) for row in members]
    selected_sizes = set(sizes) if all(size is not None for size in sizes) else None
    mappings, failures, metadata = {}, [], []

    def add(obj, names, cwd, evidence, arguments, translation_units, digest=None, trace_lines=None,
            trace_line_numbers=None, response_files=None):
        obj = sources.relocate(str(obj), cwd)
        if selected_sizes is not None and obj.stat().st_size not in selected_sizes:
            return
        digest = digest or digest_file(obj)
        if digest not in selected:
            return
        try:
            V.require(names, "actual compiler dependencies are unavailable")
            V.require(translation_units, "actual compiler translation unit is unavailable")
            generated = []
            rows = {}
            translation_unit_paths = {sources.relocate(name, cwd) for name in translation_units}
            for name in translation_units:
                try:
                    candidates = sources.source_candidates(name, cwd)
                except ValueError:
                    path = sources.relocate(name, cwd)
                    V.require(path.suffix in (".swift", ".mm"),
                              "compiler translation unit has no pinned source: " + str(path))
                    candidates, source_paths = sources.generated_swift_sources(name, cwd)
                    V.require(retained is not None, "generated Swift source retention is required: " + str(path))
                    generated.append(dict(originalPath=str(path), data=path.read_bytes(),
                                          kind="generated-template-source-input", sourceFiles=candidates,
                                          sourcePaths=source_paths))
                for row in candidates:
                    rows[V.canonical(row)] = row
                if not sources.is_tracked_path(name, cwd) and not any(
                        item["originalPath"] == str(sources.relocate(name, cwd)) for item in generated):
                    V.require(retained is not None, "copied compiler-source retention is required: " + str(name))
                    path = sources.relocate(name, cwd)
                    generated.append(dict(originalPath=str(path), data=path.read_bytes(),
                                          kind="copied-source-input", matchingSources=candidates))
            unit_rows = list(rows.values())
            has_nonempty_source = any(row["sha256"] != V.digest(b"") for row in rows.values())
            exact_traced_empty_unit = (bool(trace_lines) and len(unit_rows) == 1
                and unit_rows[0]["sha256"] == V.digest(b"")
                and any(sources.relocate(name, cwd) in translation_unit_paths for name in names))
            V.require(has_nonempty_source or exact_traced_empty_unit,
                      "actual nonempty compiler translation unit is unavailable")
            modules = []
            for name in names:
                try:
                    if sources.relocate(name, cwd) in translation_unit_paths:
                        continue
                    if not sources.is_tracked_path(name, cwd):
                        raise ValueError("compiler input is outside pinned source roots")
                    for row in sources.source_candidates(name, cwd):
                        rows[V.canonical(row)] = row
                except ValueError:
                    path = sources.relocate(name, cwd)
                    if path.suffix == ".pcm":
                        V.require(retained is not None and any(path.is_relative_to(root) for root in header_roots),
                                  "compiler module retention is required: " + str(path))
                        modules.append(dict(originalPath=str(path), file=retained.retain_file(path)))
                        continue
                    if path.name != "cmake_pch.h.c" and path.suffix in (".c", ".cc", ".cpp", ".mm", ".m", ".S", ".s", ".swift"):
                        try:
                            matches = sources.source_candidates(name, cwd)
                            source_paths = None
                        except ValueError:
                            V.require(path.suffix in (".swift", ".mm"),
                                      "compiler dependency has no pinned source: " + str(path))
                            matches, source_paths = sources.generated_swift_sources(name, cwd)
                        V.require(retained is not None, "copied compiler-source retention is required: " + str(path))
                        generated.append(dict(originalPath=str(path), data=path.read_bytes(),
                            kind="generated-template-source-input" if source_paths else "copied-source-input",
                            sourceFiles=matches, sourcePaths=source_paths) if source_paths else
                            dict(originalPath=str(path), data=path.read_bytes(), kind="copied-source-input",
                                 matchingSources=matches))
                        for row in matches:
                            rows[V.canonical(row)] = row
                        continue
                    V.require(retained is not None, "generated-header retention is required: " + str(name))
                    path, data, matches = sources.build_header(name, cwd, header_roots)
                    for row in matches:
                        rows[V.canonical(row)] = row
                    header = dict(originalPath=str(path), file=retained.retain(data))
                    if path.name == "cmake_pch.h.c":
                        header["kind"] = "generated-source-input"
                    elif path.name == "SDKSettings.json":
                        header["kind"] = "sdk-configuration-input"
                    elif matches:
                        header.update(kind="copied-header", matchingSources=matches)
                    elif not data:
                        header["kind"] = "empty-header"
                    generated.append(header)
            V.require(digest_file(obj) == digest, "object changed during source capture")
            value = dict(objectSHA256=digest, sourceFiles=[rows[key] for key in sorted(rows)])
            if modules:
                value["compilerModuleFiles"] = sorted(modules, key=lambda row: row["originalPath"])
            if response_files:
                V.require(retained is not None, "Swift response-file retention is required")
                value["compilerResponseFiles"] = [dict(originalPath=row["originalPath"],
                    file=retained.retain(row["data"]), sourcePaths=row["sourcePaths"],
                    sourceFiles=unit_rows)
                    for row in response_files]
            if generated:
                V.require(cwd is not None, "generated-header evidence requires the compiler working directory")
                for item in generated:
                    if "data" in item:
                        item["file"] = retained.retain(item.pop("data"))
                bound_evidence = []
                for key in ("path", "dependencyPath"):
                    if key in evidence and not trace_lines:
                        path = Path(evidence[key])
                        bound_evidence.append(dict(originalPath=str(path), file=retained.retain_file(path)))
                if trace_lines:
                    bound_evidence.append(dict(kind="source-read-trace", lineNumbers=trace_line_numbers,
                        file=retained.retain("".join(trace_lines).encode())))
                value["generatedHeaders"] = [dict(row, compilerArguments=arguments, cwd=str(cwd),
                    evidence=evidence, retainedEvidence=bound_evidence) for row in sorted(generated, key=lambda row: row["originalPath"])]
            if retained is not None:
                value = compact_compiler_inputs(value, unit_rows, retained)
            mappings.setdefault(digest, {})[V.canonical(value)] = value
            metadata.append(dict(object=str(obj), objectSHA256=digest, evidence=evidence))
        except (ValueError, OSError) as error:
            failures.append(dict(object=str(obj), objectSHA256=digest, reason=str(error), evidence=evidence))

    for build_root in build_roots:
        for database in sorted(Path(build_root).rglob("compile_commands.json")):
            rows = V.parse(database.read_bytes(), limit=V.MAX_SOURCE_INVENTORY)
            dependencies = ninja_dependencies(database.parent)
            for row in rows:
                try:
                    arguments = row.get("arguments") or shlex.split(row["command"])
                    output = row.get("output") or arguments[arguments.index("-o") + 1]
                    obj = sources.relocate(output, row["directory"])
                    if selected_sizes is not None and obj.stat().st_size not in selected_sizes:
                        continue
                    digest = digest_file(obj)
                    if digest not in selected:
                        continue
                    depfile = next((arguments[i + 1] for i, item in enumerate(arguments[:-1]) if item == "-MF"), None)
                    names = []
                    evidence = dict(path=str(database), file=row["file"])
                    if depfile:
                        try:
                            dependency_path = sources.relocate(depfile, row["directory"])
                            names = N.depfile_sources(dependency_path)
                            evidence["dependencyPath"] = str(dependency_path)
                        except FileNotFoundError:
                            pass
                    if not names:
                        names = dependencies.get(output, [])
                        if names:
                            evidence["dependencyPath"] = str(database.parent / ".ninja_deps")
                    add(obj, names, row["directory"], evidence, arguments, [row["file"]], digest)
                except (ValueError, OSError, IndexError) as error:
                    failures.append(dict(metadata=str(database), reason=str(error)))
        for mapping in sorted(Path(build_root).rglob("*output-file-map.json")):
            values = V.parse(mapping.read_bytes())
            source_list = mapping.parent / "sources"
            module_sources = shlex.split(source_list.read_text()) if source_list.is_file() else []
            for name, row in values.items():
                if "object" not in row:
                    continue
                try:
                    units = module_sources or ([name] if name else [])
                    obj = mapped_object_path(row["object"], mapping, build_roots)
                    add(str(obj), units, mapping.parent,
                        dict(path=str(mapping), sourceList=str(source_list) if module_sources else None), [], units)
                except (ValueError, OSError) as error:
                    failures.append(dict(metadata=str(mapping), reason=str(error)))
    for trace in traces:
        for row in trace_compilers(trace, sources, selected, trace_cwd, selected_sizes):
            units = [name for name in row["argv"][1:] if not name.startswith("-")
                     and Path(name).suffix in (".c", ".C", ".cc", ".cpp", ".cxx", ".m", ".mm", ".S", ".s", ".swift")]
            units.extend(row["translationUnits"])
            add(row["object"], row["sources"], row["cwd"], row["evidence"], row["argv"], units,
                row["objectSHA256"], row["sourceReadTrace"], row["sourceReadTraceLineNumbers"], row["responseFiles"])
    complete = select_source_mappings(mappings, retained)
    empty_paths = {row["object"] for row in empty_non_source_members}
    unresolved = [dict(row, reason="ambiguous source attribution" if row["objectSHA256"] in mappings
                       else "no verified successful compilation mapping") for row in members
                  if row["objectSHA256"] not in complete and row.get("object") not in empty_paths]
    return dict(kind="hostwright.sdk-object-sources.v1", status="partial-not-release-qualified",
                sourceMap=[complete[digest] for digest in sorted(complete)], unresolved=unresolved,
                emptyNonSourceMembers=empty_non_source_members,
                rejectedInputs=failures, mappingEvidence=metadata, archiveMembers=members,
                counts=dict(archiveMembers=len(members), mappedMembers=len(members)-len(unresolved),
                            unresolvedMembers=len(unresolved), mappedObjects=len(complete)))


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--sources", type=Path, required=True)
    parser.add_argument("--build", type=Path, action="append", required=True)
    parser.add_argument("--sdk-root", type=Path)
    parser.add_argument("--header-root", type=Path, action="append", default=[],
                        help="Additional root for exact compiler-consumed generated headers")
    parser.add_argument("--source-projects", type=Path, help="Validated project catalog, including explicit applied patches")
    parser.add_argument("--source-roots", type=Path, help="JSON mapping of captured project identities to current source roots")
    parser.add_argument("--sdk-build-inputs", type=Path,
                        help="Retained SDK build inventory used to verify exact applied source patches")
    parser.add_argument("--selected-inputs", type=Path, help="Additional actual selected-input ledger rows, including standalone objects")
    parser.add_argument("--trace", type=Path, action="append", default=[])
    parser.add_argument("--trace-cwd", type=Path, help="Actual initial working directory of each traced build")
    parser.add_argument("--generated-output", type=Path, help="New directory inside the mapping output directory for generated headers and compiler evidence")
    parser.add_argument("--relocate", action="append", default=[], help="Original absolute root=current absolute root")
    parser.add_argument("--pins", type=Path, default=HERE / "runtime-swift-sources.json")
    parser.add_argument("--output", type=Path, required=True)
    args = parser.parse_args()
    V.require(args.output.is_absolute() and args.output.parent.is_dir() and not args.output.exists(), "output must be a new absolute file")
    relocations = [(Path(old), Path(new)) for old, new in (value.split("=", 1) for value in args.relocate)]
    V.require((args.source_projects is None) == (args.source_roots is None), "source projects and roots must be supplied together")
    pins = [] if args.source_projects is not None else V.parse(args.pins.read_bytes())
    result = capture(args.sources, args.build, args.sdk_root, pins, args.trace, relocations,
                     args.source_projects, V.parse(args.source_roots.read_bytes()) if args.source_roots else None,
                     V.parse(args.selected_inputs.read_bytes()) if args.selected_inputs else [], args.trace_cwd,
                     args.generated_output, args.output.parent, args.header_root, args.sdk_build_inputs)
    with args.output.open("xb") as stream:
        stream.write(V.canonical(result))
    print(json.dumps(result["counts"], sort_keys=True))
