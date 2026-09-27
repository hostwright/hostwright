#!/usr/bin/env python3
import importlib.util
from pathlib import Path
import subprocess
import tempfile
import unittest


SPEC = importlib.util.spec_from_file_location("sdk_capture", Path(__file__).with_name("capture-swift-sdk-build-inputs.py"))
C = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(C)


class SDKInputTests(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory()
        self.addCleanup(self.temporary.cleanup)
        self.root = Path(self.temporary.name).resolve()
        self.sources = self.root / "sources"
        self.repository = self.sources / "example"
        self.repository.mkdir(parents=True)
        subprocess.run(["git", "init", "-q", str(self.repository)], check=True)
        (self.repository / "source.c").write_text("int value = 1;\n")
        subprocess.run(["git", "-C", str(self.repository), "add", "."], check=True)
        subprocess.run(["git", "-C", str(self.repository), "-c", "user.name=Test", "-c", "user.email=test@example.test",
                        "commit", "-qm", "source"], check=True)
        commit = C.SOURCE.git(self.repository, "rev-parse", "HEAD").decode().strip()
        self.pins = [dict(destination="example", commit=commit)]
        self.build = self.root / "build"
        self.build.mkdir()
        (self.build / "compile_commands.json").write_text('[{"file":"source.c"}]\n')
        (self.build / "source.o").write_bytes(b"retained object index fixture")
        self.sdk = self.root / "sdk.tar.gz"
        self.sdk.write_bytes(b"SDK archive fixture")
        self.output = self.root / "output"

    def capture(self):
        return C.capture(self.sources, self.build, self.sdk, self.pins, self.output)

    def test_retains_exact_pinned_sources_metadata_and_object_identity(self):
        result = self.capture()
        self.assertEqual(result["sdkArchiveSHA256"], C.digest_file(self.sdk))
        row = result["metadata"][0]
        self.assertEqual((self.output / row["file"]["path"]).read_bytes(), (self.build / "compile_commands.json").read_bytes())
        objects = C.V.parse((self.output / "objects.json").read_bytes())
        self.assertEqual(objects[0]["sha256"], C.digest_file(self.build / "source.o"))
        self.assertTrue((self.output / "source-trees/example/source.tar.gz").is_file())

    def test_preserves_actual_working_tree_patch(self):
        (self.repository / "source.c").write_text("int value = 2;\n")
        result = self.capture()
        patch = (self.output / result["sourceProjects"][0]["workingTreePatch"]["path"]).read_bytes()
        self.assertIn(b"-int value = 1;", patch)
        self.assertIn(b"+int value = 2;", patch)
        self.assertEqual((self.repository / "source.c").read_text(), "int value = 2;\n")

    def test_retains_musl_objects_and_swift_source_lists(self):
        (self.build / "source.lo").write_bytes(b"musl object fixture")
        (self.build / "source.os").write_bytes(b"musl shared object fixture")
        (self.build / "sources").write_text("module.swift\n")
        result = self.capture()
        objects = C.V.parse((self.output / "objects.json").read_bytes())
        self.assertEqual({row["buildPath"] for row in objects}, {"source.o", "source.lo", "source.os"})
        source_list = next(row for row in result["metadata"] if row["buildPath"] == "sources")
        self.assertEqual((self.output / source_list["file"]["path"]).read_text(), "module.swift\n")

    def test_wrong_source_pin_publishes_no_capture(self):
        self.pins[0]["commit"] = "0" * 40
        with self.assertRaisesRegex(ValueError, "exact pin"):
            self.capture()
        self.assertFalse(self.output.exists())

    def test_missing_build_metadata_publishes_no_capture(self):
        (self.build / "compile_commands.json").unlink()
        with self.assertRaisesRegex(ValueError, "compilation metadata"):
            self.capture()
        self.assertFalse(self.output.exists())

    def test_checkout_escape_is_rejected(self):
        self.pins[0]["destination"] = "../escape"
        with self.assertRaisesRegex(ValueError, "unsafe provenance path"):
            self.capture()
        self.assertFalse(self.output.exists())

    def test_output_inside_build_is_rejected_before_recursive_capture(self):
        self.output = self.build / "evidence"
        with self.assertRaisesRegex(ValueError, "outside source and build"):
            self.capture()
        self.assertFalse(self.output.exists())


if __name__ == "__main__":
    unittest.main()
