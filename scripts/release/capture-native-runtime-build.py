#!/usr/bin/env python3
"""Retain native tool invocations and bind LLD selections to captured source leaves."""

import argparse
import hashlib
import importlib.util
import os
from pathlib import Path
import re
import shlex
import shutil
import struct
import subprocess
import tempfile
import uuid


SPEC = importlib.util.spec_from_file_location("runtime_verifier", Path(__file__).with_name("verify-runtime-provenance.py"))
V = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(V)
ENVIRONMENT_KEYS = ("PATH", "LANG", "LC_ALL", "LC_CTYPE", "TZ", "SOURCE_DATE_EPOCH", "SDKROOT",
                    "CC", "CXX", "AR", "LD", "CFLAGS", "CXXFLAGS", "CPPFLAGS", "LDFLAGS",
                    "SWIFT_EXEC", "SWIFT_DRIVER_SWIFT_FRONTEND_EXEC", "GOTOOLCHAIN", "GOROOT",
                    "GOOS", "GOARCH", "CGO_ENABLED", "KCFLAGS", "KAFLAGS", "KBUILD_BUILD_TIMESTAMP",
                    "KBUILD_BUILD_USER", "KBUILD_BUILD_HOST", "KBUILD_BUILD_VERSION")


def retain(root, filename):
    root = Path(root).resolve(strict=True)
    original = Path(filename)
    filename = original.resolve(strict=True)
    V.require(filename.is_file(), "native input is not a regular file: " + str(original))
    with filename.open("rb") as stream:
        digest = hashlib.file_digest(stream, "sha256").hexdigest()
    name = V.path("native-files/" + digest + "/" + original.name)
    target = root / name
    target.parent.mkdir(parents=True, exist_ok=True)
    if not target.exists():
        shutil.copyfile(filename, target)
    with target.open("rb") as stream:
        V.require(hashlib.file_digest(stream, "sha256").hexdigest() == digest, "native input changed during capture")
    return dict(path=name, sha256=digest, sizeBytes=target.stat().st_size)


def retain_bytes(root, data, name):
    V.path(name)
    V.require("/" not in name, "metadata name must be a basename")
    target = Path(root) / "native-files" / V.digest(data) / name
    target.parent.mkdir(parents=True, exist_ok=True)
    if target.exists():
        V.require(target.read_bytes() == data, "native metadata collision")
    else:
        target.write_bytes(data)
    return dict(path=target.relative_to(root).as_posix(), sha256=V.digest(data), sizeBytes=len(data))


def process_environment(environment=None):
    environment = os.environ if environment is None else environment
    result = {key: environment[key] for key in ENVIRONMENT_KEYS if key in environment}
    V.require(result, "native tool environment is empty")
    return result


def traced_command(arguments, environment, trace, **kwargs):
    tracer = shutil.which("strace")
    V.require(tracer is not None, "Linux strace is required for actual loaded-library evidence")
    return subprocess.run([tracer, "-f", "-qq", "-yy", "-s", "65535", "-e", "trace=mmap",
                           "-o", str(trace), "--", *arguments], env=environment, check=False, **kwargs)


def trace_lines(filename):
    with Path(filename).open() as stream:
        yield from stream


def mapped_libraries(root, trace):
    libraries = set()
    for line in trace_lines(trace):
        if not re.search(r"= (?:0x[0-9a-f]+|[0-9]+)\s*$", line):
            continue
        for filename in re.findall(r"[0-9]+<(/[^<>]+)>", line):
            if re.search(r"\.so(?:\.|$)", filename):
                V.require(not filename.endswith(" (deleted)"), "loaded library disappeared during capture")
                with Path(filename).open("rb") as stream:
                    if stream.read(4) == b"\x7fELF":
                        libraries.add(filename)
    return [retain(root, name) for name in sorted(libraries)]


