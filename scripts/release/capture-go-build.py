#!/usr/bin/env python3
"""Retain Go tool invocations and the exact package archives consumed by the linker."""

import argparse
import errno
import hashlib
import importlib.util
import json
import os
from pathlib import Path
import re
import shlex
import shutil
import subprocess
import sys
import tarfile
import tempfile
import uuid


def canonical(value):
    return (json.dumps(value, sort_keys=True, separators=(",", ":")) + "\n").encode()


def retain(root, filename):
    filename = Path(filename).resolve(strict=True)
    if not filename.is_file():
        raise ValueError("build input is not a regular file: " + str(filename))
    digest = hashlib.sha256()
    with filename.open("rb") as stream:
        for block in iter(lambda: stream.read(1024 * 1024), b""):
            digest.update(block)
    target = root / "files" / digest.hexdigest()
    if not target.exists():
        descriptor, temporary = tempfile.mkstemp(prefix=".input-", dir=target.parent)
        try:
            with os.fdopen(descriptor, "wb") as output, filename.open("rb") as source:
                shutil.copyfileobj(source, output)
            if hashlib.sha256(Path(temporary).read_bytes()).hexdigest() != digest.hexdigest():
                raise ValueError("build input changed during capture: " + str(filename))
            os.replace(temporary, target)
        finally:
            Path(temporary).unlink(missing_ok=True)
    return dict(path=str(target.relative_to(root)), sha256=digest.hexdigest(),
                sizeBytes=target.stat().st_size)


def prepare(repository, commit, archive_path, archive_sha256, output):
    spec = importlib.util.spec_from_file_location("source_capture", Path(__file__).with_name("capture-runtime-source.py"))
    source = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(source)
    if not output.is_absolute() or not output.parent.is_dir() or output.exists() or output.is_symlink():
        raise ValueError("toolchain requires a new absolute output in an existing parent")
    with archive_path.open("rb") as archive:
        actual = hashlib.file_digest(archive, "sha256").hexdigest()
    if actual != archive_sha256:
        raise ValueError("Go distribution archive digest mismatch")
    with tempfile.TemporaryDirectory(prefix=".go-source-toolchain-", dir=output.parent) as temporary:
        staging = Path(temporary) / "prepared"
        staging.mkdir(mode=0o700)
        source.capture(repository, commit, staging / "source")
        tree = staging / "toolchain"
        subprocess.run(["git", "clone", "--quiet", "--no-hardlinks", "--no-checkout", str(repository), str(tree)], check=True)
        subprocess.run(["git", "-C", str(tree), "checkout", "--quiet", "--detach", commit], check=True)
        files = []
        names = set()
        with tarfile.open(archive_path, "r:gz") as archive:
            for member in archive:
                if not member.name.startswith(("go/bin/", "go/pkg/tool/", "go/pkg/include/")):
                    continue
                if member.isdir():
                    continue
                if not member.isfile() or member.size > 512 * 1024**2:
                    raise ValueError("unsafe Go distribution tool entry")
                relative = source.VERIFIER.path(member.name.removeprefix("go/"))
                if relative in names:
                    raise ValueError("duplicate Go distribution tool entry")
                names.add(relative)
                target = tree / relative
                if target.exists() or target.is_symlink():
                    raise ValueError("Go tool overlay collides with source")
                if not target.parent.resolve().is_relative_to(tree.resolve()):
                    raise ValueError("Go tool overlay escapes source tree")
                data = archive.extractfile(member).read()
                if relative.startswith("pkg/include/"):
                    header = "src/runtime/" + target.name
                    if source.git(repository, "show", commit + ":" + header) != data:
                        raise ValueError("Go assembler header differs from pinned source")
                target.parent.mkdir(parents=True, exist_ok=True)
                target.write_bytes(data)
                target.chmod(0o755 if member.mode & 0o111 else 0o644)
                files.append(dict(path=relative, sha256=hashlib.sha256(data).hexdigest(), sizeBytes=len(data)))
        required = {"bin/go", "pkg/tool/linux_arm64/compile", "pkg/tool/linux_arm64/asm", "pkg/tool/linux_arm64/link"}
        if not required <= names:
            raise ValueError("Go distribution lacks required Linux arm64 tools")
        if source.git(tree, "status", "--porcelain=v1", "--untracked-files=all"):
            raise ValueError("Go tool overlay changed the pinned source tree")
        (staging / "tool-overlay.json").write_bytes(canonical(dict(sourceCommit=commit,
            toolchainArchiveSHA256=archive_sha256, files=sorted(files, key=lambda item: item["path"]))))
        os.rename(staging, output)


