#!/usr/bin/env python3
import copy
import hashlib
import importlib.util
import io
import json
import os
from pathlib import Path
import subprocess
import tarfile
import tempfile
import unittest


SPEC = importlib.util.spec_from_file_location("linux_source_capture", Path(__file__).with_name("capture-linux-runtime-source.py"))
CAPTURE = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(CAPTURE)


class LinuxSourceCaptureTests(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory()
        self.addCleanup(self.temporary.cleanup)
        self.root = Path(self.temporary.name).resolve()
        self.repository = self.root / "repository"
        self.repository.mkdir()
        self.git("init", "--quiet")
        (self.repository / "LICENSE").write_text("Source license evidence\n")
        (self.repository / "run.sh").write_text("#!/bin/sh\nexit 0\n")
        (self.repository / "run.sh").chmod(0o755)
        (self.repository / "link").symlink_to("../outside")
        (self.root / "outside").write_text("preserve personal data\n")
        self.archive = self.root / "source.tar"
        self.prefix = "linux-test"
        self.update_archive()

    def git(self, *arguments, input=None):
        return subprocess.check_output(["git", "-C", str(self.repository), *arguments], input=input,
            env={**os.environ, "GIT_AUTHOR_NAME": "Kernel source test", "GIT_AUTHOR_EMAIL": "test@example.invalid",
                 "GIT_COMMITTER_NAME": "Kernel source test", "GIT_COMMITTER_EMAIL": "test@example.invalid"})

    def update_archive(self):
        self.git("add", ".")
        tree = self.git("write-tree").decode().strip()
        self.commit = self.git("commit-tree", tree, input=b"Kernel source test\n").decode().strip()
        self.archive.write_bytes(self.git("archive", "--format=tar", "--prefix=" + self.prefix + "/", self.commit))

    def capture(self, output=None, digest=None):
        return CAPTURE.capture(self.repository, self.archive, output or self.root / "capture", commit=self.commit,
                               archive_sha256=digest or hashlib.sha256(self.archive.read_bytes()).hexdigest(),
                               archive_prefix=self.prefix)

    def rewrite_archive(self, change):
        rows = []
        with tarfile.open(self.archive) as archive:
            for member in archive:
                data = archive.extractfile(member).read() if member.isfile() else None
                rows.append((copy.copy(member), data))
        rows = change(rows)
        with tarfile.open(self.archive, mode="w", format=tarfile.PAX_FORMAT) as archive:
            for member, data in rows:
                if data is not None:
                    member.size = len(data)
                archive.addfile(member, io.BytesIO(data) if data is not None else None)

    def test_real_git_archive_matches_all_leaf_bytes_modes_and_symlinks(self):
        source = self.capture()
        output = self.root / "capture"
        receipt = json.loads((output / "archive-match.json").read_bytes())
        self.assertEqual(receipt["commit"], self.commit)
        self.assertEqual(receipt["tree"], source["tree"])
        self.assertEqual(receipt["leafCount"], 3)
        self.assertEqual(receipt["inventory"], source["inventory"])
        self.assertEqual(receipt["sourceArchive"]["sizeBytes"], self.archive.stat().st_size)
        self.assertEqual(receipt["sourceArchive"]["sha256"], hashlib.sha256(self.archive.read_bytes()).hexdigest())
        inventory = {item["path"]: item for item in json.loads((output / "source-inventory.json").read_bytes())}
        self.assertEqual(inventory["run.sh"]["gitMode"], "100755")
        self.assertEqual(inventory["link"]["gitMode"], "120000")
        with tarfile.open(output / "source.tar.gz") as archive:
            self.assertTrue(archive.getmember("link").isfile())
            self.assertEqual(archive.extractfile("link").read(), b"../outside")
        self.assertEqual((self.root / "outside").read_text(), "preserve personal data\n")

    def test_changed_bytes_modes_and_link_targets_are_refused(self):
        original = self.archive.read_bytes()
        for change in ("bytes", "mode", "link"):
            self.archive.write_bytes(original)
            def alter(rows):
                for member, data in rows:
                    if change == "bytes" and member.name.endswith("/LICENSE"):
                        data = b"different bytes\n"
                    elif change == "mode" and member.name.endswith("/run.sh"):
                        member.mode = 0o644
                    elif change == "link" and member.issym():
                        member.linkname = "LICENSE"
                    yield member, data
            self.rewrite_archive(alter)
            with self.subTest(change=change), self.assertRaisesRegex(ValueError, "differs from the captured Git leaf"):
                self.capture()
            self.assertFalse((self.root / "capture").exists())

    def test_export_ignored_file_is_detected_as_missing_from_signed_tar(self):
        (self.repository / ".gitattributes").write_text("LICENSE export-ignore\n")
        self.update_archive()
        with self.assertRaisesRegex(ValueError, "missing Git leaves: LICENSE"):
            self.capture()
        self.assertFalse((self.root / "capture").exists())

    def test_duplicate_extra_escaping_hardlink_and_special_entries_are_refused(self):
        original = self.archive.read_bytes()
        for change in ("duplicate", "extra", "parent", "absolute", "prefix", "hardlink", "fifo"):
            self.archive.write_bytes(original)
            def alter(rows):
                member = copy.copy(next(row[0] for row in rows if row[0].name.endswith("/LICENSE")))
                data = b"Source license evidence\n"
                if change == "extra":
                    member.name = self.prefix + "/extra"
                elif change == "parent":
                    member.name = self.prefix + "/../escape"
                elif change == "absolute":
                    member.name = "/escape"
                elif change == "prefix":
                    member.name = "elsewhere/escape"
                elif change in ("hardlink", "fifo"):
                    member.name = self.prefix + "/special"
                    member.type = tarfile.LNKTYPE if change == "hardlink" else tarfile.FIFOTYPE
                    member.linkname = self.prefix + "/LICENSE" if change == "hardlink" else ""
                    member.size = 0
                    data = None
                return rows + [(member, data)]
            self.rewrite_archive(alter)
            with self.subTest(change=change), self.assertRaises(ValueError):
                self.capture()
            self.assertFalse((self.root / "capture").exists())

    def test_wrong_archive_digest_and_existing_outputs_are_unchanged(self):
        with self.assertRaisesRegex(ValueError, "archive digest mismatch"):
            self.capture(digest="0" * 64)
        self.assertFalse((self.root / "capture").exists())
        existing = self.root / "existing"
        existing.mkdir()
        (existing / "personal").write_text("retain")
        link = self.root / "link"
        link.symlink_to(existing, target_is_directory=True)
        for output in (existing, link):
            with self.subTest(output=output), self.assertRaisesRegex(ValueError, "new absolute output"):
                self.capture(output)
        self.assertEqual((existing / "personal").read_text(), "retain")


if __name__ == "__main__":
    unittest.main()
