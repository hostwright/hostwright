#!/usr/bin/env python3
"""Synthetic fixtures exercise preparation, never provide release evidence."""

import copy
import importlib.util
from pathlib import Path
import tarfile
import tempfile
import unittest


HERE = Path(__file__).resolve().parent


def load(name, filename):
    spec = importlib.util.spec_from_file_location(name, HERE / filename)
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


P = load("runtime_preparer", "prepare-runtime-provenance.py")
F = load("runtime_fixture", "test-runtime-provenance.py")


class RuntimePreparationTests(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory()
        self.addCleanup(self.temporary.cleanup)
        self.root = Path(self.temporary.name)
        self.native = self.root / "native-input"
        self.loader = self.root / "loader-input"
        self.output = self.root / "output"
        self.manifest, _, self.payloads, evidence = F.fixture()
        self.commit = self.manifest["sourceCommit"]
        self.native_fragment = dict(status="prepared-not-release-qualified", sourceCommit=self.commit,
            **{key: copy.deepcopy(self.manifest[key]) for key in ("sourceProjects", "toolchain", "kernel", "oci")},
            payloads=[copy.deepcopy(record) for record in self.manifest["payloads"]
                      if record["path"] != self.manifest["loader"]["path"]])
        self.loader_fragment = dict(status="prepared-not-release-qualified", sourceCommit=self.commit,
            sourceProjects=copy.deepcopy(self.manifest["sourceProjects"]), loader=copy.deepcopy(self.manifest["loader"]))
        self.receipt = dict(kind="hostwright.kernel-source-signature.v1",
            archiveSHA256="7c716216c3c4134ed0de69195701e677577bbcdd3979f331c182acd06bf2f170",
            fingerprint="647F28654894E3BD457199BE38DBBDC86092693E", signatureVerified=True, exitStatus=0)
        for name, data in evidence.items():
            self.write(self.native, name, data)
            self.write(self.loader, name, data)
        for record in self.native_fragment["payloads"]:
            self.write(self.native, record["path"], self.payloads[record["path"]])
        self.write(self.loader, "capture-first/payload", self.payloads[self.manifest["loader"]["path"]])
        self.write(self.native, "upstream/kernel-source-signature.json", P.V.canonical(self.receipt))
        self.save_fragments()

    def write(self, root, name, data):
        filename = root / name
        filename.parent.mkdir(parents=True, exist_ok=True)
        filename.write_bytes(data)

    def save_fragments(self):
        self.write(self.native, "native-provenance.json", P.V.canonical(self.native_fragment))
        self.write(self.loader, "loader-provenance.json", P.V.canonical(self.loader_fragment))

    def prepare(self, output=None):
        return P.prepare(self.native, self.loader, self.commit, 123, 2, output or self.output)

    def test_prepares_only_verified_closure_and_assembles_deterministically(self):
        self.write(self.native, "unreferenced.log", b"not source evidence")
        manifest = self.prepare()
        self.assertEqual(len(manifest["sourceProjects"]), 1)
        self.assertEqual(manifest["producer"], dict(commit=self.commit, runID=123, attempt=2))
        self.assertEqual(manifest["oci"]["files"], self.manifest["oci"]["files"])
        self.assertEqual(manifest["oci"]["links"][0]["selectedInputs"][0]["sourceFiles"],
                         self.manifest["oci"]["links"][0]["selectedInputs"][0]["sourceFiles"])
        self.assertFalse((self.output / "native/unreferenced.log").exists())
        self.assertFalse((self.output / "loader/proof/source.tar.gz").exists())
        self.assertTrue((self.output / "native/proof/source.tar.gz").is_file())
        self.assertEqual(manifest, self.prepare(self.root / "second"))
        state = dict(head=self.commit, clean=True, gitStatusSHA256=P.V.digest(b""))
        first, second = self.root / "first.tar.gz", self.root / "second.tar.gz"
        for source, archive in ((self.output, first), (self.root / "second", second)):
            P.A.assemble(source, archive, "0.0.2", state, P.V.canonical(self.receipt))
        self.assertEqual(first.read_bytes(), second.read_bytes())
        with tarfile.open(first) as archive:
            self.assertIn("runtime-provenance/manifest.json", archive.getnames())

    def test_record_rebasing_preserves_source_and_installed_paths(self):
        source = dict(project="project", path="src/main.c", sha256="a" * 64)
        trace = [dict(package="main", archive=dict(path="capture-first/archive.a", sha256="b" * 64,
                      sizeBytes=100), sourceFiles=[source])]
        moved = P.rebase(trace, "loader/")
        self.assertEqual(moved[0]["archive"]["path"], "loader/capture-first/archive.a")
        self.assertEqual(moved[0]["sourceFiles"], [source])
        self.assertEqual(trace[0]["archive"]["path"], "capture-first/archive.a")

    def test_go_package_trace_rebases_global_records_but_capture_stays_relative(self):
        source = dict(project="project", path="src/main.go", sha256="a" * 64)
        files = {}
        def add(name, data):
            files["loader/" + name] = data
            return dict(path=name, sha256=P.V.digest(data), sizeBytes=len(data))
        archive = add("capture-first/archive.a", b"retained archive")
        trace = add("loader-evidence/first/package-trace.json", P.V.canonical([
            dict(package="main", project="project", archive=archive, sourceFiles=[source])]))
        command = add("capture-first/commands/compile.json", P.V.canonical(dict(
            outputs=[dict(file=dict(archive, path="archive.a"))])))
        packages = add("capture-first/packages.json", P.V.canonical([]))
        capture_data = P.V.canonical(dict(kind="hostwright.go-build-capture.v1",
            commands=[dict(command, path="commands/compile.json")], packages=dict(packages, path="packages.json")))
        capture = add("capture-first/build.json", capture_data)
        generated = {}
        moved = P.rebase_loader(dict(format="go-buildinfo-v1", path="installed/loader",
            sourceFiles=[source], packageTrace=trace, buildCapture=capture), files.__getitem__, generated)
        fetch = lambda name: generated[name] if name in generated else files[name]
        moved_trace = P.V.parse(P.V.bound(moved["packageTrace"], fetch))
        self.assertEqual(moved_trace[0]["archive"]["path"], "loader/capture-first/archive.a")
        self.assertEqual(moved_trace[0]["sourceFiles"], [source])
        self.assertEqual(moved["path"], "installed/loader")
        self.assertEqual(P.V.bound(moved["buildCapture"], fetch), capture_data)
        closure = P.A.evidence_records(dict(loader=moved), fetch)
        self.assertIn("loader/capture-first/archive.a", closure)
        self.assertEqual(set(closure), set(files))

    def test_toolchain_sidecar_deduplicates_only_identical_tools(self):
        self.write(self.loader, "loader-toolchain.json", P.V.canonical(self.manifest["toolchain"]))
        self.assertEqual(len(self.prepare()["toolchain"]), 2)
        self.write(self.loader, "proof/clang.version", b"different compiler version")
        with self.assertRaisesRegex(ValueError, "evidence bytes mismatch"):
            self.prepare(self.root / "changed-toolchain")

    def test_tampered_or_missing_evidence_never_publishes(self):
        filename = self.native / "proof/kernel.config"
        filename.write_bytes(b"CONFIG_ARM64=n\n")
        with self.assertRaisesRegex(ValueError, "evidence bytes mismatch"):
            self.prepare()
        self.assertFalse(self.output.exists())
        filename.unlink()
        with self.assertRaisesRegex(ValueError, "missing regular runtime input"):
            self.prepare()
        self.assertFalse(self.output.exists())
        self.assertFalse(list(self.root.glob(".runtime-provenance-*")))

    def test_duplicate_projects_require_identical_metadata_and_bytes(self):
        original = (self.loader / "proof/LICENSE").read_bytes()
        self.write(self.loader, "proof/LICENSE", b"tampered")
        with self.assertRaisesRegex(ValueError, "evidence bytes mismatch"):
            self.prepare()
        self.write(self.loader, "proof/LICENSE", original)
        self.loader_fragment["sourceProjects"][0]["spdx"] = "BSD-3-Clause"
        self.save_fragments()
        with self.assertRaisesRegex(ValueError, "conflicting runtime identity"):
            self.prepare()
        self.assertFalse(self.output.exists())

    def test_missing_component_or_false_oci_attribution_is_rejected(self):
        self.native_fragment["oci"]["files"][0]["components"] = ["missing-project"]
        self.save_fragments()
        with self.assertRaisesRegex(ValueError, "missing runtime source component"):
            self.prepare()
        self.native_fragment["oci"]["files"][0]["components"] = ["compiled-project", "compiled-project"]
        self.save_fragments()
        with self.assertRaisesRegex(ValueError, "OCI file component attribution mismatch"):
            self.prepare()
        self.assertFalse(self.output.exists())

    def test_path_escape_and_symlink_parent_are_rejected(self):
        self.native_fragment["kernel"]["config"]["path"] = "../outside"
        self.save_fragments()
        with self.assertRaisesRegex(ValueError, "unsafe provenance path"):
            self.prepare()
        self.native_fragment["kernel"]["config"]["path"] = "linked/kernel.config"
        (self.native / "linked").symlink_to(self.native / "proof", target_is_directory=True)
        self.save_fragments()
        with self.assertRaisesRegex(ValueError, "symlink in runtime input"):
            self.prepare()
        self.assertFalse(self.output.exists())

    def test_source_binding_signature_and_output_location_are_checked(self):
        self.loader_fragment["sourceCommit"] = "0" * 40
        self.save_fragments()
        with self.assertRaisesRegex(ValueError, "runtime fragment source/status mismatch"):
            self.prepare()
        self.loader_fragment["sourceCommit"] = self.commit
        self.save_fragments()
        self.receipt["signatureVerified"] = False
        self.write(self.native, "upstream/kernel-source-signature.json", P.V.canonical(self.receipt))
        with self.assertRaisesRegex(ValueError, "signature receipt is not qualified"):
            self.prepare()
        with self.assertRaisesRegex(ValueError, "outside input roots"):
            self.prepare(self.native / "output")
        self.output.mkdir()
        with self.assertRaisesRegex(ValueError, "runtime output already exists"):
            self.prepare()

    def test_rebuild_bytes_and_evidence_are_verified(self):
        self.loader_fragment["reproducibleBuild"] = copy.deepcopy(self.loader_fragment["loader"])
        self.write(self.loader, "capture-second/payload", self.payloads[self.manifest["loader"]["path"]])
        self.save_fragments()
        self.prepare()
        self.assertFalse((self.output / "loader/capture-second").exists())
        self.write(self.loader, "capture-second/payload", b"different payload")
        with self.assertRaisesRegex(ValueError, "Go loader rebuilds differ"):
            self.prepare(self.root / "different")
        self.write(self.loader, "capture-second/payload", self.payloads[self.manifest["loader"]["path"]])
        self.loader_fragment["reproducibleBuild"]["selectedInputs"][0]["objectSHA256"] = "0" * 64
        self.save_fragments()
        with self.assertRaises(ValueError):
            self.prepare(self.root / "different")
        self.assertFalse((self.root / "different").exists())

    def test_go_loader_requires_captured_toolchain(self):
        self.loader_fragment["loader"]["format"] = "go-buildinfo-v1"
        self.save_fragments()
        with self.assertRaisesRegex(ValueError, "missing captured Go toolchain records"):
            self.prepare()


if __name__ == "__main__":
    unittest.main()