def executable_interpreter(filename):
    with Path(filename).open("rb") as stream:
        header = stream.read(64)
        V.require(header[:4] == b"\x7fELF" and header[4] in (1, 2) and header[5] in (1, 2),
                  "native Linux tool must be an ELF executable")
        endian = "<" if header[5] == 1 else ">"
        wide = header[4] == 2
        offset = struct.unpack_from(endian + ("Q" if wide else "I"), header, 32 if wide else 28)[0]
        size, count = struct.unpack_from(endian + "HH", header, 54 if wide else 42)
        V.require(size >= (56 if wide else 32), "invalid tool ELF program headers")
        for index in range(count):
            stream.seek(offset + index * size)
            program = stream.read(size)
            V.require(len(program) == size, "truncated tool ELF program headers")
            if struct.unpack_from(endian + "I", program)[0] != 3:
                continue
            location = struct.unpack_from(endian + ("Q" if wide else "I"), program, 8 if wide else 4)[0]
            length = struct.unpack_from(endian + ("Q" if wide else "I"), program, 32 if wide else 16)[0]
            V.require(1 < length < 4096, "invalid tool ELF interpreter")
            stream.seek(location)
            value = stream.read(length)
            V.require(len(value) == length and value[-1:] == b"\0", "truncated tool ELF interpreter")
            name = value[:-1].decode()
            V.require(Path(name).is_absolute(), "tool ELF interpreter is not absolute")
            return name
    return None


def loaded_libraries(root, trace, executable):
    records = mapped_libraries(root, trace)
    interpreter = executable_interpreter(executable)
    if interpreter is not None:
        record = retain(root, interpreter)
        if record not in records:
            records.append(record)
    return sorted(records, key=lambda row: row["path"])


def record_tool(root, identity, executable_path, version_argv=None, environment=None):
    """Capture a real version invocation; version_argv is the complete argv, when supplied."""
    root = Path(root).resolve(strict=True)
    executable_path = str(executable_path)
    V.require(Path(executable_path).is_absolute(), "native tool executable must be absolute")
    version_argv = [executable_path, "--version"] if version_argv is None else list(version_argv)
    V.require(version_argv and version_argv[0] == executable_path, "version command uses a different executable")
    environment = dict(os.environ if environment is None else environment)
    executable = retain(root, executable_path)
    with tempfile.TemporaryDirectory(prefix=".native-tool-", dir=root) as temporary:
        trace = Path(temporary) / "mmap.trace"
        result = traced_command(version_argv, environment, trace, stdout=subprocess.PIPE, stderr=subprocess.STDOUT)
        V.require(result.returncode == 0 and result.stdout.strip(), "native tool version command failed: " + shlex.join(version_argv))
        libraries = loaded_libraries(root, trace, executable_path)
        trace_record = retain(root, trace)
    V.require(retain(root, executable_path) == executable, "native tool changed during version capture")
    return dict(identity=identity, executablePath=executable_path, executable=executable,
                version=retain_bytes(root, result.stdout, "version.txt"),
                environment=retain_bytes(root, V.canonical(process_environment(environment)), "environment.json"),
                loadedLibraries=libraries, libraryTrace=trace_record,
                versionCommand=retain_bytes(root, V.canonical(version_argv), "version-argv.json"))


def response_files(arguments, cwd):
    result = {}
    def visit(values):
        for value in values:
            if not value.startswith("@"):
                continue
            filename = (Path(cwd) / value[1:]).resolve(strict=True)
            V.require(filename not in result, "duplicate or recursive native response file")
            data = filename.read_bytes()
            V.require(data.strip(), "empty native response file")
            result[filename] = data
            visit(shlex.split(data.decode()))
    visit(arguments)
    return result


def run(root, identity, arguments, version_argv=None, environment=None):
    """Execute the real compiler/linker and retain its argv and libraries before returning."""
    root = Path(root).resolve(strict=True)
    V.require(arguments and Path(arguments[0]).is_absolute(), "native invocation requires an absolute executable")
    environment = dict(os.environ if environment is None else environment)
    cwd = Path.cwd()
    responses = response_files(arguments, cwd)
    tool = record_tool(root, identity, arguments[0], version_argv, environment)
    with tempfile.TemporaryDirectory(prefix=".native-run-", dir=root) as temporary:
        trace = Path(temporary) / "mmap.trace"
        result = traced_command(arguments, environment, trace)
        tool["loadedLibraries"] = loaded_libraries(root, trace, arguments[0])
        tool["libraryTrace"] = retain(root, trace)
    V.require(retain(root, arguments[0]) == tool["executable"], "native tool changed during execution")
    for filename, data in responses.items():
        V.require(filename.read_bytes() == data, "native response file changed during execution")
    return dict(argv=retain_bytes(root, V.canonical(arguments), "argv.json"), toolchain=tool,
                cwd=str(cwd), responseFiles=[retain(root, name) for name in responses], exitCode=result.returncode)


