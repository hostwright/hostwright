#!/usr/bin/env python3
"""Package the pinned vminit root filesystem without wall-clock metadata."""
import argparse
import gzip
import hashlib
import importlib.util
import io
import pathlib
import tarfile

HERE = pathlib.Path(__file__).resolve().parent
SPEC = importlib.util.spec_from_file_location("runtime_verifier", HERE / "verify-runtime-provenance.py")
VERIFIER = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(VERIFIER)


def create(vminitd, vmexec, output):
    payloads = {}
    for name, source in (("sbin/vminitd", vminitd), ("sbin/vmexec", vmexec)):
        if source.is_symlink() or not source.is_file():
            raise ValueError("runtime executable must be a regular file")
        data = source.read_bytes()
        VERIFIER.elf(data)
        payloads[name] = data
    if output.exists() or output.is_symlink():
        raise ValueError("root filesystem output must not exist")

    buffer = io.BytesIO()
    with tarfile.open(fileobj=buffer, mode="w", format=tarfile.PAX_FORMAT) as archive:
        for name in ("bin", "sbin", "dev", "sys", "proc/self", "run", "tmp", "mnt", "var"):
            entry = tarfile.TarInfo(name)
            entry.type = tarfile.DIRTYPE
            entry.mode = 0o755
            archive.addfile(entry)
        for name, data in payloads.items():
            entry = tarfile.TarInfo(name)
            entry.mode = 0o755
            entry.size = len(data)
            archive.addfile(entry, io.BytesIO(data))
        entry = tarfile.TarInfo("proc/self/exe")
        entry.type = tarfile.SYMTYPE
        entry.linkname = "sbin/vminitd"
        entry.mode = 0o755
        archive.addfile(entry)

    with output.open("xb") as raw:
        with gzip.GzipFile(filename="", mode="wb", fileobj=raw, mtime=0) as compressed:
            compressed.write(buffer.getvalue())
    return hashlib.sha256(output.read_bytes()).hexdigest()


if __name__ == "__main__":
    parser = argparse.ArgumentParser()
    parser.add_argument("--vminitd", type=pathlib.Path, required=True)
    parser.add_argument("--vmexec", type=pathlib.Path, required=True)
    parser.add_argument("--output", type=pathlib.Path, required=True)
    args = parser.parse_args()
    print(create(args.vminitd, args.vmexec, args.output))
