#!/usr/bin/env python3
import importlib.util
from pathlib import Path
import subprocess
import tempfile
import unittest
from unittest import mock


SPEC = importlib.util.spec_from_file_location("go_sources", Path(__file__).with_name("capture-go-runtime-sources.py"))
CAPTURE = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(CAPTURE)


class GoRuntimeSourcesTests(unittest.TestCase):
    def setUp(self):
        temporary = tempfile.TemporaryDirectory()
        self.addCleanup(temporary.cleanup)
        self.root = Path(temporary.name)
        self.repository = self.root / "repository"
        self.repository.mkdir()
        self.git("init", "--quiet")
        self.git("config", "user.name", "Fixture")
        self.git("config", "user.email", "fixture@example.invalid")
        (self.repository / "LICENSE").write_text("Fixture license\n")
        (self.repository / "PATENTS").write_text("Fixture notice\n")
        (self.repository / "source.go").write_text("package fixture\n")
        self.git("add", ".")
        self.git("commit", "--quiet", "-m", "fixture")
        self.commit = self.git("rev-parse", "HEAD").decode().strip()
        self.repositories = self.root / "repositories"
        self.repositories.mkdir()
        subprocess.run(["git", "clone", "--quiet", "--bare", str(self.repository),
                        str(self.repositories / "go-runtime.git")], check=True)
        self.pins = dict(go=dict(identity="go-runtime", commit=self.commit, spdx="BSD-3-Clause",
                                licenses=["LICENSE"], notices=["LICENSE", "PATENTS"]), modules=[])

    def git(self, *arguments):
        return subprocess.check_output(["git", "-C", str(self.repository), *arguments])

    def capture(self):
        return CAPTURE.capture(self.pins, self.repository, self.commit, self.repositories, self.root / "output")

    def test_captures_complete_sources_and_exact_license_files(self):
        projects = self.capture()
        self.assertEqual({item["identity"] for item in projects}, {"hostwright", "go-runtime"})
        for item in projects:
            folder = self.root / "output" / item["directory"]
            leaves = CAPTURE.V.source_project(item["project"], lambda name: (folder / name).read_bytes())
            self.assertEqual(set(leaves), {"LICENSE", "PATENTS", "source.go"})
            for notice in item["project"]["licenses"] + item["project"]["notices"]:
                self.assertEqual((folder / notice["path"]).read_bytes(),
                                 (self.repository / notice["sourcePath"]).read_bytes())

    def test_dirty_host_checkout_is_rejected_without_partial_output(self):
        (self.repository / "source.go").write_text("changed\n")
        with self.assertRaisesRegex(ValueError, "checkout is dirty"):
            self.capture()
        self.assertFalse((self.root / "output").exists())

    def test_unavailable_source_revision_leaves_no_partial_output(self):
        self.pins["go"]["commit"] = "a" * 40
        with self.assertRaises(subprocess.CalledProcessError):
            self.capture()
        self.assertFalse((self.root / "output").exists())

    def test_existing_output_is_preserved(self):
        output = self.root / "output"
        output.mkdir()
        (output / "retain").write_text("retain")
        with self.assertRaisesRegex(ValueError, "new absolute output"):
            self.capture()
        self.assertEqual((output / "retain").read_text(), "retain")

    def test_fetched_pinned_repository_can_be_cloned_by_toolchain_preparation(self):
        self.pins["go"]["repository"] = "https://go.googlesource.com/go"
        run = subprocess.run
        def fetch_local(arguments, **kwargs):
            if "fetch" in arguments:
                arguments = list(arguments)
                arguments[-2] = str(self.repository)
            return run(arguments, **kwargs)
        output = self.root / "fetched"
        with mock.patch.object(CAPTURE.subprocess, "run", side_effect=fetch_local):
            CAPTURE.fetch_repositories(self.pins, output)
        checkout = self.root / "checkout"
        run(["git", "clone", "--quiet", "--no-hardlinks", str(output / "go-runtime.git"), str(checkout)], check=True)
        self.assertEqual(subprocess.check_output(["git", "-C", str(checkout), "rev-parse", "HEAD"]).decode().strip(), self.commit)


if __name__ == "__main__":
    unittest.main()
