#!/usr/bin/env python3
import copy
import importlib.util
from pathlib import Path
import subprocess
import sys
import tarfile
import tempfile
import unittest
from unittest import mock


def load(name, filename):
    spec = importlib.util.spec_from_file_location(name, Path(__file__).with_name(filename))
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


P = load("native_preparer", "prepare-native-runtime-provenance.py")
FIXTURE = load("native_fixture", "test-runtime-provenance.py")
FINAL = load("final_preparer", "prepare-runtime-provenance.py")
V = P.V


class NativePreparationTests(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory()
        self.addCleanup(self.temporary.cleanup)
        self.root = Path(self.temporary.name).resolve()
        self.ingredients = self.root / "ingredients"
        self.sources = self.root / "projects"
        self.output = self.root / "prepared"
        self.manifest, self.inventory, self.payloads, self.evidence = FIXTURE.fixture()
        self.commit = self.manifest["sourceCommit"]
        self.project = self.manifest["kernel"]["project"]
        for name, data in self.evidence.items():
            self.write(self.ingredients / "evidence", name, data)
            self.write(self.sources, name, data)
        self.write(self.sources, "projects.json", V.canonical(self.manifest["sourceProjects"]))
        kernel = self.manifest["kernel"]
        kernel_data = self.payloads[kernel["payloadPath"]]
        for name in ("payloads/vmlinux", "evidence/rebuilds/kernel-first.Image", "evidence/rebuilds/kernel-second.Image"):
            self.write(self.ingredients, name, kernel_data)
        for name, data in self.payloads.items():
            prefix = self.manifest["oci"]["prefix"] + "/"
            if name.startswith(prefix):
                self.write(self.ingredients, "payloads/vminit/" + name[len(prefix):], data)
        for name in ("vminitd", "vmexec"):
            for location in ("payloads/" + name, "evidence/rebuilds/" + name + "-first", "evidence/rebuilds/" + name + "-second"):
                self.write(self.ingredients, location, FIXTURE.elf())
        self.kernel = dict(status="prepared-not-release-qualified", kind="kernel", toolchain=self.manifest["toolchain"][:1],
            metadata=[dict(originalPath="/build/.config", file=kernel["config"])],
            invocations=[dict(executablePath="/toolchains/clang", target="arch/arm64/kernel/head.o", argv=kernel["commands"])])
        self.write(self.ingredients / "evidence", kernel["commands"]["path"],
                   V.canonical(["/toolchains/clang", "-c", "arch/arm64/kernel/head.S", "-o", "arch/arm64/kernel/head.o"]))
        self.kernel["invocations"][0]["argv"] = self.record(kernel["commands"]["path"])
        self.swift = dict(status="prepared-not-release-qualified", kind="swift", toolchain=self.manifest["toolchain"][1:],
                          invocations=[], links=[])
        self.source_map = []
        for original in self.manifest["oci"]["links"]:
            link = copy.deepcopy(original)
            name = Path(link["path"]).name
            map_path = "proof/" + name + "-first.map"
            self.write(self.ingredients / "evidence", map_path, self.evidence[link["map"]["path"]])
            argv_path = "proof/" + name + "-first.argv"
            response_path = "proof/" + name + "-first.rsp"
            original_response = "/tmp/response-" + name + ".txt"
            self.write(self.ingredients / "evidence", response_path,
                       ("-Map=/build/" + name + "-first.map -o " + name + " libcompiled.a\n").encode())
            self.write(self.ingredients / "evidence", argv_path,
                       V.canonical(["/toolchains/ld.lld", "@" + original_response]))
            self.swift["invocations"].append(dict(executablePath="/toolchains/ld.lld", argv=self.record(argv_path),
                cwd="/build", responseFiles=[dict(originalPath=original_response, file=self.record(response_path))]))
            for selected in link["selectedInputs"]:
                self.source_map.append(dict(objectSHA256=selected["objectSHA256"], sourceFiles=selected.pop("sourceFiles")))
            self.swift["links"].append(dict(map=self.record(map_path), selectedInputs=link["selectedInputs"]))
        self.write_captures()
        self.write(self.ingredients / "evidence", "kernel-source-signature.json", V.canonical(dict(
            kind="hostwright.kernel-source-signature.v1", archiveSHA256="7c716216c3c4134ed0de69195701e677577bbcdd3979f331c182acd06bf2f170",
            fingerprint="647F28654894E3BD457199BE38DBBDC86092693E", signatureVerified=True, exitStatus=0)))

    def write(self, root, name, data):
        path = root / name
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_bytes(data)

    def record(self, name):
        data = (self.ingredients / "evidence" / name).read_bytes()
        return dict(path=name, sha256=V.digest(data), sizeBytes=len(data))

    def write_captures(self):
        for name, capture in (("kernel", self.kernel), ("swift", self.swift)):
            self.write(self.ingredients / "evidence", "native-" + name + "-first.json", V.canonical(capture))

    def prepare(self, source_map_root=None):
        return P.prepare(self.ingredients, self.sources, self.source_map, self.commit, self.project, self.output,
                         source_map_root)

    def generated_headers(self):
        root = self.root / "mapping"
        inputs = {"generated/config.h": b"#define BUILD_CONFIG 1\n",
                  "generated/compile_commands.json": V.canonical([dict(directory="/build",
                      arguments=["clang", "-c", "/source/main.c", "-o", "main.o"], file="/source/main.c")]),
                  "generated/main.d": b"main.o: /source/main.c /build/config.h\n"}
        records = {}
        for name, data in inputs.items():
            self.write(root, name, data)
            records[name] = dict(path=name, sha256=V.digest(data), sizeBytes=len(data))
        for row in self.source_map:
            row["generatedHeaders"] = [dict(originalPath="/build/config.h", file=records["generated/config.h"],
                compilerArguments=["clang", "-c", "/source/main.c", "-o", "main.o"], cwd="/build",
                evidence=dict(path="/build/compile_commands.json", file="/source/main.c", dependencyPath="/build/main.d"),
                retainedEvidence=[dict(originalPath="/build/" + Path(name).name, file=record)
                                  for name, record in records.items() if not name.endswith("config.h")])]
        return root, inputs

    def prepare_final(self):
        loader_root = self.root / "loader"
        for name, data in self.evidence.items():
            self.write(loader_root, name, data)
        self.write(loader_root, "capture-first/payload", FIXTURE.elf())
        self.write(loader_root, "loader-provenance.json", V.canonical(dict(status="prepared-not-release-qualified",
            sourceCommit=self.commit, sourceProjects=self.manifest["sourceProjects"],
            loader=self.manifest["loader"], toolchain=[])))
        return FINAL.prepare(self.output, loader_root, self.commit, 42, 1, self.root / "final")

    def test_native_fragment_rejoins_and_passes_complete_verifier(self):
        native = self.prepare()
        self.assertEqual(native["status"], "prepared-not-release-qualified")
        tools = {row["identity"]: row for row in native["toolchain"]}
        self.assertEqual(set(tools), {"compiler", "linker"})
        self.assertEqual(native["kernel"]["compiler"], tools["compiler"]["executable"])
        final = self.prepare_final()
        self.assertEqual(final["sourceCommit"], self.commit)

    def test_generated_headers_survive_final_preparation_and_archive(self):
        root, inputs = self.generated_headers()
        original = copy.deepcopy(self.source_map)
        native = self.prepare(root)
        self.assertEqual(self.source_map, original)
        header = native["oci"]["links"][0]["selectedInputs"][0]["generatedHeaders"][0]
        self.assertEqual(header["evidence"], original[0]["generatedHeaders"][0]["evidence"])
        self.assertEqual(header["file"]["path"], "evidence/source-map/generated/config.h")
        final = self.prepare_final()
        selected = final["oci"]["links"][0]["selectedInputs"][0]
        self.assertEqual(selected["sourceFiles"], original[0]["sourceFiles"])
        self.assertEqual(selected["generatedHeaders"][0]["compilerArguments"], header["compilerArguments"])
        archive = self.root / "source.tar.gz"
        receipt = (self.output / "upstream/kernel-source-signature.json").read_bytes()
        FINAL.A.assemble(self.root / "final", archive, "0.0.2",
                         dict(head=self.commit, clean=True, gitStatusSHA256=V.digest(b"")), receipt)
        with tarfile.open(archive) as source:
            for name, data in inputs.items():
                stored = "native/evidence/source-map/" + name
                self.assertEqual((self.root / "final" / stored).read_bytes(), data)
                self.assertEqual(source.extractfile(stored).read(), data)
            archived = V.parse(source.extractfile("runtime-provenance/manifest.json").read())
        self.assertEqual(archived["oci"]["links"], final["oci"]["links"])

    def test_compiler_inputs_stay_compact_and_preserve_raw_nested_evidence(self):
        root, inputs = self.generated_headers()
        for row in self.source_map:
            document = dict(objectSHA256=row["objectSHA256"], sourceFiles=[*row["sourceFiles"],
                dict(project=row["sourceFiles"][0]["project"], path="NOTICE", sha256=V.digest(b"Fixture notice text\n"))],
                translationUnits=row["sourceFiles"], generatedHeaders=row.pop("generatedHeaders"))
            raw = V.canonical(document)
            row["compilerInputs"] = dict(path="compiler-inputs.json", sha256=V.digest(raw), sizeBytes=len(raw))
        self.write(root, "compiler-inputs.json", raw)
        inputs["compiler-inputs.json"] = raw
        original_read = Path.read_bytes
        reads = {}
        def read(path):
            if path.is_relative_to(root):
                reads[path] = reads.get(path, 0) + 1
            return original_read(path)
        with mock.patch.object(Path, "read_bytes", read):
            native = self.prepare(root)
        self.assertEqual({name: reads[root / name] for name in inputs}, {name: 1 for name in inputs})
        selected = native["oci"]["links"][0]["selectedInputs"][0]
        self.assertNotIn("generatedHeaders", selected)
        self.assertEqual(len(selected["sourceFiles"]), 1)
        self.assertEqual((self.output / selected["compilerInputs"]["path"]).read_bytes(), raw)
        final = self.prepare_final()
        archive = self.root / "source.tar.gz"
        FINAL.A.assemble(self.root / "final", archive, "0.0.2",
            dict(head=self.commit, clean=True, gitStatusSHA256=V.digest(b"")),
            (self.output / "upstream/kernel-source-signature.json").read_bytes())
        with tarfile.open(archive) as source:
            for name, data in inputs.items():
                self.assertEqual(source.extractfile("native/evidence/source-map/" + name).read(), data)
        self.assertEqual(len(final["oci"]["links"][0]["selectedInputs"][0]["sourceFiles"]), 1)

    def test_compiler_inputs_cannot_escape_or_hide_differing_duplicates(self):
        root, _ = self.generated_headers()
        for row in self.source_map:
            document = dict(objectSHA256=row["objectSHA256"], sourceFiles=row["sourceFiles"],
                translationUnits=row["sourceFiles"], generatedHeaders=row.pop("generatedHeaders"))
            raw = V.canonical(document)
            row["compilerInputs"] = dict(path="compiler-inputs.json", sha256=V.digest(raw), sizeBytes=len(raw))
        self.write(root, "compiler-inputs.json", raw)
        duplicate = copy.deepcopy(self.source_map[0])
        duplicate["compilerInputs"]["path"] = "different-inputs.json"
        changed = copy.deepcopy(document)
        changed["generatedHeaders"][0]["compilerArguments"].append("-DDIFFERENT=1")
        data = V.canonical(changed)
        self.write(root, "different-inputs.json", data)
        duplicate["compilerInputs"].update(sha256=V.digest(data), sizeBytes=len(data))
        self.source_map.append(duplicate)
        with self.assertRaisesRegex(ValueError, "missing or ambiguous native source mapping"):
            self.prepare(root)
        self.source_map.pop()
        document["generatedHeaders"][0]["file"]["path"] = "../outside.h"
        data = V.canonical(document)
        self.write(root, "compiler-inputs.json", data)
        for row in self.source_map:
            row["compilerInputs"].update(sha256=V.digest(data), sizeBytes=len(data))
        with self.assertRaisesRegex(ValueError, "unsafe provenance path"):
            self.prepare(root)
        self.assertFalse(self.output.exists())

    def test_generated_header_files_and_compiler_evidence_are_bound(self):
        root, inputs = self.generated_headers()
        for name, original in inputs.items():
            with self.subTest(name=name):
                (root / name).write_bytes(b"altered")
                with self.assertRaisesRegex(ValueError, "evidence bytes mismatch"):
                    self.prepare(root)
                self.assertFalse(self.output.exists())
                (root / name).unlink()
                with self.assertRaisesRegex(ValueError, "missing native provenance input"):
                    self.prepare(root)
                self.assertFalse(self.output.exists())
                (root / name).write_bytes(original)
        self.assertFalse(list(self.root.glob(".native-provenance-*")))

    def test_generated_header_requires_root_and_retained_compiler_metadata(self):
        root, _ = self.generated_headers()
        with self.assertRaisesRegex(ValueError, "requires a source map root"):
            self.prepare()
        self.source_map[0]["generatedHeaders"][0]["retainedEvidence"] = []
        with self.assertRaisesRegex(ValueError, "missing retained generated-header compiler evidence"):
            self.prepare(root)
        self.assertFalse(self.output.exists())

    def test_duplicate_source_mapping_cannot_drop_differing_generated_evidence(self):
        root, _ = self.generated_headers()
        duplicate = copy.deepcopy(self.source_map[0])
        duplicate["generatedHeaders"][0]["compilerArguments"].append("-DDIFFERENT_CONFIG=1")
        self.source_map.append(duplicate)
        with self.assertRaisesRegex(ValueError, "missing or ambiguous native source mapping"):
            self.prepare(root)
        self.assertFalse(self.output.exists())

    def test_cli_defaults_generated_evidence_root_to_source_map_parent(self):
        root, _ = self.generated_headers()
        mapping = root / "source-map.json"
        mapping.write_bytes(V.canonical(self.source_map))
        subprocess.run([sys.executable, P.__file__, "--ingredients", str(self.ingredients),
            "--source-projects", str(self.sources), "--source-map", str(mapping),
            "--source-commit", self.commit, "--kernel-project", self.project, "--output", str(self.output)],
            check=True, stdout=subprocess.PIPE, stderr=subprocess.PIPE)
        manifest = V.parse((self.output / "native-provenance.json").read_bytes())
        self.assertIn("generatedHeaders", manifest["oci"]["links"][0]["selectedInputs"][0])

    def test_missing_source_mapping_is_refused_atomically(self):
        self.source_map = [dict(objectSHA256="f" * 64, sourceFiles=self.source_map[0]["sourceFiles"])]
        with self.assertRaisesRegex(ValueError, "missing or ambiguous native source mapping"):
            self.prepare()
        self.assertFalse(self.output.exists())

    def test_missing_linker_response_is_refused_atomically(self):
        self.swift["invocations"][0]["responseFiles"] = []
        self.write_captures()
        with self.assertRaisesRegex(ValueError, "linker argv or retained response"):
            self.prepare()
        self.assertFalse(self.output.exists())

    def test_discarded_duplicate_tool_evidence_is_still_validated(self):
        duplicate = copy.deepcopy(self.kernel["toolchain"][0])
        duplicate["executable"]["path"] = "missing-tool-bytes"
        self.swift["toolchain"].append(duplicate)
        self.write_captures()
        with self.assertRaisesRegex(ValueError, "missing native provenance input"):
            self.prepare()
        self.assertFalse(self.output.exists())

    def test_host_tool_command_cannot_stand_in_for_kernel_compilation(self):
        self.kernel["invocations"][0]["target"] = "scripts/basic/fixdep"
        self.write_captures()
        with self.assertRaisesRegex(ValueError, "target-kernel compiler command"):
            self.prepare()

    def test_rebuild_mismatch_and_tampered_sources_fail(self):
        self.write(self.ingredients, "evidence/rebuilds/vmexec-second", b"different output")
        with self.assertRaisesRegex(ValueError, "retained rebuild differs"):
            self.prepare()
        self.write(self.ingredients, "evidence/rebuilds/vmexec-second", FIXTURE.elf())
        self.source_map[0]["sourceFiles"][0]["sha256"] = "0" * 64
        with self.assertRaisesRegex(ValueError, "differs from captured Git source"):
            self.prepare()
        self.assertFalse(self.output.exists())


if __name__ == "__main__":
    unittest.main()