def tool(root, arguments):
    if not arguments or not Path(arguments[0]).is_absolute():
        raise ValueError("an absolute Go tool executable is required")
    root = root.resolve(strict=True)
    name = Path(arguments[0]).name
    if name not in {"compile", "asm", "link", "pack", "cgo", "cover", "preprofile"}:
        raise ValueError("unsupported Go build tool: " + name)
    environment_keys = ("PATH", "HOME", "TMPDIR", "GOCACHE", "GOMODCACHE", "GOPROXY", "GOSUMDB",
                        "GOENV", "GOFLAGS", "GOWORK", "GOTOOLCHAIN", "GOOS", "GOARCH", "CGO_ENABLED",
                        "GOMAXPROCS", "GOEXPERIMENT", "GOTELEMETRY", "LANG", "TZ", "GOROOT",
                        "GOROOT_FINAL", "TOOLEXEC_IMPORTPATH", "LC_CTYPE", "GODEBUG")
    invocation = dict(argv=arguments, cwd=os.getcwd(),
                      environment={key: os.environ[key] for key in environment_keys if key in os.environ},
                      package=os.environ.get("TOOLEXEC_IMPORTPATH", ""),
                      executable=retain(root, arguments[0]), inputs=[], includeCandidates=[], packageArchives=[])
    invocation["collector"] = dict(path=str(Path(__file__).resolve()), file=retain(root, Path(__file__)))
    outputs = []
    for index, argument in enumerate(arguments[1:], 1):
        if arguments[index - 1] in {"-o", "-asmhdr"}:
            outputs.append(Path(argument))
            continue
        if argument.startswith("-"):
            continue
        candidate = Path(argument)
        try:
            regular = candidate.is_file()
        except OSError as error:
            if error.errno != errno.ENAMETOOLONG:
                raise
            regular = False
        if regular:
            invocation["inputs"].append(dict(originalPath=str(candidate.resolve()),
                                             file=retain(root, candidate)))
        if arguments[index - 1] == "-I":
            for header in sorted(candidate.glob("*.h")):
                invocation["includeCandidates"].append(dict(originalPath=str(header.resolve()),
                                                           file=retain(root, header)))
        if arguments[index - 1] == "-importcfg":
            for line in candidate.read_text().splitlines():
                if not line.startswith("packagefile "):
                    continue
                package, archive = line.removeprefix("packagefile ").split("=", 1)
                invocation["packageArchives"].append(dict(package=package, originalPath=archive,
                                                          file=retain(root, archive)))
    invocation["openedHeaders"] = []
    if name == "asm" and "-o" in arguments:
        tracer = shutil.which("strace")
        if tracer is None:
            raise ValueError("Linux strace is required to capture assembler header reads")
        with tempfile.TemporaryDirectory(prefix=".asm-trace-", dir=root) as temporary:
            trace = Path(temporary) / "opens.trace"
            command = [tracer, "-f", "-qq", "-yy", "-s", "65535", "-e",
                       "trace=open,openat,openat2", "-o", str(trace), "--", *arguments]
            result = subprocess.run(command, check=False)
            roots = {Path(item["originalPath"]).parent for item in invocation["inputs"]
                     if item["originalPath"].endswith(".s")}
            roots.update(Path(arguments[index + 1]).resolve() for index, item in enumerate(arguments[:-1]) if item == "-I")
            sources = {item["originalPath"] for item in invocation["inputs"] if item["originalPath"].endswith(".s")}
            headers = set()
            for line in trace.read_text().splitlines():
                opened = re.search(r"O_RDONLY.*= [0-9]+<([^<>\n]+)>\s*$", line)
                if not opened:
                    continue
                filename = opened[1]
                if filename in sources:
                    continue
                if re.fullmatch(r"/proc/[0-9]+/(cgroup|mountinfo)", filename) or filename in {
                    "/sys/fs/cgroup/cpu.max", str(Path.home() / ".config/go/telemetry/local/weekends")
                }:
                    continue
                headers.add(filename)
            for name in sorted(headers):
                header = Path(name)
                if not header.is_absolute() or header.is_symlink() or not any(header.resolve().is_relative_to(base) for base in roots):
                    raise ValueError("assembler header escaped its source/include roots")
                invocation["openedHeaders"].append(dict(originalPath=name, file=retain(root, header)))
            invocation["headerTrace"] = dict(file=retain(root, trace), originalPath=str(trace), exitCode=result.returncode,
                                             executable=retain(root, tracer), argv=command,
                                             version=retain_bytes(root, subprocess.check_output([tracer, "--version"])))
    else:
        result = subprocess.run(arguments, check=False)
    invocation["exitCode"] = result.returncode
    if result.returncode == 0:
        for item in invocation["inputs"] + invocation["includeCandidates"] + invocation["openedHeaders"] + invocation["packageArchives"]:
            if retain(root, item["originalPath"]) != item["file"]:
                raise ValueError("Go tool input changed during execution: " + item["originalPath"])
        if retain(root, arguments[0]) != invocation["executable"]:
            raise ValueError("Go tool executable changed during execution")
        invocation["outputs"] = [dict(originalPath=str(path.resolve()), file=retain(root, path))
                                 for path in outputs]
    (root / "commands" / (uuid.uuid4().hex + ".json")).write_bytes(canonical(invocation))
    return result.returncode


