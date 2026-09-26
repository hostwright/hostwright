#!/usr/bin/env python3
"""Assemble exact runtime build evidence into a deterministic source archive."""

import argparse
import gzip
import hashlib
import importlib.util
import io
import pathlib
import re
import subprocess
import tarfile
import tempfile


HERE = pathlib.Path(__file__).resolve().parent
SPEC = importlib.util.spec_from_file_location(
    "runtime_provenance_verifier", HERE / "verify-runtime-provenance.py"
)
VERIFIER = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(VERIFIER)


def fail(message):
    raise ValueError(message)


def regular(root, relative):
    relative = VERIFIER.path(relative)
    candidate = root.joinpath(*relative.split("/"))
    if candidate.is_symlink() or not candidate.is_file():
        fail("missing regular runtime provenance input: " + relative)
    resolved_root = root.resolve()
    if resolved_root not in candidate.resolve().parents:
        fail("runtime provenance input escapes root: " + relative)
    return candidate


def records(value):
    found = {}

    def visit(item):
        if isinstance(item, dict):
            if {"path", "sha256", "sizeBytes"} <= set(item):
                name = VERIFIER.path(item["path"])
                if name in found and found[name] != item:
                    fail("conflicting runtime provenance record: " + name)
                found[name] = item
            for child in item.values():
                visit(child)
        elif isinstance(item, list):
            for child in item:
                visit(child)

    visit(value)
    return found


def evidence_records(manifest, fetch):
    found = records(manifest)
    capture_record = manifest.get("loader", {}).get("buildCapture")
    if capture_record is None:
        return found
    prefix = capture_record["path"].rsplit("/", 1)[0] + "/" if "/" in capture_record["path"] else ""

    def local(name):
        return fetch(prefix + VERIFIER.path(name))

    capture = VERIFIER.parse(VERIFIER.substantive(capture_record, fetch))
    if capture.get("kind") != "hostwright.go-build-capture.v1":
        fail("wrong Go build capture")
    documents = [capture]
    for record in capture["commands"] + [capture["packages"]]:
        documents.append(VERIFIER.parse(VERIFIER.substantive(record, local)))
    for document in documents:
        for name, record in records(document).items():
            qualified = dict(record, path=prefix + name)
            if qualified["path"] in found and found[qualified["path"]] != qualified:
                fail("conflicting nested Go provenance record")
            found[qualified["path"]] = qualified
    return found


