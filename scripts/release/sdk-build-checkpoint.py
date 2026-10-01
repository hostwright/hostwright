#!/usr/bin/env python3
"""Create and restore an authenticated, resumable Swift SDK build checkpoint."""

import argparse
import gzip
import hashlib
import importlib.util
import json
import os
from pathlib import Path, PurePosixPath
import re
import shutil
import stat
import subprocess
import tarfile
import tempfile


HERE = Path(__file__).resolve().parent
SPEC = importlib.util.spec_from_file_location("sdk_object_sources", HERE / "capture-sdk-object-sources.py")
CAPTURE = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(CAPTURE)
V = CAPTURE.V
RECIPE_SPEC = importlib.util.spec_from_file_location("sdk_build_recipe", HERE / "sdk-build-recipe.py")
RECIPE = importlib.util.module_from_spec(RECIPE_SPEC)
RECIPE_SPEC.loader.exec_module(RECIPE)
KIND = "hostwright.swift-sdk-build-checkpoint.v1"
PREFIXES = ("sources", "build", "records", "temporary")
MAX_ENTRIES = 1_000_000
INDEX_LIMIT = 256 * 1024**2


def digest_file(path):
    digest = hashlib.sha256()
    with Path(path).open("rb") as stream:
        for block in iter(lambda: stream.read(1024 * 1024), b""):
            digest.update(block)
    return digest.hexdigest()


class _BoundReader:
    def __init__(self, stream):
        self.stream = stream
        self.digest = hashlib.sha256()
        self.size = 0

    def read(self, size=-1):
        data = self.stream.read(size)
        self.digest.update(data)
        self.size += len(data)
        return data


def _inside(path, roots):
    return any(path == root or path.is_relative_to(root) for root in roots)


def _regular(path):
    return path.is_file() and not path.is_symlink()


def _elf_type(path):
    with path.open("rb") as stream:
        header = stream.read(20)
    if len(header) < 20 or header[:4] != b"\x7fELF" or header[4] not in (1, 2) or header[5] not in (1, 2):
        return None
    endian = "little" if header[5] == 1 else "big"
    return int.from_bytes(header[16:18], endian)


def _archive_objects(path):
    """Yield (member name, size, digest) from a Unix ar archive without buffering it."""
    with path.open("rb") as stream:
        V.require(stream.read(8) == b"!<arch>\n", "invalid SDK static library: " + str(path))
        string_table = b""
        while True:
            header = stream.read(60)
            if not header:
                break
            V.require(len(header) == 60 and header[58:60] == b"`\n", "truncated SDK static library: " + str(path))
            raw_name = header[:16].decode("ascii", "strict").rstrip()
            size_text = header[48:58].decode("ascii", "strict").strip()
            V.require(size_text.isdigit(), "invalid SDK archive member size")
            member_size = size = int(size_text)
            data_offset = stream.tell()
            member_end = data_offset + member_size + (member_size & 1)
            name = raw_name.rstrip("/")
            if raw_name == "//":
                string_table = stream.read(size)
                V.require(len(string_table) == size, "truncated SDK archive string table")
                stream.seek(member_end)
                continue
            if raw_name.startswith("#1/"):
                name_size_text = raw_name[3:]
                V.require(name_size_text.isdigit(), "invalid BSD archive member name")
                name_size = int(name_size_text)
                V.require(name_size <= size, "invalid BSD archive member length")
                name = stream.read(name_size).decode("utf-8", "strict")
                data_offset += name_size
                size -= name_size
            elif raw_name.startswith("/") and raw_name[1:].isdigit():
                offset = int(raw_name[1:])
                V.require(offset < len(string_table), "invalid GNU archive member name offset")
                end = string_table.find(b"/\n", offset)
                V.require(end >= 0, "unterminated GNU archive member name")
                name = string_table[offset:end].decode("utf-8", "strict")
            if name not in ("", "/", "__.SYMDEF", "__.SYMDEF SORTED"):
                stream.seek(data_offset)
                digest = hashlib.sha256()
                remaining = size
                while remaining:
                    block = stream.read(min(1024 * 1024, remaining))
                    V.require(block, "truncated SDK archive member")
                    digest.update(block)
                    remaining -= len(block)
                yield name, size, digest.hexdigest()
            stream.seek(member_end)