def retain_bytes(root, data):
    filename = root / "files" / hashlib.sha256(data).hexdigest()
    filename.write_bytes(data)
    return retain(root, filename)


def build(go, source, output, jobs):
    go = go.resolve(strict=True)
    source = source.resolve(strict=True)
    if not output.is_absolute() or not output.parent.is_dir() or output.exists() or output.is_symlink():
        raise ValueError("capture requires a new absolute output in an existing parent")
    if not (source / "go.mod").is_file() or not (source / "go.sum").is_file():
        raise ValueError("capture requires the locked Go module")
    environment = {key: os.environ[key] for key in
                   ("HOME", "TMPDIR", "GOCACHE", "GOMODCACHE", "GOPROXY", "GOSUMDB") if key in os.environ}
    environment.update(PATH=str(go.parent) + os.pathsep + os.defpath, GOENV="off", GOFLAGS="", GOWORK="off",
                       GOTOOLCHAIN="local", GOOS="linux", GOARCH="arm64", CGO_ENABLED="0",
                       GOMAXPROCS=str(jobs), GOEXPERIMENT="", GOTELEMETRY="off", LANG="C", TZ="UTC")
    with tempfile.TemporaryDirectory(prefix=".go-build-capture-", dir=output.parent) as temporary:
        root = Path(temporary) / "capture"
        root.mkdir(mode=0o700)
        (root / "files").mkdir()
        (root / "commands").mkdir()
        (root / "process-environment.json").write_bytes(canonical(environment))
        before = {name: retain(root, source / name) for name in ("go.mod", "go.sum")}
        collector = retain(root, Path(__file__))
        version = subprocess.check_output([str(go), "version"], env=environment)
        (root / "version.txt").write_bytes(version)
        selected = ["GOVERSION", "GOOS", "GOARCH", "CGO_ENABLED", "GOROOT", "GOMOD", "GOWORK", "GOEXPERIMENT"]
        observed = subprocess.check_output([str(go), "env", "-json", *selected], cwd=source, env=environment)
        (root / "environment.json").write_bytes(observed)
        wrapper = shlex.join([sys.executable, str(Path(__file__).resolve()), "tool", "--output", str(root), "--"])
        command = [str(go), "build", "-a", "-p=" + str(jobs), "-work", "-x", "-mod=readonly",
                   "-trimpath", "-buildvcs=false", "-gcflags=all=-buildid=", "-toolexec=" + wrapper,
                   "-ldflags=-buildid= -s -w", "-o", str(root / "payload"), "."]
        with (root / "build.log").open("wb") as log:
            result = subprocess.run(command, cwd=source, env=environment, stdout=log,
                                    stderr=subprocess.STDOUT, check=False)
        if result.returncode:
            failure = output.with_name(output.name + ".failure.log")
            with failure.open("xb") as destination, (root / "build.log").open("rb") as log:
                shutil.copyfileobj(log, destination)
            raise RuntimeError("Go build failed; retained log: " + str(failure))
        after = {name: retain(root, source / name) for name in before}
        if before != after:
            raise ValueError("locked module inputs changed during the build")
        if collector != retain(root, Path(__file__)):
            raise ValueError("Go build collector changed during the build")
        package_data = subprocess.check_output([str(go), "list", "-deps", "-json", "-mod=readonly", "."],
                                               cwd=source, env=environment)
        decoder = json.JSONDecoder()
        remaining = package_data.decode().lstrip()
        packages = []
        while remaining:
            package, end = decoder.raw_decode(remaining)
            remaining = remaining[end:].lstrip()
            if package.get("SysoFiles") or package.get("CgoFiles") or package.get("Module", {}).get("Replace"):
                raise ValueError("Go package has an unsupported prebuilt, cgo or replacement input")
            package["retainedSources"] = []
            for field in ("GoFiles", "SFiles", "HFiles", "EmbedFiles"):
                for name in package.get(field, []):
                    filename = Path(package["Dir"]) / name
                    package["retainedSources"].append(dict(kind=field, originalPath=str(filename.resolve()),
                                                           file=retain(root, filename)))
            packages.append(package)
        (root / "packages.json").write_bytes(canonical(packages))
        commands = [json.loads(path.read_bytes()) for path in sorted((root / "commands").glob("*.json"))]
        if not commands or any(item["exitCode"] != 0 for item in commands):
            raise ValueError("missing or failed Go tool invocation")
        links = [item for item in commands if Path(item["argv"][0]).name == "link" and "-importcfg" in item["argv"]]
        if len(links) != 1 or not links[0]["packageArchives"]:
            raise ValueError("missing unambiguous linker package archive trace")
        metadata = dict(kind="hostwright.go-build-capture.v1", command=command,
                        executable=retain(root, go), collector=collector, lockedInputs=before,
                        toolExec=dict(interpreterPath=sys.executable, interpreter=retain(root, sys.executable),
                                      collectorPath=str(Path(__file__).resolve()), output=str(root)),
                        environment=retain(root, root / "process-environment.json"),
                        goEnvironment=retain(root, root / "environment.json"), version=retain(root, root / "version.txt"),
                        packages=retain(root, root / "packages.json"),
                        payload=retain(root, root / "payload"),
                        commands=[retain(root, path) for path in sorted((root / "commands").glob("*.json"))])
        (root / "build.json").write_bytes(canonical(metadata))
        (root / "buildinfo.txt").write_bytes(subprocess.check_output([str(go), "version", "-m", str(root / "payload")], env=environment))
        os.rename(root, output)
    return metadata


