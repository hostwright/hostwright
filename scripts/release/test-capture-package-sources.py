#!/usr/bin/env python3
import importlib.util
import json
import os
from pathlib import Path
import subprocess
import tempfile
import unittest


SPEC = importlib.util.spec_from_file_location(
    "package_capture", Path(__file__).with_name("capture-package-sources.py")
)
CAPTURE = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(CAPTURE)


class PackageSourceTests(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory()
        self.addCleanup(self.temporary.cleanup)
        self.root = Path(self.temporary.name).resolve()
        self.checkouts = self.root / "checkouts"
        self.checkouts.mkdir()
        self.parent = self.checkouts / "package"
        self.parent.mkdir()
        self.git(self.parent, "init", "--quiet")
        (self.parent / "LICENSE").write_text("MIT license evidence\n")
        self.git(self.parent, "add", ".")
        self.child_commit = self.commit(self.parent)
        self.git(self.parent, "update-index", "--add", "--cacheinfo", "160000," + self.child_commit + ",vendor/child")
        self.parent_commit = self.commit(self.parent)
        self.child = self.parent / "vendor/child"
        self.git(self.root, "clone", "--quiet", "--no-checkout", str(self.parent), str(self.child))
        self.git(self.child, "checkout", "--quiet", "--detach", self.child_commit)
        self.lockfile = self.root / "Package.resolved"
        self.lockfile.write_text(json.dumps(dict(version=3, pins=[dict(identity="package", kind="remoteSourceControl",
            location="https://example.invalid/package.git", state=dict(revision=self.parent_commit))])))

    def git(self, repository, *arguments, input=None):
        return subprocess.check_output(["git", "-C", str(repository), *arguments], input=input,
            env={**os.environ, "GIT_AUTHOR_NAME": "Source capture test", "GIT_AUTHOR_EMAIL": "test@example.invalid",
                 "GIT_COMMITTER_NAME": "Source capture test", "GIT_COMMITTER_EMAIL": "test@example.invalid"})

    def commit(self, repository):
        tree = self.git(repository, "write-tree").decode().strip()
        commit = self.git(repository, "commit-tree", tree, input=b"Source capture test\n").decode().strip()
        self.git(repository, "update-ref", "HEAD", commit)
        return commit

    def test_locked_parent_and_submodule_are_both_captured(self):
        output = self.root / "output"
        projects = CAPTURE.capture_packages(self.lockfile, self.checkouts, output)
        self.assertEqual(len(projects), 2)
        parent = next(project for project in projects if project["identity"] == "package")
        child = next(project for project in projects if project["identity"] != "package")
        self.assertEqual(parent["source"]["submodules"], [dict(path="vendor/child", project=child["identity"], commit=self.child_commit)])
        self.assertEqual(child["source"]["commit"], self.child_commit)
        self.assertEqual((output / "Package.resolved").read_bytes(), self.lockfile.read_bytes())
        self.assertTrue((output / child["directory"] / "source.tar.gz").is_file())

    def test_dirty_package_is_rejected_without_partial_output(self):
        (self.parent / "LICENSE").write_text("changed\n")
        with self.assertRaisesRegex(ValueError, "dirty"):
            CAPTURE.capture_packages(self.lockfile, self.checkouts, self.root / "output")
        self.assertFalse((self.root / "output").exists())

    def test_wrong_locked_commit_is_rejected(self):
        lock = json.loads(self.lockfile.read_bytes())
        lock["pins"][0]["state"]["revision"] = self.child_commit
        self.lockfile.write_text(json.dumps(lock))
        with self.assertRaisesRegex(ValueError, "pinned commit"):
            CAPTURE.capture_packages(self.lockfile, self.checkouts, self.root / "output")

    def test_changed_child_is_rejected_without_partial_output(self):
        for committed in (False, True):
            with self.subTest(committed=committed):
                (self.child / "LICENSE").write_text("changed child\n")
                if committed:
                    self.git(self.child, "add", ".")
                    self.commit(self.child)
                with self.assertRaisesRegex(ValueError, "dirty|pinned commit"):
                    CAPTURE.capture_packages(self.lockfile, self.checkouts, self.root / "output")
                self.assertFalse((self.root / "output").exists())

    def test_uninitialized_submodule_is_rejected(self):
        self.child.rename(self.root / "moved-child")
        self.child.mkdir()
        with self.assertRaisesRegex(ValueError, "not initialized|dirty"):
            CAPTURE.capture_packages(self.lockfile, self.checkouts, self.root / "output")


if __name__ == "__main__":
    unittest.main()