def assemble(input_root, output, version, prepared_source_state, signature_receipt_data):
    if input_root.is_symlink():
        fail("runtime provenance input root must not be a symlink")
    input_root = input_root.resolve()
    if not input_root.is_dir():
        fail("runtime provenance input root must be a directory")
    if output.is_symlink() or output.exists():
        fail("runtime provenance output must not exist")
    if input_root == output.parent.resolve() or input_root in output.parent.resolve().parents:
        fail("runtime provenance output must be outside the input root")

    manifest_path = regular(input_root, "runtime-provenance/manifest.json")
    inventory_path = regular(input_root, "licenses/runtime-license-inventory.json")
    signature_receipt_path = regular(input_root, "upstream/kernel-source-signature.json")
    manifest_data = manifest_path.read_bytes()
    inventory_data = inventory_path.read_bytes()
    manifest = VERIFIER.parse(manifest_data)
    inventory = VERIFIER.parse(inventory_data)
    signature_receipt = VERIFIER.parse(signature_receipt_data)
    if signature_receipt_path.read_bytes() != signature_receipt_data:
        fail("kernel upstream signature receipt changed before assembly")
    VERIFIER.validate_schema(manifest)
    if manifest_data != VERIFIER.canonical(manifest):
        fail("runtime provenance manifest is not canonical JSON")
    if inventory_data != VERIFIER.canonical(inventory):
        fail("runtime license inventory is not canonical JSON")
    if VERIFIER.digest(inventory_data) != manifest["runtimeInventorySHA256"]:
        fail("runtime license inventory digest mismatch")
    if not re.fullmatch(r"0\.0\.2(?:-dev\.(?:[1-9][0-9]{0,2})|-rc\.(?:[1-9][0-9]?))?", version):
        fail("invalid runtime corresponding-source version")
    expected_state = {
        "head": manifest["sourceCommit"],
        "clean": True,
        "gitStatusSHA256": hashlib.sha256(b"").hexdigest(),
    }
    if prepared_source_state != expected_state:
        fail("runtime producer source state is not the exact clean source commit")
    if not (signature_receipt.get("kind") == "hostwright.kernel-source-signature.v1"
            and signature_receipt.get("archiveSHA256") == "7c716216c3c4134ed0de69195701e677577bbcdd3979f331c182acd06bf2f170"
            and signature_receipt.get("fingerprint") == "647F28654894E3BD457199BE38DBBDC86092693E"
            and signature_receipt.get("signatureVerified") is True
            and signature_receipt.get("exitStatus") == 0):
        fail("kernel upstream signature receipt is not qualified")

    required = {
        "runtime-provenance/manifest.json": manifest_path,
        "licenses/runtime-license-inventory.json": inventory_path,
        "upstream/kernel-source-signature.json": signature_receipt_path,
    }
    layer_files = {
        (record["path"], record["sha256"], record["sizeBytes"])
        for record in manifest["oci"]["files"]
    }
    for name, record in evidence_records(manifest, lambda name: regular(input_root, name).read_bytes()).items():
        if (name, record["sha256"], record["sizeBytes"]) in layer_files:
            continue
        archive_name = name
        if record in manifest["payloads"]:
            archive_name = "runtime-provenance/payloads/" + name
        candidate = regular(input_root, archive_name)
        data = candidate.read_bytes()
        if len(data) != record["sizeBytes"] or hashlib.sha256(data).hexdigest() != record["sha256"]:
            fail("runtime provenance evidence bytes mismatch: " + archive_name)
        required[archive_name] = candidate

    actual = {}
    for candidate in input_root.rglob("*"):
        relative = candidate.relative_to(input_root).as_posix()
        if candidate.is_symlink():
            fail("runtime provenance input contains a symlink: " + relative)
        if candidate.is_file():
            actual[VERIFIER.path(relative)] = candidate
        elif not candidate.is_dir():
            fail("runtime provenance input contains a special file: " + relative)
    if set(actual) != set(required):
        missing = sorted(set(required) - set(actual))
        extra = sorted(set(actual) - set(required))
        fail("runtime provenance input closure mismatch: missing=%r extra=%r" % (missing, extra))

    evidence = {name: candidate.read_bytes() for name, candidate in required.items()}
    evidence["runtime-provenance/manifest.json"] = manifest_data
    evidence["licenses/runtime-license-inventory.json"] = inventory_data
    evidence["upstream/kernel-source-signature.json"] = signature_receipt_data
    payloads = {
        record["path"]: evidence["runtime-provenance/payloads/" + record["path"]]
        for record in manifest["payloads"]
    }
    VERIFIER.verify(
        manifest_data,
        inventory,
        payloads,
        evidence.__getitem__,
        manifest["sourceCommit"],
        require_authentication=False,
    )

    source_records = [
        {"path": name, "sha256": hashlib.sha256(data).hexdigest(), "sizeBytes": len(data),
         "mode": 0o644, "type": "regular", "linkTarget": ""}
        for name, data in sorted(evidence.items())
    ]
    source_manifest_data = VERIFIER.canonical({
        "kind": "hostwright.corresponding-source.new-runtime.v1",
        "schemaVersion": 1,
        "releaseSourceRevision": manifest["sourceCommit"],
        "version": version,
        "status": "prepared-not-release-qualified",
        "publicationRoute": "same-github-release-alongside-binaries",
        "upstreamSignatureVerified": True,
        "preparedSourceState": prepared_source_state,
        "files": source_records,
    })

    output.parent.mkdir(parents=True, exist_ok=True)
    buffer = io.BytesIO()
    with tarfile.open(fileobj=buffer, mode="w", format=tarfile.PAX_FORMAT) as archive:
        for name in sorted(required):
            data = evidence[name]
            info = tarfile.TarInfo(name)
            info.size = len(data)
            info.mode = 0o644
            info.uid = info.gid = 0
            info.uname = info.gname = ""
            info.mtime = 0
            archive.addfile(info, io.BytesIO(data))
        info = tarfile.TarInfo("source-manifest.json")
        info.size = len(source_manifest_data)
        info.mode = 0o644
        info.uid = info.gid = 0
        info.uname = info.gname = ""
        info.mtime = 0
        archive.addfile(info, io.BytesIO(source_manifest_data))
    with output.open("xb") as raw:
        with gzip.GzipFile(filename="", mode="wb", fileobj=raw, mtime=0) as compressed:
            compressed.write(buffer.getvalue())
    return hashlib.sha256(output.read_bytes()).hexdigest()


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--input-root", type=pathlib.Path, required=True)
    parser.add_argument("--output", type=pathlib.Path, required=True)
    parser.add_argument("--version", required=True)
    parser.add_argument("--source-root", type=pathlib.Path, required=True)
    parser.add_argument("--kernel-signature-inputs", type=pathlib.Path, required=True)
    parser.add_argument("--gpg")
    parser.add_argument("--gpg-sha256")
    args = parser.parse_args()
    if (args.gpg is None) != (args.gpg_sha256 is None):
        fail("GPG path and SHA256 must be supplied together")
    head = subprocess.check_output(["git", "-C", str(args.source_root), "rev-parse", "HEAD"], text=True).strip()
    status = subprocess.check_output(["git", "-C", str(args.source_root), "status", "--porcelain=v1", "--untracked-files=all"])
    state = {"head": head, "clean": not status, "gitStatusSHA256": hashlib.sha256(status).hexdigest()}
    with tempfile.TemporaryDirectory(prefix="runtime-kernel-signature-") as temporary:
        verified_receipt = pathlib.Path(temporary) / "kernel-source-signature.json"
        command = ["python3", str(HERE / "verify-kernel-source-signature.py"),
                   "--inputs", str(args.kernel_signature_inputs), "--output", str(verified_receipt)]
        if args.gpg is not None:
            command += ["--gpg", args.gpg, "--gpg-sha256", args.gpg_sha256]
        subprocess.run(command, check=True)
        receipt = verified_receipt.read_bytes()
        retained = regular(args.input_root.resolve(), "upstream/kernel-source-signature.json").read_bytes()
        if receipt != retained:
            fail("retained kernel signature receipt differs from independent verification")
        print(assemble(args.input_root, args.output, args.version, state, receipt))


if __name__ == "__main__":
    main()