def capture_linker(root, executable, arguments, metadata_directory):
    """Wrap the actual linker so driver-owned temporary response files survive its return."""
    root = Path(root).resolve(strict=True)
    executable = str(executable)
    V.require(Path(executable).is_absolute(), "captured linker executable must be absolute")
    metadata_directory = Path(metadata_directory).resolve(strict=True)
    V.require(metadata_directory.is_relative_to(root), "linker metadata must stay inside evidence root")
    argv = [executable, *arguments]
    responses = response_files(argv, Path.cwd())
    invocation = dict(kind="hostwright.native-link-invocation.v1", executablePath=executable,
        executable=retain(root, executable), argv=retain_bytes(root, V.canonical(argv), "argv.json"),
        cwd=str(Path.cwd()), environment=retain_bytes(root, V.canonical(process_environment()), "environment.json"),
        responseFiles=[dict(originalPath=str(name), file=retain(root, name)) for name in responses])
    result = subprocess.run(argv, check=False)
    V.require(retain(root, executable) == invocation["executable"], "linker changed during invocation")
    for name, data in responses.items():
        V.require(name.read_bytes() == data, "linker response changed during invocation")
    invocation["exitCode"] = result.returncode
    (metadata_directory / (uuid.uuid4().hex + ".json")).write_bytes(V.canonical(invocation))
    return result.returncode


def source_file(filename, roots, projects):
    filename = Path(filename).resolve(strict=True)
    candidates = []
    for identity, directory in roots.items():
        directory = Path(directory).resolve(strict=True)
        if not filename.is_relative_to(directory):
            continue
        relative = filename.relative_to(directory).as_posix()
        leaf = projects[identity].get(relative)
        if leaf is not None:
            V.require(leaf["gitMode"] != "120000" and leaf["sha256"] == V.digest(filename.read_bytes()),
                      "compiled source differs from captured Git leaf: " + str(filename))
            candidates.append(dict(project=identity, path=relative, sha256=leaf["sha256"]))
    V.require(len(candidates) == 1, "compiled source lacks a unique captured Git mapping: " + str(filename))
    return candidates[0]


def depfile_sources(filename):
    text = Path(filename).read_text().replace("\\\n", "")
    dependencies = []
    for line in text.splitlines():
        if not line.strip():
            continue
        target, separator, inputs = line.partition(":")
        V.require(separator and target.strip(), "unsupported native dependency file")
        dependencies.extend(shlex.split(inputs))
    V.require(dependencies, "empty native dependency file")
    return dependencies


def compile_dependencies(cwd, obj, dependency):
    dependency = Path(dependency)
    if dependency.is_file():
        return [(cwd / name).resolve(strict=True) for name in depfile_sources(dependency)]
    directory = next((base for base in (cwd, *cwd.parents) if (base / "build.ninja").is_file()), None)
    ninja = shutil.which("ninja")
    V.require(directory is not None and ninja is not None,
              "compiler depfile is absent and no Ninja dependency database is available: " + str(dependency))
    target = os.path.relpath(obj, directory)
    result = subprocess.run([ninja, "-C", str(directory), "-t", "deps", target],
                            stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True, check=False)
    lines = result.stdout.splitlines()
    V.require(result.returncode == 0 and lines and re.search(r": #deps [0-9]+, deps mtime [0-9]+ \(VALID\)$", lines[0]),
              "Ninja lacks current compiler dependencies for " + str(obj))
    sources = [line.strip() for line in lines[1:] if line.startswith("    ")]
    V.require(sources, "Ninja compiler dependency record is empty")
    return [(directory / name).resolve(strict=True) for name in sources]