class _TraceSources:
    """Only the path relocation method needed by the existing trace parser."""
    def __init__(self, temporary_root):
        self.temporary_root = Path(temporary_root).resolve(strict=True)

    def relocate(self, value, cwd=None):
        path = Path(value)
        if not path.is_absolute():
            V.require(cwd is not None, "relative compiler path has no recorded cwd")
            path = Path(cwd) / path
        return path.resolve(strict=False)


def _selected_sdk_objects(build):
    build = Path(build).resolve(strict=True)
    sdk_root = Path(build) / "sdk_root" / "aarch64"
    V.require(sdk_root.is_dir() and not sdk_root.is_symlink(), "compiled SDK root is missing")
    selected = set()
    sizes = set()
    for archive in sorted(sdk_root.rglob("*.a")):
        target = archive.resolve(strict=True)
        V.require(target.is_relative_to(build) and target.is_file(),
                  "SDK archive symlink escapes the build root or is not a file: " + str(archive))
        for _, size, digest in _archive_objects(archive):
            selected.add(digest)
            sizes.add(size)
    for path in sorted(sdk_root.rglob("*")):
        if path.suffix in (".o", ".obj") and path.is_file():
            target = path.resolve(strict=True)
            V.require(target.is_relative_to(build) and target.is_file(),
                      "SDK object symlink escapes the build root or is not a file: " + str(path))
            selected.add(digest_file(path))
            sizes.add(path.stat().st_size)
    V.require(selected, "compiled SDK root contains no selected object inputs")
    return selected, sizes


def _temporary_inputs(trace, trace_cwd, temporary_root, selected, sizes):
    temp_root = Path(temporary_root).resolve(strict=True)
    parser_sources = _TraceSources(temp_root)
    captured = {}
    for row in CAPTURE.trace_compilers(trace, parser_sources, selected, trace_cwd, sizes):
        candidates = list(row.get("sources", []))
        for response in row.get("responseFiles", []):
            candidates.append(response["originalPath"])
        argv = row.get("argv", [])
        required_next = {"-filelist", "-include", "-imacros", "-include-pch", "-fmodule-map-file",
                         "-fmodule-file", "-ivfsoverlay"}
        for index, argument in enumerate(argv):
            if argument.startswith("@"):
                candidates.append(argument[1:])
            elif argument in required_next and index + 1 < len(argv):
                candidates.append(argv[index + 1])
            elif argument.startswith(("-fmodule-map-file=", "-fmodule-file=", "-ivfsoverlay=")):
                candidates.append(argument.split("=", 1)[1])
        for value in candidates:
            if not isinstance(value, str) or not value:
                continue
            path = Path(value)
            if not path.is_absolute():
                path = Path(row.get("cwd") or trace_cwd) / path
            path = path.resolve(strict=False)
            if not path.is_relative_to(temp_root):
                continue
            V.require(path.is_file() and not path.is_symlink(),
                      "trace-referenced temporary compiler input is missing or not a regular file: " + str(path))
            captured[path] = (digest_file(path), path.stat().st_size)
    return temp_root, captured


def _tree_entries(label, root, roots, build_root):
    root = Path(root)
    entries = [dict(path=label, type="directory", mode=stat.S_IMODE(root.stat().st_mode))]
    for directory, children, filenames in os.walk(root, followlinks=False):
        parent = Path(directory)
        relative_parent = parent.relative_to(root)
        kept_children = []
        for name in sorted(children):
            path = parent / name
            rel = PurePosixPath(label, relative_parent.as_posix(), name).as_posix()
            if path.is_symlink():
                target = path.resolve(strict=False)
                V.require(_inside(target, tuple(root for root, _ in roots)),
                          "checkpoint symlink escapes declared roots: " + str(path))
                entries.append(dict(path=rel, type="symlink", mode=stat.S_IMODE(path.lstat().st_mode),
                                    target=str(target)))
            else:
                kept_children.append(name)
                entries.append(dict(path=rel, type="directory", mode=stat.S_IMODE(path.stat().st_mode)))
        children[:] = kept_children
        for name in sorted(filenames):
            path = parent / name
            rel = PurePosixPath(label, relative_parent.as_posix(), name).as_posix()
            st = path.lstat()
            if stat.S_ISLNK(st.st_mode):
                target = path.resolve(strict=False)
                V.require(_inside(target, tuple(root for root, _ in roots)),
                          "checkpoint symlink escapes declared roots: " + str(path))
                entries.append(dict(path=rel, type="symlink", mode=stat.S_IMODE(st.st_mode), target=str(target)))
                continue
            V.require(stat.S_ISREG(st.st_mode), "unsupported checkpoint file type: " + str(path))
            if label == "build" and not path.is_relative_to(build_root / "sdk_root") and _elf_type(path) in (2, 3):
                entries.append(dict(path=rel, type="excluded-elf", mode=stat.S_IMODE(st.st_mode),
                                    sizeBytes=st.st_size, sha256=digest_file(path), reason="host executable outside SDK root"))
                continue
            entries.append(dict(path=rel, type="file", mode=stat.S_IMODE(st.st_mode),
                                sizeBytes=st.st_size, sha256=digest_file(path)))
    return entries


