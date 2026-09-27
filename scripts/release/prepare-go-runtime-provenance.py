#!/usr/bin/env python3
"""Bind both loader builds to complete source projects before retaining a fragment."""

import argparse
import importlib.util
from pathlib import Path


SPEC = importlib.util.spec_from_file_location("verifier", Path(__file__).with_name("verify-runtime-provenance.py"))
V = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(V)
NATIVE_SPEC = importlib.util.spec_from_file_location("native_capture", Path(__file__).with_name("capture-native-runtime-build.py"))
NATIVE = importlib.util.module_from_spec(NATIVE_SPEC)
NATIVE_SPEC.loader.exec_module(NATIVE)


def capture_toolchain(root, capture, commands, fetch):
    environment = V.parse(V.bound(capture["environment"], fetch))
    specifications = {}

    def add(identity, executable, digest, arguments):
        previous = specifications.get(executable)
        current = (identity, digest, arguments)
        V.require(previous is None or previous == current, "Go build used conflicting executable bytes")
        specifications[executable] = current

    add("go-driver", capture["command"][0], capture["executable"]["sha256"], [capture["command"][0], "version"])
    interpreter = capture["toolExec"]["interpreterPath"]
    add("go-collector-python", interpreter, capture["toolExec"]["interpreter"]["sha256"], [interpreter, "--version"])
    for command in commands:
        executable = command["argv"][0]
        add("go-" + Path(executable).name, executable, command["executable"]["sha256"], [executable, "-V=full"])
        if "headerTrace" in command:
            trace = command["headerTrace"]
            executable = trace["argv"][0]
            add("go-header-tracer", executable, trace["executable"]["sha256"], [executable, "--version"])
    result = []
    for executable, (identity, expected, arguments) in sorted(specifications.items()):
        tool = NATIVE.record_tool(root, identity, executable, arguments, environment)
        V.require(tool["executable"]["sha256"] == expected, "Go tool changed after the captured build")
        result.append(tool)
    return result


