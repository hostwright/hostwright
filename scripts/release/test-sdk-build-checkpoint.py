#!/usr/bin/env python3
"""Regression tests for resumable, source-bound SDK build checkpoints."""

import hashlib
import importlib.util
import json
import os
from pathlib import Path
import shutil
import struct
import subprocess
import tarfile
import tempfile
import unittest
from unittest import mock


SPEC = importlib.util.spec_from_file_location(
    "sdk_build_checkpoint", Path(__file__).with_name("sdk-build-checkpoint.py"))
CHECKPOINT = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(CHECKPOINT)
CAPTURE_SPEC = importlib.util.spec_from_file_location(
    "sdk_object_sources", Path(__file__).with_name("capture-sdk-object-sources.py"))
CAPTURE = importlib.util.module_from_spec(CAPTURE_SPEC)
CAPTURE_SPEC.loader.exec_module(CAPTURE)


@unittest.skipUnless(shutil.which("clang"), "a real clang compiler is required")
class SDKBuildCheckpointTests(unittest.TestCase):
    run_id = 12345
    attempt = 2

    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name).resolve()
        self.source_commit = subprocess.check_output(
            ["git", "-C", str(Path(__file__).resolve().parents[2]), "rev-parse", "HEAD"], text=True).strip()
        self.sources = self.root / "sources"
        self.project = self.sources / "swift-project"
        self.project.mkdir(parents=True)
        self.build = self.root / "build"
        self.sdk_root = self.build / "sdk_root" / "aarch64"
        self.sdk_root.mkdir(parents=True)
        self.records = self.root / "records"
        self.records.mkdir()
        self.temporary = self.root / "temporary"
        self.temporary.mkdir()
        self.cwd = self.build

        (self.project / "LICENSE").write_text("MIT fixture license\n")
        (self.project / "value.c").write_text("int value(void) { return VALUE + GENERATED_VALUE; }\n")
        (self.project / "macro.h").write_text("#define GENERATED_VALUE 11\n")
        self.generated = self.temporary / "swift-generated-sources" / "macro.h"
        self.generated.parent.mkdir()
        shutil.copyfile(self.project / "macro.h", self.generated)
        self.response = self.temporary / "compiler.rsp"
        self.response.write_text("-DVALUE=7\n")
        self.object = self.build / "objects" / "Swift.o"
        self.object.parent.mkdir()
        self.depfile = self.build / "objects" / "Swift.d"
        self.command = [shutil.which("clang"), "--target=aarch64-linux-gnu", "@" + str(self.response), "-include", str(self.generated),
                        "-MMD", "-MF", str(self.depfile), "-c",
                        str(self.project / "value.c"),
                        "-o", str(self.object)]
        subprocess.run(self.command, check=True, capture_output=True)
        (self.build / "compile_commands.json").write_bytes(CAPTURE.V.canonical([dict(
            directory=str(self.build), file=str(self.project / "value.c"),
            arguments=self.command, output=str(self.object))]))
        self.project_commit = self.git(self.project, "init", "--quiet")
        self.git(self.project, "config", "user.name", "SDK checkpoint test")
        self.git(self.project, "config", "user.email", "checkpoint@example.invalid")
        self.git(self.project, "add", ".")
        self.git(self.project, "commit", "--quiet", "-m", "pinned source fixture")
        self.project_commit = self.git(self.project, "rev-parse", "HEAD").strip()
        (self.sdk_root / "libswiftCore.a").write_bytes(self.ar_archive(self.object))

        self.relative_object = self.build / "objects" / "retained-rel.o"
        shutil.copyfile(self.object, self.relative_object)
        self.executable = self.build / "bin" / "host-tool"
        self.executable.parent.mkdir()
        self.executable.write_bytes(self.elf_header(2))
        self.executable.chmod(0o755)
        self.sdk_executable = self.sdk_root / "bin" / "sdk-tool"
        self.sdk_executable.parent.mkdir()
        self.sdk_executable.write_bytes(self.elf_header(3))
        self.sdk_executable.chmod(0o755)

        (self.build / "compile-metadata.json").write_text('{"fixture":"retained"}\n')
        (self.records / "build-record.json").write_text('{"build":"success"}\n')
        self.trace = self.records / "build.trace"
        self.trace.write_text(
            f'77 1.000 execve({json.dumps(self.command[0])}, {json.dumps(self.command)}, '
            '0xffff /* 10 vars */) = 0 <0.001>\n'
            '77 1.010 exit_group(0) = ?\n')
        self.checkpoint = self.root / "checkpoint"

    @staticmethod
    def elf_header(kind):
        header = bytearray(20)
        header[:4] = b"\x7fELF"
        header[4:6] = b"\x02\x01"
        struct.pack_into("<H", header, 16, kind)
        return bytes(header)

    @staticmethod
    def ar_archive(path):
        raw = path.read_bytes()
        name = (path.name + "/").encode("ascii")
        header = (name.ljust(16) + b"0".ljust(12) + b"0".ljust(6) + b"0".ljust(6)
                  + b"100644".ljust(8) + str(len(raw)).encode().ljust(10) + b"`\n")
        return b"!<arch>\n" + header + raw + (b"\n" if len(raw) & 1 else b"")

    def create(self, *, output=None, **kwargs):
        source_commit = kwargs.pop("source_commit", self.source_commit)
        return CHECKPOINT.create(
            self.sources, self.build, self.records, self.trace, self.cwd,
            source_commit, self.run_id, self.attempt,
            output or self.checkpoint, temporary_root=self.temporary, **kwargs)

    @staticmethod
    def git(repository, *arguments):
        return subprocess.check_output(["git", "-C", str(repository), *arguments], text=True)

    def capture_map(self, sources, build, output):
        output.mkdir(parents=True)
        restored = sources != self.sources
        trace = build.parent / "records/build.trace" if restored else self.records / "build.trace"
        temporary_root = build.parent / "temporary" if restored else self.temporary
        relocations = ([(self.sources, sources), (self.build, build),
                        (self.temporary, temporary_root)] if restored else [])
        return CAPTURE.capture(sources, [build], build / "sdk_root/aarch64",
            [dict(destination="swift-project", commit=self.project_commit)],
            traces=[trace], relocations=relocations,
            trace_cwd=build, generated_output=output / "generated-headers",
            external_header_roots=[temporary_root])

    def recipe_repository(self):
        checkout = self.root / "recipe-repo"
        repository = Path(__file__).resolve().parents[2]
        for name in ("scripts/release/build-static-swift-sdk.sh",
                     "scripts/release/materialize-swift-sdk-sources.py",
                     "scripts/release/runtime-swift-sources.json",
                     ".github/workflows/runtime-ingredients.yml"):
            destination = checkout / name
            destination.parent.mkdir(parents=True, exist_ok=True)
            shutil.copyfile(repository / name, destination)
        shutil.copytree(repository / "scripts/release/patches/swift-sdk",
                        checkout / "scripts/release/patches/swift-sdk")
        (checkout / "README.md").write_text("evidence-only fixture\n")
        subprocess.run(["git", "-C", str(checkout), "init", "--quiet"], check=True)
        self.git(checkout, "config", "user.name", "SDK checkpoint test")
        self.git(checkout, "config", "user.email", "checkpoint@example.invalid")
        self.git(checkout, "add", ".")
        self.git(checkout, "commit", "--quiet", "-m", "build recipe")
        return checkout, self.git(checkout, "rev-parse", "HEAD").strip()

    def commit_fixture(self, checkout, message):
        self.git(checkout, "add", "-A")
        self.git(checkout, "commit", "--quiet", "-m", message)
        return self.git(checkout, "rev-parse", "HEAD").strip()

    def authenticate_fixture(self, checkpoint, source_commit=None, run_id=None, attempt=None):
        return mock.patch.object(
            CHECKPOINT.V, "authenticate",
            side_effect=lambda path, producer, commit: self.assertEqual(
                (path, producer, commit),
                (checkpoint / "checkpoint.json",
                 dict(commit=source_commit or self.source_commit,
                      runID=self.run_id if run_id is None else run_id,
                      attempt=self.attempt if attempt is None else attempt),
                 source_commit or self.source_commit)))

    def test_restore_preserves_compiled_object_sources_metadata_and_referenced_temp_inputs(self):
        expected_object = self.object.read_bytes()
        self.assertEqual(expected_object[:4], b"\x7fELF")
        expected_sources = (self.project / "value.c").read_bytes()
        expected_build_metadata = (self.build / "compile-metadata.json").read_bytes()
        expected_record = (self.records / "build-record.json").read_bytes()
        expected_response = self.response.read_bytes()
        expected_generated = self.generated.read_bytes()

        manifest = self.create()
        before_mapping = self.capture_map(self.sources, self.build, self.root / "before-map")
        self.assertEqual(before_mapping["counts"]["mappedMembers"], 1)
        self.assertEqual(before_mapping["counts"]["unresolvedMembers"], 0)
        index = json.loads((self.checkpoint / "checkpoint-index.json").read_text())
        indexed = {row["path"]: row for row in index["entries"]}
        self.assertEqual(indexed["build/bin/host-tool"]["type"], "excluded-elf")
        self.assertEqual(indexed["build/objects/retained-rel.o"]["type"], "file")
        self.assertEqual(indexed["build/sdk_root/aarch64/bin/sdk-tool"]["type"], "file")
        self.assertIn("temporary/compiler.rsp", indexed)
        self.assertIn("temporary/swift-generated-sources/macro.h", indexed)
        self.assertEqual(manifest["producer"], dict(commit=self.source_commit,
                                                     runID=self.run_id, attempt=self.attempt))

        shutil.rmtree(self.sources)
        shutil.rmtree(self.build)
        shutil.rmtree(self.records)
        shutil.rmtree(self.temporary)
        restored = self.root / "restored"
        with self.authenticate_fixture(self.checkpoint):
            CHECKPOINT.restore(self.checkpoint, restored, self.source_commit,
                               self.run_id, self.attempt)

        after_mapping = self.capture_map(restored / "sources", restored / "build", self.root / "after-map")

        self.assertEqual((restored / "build/objects/Swift.o").read_bytes(), expected_object)
        self.assertEqual(hashlib.sha256((restored / "build/objects/Swift.o").read_bytes()).hexdigest(),
                         hashlib.sha256(expected_object).hexdigest())
        self.assertEqual((restored / "sources/swift-project/value.c").read_bytes(), expected_sources)
        self.assertEqual((restored / "build/compile-metadata.json").read_bytes(), expected_build_metadata)
        self.assertEqual((restored / "records/build-record.json").read_bytes(), expected_record)
        self.assertEqual((restored / "temporary/compiler.rsp").read_bytes(), expected_response)
        self.assertEqual((restored / "temporary/swift-generated-sources/macro.h").read_bytes(), expected_generated)
        self.assertFalse((restored / "build/bin/host-tool").exists())
        self.assertTrue((restored / "build/sdk_root/aarch64/bin/sdk-tool").exists())
        self.assertEqual(before_mapping["counts"], after_mapping["counts"])
        self.assertEqual([row["objectSHA256"] for row in before_mapping["sourceMap"]],
                         [row["objectSHA256"] for row in after_mapping["sourceMap"]])
        self.assertEqual(before_mapping["sourceMap"][0]["sourceFiles"],
                         after_mapping["sourceMap"][0]["sourceFiles"])

    def test_restore_rejects_archive_and_manifest_tampering(self):
        self.create()
        with (self.checkpoint / "checkpoint.tar.gz").open("ab") as stream:
            stream.write(b"tamper")
        with self.authenticate_fixture(self.checkpoint):
            with self.assertRaisesRegex(ValueError, "checkpoint archive integrity"):
                CHECKPOINT.restore(self.checkpoint, self.root / "restored", self.source_commit,
                                   self.run_id, self.attempt)

        shutil.rmtree(self.checkpoint)
        self.create()
        manifest_path = self.checkpoint / "checkpoint.json"
        manifest = json.loads(manifest_path.read_text())
        manifest["sourceCommit"] = "b" * 40
        manifest_path.write_bytes(CHECKPOINT.V.canonical(manifest))
        with self.assertRaisesRegex(ValueError, "producer identity mismatch"):
            CHECKPOINT.restore(self.checkpoint, self.root / "restored", self.source_commit,
                               self.run_id, self.attempt)

    def test_restore_rejects_wrong_source_run_or_attempt(self):
        self.create()
        for commit, run_id, attempt in (("b" * 40, self.run_id, self.attempt),
                                        (self.source_commit, self.run_id + 1, self.attempt),
                                        (self.source_commit, self.run_id, self.attempt + 1)):
            with self.subTest(commit=commit, run=run_id, attempt=attempt):
                output = self.root / f"restored-{run_id}-{attempt}-{commit[0]}"
                with self.assertRaisesRegex(ValueError, "source commit mismatch|producer identity mismatch"):
                    CHECKPOINT.restore(self.checkpoint, output, commit, run_id, attempt)
                self.assertFalse(output.exists())

    def test_restore_allows_evidence_only_descendant_without_rebuilding_recipe_inputs(self):
        checkout, producer_commit = self.recipe_repository()
        self.create(source_commit=producer_commit, repo_root=checkout)
        evidence_file = checkout / "README.md"
        evidence_file.write_text("evidence-only follow-up\n")
        evidence_commit = self.commit_fixture(checkout, "evidence-only change")

        restored = self.root / "restored-evidence-only"
        with self.authenticate_fixture(self.checkpoint, source_commit=producer_commit):
            CHECKPOINT.restore(self.checkpoint, restored, evidence_commit, self.run_id,
                               self.attempt, producer_commit=producer_commit, repo_root=checkout)
        self.assertEqual((restored / "build/objects/Swift.o").read_bytes(), self.object.read_bytes())

    def test_restore_rejects_changed_recipe_and_unrelated_or_mismatched_checkout(self):
        checkout, producer_commit = self.recipe_repository()
        self.create(source_commit=producer_commit, repo_root=checkout)

        recipe_file = checkout / "scripts/release/build-static-swift-sdk.sh"
        recipe_file.write_bytes(recipe_file.read_bytes() + b"# changed compiler input\n")
        changed_recipe_commit = self.commit_fixture(checkout, "change SDK build recipe")
        with self.authenticate_fixture(self.checkpoint, source_commit=producer_commit):
            with self.assertRaisesRegex(ValueError, "build recipe differs"):
                CHECKPOINT.restore(self.checkpoint, self.root / "changed-recipe", changed_recipe_commit,
                                   self.run_id, self.attempt, producer_commit=producer_commit,
                                   repo_root=checkout)

        # Return to the producer tree, then create a same-tree commit with no parent.
        self.git(checkout, "checkout", "--quiet", producer_commit)
        tree = self.git(checkout, "write-tree").strip()
        unrelated = subprocess.check_output(
            ["git", "-C", str(checkout), "-c", "user.name=SDK checkpoint test",
             "-c", "user.email=checkpoint@example.invalid", "commit-tree", tree, "-m", "unrelated"],
            text=True).strip()
        self.git(checkout, "update-ref", "refs/heads/unrelated", unrelated)
        self.git(checkout, "checkout", "--quiet", "--detach", unrelated)
        with self.authenticate_fixture(self.checkpoint, source_commit=producer_commit):
            with self.assertRaisesRegex(ValueError, "producer is not an ancestor"):
                CHECKPOINT.restore(self.checkpoint, self.root / "unrelated", unrelated,
                                   self.run_id, self.attempt, producer_commit=producer_commit,
                                   repo_root=checkout)

        with self.authenticate_fixture(self.checkpoint, source_commit=producer_commit):
            with self.assertRaisesRegex(ValueError, "requested source commit differs"):
                CHECKPOINT.restore(self.checkpoint, self.root / "wrong-current", "b" * 40,
                                   self.run_id, self.attempt, producer_commit=producer_commit,
                                   repo_root=checkout)

    def test_restore_rejects_missing_archive_input_even_when_archive_digest_is_rebound(self):
        self.create()
        archive_path = self.checkpoint / "checkpoint.tar.gz"
        temporary_archive = self.root / "truncated.tar.gz"
        omitted = "sources/swift-project/value.c"
        with tarfile.open(archive_path, "r:gz") as source, tarfile.open(temporary_archive, "w:gz") as target:
            for member in source:
                if member.name != omitted:
                    target.addfile(member, source.extractfile(member) if member.isfile() else None)
        temporary_archive.replace(archive_path)
        self.rebind_manifest_artifact("archive", archive_path)
        with self.authenticate_fixture(self.checkpoint):
            with self.assertRaisesRegex(ValueError, "does not match its index"):
                CHECKPOINT.restore(self.checkpoint, self.root / "restored", self.source_commit,
                                   self.run_id, self.attempt)

    def test_restore_rejects_duplicate_and_traversal_index_paths(self):
        for mutation, expected in (("duplicate", "duplicate or invalid"),
                                   ("traversal", "unsafe checkpoint archive path")):
            with self.subTest(mutation=mutation):
                shutil.rmtree(self.checkpoint, ignore_errors=True)
                self.create()
                index_path = self.checkpoint / "checkpoint-index.json"
                index = json.loads(index_path.read_text())
                if mutation == "duplicate":
                    index["entries"].append(dict(index["entries"][0]))
                    manifest_path = self.checkpoint / "checkpoint.json"
                    manifest = json.loads(manifest_path.read_text())
                    manifest["fileCount"] += 1
                    manifest_path.write_bytes(CHECKPOINT.V.canonical(manifest))
                else:
                    index["entries"][0]["path"] = "sources/../escape"
                index_path.write_bytes(CHECKPOINT.V.canonical(index))
                self.rebind_manifest_artifact("index", index_path)
                with self.authenticate_fixture(self.checkpoint):
                    with self.assertRaisesRegex(ValueError, expected):
                        CHECKPOINT.restore(self.checkpoint, self.root / "restored", self.source_commit,
                                           self.run_id, self.attempt)

    def test_create_rejects_special_files_and_symlinks_outside_declared_roots(self):
        outside = self.root / "outside"
        outside.write_text("outside\n")
        escape = self.project / "escape"
        escape.symlink_to(outside)
        with self.assertRaisesRegex(ValueError, "symlink escapes declared roots"):
            self.create()
        escape.unlink()
        fifo = self.project / "pipe"
        os.mkfifo(fifo)
        with self.assertRaisesRegex(ValueError, "unsupported checkpoint file type"):
            self.create()

    def test_create_rejects_a_missing_trace_referenced_temporary_input(self):
        self.generated.unlink()
        with self.assertRaisesRegex(ValueError, "temporary compiler input is missing"):
            self.create()

    def test_selected_sdk_inputs_follow_only_internal_symlinks(self):
        expected = CHECKPOINT._selected_sdk_objects(self.build)
        (self.sdk_root / "alias.a").symlink_to("libswiftCore.a")
        (self.sdk_root / "standalone.o").symlink_to(self.object)
        self.assertEqual(CHECKPOINT._selected_sdk_objects(self.build), expected)
        (self.sdk_root / "outside.a").symlink_to(self.project / "value.c")
        with self.assertRaisesRegex(ValueError, "outside|escapes|within|unsafe"):
            CHECKPOINT._selected_sdk_objects(self.build)

    def test_checkpoint_limits_are_enforced_on_create_and_restore(self):
        with mock.patch.object(CHECKPOINT, "MAX_ENTRIES", 1):
            with self.assertRaisesRegex(ValueError, "limit"):
                self.create()
        self.create()
        with self.authenticate_fixture(self.checkpoint), mock.patch.object(CHECKPOINT, "MAX_ENTRIES", 1):
            with self.assertRaisesRegex(ValueError, "invalid checkpoint index"):
                CHECKPOINT.restore(self.checkpoint, self.root / "restored", self.source_commit,
                                   self.run_id, self.attempt)
        self.assertFalse((self.root / "restored").exists())

    def rebind_manifest_artifact(self, key, path):
        manifest_path = self.checkpoint / "checkpoint.json"
        manifest = json.loads(manifest_path.read_text())
        manifest[key]["sha256"] = CHECKPOINT.digest_file(path)
        manifest[key]["sizeBytes"] = path.stat().st_size
        manifest_path.write_bytes(CHECKPOINT.V.canonical(manifest))


if __name__ == "__main__":
    unittest.main()