def main():
    parser = argparse.ArgumentParser()
    sub = parser.add_subparsers(dest="action", required=True)
    preparation = sub.add_parser("prepare")
    preparation.add_argument("--repository", type=Path, required=True)
    preparation.add_argument("--commit", required=True)
    preparation.add_argument("--toolchain-archive", type=Path, required=True)
    preparation.add_argument("--toolchain-sha256", required=True)
    preparation.add_argument("--output", type=Path, required=True)
    capture = sub.add_parser("build")
    capture.add_argument("--go", type=Path, required=True)
    capture.add_argument("--source", type=Path, required=True)
    capture.add_argument("--output", type=Path, required=True)
    capture.add_argument("--jobs", type=int, choices=range(1, 65), default=1)
    execute = sub.add_parser("tool")
    execute.add_argument("--output", type=Path, required=True)
    execute.add_argument("arguments", nargs=argparse.REMAINDER)
    args = parser.parse_args()
    if args.action == "prepare":
        prepare(args.repository, args.commit, args.toolchain_archive, args.toolchain_sha256, args.output)
        return 0
    if args.action == "tool":
        arguments = args.arguments[1:] if args.arguments[:1] == ["--"] else args.arguments
        return tool(args.output, arguments)
    build(args.go, args.source, args.output, args.jobs)
    return 0


if __name__ == "__main__":
    sys.exit(main())