def source_map_from_compile_commands(filename, roots, projects):
    """Map existing object bytes using compile_commands.json and actual -MF depfiles."""
    rows = V.parse(Path(filename).read_bytes())
    V.require(isinstance(rows, list) and rows, "empty compilation database")
    result = []
    for row in rows:
        cwd = Path(row["directory"]).resolve(strict=True)
        arguments = row.get("arguments") or shlex.split(row["command"])
        output = row.get("output")
        if output is None and "-o" in arguments:
            output = arguments[arguments.index("-o") + 1]
        V.require(output, "compile command lacks an explicit object output")
        obj = (cwd / output).resolve(strict=True)
        sources = [row["file"]]
        dependency = None
        for index, argument in enumerate(arguments):
            if argument == "-MF":
                dependency = arguments[index + 1]
            elif argument.startswith("-MF") and len(argument) > 3:
                dependency = argument[3:]
        if dependency is not None:
            sources.extend(compile_dependencies(cwd, obj, cwd / dependency))
        elif any(argument in ("-MD", "-MMD") for argument in arguments):
            sources.extend(compile_dependencies(cwd, obj, obj.with_suffix(".d")))
        mapped = {}
        for name in sources:
            source = source_file(cwd / name, roots, projects)
            mapped[V.canonical(source)] = source
        result.append(dict(object=str(obj), objectSHA256=V.digest(obj.read_bytes()),
                           sourceFiles=[mapped[key] for key in sorted(mapped)]))
    return result


def source_map_from_swift_output_map(filename, roots, projects, source_list=None, cwd=None):
    """Use Swift's emitted source/output mapping; module-wide objects require its source list."""
    filename = Path(filename).resolve(strict=True)
    cwd = Path.cwd() if cwd is None else Path(cwd)
    outputs = V.parse(filename.read_bytes())
    module_sources = shlex.split(Path(source_list).read_text()) if source_list else []
    result = []
    for source, output in outputs.items():
        if "object" not in output:
            continue
        sources = module_sources or ([source] if source else [])
        V.require(sources, "module-wide Swift object requires the actual source list")
        obj = (cwd / output["object"]).resolve(strict=True)
        result.append(dict(object=str(obj), objectSHA256=V.digest(obj.read_bytes()),
                           sourceFiles=[source_file(cwd / name, roots, projects) for name in sources]))
    V.require(result, "Swift output file map has no retained objects")
    return result


def collect_link(root, specification, projects, tools):
    """Retain a real LLD map and exact selected occurrences; refuse unattributed SDK objects.

    specification: output, path, map, cwd, commands (actual argv arrays), responseFiles,
    sourceMap (objectSHA256/sourceFiles rows, optionally restricted by mapInput).
    projects is the leaf dictionary returned by verifier.source_project for every source.
    tools maps authenticated executable paths to executable SHA256 values.
    """
    root = Path(root).resolve(strict=True)
    cwd = Path(specification["cwd"]).resolve(strict=True)
    map_path = Path(specification["map"])
    map_data = map_path.read_text()
    selected = V.lld_map_inputs(map_data)
    sections = V.lld_map_sections(map_data)
    ledger = []
    files = {}
    source_index = {}
    for row in specification["sourceMap"]:
        source_index.setdefault(row["objectSHA256"], []).append(row)
    for name in sorted(selected):
        match = re.fullmatch(r"(.+\.a)\(([^()]+)\)", name)
        filename = cwd / (match[1] if match else name)
        if filename not in files:
            data = filename.read_bytes()
            files[filename] = (data, V.archive_entries(data) if match else None, retain(root, filename))
        data, entries, file_record = files[filename]
        occurrences = V.selected_archive_entries(data, match[2], sections[name], entries) if match else [(None, data)]
        for offset, obj in occurrences:
            digest = V.digest(obj)
            candidates = [row for row in source_index.get(digest, []) if row.get("mapInput", name) == name]
            attributions = {V.canonical(row["sourceFiles"]) for row in candidates}
            V.require(len(attributions) == 1, "missing or ambiguous compiled-source mapping for " + name + " (" + digest + ")")
            item = dict(mapInput=name, file=file_record, objectSHA256=digest,
                        sourceFiles=V.parse(next(iter(attributions))))
            if match:
                item.update(member=match[2], archiveOffset=offset)
            ledger.append(item)
    link = dict(path=V.path(specification["path"]), outputSHA256=V.digest(Path(specification["output"]).read_bytes()),
                map=retain(root, map_path), selectedInputs=ledger,
                commands=[retain_bytes(root, V.canonical(argv), "argv.json") for argv in specification["commands"]],
                responseFiles=[retain(root, name) for name in specification["responseFiles"]])
    V.link_closure(link, Path(specification["output"]).read_bytes(), projects,
                   lambda name: (root / V.path(name)).read_bytes(), tools)
    return link