def _tar_add_tree(archive, label, root, index, all_roots):
    root = Path(root)
    root_row = index[label]
    root_info = tarfile.TarInfo(label + "/")
    root_info.type, root_info.mode, root_info.mtime = tarfile.DIRTYPE, root_row["mode"], 0
    archive.addfile(root_info)
    for directory, children, filenames in os.walk(root, followlinks=False):
        parent = Path(directory)
        relative_parent = parent.relative_to(root)
        for name in sorted(children):
            path = parent / name
            member_name = PurePosixPath(label, relative_parent.as_posix(), name).as_posix()
            if path.is_symlink():
                _add_link(archive, path, member_name, all_roots)
            else:
                row = index[member_name]
                info = tarfile.TarInfo(member_name + "/")
                info.type, info.mode, info.mtime = tarfile.DIRTYPE, row["mode"], 0
                archive.addfile(info)
        for name in sorted(filenames):
            path = parent / name
            member_name = PurePosixPath(label, relative_parent.as_posix(), name).as_posix()
            row = index.get(member_name)
            if row is None or row["type"] != "file":
                if path.is_symlink():
                    _add_link(archive, path, member_name, all_roots)
                continue
            info = tarfile.TarInfo(member_name)
            info.size = row["sizeBytes"]
            info.mode = row["mode"]
            info.mtime = 0
            with path.open("rb") as stream:
                bounded = _BoundReader(stream)
                archive.addfile(info, bounded)
            V.require(bounded.size == row["sizeBytes"] and bounded.digest.hexdigest() == row["sha256"],
                      "checkpoint input changed during archive capture: " + str(path))
def _add_link(archive, path, member_name, roots):
    target = path.resolve(strict=False)
    V.require(_inside(target, tuple(root for root, _ in roots)),
              "checkpoint symlink escapes declared roots: " + str(path))
    match = next(((root, label) for root, label in roots if _inside(target, (root,))), None)
    V.require(match is not None, "checkpoint symlink has no declared root: " + str(path))
    root, label = match
    logical_target = PurePosixPath(label, target.relative_to(root).as_posix()).as_posix()
    linkname = os.path.relpath(logical_target, PurePosixPath(member_name).parent.as_posix())
    info = tarfile.TarInfo(member_name)
    info.type = tarfile.SYMTYPE
    info.linkname = linkname
    info.mode = stat.S_IMODE(path.lstat().st_mode)
    info.mtime = 0
    archive.addfile(info)


