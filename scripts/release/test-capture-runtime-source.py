#!/usr/bin/env python3
import copy
import importlib.util
import io
import json
import os
from pathlib import Path
import subprocess
import tarfile
import tempfile
import unittest


SPEC = importlib.util.spec_from_file_location(
    "capture_runtime_source", Path(__file__).with_name("capture-runtime-source.py")
)
CAPTURE = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(CAPTURE)
V = CAPTURE.VERIFIER


class SourceCaptureTests(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory()
        self.addCleanup(self.temporary.cleanup)
        self.root = Path(self.temporary.name).resolve()
        self.repository = self.root / "repository"
        self.repository.mkdir()
        self.git("init", "--quiet")
        (self.repository / "LICENSE").write_text("MIT license evidence\n")
        (self.repository / ".gitattributes").write_text("LICENSE export-ignore\n")
        (self.repository / "run.sh").write_text("#!/bin/sh\nexit 0\n")
        (self.repository / "run.sh").chmod(0o755)
        (self.repository / "link").symlink_to("../../outside")
        self.git("add", ".")
        self.commit = self.commit_tree()

    def git(self, *arguments, input=None):
        return subprocess.check_output(["git", "-C", str(self.repository), *arguments], input=input,
            env={**os.environ, "GIT_AUTHOR_NAME": "Source capture test", "GIT_AUTHOR_EMAIL": "test@example.invalid",
                 "GIT_COMMITTER_NAME": "Source capture test", "GIT_COMMITTER_EMAIL": "test@example.invalid"})

    def commit_tree(self):
        tree = self.git("write-tree").decode().strip()
        return self.git("commit-tree", tree, input=b"Source capture test\n").decode().strip()

    def project(self, output, source):
        license_data = (self.repository / "LICENSE").read_bytes()
        (output / "LICENSE").write_bytes(license_data)
        notice = dict(path="LICENSE", sha256=V.digest(license_data), sizeBytes=len(license_data),
                      sourcePath="LICENSE", component="source-test", spdx="MIT")
        return dict(source, identity="source-test", spdx="MIT", patches=[], licenses=[notice], notices=[notice])

    def test_complete_tree_roundtrips_with_modes_links_and_export_ignored_license(self):
        first, second = self.root / "first", self.root / "second"
        source = CAPTURE.capture(self.repository, self.commit, first)
        CAPTURE.capture(self.repository, self.commit, second)
        self.assertEqual((first / "source.tar.gz").read_bytes(), (second / "source.tar.gz").read_bytes())
        leaves = V.source_project(self.project(first, source), lambda name: (first / name).read_bytes())
        self.assertEqual(set(leaves), {".gitattributes", "LICENSE", "run.sh", "link"})
        self.assertEqual(leaves["run.sh"]["gitMode"], "100755")
        self.assertEqual(leaves["link"]["gitMode"], "120000")
        with tarfile.open(first / "source.tar.gz") as archive:
            self.assertTrue(all(member.isfile() for member in archive))
            self.assertEqual(archive.extractfile("link").read(), b"../../outside")
        with self.assertRaisesRegex(ValueError, "already exists"):
            CAPTURE.capture(self.repository, self.commit, first)

    def test_omitted_source_leaf_is_rejected_even_with_updated_record_hashes(self):
        output = self.root / "capture"
        project = self.project(output, CAPTURE.capture(self.repository, self.commit, output))
        inventory = json.loads((output / "source-inventory.json").read_bytes())
        inventory = [row for row in inventory if row["path"] != "run.sh"]
        data = V.canonical(inventory)
        (output / "source-inventory.json").write_bytes(data)
        project["inventory"].update(sha256=V.digest(data), sizeBytes=len(data))
        buffer = io.BytesIO()
        with tarfile.open(output / "source.tar.gz") as original, tarfile.open(fileobj=buffer, mode="w:gz") as changed:
            for member in original:
                if member.name != "run.sh":
                    changed.addfile(member, original.extractfile(member))
        data = buffer.getvalue()
        (output / "source.tar.gz").write_bytes(data)
        project["archive"].update(sha256=V.digest(data), sizeBytes=len(data))
        with self.assertRaisesRegex(ValueError, "incomplete or wrong source Git tree"):
            V.source_project(project, lambda name: (output / name).read_bytes())

    def test_gitlink_is_refused_without_silent_omission(self):
        self.git("update-index", "--add", "--cacheinfo", "160000," + self.commit + ",dependency")
        commit = self.commit_tree()
        with self.assertRaisesRegex(ValueError, "submodule"):
            CAPTURE.capture(self.repository, commit, self.root / "capture")
        self.assertFalse((self.root / "capture").exists())

    def test_submodule_tree_requires_the_exact_separately_captured_project(self):
        child = self.commit
        self.git("update-index", "--add", "--cacheinfo", "160000," + child + ",vendor/dependency")
        parent = self.commit_tree()
        output = self.root / "parent"
        source = CAPTURE.capture(self.repository, parent, output, {"vendor/dependency": "dependency"})
        project = self.project(output, source)
        fetch = lambda name: (output / name).read_bytes()
        commits = {"source-test": parent, "dependency": child}
        leaves = V.source_project(project, fetch, commits)
        self.assertNotIn("vendor/dependency", leaves)
        self.assertEqual(source["submodules"], [{"path": "vendor/dependency", "project": "dependency", "commit": child}])
        child_output = self.root / "child"
        child_source = CAPTURE.capture(self.repository, child, child_output)
        V.source_project(self.project(child_output, child_source), lambda name: (child_output / name).read_bytes())
        for identities in (None, {}, {"dependency": "0" * 40}):
            with self.subTest(identities=identities), self.assertRaisesRegex(ValueError, "exact captured source"):
                V.source_project(project, fetch, identities)
        for path in ("wrong", "LICENSE", "LICENSE/child", "../escape"):
            changed = copy.deepcopy(project)
            changed["submodules"][0]["path"] = path
            with self.subTest(path=path), self.assertRaises(ValueError):
                V.source_project(changed, fetch, commits)
        changed = copy.deepcopy(project)
        changed["submodules"] *= 2
        with self.assertRaisesRegex(ValueError, "duplicate"):
            V.source_project(changed, fetch, commits)
        changed = copy.deepcopy(project)
        del changed["submodules"]
        with self.assertRaisesRegex(ValueError, "incomplete or wrong source Git tree"):
            V.source_project(changed, fetch, commits)

    def test_submodule_mapping_cannot_add_untracked_dependencies(self):
        with self.assertRaisesRegex(ValueError, "mapping differs"):
            CAPTURE.capture(self.repository, self.commit, self.root / "capture", {"invented": "dependency"})
        self.assertFalse((self.root / "capture").exists())

    def test_gitlink_only_tree_is_refused_before_publishing(self):
        for name in ("LICENSE", ".gitattributes", "run.sh", "link"):
            self.git("update-index", "--force-remove", name)
        self.git("update-index", "--add", "--cacheinfo", "160000," + self.commit + ",dependency")
        commit = self.commit_tree()
        with self.assertRaisesRegex(ValueError, "leaf count"):
            CAPTURE.capture(self.repository, commit, self.root / "capture", {"dependency": "dependency"})
        self.assertFalse((self.root / "capture").exists())

    def test_inventory_limit_is_separate_from_general_metadata(self):
        payload = b'["' + b'a' * V.MAX_METADATA + b'"]'
        with self.assertRaisesRegex(ValueError, "oversized"):
            V.parse(payload)
        self.assertEqual(len(V.parse(payload, limit=V.MAX_SOURCE_INVENTORY)[0]), V.MAX_METADATA)
        with self.assertRaisesRegex(ValueError, "oversized"):
            V.parse(b" " * (V.MAX_SOURCE_INVENTORY + 1), limit=V.MAX_SOURCE_INVENTORY)


if __name__ == "__main__":
    unittest.main()