def successful_execs(trace):
    """Decode successful strace execve records, including unfinished/resumed calls."""
    import json
    decoder = json.JSONDecoder()
    pending = {}
    result = []
    for line in trace_lines(trace):
        match = re.match(r"\s*([0-9]+)\s+execve\((.*)", line)
        if match:
            pid, body = match.groups()
            executable, end = decoder.raw_decode(body)
            body = body[end:].lstrip()
            V.require(body.startswith(","), "unsupported native exec trace")
            arguments, end = decoder.raw_decode(body[1:].lstrip())
            call = dict(executablePath=executable, argv=arguments)
            if re.search(r"= 0\s*$", line):
                result.append(call)
            elif "<unfinished ...>" in line:
                pending[pid] = call
        else:
            resumed = re.match(r"\s*([0-9]+)\s+<\.\.\. execve resumed>.*= 0\s*$", line)
            if resumed and resumed[1] in pending:
                result.append(pending.pop(resumed[1]))
    return result


def retain_map_inputs(root, map_file, cwd):
    map_data = Path(map_file).read_text()
    sections = V.lld_map_sections(map_data)
    files = {}
    result = []
    for name in sorted(V.lld_map_inputs(map_data)):
        match = re.fullmatch(r"(.+\.a)\(([^()]+)\)", name)
        filename = Path(cwd) / (match[1] if match else name)
        if filename not in files:
            data = filename.read_bytes()
            files[filename] = (data, V.archive_entries(data) if match else None, retain(root, filename))
        data, entries, record = files[filename]
        selected = V.selected_archive_entries(data, match[2], sections[name], entries) if match else [(None, data)]
        for offset, obj in selected:
            value = dict(mapInput=name, file=record, objectSHA256=V.digest(obj))
            if match:
                value.update(member=match[2], archiveOffset=offset)
            result.append(value)
    return result


def retain_build(root, kind, tree, traces=(), maps=(), linker_invocations=None):
    """Save generated evidence while build paths and SDK archives still exist."""
    root = Path(root).resolve(strict=True)
    tree = Path(tree).resolve(strict=True)
    metadata = []
    invocations = []
    tool_paths = set()
    unresolved = []
    if kind == "kernel":
        candidates = sorted(tree.rglob("*.cmd")) + sorted(tree.rglob("*.d")) + [tree / ".config"]
    else:
        build = tree / ".build"
        V.require(build.is_dir(), "missing Swift build directory")
        suffixes = {".d", ".dia", ".rsp", ".resp", ".LinkFileList", ".autolink"}
        names = {"sources", "output-file-map.json", "description.json", "release.yaml", "compile_commands.json"}
        candidates = sorted(item for item in build.rglob("*") if item.is_file() and
                            (item.suffix in suffixes or item.name in names))
    for filename in candidates:
        metadata.append(dict(originalPath=str(filename), file=retain(root, filename)))
        if kind != "kernel" or filename.suffix != ".cmd":
            continue
        for line in filename.read_text().splitlines():
            if not line.startswith(("savedcmd_", "cmd_")) or " := " not in line:
                continue
            target, command = line.split(" := ", 1)
            lexer = shlex.shlex(command, posix=True, punctuation_chars=";&|")
            lexer.whitespace_split = True
            values = list(lexer)
            for index, value in enumerate(values):
                if not re.fullmatch(r"(?:[^\s]*/)?(?:[A-Za-z0-9_.-]+-)?(?:gcc|clang|ld|ld.lld)(?:-[0-9]+)?", value):
                    continue
                executable = shutil.which(value)
                if not executable:
                    unresolved.append(dict(commandFile=str(filename), executable=value))
                    continue
                arguments = [executable]
                for argument in values[index + 1:]:
                    if re.fullmatch(r"[;&|]+", argument):
                        break
                    arguments.append(argument)
                tool_paths.add(executable)
                invocations.append(dict(executablePath=executable,
                    argv=retain_bytes(root, V.canonical(arguments), "argv.json"),
                    commandFile=retain(root, filename), target=target.split("_", 1)[1]))
    for trace in traces:
        metadata.append(dict(originalPath=str(trace), file=retain(root, trace)))
        for call in successful_execs(trace):
            name = Path(call["executablePath"]).name
            if not re.fullmatch(r"(?:swift-frontend|swiftc|clang(?:\+\+)?(?:-[0-9]+)?|ld.lld|lld)", name):
                continue
            if linker_invocations is not None and name in ("ld.lld", "lld"):
                continue
            executable = call["executablePath"]
            V.require(Path(executable).is_absolute(), "trace compiler executable is not absolute")
            argv = call["argv"]
            V.require(argv and argv[0] == executable, "trace executable and argv entrypoint differ")
            tool_paths.add(executable)
            response_records = []
            try:
                response_records = [dict(originalPath=str(path), file=retain(root, path))
                                    for path in response_files(argv, tree)]
            except FileNotFoundError as error:
                unresolved.append(dict(executable=executable, missingResponse=str(error.filename)))
            invocations.append(dict(executablePath=executable, argv=retain_bytes(root, V.canonical(argv), "argv.json"),
                                    responseFiles=response_records))
    if linker_invocations is not None:
        captured = sorted(Path(linker_invocations).glob("*.json"))
        V.require(captured, "missing wrapped native linker invocations")
        for filename in captured:
            invocation = V.parse(filename.read_bytes())
            V.require(invocation.get("kind") == "hostwright.native-link-invocation.v1" and invocation.get("exitCode") == 0,
                      "native linker capture failed")
            V.require(retain(root, invocation["executablePath"]) == invocation["executable"], "captured linker bytes changed")
            V.bound(invocation["argv"], lambda name: (root / V.path(name)).read_bytes())
            for response in invocation["responseFiles"]:
                V.bound(response["file"], lambda name: (root / V.path(name)).read_bytes())
            invocation["capture"] = retain(root, filename)
            tool_paths.add(invocation["executablePath"])
            invocations.append(invocation)
    V.require(invocations, "native build has no retained compiler/linker invocations")
    tools = [record_tool(root, "native-" + V.digest(path.encode())[:16], path) for path in sorted(tool_paths)]
    links = [dict(map=retain(root, name), selectedInputs=retain_map_inputs(root, name, tree)) for name in maps]
    return dict(status="prepared-not-release-qualified", kind=kind, buildDirectory=str(tree),
                metadata=metadata, invocations=invocations, toolchain=tools, links=links,
                unresolved=unresolved, sourceAttribution="requires captured compiler dependencies and SDK source mappings")