def create(sources, build, records, trace, trace_cwd, source_commit, run_id, attempt,
           output, temporary_root=Path("/tmp"), repo_root=None):
    roots = [Path(value).resolve(strict=True) for value in (sources, build, records)]
    sources_root, build_root, records_root = roots
    V.require(all(root.is_dir() and not Path(value).is_symlink()
                  for root, value in zip(roots, (sources, build, records))), "checkpoint roots must be real directories")
    V.require(all(not _inside(left, (right,)) and not _inside(right, (left,))
                  for i, left in enumerate(roots) for right in roots[i + 1:]), "checkpoint roots overlap")
    V.require(re.fullmatch(r"[a-f0-9]{40}", source_commit) is not None, "invalid checkpoint source commit")
    V.require(type(run_id) is int and run_id > 0 and type(attempt) is int and attempt > 0,
              "invalid checkpoint producer identity")
    output = Path(output)
    V.require(output.is_absolute() and output.parent.is_dir() and not output.exists() and not output.is_symlink(),
              "checkpoint output must be a new absolute directory")
    repo_root = Path(repo_root or HERE.parents[1]).resolve(strict=True)
    actual_commit = subprocess.check_output(["git", "-C", str(repo_root), "rev-parse", "HEAD"], text=True).strip()
    V.require(actual_commit == source_commit, "checkpoint source commit differs from the producer checkout")
    recipe = RECIPE.fingerprint(repo_root)
    trace, trace_cwd = Path(trace).resolve(strict=True), Path(trace_cwd).resolve(strict=True)
    V.require(_inside(trace, (records_root,)) and
              (trace_cwd == repo_root or _inside(trace_cwd, (build_root,))),
              "compiler trace and cwd must be inside retained records/build roots")
    selected, sizes = _selected_sdk_objects(build_root)
    temp_root, temp_files = _temporary_inputs(trace, trace_cwd, temporary_root, selected, sizes)
    V.require(all(not _inside(temp_root, (root,)) and not _inside(root, (temp_root,)) for root in roots),
              "temporary root overlaps another checkpoint root")
    all_roots = tuple((root, label) for root, label in zip(roots, PREFIXES[:3])) + ((temp_root, "temporary"),)
    directory = output
    directory.mkdir(mode=0o700)
    try:
        entries = []
        for label, root in zip(PREFIXES[:3], roots):
            entries.extend(_tree_entries(label, root, all_roots, build_root))
        temporary_directories = {PurePosixPath("temporary")}
        for path, (digest, size) in sorted(temp_files.items()):
            relative = PurePosixPath(path.relative_to(temp_root).as_posix())
            for count in range(0, len(relative.parts)):
                temporary_directories.add(PurePosixPath("temporary", *relative.parts[:count]))
            entries.append(dict(path=PurePosixPath("temporary", relative.as_posix()).as_posix(),
                                type="file", mode=stat.S_IMODE(path.stat().st_mode), sizeBytes=size, sha256=digest))
        entries.extend(dict(path=path.as_posix(), type="directory",
                            mode=stat.S_IMODE(temp_root.joinpath(*path.parts[1:]).stat().st_mode))
                       for path in sorted(temporary_directories, key=lambda item: (len(item.parts), item.as_posix())))
        V.require(len(entries) <= MAX_ENTRIES, "checkpoint exceeds file limit")
        index_data = V.canonical(dict(kind=KIND + ".index", entries=entries,
                                      roots={"sources": str(sources_root), "build": str(build_root),
                                             "records": str(records_root), "temporary": str(temp_root)},
                                      trace=str(trace), traceCwd=str(trace_cwd)))
        V.require(len(index_data) <= INDEX_LIMIT, "checkpoint index exceeds size limit")
        index_path = directory / "checkpoint-index.json"
        index_path.write_bytes(index_data)
        by_path = {row["path"]: row for row in entries}
        archive_path = directory / "checkpoint.tar.gz"
        with archive_path.open("xb") as raw, gzip.GzipFile(fileobj=raw, mode="wb", compresslevel=1, mtime=0) as compressed:
            with tarfile.open(fileobj=compressed, mode="w|", format=tarfile.PAX_FORMAT) as archive:
                for label, root in zip(PREFIXES[:3], roots):
                    _tar_add_tree(archive, label, root, by_path, all_roots)
                for path in sorted(temporary_directories, key=lambda item: (len(item.parts), item.as_posix())):
                    name = path.as_posix()
                    info = tarfile.TarInfo(name + "/")
                    info.type, info.mode, info.mtime = tarfile.DIRTYPE, by_path[name]["mode"], 0
                    archive.addfile(info)
                for path in sorted(temp_files):
                    row = by_path[PurePosixPath("temporary", path.relative_to(temp_root).as_posix()).as_posix()]
                    info = tarfile.TarInfo(row["path"])
                    info.size, info.mode, info.mtime = row["sizeBytes"], row["mode"], 0
                    with path.open("rb") as stream:
                        bounded = _BoundReader(stream)
                        archive.addfile(info, bounded)
                    V.require(bounded.size == row["sizeBytes"] and bounded.digest.hexdigest() == row["sha256"],
                              "temporary compiler input changed during archive capture: " + str(path))
        manifest = dict(kind=KIND, sourceCommit=source_commit,
                        producer=dict(commit=source_commit, runID=run_id, attempt=attempt),
                        buildRecipe=recipe,
                        archive=dict(path="checkpoint.tar.gz", sha256=digest_file(archive_path),
                                     sizeBytes=archive_path.stat().st_size),
                        index=dict(path="checkpoint-index.json", sha256=digest_file(index_path),
                                   sizeBytes=index_path.stat().st_size),
                        fileCount=len(entries), excludedELFCount=sum(row["type"] == "excluded-elf" for row in entries))
        (directory / "checkpoint.json").write_bytes(V.canonical(manifest))
        return manifest
    except BaseException:
        shutil.rmtree(directory, ignore_errors=True)
        raise


