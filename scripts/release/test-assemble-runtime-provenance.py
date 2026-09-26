#!/usr/bin/env python3
import importlib.util
import io
import json
import pathlib
import subprocess
import tarfile
import tempfile
import unittest
from unittest import mock


HERE = pathlib.Path(__file__).resolve().parent


def load(name, filename):
    spec = importlib.util.spec_from_file_location(name, HERE / filename)
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


ASSEMBLER = load("runtime_assembler", "assemble-runtime-provenance.py")
VERIFIER_TEST = load("runtime_verifier_tests", "test-runtime-provenance.py")
CORRESPONDING_SOURCE = load("corresponding_source", "corresponding-source.py")


class RuntimeProvenanceAssemblerTests(unittest.TestCase):
    """Exercise archive closure only; synthetic bytes are not producer evidence."""

    def test_go_capture_retains_nested_tool_input_and_archive_records(self):
        files = {}
        def add(name, data):
            files["go/" + name] = data
            return dict(path=name, sha256=VERIFIER_TEST.v.digest(data), sizeBytes=len(data))
        archive = add("files/package", b"package bytes")
        source = add("files/source", b"source bytes")
        command = add("commands/compile.json", VERIFIER_TEST.v.canonical(dict(
            inputs=[dict(originalPath="/source.go", file=source)],
            outputs=[dict(originalPath="/package.a", file=archive)])))
        packages = add("packages.json", VERIFIER_TEST.v.canonical([dict(retainedSources=[dict(file=source)])]))
        capture = add("build.json", VERIFIER_TEST.v.canonical(dict(
            kind="hostwright.go-build-capture.v1", commands=[command], packages=packages)))
        manifest = dict(loader=dict(buildCapture=dict(capture, path="go/build.json")))
        closure = ASSEMBLER.evidence_records(manifest, files.__getitem__)
        self.assertEqual(set(closure), set(files))
        for name, record in closure.items():
            self.assertEqual(record["sha256"], VERIFIER_TEST.v.digest(files[name]))
        files["go/commands/compile.json"] += b"changed"
        with self.assertRaisesRegex(ValueError, "evidence bytes mismatch"):
            ASSEMBLER.evidence_records(manifest, files.__getitem__)

    def fixture(self, root):
        manifest, inventory, payloads, files = VERIFIER_TEST.fixture()
        files = dict(files)
        files["licenses/runtime-license-inventory.json"] = VERIFIER_TEST.v.canonical(inventory)
        files["runtime-provenance/manifest.json"] = VERIFIER_TEST.v.canonical(manifest)
        files.update({"runtime-provenance/payloads/" + name: data for name, data in payloads.items()})
        files["upstream/kernel-source-signature.json"] = VERIFIER_TEST.v.canonical({
            "kind": "hostwright.kernel-source-signature.v1",
            "archiveSHA256": "7c716216c3c4134ed0de69195701e677577bbcdd3979f331c182acd06bf2f170",
            "fingerprint": "647F28654894E3BD457199BE38DBBDC86092693E",
            "signatureVerified": True,
            "exitStatus": 0,
        })
        for name, data in files.items():
            target = root.joinpath(*name.split("/"))
            target.parent.mkdir(parents=True, exist_ok=True)
            target.write_bytes(data)
        return manifest, inventory, payloads, files

    def assemble(self, source, output, manifest):
        state = {"head": manifest["sourceCommit"], "clean": True,
                 "gitStatusSHA256": VERIFIER_TEST.v.digest(b"")}
        receipt = (source / "upstream/kernel-source-signature.json").read_bytes()
        return ASSEMBLER.assemble(source, output, "0.0.2", state, receipt)

    def test_assembly_is_deterministic_and_verifier_consumable(self):
        with tempfile.TemporaryDirectory() as temporary:
            temporary = pathlib.Path(temporary)
            source = temporary / "input"
            source.mkdir()
            manifest, _, payloads, files = self.fixture(source)
            first = temporary / "first.tar.gz"
            second = temporary / "second.tar.gz"
            first_sha = self.assemble(source, first, manifest)
            second_sha = self.assemble(source, second, manifest)
            self.assertEqual(first_sha, second_sha)
            self.assertEqual(first.read_bytes(), second.read_bytes())
            with tarfile.open(first, "r:gz") as archive:
                self.assertEqual(
                    archive.getnames(),
                    [*sorted(files), "source-manifest.json"],
                )
                with mock.patch.object(VERIFIER_TEST.v, "authenticate"):
                    result = VERIFIER_TEST.v.verify_source_bundle(
                        archive, manifest["sourceCommit"], payloads
                    )
            self.assertEqual(result["payloadCount"], len(payloads))
            producer = manifest["producer"]
            identity = "https://github.com/hostwright/hostwright/.github/workflows/runtime-ingredients.yml@refs/heads/main"
            invocation = "https://github.com/hostwright/hostwright/actions/runs/%d/attempts/%d" % (
                producer["runID"], producer["attempt"]
            )
            def authenticated(command, stdout, **_):
                subject = pathlib.Path(command[3])
                certificate = {
                    "issuer": "https://token.actions.githubusercontent.com",
                    "buildSignerURI": identity,
                    "buildSignerDigest": manifest["sourceCommit"],
                    "sourceRepositoryURI": "https://github.com/hostwright/hostwright",
                    "sourceRepositoryDigest": manifest["sourceCommit"],
                    "sourceRepositoryRef": "refs/heads/main",
                    "runnerEnvironment": "github-hosted",
                    "runInvocationURI": invocation,
                }
                value = [{"verificationResult": {"signature": {"certificate": certificate},
                          "verifiedTimestamps": ["fixture"], "statement": {"subject": [
                              {"digest": {"sha256": VERIFIER_TEST.v.digest(subject.read_bytes())}}
                          ]}}}]
                stdout.write(json.dumps(value).encode())
                return subprocess.CompletedProcess(command, 0)
            with mock.patch("subprocess.run", side_effect=authenticated):
                consumed = CORRESPONDING_SOURCE.verify(
                    first, expected_source=manifest["sourceCommit"], expected_version="0.0.2"
                )
            self.assertEqual(consumed["releaseSourceRevision"], manifest["sourceCommit"])

    def test_missing_changed_extra_and_symlink_inputs_are_rejected(self):
        for change in ("missing", "changed", "extra", "symlink"):
            with self.subTest(change=change), tempfile.TemporaryDirectory() as temporary:
                temporary = pathlib.Path(temporary)
                source = temporary / "input"
                source.mkdir()
                _, _, _, files = self.fixture(source)
                evidence = next(
                    name for name in files if name.startswith("proof/")
                )
                target = source.joinpath(*evidence.split("/"))
                if change == "missing":
                    target.unlink()
                elif change == "changed":
                    target.write_bytes(target.read_bytes() + b"changed")
                elif change == "extra":
                    (source / "unbound.txt").write_text("extra")
                else:
                    target.unlink()
                    target.symlink_to(source / "runtime-provenance/manifest.json")
                with self.assertRaises(ValueError):
                    self.assemble(source, temporary / "out.tar.gz", VERIFIER_TEST.v.parse((source / "runtime-provenance/manifest.json").read_bytes()))

    def test_schema_valid_but_unqualified_inventory_is_rejected(self):
        with tempfile.TemporaryDirectory() as temporary:
            temporary = pathlib.Path(temporary)
            source = temporary / "input"
            source.mkdir()
            manifest, inventory, _, _ = self.fixture(source)
            inventory["status"] = "blocked"
            inventory_data = VERIFIER_TEST.v.canonical(inventory)
            (source / "licenses/runtime-license-inventory.json").write_bytes(inventory_data)
            manifest["runtimeInventorySHA256"] = VERIFIER_TEST.v.digest(inventory_data)
            (source / "runtime-provenance/manifest.json").write_bytes(
                VERIFIER_TEST.v.canonical(manifest)
            )
            with self.assertRaisesRegex(ValueError, "unresolved runtime license evidence"):
                self.assemble(source, temporary / "out.tar.gz", manifest)

    def test_pre_attestation_validation_keeps_subject_and_producer_bindings(self):
        for change, message in (("payload", "evidence bytes mismatch"), ("producer", "invalid producer binding")):
            with self.subTest(change=change), tempfile.TemporaryDirectory() as temporary:
                temporary = pathlib.Path(temporary)
                source = temporary / "input"
                source.mkdir()
                manifest, _, _, _ = self.fixture(source)
                if change == "payload":
                    record = manifest["payloads"][0]
                    target = source / "runtime-provenance/payloads" / record["path"]
                    target.write_bytes(target.read_bytes() + b"changed")
                else:
                    manifest["producer"]["commit"] = "0" * 40
                    (source / "runtime-provenance/manifest.json").write_bytes(
                        VERIFIER_TEST.v.canonical(manifest)
                    )
                with self.assertRaisesRegex(ValueError, message):
                    self.assemble(source, temporary / "out.tar.gz", manifest)


if __name__ == "__main__":
    unittest.main()
