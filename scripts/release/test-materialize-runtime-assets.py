#!/usr/bin/env python3
import importlib.util
import pathlib
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


MATERIALIZER = load("runtime_asset_materializer", "materialize-runtime-assets.py")
ASSEMBLER_TEST = load("runtime_assembler_tests", "test-assemble-runtime-provenance.py")


class RuntimeAssetMaterializerTests(unittest.TestCase):
    """Exercise the authenticated handoff with synthetic verifier fixture bytes."""

    def test_materializes_exact_authenticated_product_payloads(self):
        with tempfile.TemporaryDirectory() as temporary:
            temporary = pathlib.Path(temporary).resolve()
            source = temporary / "input"
            source.mkdir()
            case = ASSEMBLER_TEST.RuntimeProvenanceAssemblerTests()
            manifest, _, payloads, _ = case.fixture(source)
            archive = temporary / "runtime-provenance.tar.gz"
            case.assemble(source, archive, manifest)
            output = temporary / "assets"
            with mock.patch.object(MATERIALIZER.VERIFIER, "authenticate") as authenticate:
                result = MATERIALIZER.materialize(archive, output, manifest["sourceCommit"])
            self.assertEqual(authenticate.call_count, len(payloads) + 1)
            self.assertEqual(result["payloadCount"], len(payloads))
            for name, data in payloads.items():
                relative = name.removeprefix(MATERIALIZER.PREFIX)
                self.assertEqual((output / relative).read_bytes(), data)
            self.assertEqual(
                {path.relative_to(output).as_posix() for path in output.rglob("*") if path.is_file()},
                {name.removeprefix(MATERIALIZER.PREFIX) for name in payloads},
            )
            self.assertEqual((output / "guest/hostwright-netfilter").stat().st_mode & 0o777, 0o755)
            for path in output.rglob("*"):
                self.assertEqual(path.stat().st_mode & 0o777, 0o700 if path.is_dir() else (
                    0o755 if path.relative_to(output).as_posix() == "guest/hostwright-netfilter" else 0o644
                ))

    def test_rejects_existing_output_and_authentication_failure(self):
        with tempfile.TemporaryDirectory() as temporary:
            temporary = pathlib.Path(temporary).resolve()
            source = temporary / "input"
            source.mkdir()
            manifest, _, _, _ = ASSEMBLER_TEST.RuntimeProvenanceAssemblerTests().fixture(source)
            archive = temporary / "runtime-provenance.tar.gz"
            ASSEMBLER_TEST.RuntimeProvenanceAssemblerTests().assemble(source, archive, manifest)
            output = temporary / "assets"
            output.mkdir()
            with self.assertRaisesRegex(ValueError, "must not exist"):
                MATERIALIZER.materialize(archive, output, manifest["sourceCommit"])
            output.rmdir()
            with mock.patch.object(MATERIALIZER.VERIFIER, "authenticate", side_effect=ValueError("untrusted")):
                with self.assertRaisesRegex(ValueError, "untrusted"):
                    MATERIALIZER.materialize(archive, output, manifest["sourceCommit"])
            self.assertFalse(output.exists())

    def test_rejects_symlink_archive_and_output_parent(self):
        with tempfile.TemporaryDirectory() as temporary:
            temporary = pathlib.Path(temporary).resolve()
            source = temporary / "input"
            source.mkdir()
            manifest, _, _, _ = ASSEMBLER_TEST.RuntimeProvenanceAssemblerTests().fixture(source)
            archive = temporary / "runtime-provenance.tar.gz"
            ASSEMBLER_TEST.RuntimeProvenanceAssemblerTests().assemble(source, archive, manifest)
            archive_link = temporary / "archive-link.tar.gz"
            archive_link.symlink_to(archive)
            with self.assertRaisesRegex(ValueError, "traverses a symlink"):
                MATERIALIZER.materialize(archive_link, temporary / "assets", manifest["sourceCommit"])
            real_parent = temporary / "real-parent"
            real_parent.mkdir()
            parent_link = temporary / "parent-link"
            parent_link.symlink_to(real_parent, target_is_directory=True)
            with self.assertRaisesRegex(ValueError, "traverses a symlink"):
                MATERIALIZER.materialize(archive, parent_link / "assets", manifest["sourceCommit"])


if __name__ == "__main__":
    unittest.main()