def _safe_member_name(name):
    path = PurePosixPath(name)
    V.require(not path.is_absolute() and path.parts and all(part not in ("", ".", "..") for part in path.parts),
              "unsafe checkpoint archive path")
    V.require(path.parts[0] in PREFIXES, "unexpected checkpoint archive root")
    return path.as_posix()


def restore(checkpoint, output, source_commit, run_id, attempt, producer_commit=None, repo_root=None):
    checkpoint, output = Path(checkpoint), Path(output)
    V.require(checkpoint.is_dir() and not checkpoint.is_symlink(), "checkpoint directory is required")
    manifest_path = checkpoint / "checkpoint.json"
    manifest = V.parse(manifest_path.read_bytes(), limit=V.MAX_METADATA)
    V.require(manifest.get("kind") == KIND, "invalid checkpoint manifest kind")
    producer = manifest.get("producer")
    producer_commit = producer_commit or source_commit
    V.require(producer == dict(commit=producer_commit, runID=run_id, attempt=attempt)
              and manifest.get("sourceCommit") == producer_commit,
              "checkpoint producer identity mismatch")
    V.authenticate(manifest_path, producer, producer_commit)
    repo_root = Path(repo_root or HERE.parents[1]).resolve(strict=True)
    actual_commit = subprocess.check_output(["git", "-C", str(repo_root), "rev-parse", "HEAD"], text=True).strip()
    V.require(actual_commit == source_commit, "requested source commit differs from the restore checkout")
    ancestor = subprocess.run(["git", "-C", str(repo_root), "merge-base", "--is-ancestor",
                               producer_commit, source_commit], check=False)
    V.require(ancestor.returncode == 0, "checkpoint producer is not an ancestor of the restore source")
    V.require(manifest.get("buildRecipe") == RECIPE.fingerprint(repo_root),
              "checkpoint SDK build recipe differs from the current checkout")
    index_path, archive_path = checkpoint / "checkpoint-index.json", checkpoint / "checkpoint.tar.gz"
    index_ref, archive_ref = manifest.get("index", {}), manifest.get("archive", {})
    V.require(index_ref.get("path") == index_path.name and archive_ref.get("path") == archive_path.name,
              "invalid checkpoint artifact paths")
    V.require(index_path.is_file() and index_path.stat().st_size == index_ref.get("sizeBytes")
              and digest_file(index_path) == index_ref.get("sha256"), "checkpoint index integrity failure")
    V.require(archive_path.is_file() and archive_path.stat().st_size == archive_ref.get("sizeBytes")
              and digest_file(archive_path) == archive_ref.get("sha256"), "checkpoint archive integrity failure")
    index = V.parse(index_path.read_bytes(), limit=INDEX_LIMIT)
    V.require(index.get("kind") == KIND + ".index"
              and len(index.get("entries", [])) == manifest.get("fileCount")
              and len(index.get("entries", [])) <= MAX_ENTRIES,
              "invalid checkpoint index")
    records = {}
    for row in index["entries"]:
        name = _safe_member_name(row.get("path", ""))
        V.require(name not in records and row.get("type") in ("file", "directory", "symlink", "excluded-elf"),
                  "duplicate or invalid checkpoint index entry")
        records[name] = row
    V.require(output.is_absolute() and output.parent.is_dir() and not output.exists() and not output.is_symlink(),
              "checkpoint restore output must be a new absolute path")
    output.mkdir(mode=0o700)
    seen = set()
    try:
        with tarfile.open(archive_path, "r:gz") as archive:
            for member in archive:
                name = _safe_member_name(member.name)
                V.require(name not in seen, "duplicate checkpoint archive member")
                seen.add(name)
                row = records.get(name)
                V.require(row is not None, "unindexed checkpoint archive member")
                destination = output.joinpath(*PurePosixPath(name).parts)
                V.require(destination.resolve(strict=False).is_relative_to(output.resolve()), "checkpoint path escapes output")
                if row["type"] == "directory":
                    V.require(member.isdir(), "checkpoint directory type mismatch")
                    destination.mkdir(parents=True, exist_ok=True)
                    destination.chmod(row["mode"])
                elif row["type"] == "symlink":
                    V.require(member.issym() and member.linkname == _relative_link(name, row["target"], index["roots"]),
                              "checkpoint symlink mismatch")
                    destination.parent.mkdir(parents=True, exist_ok=True)
                    os.symlink(member.linkname, destination)
                elif row["type"] == "file":
                    V.require(member.isfile() and member.size == row["sizeBytes"], "checkpoint file type/size mismatch")
                    destination.parent.mkdir(parents=True, exist_ok=True)
                    source = archive.extractfile(member)
                    V.require(source is not None, "checkpoint file data is missing")
                    digest = hashlib.sha256()
                    with source, destination.open("xb") as target:
                        for block in iter(lambda: source.read(1024 * 1024), b""):
                            digest.update(block)
                            target.write(block)
                    V.require(digest.hexdigest() == row["sha256"], "checkpoint file digest mismatch")
                    destination.chmod(row["mode"])
                else:
                    V.require(False, "excluded compiler executable appeared in checkpoint archive")
        expected = {name for name, row in records.items() if row["type"] in ("file", "directory", "symlink")}
        V.require(seen == expected, "checkpoint archive does not match its index")
        for name, row in records.items():
            if row["type"] != "symlink":
                continue
            path = output.joinpath(*PurePosixPath(name).parts)
            target = path.resolve(strict=False)
            V.require(_inside(target, tuple(output.resolve() / prefix for prefix in PREFIXES)),
                      "restored checkpoint symlink escapes its roots")
        return manifest
    except BaseException:
        shutil.rmtree(output, ignore_errors=True)
        raise