def main():
    parser = argparse.ArgumentParser()
    subparsers = parser.add_subparsers(dest="operation", required=True)
    tool_parser = subparsers.add_parser("tool")
    run_parser = subparsers.add_parser("run")
    for child in (tool_parser, run_parser):
        child.add_argument("--root", type=Path, required=True)
        child.add_argument("--identity", required=True)
        child.add_argument("--metadata", type=Path, required=True)
        child.add_argument("argv", nargs=argparse.REMAINDER)
    build_parser = subparsers.add_parser("retain-build")
    build_parser.add_argument("--root", type=Path, required=True)
    build_parser.add_argument("--kind", choices=("kernel", "swift"), required=True)
    build_parser.add_argument("--tree", type=Path, required=True)
    build_parser.add_argument("--trace", type=Path, action="append", default=[])
    build_parser.add_argument("--map", type=Path, action="append", default=[])
    build_parser.add_argument("--link-invocations", type=Path)
    build_parser.add_argument("--metadata", type=Path, required=True)
    linker_parser = subparsers.add_parser("linker")
    linker_parser.add_argument("--root", type=Path, required=True)
    linker_parser.add_argument("--executable", type=Path, required=True)
    linker_parser.add_argument("--metadata-dir", type=Path, required=True)
    linker_parser.add_argument("argv", nargs=argparse.REMAINDER)
    args = parser.parse_args()
    if args.operation == "retain-build":
        value = retain_build(args.root, args.kind, args.tree, args.trace, args.map, args.link_invocations)
    else:
        arguments = args.argv[1:] if args.argv[:1] == ["--"] else args.argv
        V.require(arguments, "missing native command")
        if args.operation == "linker":
            raise SystemExit(capture_linker(args.root, args.executable, arguments, args.metadata_dir))
        elif args.operation == "tool":
            value = record_tool(args.root, args.identity, arguments[0], arguments)
        else:
            value = run(args.root, args.identity, arguments)
    with args.metadata.open("xb") as stream:
        stream.write(V.canonical(value))
    if args.operation == "run":
        raise SystemExit(value["exitCode"])


if __name__ == "__main__":
    main()