def prepare(root, source_commit, pins):
    root = root.resolve(strict=True)
    output = root / "loader-provenance.json"
    evidence_directory = root / "loader-evidence"
    if output.exists() or output.is_symlink() or evidence_directory.exists() or evidence_directory.is_symlink():
        raise ValueError("loader provenance already exists")

    def fetch(name):
        filename = root / V.path(name)
        if filename.is_symlink() or not filename.resolve().is_relative_to(root):
            raise ValueError("loader evidence escapes its root")
        return filename.read_bytes()

    def record(name, data=None):
        data = fetch(name) if data is None else data
        return dict(path=name, sha256=V.digest(data), sizeBytes=len(data))

    def rebase(value, prefix):
        if isinstance(value, dict):
            result = {key: rebase(item, prefix) for key, item in value.items()}
            if {"path", "sha256", "sizeBytes"} <= set(result):
                result["path"] = prefix + V.path(result["path"])
            return result
        return [rebase(item, prefix) for item in value] if isinstance(value, list) else value

    catalog = V.parse(fetch("source-projects/projects.json"))
    source_projects = [rebase(item["project"], "source-projects/" + V.path(item["directory"]) + "/") for item in catalog]
    expected = {"hostwright": source_commit, pins["go"]["identity"]: pins["go"]["commit"],
                **{item["identity"]: item["commit"] for item in pins["modules"]}}
    V.require(len(source_projects)==len(expected) and {p['identity']:p['commit'] for p in source_projects}==expected,
              "Go source project commits differ from the locked release inputs")
    projects = {item["identity"]: V.source_project(item, fetch) for item in source_projects}
    module_pins = {item["module"]: item for item in pins["modules"]}
    first_payload = fetch("capture-first/payload")
    V.require(first_payload==fetch("capture-second/payload"), "Go loader rebuilds differ")
    fragments = []
    captured_tools = None
    first_capture = first_commands = None
    for pass_name in ("first", "second"):
        prefix = "capture-" + pass_name + "/"
        capture_record = record(prefix + "build.json")
        capture = V.parse(fetch(capture_record["path"]))
        commands = [V.parse(V.bound(item, lambda name: fetch(prefix + name))) for item in capture["commands"]]
        tools = {item["argv"][0]: item["executable"]["sha256"] for item in commands}
        tools[capture["command"][0]] = capture["executable"]["sha256"]
        tools[capture["toolExec"]["interpreterPath"]] = capture["toolExec"]["interpreter"]["sha256"]
        tools.update({item["headerTrace"]["argv"][0]: item["headerTrace"]["executable"]["sha256"]
                      for item in commands if "headerTrace" in item})
        V.require(captured_tools is None or tools == captured_tools, "Go rebuild toolchains differ")
        if captured_tools is None:
            captured_tools = tools
            first_capture, first_commands = capture, commands
        packages, _ = V.go_capture(capture_record, first_payload, fetch, tools)
        package_metadata = {item["ImportPath"]: item for item in V.parse(V.bound(capture["packages"], lambda name: fetch(prefix + name)))}
        goroot = V.parse(V.bound(capture["goEnvironment"], lambda name: fetch(prefix + name)))["GOROOT"]
        trace = []
        sources = {}
        for name, package in sorted(packages.items()):
            metadata = package_metadata[name]
            module = metadata.get("Module", {})
            owner = "go-runtime" if metadata.get("Standard") else "hostwright" if module.get("Main") else module_pins[module["Path"]]["identity"]
            selected = []
            for filename, digest in sorted(package["sources"]):
                if filename.startswith(goroot + "/src/"):
                    project, relative = "go-runtime", filename[len(goroot)+1:]
                elif filename.startswith(goroot + "/pkg/include/"):
                    project, relative = "go-runtime", "src/runtime/" + Path(filename).name
                else:
                    project = owner
                    relative = Path(filename).relative_to(module["Dir"]).as_posix()
                    if project=="hostwright":
                        relative = "Guest/HostwrightNetfilter/" + relative
                V.require(projects[project].get(relative, {}).get("sha256")==digest, "Go compiled input differs from complete Git source")
                source = dict(project=project, path=relative, originalPath=filename, sha256=digest)
                selected.append(source)
                sources[V.canonical(source)] = source
            trace.append(dict(package=name, project=owner, archive=rebase(package["archive"], prefix), sourceFiles=selected))
        version, build_modules = V.go_build_info(first_payload)
        V.require(version==pins["go"]["version"], "Go loader toolchain differs from the reviewed version")
        modules = []
        for module in build_modules:
            project = "hostwright" if module[0]=="dev.hostwright/guest-netfilter" else module_pins[module[0]]["identity"]
            V.require(module[1]==("(devel)" if project=="hostwright" else module_pins[module[0]]["version"]), "Go linked module differs from pinned version")
            modules.append(dict(project=project, revision=expected[project], buildInfo=module))
        V.require({item['project'] for item in modules}==set(expected)-{'go-runtime'}, "Go linked module coverage differs from source pins")
        generated = {}
        def metadata_record(name, value):
            name = "loader-evidence/" + pass_name + "/" + name
            data = V.canonical(value)
            generated[name] = data
            return record(name, data)
        compiler = next(item["executable"] for item in commands if Path(item["argv"][0]).name=="compile")
        loader = dict(format="go-buildinfo-v1", path="share/hostwright/containerization/guest/hostwright-netfilter",
                      outputSHA256=V.digest(first_payload), project="hostwright", goRuntimeProject="go-runtime", goVersion=version,
                      modules=modules, moduleRevisions={item["project"]: item["revision"] for item in modules}, sourceFiles=list(sources.values()),
                      compiler=rebase(compiler, prefix), commands=[metadata_record("argv/"+str(i)+".json", item["argv"]) for i,item in enumerate(commands)],
                      packageTrace=metadata_record("package-trace.json", trace), buildCapture=capture_record)
        V.go_loader(loader, first_payload, projects, lambda name: generated[name] if name in generated else fetch(name), tools)
        fragments.append((loader, generated))
    toolchain = capture_toolchain(root, first_capture, first_commands, lambda name: fetch("capture-first/" + name))
    for _, generated in fragments:
        for name, data in generated.items():
            filename = root / name
            filename.parent.mkdir(parents=True, exist_ok=True)
            with filename.open("xb") as stream:
                stream.write(data)
    fragment = dict(status="prepared-not-release-qualified", sourceCommit=source_commit,
                    sourceProjects=source_projects, loader=fragments[0][0], reproducibleBuild=fragments[1][0],
                    toolchain=toolchain)
    with output.open("xb") as stream:
        stream.write(V.canonical(fragment))
    return fragment


if __name__ == "__main__":
    parser = argparse.ArgumentParser()
    parser.add_argument("--root", type=Path, required=True)
    parser.add_argument("--source-commit", required=True)
    parser.add_argument("--pins", type=Path, default=Path(__file__).with_name("runtime-go-sources.json"))
    args = parser.parse_args()
    prepare(args.root, args.source_commit, V.parse(args.pins.read_bytes()))