def _relative_link(member_name, target, original_roots):
    absolute = Path(target)
    V.require(absolute.is_absolute() and _inside(absolute, tuple(Path(value) for value in original_roots.values())),
              "invalid indexed checkpoint symlink target")
    source_prefix = next(prefix for prefix, original in original_roots.items()
                         if _inside(absolute, (Path(original),)))
    relative_target = absolute.relative_to(Path(original_roots[source_prefix]))
    relocated_target = Path(source_prefix) / relative_target
    return os.path.relpath(relocated_target.as_posix(), PurePosixPath(member_name).parent.as_posix())


def main(argv=None):
    parser = argparse.ArgumentParser(description=__doc__)
    commands = parser.add_subparsers(dest="command", required=True)
    make = commands.add_parser("create")
    for name in ("sources", "build", "records", "trace", "trace-cwd", "output"):
        make.add_argument("--" + name, type=Path, required=True)
    make.add_argument("--source-commit", required=True)
    make.add_argument("--run-id", type=int, required=True)
    make.add_argument("--attempt", type=int, required=True)
    make.add_argument("--temporary-root", type=Path, default=Path("/tmp"))
    make.add_argument("--repo-root", type=Path, required=True)
    resume = commands.add_parser("restore")
    for name in ("checkpoint", "output"):
        resume.add_argument("--" + name, type=Path, required=True)
    resume.add_argument("--source-commit", required=True)
    resume.add_argument("--producer-commit", required=True)
    resume.add_argument("--run-id", type=int, required=True)
    resume.add_argument("--attempt", type=int, required=True)
    resume.add_argument("--repo-root", type=Path, required=True)
    args = parser.parse_args(argv)
    if args.command == "create":
        result = create(args.sources, args.build, args.records, args.trace, args.trace_cwd,
                        args.source_commit, args.run_id, args.attempt, args.output, args.temporary_root,
                        args.repo_root)
    else:
        result = restore(args.checkpoint, args.output, args.source_commit, args.run_id, args.attempt,
                         args.producer_commit, args.repo_root)
    print(json.dumps({"kind": result["kind"], "sourceCommit": result["sourceCommit"],
                      "fileCount": result.get("fileCount")}, sort_keys=True))


if __name__ == "__main__":
    main()
